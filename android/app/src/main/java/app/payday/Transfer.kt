package app.payday

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import java.time.Instant
import java.time.LocalDate
import java.util.UUID

@Serializable data class Transfer(val format: String = "app.payday.transfer", val version: Int = 1,
    val source: String, val mode: String, val exportedAt: String, val state: AppState)
object Transfers {
    const val maxBytes = 20 * 1024 * 1024
    fun decodeState(text: String): AppState {
        val element = paydayJson.parseToJsonElement(text).jsonObject
        ensure(listOf("schemaVersion", "defaults", "history").all { element.containsKey(it) }, "The saved data document is incomplete.")
        return paydayJson.decodeFromJsonElement<AppState>(element).also { validate(it) }
    }
    fun decode(bytes: ByteArray, practice: Boolean): Transfer {
        ensure(bytes.size <= maxBytes, "This transfer is too large (maximum 20 MB).")
        try {
            val element = paydayJson.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject
            ensure(listOf("format", "version", "source", "mode", "exportedAt", "state").all { element.containsKey(it) }, "Choose a complete Payday transfer, not a history-only export.")
            val state = element.getValue("state").jsonObject
            ensure(listOf("schemaVersion", "defaults", "history").all { state.containsKey(it) }, "This transfer is incomplete.")
            val transfer = paydayJson.decodeFromJsonElement<Transfer>(element)
            ensure(transfer.format == "app.payday.transfer" && transfer.version == 1, "This transfer version is unsupported. Update Payday.")
            ensure(transfer.mode == if (practice) "practice" else "real", "Practice and real data stay separate. Switch modes before importing this file.")
            Instant.parse(transfer.exportedAt)
            validate(transfer.state)
            return transfer
        } catch (e: PaydayException) { throw e }
        catch (_: Exception) { throw PaydayException("This is not a valid Payday transfer. Export again using Connection → Export for Android on your Mac.") }
    }
    fun encode(state: AppState, practice: Boolean): ByteArray {
        ensure(state.history.none { it.status == OperationStatus.applying }, "Wait for the allocation to finish before exporting.")
        validate(state)
        return paydayJson.encodeToString(Transfer(source = "android", mode = if (practice) "practice" else "real", exportedAt = Instant.now().toString(), state = state)).toByteArray()
    }
    fun merge(local: AppState, transfer: Transfer): AppState {
        ensure(!local.blocked, "Reconcile this phone’s interrupted allocation before importing.")
        validate(transfer.state)
        val imported = transfer.state
        val merged = local.history.toMutableList()
        for (raw in imported.history) {
            val incoming = raw.recovered()
            val existing = merged.find { it.id.equals(incoming.id, ignoreCase = true) }
            if (existing != null) {
                // A stale file must never roll a local resolution or audit observation backward.
                ensure(existing.copy(status = incoming.status, steps = existing.steps.map { step ->
                    val other = incoming.steps.find { it.contribution.categoryID == step.contribution.categoryID }
                    step.copy(status = other?.status ?: step.status, observation = other?.observation)
                }, message = incoming.message, reconciliationNote = incoming.reconciliationNote, resolvedAt = incoming.resolvedAt) == incoming,
                    "An allocation conflicts with this phone’s history. Import stopped; no data was replaced.")
                ensure(!incoming.blocksWrites || existing.blocksWrites || existing.status == OperationStatus.reconciled,
                    "This transfer reports an interruption that conflicts with a completed allocation. Check both histories first.")
            } else {
                ensure(merged.none { claimsOverlap(it, incoming) }, "Two records claim the same paycheck. Import stopped; keep both files and reconcile the histories.")
                merged.add(incoming)
            }
        }
        val result = local.copy(selectedPlan = imported.selectedPlan ?: local.selectedPlan,
            defaults = local.defaults + imported.defaults, draft = imported.draft,
            history = merged.sortedByDescending { Instant.parse(it.createdAt) })
        validate(result)
        return result
    }
    fun claimsOverlap(a: Operation, b: Operation): Boolean = a.draft.identity == b.draft.identity ||
        (a.plan.id == b.plan.id && a.draft.incomeID != null && b.draft.incomeID != null &&
            (listOf(a.draft.incomeID) + a.draft.incomeAliases.orEmpty()).intersect((listOf(b.draft.incomeID) + b.draft.incomeAliases.orEmpty()).toSet()).isNotEmpty())

