import SwiftUI
import PaydayCore

private let forest = Color(red: 0.13, green: 0.29, blue: 0.24)
private let paper = Color(red: 0.97, green: 0.97, blue: 0.94)
private let muted = Color(red: 0.43, green: 0.47, blue: 0.44)

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                if let fatal = model.fatalError {
                    ContentUnavailableView("Payday couldn’t open", systemImage: "lock.shield", description: Text(fatal))
                } else {
                    topbar
                    if let error = model.error { banner(error, symbol: "exclamationmark.triangle.fill", color: .red) }
                    if let notice = model.notice { banner(notice, symbol: "checkmark.circle", color: forest) }
                    if model.busy { ProgressView().progressViewStyle(.linear).tint(forest).accessibilityLabel("Working with YNAB") }
                    Group {
                        switch model.page {
                        case .paycheck: PaycheckView()
                        case .defaults: DefaultsView()
                        case .history: HistoryView()
                        case .connection: ConnectionView()
                        }
                    }.disabled(model.busy)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(paper)
        }
        .tint(forest)
        .sheet(item: $model.reviewed) { ReviewView(operation: $0).environmentObject(model) }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                Image(systemName: "sun.max.fill").font(.system(size: 29, weight: .medium)).foregroundStyle(Color(red: 0.91, green: 0.80, blue: 0.49))
                Text("payday").font(.system(size: 28, weight: .semibold, design: .rounded))
            }.padding(.top, 34).padding(.bottom, 18)
            VStack(spacing: 7) {
                nav(.paycheck, icon: "tray.and.arrow.down")
                nav(.defaults, icon: "slider.horizontal.3")
                nav(.history, icon: "clock.arrow.circlepath")
            }
            Spacer()
            VStack(alignment: .leading, spacing: 9) {
                Text(model.demo ? "PRACTICE MODE" : "YOUR BUDGET").font(.system(size: 10, weight: .bold)).tracking(1.7).opacity(0.6)
                Text(model.plan?.name ?? "Let’s get connected").font(.system(size: 13, weight: .medium)).lineLimit(2)
                Label(model.demo ? "No real money moves" : "Only on this Mac", systemImage: model.demo ? "leaf" : "lock")
                    .font(.system(size: 11)).opacity(0.7)
            }.padding(.horizontal, 12)
            nav(.connection, icon: "gearshape")
        }
        .padding(.horizontal, 18).padding(.bottom, 24)
        .frame(width: 190).frame(maxHeight: .infinity)
        .foregroundStyle(.white).background(forest)
    }
    private func nav(_ page: Page, icon: String) -> some View {
        Button { model.page = page } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).frame(width: 18)
                Text(page.rawValue).font(.system(size: 13, weight: .medium))
                Spacer()
                if page == .history && model.blocked { Circle().fill(.orange).frame(width: 7, height: 7) }
            }.padding(12).background(model.page == page ? .white.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(model.busy).accessibilityLabel(page.rawValue)
    }
    private var topbar: some View {
        HStack {
            Text(model.page == .paycheck ? "A LITTLE ROUTINE. A LOT OF PEACE OF MIND." : "PAYDAY / \(model.page.rawValue.uppercased())")
                .font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(muted)
            Spacer()
            if model.connected {
                Button { model.refresh() } label: { Label("Refresh YNAB", systemImage: "arrow.clockwise") }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(muted).disabled(model.busy)
            }
        }.padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 18)
    }
    private func banner(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { model.error = nil; model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
        }.font(.system(size: 12)).foregroundStyle(color).padding(12).background(color.opacity(0.07)).padding(.horizontal, 24).padding(.bottom, 8)
    }
}

