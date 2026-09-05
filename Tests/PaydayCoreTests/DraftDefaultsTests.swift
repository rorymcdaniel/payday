import XCTest
@testable import PaydayCore

final class DraftDefaultsTests: XCTestCase {
    private func row(_ id: String, _ amount: Int64) -> Contribution {
        .init(categoryID: id, name: id, amount: amount, normal: amount)
    }
    private func draft(_ rows: [Contribution] = []) -> Draft {
        Draft(planID: "plan", month: Dates.month(), date: Dates.day(), contributions: rows)
    }
    func testDefaultsPopulateAnExistingEmptyDraftAndTrackAmountChanges() {
        var value = draft()
        value.synchronizeDefaults([row("food", 100_000), row("car", 200_000)])
        XCTAssertEqual(value.contributions.map(\.amount), [100_000, 200_000])
        value.synchronizeDefaults([row("food", 125_000), row("car", 200_000)])
        XCTAssertEqual(value.contributions.map(\.amount), [125_000, 200_000])
        XCTAssertEqual(value.normalContributions?.map(\.amount), [125_000, 200_000])
    }
    func testSyncPreservesOverridesOmissionsAndOneOffs() {
        var value = draft([row("food", 100_000), row("car", 200_000)])
        value.amount = 555_000
        value.contributions[0].amount = 150_000
        value.contributions.removeLast()
        value.contributions.append(.init(categoryID: "gift", name: "Gift", amount: 50_000))
        value.synchronizeDefaults([row("car", 300_000), row("food", 125_000), row("savings", 20_000)])
        XCTAssertEqual(value.contributions.map(\.id), ["food", "savings", "gift"])
        XCTAssertEqual(value.contributions.map(\.amount), [150_000, 20_000, 50_000])
        XCTAssertEqual(value.amount, 555_000)
        XCTAssertEqual(value.contributions[0].normal, 125_000)
    }
    func testRemovingDefaultDropsUntouchedButKeepsAdjustedContributionAsOneOff() {
        var value = draft([row("food", 100_000), row("car", 200_000)])
        value.contributions[1].amount = 225_000
        value.synchronizeDefaults([])
        XCTAssertEqual(value.contributions.map(\.id), ["car"])
        XCTAssertEqual(value.contributions[0].normal, 0)
    }
    func testReorderPersistsAndPropagatesWithoutChangingAmounts() throws {
        var state = AppState()
        state.defaults["plan"] = [row("food", 100_000), row("car", 200_000), row("savings", 50_000)]
        state.draft = draft(state.defaults["plan"]!)
        state.draft?.contributions[0].amount = 125_000
        state.moveDefault(planID: "plan", categoryID: "food", to: "savings")
        let restored = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.defaults["plan"]?.map(\.id), ["car", "savings", "food"])
        XCTAssertEqual(restored.draft?.contributions.map(\.id), ["car", "savings", "food"])
        XCTAssertEqual(restored.draft?.contributions.last?.amount, 125_000)
    }
    func testLegacyDraftWithoutBaselineAndNewSchemaFieldsStillLoads() throws {
        var value = draft([row("food", 100_000)])
        value.normalContributions = nil
        value.synchronizeDefaults([row("food", 110_000)])
        let data = try JSONEncoder().encode(value)
        let restored = try JSONDecoder().decode(Draft.self, from: data)
        XCTAssertEqual(restored.contributions[0].amount, 110_000)
        XCTAssertNil(restored.usesReadyToAssign)
    }
    func testReadyToAssignUsesWholeBudgetAmountAndClearsDepositLink() throws {
        var value = draft([row("food", 100_000)])
        value.incomeID = "half-paycheck"; value.incomeAliases = ["imported"]
        let snapshot = Snapshot(month: Dates.month(), readyToAssign: 4_123_720, categories: [])
        try value.useReadyToAssign(snapshot, history: [], digits: 2)
        XCTAssertEqual(value.amount, 4_123_720)
        XCTAssertNil(value.incomeID); XCTAssertNil(value.incomeAliases)
        XCTAssertEqual(value.reference, "Ready to Assign")
        XCTAssertEqual(value.contributions[0].amount, 100_000)
        let identity = value.identity; let id = value.id
        try value.useReadyToAssign(snapshot, history: [], digits: 2)
        XCTAssertEqual(value.identity, identity); XCTAssertEqual(value.id, id)
    }
    func testReadyToAssignRejectsUnavailableFundsAndDoesNotChangeDraft() {
        var value = draft(); let original = value
        for ready: Int64 in [0, -10, 1, Money.limit + 1] {
            XCTAssertThrowsError(try value.useReadyToAssign(.init(month: Dates.month(), readyToAssign: ready, categories: []), history: [], digits: 2))
            XCTAssertEqual(value, original)
        }
        XCTAssertThrowsError(try value.useReadyToAssign(.init(month: "2000-01-01", readyToAssign: 1000, categories: []), history: [], digits: 2))
    }
    func testCentsFirstSequencesAndBackspace() throws {
        var display = ""
        for (character, expected) in [("1", "0.01"), ("0", "0.10"), ("0", "1.00")] {
            display = Money.input(try Money.minorUnitEntry(display + character))
            XCTAssertEqual(display, expected)
        }
        XCTAssertEqual(Money.input(try Money.minorUnitEntry(String(display.dropLast()))), "0.10")
        XCTAssertEqual(try Money.minorUnitEntry(""), 0)
        XCTAssertEqual(try Money.minorUnitEntry("4123.72"), 4_123_720)
        for invalid in ["-1", "1,000", "NaN", "1.2.3", "9999999999999999999999"] {
            XCTAssertThrowsError(try Money.minorUnitEntry(invalid))
        }
    }
}
