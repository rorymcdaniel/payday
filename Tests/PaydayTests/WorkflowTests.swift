import XCTest
import AppKit
import PaydayCore
@testable import Payday

@MainActor final class WorkflowTests: XCTestCase {
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
