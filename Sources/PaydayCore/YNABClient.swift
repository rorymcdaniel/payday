import Foundation

public protocol BudgetAPI {
    func plans() async throws -> [Plan]
    func snapshot(planID: String, month: String) async throws -> Snapshot
    func incomes(planID: String) async throws -> [Income]
    func assign(planID: String, month: String, categoryID: String, budgeted: Int64) async throws -> Int64
    func checkWriteCapacity(categoryCount: Int) throws
}

public extension BudgetAPI {
    func checkWriteCapacity(categoryCount: Int) throws {}
}

/// Ephemeral HTTPS session: no cookies, disk cache, response logging, or write retries.
public final class YNABClient: BudgetAPI {
    private let token: String
    private let session: URLSession
    private var requestsRemaining: Int?
    public init(token: String, session: URLSession? = nil) {
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 40
        self.session = session ?? URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }

    public func plans() async throws -> [Plan] {
        let data: PlansData = try await request("plans")
        return try data.plans.map {
            guard let currency = $0.currency_format, (0...3).contains(currency.decimal_digits) else {
                throw AppError("YNAB did not supply a supported currency format for \($0.name). Set its currency in YNAB first.")
            }
            return Plan(id: $0.id, name: $0.name, currency: currency.iso_code, digits: currency.decimal_digits)
        }
    }

    public func snapshot(planID: String, month: String) async throws -> Snapshot {
        let prefix = "plans/\(try component(planID))"
        let detail: MonthData = try await request("\(prefix)/months/\(try component(month))")
        let months: MonthsData = try await request("\(prefix)/months")
        let groups: GroupsData = try await request("\(prefix)/categories")
        guard detail.month.month == month, months.months.contains(where: { $0.month == month }) else {
            throw AppError("YNAB did not return the requested budget month. Refresh before continuing.")
        }
        // Taking the minimum is intentionally conservative, including future allocations.
        let ready = min(detail.month.to_be_budgeted, months.months.filter { $0.month >= month }.map(\.to_be_budgeted).min() ?? Int64.min)
        let categories = detail.month.categories.map { category in
            let group = groups.category_groups.first { $0.id == category.category_group_id }
            return BudgetCategory(id: category.id, name: category.name, group: group?.name ?? "Unavailable",
                            budgeted: category.budgeted, balance: category.balance,
                            eligible: !category.hidden && !category.deleted && !category.internalCategory &&
                                group != nil && group?.hidden == false && group?.deleted == false && group?.internalGroup == false)
        }
        guard Set(categories.map(\.id)).count == categories.count,
              categories.allSatisfy({ (-Money.limit...Money.limit).contains($0.budgeted) && (-Money.limit...Money.limit).contains($0.balance) }),
              (-Money.limit...Money.limit).contains(ready) else { throw AppError("YNAB returned unsupported or duplicate amounts. No changes were sent.") }
        return Snapshot(month: month, readyToAssign: ready, categories: categories)
    }

    public func incomes(planID: String) async throws -> [Income] {
        let prefix = "plans/\(try component(planID))"
        let since = Dates.day(Calendar.current.date(byAdding: .day, value: -60, to: Date())!)
        let accounts: AccountsData = try await request("\(prefix)/accounts")
        let data: TransactionsData = try await request("\(prefix)/transactions?since_date=\(since)")
        let budgetAccounts = Set(accounts.accounts.filter { $0.on_budget && !$0.deleted }.map(\.id))
        return data.transactions.filter {
            !$0.deleted && $0.amount > 0 && $0.amount <= Money.limit && $0.date <= Dates.day() &&
            $0.transfer_account_id == nil && $0.subtransactions.isEmpty && budgetAccounts.contains($0.account_id)
        }.map {
            var aliases = [$0.matched_transaction_id].compactMap { $0 }
            if let imported = $0.import_id { aliases.append("import:\($0.account_id):\(imported)") }
            return Income(id: $0.id, date: $0.date, name: $0.payee_name ?? "Income", amount: $0.amount, aliases: aliases)
        }
            .sorted { $0.date > $1.date }
    }

