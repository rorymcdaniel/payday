import Foundation

/// Separate, persistent practice budget. This type never creates a network client.
public final class DemoAPI: BudgetAPI {
    private let file: URL
    private var value: Snapshot
    public static let plan = Plan(id: "demo", name: "My practice budget")
    public static let defaults: [Contribution] = [
        .init(categoryID: "home", name: "Rent & home", amount: 1_800_000),
        .init(categoryID: "groceries", name: "Groceries", amount: 400_000),
        .init(categoryID: "gas", name: "Gasoline", amount: 100_000),
        .init(categoryID: "dining", name: "Dining out", amount: 100_000),
        .init(categoryID: "utilities", name: "Utilities", amount: 175_000),
        .init(categoryID: "car", name: "Car repair", amount: 225_000),
        .init(categoryID: "savings", name: "Emergency fund", amount: 1_000_000),
        .init(categoryID: "fun", name: "Fun & adventures", amount: 275_000)
    ]
    public init(directory: URL) throws {
        file = directory.appendingPathComponent("practice-budget.json")
        if FileManager.default.fileExists(atPath: file.path) {
            value = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
        } else {
            value = Snapshot(month: Dates.month(), readyToAssign: 8_247_440, categories:
                Self.defaults.enumerated().map { index, entry in
                    BudgetCategory(id: entry.id, name: entry.name, group: index < 5 ? "Everyday" : "Looking ahead",
                             budgeted: index == 1 ? 500_000 : 0,
                             balance: index == 1 ? 35_000 : index == 5 ? 2_000_000 : index == 6 ? 6_400_000 : 0)
                } + [BudgetCategory(id: "gifts", name: "Gifts", group: "Looking ahead", budgeted: 0, balance: 80_000)])
            try save()
        }
    }
    public func plans() async throws -> [Plan] { [Self.plan] }
    public func snapshot(planID: String, month: String) async throws -> Snapshot {
        var copy = value; copy.month = month; return copy
    }
    public func incomes(planID: String) async throws -> [Income] {
        [Income(id: "practice-paycheck-\(Dates.day())", date: Dates.day(), name: "Example employer", amount: 4_123_720)]
    }
    public func assign(planID: String, month: String, categoryID: String, budgeted: Int64) async throws -> Int64 {
        guard let index = value.categories.firstIndex(where: { $0.id == categoryID }) else { throw AppError("Practice category not found.") }
        let difference = budgeted - value.categories[index].budgeted
        value.categories[index].budgeted = budgeted
        value.categories[index].balance += difference
        value.readyToAssign -= difference
        value.month = month
        try save()
        return budgeted
    }
    private func save() throws {
        try JSONEncoder().encode(value).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
