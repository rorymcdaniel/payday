import Foundation

/// Main-actor serialization prevents reentrancy from a second confirm/window.
/// Store's process lock extends this protection across app instances.
@MainActor public final class AllocationEngine {
    public let store: Store
    public let api: BudgetAPI
    public private(set) var busy = false
    public init(store: Store, api: BudgetAPI) { self.store = store; self.api = api }

    public func recoverInterruptedOperations() throws {
        try store.update { state in
            for index in state.history.indices where state.history[index].status == .applying {
                state.history[index].status = .needsAttention
                state.history[index].message = "Payday closed during this allocation. Nothing will be retried. Compare the saved steps with YNAB and reconcile below."
                for step in state.history[index].steps.indices where state.history[index].steps[step].status == .sending {
                    state.history[index].steps[step].status = .uncertain
                }
            }
        }
    }

    public func review(_ draft: Draft, plan: Plan) async throws -> AllocationOperation {
        guard !busy else { throw AppError("An allocation is already running.") }
        try validate(draft, plan: plan)
        try await validateCurrency(plan)
        if let incomeID = draft.incomeID {
            let incomes = try await api.incomes(planID: plan.id)
            guard let income = incomes.first(where: { $0.id == incomeID && $0.amount == draft.amount && $0.date == draft.date }) else {
                throw AppError("The linked deposit changed or is no longer available. Refresh and choose the paycheck again.")
            }
            try validateIncomeIdentity(income, planID: plan.id)
        }
        let snapshot = try await api.snapshot(planID: plan.id, month: draft.month)
        guard snapshot.readyToAssign >= draft.amount else { throw AppError("There isn’t enough Ready to Assign, including future months. Record the paycheck in YNAB and resolve any overassignment first.") }
        let steps = try draft.contributions.filter { $0.amount > 0 }.map { contribution -> AllocationStep in
            guard let category = snapshot.categories.first(where: { $0.id == contribution.categoryID }), category.eligible else {
                throw AppError("\(contribution.name) is hidden, deleted, or unavailable. Replace or remove it before applying.")
            }
            let target = category.budgeted.addingReportingOverflow(contribution.amount)
            guard !target.overflow, (-Money.limit...Money.limit).contains(target.partialValue) else { throw AppError("The resulting assigned amount is too large.") }
            return AllocationStep(contribution: contribution, beforeBudgeted: category.budgeted, beforeBalance: category.balance, targetBudgeted: target.partialValue)
        }
        return AllocationOperation(id: draft.id, draft: draft, plan: plan, createdAt: Date(), status: .applying,
                         readyBefore: snapshot.readyToAssign, steps: steps)
    }

    public func apply(_ reviewed: AllocationOperation, progress: () -> Void = {}) async throws {
        guard !busy else { throw AppError("An allocation is already running.") }
        busy = true
        defer { busy = false; progress() }
        try validate(reviewed.draft, plan: reviewed.plan)
        guard store.state.draft == reviewed.draft else { throw AppError("The paycheck changed after review. Review it again.") }
        guard Date().timeIntervalSince(reviewed.createdAt) < 300 else { throw AppError("This review is over five minutes old. Refresh it before applying.") }
        try await validateCurrency(reviewed.plan)
        // Revalidate linked income at the final boundary too.
        if let incomeID = reviewed.draft.incomeID {
            let incomes = try await api.incomes(planID: reviewed.plan.id)
            guard let income = incomes.first(where: { $0.id == incomeID && $0.amount == reviewed.draft.amount && $0.date == reviewed.draft.date }) else {
                throw AppError("The linked paycheck changed since review. Review it again.")
            }
            try validateIncomeIdentity(income, planID: reviewed.plan.id)
        }
        let fresh = try await api.snapshot(planID: reviewed.plan.id, month: reviewed.draft.month)
        try check(fresh, operation: reviewed, startingAt: 0)
        try api.checkWriteCapacity(categoryCount: reviewed.steps.count)
        // Claim the paycheck and write all intents atomically before any network write.
        try store.update { $0.history.insert(reviewed, at: 0); $0.draft = nil }
        progress()
        do {
            for index in reviewed.steps.indices {
                let op = operation(reviewed.id)!
                let live = index == 0 ? fresh : try await api.snapshot(planID: op.plan.id, month: op.draft.month)
                try check(live, operation: op, startingAt: index)
                try mutate(op.id) { $0.steps[index].status = .sending }
                progress()
                let step = op.steps[index]
                let response = try await api.assign(planID: op.plan.id, month: op.draft.month,
                                                    categoryID: step.id, budgeted: step.targetBudgeted)
                guard response == step.targetBudgeted else { throw AppError("YNAB’s response did not match the requested assignment.") }
                // A confirmed PATCH is recorded; the next snapshot verifies it again.
                try mutate(op.id) { $0.steps[index].status = .verified; $0.steps[index].observation = response }
                progress()
            }
            let op = operation(reviewed.id)!
            let final = try await api.snapshot(planID: op.plan.id, month: op.draft.month)
            try check(final, operation: op, startingAt: op.steps.count)
            try mutate(op.id) { $0.status = .completed; $0.message = "Every contribution was confirmed by YNAB and verified in a final read."; $0.resolvedAt = Date() }
        } catch {
            // If this persistence fails too, the durable 'applying/sending' intent
            // still blocks all writes and is recovered as uncertain next launch.
            try? mutate(reviewed.id) { op in
                op.status = .needsAttention
                op.message = error.localizedDescription
                for index in op.steps.indices where op.steps[index].status == .sending { op.steps[index].status = .uncertain }
            }
            throw error
        }
    }

