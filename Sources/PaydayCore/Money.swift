import Foundation

/// YNAB stores amounts as integer thousandths of a currency unit.
public enum Money {
    public static let limit: Int64 = 1_000_000_000_000

    /// Digit entry shifts through minor units: 1 -> 0.01, 10 -> 0.10.
    /// The existing decimal separator is presentation; pasted 123.45 is 123.45.
    public static func minorUnitEntry(_ text: String, digits: Int = 2) throws -> Int64 {
        guard (0...3).contains(digits) else { throw AppError("Unsupported currency precision.") }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return 0 }
        guard text.filter({ $0 == "." }).count <= 1,
              text.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." }),
              let minor = Int64(text.filter({ $0 != "." })) else {
            throw AppError("Enter digits only; the decimal point is placed automatically.")
        }
        let scale: Int64 = [1000, 100, 10, 1][digits]
        guard minor >= 0, minor <= limit / scale else { throw AppError("That amount is too large.") }
        return minor * scale
    }

    public static func parse(_ text: String, digits: Int = 2) throws -> Int64 {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (0...3).contains(digits), !value.isEmpty else { throw AppError("Enter an amount.") }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, !parts[0].isEmpty,
              parts.allSatisfy({ $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              parts.count == 1 || parts[1].count <= digits,
              let whole = Int64(parts[0]), whole <= limit / 1000 else {
            throw AppError("Use a positive amount with up to \(digits) decimal places (for example, 400\(digits > 0 ? "." + String(repeating: "0", count: digits) : "")).")
        }
        let fractional = parts.count == 2 ? String(parts[1]) : ""
        let fraction = Int64(fractional + String(repeating: "0", count: 3 - fractional.count)) ?? 0
        let amount = whole * 1000 + fraction
        guard amount <= limit else { throw AppError("That amount is too large.") }
        return amount
    }

    public static func input(_ amount: Int64, digits: Int = 2) -> String {
        let absolute = abs(amount)
        let fraction = String(format: "%03lld", absolute % 1000).prefix(digits)
        return "\(amount < 0 ? "-" : "")\(absolute / 1000)" + (digits > 0 ? ".\(fraction)" : "")
    }

    public static func format(_ amount: Int64, currency: String = "USD", digits: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = max(digits, amount % 10 == 0 ? digits : 3)
        return formatter.string(from: NSDecimalNumber(value: amount).dividing(by: 1000)) ?? input(amount, digits: 3)
    }

    public static func total(_ values: [Int64]) throws -> Int64 {
        var total: Int64 = 0
        for value in values {
            guard value >= 0, value <= limit else { throw AppError("Contributions must be nonnegative and within the supported range.") }
            let result = total.addingReportingOverflow(value)
            guard !result.overflow, result.partialValue <= limit else { throw AppError("The allocation is too large.") }
            total = result.partialValue
        }
        return total
    }
}

public struct AppError: LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
