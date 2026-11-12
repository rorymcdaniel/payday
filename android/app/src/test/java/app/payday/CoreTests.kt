package app.payday

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.encodeToString
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

private class MemoryStore(initial: AppState) : StateStore {
    override var state = initial
    var saves = 0
    var failAt: Int? = null
    override fun update(change: (AppState) -> AppState) {
        saves++; if (saves == failAt) throw PaydayException("Disk full")
        state = change(state)
    }
}
private class FakeAPI : BudgetAPI {
    var plan = Plan("plan", "Example budget")
    var value = Snapshot(Dates.month(), 500_000, listOf(Category("food", "Food", "Everyday", 50_000, 20_000, true), Category("car", "Car", "Future", 20_000, 30_000, true)))
    var writes = 0; var reads = 0; var lostResponse = false; var badResponse = false; var capacity = true
    var beforeWrite: (() -> Unit)? = null
    var beforeSnapshot: ((Int) -> Unit)? = null
    var beforePlans: (suspend () -> Unit)? = null
    var deposits = emptyList<Income>()
    override suspend fun plans(): List<Plan> { beforePlans?.invoke(); return listOf(plan) }
    override suspend fun snapshot(planID: String, month: String): Snapshot { reads++; beforeSnapshot?.invoke(reads); return value }
    override suspend fun incomes(planID: String) = deposits
    override fun checkWriteCapacity(categoryCount: Int) { ensure(capacity, "No capacity") }
    override suspend fun assign(planID: String, month: String, categoryID: String, budgeted: Long): Long {
        beforeWrite?.invoke(); writes++
        val category = value.categories.first { it.id == categoryID }; val diff = budgeted - category.budgeted
        value = value.copy(readyToAssign = value.readyToAssign - diff, categories = value.categories.map { if (it.id == categoryID) it.copy(budgeted = budgeted, balance = it.balance + diff) else it })
        if (lostResponse) throw PaydayException("Connection lost")
        return if (badResponse) budgeted + 1 else budgeted
    }
}
class CoreTests {
    private val rows = listOf(Contribution("food", "Food", 100_000, 100_000), Contribution("car", "Car", 50_000, 50_000))
    private fun initial(): AppState = AppState(selectedPlan = Plan("plan", "Example budget"), defaults = mapOf("plan" to rows), draft = Draft(planID = "plan", amount = 150_000, contributions = rows, normalContributions = rows))
    private fun fixture(): Transfer = Transfers.decode(javaClass.getResourceAsStream("/mac-transfer-v1.json")!!.readBytes(), false)
    private suspend fun review(store: StateStore, engine: AllocationEngine) = engine.review(store.state.draft!!, store.state.selectedPlan!!)
    private suspend fun failure(action: suspend () -> Unit) { try { action(); fail("Expected failure") } catch (_: PaydayException) { } }

