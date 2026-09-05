import XCTest
@testable import PaydayCore

private final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, headers, body) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class APIContractTests: XCTestCase {
    private func client() -> YNABClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return YNABClient(token: "test-token", session: URLSession(configuration: config))
    }
    private func response(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: ["data": object]) }
    private func category(_ id: String = "food", internalValue: Bool = false) -> [String: Any] {
        ["id": id, "name": "Groceries", "category_group_id": "group", "budgeted": 500000,
         "balance": 35000, "hidden": false, "deleted": false, "internal": internalValue]
    }
    private func snapshotHandler(future: Int64, missingMonth: Bool = false) -> (URLRequest) throws -> (Int, [String: String], Data) {
        { request in
            XCTAssertEqual(request.url?.host, "api.ynab.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.httpMethod, "GET")
            switch request.url!.path {
            case "/v1/plans/budget/months/2026-09-01":
                return (200, [:], try self.response(["month": ["month": "2026-09-01", "to_be_budgeted": 1000000, "categories": [self.category(), self.category("internal", internalValue: true)]]]))
            case "/v1/plans/budget/months":
                var months: [[String: Any]] = [["month": "2026-10-01", "to_be_budgeted": future]]
                if !missingMonth { months.append(["month": "2026-09-01", "to_be_budgeted": 1000000]) }
                return (200, [:], try self.response(["months": months]))
            case "/v1/plans/budget/categories":
                return (200, [:], try self.response(["category_groups": [["id": "group", "name": "Living", "hidden": false, "deleted": false, "internal": false]]]))
            default: throw AppError("Unexpected route")
            }
        }
    }
    func testFutureMonthReadyToAssignLimitsCurrentAllocation() async throws {
        StubProtocol.handler = snapshotHandler(future: 150000)
        let snapshot = try await client().snapshot(planID: "budget", month: "2026-09-01")
        XCTAssertEqual(snapshot.readyToAssign, 150000)
        XCTAssertEqual(snapshot.categories.first?.budgeted, 500000)
        XCTAssertEqual(snapshot.categories.first?.balance, 35000)
        XCTAssertEqual(snapshot.categories.map(\.eligible), [true, false])
    }
    func testNegativeFutureMonthRemainsNegative() async throws {
        StubProtocol.handler = snapshotHandler(future: -12000)
        let value = try await client().snapshot(planID: "budget", month: "2026-09-01")
        XCTAssertEqual(value.readyToAssign, -12000)
    }
    func testMissingSelectedMonthFailsClosed() async {
        StubProtocol.handler = snapshotHandler(future: 1000000, missingMonth: true)
        do { _ = try await client().snapshot(planID: "budget", month: "2026-09-01"); XCTFail("Expected failure") } catch {}
    }
    func testPatchSendsOnlyAbsoluteBudgetedMilliunits() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.path, "/v1/plans/budget/months/2026-09-01/categories/food")
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(buffer, count: count) }
            }
            let body = try JSONSerialization.jsonObject(with: bytes) as! [String: [String: Int64]]
            XCTAssertEqual(body, ["category": ["budgeted": 900000]])
            var category = self.category(); category["budgeted"] = 900000
            return (200, [:], try self.response(["category": category]))
        }
        let result = try await client().assign(planID: "budget", month: "2026-09-01", categoryID: "food", budgeted: 900000)
        XCTAssertEqual(result, 900000)
    }
    func testRateLimitPreflightUsesServerHeader() async throws {
        StubProtocol.handler = { _ in (200, ["X-Rate-Limit": "190/200"], try self.response(["plans": []])) }
        let api = client(); _ = try await api.plans()
        XCTAssertThrowsError(try api.checkWriteCapacity(categoryCount: 3))
        XCTAssertNoThrow(try api.checkWriteCapacity(categoryCount: 2))
    }
    func testHTTPFailureIsNotRetriedAndDoesNotExposeBodyOrToken() async {
        var calls = 0
        StubProtocol.handler = { _ in calls += 1; return (500, [:], Data("sensitive-server-body".utf8)) }
        do { _ = try await client().assign(planID: "budget", month: "2026-09-01", categoryID: "food", budgeted: 1); XCTFail("Expected failure") }
        catch { XCTAssertFalse(error.localizedDescription.contains("sensitive-server-body")); XCTAssertFalse(error.localizedDescription.contains("test-token")) }
        XCTAssertEqual(calls, 1)
    }
    func testCurrencyMetadataRequired() async {
        StubProtocol.handler = { _ in (200, [:], try self.response(["plans": [["id": "budget", "name": "Budget", "currency_format": NSNull()]]])) }
        do { _ = try await client().plans(); XCTFail("Expected failure") } catch {}
    }
    func testInvalidPathIsRejectedBeforeTransport() async {
        var calls = 0
        StubProtocol.handler = { _ in calls += 1; throw AppError("Unexpected request") }
        do { _ = try await client().snapshot(planID: "../other", month: "2026-09-01"); XCTFail("Expected failure") } catch {}
        XCTAssertEqual(calls, 0)
    }
    func testRecentDepositEligibilityAndImportedIdentity() async throws {
        StubProtocol.handler = { request in
            if request.url!.path.hasSuffix("/accounts") {
                return (200, [:], try self.response(["accounts": [
                    ["id": "checking", "on_budget": true, "deleted": false],
                    ["id": "tracking", "on_budget": false, "deleted": false]
                ]]))
            }
            XCTAssertNotNil(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "since_date" })
            let original: [String: Any] = ["id": "income", "date": Dates.day(), "amount": 475000, "account_id": "checking", "payee_name": "Employer", "deleted": false, "subtransactions": [], "matched_transaction_id": "original", "import_id": "bank-import"]
            var rows = [original]
            for (key, value) in [("amount", -1 as Any), ("account_id", "tracking" as Any), ("transfer_account_id", "other" as Any), ("subtransactions", [["id": "split"]] as Any), ("deleted", true as Any), ("date", "2999-01-01" as Any)] {
                var excluded = original; excluded[key] = value; rows.append(excluded)
            }
            return (200, [:], try self.response(["transactions": rows]))
        }
        let deposits = try await client().incomes(planID: "budget")
        XCTAssertEqual(deposits.count, 1)
        XCTAssertEqual(deposits.first?.identityKeys, Set(["income", "original", "import:checking:bank-import"]))
    }
}
