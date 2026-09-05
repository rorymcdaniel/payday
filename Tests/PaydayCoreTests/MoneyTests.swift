import XCTest
@testable import PaydayCore

final class MoneyTests: XCTestCase {
    func testExactDecimalMath() throws {
        XCTAssertEqual(try Money.parse("4123.72"), 4_123_720)
        XCTAssertEqual(try Money.parse("0.01"), 10)
        XCTAssertEqual(try Money.parse("400"), 400_000)
        XCTAssertEqual(try Money.total([10, 20]), 30)
        XCTAssertEqual(try Money.parse("4123.72") - Money.parse("4075"), 48_720)
    }
    func testZeroAndThreeDecimalCurrencies() throws {
        XCTAssertEqual(try Money.parse("200", digits: 0), 200_000)
        XCTAssertThrowsError(try Money.parse("200.1", digits: 0))
        XCTAssertEqual(try Money.parse("12.345", digits: 3), 12_345)
        XCTAssertEqual(Money.input(12_345, digits: 3), "12.345")
    }
    func testMalformedNegativeAndOverflowInputRejected() {
        for value in ["", "-1", "+2", "1,000", "$100", "1e3", "NaN", "Infinity", "0.001", "1.2.3", "１２", "999999999999999999999999", "1000000000.01"] {
            XCTAssertThrowsError(try Money.parse(value), "Accepted invalid input: \(value)")
        }
        XCTAssertThrowsError(try Money.total([Money.limit, 1]))
        XCTAssertThrowsError(try Money.total([-1]))
        XCTAssertThrowsError(try Money.total([Int64.max]))
    }
    func testNoBinaryFloatingPointDriftAcrossManyContributions() throws {
        XCTAssertEqual(try Money.total(Array(repeating: Money.parse("0.01"), count: 100)), 1000)
    }
}