    @Test fun centsEntryAndPrecisionAreExact() {
        assertEquals(10L, Money.minorEntry("1", 2)); assertEquals(100L, Money.minorEntry("10", 2)); assertEquals(1000L, Money.minorEntry("100", 2))
        assertEquals(4_123_720L, Money.parse("4123.72", 2)); assertEquals(123L, Money.minorEntry("123", 3)); assertEquals(123_000L, Money.minorEntry("123", 0))
        assertEquals("0.01", Money.input(10, 2)); assertEquals(0L, Money.minorEntry("", 2))
        listOf("-1", "NaN", "1,000", "1.2.3", "999999999999999999999").forEach { assertTrue(runCatching { Money.minorEntry(it, 2) }.isFailure) }
        assertTrue(runCatching { Money.total(listOf(Money.limit, 1)) }.isFailure)
        assertTrue(runCatching { Money.total(listOf(-1)) }.isFailure)
        assertTrue(runCatching { Money.parse("1.234", 2) }.isFailure)
    }
    @Test fun defaultsPreserveOverridesOmissionsAndOneOffs() {
        val d = initial().draft!!.copy(contributions = listOf(rows[0].copy(amount = 120_000), Contribution("gift", "Gift", 30_000)))
        val next = d.synchronize(listOf(rows[1].copy(amount = 75_000), rows[0].copy(amount = 110_000), Contribution("savings", "Savings", 20_000)))
        assertEquals(listOf("food", "savings", "gift"), next.contributions.map { it.categoryID })
        assertEquals(listOf(120_000L, 20_000L, 30_000L), next.contributions.map { it.amount })
        assertEquals(110_000L, next.contributions[0].normal)
        assertEquals(listOf("food"), initial().draft!!.copy(contributions = listOf(rows[0].copy(amount = 120_000), rows[1])).synchronize(emptyList()).contributions.map { it.categoryID })
    }
    @Test fun untouchedDefaultsTrackAmountsAndOrder() {
        val d = initial().draft!!.synchronize(listOf(rows[1], rows[0].copy(amount = 110_000)))
        assertEquals(listOf("car", "food"), d.contributions.map { it.categoryID }); assertEquals(110_000L, d.contributions.last().amount)
    }
    @Test fun readyToAssignPreservesIdentityOnRepeatAndClearsDeposit() {
        val d = initial().draft!!.copy(incomeID = "deposit", incomeAliases = listOf("alias"))
        val live = FakeAPI().value
        val first = d.useReady(live, emptyList(), 2)
        assertNull(first.incomeID); assertNull(first.incomeAliases); assertEquals(500_000L, first.amount)
        assertEquals(first.id, first.useReady(live.copy(readyToAssign = 100_000), emptyList(), 2).id)
        assertEquals(first.reference, first.useReady(live, emptyList(), 2).reference)
    }
    @Test fun macFixtureRoundTripsAndRepeatedImportKeepsHistory() {
        val transfer = fixture(); val first = Transfers.merge(AppState(), transfer)
        assertEquals("Synthetic transfer budget", first.selectedPlan!!.name); assertEquals(123_450L, first.defaults.values.first()[0].amount)
        assertEquals(173_450L, first.history[0].steps[0].targetBudgeted)
        assertEquals(listOf("import:account-1:example"), first.history[0].draft.incomeAliases)
        assertEquals(first, Transfers.decode(Transfers.encode(first, false), false).state)
        assertEquals(first, Transfers.merge(first, transfer))
    }
    @Test fun importRetainsLocalHistoryAndRejectsConflicts() {
        val transfer = fixture(); val localOp = transfer.state.history.first().let { it.copy(id = "33333333-3333-4333-8333-333333333333", draft = it.draft.copy(id = "33333333-3333-4333-8333-333333333333", reference = "Other paycheck", incomeID = null, incomeAliases = null)) }
        val local = transfer.state.copy(history = listOf(localOp))
        assertEquals(2, Transfers.merge(local, transfer).history.size)
        val conflict = transfer.state.copy(history = transfer.state.history.map { it.copy(readyBefore = 600_000) })
        assertTrue(runCatching { Transfers.merge(conflict, transfer) }.isFailure)
        val aliasDuplicate = local.copy(history = listOf(localOp.copy(draft = localOp.draft.copy(incomeID = "new-id", incomeAliases = listOf("deposit-1")))))
        assertTrue(runCatching { Transfers.merge(aliasDuplicate, transfer) }.isFailure)
    }
    @Test fun importFailsClosedOnMalformedVersionsModesAndAmounts() {
        val bytes = javaClass.getResourceAsStream("/mac-transfer-v1.json")!!.readBytes()
        assertTrue(runCatching { Transfers.decode(bytes, true) }.isFailure)
        listOf(String(bytes).replace("\"version\": 1", "\"version\": 2"), "[]", "{}", String(bytes).replace("173450", "173451"), String(bytes).replace("123450", "-123450")).forEach {
            assertTrue(runCatching { Transfers.decode(it.toByteArray(), false) }.isFailure)
        }
        assertTrue(runCatching { Transfers.decode(ByteArray(Transfers.maxBytes + 1), false) }.isFailure)
        assertTrue(runCatching { Transfers.decodeState("{}") }.isFailure)
        assertEquals(fixture().state, Transfers.decodeState(paydayJson.encodeToString(fixture().state)))
    }
    @Test fun interruptedImportBlocksAndReimportCannotUndoReconciliation() {
        val t = fixture(); val interrupted = t.copy(state = t.state.copy(history = t.state.history.map { it.copy(status = OperationStatus.applying, steps = it.steps.map { s -> s.copy(status = StepStatus.sending) }) }))
        val imported = Transfers.merge(AppState(), interrupted)
        assertTrue(imported.blocked); assertEquals(StepStatus.uncertain, imported.history[0].steps[0].status)
        assertTrue(runCatching { Transfers.merge(imported, t) }.isFailure)
        val local = imported.copy(history = imported.history.map { it.copy(status = OperationStatus.reconciled, reconciliationNote = "Checked in YNAB and corrected all contributions.") })
        assertEquals(OperationStatus.reconciled, Transfers.merge(local, interrupted).history[0].status)
    }
    @Test fun appliesAdditivelyOnlyAfterDurableClaimAndIntent() = runTest {
        val store = MemoryStore(initial()); val api = FakeAPI(); val engine = AllocationEngine(store, api)
        api.beforeWrite = { assertNull(store.state.draft); assertEquals(OperationStatus.applying, store.state.history.first().status); assertTrue(store.state.history.first().steps.any { it.status == StepStatus.sending }) }
        val reviewed = review(store, engine); assertEquals(0, api.writes)
        engine.apply(reviewed)
        assertEquals(2, api.writes); assertEquals(150_000L, api.value.categories[0].budgeted); assertEquals(120_000L, api.value.categories[0].balance)
        assertEquals(OperationStatus.completed, store.state.history.first().status)
        assertTrue(store.state.history.first().steps.all { it.status == StepStatus.verified })
    }
    @Test fun unbalancedHiddenPrecisionOldMonthAndInsufficientFundsNeverWrite() = runTest {
        val cases = listOf(initial().copy(draft = initial().draft!!.copy(amount = 200_000)), initial().copy(draft = initial().draft!!.copy(month = "2020-01-01")), initial().copy(draft = initial().draft!!.copy(amount = 150_001, contributions = listOf(rows[0].copy(amount = 100_001), rows[1]))), initial().copy(draft = initial().draft!!.copy(contributions = listOf(rows[0], rows[0].copy(amount = 50_000)))))
        cases.forEach { state -> val store = MemoryStore(state); val api = FakeAPI(); failure { review(store, AllocationEngine(store, api)) }; assertEquals(0, api.writes) }
        val store = MemoryStore(initial()); val api = FakeAPI(); api.value = api.value.copy(readyToAssign = 100_000)
        failure { review(store, AllocationEngine(store, api)) }
        api.value = FakeAPI().value.copy(categories = FakeAPI().value.categories.map { it.copy(eligible = false) })
        failure { review(store, AllocationEngine(store, api)) }; assertEquals(0, api.writes)
    }
    @Test fun staleReviewChangedDraftCurrencyBaselineAndCapacityBlockBeforeClaim() = runTest {
        for (scenario in 0..4) {
            val store = MemoryStore(initial()); val api = FakeAPI(); val engine = AllocationEngine(store, api); var op = review(store, engine)
            when (scenario) {
                0 -> op = op.copy(createdAt = Instant.now().minusSeconds(301).toString())
                1 -> store.update { it.copy(draft = it.draft!!.copy(reference = "Changed")) }
                2 -> api.plan = api.plan.copy(currency = "EUR")
                3 -> api.value = api.value.copy(categories = api.value.categories.map { it.copy(budgeted = it.budgeted + 1) })
                4 -> api.capacity = false
            }
            failure { engine.apply(op) }; assertEquals(0, api.writes); assertTrue(store.state.history.isEmpty())
        }
    }
    @Test fun lostResponseIsUncertainNeverRetriedAndBlocksNewPaychecks() = runTest {
        val store = MemoryStore(initial()); val api = FakeAPI(); val engine = AllocationEngine(store, api)
        val op = review(store, engine); api.lostResponse = true
        failure { engine.apply(op) }; assertEquals(1, api.writes)
        assertEquals(StepStatus.uncertain, store.state.history[0].steps[0].status)
        assertEquals(StepStatus.pending, store.state.history[0].steps[1].status)
        assertTrue(store.state.blocked); failure { engine.apply(op) }; assertEquals(1, api.writes)
        engine.inspect(op.id); assertEquals(150_000L, store.state.history[0].steps[0].observation)
        engine.reconcile(op.id, "Checked YNAB and completed the missing car contribution.")
        assertFalse(store.state.blocked); assertEquals(StepStatus.uncertain, store.state.history[0].steps[0].status)
        store.update { it.copy(draft = op.draft) }; failure { review(store, engine) }; assertEquals(1, api.writes)
    }
    @Test fun persistenceFailureBeforeClaimSendsNothing() = runTest {
        val store = MemoryStore(initial()); val api = FakeAPI(); val engine = AllocationEngine(store, api)
        val op = review(store, engine); store.failAt = 1; failure { engine.apply(op) }; assertEquals(0, api.writes); assertTrue(store.state.history.isEmpty())
    }
    @Test fun persistenceFailureBeforeSendingLeavesPendingAndBlocks() = runTest {
        val store = MemoryStore(initial()); val api = FakeAPI(); val engine = AllocationEngine(store, api)
        val op = review(store, engine); store.failAt = 2; failure { engine.apply(op) }; assertEquals(0, api.writes); assertTrue(store.state.blocked)
    }
    @Test fun persistenceFailureAfterWritePreservesUncertainty() = runTest {
        val store = MemoryStore(initial()); val api = FakeAPI(); val engine = AllocationEngine(store, api)
        val op = review(store, engine); store.failAt = 3; failure { engine.apply(op) }; assertEquals(1, api.writes); assertEquals(StepStatus.uncertain, store.state.history[0].steps[0].status)
    }
    @Test fun detectsConcurrentEditBetweenStepsAndFinalMismatch() = runTest {
        for (read in listOf(3, 4)) {
            val store = MemoryStore(initial()); val api = FakeAPI(); val engine = AllocationEngine(store, api); val op = review(store, engine)
            api.beforeSnapshot = { count -> if (count == read) api.value = api.value.copy(categories = api.value.categories.map { it.copy(budgeted = it.budgeted + 10) }) }
            failure { engine.apply(op) }; assertEquals(if (read == 3) 1 else 2, api.writes); assertTrue(store.state.blocked)
        }
    }
    @Test fun incorrectPatchResponseStaysUncertain() = runTest {
        val store = MemoryStore(initial()); val api = FakeAPI(); val engine = AllocationEngine(store, api); val op = review(store, engine)
        api.badResponse = true; failure { engine.apply(op) }; assertEquals(StepStatus.uncertain, store.state.history[0].steps[0].status)
    }
    @Test fun relaunchRecoversInFlightWithoutNetworkAndPreservesClaim() = runTest {
        val store = MemoryStore(initial()); val api = FakeAPI(); val engine = AllocationEngine(store, api); val op = review(store, engine)
        store.update { it.copy(history = listOf(op.copy(steps = op.steps.mapIndexed { i, s -> if (i == 0) s.copy(status = StepStatus.sending) else s })), draft = null) }
        engine.recover(); assertTrue(store.state.blocked); assertEquals(StepStatus.uncertain, store.state.history[0].steps[0].status); assertEquals(0, api.writes)
    }
    @Test fun concurrentConfirmCannotSendTwice() = runTest {
        val store = MemoryStore(initial()); val api = FakeAPI(); val engine = AllocationEngine(store, api); val op = review(store, engine)
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        api.beforePlans = { entered.complete(Unit); release.await() }
        val first = async { engine.apply(op) }; entered.await()
        failure { engine.apply(op) }; release.complete(Unit); first.await(); assertEquals(2, api.writes)
    }
    @Test fun linkedDepositAliasesAndChangesBlockReuse() = runTest {
        val prior = fixture().state.history[0]
        val draft = initial().draft!!.copy(incomeID = "new-id", date = Dates.day())
        val store = MemoryStore(initial().copy(draft = draft, history = listOf(prior.copy(plan = initial().selectedPlan!!, draft = prior.draft.copy(planID = "plan")))))
        val api = FakeAPI(); api.deposits = listOf(Income("new-id", Dates.day(), "Employer", 150_000, listOf("deposit-1")))
        failure { review(store, AllocationEngine(store, api)) }; assertEquals(0, api.writes)
        api.deposits = listOf(Income("new-id", Dates.day(), "Employer", 150_001)); failure { review(store, AllocationEngine(store, api)) }
    }
}