    fun validate(state: AppState) {
        ensure(state.schemaVersion == 1, "Unsupported saved-data version. Update Payday.")
        fun amount(value: Long, signed: Boolean = false) = ensure(value in (if (signed) -Money.limit else 0)..Money.limit, "The file contains an unsupported amount.")
        fun rows(rows: List<Contribution>) {
            ensure(rows.map { it.categoryID }.toSet().size == rows.size, "The file contains duplicate categories.")
            rows.forEach { ensure(it.categoryID.isNotBlank(), "A category identifier is missing."); amount(it.amount); amount(it.normal) }
            Money.total(rows.map { it.amount })
        }
        fun plan(plan: Plan) { ensure(plan.id.isNotBlank() && plan.digits in 0..3, "Invalid budget in transfer."); java.util.Currency.getInstance(plan.currency) }
        fun draft(d: Draft) {
            UUID.fromString(d.id); ensure(d.planID.isNotBlank(), "Missing budget identifier.")
            ensure(LocalDate.parse(d.month).dayOfMonth == 1, "Invalid budget month."); LocalDate.parse(d.date)
            amount(d.amount); rows(d.contributions); d.normalContributions?.let { rows(it) }
        }
        state.selectedPlan?.let { plan(it) }
        state.defaults.forEach { (id, entries) -> ensure(id.isNotBlank(), "Missing budget identifier."); rows(entries) }
        state.draft?.let { draft(it); ensure(it.planID == state.selectedPlan?.id, "Draft and selected budget do not match.") }
        state.selectedPlan?.let { selected ->
            val unit = Money.unit(selected.digits)
            val rows = state.defaults[selected.id].orEmpty() + state.draft?.contributions.orEmpty() + state.draft?.normalContributions.orEmpty()
            ensure(rows.all { it.amount % unit == 0L && it.normal % unit == 0L } && (state.draft?.amount ?: 0L) % unit == 0L,
                "Saved amounts do not match this budget’s currency precision.")
        }
        ensure(state.history.map { it.id.lowercase() }.toSet().size == state.history.size, "The file contains duplicate history identifiers.")
        state.history.forEach { op ->
            draft(op.draft); plan(op.plan); Instant.parse(op.createdAt); op.resolvedAt?.let { Instant.parse(it) }
            ensure(op.id.equals(op.draft.id, true) && op.plan.id == op.draft.planID, "History identity does not match its paycheck.")
            amount(op.readyBefore, true)
            ensure(op.draft.amount > 0 && Money.total(op.draft.contributions.map { it.amount }) == op.draft.amount, "History contains an unbalanced paycheck.")
            ensure(op.steps.map { it.contribution } == op.draft.contributions.filter { it.amount > 0 }, "History is missing allocation steps.")
            op.steps.forEach { step ->
                amount(step.beforeBudgeted, true); amount(step.beforeBalance, true); amount(step.targetBudgeted, true); step.observation?.let { amount(it, true) }
                ensure(step.targetBudgeted == step.beforeBudgeted + step.contribution.amount, "A history target does not match its contribution.")
            }
            ensure(op.status != OperationStatus.completed || op.steps.all { it.status == StepStatus.verified }, "Completed history contains unconfirmed steps.")
            ensure(op.status != OperationStatus.reconciled || op.reconciliationNote.orEmpty().trim().length >= 12, "A reconciled allocation is missing its note.")
        }
        state.history.forEachIndexed { i, op -> ensure(state.history.take(i).none { claimsOverlap(it, op) }, "History contains duplicate paycheck claims.") }
    }
}
