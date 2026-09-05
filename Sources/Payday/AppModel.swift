import SwiftUI
import PaydayCore

enum Page: String, CaseIterable { case paycheck = "Paycheck", defaults = "Defaults", history = "History", connection = "Connection" }

@MainActor final class AppModel: ObservableObject {
    @Published var page: Page = .paycheck
    @Published var state = AppState()
    @Published var snapshot: Snapshot?
    @Published var plans: [Plan] = []
    @Published var incomes: [Income] = []
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var reviewed: AllocationOperation?
    @Published var invalidFields: Set<String> = []
    @Published var connected = false
    @Published var fatalError: String?
    @Published var contributionInputRevision = 0
    @Published var paycheckInputRevision = 0
    let demo: Bool
    var store: Store?
    var engine: AllocationEngine?
    var plan: Plan? { state.selectedPlan }
    var defaults: [Contribution] { state.defaults[plan?.id ?? ""] ?? [] }
    var allocated: Int64 { (try? Money.total(state.draft?.contributions.map(\.amount) ?? [])) ?? 0 }
    var remaining: Int64 { (state.draft?.amount ?? 0) - allocated }
    var blocked: Bool { state.history.contains(where: \.blocksWrites) }
    var canReview: Bool {
        connected && !busy && !blocked && invalidFields.isEmpty && remaining == 0 && (state.draft?.amount ?? 0) > 0
    }