struct PaycheckView: View {
    @EnvironmentObject var model: AppModel
    @State private var adding = false
    @State private var replaceDraft = false
    @State private var saveDefaults = false
    @State private var resetAmounts = false
    var body: some View {
        if !model.connected || model.plan == nil {
            ContentUnavailableView { Label("A calmer payday starts here", systemImage: "sun.max") }
                description: { Text("Connect your YNAB budget to create your first allocation.") }
                actions: { Button("Connect YNAB") { model.page = .connection }.buttonStyle(.borderedProminent) }
        } else if let draft = model.state.draft {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Give this paycheck a purpose.").font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(forest)
                        Text("Start with your usual amounts. Make this payday yours.").font(.system(size: 13)).foregroundStyle(muted)
                    }
                    Spacer()
                    Menu {
                        Button("Start a new paycheck…") { replaceDraft = true }
                        Button("Save this allocation as defaults…") { saveDefaults = true }.disabled(!model.invalidFields.isEmpty)
                        Menu("Link a YNAB deposit") {
                            ForEach(model.incomes) { income in
                                Button("\(income.date) · \(income.name) · \(model.money(income.amount))") { model.chooseIncome(income) }
                                    .disabled(model.state.history.contains { $0.draft.planID == draft.planID && $0.draft.incomeID == income.id })
                            }
                        }
                    }
                    label: { Image(systemName: "ellipsis.circle").font(.title3) }.menuStyle(.borderlessButton).fixedSize()
                }.padding(.bottom, 24)
                paycheckCard(draft)
                HStack {
                    Text("This paycheck’s contributions").font(.system(size: 15, weight: .semibold))
                    Text("\(draft.contributions.count) categories").font(.system(size: 11)).foregroundStyle(muted)
                    Spacer()
                    Button("Use default amounts") { resetAmounts = true }.buttonStyle(.plain).font(.system(size: 12)).disabled(model.defaults.isEmpty)
                    Button { adding = true } label: { Label("Add category", systemImage: "plus") }.buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                }.padding(.top, 25).padding(.bottom, 12)
                if model.remaining != 0 && model.allocated > 0 && model.invalidFields.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkle")
                        Text(model.remaining > 0 ? "An extra \(model.money(model.remaining)) to put to work." : "\(model.money(-model.remaining)) over. Make a quick adjustment.")
                        Spacer()
                        Menu(model.remaining > 0 ? "Put remaining in…" : "Subtract from…") {
                            ForEach(draft.contributions.filter { $0.amount + model.remaining >= 0 }) { row in
                                Button(row.name) { model.useRemainder(row.id) }
                            }
                        }.menuStyle(.borderlessButton).fixedSize()
                    }.font(.system(size: 11)).foregroundStyle(forest).padding(11)
                        .background(forest.opacity(0.06), in: RoundedRectangle(cornerRadius: 8)).padding(.bottom, 12)
                }
                HStack {
                    Text("CATEGORY"); Spacer(); Text("AVAILABLE NOW").frame(width: 112, alignment: .trailing)
                    Text("ADD THIS PAYCHECK").frame(width: 154, alignment: .trailing); Color.clear.frame(width: 42, height: 1)
                }.font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(muted).padding(.horizontal, 16).padding(.bottom, 7)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(draft.contributions) { row in ContributionRow(row: row, isDefault: false) }
                        if draft.contributions.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "tray").font(.largeTitle).foregroundStyle(muted)
                                Text("Where should this paycheck go?").font(.headline)
                                Text("Add categories here, then save your usual amounts as defaults.").foregroundStyle(muted)
                                Button("Add your first category") { adding = true }.buttonStyle(.bordered)
                            }.frame(maxWidth: .infinity).padding(35)
                        }
                    }.background(.white, in: RoundedRectangle(cornerRadius: 12))
                }
                footer(draft)
            }.padding(.horizontal, 32).padding(.bottom, 24)
            .sheet(isPresented: $adding) { CategoryPicker(isDefault: false) }
            .confirmationDialog("Replace these contributions with your defaults?", isPresented: $resetAmounts, titleVisibility: .visible) {
                Button("Use default amounts") { model.resetContributions() }
            } message: { Text("This replaces paycheck-specific category changes. The amount to allocate, date, and reference stay the same.") }
            .confirmationDialog("Replace the saved draft with your defaults?", isPresented: $replaceDraft, titleVisibility: .visible) {
                Button("Start over", role: .destructive) { model.newDraft() }
            } message: { Text("Temporary edits will be discarded. Nothing changes in YNAB.") }
            .confirmationDialog("Use these amounts for future paychecks?", isPresented: $saveDefaults, titleVisibility: .visible) {
                Button("Save as defaults") { model.saveAllDefaults() }
            } message: { Text("This replaces your normal allocation, including its category list.") }
        } else {
            ContentUnavailableView { Label(model.blocked ? "An allocation needs your attention" : "Ready for your next payday", systemImage: model.blocked ? "exclamationmark.shield" : "checkmark.seal") }
            description: { Text(model.blocked ? "Open History to see exactly what happened before you continue." : "Your last allocation is saved in History. A new paycheck starts with your defaults.") }
            actions: { Button(model.blocked ? "Open History" : "New paycheck") { if model.blocked { model.page = .history } else { model.newDraft() } }.buttonStyle(.borderedProminent) }
        }
    }
    private func paycheckCard(_ draft: Draft) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top, spacing: 26) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("AMOUNT TO ALLOCATE").font(.system(size: 9, weight: .bold)).tracking(1.4).foregroundStyle(muted)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(model.plan?.currency ?? "USD").font(.system(size: 13)).foregroundStyle(muted)
                        AmountField(value: draft.amount, fieldID: "paycheck", large: true) { model.setPaycheck($0) }.frame(width: 190)
                    }
                }
                Spacer(minLength: 0)
                metric("ALLOCATED", amount: model.allocated, color: forest)
                Divider().frame(height: 45)
                metric(model.invalidFields.isEmpty ? (model.remaining < 0 ? "OVER-ALLOCATED" : model.remaining == 0 ? "LEFT TO ASSIGN" : "REMAINING") : "CHECK AMOUNTS", amount: abs(model.remaining), color: model.remaining < 0 || !model.invalidFields.isEmpty ? .red : forest)
            }
            Divider()
            HStack(spacing: 12) {
                DatePicker("Received", selection: Binding(get: { dateFrom(draft.date) }, set: { date in model.persist { $0.draft?.date = Dates.day(date); $0.draft?.incomeID = nil } }), in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.field).fixedSize().font(.system(size: 11))
                TextField("Paycheck reference", text: Binding(get: { draft.reference }, set: { value in model.persist { $0.draft?.reference = value } }))
                    .textFieldStyle(.plain).font(.system(size: 12)).frame(maxWidth: 180).help("A unique name for this paycheck on this date, such as your employer. Used to prevent duplicates.")
                Spacer()
                Button { model.useReadyToAssign() } label: { Label("Use Ready to Assign", systemImage: "tray.and.arrow.down") }
                    .font(.system(size: 11)).buttonStyle(.bordered).disabled(model.blocked)
                    .help("Read the currently available amount across your budget, including future-month commitments. This does not apply an allocation.")
            }
        }.padding(20).background(.white, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(forest.opacity(0.09)))
    }
    private func metric(_ title: String, amount: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(muted)
            Text(model.money(amount)).font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(color)
        }
    }
    private func footer(_ draft: Draft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right.circle").foregroundStyle(forest)
                Text("These amounts are added to your categories. Existing money stays put.").foregroundStyle(muted)
            }.font(.system(size: 11)).padding(.top, 12)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Label(status, systemImage: model.remaining == 0 && model.invalidFields.isEmpty ? "checkmark.circle.fill" : "circle.dotted")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(model.remaining < 0 ? .red : forest)
                    Text("\(draft.month.prefix(7)) · Safe Ready to Assign: \(model.snapshot.map { model.money($0.readyToAssign) } ?? "refresh to check")")
                .font(.system(size: 10)).foregroundStyle(muted)
                }
                Spacer()
                Text("Draft saved locally").font(.system(size: 10)).foregroundStyle(muted)
                Button("Review allocation →") { model.review() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canReview).accessibilityIdentifier("review-allocation")
            }
        }
    }
    private var status: String {
        if model.blocked { return "An earlier allocation needs attention" }
        if !model.invalidFields.isEmpty { return "Fix the highlighted amounts" }
        if let ready = model.snapshot?.readyToAssign, let amount = model.state.draft?.amount, ready < amount {
            return "Ready to Assign is short by \(model.money(amount - ready)) · refresh after funding YNAB"
        }
        if model.remaining == 0 && model.allocated > 0 { return "Every dollar has a job" }
        if model.remaining < 0 { return "Reduce contributions by \(model.money(-model.remaining))" }
        return "\(model.money(model.remaining)) still to give a job"
    }
    private func dateFrom(_ string: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: string) ?? Date()
    }
}

