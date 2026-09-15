import Foundation

/// An exact quantity of an asset, held in integer minor units.
///
/// Deliberately integer-only. Floating point has no place anywhere near a
/// payment path: `0.1 + 0.2` problems become real money problems.
public struct Amount: Equatable, Hashable, Codable, Sendable {
    public let asset: Asset
    public let minorUnits: Int64

    public init(asset: Asset, minorUnits: Int64) {
        self.asset = asset
        self.minorUnits = minorUnits
    }

    public static func sats(_ value: Int64) -> Amount {
        Amount(asset: .bitcoin, minorUnits: value)
    }

    public static func usdtCents(_ value: Int64) -> Amount {
        Amount(asset: .usdt, minorUnits: value)
    }

    public static func zero(_ asset: Asset) -> Amount {
        Amount(asset: asset, minorUnits: 0)
    }

    public var isZero: Bool { minorUnits == 0 }
    public var isPositive: Bool { minorUnits > 0 }

    /// Addition is only defined within one asset. Mixing assets is a programmer
    /// error, not a runtime condition to recover from, so it traps.
    public static func + (lhs: Amount, rhs: Amount) -> Amount {
        precondition(lhs.asset == rhs.asset, "cannot add \(lhs.asset) to \(rhs.asset)")
        let (sum, overflow) = lhs.minorUnits.addingReportingOverflow(rhs.minorUnits)
        precondition(!overflow, "amount overflow")
        return Amount(asset: lhs.asset, minorUnits: sum)
    }

    public static func - (lhs: Amount, rhs: Amount) -> Amount {
        precondition(lhs.asset == rhs.asset, "cannot subtract \(rhs.asset) from \(lhs.asset)")
        let (diff, overflow) = lhs.minorUnits.subtractingReportingOverflow(rhs.minorUnits)
        precondition(!overflow, "amount overflow")
        return Amount(asset: lhs.asset, minorUnits: diff)
    }

    public static func < (lhs: Amount, rhs: Amount) -> Bool {
        precondition(lhs.asset == rhs.asset, "cannot compare \(lhs.asset) with \(rhs.asset)")
        return lhs.minorUnits < rhs.minorUnits
    }

    /// `1234` USDT cents -> `"12.34"`. Bitcoin has no fractional part.
    public var displayValue: String {
        let digits = asset.fractionDigits
        guard digits > 0 else { return String(minorUnits) }
        let divisor = asset.minorUnitsPerDisplayUnit
        let whole = minorUnits / divisor
        let frac = abs(minorUnits % divisor)
        return "\(whole).\(String(format: "%0\(digits)d", frac))"
    }

    public var formatted: String {
        switch asset {
        case .bitcoin:
            return "\(minorUnits.formattedWithSeparators) sats"
        case .usdt:
            return "\(displayValue) USDT"
        }
    }
}

extension Int64 {
    var formattedWithSeparators: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: self)) ?? String(self)
    }
}

/// A fiat figure used for *display* and for the send caps. Tips never settle in
/// fiat; this exists so "£20 a day" means the same thing whether the user tips
/// in sats or USDT.
public struct FiatAmount: Equatable, Hashable, Codable, Sendable {
    public let currencyCode: String
    public let minorUnits: Int64

    public init(currencyCode: String, minorUnits: Int64) {
        self.currencyCode = currencyCode.uppercased()
        self.minorUnits = minorUnits
    }

    public static func gbp(pence: Int64) -> FiatAmount {
        FiatAmount(currencyCode: "GBP", minorUnits: pence)
    }

    public static func + (lhs: FiatAmount, rhs: FiatAmount) -> FiatAmount {
        precondition(lhs.currencyCode == rhs.currencyCode, "currency mismatch")
        return FiatAmount(currencyCode: lhs.currencyCode, minorUnits: lhs.minorUnits + rhs.minorUnits)
    }

    public var formatted: String {
        let symbol: String
        switch currencyCode {
        case "GBP": symbol = "£"
        case "USD": symbol = "$"
        case "EUR": symbol = "€"
        default: symbol = currencyCode + " "
        }
        let whole = minorUnits / 100
        let frac = abs(minorUnits % 100)
        return "\(symbol)\(whole).\(String(format: "%02d", frac))"
    }
}
