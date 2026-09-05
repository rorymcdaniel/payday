import Foundation

public struct Plan: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var currency: String
    public var digits: Int
    public init(id: String, name: String, currency: String = "USD", digits: Int = 2) {
        self.id = id; self.name = name; self.currency = currency; self.digits = digits
    }
}

public struct BudgetCategory: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var group: String
    public var budgeted: Int64
    public var balance: Int64
    public var eligible: Bool
    public init(id: String, name: String, group: String, budgeted: Int64, balance: Int64, eligible: Bool = true) {
        self.id = id; self.name = name; self.group = group
        self.budgeted = budgeted; self.balance = balance; self.eligible = eligible
    }
}

public struct Snapshot: Codable, Equatable {
    public var month: String
    public var readyToAssign: Int64
    public var categories: [BudgetCategory]
    public init(month: String, readyToAssign: Int64, categories: [BudgetCategory]) {
        self.month = month; self.readyToAssign = readyToAssign; self.categories = categories
    }
}

public struct Income: Codable, Identifiable, Equatable {
    public var id: String
    public var date: String
    public var name: String
    public var amount: Int64
    public var aliases: [String]?
    public init(id: String, date: String, name: String, amount: Int64, aliases: [String]? = nil) {
        self.id = id; self.date = date; self.name = name; self.amount = amount
        self.aliases = aliases
    }
    public var identityKeys: Set<String> { Set([id] + (aliases ?? [])) }
}

public struct Contribution: Codable, Identifiable, Equatable {
    public var categoryID: String
    public var name: String
    public var amount: Int64
    public var normal: Int64
    public var id: String { categoryID }
    public init(categoryID: String, name: String, amount: Int64, normal: Int64 = 0) {
        self.categoryID = categoryID; self.name = name; self.amount = amount; self.normal = normal
    }
}

public struct Draft: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var planID: String
    public var month: String
    public var date: String
    public var reference: String = "Paycheck"
    public var incomeID: String?
    public var incomeAliases: [String]?
    public var usesReadyToAssign: Bool?
    public var amount: Int64 = 0
    public var contributions: [Contribution]
    public var normalContributions: [Contribution]?
    public var identity: String { "\(planID)|\(date)|\(reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" }
    public init(planID: String, month: String, date: String, contributions: [Contribution]) {
        self.planID = planID; self.month = month; self.date = date; self.contributions = contributions
        self.normalContributions = contributions.map { .init(categoryID: $0.id, name: $0.name, amount: $0.normal, normal: $0.normal) }
    }
}

public enum StepStatus: String, Codable { case pending, sending, verified, uncertain }
public enum OperationStatus: String, Codable { case applying, completed, needsAttention, reconciled }

public struct AllocationStep: Codable, Identifiable, Equatable {
    public var contribution: Contribution
    public var beforeBudgeted: Int64
    public var beforeBalance: Int64
    public var targetBudgeted: Int64
    public var status: StepStatus = .pending
    public var observation: Int64?
    public var id: String { contribution.categoryID }
}

public struct AllocationOperation: Codable, Identifiable, Equatable {
    public var id: UUID
    public var draft: Draft
    public var plan: Plan
    public var createdAt: Date
    public var status: OperationStatus
    public var readyBefore: Int64
    public var steps: [AllocationStep]
    public var message: String?
    public var reconciliationNote: String?
    public var resolvedAt: Date?
    public var blocksWrites: Bool { status == .applying || status == .needsAttention }
}

public struct AppState: Codable, Equatable {
    public var schemaVersion = 1
    public var selectedPlan: Plan?
    public var defaults: [String: [Contribution]] = [:]
    public var draft: Draft?
    public var history: [AllocationOperation] = []
    public init() {}
}

public enum Dates {
    public static func day(_ date: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    public static func month(_ date: Date = Date()) -> String { String(day(date).prefix(7)) + "-01" }
}
