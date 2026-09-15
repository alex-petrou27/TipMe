import Foundation

/// Per-asset floors and ceilings on our fee.
public struct FeeAssetRule: Equatable, Codable, Sendable {
    /// Never charge less than this (in minor units) when a fee applies.
    public var minimumFee: Int64
    /// Never charge more than this. `nil` = uncapped.
    public var maximumFee: Int64?
    /// Tips below this size are free. Below roughly 1000 sats a percentage fee
    /// is a handful of sats and the routing cost of collecting it exceeds what
    /// we collect, so charging is worse than pointless.
    public var waiveTipsBelow: Int64

    public init(minimumFee: Int64, maximumFee: Int64? = nil, waiveTipsBelow: Int64) {
        self.minimumFee = minimumFee
        self.maximumFee = maximumFee
        self.waiveTipsBelow = waiveTipsBelow
    }
}

/// Sender-side fee, added **on top of** the tip.
///
/// The creator is never skimmed: they receive `tip` exactly, and the fee is a
/// separate payment from the sender to us. See `PaymentEngine` for why that is
/// two payments rather than one.
///
/// Every number here is configuration, not a literal buried in the payment path.
public struct FeePolicy: Equatable, Codable, Sendable {
    /// 300 = 3.00%. Basis points keep the arithmetic in integers.
    public var rateBasisPoints: Int
    public var bitcoin: FeeAssetRule
    public var usdt: FeeAssetRule

    public init(rateBasisPoints: Int, bitcoin: FeeAssetRule, usdt: FeeAssetRule) {
        precondition(rateBasisPoints >= 0 && rateBasisPoints <= 10_000,
                     "fee rate must be between 0 and 100%")
        self.rateBasisPoints = rateBasisPoints
        self.bitcoin = bitcoin
        self.usdt = usdt
    }

    /// The shipping default. Overridden at launch from `TIPME_FEE_BASIS_POINTS`
    /// and friends — see `AppConfiguration`.
    public static let standard = FeePolicy(
        rateBasisPoints: 300,
        bitcoin: FeeAssetRule(minimumFee: 1, maximumFee: 25_000, waiveTipsBelow: 1_000),
        usdt: FeeAssetRule(minimumFee: 1, maximumFee: 1_000, waiveTipsBelow: 50)
    )

    public func rule(for asset: Asset) -> FeeAssetRule {
        switch asset {
        case .bitcoin: return bitcoin
        case .usdt: return usdt
        }
    }

    /// Fee charged on a tip, in the same asset the sender is paying with.
    ///
    /// Rounds half-up, then clamps to the asset's floor and ceiling. Returns a
    /// zero amount for tips under the waiver threshold.
    public func fee(on tip: Amount) -> Amount {
        let rule = rule(for: tip.asset)
        guard tip.minorUnits > 0, tip.minorUnits >= rule.waiveTipsBelow else {
            return .zero(tip.asset)
        }

        let (product, overflow) = tip.minorUnits.multipliedReportingOverflow(by: Int64(rateBasisPoints))
        precondition(!overflow, "fee calculation overflow")

        // Round half up: (x + 5000) / 10000 in integer arithmetic.
        var fee = (product + 5_000) / 10_000

        if fee < rule.minimumFee { fee = rule.minimumFee }
        if let max = rule.maximumFee, fee > max { fee = max }

        return Amount(asset: tip.asset, minorUnits: fee)
    }

    /// What the sender's wallet is actually debited: tip + fee.
    public func total(on tip: Amount) -> Amount {
        tip + fee(on: tip)
    }

    public var percentageDescription: String {
        let whole = rateBasisPoints / 100
        let frac = rateBasisPoints % 100
        return frac == 0 ? "\(whole)%" : "\(whole).\(String(format: "%02d", frac))%"
    }
}
