package app.payday

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.math.BigDecimal
import java.text.NumberFormat
import java.time.LocalDate
import java.util.Currency
import java.util.Locale
import java.util.UUID

val paydayJson = Json { ignoreUnknownKeys = false; encodeDefaults = true; explicitNulls = false }
fun ensure(value: Boolean, message: String) { if (!value) throw PaydayException(message) }
class PaydayException(message: String) : Exception(message)
object Dates {
    fun day(): String = LocalDate.now().toString()
    fun month(): String = LocalDate.now().withDayOfMonth(1).toString()
}
@Serializable data class Plan(val id: String, val name: String, val currency: String = "USD", val digits: Int = 2)
@Serializable data class Category(val id: String, val name: String, val group: String, val budgeted: Long, val balance: Long, val eligible: Boolean)
@Serializable data class Snapshot(val month: String, val readyToAssign: Long, val categories: List<Category>)
@Serializable data class Income(val id: String, val date: String, val name: String, val amount: Long, val aliases: List<String>? = null) {
    val identityKeys get() = (listOf(id) + aliases.orEmpty()).toSet()
}
@Serializable data class Contribution(val categoryID: String, val name: String, val amount: Long, val normal: Long = 0)
@Serializable data class Draft(
    val id: String = UUID.randomUUID().toString().uppercase(Locale.ROOT), val planID: String,
    val month: String = Dates.month(), val date: String = Dates.day(), val reference: String = "Paycheck",
    val incomeID: String? = null, val incomeAliases: List<String>? = null, val usesReadyToAssign: Boolean? = null,
    val amount: Long = 0, val contributions: List<Contribution>, val normalContributions: List<Contribution>? = null
) {
    val identity get() = "$planID|$date|${reference.trim().lowercase(Locale.ROOT)}"
    fun synchronize(defaults: List<Contribution>): Draft {
        val baseline = normalContributions ?: contributions.map { it.copy(amount = it.normal) }
        val next = defaults.mapNotNull { normal ->
            val old = baseline.find { it.categoryID == normal.categoryID }
            val row = contributions.find { it.categoryID == normal.categoryID }
            when {
                row != null -> row.copy(name = normal.name, normal = normal.amount, amount = if (old != null && row.amount == old.amount) normal.amount else row.amount)
                old == null -> normal.copy(normal = normal.amount)
                else -> null
            }
        } + contributions.filter { row -> defaults.none { it.categoryID == row.categoryID } &&
            baseline.find { it.categoryID == row.categoryID }?.amount != row.amount }.map { it.copy(normal = 0) }
        return copy(contributions = next, normalContributions = defaults.map { it.copy(normal = it.amount) })
    }
    fun useReady(snapshot: Snapshot, history: List<Operation>, digits: Int): Draft {
        ensure(snapshot.month == month && month == Dates.month(), "Start a new paycheck for the current month.")
        ensure(snapshot.readyToAssign in 1..Money.limit, "There is no positive Ready to Assign, including future months.")
        ensure(snapshot.readyToAssign % Money.unit(digits) == 0L, "Ready to Assign has unsupported currency precision.")
        var next = if (usesReadyToAssign == true) this else copy(date = Dates.day(), reference = "Ready to Assign")
        var sequence = 2
        if (usesReadyToAssign != true) while (history.any { it.draft.identity == next.identity }) next = next.copy(reference = "Ready to Assign ${sequence++}")
        return next.copy(amount = snapshot.readyToAssign, incomeID = null, incomeAliases = null, usesReadyToAssign = true)
    }
}
@Serializable enum class StepStatus { pending, sending, verified, uncertain }
@Serializable enum class OperationStatus { applying, completed, needsAttention, reconciled }
@Serializable data class Step(val contribution: Contribution, val beforeBudgeted: Long, val beforeBalance: Long,
    val targetBudgeted: Long, val status: StepStatus = StepStatus.pending, val observation: Long? = null)
@Serializable data class Operation(val id: String, val draft: Draft, val plan: Plan, val createdAt: String,
    val status: OperationStatus, val readyBefore: Long, val steps: List<Step>, val message: String? = null,
    val reconciliationNote: String? = null, val resolvedAt: String? = null) {
    val blocksWrites get() = status == OperationStatus.applying || status == OperationStatus.needsAttention
    fun recovered() = if (status == OperationStatus.applying) copy(status = OperationStatus.needsAttention,
        message = "Payday stopped during this allocation. Check YNAB and reconcile here. Nothing will be retried.",
        steps = steps.map { if (it.status == StepStatus.sending) it.copy(status = StepStatus.uncertain) else it }) else this
}
@Serializable data class AppState(val schemaVersion: Int = 1, val selectedPlan: Plan? = null,
    val defaults: Map<String, List<Contribution>> = emptyMap(), val draft: Draft? = null, val history: List<Operation> = emptyList()) {
    val blocked get() = history.any { it.blocksWrites }
    fun synchronized(): AppState = copy(draft = draft?.synchronize(defaults[draft.planID].orEmpty()))
}
object Money {
    const val limit = 1_000_000_000_000L
    fun unit(digits: Int): Long { ensure(digits in 0..3, "Unsupported currency precision."); return longArrayOf(1000, 100, 10, 1)[digits] }
    fun minorEntry(text: String, digits: Int): Long {
        val clean = text.trim()
        ensure(clean.matches(Regex("[0-9]*\\.?[0-9]*")), "Enter digits; the decimal is automatic.")
        val minor = clean.replace(".", "").ifEmpty { "0" }.toLongOrNull()
        ensure(minor != null && minor in 0..limit / unit(digits), "That amount is too large.")
        return minor!! * unit(digits)
    }
    fun parse(text: String, digits: Int): Long {
        unit(digits)
        ensure(text.matches(Regex("[0-9]+" + if (digits > 0) "(\\.[0-9]{0,$digits})?" else "")), "Enter an amount with up to $digits decimal places.")
        val value = try { BigDecimal(text).movePointRight(3).longValueExact() } catch (_: Exception) { throw PaydayException("That amount is too large.") }
        ensure(value in 0..limit, "That amount is too large."); return value
    }
    fun input(amount: Long, digits: Int): String = BigDecimal.valueOf(amount, 3).setScale(digits).toPlainString()
    fun format(amount: Long, plan: Plan?): String {
        val format = NumberFormat.getCurrencyInstance()
        format.currency = Currency.getInstance(plan?.currency ?: "USD")
        format.minimumFractionDigits = plan?.digits ?: 2; format.maximumFractionDigits = plan?.digits ?: 2
        return format.format(BigDecimal.valueOf(amount, 3))
    }
    fun total(values: List<Long>): Long = values.fold(0L) { total, value ->
        ensure(value in 0..limit && total <= limit - value, "Contributions must be positive or zero and within the supported range."); total + value
    }
}