    public func inspect(_ id: UUID) async throws {
        guard !busy, let op = operation(id) else { throw AppError("Wait for the current allocation to finish.") }
        let snapshot = try await api.snapshot(planID: op.plan.id, month: op.draft.month)
        try mutate(id) { value in
            for index in value.steps.indices {
                value.steps[index].observation = snapshot.categories.first { $0.id == value.steps[index].id }?.budgeted
            }
        }
    }

    public func reconcile(_ id: UUID, note: String) throws {
        guard !busy, let op = operation(id), op.blocksWrites,
              note.trimmingCharacters(in: .whitespacesAndNewlines).count >= 12 else {
            throw AppError("Describe what you checked and corrected in YNAB (at least 12 characters).")
        }
        try mutate(id) { $0.status = .reconciled; $0.reconciliationNote = note; $0.resolvedAt = Date() }
    }

    private func validate(_ draft: Draft, plan: Plan) throws {
        guard !store.state.history.contains(where: \.blocksWrites) else { throw AppError("An earlier allocation needs attention in History. Reconcile it before allocating another paycheck.") }
        guard draft.planID == plan.id, store.state.selectedPlan?.id == plan.id else { throw AppError("The selected budget changed. Review the paycheck again.") }
        guard draft.month == Dates.month() else { throw AppError("This paycheck draft targets a different month. Start a new draft for the current month; your old draft has not been applied.") }
        guard draft.date <= Dates.day(), draft.date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              !draft.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError("Enter the paycheck date and a reference.") }
        guard draft.amount > 0, try Money.total(draft.contributions.map(\.amount)) == draft.amount else { throw AppError("Allocate every dollar of the paycheck before reviewing.") }
        guard Set(draft.contributions.map(\.id)).count == draft.contributions.count else { throw AppError("A category appears more than once.") }
        guard (0...3).contains(plan.digits) else { throw AppError("Unsupported currency precision.") }
        let unit: Int64 = [1000, 100, 10, 1][plan.digits]
        guard draft.amount % unit == 0, draft.contributions.allSatisfy({ $0.amount % unit == 0 }) else { throw AppError("Use your budget currency’s supported decimal precision.") }
        guard !store.state.history.contains(where: {
            $0.id == draft.id || $0.draft.identity == draft.identity ||
            (draft.incomeID != nil && $0.draft.planID == draft.planID && $0.draft.incomeID == draft.incomeID)
        }) else { throw AppError("This paycheck already has an allocation in History. It cannot be applied again.") }
    }

    private func validateCurrency(_ plan: Plan) async throws {
        let live = try await api.plans().first { $0.id == plan.id }
        guard live?.currency == plan.currency, live?.digits == plan.digits else {
            throw AppError("The budget is no longer accessible or its currency changed. Refresh your connection and review the amounts again.")
        }
    }

    private func validateIncomeIdentity(_ income: Income, planID: String) throws {
        guard !store.state.history.contains(where: { op in
            guard op.plan.id == planID, let id = op.draft.incomeID else { return false }
            return !income.identityKeys.isDisjoint(with: Set([id] + (op.draft.incomeAliases ?? [])))
        }) else { throw AppError("This deposit matches a paycheck already recorded in History, including its imported or matched transaction identity.") }
    }

    private func check(_ snapshot: Snapshot, operation: AllocationOperation, startingAt index: Int) throws {
        guard snapshot.month == operation.draft.month else { throw AppError("YNAB returned a different month.") }
        let remaining = try Money.total(operation.steps.dropFirst(index).map { $0.contribution.amount })
        guard snapshot.readyToAssign >= remaining else { throw AppError("Ready to Assign changed or is insufficient. Assignment stopped; inspect History.") }
        for (position, step) in operation.steps.enumerated() {
            guard let live = snapshot.categories.first(where: { $0.id == step.id }), live.eligible else { throw AppError("A category became unavailable. Assignment stopped.") }
            let expected = position < index ? step.targetBudgeted : step.beforeBudgeted
            guard live.budgeted == expected else { throw AppError("\(step.contribution.name) changed in YNAB since review. Assignment stopped to avoid overwriting that change.") }
        }
    }
    private func operation(_ id: UUID) -> AllocationOperation? { store.state.history.first { $0.id == id } }
    private func mutate(_ id: UUID, _ change: (inout AllocationOperation) -> Void) throws {
        try store.update { state in
            guard let index = state.history.firstIndex(where: { $0.id == id }) else { throw AppError("The allocation journal is missing. No further changes will be sent.") }
            change(&state.history[index])
        }
    }
}
