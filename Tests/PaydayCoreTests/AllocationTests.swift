import XCTest
@testable import PaydayCore

final class FakeAPI: BudgetAPI {
    var value = Snapshot(month: Dates.month(), readyToAssign: 1_000_000, categories: [
        BudgetCategory(id: "food", name: "Groceries", group: "Everyday", budgeted: 500_000, balance: 35_000),
        BudgetCategory(id: "car", name: "Car repair", group: "Later", budgeted: 0, balance: 2_000_000)
    ])
    var writes: [(String, Int64)] = []
    var reads = 0
    var onRead: ((FakeAPI) throws -> Void)?
    var onWrite: ((FakeAPI) throws -> Void)?
    var pauseRead: (() async -> Void)?
    var deposits: [Income] = []
    func plans() async throws -> [Plan] { [Plan(id: "budget", name: "Budget")] }
    func snapshot(planID: String, month: String) async throws -> Snapshot {
        await pauseRead?()
        reads += 1; try onRead?(self); return value
    }
    func incomes(planID: String) async throws -> [Income] { deposits }
    func assign(planID: String, month: String, categoryID: String, budgeted: Int64) async throws -> Int64 {
        writes.append((categoryID, budgeted))
        let index = value.categories.firstIndex { $0.id == categoryID }!
        let difference = budgeted - value.categories[index].budgeted
        value.categories[index].budgeted = budgeted
        value.categories[index].balance += difference
        value.readyToAssign -= difference
        try onWrite?(self)
        return budgeted
    }
}