    init() {
        demo = CommandLine.arguments.contains("--demo")
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directory: URL
            if demo, let flag = CommandLine.arguments.firstIndex(of: "--demo-directory"), CommandLine.arguments.indices.contains(flag + 1) {
                directory = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
            } else { directory = support.appendingPathComponent(demo ? "Payday Practice" : "Payday", isDirectory: true) }
            let store = try Store(directory: directory)
            self.store = store
            if demo {
                let api = try DemoAPI(directory: directory)
                engine = AllocationEngine(store: store, api: api)
                if store.state.selectedPlan == nil {
                    try store.update { $0.selectedPlan = DemoAPI.plan; $0.defaults[DemoAPI.plan.id] = DemoAPI.defaults }
                }
                connected = true
            } else if let token = try TokenVault.read() {
                engine = AllocationEngine(store: store, api: YNABClient(token: token))
                connected = true
            }
            // Recovery does not depend on credentials being available.
            if let engine { try engine.recoverInterruptedOperations() }
            try store.update { state in
                if let planID = state.draft?.planID, !state.history.contains(where: \.blocksWrites) {
                    state.draft?.synchronizeDefaults(state.defaults[planID] ?? [])
                }
            }
            sync()
            if !connected || plan == nil { page = .connection }
            if blocked { page = .history }
        } catch { fatalError = error.localizedDescription }
    }

    /// Explicit local dependencies let tests exercise the native workflow without Keychain.
    init(store: Store, api: BudgetAPI) {
        demo = true; self.store = store
        engine = AllocationEngine(store: store, api: api)
        connected = true; sync()
    }

    func money(_ amount: Int64) -> String { Money.format(amount, currency: plan?.currency ?? "USD", digits: plan?.digits ?? 2) }
    func sync() { if let store { state = store.state } }
    func persist(_ change: (inout AppState) -> Void) {
        guard !busy, let store else { return }
        do {
            try store.update { state in
                change(&state)
                if let planID = state.draft?.planID {
                    state.draft?.synchronizeDefaults(state.defaults[planID] ?? [])
                }
            }
            sync()
        } catch { self.error = error.localizedDescription }
    }
    func work(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil; notice = nil
        Task {
            defer { busy = false; sync() }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
    func start() async {
        guard connected else { return }
        work { try await self.refreshData() }
    }
    func refresh() { work { try await self.refreshData() } }
    private func refreshData() async throws {
        guard let engine else { return }
        plans = try await engine.api.plans()
        guard let plan else { return }
        guard let refreshedPlan = plans.first(where: { $0.id == plan.id }) else { throw AppError("Your selected budget is no longer accessible. Choose another in Connection.") }
        guard refreshedPlan.currency == plan.currency && refreshedPlan.digits == plan.digits else {
            throw AppError("Your budget currency changed. Check your saved amounts, then reselect this budget in Connection.")
        }
        snapshot = try await engine.api.snapshot(planID: plan.id, month: state.draft?.month ?? Dates.month())
        // The deposit picker is optional; an unavailable listing must not erase a draft.
        do { incomes = try await engine.api.incomes(planID: plan.id) }
        catch { incomes = []; notice = "Budget refreshed. Recent deposits could not be loaded; you can enter a paycheck manually." }
        if state.draft == nil && !blocked { try createDraft() }
        else if !blocked {
            try store?.update { state in state.draft?.synchronizeDefaults(state.defaults[plan.id] ?? []) }
            sync()
        }
    }
    private func createDraft() throws {
        guard let plan, let store else { return }
        var draft = Draft(planID: plan.id, month: Dates.month(), date: Dates.day(),
                          contributions: defaults.map { .init(categoryID: $0.id, name: $0.name, amount: $0.amount, normal: $0.amount) })
        if demo { draft.amount = 4_123_720 }
        try store.update { $0.draft = draft }; sync(); invalidFields = []
        contributionInputRevision += 1; paycheckInputRevision += 1
    }
    func newDraft() { work { try self.createDraft(); self.page = .paycheck; try await self.refreshData() } }
    func connect(_ rawToken: String) {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { error = "Paste your personal access token first."; return }
        guard token.count <= 4096, token.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else {
            error = "Paste only the token, without spaces, line breaks, or an Authorization header."; return
        }
        work {
            let api = YNABClient(token: token)
            let plans = try await api.plans()
            try TokenVault.save(token)
            guard let store = self.store else { return }
            self.engine = AllocationEngine(store: store, api: api)
            try self.engine?.recoverInterruptedOperations()
            self.plans = plans; self.connected = true
            self.notice = "Connected. Choose the budget you want to allocate into."
        }
    }
    func disconnect() {
        guard !busy else { return }
        do { try TokenVault.remove(); engine = nil; connected = false; snapshot = nil; incomes = []; page = .connection }
        catch { self.error = error.localizedDescription }
    }
    func selectPlan(_ selected: Plan) {
        guard !blocked else { error = "Reconcile the pending allocation in History before switching budgets."; return }
        work {
            try self.store?.update { $0.selectedPlan = selected; $0.draft = nil }
            self.sync(); try self.createDraft(); try await self.refreshData(); self.page = .paycheck
        }
    }
    func setPaycheck(_ amount: Int64) { persist { $0.draft?.amount = amount; $0.draft?.incomeID = nil; $0.draft?.incomeAliases = nil; $0.draft?.usesReadyToAssign = false } }
    func useReadyToAssign() {
        guard let plan, let engine, !blocked else { return }
        work {
            let live = try await engine.api.snapshot(planID: plan.id, month: Dates.month())
            if self.store?.state.draft == nil { try self.createDraft() }
            try self.store?.update { state in
                try state.draft?.useReadyToAssign(live, history: state.history, digits: plan.digits)
            }
            self.snapshot = live
            self.invalidFields.remove("paycheck")
            self.paycheckInputRevision += 1
            self.notice = "Using \(self.money(live.readyToAssign)) available across your budget. Review the contributions before applying."
        }
    }
    func chooseIncome(_ income: Income) {
        persist { $0.draft?.amount = income.amount; $0.draft?.date = income.date; $0.draft?.incomeID = income.id; $0.draft?.incomeAliases = income.aliases; $0.draft?.reference = income.name; $0.draft?.usesReadyToAssign = false }
        invalidFields.remove("paycheck")
        paycheckInputRevision += 1
    }
    func setContribution(_ id: String, amount: Int64, isDefault: Bool) {
        guard let plan else { return }
        persist { state in
            if isDefault, let index = state.defaults[plan.id]?.firstIndex(where: { $0.id == id }) { state.defaults[plan.id]?[index].amount = amount }
            if !isDefault, let index = state.draft?.contributions.firstIndex(where: { $0.id == id }) { state.draft?.contributions[index].amount = amount }
        }
    }
    func addCategory(_ category: BudgetCategory, isDefault: Bool) {
        guard let plan else { return }
        let row = Contribution(categoryID: category.id, name: category.name, amount: 0)
        persist {
            if isDefault, !$0.defaults[plan.id, default: []].contains(where: { $0.id == row.id }) { $0.defaults[plan.id, default: []].append(row) }
            else if !isDefault, $0.draft?.contributions.contains(where: { $0.id == row.id }) == false { $0.draft?.contributions.append(row) }
        }
    }
    func moveDefault(_ id: String, to target: String) {
        guard let plan else { return }
        persist { $0.moveDefault(planID: plan.id, categoryID: id, to: target) }
    }
    func moveDefault(_ id: String, by offset: Int) {
        guard let index = defaults.firstIndex(where: { $0.id == id }), defaults.indices.contains(index + offset) else { return }
        moveDefault(id, to: defaults[index + offset].id)
    }
    func resetContributions() {
        persist { state in
            guard let planID = state.draft?.planID else { return }
            let rows = (state.defaults[planID] ?? []).map { Contribution(categoryID: $0.id, name: $0.name, amount: $0.amount, normal: $0.amount) }
            state.draft?.contributions = rows; state.draft?.normalContributions = rows
        }
        invalidFields = invalidFields.filter { !$0.hasPrefix("draft-") }
        contributionInputRevision += 1
    }
    func removeCategory(_ id: String, isDefault: Bool) {
        guard let plan else { return }
        persist {
            if isDefault { $0.defaults[plan.id]?.removeAll { $0.id == id } }
            else { $0.draft?.contributions.removeAll { $0.id == id } }
        }
        invalidFields.remove((isDefault ? "default-" : "draft-") + id)
    }
    func useRemainder(_ id: String) {
        guard invalidFields.isEmpty, let row = state.draft?.contributions.first(where: { $0.id == id }), row.amount + remaining >= 0 else { return }
        setContribution(id, amount: row.amount + remaining, isDefault: false)
    }
    func promote(_ row: Contribution) {
        guard let plan else { return }
        persist {
            let saved = Contribution(categoryID: row.id, name: row.name, amount: row.amount)
            if let index = $0.defaults[plan.id]?.firstIndex(where: { $0.id == row.id }) { $0.defaults[plan.id]?[index] = saved }
            else { $0.defaults[plan.id, default: []].append(saved) }
        }
        notice = "\(row.name): \(money(row.amount)) saved for future paychecks."
    }
    func saveAllDefaults() {
        guard let plan, let rows = state.draft?.contributions else { return }
        persist { $0.defaults[plan.id] = rows.map { .init(categoryID: $0.id, name: $0.name, amount: $0.amount) } }
        notice = "This allocation is now your default for future paychecks."
    }
    func review() {
        guard let draft = state.draft, let plan, let engine, canReview else { return }
        work { self.reviewed = try await engine.review(draft, plan: plan) }
    }
    func apply() {
        guard let reviewed, let engine else { return }
        self.reviewed = nil
        work {
            self.page = .history
            try await engine.apply(reviewed) { self.sync() }
            self.notice = "Allocation complete. Every contribution was verified in YNAB."
            self.snapshot = nil
        }
    }
    func inspect(_ id: UUID) { work { try await self.engine?.inspect(id); self.notice = "Observed assignments refreshed. Matches are evidence, not proof of which app made a change." } }
    func reconcile(_ id: UUID, note: String) {
        do { try engine?.reconcile(id, note: note); sync(); notice = "Recorded as manually reconciled. This paycheck remains protected against reuse." }
        catch { self.error = error.localizedDescription }
    }
    func exportHistory() {
        guard let store else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Payday-history.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(store.state.history).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { self.error = error.localizedDescription }
        }
    }
}