struct AmountField: View {
    @EnvironmentObject var model: AppModel
    let value: Int64
    let fieldID: String
    var large = false
    var change: (Int64) -> Void
    @State private var invalid = false
    @State private var focused = false
    var body: some View {
        CentsTextField(value: value, digits: model.plan?.digits ?? 2, large: large,
                       label: fieldID == "paycheck" ? "Amount to allocate" : "Contribution amount", change: change,
                       validity: { valid in
                           invalid = !valid
                           if valid { model.invalidFields.remove(fieldID) } else { model.invalidFields.insert(fieldID) }
                       }, focus: { focused = $0 })
            .id(fieldID == "paycheck" ? model.paycheckInputRevision : fieldID.hasPrefix("draft-") ? model.contributionInputRevision : 0)
            .frame(height: large ? 38 : 20)
            .padding(large ? 0 : 9)
            .background(large ? .clear : paper, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(invalid ? .red : focused ? forest.opacity(0.5) : .clear))
            .help("Type digits and the decimal point moves automatically: 1 → 0.01, 10 → 0.10, 100 → 1.00. Clicking selects the current amount.")
            .onChange(of: value) { _, _ in invalid = false; model.invalidFields.remove(fieldID) }
    }
}

struct ContributionRow: View {
    @EnvironmentObject var model: AppModel
    let row: Contribution
    let isDefault: Bool
    @State private var promote = false
    private var category: BudgetCategory? { model.snapshot?.categories.first { $0.id == row.id } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if isDefault {
                    Image(systemName: "line.3.horizontal").foregroundStyle(muted).frame(width: 20)
                        .draggable(row.id).help("Drag to reorder \(row.name)")
                        .accessibilityLabel("Reorder \(row.name)")
                }
                Image(systemName: isDefault ? "repeat" : "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(forest)
                    .frame(width: 30, height: 30).background(forest.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text(category?.name ?? row.name).font(.system(size: 13, weight: .medium))
                    if category?.eligible != true {
                        Text("Unavailable in YNAB · remove or replace").foregroundStyle(.red).font(.system(size: 10))
                    } else if !isDefault && row.amount != row.normal {
                        Text(model.defaults.first(where: { $0.id == row.id })?.amount == row.amount ? "Saved as your new default" : row.normal == 0 ? "One-off contribution" : "Usually \(model.money(row.normal)) · this paycheck only").foregroundStyle(muted).font(.system(size: 10))
                    } else { Text(category?.group ?? "").font(.system(size: 10)).foregroundStyle(muted) }
                }
                Spacer(minLength: 4)
                if !isDefault { Text(category.map { model.money($0.balance) } ?? "—").font(.system(size: 12)).monospacedDigit().foregroundStyle(muted).frame(width: 112, alignment: .trailing) }
                HStack(spacing: 4) {
                    if !isDefault { Text("+").foregroundStyle(muted) }
                    AmountField(value: row.amount, fieldID: (isDefault ? "default-" : "draft-") + row.id) { model.setContribution(row.id, amount: $0, isDefault: isDefault) }
                }.frame(width: 142)
                Menu {
                    if isDefault {
                        Button("Move up") { model.moveDefault(row.id, by: -1) }.disabled(model.defaults.first?.id == row.id)
                        Button("Move down") { model.moveDefault(row.id, by: 1) }.disabled(model.defaults.last?.id == row.id)
                        Divider()
                    }
                    if !isDefault {
                        Button(model.remaining < 0 ? "Subtract over-allocation here" : "Add remaining here") { model.useRemainder(row.id) }
                            .disabled(model.remaining == 0 || row.amount + model.remaining < 0 || !model.invalidFields.isEmpty)
                        Button("Make this amount the default…") { promote = true }.disabled(!model.invalidFields.isEmpty)
                        Divider()
                    }
                    Button("Remove category", role: .destructive) { model.removeCategory(row.id, isDefault: isDefault) }
                } label: { Image(systemName: "ellipsis").frame(width: 22) }.menuStyle(.borderlessButton).fixedSize()
            }.padding(.horizontal, 15).padding(.vertical, 10)
            Divider().padding(.leading, 57)
        }
        .confirmationDialog("Save \(model.money(row.amount)) as the default for \(row.name)?", isPresented: $promote, titleVisibility: .visible) {
            Button("Save default") { model.promote(row) }
        } message: { Text("Future paychecks will start with this contribution.") }
    }
}

