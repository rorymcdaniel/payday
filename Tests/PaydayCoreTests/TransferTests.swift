import XCTest
@testable import PaydayCore

final class TransferTests: XCTestCase {
    private func sample() -> AppState {
        var state = AppState()
        let plan = Plan(id: "fixture-plan", name: "Synthetic transfer budget")
        let rows = [Contribution(categoryID: "food", name: "Groceries", amount: 123_450, normal: 123_450)]
        var draft = Draft(planID: plan.id, month: "2026-10-01", date: "2026-10-14", contributions: rows)
        draft.id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        draft.amount = 123_450; draft.reference = "Example employer"
        draft.incomeID = "deposit-1"; draft.incomeAliases = ["import:account-1:example"]
        let date = ISO8601DateFormatter().date(from: "2026-10-14T12:00:00Z")!
        state.selectedPlan = plan; state.defaults[plan.id] = rows
        state.history = [AllocationOperation(id: draft.id, draft: draft, plan: plan, createdAt: date,
            status: .completed, readyBefore: 500_000, steps: [AllocationStep(contribution: rows[0], beforeBudgeted: 50_000,
                beforeBalance: 20_000, targetBudgeted: 173_450, status: .verified, observation: 173_450)],
            message: "Every contribution verified.", resolvedAt: date)]
        draft.id = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        draft.date = "2026-10-15"; draft.reference = "Next paycheck"; draft.incomeID = nil; draft.incomeAliases = nil
        state.draft = draft
        return state
    }
    func testPortableExportPreservesAllDataAndUsesISODates() throws {
        let value = try PaydayTransfer(state: sample(), practice: false, now: ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z")!)
        let data = try value.encoded()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(PaydayTransfer.self, from: data), value)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("2026-10-14T12:00:00Z"))
        XCTAssertFalse(text.lowercased().contains("token"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/mac-transfer-v1.json")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? NSDictionary,
                       "The shared Android fixture must match Swift’s actual export.")
    }
    func testPracticeIsLabeledAndUnresolvedHistoryIsPreserved() throws {
        var state = sample()
        state.history[0].status = .needsAttention; state.history[0].steps[0].status = .uncertain
        let transfer = try PaydayTransfer(state: state, practice: true)
        XCTAssertEqual(transfer.mode, "practice")
        XCTAssertTrue(transfer.state.history[0].blocksWrites)
        XCTAssertEqual(transfer.state.history[0].steps[0].status, .uncertain)
    }
    func testRejectsInFlightExportAndUnknownStateVersion() {
        var state = sample(); state.history[0].status = .applying
        XCTAssertThrowsError(try PaydayTransfer(state: state, practice: false))
        state = sample(); state.schemaVersion = 2
        XCTAssertThrowsError(try PaydayTransfer(state: state, practice: false))
    }
}
