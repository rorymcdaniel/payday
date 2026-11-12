package app.payday

import kotlinx.coroutines.sync.Mutex
import java.time.Duration
import java.time.Instant
import java.time.LocalDate

interface StateStore {
    val state: AppState
    fun update(change: (AppState) -> AppState)
}
interface BudgetAPI {
    suspend fun plans(): List<Plan>
    suspend fun snapshot(planID: String, month: String): Snapshot
    suspend fun incomes(planID: String): List<Income>
    suspend fun assign(planID: String, month: String, categoryID: String, budgeted: Long): Long
    fun checkWriteCapacity(categoryCount: Int) {}
}
class AllocationEngine(private val store: StateStore, val api: BudgetAPI) {
    private val mutex = Mutex()
    fun recover() { store.update { it.copy(history = it.history.map(Operation::recovered)) } }
    suspend fun review(draft: Draft, plan: Plan): Operation {
        ensure(!mutex.isLocked, "An allocation is already running.")
        validate(draft, plan); validateRemote(draft, plan)
        val snapshot = api.snapshot(plan.id, draft.month)
        ensure(snapshot.month == draft.month, "YNAB returned a different month.")
        ensure(snapshot.readyToAssign >= draft.amount, "There isn’t enough Ready to Assign, including future months. Fund your budget first.")
        val steps = draft.contributions.filter { it.amount > 0 }.map { contribution ->
            val category = snapshot.categories.find { it.id == contribution.categoryID && it.eligible }
                ?: throw PaydayException("${contribution.name} is unavailable. Remove or replace it.")
            val target = category.budgeted + contribution.amount
            ensure(target in -Money.limit..Money.limit, "The resulting assigned amount is too large.")
            Step(contribution, category.budgeted, category.balance, target)
        }
        return Operation(draft.id, draft, plan, Instant.now().toString(), OperationStatus.applying, snapshot.readyToAssign, steps)
    }
    suspend fun apply(reviewed: Operation, progress: () -> Unit = {}) {
        ensure(mutex.tryLock(), "An allocation is already running.")
        try {
            validate(reviewed.draft, reviewed.plan)
            ensure(store.state.draft == reviewed.draft, "The paycheck changed after review. Review it again.")
            ensure(Duration.between(Instant.parse(reviewed.createdAt), Instant.now()).seconds in 0..299, "This review expired. Review the allocation again.")
            validateRemote(reviewed.draft, reviewed.plan)
            val fresh = api.snapshot(reviewed.plan.id, reviewed.draft.month)
            check(fresh, reviewed, 0); api.checkWriteCapacity(reviewed.steps.size)
            store.update { it.copy(history = listOf(reviewed) + it.history, draft = null) }
            progress()
            try {
                reviewed.steps.indices.forEach { index ->
                    val op = operation(reviewed.id)
                    check(if (index == 0) fresh else api.snapshot(op.plan.id, op.draft.month), op, index)
                    mutate(op.id) { it.copy(steps = it.steps.mapIndexed { i, s -> if (i == index) s.copy(status = StepStatus.sending) else s }) }
                    progress()
                    val step = op.steps[index]
                    val assigned = api.assign(op.plan.id, op.draft.month, step.contribution.categoryID, step.targetBudgeted)
                    ensure(assigned == step.targetBudgeted, "YNAB’s response did not match the requested assignment.")
                    mutate(op.id) { it.copy(steps = it.steps.mapIndexed { i, s -> if (i == index) s.copy(status = StepStatus.verified, observation = assigned) else s }) }
                    progress()
                }
                val op = operation(reviewed.id)
                check(api.snapshot(op.plan.id, op.draft.month), op, op.steps.size)
                mutate(op.id) { it.copy(status = OperationStatus.completed, resolvedAt = Instant.now().toString(), message = "Every contribution was confirmed by YNAB and verified in a final read.") }
            } catch (e: Exception) {
                try { mutate(reviewed.id) { it.copy(status = OperationStatus.needsAttention,
                    message = e.message ?: "Allocation interrupted. Check YNAB before continuing.",
                    steps = it.steps.map { s -> if (s.status == StepStatus.sending) s.copy(status = StepStatus.uncertain) else s }) } } catch (_: Exception) { /* Durable applying/sending still blocks further writes. */ }
                throw e
            }
        } finally { mutex.unlock(); progress() }
    }
    suspend fun inspect(id: String) {
        ensure(!mutex.isLocked, "Wait for this allocation to finish.")
        val op = operation(id); val snapshot = api.snapshot(op.plan.id, op.draft.month)
        ensure(snapshot.month == op.draft.month, "YNAB returned a different month.")
        mutate(id) { it.copy(steps = it.steps.map { s -> s.copy(observation = snapshot.categories.find { c -> c.id == s.contribution.categoryID }?.budgeted) }) }
    }
    fun reconcile(id: String, note: String) {
        ensure(!mutex.isLocked && operation(id).blocksWrites && note.trim().length >= 12, "Describe what you checked and corrected in YNAB (at least 12 characters).")
        mutate(id) { it.copy(status = OperationStatus.reconciled, reconciliationNote = note.trim(), resolvedAt = Instant.now().toString()) }
    }
    private fun validate(draft: Draft, plan: Plan) {
        ensure(!store.state.blocked, "An earlier allocation needs attention. Reconcile it in History first.")
        ensure(draft.planID == plan.id && store.state.selectedPlan == plan, "The selected budget changed. Review again.")
        ensure(draft.month == Dates.month(), "This draft targets another month. Start a new paycheck for the current month.")
        ensure(runCatching { LocalDate.parse(draft.date) }.isSuccess && draft.date <= Dates.day() && draft.reference.trim().isNotEmpty(), "Enter a valid paycheck date and reference.")
        ensure(draft.amount > 0 && Money.total(draft.contributions.map { it.amount }) == draft.amount, "Give every dollar a job before reviewing.")
        ensure(draft.contributions.map { it.categoryID }.toSet().size == draft.contributions.size, "A category appears more than once.")
        val unit = Money.unit(plan.digits)
        ensure(draft.amount % unit == 0L && draft.contributions.all { it.amount % unit == 0L }, "Use your budget’s currency precision.")
        ensure(store.state.history.none { it.id.equals(draft.id, true) || it.draft.identity == draft.identity ||
            (it.plan.id == plan.id && draft.incomeID != null && it.draft.incomeID == draft.incomeID) }, "This paycheck already appears in History. It cannot be applied again.")
    }
    private suspend fun validateRemote(draft: Draft, plan: Plan) {
        val live = api.plans().find { it.id == plan.id }
        ensure(live?.currency == plan.currency && live?.digits == plan.digits, "The budget is inaccessible or its currency changed. Refresh your connection.")
        if (draft.incomeID != null) {
            val income = api.incomes(plan.id).find { it.id == draft.incomeID && it.amount == draft.amount && it.date == draft.date }
                ?: throw PaydayException("The linked deposit changed or is unavailable. Choose it again.")
            ensure(store.state.history.none { it.plan.id == plan.id && it.draft.incomeID != null &&
                income.identityKeys.intersect((listOf(it.draft.incomeID) + it.draft.incomeAliases.orEmpty()).toSet()).isNotEmpty() }, "This deposit matches a paycheck already recorded in History.")
        }
    }
    private fun check(snapshot: Snapshot, op: Operation, index: Int) {
        ensure(snapshot.month == op.draft.month, "YNAB returned a different month.")
        ensure(snapshot.readyToAssign >= Money.total(op.steps.drop(index).map { it.contribution.amount }), "Ready to Assign changed or is insufficient. Inspect History.")
        op.steps.forEachIndexed { i, step ->
            val category = snapshot.categories.find { it.id == step.contribution.categoryID && it.eligible }
            ensure(category != null, "A category became unavailable. Assignment stopped.")
            ensure(category!!.budgeted == if (i < index) step.targetBudgeted else step.beforeBudgeted,
                "${step.contribution.name} changed in YNAB since review. Assignment stopped to avoid overwriting that change.")
        }
    }
    private fun operation(id: String) = store.state.history.find { it.id == id } ?: throw PaydayException("Allocation journal missing. No further changes will be sent.")
    private fun mutate(id: String, change: (Operation) -> Operation) { operation(id); store.update { it.copy(history = it.history.map { op -> if (op.id == id) change(op) else op }) } }
}