struct CategoryPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let isDefault: Bool
    @State private var search = ""
    @State private var added: Set<String> = []
    private var choices: [BudgetCategory] {
        let existing = Set((isDefault ? model.defaults : model.state.draft?.contributions ?? []).map(\.id))
        return (model.snapshot?.categories ?? []).filter { $0.eligible && (!existing.contains($0.id) || added.contains($0.id)) && (search.isEmpty || "\($0.group) \($0.name)".localizedCaseInsensitiveContains(search)) }
            .sorted { ($0.group, $0.name) < ($1.group, $1.name) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add categories").font(.title2.weight(.semibold))
            Text(isDefault ? "Choose as many categories as you like, then click Done. Set their amounts on the Defaults page." : "Choose categories for this paycheck, then click Done. These stay one-off unless saved as defaults.").foregroundStyle(.secondary)
            TextField("Search categories or groups", text: $search).textFieldStyle(.roundedBorder)
            List(choices) { category in
                Button {
                    model.addCategory(category, isDefault: isDefault)
                    if (isDefault ? model.defaults : model.state.draft?.contributions ?? []).contains(where: { $0.id == category.id }) { added.insert(category.id) }
                } label: {
                    HStack { VStack(alignment: .leading) { Text(category.name); Text(category.group).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: added.contains(category.id) ? "checkmark.circle.fill" : "plus.circle") }.padding(.vertical, 3)
                }.buttonStyle(.plain)
                    .disabled(added.contains(category.id))
            }.overlay { if choices.isEmpty { Text("No available categories match.").foregroundStyle(.secondary) } }
            HStack {
                Text("\(added.count) added").font(.caption).foregroundStyle(.secondary)
                Spacer(); Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 460, height: 480)
    }
}