    public func assign(planID: String, month: String, categoryID: String, budgeted: Int64) async throws -> Int64 {
        let body = try JSONEncoder().encode(PatchBody(category: .init(budgeted: budgeted)))
        let result: CategoryData = try await request("plans/\(try component(planID))/months/\(try component(month))/categories/\(try component(categoryID))", method: "PATCH", body: body)
        guard result.category.id == categoryID else { throw AppError("YNAB returned a different category. The write outcome is uncertain.") }
        return result.category.budgeted
    }

    public func checkWriteCapacity(categoryCount: Int) throws {
        // Each step needs a PATCH plus three reads; the final verification also
        // needs three reads. The initial snapshot has already been fetched.
        let needed = categoryCount * 4
        guard needed <= (requestsRemaining ?? 190) else {
            throw AppError("This allocation needs about \(needed) more API requests to apply and verify safely. YNAB allows 200 per hour. Wait for capacity to recover, or reduce the number of categories before trying again.")
        }
    }

    private func component(_ value: String) throws -> String {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { throw AppError("Invalid YNAB identifier.") }
        return value
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        var request = URLRequest(url: URL(string: "https://api.ynab.com/v1/" + path)!)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw AppError("Could not reach YNAB. Check your connection. If this happened during an assignment, inspect its history before proceeding.") }
        guard let http = response as? HTTPURLResponse else { throw AppError("YNAB returned an invalid response.") }
        if let rate = http.value(forHTTPHeaderField: "X-Rate-Limit") {
            let parts = rate.split(separator: "/")
            if parts.count == 2, let used = Int(parts[0]), let limit = Int(parts[1]) { requestsRemaining = max(0, limit - used) }
        }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 403: throw AppError("YNAB denied access. Check your token in Connection settings; it needs write access.")
            case 429: throw AppError("YNAB’s hourly request limit has been reached. Wait before refreshing. Any interrupted assignment requires review in History.")
            case 404: throw AppError("The requested plan, month, or category no longer exists in YNAB.")
            default: throw AppError("YNAB returned HTTP \(http.statusCode). Inspect History if an assignment was in progress.")
            }
        }
        do { return try JSONDecoder().decode(Envelope<T>.self, from: data).data }
        catch { throw AppError("YNAB returned a response Payday could not verify. Inspect History if an assignment was in progress.") }
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
private struct Envelope<T: Decodable>: Decodable { var data: T }
private struct CurrencyDTO: Decodable { var iso_code: String; var decimal_digits: Int }
private struct PlanDTO: Decodable { var id: String; var name: String; var currency_format: CurrencyDTO? }
private struct PlansData: Decodable { var plans: [PlanDTO] }
private struct MonthSummaryDTO: Decodable { var month: String; var to_be_budgeted: Int64 }
private struct MonthsData: Decodable { var months: [MonthSummaryDTO] }
private struct MonthDTO: Decodable { var month: String; var to_be_budgeted: Int64; var categories: [CategoryDTO] }
private struct MonthData: Decodable { var month: MonthDTO }
private struct CategoryDTO: Decodable {
    var id: String; var name: String; var category_group_id: String
    var budgeted: Int64; var balance: Int64; var hidden: Bool; var deleted: Bool
    var internalCategory: Bool
    enum CodingKeys: String, CodingKey { case id, name, category_group_id, budgeted, balance, hidden, deleted; case internalCategory = "internal" }
}
private struct GroupDTO: Decodable {
    var id: String; var name: String; var hidden: Bool; var deleted: Bool; var internalGroup: Bool
    enum CodingKeys: String, CodingKey { case id, name, hidden, deleted; case internalGroup = "internal" }
}
private struct GroupsData: Decodable { var category_groups: [GroupDTO] }
private struct CategoryData: Decodable { var category: CategoryDTO }
private struct PatchBody: Encodable { struct Value: Encodable { var budgeted: Int64 }; var category: Value }
private struct AccountDTO: Decodable { var id: String; var on_budget: Bool; var deleted: Bool }
private struct AccountsData: Decodable { var accounts: [AccountDTO] }
private struct TransactionDTO: Decodable {
    var id: String; var date: String; var amount: Int64; var account_id: String; var payee_name: String?
    var deleted: Bool; var transfer_account_id: String?; var subtransactions: [Subtransaction]
    var matched_transaction_id: String?; var import_id: String?
    struct Subtransaction: Decodable { var id: String }
}
private struct TransactionsData: Decodable { var transactions: [TransactionDTO] }
