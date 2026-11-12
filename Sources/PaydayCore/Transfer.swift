import Foundation

/// Portable, credential-free handoff. Dates use ISO 8601, unlike the private SQLite document.
public struct PaydayTransfer: Codable, Equatable {
    public let format: String
    public let version: Int
    public let source: String
    public let mode: String
    public let exportedAt: Date
    public let state: AppState

    public init(state: AppState, practice: Bool, now: Date = Date()) throws {
        guard state.schemaVersion == 1 else { throw AppError("Update Payday before exporting this data.") }
        guard !state.history.contains(where: { $0.status == .applying }) else {
            throw AppError("Wait for the allocation to finish before exporting your data.")
        }
        format = "app.payday.transfer"; version = 1; source = "macOS"
        mode = practice ? "practice" : "real"; exportedAt = now; self.state = state
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