struct DefaultsView: View {
    @EnvironmentObject var model: AppModel
    @State private var adding = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your usual payday.").font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(forest)
            Text("These categories and amounts automatically populate your paycheck. Changes flow into unadjusted contributions; paycheck-specific edits stay intact. Drag the handles to set the order.")
                .font(.system(size: 13)).foregroundStyle(muted)
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("DEFAULT PAYCHECK TOTAL").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(muted)
                    Text(model.money((try? Money.total(model.defaults.map(\.amount))) ?? 0)).font(.system(size: 30, weight: .medium, design: .rounded)).foregroundStyle(forest)
                }
                Spacer()
                Button { adding = true } label: { Label("Add category", systemImage: "plus") }.buttonStyle(.bordered).disabled(model.snapshot == nil)
            }.padding(20).background(.white, in: RoundedRectangle(cornerRadius: 12))
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.defaults) { row in
                        ContributionRow(row: row, isDefault: true)
                            .dropDestination(for: String.self) { ids, _ in
                                guard let id = ids.first, model.defaults.contains(where: { $0.id == id }) else { return false }
                                model.moveDefault(id, to: row.id)
                                return true
                            }
                    }
                }
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                if model.defaults.isEmpty { ContentUnavailableView("Build your starting point", systemImage: "slider.horizontal.3", description: Text("Add the categories you normally fund from a paycheck.")) }
            }
            Label("Saved automatically on this Mac. No changes are sent to YNAB.", systemImage: "lock").font(.system(size: 11)).foregroundStyle(muted)
        }.padding(.horizontal, 32).padding(.bottom, 28)
        .sheet(isPresented: $adding) { CategoryPicker(isDefault: true) }
    }
}

