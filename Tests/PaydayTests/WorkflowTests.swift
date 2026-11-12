import XCTest
import AppKit
@testable import PaydayCore
@testable import Payday

@MainActor final class WorkflowTests: XCTestCase {
    func testEarlierMonthDraftCanStartCurrentPaycheckKeepingDefaultsAndHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("payday-new-paycheck-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store(directory: directory)
        let row = Contribution(categoryID: "home", name: "Rent & home", amount: 100_000, normal: 100_000)
        let previousMonth = Dates.month(Calendar.current.date(byAdding: .month, value: -1, to: Date())!)
        var draft = Draft(planID: DemoAPI.plan.id, month: previousMonth, date: Dates.day(), contributions: [row])
        draft.amount = row.amount
        var saved = draft; saved.id = UUID(); saved.reference = "Earlier allocation"
        let history = AllocationOperation(id: saved.id, draft: saved, plan: DemoAPI.plan, createdAt: Date(),
                                          status: .completed, readyBefore: 1_000_000, steps: [])
        try store.update { $0.selectedPlan = DemoAPI.plan; $0.defaults[DemoAPI.plan.id] = [row]; $0.draft = draft; $0.history = [history] }
        let model = AppModel(store: store, api: try DemoAPI(directory: directory))
        XCTAssertFalse(model.canReview, "An earlier-month draft needs an explicit new paycheck before review.")
        model.newDraft()
        try await waitForWork(model)
        XCTAssertNil(model.error)
        XCTAssertNotEqual(model.state.draft?.id, draft.id)
        XCTAssertEqual(model.state.draft?.month, Dates.month())
        XCTAssertEqual(model.state.draft?.date, Dates.day())
        XCTAssertEqual(model.state.draft?.contributions, [row])
        XCTAssertEqual(model.state.defaults[DemoAPI.plan.id], [row])
        XCTAssertEqual(model.state.history, [history])
        XCTAssertEqual(model.snapshot?.month, Dates.month())
        model.useReadyToAssign()
        try await waitForWork(model)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.state.draft?.amount, model.snapshot?.readyToAssign)
        XCTAssertEqual(model.state.draft?.usesReadyToAssign, true)
        XCTAssertEqual(model.state, store.state)
    }

    func testNewPaycheckKeepsSavedDraftWhenHistoryNeedsAttentionOrModelIsBusy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("payday-blocked-draft-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store(directory: directory)
        let draft = Draft(planID: DemoAPI.plan.id, month: Dates.month(), date: Dates.day(), contributions: [])
        let history = AllocationOperation(id: UUID(), draft: draft, plan: DemoAPI.plan, createdAt: Date(),
                                          status: .needsAttention, readyBefore: 1_000_000, steps: [])
        try store.update { $0.selectedPlan = DemoAPI.plan; $0.draft = draft; $0.history = [history] }
        let model = AppModel(store: store, api: try DemoAPI(directory: directory))
        let before = store.state
        model.newDraft()
        try await waitForWork(model)
        XCTAssertEqual(model.state, before)
        XCTAssertNotNil(model.error)
        model.busy = true
        model.newDraft()
        XCTAssertEqual(model.state, before)
        model.busy = false
    }

    func testNewPaycheckClearsEarlierSnapshotWhenRefreshFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("payday-draft-refresh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store(directory: directory)
        try store.update { $0.selectedPlan = DemoAPI.plan }
        let model = AppModel(store: store, api: UnavailableSnapshotAPI())
        model.snapshot = Snapshot(month: "2020-01-01", readyToAssign: 100_000, categories: [])
        model.newDraft()
        try await waitForWork(model)
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.snapshot, "An old balance must not be displayed beside the new paycheck after a failed refresh.")
        XCTAssertEqual(model.state.draft?.month, Dates.month())
        XCTAssertEqual(model.state, store.state)
    }

    private func waitForWork(_ model: AppModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertFalse(model.busy, "Local workflow should finish without external services.")
    }

    func testAndroidExportSavesPortableSetupAndHandlesCancelBusyAndWriteFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("payday-transfer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store(directory: directory)
        try store.update { $0.selectedPlan = DemoAPI.plan; $0.defaults[DemoAPI.plan.id] = DemoAPI.defaults }
        let model = AppModel(store: store, api: try DemoAPI(directory: directory))
        let destination = directory.appendingPathComponent("transfer.json")
        model.exportForAndroid { practice in XCTAssertTrue(practice); return destination }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let transfer = try decoder.decode(PaydayTransfer.self, from: Data(contentsOf: destination))
        XCTAssertEqual(transfer.state, store.state)
        XCTAssertEqual(transfer.mode, "practice")
        XCTAssertNotNil(model.notice)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        model.notice = nil
        model.exportForAndroid { _ in nil }
        XCTAssertNil(model.notice)
        model.busy = true
        model.exportForAndroid { _ in XCTFail("Must not export during network work"); return destination }
        model.busy = false
        model.exportForAndroid { _ in directory }
        XCTAssertNotNil(model.error)
        XCTAssertEqual(store.state.defaults[DemoAPI.plan.id], DemoAPI.defaults)
    }

    func testNativeFieldFormatsEachEditAndRejectsInvalidAmounts() {
        var amounts: [Int64] = []; var valid = true
        let view = CentsTextField(value: 0, digits: 2, large: false, label: "Amount",
                                  change: { amounts.append($0) }, validity: { valid = $0 }, focus: { _ in })
        let coordinator = view.makeCoordinator()
        let field = SelectAmountField()
        func type(_ raw: String) {
            field.stringValue = raw
            coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        type("1"); XCTAssertEqual(field.stringValue, "0.01")
        type(field.stringValue + "0"); XCTAssertEqual(field.stringValue, "0.10")
        type(field.stringValue + "0"); XCTAssertEqual(field.stringValue, "1.00")
        type("1.0"); XCTAssertEqual(field.stringValue, "0.10")
        type("-100"); XCTAssertFalse(valid)
        XCTAssertEqual(amounts, [10, 100, 1000, 100])
    }

    func testDefaultSetupImmediatelyPopulatesPaycheckAndResetPreservesFundingAmount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("payday-workflow-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store(directory: directory)
        try store.update {
            $0.selectedPlan = DemoAPI.plan
            $0.draft = Draft(planID: DemoAPI.plan.id, month: Dates.month(), date: Dates.day(), contributions: [])
        }
        let model = AppModel(store: store, api: try DemoAPI(directory: directory))
        for id in ["a", "b"] { model.addCategory(.init(id: id, name: id, group: "Group", budgeted: 0, balance: 0), isDefault: true) }
        model.setContribution("a", amount: 100_000, isDefault: true)
        model.setContribution("b", amount: 200_000, isDefault: true)
        XCTAssertEqual(model.state.draft?.contributions.map(\.amount), [100_000, 200_000])
        model.setContribution("a", amount: 125_000, isDefault: false)
        model.setContribution("b", amount: 225_000, isDefault: true)
        model.moveDefault("b", by: -1)
        XCTAssertEqual(model.state.draft?.contributions.map(\.id), ["b", "a"])
        XCTAssertEqual(model.state.draft?.contributions.map(\.amount), [225_000, 125_000])
        model.setPaycheck(350_000)
        model.resetContributions()
        XCTAssertEqual(model.state.draft?.amount, 350_000)
        XCTAssertEqual(model.state.draft?.contributions.map(\.amount), [225_000, 100_000])
        XCTAssertEqual(model.state, store.state)
    }
}

private struct UnavailableSnapshotAPI: BudgetAPI {
    func plans() async throws -> [Plan] { [DemoAPI.plan] }
    func snapshot(planID: String, month: String) async throws -> Snapshot { throw AppError("Synthetic refresh failure") }
    func incomes(planID: String) async throws -> [Income] { [] }
    func assign(planID: String, month: String, categoryID: String, budgeted: Int64) async throws -> Int64 {
        XCTFail("Starting a paycheck must never assign money.")
        throw AppError("Unexpected write")
    }
}
