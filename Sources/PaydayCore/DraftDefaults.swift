import Foundation

public extension Draft {
    /// Follow saved defaults while preserving paycheck overrides and omissions.
    mutating func synchronizeDefaults(_ defaults: [Contribution]) {
        let baseline = normalContributions ?? contributions.map {
            Contribution(categoryID: $0.id, name: $0.name, amount: $0.normal)
        }
        var next: [Contribution] = []
        for normal in defaults {
            let previous = baseline.first { $0.id == normal.id }
            if var row = contributions.first(where: { $0.id == normal.id }) {
                if let previous, row.amount == previous.amount { row.amount = normal.amount }
                row.name = normal.name; row.normal = normal.amount
                next.append(row)
            } else if previous == nil {
                next.append(.init(categoryID: normal.id, name: normal.name, amount: normal.amount, normal: normal.amount))
            }
        }
        for var row in contributions where !defaults.contains(where: { $0.id == row.id }) {
            let previous = baseline.first { $0.id == row.id }
            if previous == nil || previous?.amount != row.amount {
                row.normal = 0; next.append(row)
            }
        }
        contributions = next
        normalContributions = defaults.map { .init(categoryID: $0.id, name: $0.name, amount: $0.amount, normal: $0.amount) }
    }

    /// RTA is read into a draft; this never claims an allocation or writes YNAB.
    mutating func useReadyToAssign(_ snapshot: Snapshot, history: [AllocationOperation], digits: Int) throws {
        guard snapshot.month == month, month == Dates.month() else {
            throw AppError("Start a new draft for the current month before using Ready to Assign.")
        }
        guard snapshot.readyToAssign > 0, snapshot.readyToAssign <= Money.limit else {
            throw AppError("There is no positive Ready to Assign available, including future months. Refresh after funding your budget.")
        }
        guard (0...3).contains(digits), snapshot.readyToAssign % [1000, 100, 10, 1][digits] == 0 else {
            throw AppError("Ready to Assign contains more precision than your budget currency supports. Resolve the fractional amount in YNAB first.")
        }
        if usesReadyToAssign != true {
            date = Dates.day(); reference = "Ready to Assign"
            var sequence = 2
            while history.contains(where: { $0.draft.identity == identity }) {
                reference = "Ready to Assign \(sequence)"; sequence += 1
            }
        }
        amount = snapshot.readyToAssign
        incomeID = nil; incomeAliases = nil; usesReadyToAssign = true
    }
}

public extension AppState {
    mutating func moveDefault(planID: String, categoryID: String, to targetID: String) {
        guard var rows = defaults[planID],
              let source = rows.firstIndex(where: { $0.id == categoryID }),
              let target = rows.firstIndex(where: { $0.id == targetID }), source != target else { return }
        let row = rows.remove(at: source)
        rows.insert(row, at: target)
        defaults[planID] = rows
        if draft?.planID == planID { draft?.synchronizeDefaults(rows) }
    }
}