struct ReviewView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let operation: AllocationOperation
    @State private var acknowledged = false
    private var similar: Bool {
        model.state.history.contains { $0.draft.planID == operation.plan.id && $0.draft.amount == operation.draft.amount && $0.draft.date == operation.draft.date }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Label("Ready when you are.", systemImage: "checkmark.shield").font(.system(size: 25, weight: .semibold, design: .rounded)).foregroundStyle(forest)
            Text("Add \(model.money(operation.draft.amount)) to \(operation.plan.name) · \(operation.draft.month.prefix(7))")
                .font(.headline)
            Text("\(operation.draft.date) · \(operation.draft.reference)").foregroundStyle(muted)
            HStack {
                Label("Every dollar allocated", systemImage: "checkmark.circle.fill").foregroundStyle(forest)
                Spacer()
                Text("Ready to Assign: \(model.money(operation.readyBefore))").foregroundStyle(muted)
            }.font(.system(size: 12))
            Divider()
            HStack { Text("CATEGORY"); Spacer(); Text("CONTRIBUTION").frame(width: 130, alignment: .trailing); Text("AVAILABLE AFTER*").frame(width: 150, alignment: .trailing) }
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(muted)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(operation.steps) { step in
                        HStack {
                            Text(step.contribution.name); Spacer()
                            Text("+\(model.money(step.contribution.amount))").fontWeight(.semibold).frame(width: 130, alignment: .trailing)
                            Text(model.money(step.beforeBalance + step.contribution.amount)).foregroundStyle(muted).frame(width: 150, alignment: .trailing)
                        }.font(.system(size: 13)).monospacedDigit()
                    }
                }
            }.frame(minHeight: 100, maxHeight: 270)
            Text("*Assuming no new spending. Your contribution is added to the existing assigned amount; category balances do not set the contribution.").font(.system(size: 11)).foregroundStyle(muted)
            if similar { Label("Another paycheck with this date and amount appears in History. Verify that this is a separate deposit.", systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange) }
            Text("YNAB updates one category at a time. If anything is uncertain, Payday stops and records what happened. Keep YNAB unchanged on other devices while this runs.")
                .font(.system(size: 12)).padding(12).background(paper, in: RoundedRectangle(cornerRadius: 8))
            Toggle("These funds are already in YNAB’s Ready to Assign, and I haven’t allocated them before.", isOn: $acknowledged).font(.system(size: 12)).toggleStyle(.checkbox)
            HStack {
                Button("Back to edit") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.demo ? "Apply to practice budget" : "Confirm & apply \(model.money(operation.draft.amount))") { model.apply() }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!acknowledged || model.busy)
            }
        }.padding(28).frame(width: 660).interactiveDismissDisabled(model.busy)
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Every payday, accounted for.").font(.system(size: 27, weight: .semibold, design: .rounded)).foregroundStyle(forest)
                Spacer()
                Button { model.exportHistory() } label: { Image(systemName: "square.and.arrow.up") }.help("Export financial allocation history as JSON")
            }
            Text("A record of your contributions. YNAB remains the source of truth for your budget.").font(.system(size: 13)).foregroundStyle(muted)
            TextField("Search a paycheck, category, or date", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(model.state.history.filter { op in search.isEmpty || "\(op.draft.reference) \(op.draft.date) \(op.plan.name) \((op.steps.map { $0.contribution.name } + (op.draft.normalContributions ?? []).map(\.name)).joined(separator: " "))".localizedCaseInsensitiveContains(search) }) { operation in
                        HistoryCard(operation: operation)
                    }
                    if model.state.history.isEmpty { ContentUnavailableView("Your next payday starts the story", systemImage: "clock", description: Text("Confirmed allocations and interrupted attempts will appear here.")) }
                }
            }
        }.padding(.horizontal, 32).padding(.bottom, 24)
    }
}