@MainActor final class AllocationTests: XCTestCase {
    var directory: URL!
    var store: Store!
    var api: FakeAPI!
    var engine: AllocationEngine!
    let plan = Plan(id: "budget", name: "Budget")

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("payday-tests-\(UUID())")
        store = try Store(directory: directory); api = FakeAPI(); engine = AllocationEngine(store: store, api: api)
        let rows = [Contribution(categoryID: "food", name: "Groceries", amount: 400_000, normal: 400_000),
                    Contribution(categoryID: "car", name: "Car repair", amount: 75_000, normal: 75_000)]
        var draft = Draft(planID: plan.id, month: Dates.month(), date: Dates.day(), contributions: rows)
        draft.amount = 475_000
        try store.update { $0.selectedPlan = plan; $0.defaults[plan.id] = rows; $0.draft = draft }
    }
    override func tearDown() async throws {
        engine = nil; store = nil; api = nil
        try FileManager.default.removeItem(at: directory)
    }
    private func review() async throws -> AllocationOperation { try await engine.review(store.state.draft!, plan: plan) }
    private func fails(_ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected failure", file: file, line: line) } catch {}
    }

    func testContributionsIncreaseAssignedAndPreserveExistingAvailable() async throws {
        let originalDefaults = store.state.defaults
        let reviewed = try await review()
        XCTAssertEqual(reviewed.steps.map(\.targetBudgeted), [900_000, 75_000])
        try await engine.apply(reviewed)
        XCTAssertEqual(api.value.categories.map(\.balance), [435_000, 2_075_000])
        XCTAssertEqual(api.value.readyToAssign, 525_000)
        XCTAssertEqual(store.state.history.first?.status, .completed)
        XCTAssertEqual(store.state.history.first?.steps.map(\.status), [.verified, .verified])
        XCTAssertEqual(store.state.defaults, originalDefaults)
        XCTAssertNil(store.state.draft)
    }
    func testUnbalancedAndNegativeAllocationsNeverWrite() async throws {
        try store.update { $0.draft?.amount = 475_010 }
        await fails { _ = try await self.review() }
        try store.update { $0.draft?.contributions[0].amount = -1 }
        await fails { _ = try await self.review() }
        XCTAssertTrue(api.writes.isEmpty)
    }
    func testInsufficientReadyToAssignNeverWrites() async throws {
        api.value.readyToAssign = 474_990
        await fails { _ = try await self.review() }
        XCTAssertTrue(api.writes.isEmpty)
    }
    func testReviewDoesNotWriteAnything() async throws {
        _ = try await review()
        XCTAssertTrue(api.writes.isEmpty); XCTAssertTrue(store.state.history.isEmpty)
    }
    func testHiddenAndMissingCategoriesBlockReview() async throws {
        api.value.categories[0].eligible = false
        await fails { _ = try await self.review() }
        api.value.categories.removeFirst()
        await fails { _ = try await self.review() }
    }
    func testDuplicateCategoryCannotApply() async throws {
        try store.update { $0.draft?.contributions[1].categoryID = "food" }
        await fails { _ = try await self.review() }
    }
    func testMonthRolloverBlocksStaleDraft() async throws {
        try store.update { $0.draft?.month = "2000-01-01" }
        await fails { _ = try await self.review() }
    }
    func testSubcentContributionRejectedForTwoDecimalCurrency() async throws {
        try store.update { $0.draft?.contributions[0].amount += 1; $0.draft?.amount += 1 }
        await fails { _ = try await self.review() }
    }
    func testChangedDraftAfterReviewCannotApply() async throws {
        let reviewed = try await review()
        try store.update { $0.draft?.reference = "Changed" }
        await fails { try await self.engine.apply(reviewed) }
        XCTAssertTrue(api.writes.isEmpty)
    }
    func testExternalAssignmentAfterReviewCannotBeOverwritten() async throws {
        let reviewed = try await review()
        api.value.categories[0].budgeted += 10_000
        await fails { try await self.engine.apply(reviewed) }
        XCTAssertTrue(api.writes.isEmpty); XCTAssertTrue(store.state.history.isEmpty)
    }
    func testReadyToAssignChangeAfterReviewBlocksBeforeClaim() async throws {
        let reviewed = try await review(); api.value.readyToAssign = 0
        await fails { try await self.engine.apply(reviewed) }
        XCTAssertTrue(api.writes.isEmpty); XCTAssertTrue(store.state.history.isEmpty)
    }
    func testRepeatedConfirmationCannotApplyTwice() async throws {
        let reviewed = try await review()
        try await engine.apply(reviewed)
        await fails { try await self.engine.apply(reviewed) }
        XCTAssertEqual(api.writes.count, 2)
    }
    func testNewUUIDCannotReuseManualPaycheckIdentity() async throws {
        let reviewed = try await review(); try await engine.apply(reviewed)
        var duplicate = reviewed.draft; duplicate.id = UUID(); duplicate.reference = "  PAYCHECK  "
        try store.update { $0.draft = duplicate }
        await fails { _ = try await self.review() }
        XCTAssertEqual(api.writes.count, 2)
    }
    func testLinkedDepositCannotBeRenamedToBypassDuplicateProtection() async throws {
        api.deposits = [Income(id: "deposit", date: Dates.day(), name: "Employer", amount: 475_000)]
        try store.update { $0.draft?.incomeID = "deposit" }
        let reviewed = try await review(); try await engine.apply(reviewed)
        var duplicate = reviewed.draft; duplicate.id = UUID(); duplicate.reference = "Different"
        try store.update { $0.draft = duplicate }
        await fails { _ = try await self.review() }
    }
    func testDepositChangedBetweenReviewAndConfirmBlocks() async throws {
        api.deposits = [Income(id: "deposit", date: Dates.day(), name: "Employer", amount: 475_000)]
        try store.update { $0.draft?.incomeID = "deposit" }
        let reviewed = try await review(); api.deposits = []
        await fails { try await self.engine.apply(reviewed) }
        XCTAssertTrue(api.writes.isEmpty)
    }
    func testServerAppliesButResponseLostIsUncertainAndNeverRetried() async throws {
        let reviewed = try await review()
        api.onWrite = { _ in throw AppError("Connection lost after server commit") }
        await fails { try await self.engine.apply(reviewed) }
        XCTAssertEqual(api.value.categories[0].budgeted, 900_000)
        XCTAssertEqual(store.state.history.first?.steps.map(\.status), [.uncertain, .pending])
        XCTAssertEqual(store.state.history.first?.status, .needsAttention)
        await fails { try await self.engine.apply(reviewed) }
        try await engine.inspect(reviewed.id)
        XCTAssertEqual(store.state.history.first?.steps.first?.observation, 900_000)
        XCTAssertEqual(store.state.history.first?.status, .needsAttention)
        XCTAssertEqual(api.writes.count, 1)
    }
    func testSecondWriteFailurePreservesConfirmedFirstStep() async throws {
        let reviewed = try await review()
        api.onWrite = { if $0.writes.count == 2 { throw AppError("Timeout") } }
        await fails { try await self.engine.apply(reviewed) }
        XCTAssertEqual(store.state.history.first?.steps.map(\.status), [.verified, .uncertain])
        XCTAssertEqual(store.state.history.first?.status, .needsAttention)
    }
    func testMidOperationFundsChangeLeavesRemainingUnattempted() async throws {
        let reviewed = try await review()
        api.onWrite = { $0.value.readyToAssign = 0 }
        await fails { try await self.engine.apply(reviewed) }
        XCTAssertEqual(api.writes.count, 1)
        XCTAssertEqual(store.state.history.first?.steps.map(\.status), [.verified, .pending])
    }
    func testMidOperationExternalEditStopsBeforeNextWrite() async throws {
        let reviewed = try await review()
        api.onWrite = { $0.value.categories[1].budgeted = 100 }
        await fails { try await self.engine.apply(reviewed) }
        XCTAssertEqual(api.writes.count, 1)
    }
    func testFinalReadFailureNeverReportsCompleted() async throws {
        let reviewed = try await review()
        api.onRead = { if $0.writes.count == 2 { throw AppError("Offline") } }
        await fails { try await self.engine.apply(reviewed) }
        XCTAssertEqual(store.state.history.first?.steps.map(\.status), [.verified, .verified])
        XCTAssertEqual(store.state.history.first?.status, .needsAttention)
    }
    func testFinalReadConflictingAmountNeverReportsCompleted() async throws {
        let reviewed = try await review()
        api.onRead = { if $0.writes.count == 2 { $0.value.categories[0].budgeted += 1 } }
        await fails { try await self.engine.apply(reviewed) }
        XCTAssertEqual(store.state.history.first?.status, .needsAttention)
    }
    func testIntentIsDurableBeforeEachWrite() async throws {
        let reviewed = try await review()
        api.onWrite = { api in
            let operation = self.store.state.history.first!
            XCTAssertEqual(operation.steps[api.writes.count - 1].status, .sending)
            XCTAssertNil(self.store.state.draft)
        }
        try await engine.apply(reviewed)
    }
    func testCrashRecoveryDoesNotReplaySendingStep() async throws {
        var reviewed = try await review(); reviewed.steps[0].status = .sending
        try store.update { $0.history = [reviewed]; $0.draft = nil }
        engine = nil; store = nil
        store = try Store(directory: directory); engine = AllocationEngine(store: store, api: api)
        try engine.recoverInterruptedOperations()
        XCTAssertEqual(store.state.history.first?.status, .needsAttention)
        XCTAssertEqual(store.state.history.first?.steps.map(\.status), [.uncertain, .pending])
        XCTAssertTrue(api.writes.isEmpty)
    }
    func testManualReconciliationKeepsClaimAndUncertainty() async throws {
        let reviewed = try await review()
        api.onWrite = { _ in throw AppError("Unknown") }
        await fails { try await self.engine.apply(reviewed) }
        XCTAssertThrowsError(try engine.reconcile(reviewed.id, note: "ok"))
        try engine.reconcile(reviewed.id, note: "Checked all assignments and completed the remaining contribution in YNAB.")
        XCTAssertEqual(store.state.history.first?.status, .reconciled)
        XCTAssertEqual(store.state.history.first?.steps.first?.status, .uncertain)
        try store.update { $0.draft = reviewed.draft }
        await fails { _ = try await self.review() }
    }
    func testHistoryAndDefaultsSurviveRelaunch() async throws {
        let reviewed = try await review(); try await engine.apply(reviewed)
        let saved = store.state
        engine = nil; store = nil; store = try Store(directory: directory)
        XCTAssertEqual(saved, store.state)
    }
    func testSecondProcessLockIsExclusive() throws { XCTAssertThrowsError(try Store(directory: directory)) }
    func testFailedStateMutationDoesNotChangeMemoryOrDisk() throws {
        let old = store.state
        XCTAssertThrowsError(try store.update { $0.draft = nil; throw AppError("aborted") })
        XCTAssertEqual(store.state, old)
    }
    func testConcurrentConfirmationWhileNetworkSuspendedIsRejected() async throws {
        let reviewed = try await review()
        var continuation: CheckedContinuation<Void, Never>?
        api.pauseRead = { await withCheckedContinuation { continuation = $0 } }
        let first = Task { try await self.engine.apply(reviewed) }
        while continuation == nil { await Task.yield() }
        await fails { try await self.engine.apply(reviewed) }
        api.pauseRead = nil; continuation?.resume()
        try await first.value
        XCTAssertEqual(api.writes.count, 2)
        XCTAssertEqual(store.state.history.count, 1)
    }
    func testLocalCommitFailureBeforeClaimPreventsEveryRemoteWrite() async throws {
        let reviewed = try await review()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        await fails { try await self.engine.apply(reviewed) }
        XCTAssertTrue(api.writes.isEmpty)
        XCTAssertTrue(store.state.history.isEmpty)
        XCTAssertNotNil(store.state.draft)
    }
    func testPersistenceFailureAfterRemoteWriteLeavesDurableSendingIntent() async throws {
        let reviewed = try await review()
        api.onWrite = { _ in try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: self.directory.path) }
        await fails { try await self.engine.apply(reviewed) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertEqual(api.writes.count, 1)
        XCTAssertEqual(store.state.history.first?.steps.first?.status, .sending)
        XCTAssertTrue(store.state.history.first!.blocksWrites)
        engine = nil; store = nil; store = try Store(directory: directory)
        engine = AllocationEngine(store: store, api: api)
        try engine.recoverInterruptedOperations()
        XCTAssertEqual(store.state.history.first?.steps.first?.status, .uncertain)
    }
    func testMatchedDepositAliasCannotBypassIdentity() async throws {
        api.deposits = [Income(id: "original", date: Dates.day(), name: "Employer", amount: 475_000)]
        try store.update { $0.draft?.incomeID = "original" }
        let reviewed = try await review(); try await engine.apply(reviewed)
        var next = reviewed.draft; next.id = UUID(); next.reference = "Renamed"; next.incomeID = "matched"
        try store.update { $0.draft = next }
        api.deposits = [Income(id: "matched", date: Dates.day(), name: "Employer", amount: 475_000, aliases: ["original"])]
        await fails { _ = try await self.review() }
        XCTAssertEqual(api.writes.count, 2)
    }
    func testOmittedDefaultIsStillAuditable() async throws {
        try store.update { $0.draft?.contributions.removeLast(); $0.draft?.amount = 400_000 }
        let reviewed = try await review(); try await engine.apply(reviewed)
        XCTAssertEqual(store.state.history.first?.draft.normalContributions?.last?.categoryID, "car")
        XCTAssertEqual(store.state.history.first?.draft.normalContributions?.last?.amount, 75_000)
        XCTAssertEqual(store.state.history.first?.steps.count, 1)
    }
    func testReadyToAssignCannotBeReusedButSupportsNewMoneyOnTheSameDay() async throws {
        try store.update { state in
            try state.draft?.useReadyToAssign(api.value, history: state.history, digits: 2)
            state.draft?.contributions[0].amount = 925_000
        }
        let first = try await review(); try await engine.apply(first)
        XCTAssertEqual(api.value.readyToAssign, 0)
        var next = Draft(planID: plan.id, month: Dates.month(), date: Dates.day(), contributions: first.draft.contributions)
        XCTAssertThrowsError(try next.useReadyToAssign(api.value, history: store.state.history, digits: 2))
        await fails { try await self.engine.apply(first) }
        // Two deposits in different accounts need no transaction linking; only the
        // aggregate unassigned amount matters when new income arrives later.
        api.value.readyToAssign = 50_000
        try next.useReadyToAssign(api.value, history: store.state.history, digits: 2)
        XCTAssertEqual(next.reference, "Ready to Assign 2")
        next.contributions = [.init(categoryID: "food", name: "Groceries", amount: 50_000)]
        try store.update { $0.draft = next }
        let second = try await review(); try await engine.apply(second)
        XCTAssertEqual(store.state.history.count, 2)
        XCTAssertEqual(api.value.readyToAssign, 0)
        XCTAssertEqual(api.writes.count, 3)
    }
}
