import Foundation

/// A fiat price for one asset, used for display and for enforcing send caps in
/// a single currency.
public struct AssetRate: Equatable, Codable, Sendable {
    public let asset: Asset
    public let currencyCode: String
    /// Fiat minor units per one *minor unit* of the asset, scaled by 1e8 so the
    /// value stays an integer. For BTC at £50,000: one sat is 0.05p, which is
    /// 0.05 * 1e8 = 5_000_000.
    public let scaledPricePerMinorUnit: Int64
    public let asOf: Date

    public static let scale: Int64 = 100_000_000

    public init(asset: Asset, currencyCode: String, scaledPricePerMinorUnit: Int64, asOf: Date) {
        self.asset = asset
        self.currencyCode = currencyCode.uppercased()
        self.scaledPricePerMinorUnit = scaledPricePerMinorUnit
        self.asOf = asOf
    }

    public func fiatValue(of amount: Amount) -> FiatAmount {
        precondition(amount.asset == asset, "rate is for \(asset), got \(amount.asset)")
        let (product, overflow) = amount.minorUnits.multipliedReportingOverflow(by: scaledPricePerMinorUnit)
        precondition(!overflow, "fiat conversion overflow")
        // Round half up.
        let minor = (product + Self.scale / 2) / Self.scale
        return FiatAmount(currencyCode: currencyCode, minorUnits: minor)
    }

    public func isStale(at now: Date, tolerance: TimeInterval) -> Bool {
        now.timeIntervalSince(asOf) > tolerance
    }
}

public protocol ExchangeRateProvider: Sendable {
    /// Current fiat price of `asset`. Throws rather than returning a guess:
    /// a confirm screen that shows a made-up £ figure is worse than one that
    /// refuses to load.
    func rate(for asset: Asset, in currencyCode: String) async throws -> AssetRate
}

public enum ExchangeRateError: Error, Equatable, Sendable {
    case unavailable(asset: Asset, currencyCode: String)
    case stale(asOf: Date)
}

/// How long a quoted rate may be shown before the user must re-confirm.
///
/// This exists because of a specific failure: the sheet renders "£1.00 tip +
/// £0.03 fee", the user leaves it open, the BTC price moves, and Face ID then
/// authorises a sat amount that no longer matches the pounds they agreed to.
/// `TipQuote` carries its rate's timestamp and the engine re-checks freshness
/// *after* biometric approval, immediately before spending.
public enum RateFreshness {
    public static let displayTolerance: TimeInterval = 90
    public static let spendTolerance: TimeInterval = 120
}