struct HistoryCard: View {
    @EnvironmentObject var model: AppModel
    let operation: AllocationOperation
    @State private var expanded = false
    @State private var note = ""
    @State private var confirmReconciliation = false
    private func money(_ amount: Int64) -> String { Money.format(amount, currency: operation.plan.currency, digits: operation.plan.digits) }
    private var label: String {
        switch operation.status { case .applying: return "Applying…"; case .completed: return "Verified"; case .needsAttention: return "Needs attention"; case .reconciled: return "Manually reconciled" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { expanded.toggle() } label: {
                HStack {
                    Image(systemName: operation.status == .completed ? "checkmark.circle.fill" : operation.blocksWrites ? "exclamationmark.triangle.fill" : "text.badge.checkmark")
                        .font(.title2).foregroundStyle(operation.blocksWrites ? .orange : forest)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(operation.draft.reference).font(.system(size: 14, weight: .semibold))
                        Text("\(operation.draft.date) · \(operation.plan.name) · \(label)").font(.system(size: 11)).foregroundStyle(muted)
                    }
                    Spacer()
                    Text(money(operation.draft.amount)).font(.system(size: 20, weight: .medium, design: .rounded))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                }
            }.buttonStyle(.plain)
            if expanded || operation.blocksWrites {
                Divider()
                Text("Budget month \(operation.draft.month.prefix(7)) · \(operation.id.uuidString.prefix(8))").font(.caption).foregroundStyle(muted).textSelection(.enabled)
                if let message = operation.message { Text(message).font(.system(size: 12)).foregroundStyle(operation.blocksWrites ? .orange : muted) }
                ForEach(operation.steps) { step in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(step.contribution.name).fontWeight(.medium)
                            Spacer()
                            Text("+\(money(step.contribution.amount))").monospacedDigit()
                            Text(stepLabel(step.status)).foregroundStyle(step.status == .uncertain || step.status == .sending ? .orange : muted).frame(width: 100, alignment: .trailing)
                        }
                        Text("Normal \(money(step.contribution.normal)) · Change \(money(step.contribution.amount - step.contribution.normal))")
                            .font(.system(size: 10)).foregroundStyle(muted)
                        if operation.blocksWrites || operation.status == .reconciled {
                            Text("Assigned before \(money(step.beforeBudgeted)) → intended \(money(step.targetBudgeted)) · last observed \(step.observation.map(money) ?? "unknown")")
                                .font(.system(size: 10)).foregroundStyle(muted).textSelection(.enabled)
                        }
                    }.font(.system(size: 12)).padding(.vertical, 3)
                }
                ForEach((operation.draft.normalContributions ?? []).filter { normal in normal.amount > 0 && !operation.steps.contains(where: { $0.id == normal.id }) }) { omitted in
                    HStack {
                        Text(omitted.name); Spacer()
                        Text("Not funded · normally \(money(omitted.amount))").foregroundStyle(muted)
                    }.font(.system(size: 11))
                }
                if let note = operation.reconciliationNote { Text("Your reconciliation: \(note)").font(.system(size: 12)).textSelection(.enabled) }
                if operation.blocksWrites && operation.status != .applying {
                    Divider()
                    Text("No automatic retry. Check this month’s Assigned amounts and recent money moves in YNAB. Resolve missing or uncertain contributions there. A matching amount alone cannot prove a request succeeded; if a request may still be pending, wait and verify again before reconciling.")
                        .font(.system(size: 12)).foregroundStyle(muted)
                    Button("Read current YNAB assignments") { model.inspect(operation.id) }.disabled(!model.connected)
                    TextField("Describe what you checked or corrected in YNAB", text: $note, axis: .vertical).textFieldStyle(.roundedBorder)
                    Button("Record manual reconciliation…") { confirmReconciliation = true }
                        .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).count < 12 || !model.connected)
                }
            }
        }.padding(20).background(.white, in: RoundedRectangle(cornerRadius: 12))
        .confirmationDialog("Have you finished reconciling this paycheck in YNAB?", isPresented: $confirmReconciliation, titleVisibility: .visible) {
            Button("Record as manually reconciled") { model.reconcile(operation.id, note: note) }
        } message: { Text("This sends no money, does not retry any step, and does not mark uncertain steps as successful. It records your note and permits future paychecks. This paycheck stays reserved in History.") }
    }
    private func stepLabel(_ status: StepStatus) -> String {
        switch status { case .pending: return "Not attempted"; case .sending: return "In flight"; case .verified: return "Confirmed"; case .uncertain: return "Uncertain" }
    }
}

