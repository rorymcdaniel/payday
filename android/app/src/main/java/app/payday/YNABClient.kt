package app.payday

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.RequestBody
import okio.BufferedSink
import java.time.LocalDate
import java.util.concurrent.TimeUnit

// No write retries, redirects, cookies, HTTP cache, analytics, or request logging.
class YNABClient(private val token: String,
    private val client: OkHttpClient = OkHttpClient.Builder().retryOnConnectionFailure(false)
        .followRedirects(false).followSslRedirects(false).connectTimeout(25, TimeUnit.SECONDS)
        .readTimeout(40, TimeUnit.SECONDS).callTimeout(45, TimeUnit.SECONDS).build(),
    private val baseURL: String = "https://api.ynab.com/v1/") : BudgetAPI {
    private var requestsRemaining: Int? = null
    private val apiJson = Json { ignoreUnknownKeys = true }
    override suspend fun plans(): List<Plan> = request("plans").array("plans").map { element ->
        val p = element.jsonObject; val currency = p.obj("currency_format")
        Plan(p.string("id"), p.string("name"), currency.string("iso_code"), currency.int("decimal_digits")).also {
            ensure(it.digits in 0..3, "YNAB did not supply a supported currency format.")
            java.util.Currency.getInstance(it.currency)
        }
    }
    override suspend fun snapshot(planID: String, month: String): Snapshot {
        val prefix = "plans/${component(planID)}"
        val detail = request("$prefix/months/${component(month)}").obj("month")
        val months = request("$prefix/months").array("months").map { it.jsonObject }
        val groups = request("$prefix/categories").array("category_groups").map { it.jsonObject }
        ensure(detail.string("month") == month && months.any { it.string("month") == month }, "YNAB did not return the requested month.")
        val ready = minOf(detail.long("to_be_budgeted"), months.filter { it.string("month") >= month }.minOf { it.long("to_be_budgeted") })
        val categories = detail.array("categories").map { element ->
            val c = element.jsonObject; val group = groups.find { it.string("id") == c.string("category_group_id") }
            Category(c.string("id"), c.string("name"), group?.string("name") ?: "Unavailable", c.long("budgeted"), c.long("balance"),
                !c.bool("hidden") && !c.bool("deleted") && !c.bool("internal") && group != null && !group.bool("hidden") && !group.bool("deleted") && !group.bool("internal"))
        }
        ensure(ready in -Money.limit..Money.limit && categories.map { it.id }.toSet().size == categories.size &&
            categories.all { it.budgeted in -Money.limit..Money.limit && it.balance in -Money.limit..Money.limit }, "YNAB returned unsupported or duplicate amounts.")
        return Snapshot(month, ready, categories)
    }
    override suspend fun incomes(planID: String): List<Income> {
        val prefix = "plans/${component(planID)}"
        val accounts = request("$prefix/accounts").array("accounts").map { it.jsonObject }.filter { it.bool("on_budget") && !it.bool("deleted") }.map { it.string("id") }.toSet()
        return request("$prefix/transactions?since_date=${LocalDate.now().minusDays(60)}").array("transactions").map { it.jsonObject }.filter {
            !it.bool("deleted") && it.long("amount") in 1..Money.limit && it.string("date") <= Dates.day() &&
                it.optional("transfer_account_id") == null && it.array("subtransactions").isEmpty() && accounts.contains(it.string("account_id"))
        }.map {
            Income(it.string("id"), it.string("date"), it.optional("payee_name") ?: "Income", it.long("amount"),
                listOfNotNull(it.optional("matched_transaction_id"), it.optional("import_id")?.let { import -> "import:${it.string("account_id")}:$import" }))
        }.sortedByDescending { it.date }
    }
    override suspend fun assign(planID: String, month: String, categoryID: String, budgeted: Long): Long {
        val result = request("plans/${component(planID)}/months/${component(month)}/categories/${component(categoryID)}",
            "{\"category\":{\"budgeted\":$budgeted}}").obj("category")
        ensure(result.string("id") == categoryID, "YNAB returned a different category. The write outcome is uncertain.")
        return result.long("budgeted")
    }
    override fun checkWriteCapacity(categoryCount: Int) {
        ensure(categoryCount * 4 <= (requestsRemaining ?: 190), "There isn’t enough YNAB API capacity to safely apply and verify this allocation. Wait for the hourly limit to recover.")
    }
    private fun component(value: String): String { ensure(value.matches(Regex("[A-Za-z0-9-]+")), "Invalid YNAB identifier."); return value }
    private suspend fun request(path: String, body: String? = null): JsonObject = withContext(Dispatchers.IO) {
        val request = Request.Builder().url(baseURL + path).header("Authorization", "Bearer $token").header("Accept", "application/json")
        if (body != null) {
            val payload = body.toRequestBody("application/json".toMediaType())
            request.patch(object : RequestBody() {
                override fun contentType() = payload.contentType()
                override fun contentLength() = payload.contentLength()
                override fun writeTo(sink: BufferedSink) = payload.writeTo(sink)
                // Also forbids HTTP follow-ups such as 503 + Retry-After: 0.
                override fun isOneShot() = true
            })
        }
        try {
            client.newCall(request.build()).execute().use { response ->
                response.header("X-Rate-Limit")?.split("/")?.let { parts ->
                    if (parts.size == 2) { val used = parts[0].trim().toIntOrNull(); val limit = parts[1].trim().toIntOrNull(); if (used != null && limit != null) requestsRemaining = maxOf(0, limit - used) }
                }
                ensure(response.isSuccessful, when (response.code) {
                    401, 403 -> "YNAB denied access. Check your token in Settings."
                    429 -> "YNAB’s hourly request limit has been reached. Wait before refreshing."
                    404 -> "The requested budget, month, or category is unavailable."
                    else -> "YNAB returned HTTP ${response.code}. Inspect History if an allocation was in progress."
                })
                val bytes = response.body?.byteStream()?.readNBytes(Transfers.maxBytes + 1) ?: throw PaydayException("YNAB returned an empty response.")
                ensure(bytes.size <= Transfers.maxBytes, "YNAB returned an oversized response.")
                apiJson.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject.obj("data")
            }
        } catch (e: PaydayException) { throw e }
        catch (_: Exception) { throw PaydayException("Could not read a verified response from YNAB. Check your connection; inspect History if applying was in progress.") }
    }
}
private fun JsonObject.string(key: String) = getValue(key).jsonPrimitive.content
private fun JsonObject.optional(key: String) = get(key)?.jsonPrimitive?.contentOrNull
private fun JsonObject.long(key: String) = getValue(key).jsonPrimitive.long
private fun JsonObject.int(key: String) = getValue(key).jsonPrimitive.int
private fun JsonObject.bool(key: String) = getValue(key).jsonPrimitive.boolean
private fun JsonObject.obj(key: String) = getValue(key).jsonObject
private fun JsonObject.array(key: String) = getValue(key).jsonArray