struct ConnectionView: View {
    @EnvironmentObject var model: AppModel
    @State private var token = ""
    @State private var switching: Plan?
    @State private var confirmSwitch = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(model.demo ? "Room to practice." : "Your budget. Your Mac.").font(.system(size: 30, weight: .semibold, design: .rounded)).foregroundStyle(forest)
                Text(model.demo ? "This is a separate sample budget. Try an entire payday, including confirmation, without touching YNAB." : "Connect directly to YNAB. Your access token stays in macOS Keychain; your defaults and history stay on this Mac.")
                    .font(.system(size: 14)).foregroundStyle(muted)
                if !model.demo {
                    VStack(alignment: .leading, spacing: 14) {
                        Label(model.connected ? "YNAB connected" : "Connect to YNAB", systemImage: "key.horizontal").font(.headline)
                        Text("Create a Personal Access Token in your YNAB account’s Developer Settings, then paste it below. Use only a token for your own account.").font(.system(size: 13)).foregroundStyle(muted)
                        Link("Open YNAB Developer Settings ↗", destination: URL(string: "https://app.ynab.com/settings/developer")!)
                        SecureField("Personal access token", text: $token).textFieldStyle(.roundedBorder)
                        HStack {
                            Button(model.connected ? "Replace token" : "Connect securely") { model.connect(token); token = "" }.buttonStyle(.borderedProminent).disabled(token.isEmpty)
                            if model.connected { Button("Disconnect") { model.disconnect() } }
                        }
                        Text("Disconnect removes the saved token. Defaults and audit history are retained.").font(.caption).foregroundStyle(muted)
                    }.padding(22).background(.white, in: RoundedRectangle(cornerRadius: 12))
                }
                if model.connected {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Choose your budget").font(.headline)
                        if model.plans.isEmpty { Button("Load budgets") { model.refresh() } }
                        ForEach(model.plans) { plan in
                            Button {
                                if model.plan != nil && model.state.draft != nil { switching = plan; confirmSwitch = true }
                                else { model.selectPlan(plan) }
                            } label: {
                                HStack {
                                    Image(systemName: model.plan?.id == plan.id ? "checkmark.circle.fill" : "circle")
                                    Text(plan.name); Spacer(); Text(plan.currency).foregroundStyle(muted)
                                }.padding(12).background(paper, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).disabled(model.blocked)
                        }
                    }.padding(22).background(.white, in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 12) {
                    Label("A small app with a careful job", systemImage: "lock.shield").font(.headline)
                    Text("Payday adds contributions to the current budget month. Your paycheck must already be in Ready to Assign. Nothing is sent until you review and confirm.")
                    Text("A linked deposit is the strongest duplicate check. Manual paychecks are identified by budget, date, and reference. Payday cannot detect assignments made outside this app or recover duplicate protection from deleted history.")
                    Text("Financial history is stored in a private local folder, without application-level encryption. macOS FileVault protects it at rest. Exported history also contains financial information.")
                    if let directory = model.store?.directory {
                        Button("Show local data in Finder") { NSWorkspace.shared.open(directory) }
                    }
                    Text("Independent software; not affiliated with or endorsed by YNAB.").font(.caption)
                }.font(.system(size: 12)).foregroundStyle(muted)
            }.padding(.horizontal, 32).padding(.bottom, 30)
        }
        .confirmationDialog("Switch budgets and replace the current draft?", isPresented: $confirmSwitch, titleVisibility: .visible) {
            Button("Use this budget") { if let switching { model.selectPlan(switching) } }
        } message: { Text("Each budget keeps its own defaults. History is retained. Nothing changes in YNAB.") }
    }
}
