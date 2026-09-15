import Foundation

/// Everything the user is agreeing to, computed before we ask for Face ID.
///
/// The whole point of this type is that the confirm screen and the payment
/// engine read the *same* numbers. If the UI computed its own display total,
/// the amount shown and the amount spent could drift apart, which is the exact
/// "surprise charge" the product must never produce.
public struct TipQuote: Equatable, Codable, Sendable {
    /// What the creator receives, in the creator's preferred asset.
    public let creatorReceives: Amount
    /// Our fee, in the sender's asset, added on top. Never deducted from the tip.
    public let fee: Amount
    /// Conversion detail (a no-op route when both sides use the same asset).
    public let route: SettlementRoute
    /// Total debited from the sender: tip + conversion cost + fee.
    public let senderPays: Amount
    /// Fiat rendering of the total, for display and for cap enforcement.
    public let fiatTotal: FiatAmount
    public let fiatTip: FiatAmount
    public let fiatFee: FiatAmount
    /// Timestamp of the exchange rate used, so staleness can be re-checked
    /// immediately before spending rather than only at render time.
    public let rateAsOf: Date
    public let feePolicy: FeePolicy

    public init(creatorReceives: Amount, fee: Amount, route: SettlementRoute,
                senderPays: Amount, fiatTotal: FiatAmount, fiatTip: FiatAmount,
                fiatFee: FiatAmount, rateAsOf: Date, feePolicy: FeePolicy) {
        self.creatorReceives = creatorReceives
        self.fee = fee
        self.route = route
        self.senderPays = senderPays
        self.fiatTotal = fiatTotal
        self.fiatTip = fiatTip
        self.fiatFee = fiatFee
        self.rateAsOf = rateAsOf
        self.feePolicy = feePolicy
    }

    public var hasFee: Bool { fee.isPositive }

    /// The disclosure line, e.g. "£1.00 tip + £0.03 fee = £1.03".
    public var disclosure: String {
        guard hasFee else { return "\(fiatTip.formatted) tip, no fee" }
        return "\(fiatTip.formatted) tip + \(fiatFee.formatted) fee = \(fiatTotal.formatted)"
    }

    public var conversionDisclosure: String? {
        guard route.requiresConversion else { return nil }
        return "\(route.debited.formatted) converted to \(route.credited.formatted)"
    }
}

/// Builds quotes. Separated from the engine so quoting is pure and testable:
/// given a tip, a creator, a rate and a policy, the numbers are deterministic.
public struct TipQuoteBuilder: Sendable {
    private let feePolicy: FeePolicy

    public init(feePolicy: FeePolicy) {
        self.feePolicy = feePolicy
    }

    /// - Parameters:
    ///   - tip: what the sender chose to give, denominated in the asset they
    ///     are spending.
    ///   - route: conversion terms from the payment backend. Must debit `tip`.
    ///   - sendRate: fiat price of the sender's asset.
    public func quote(tip: Amount, route: SettlementRoute, sendRate: AssetRate) throws -> TipQuote {
        guard tip.isPositive else { throw QuoteError.nonPositiveTip }
        guard route.debited == tip else { throw QuoteError.routeDoesNotMatchTip }
        guard sendRate.asset == tip.asset else { throw QuoteError.rateAssetMismatch }

        let fee = feePolicy.fee(on: tip)
        let senderPays = tip + route.conversionCost + fee

        return TipQuote(creatorReceives: route.credited,
                        fee: fee,
                        route: route,
                        senderPays: senderPays,
                        fiatTotal: sendRate.fiatValue(of: senderPays),
                        fiatTip: sendRate.fiatValue(of: tip),
                        fiatFee: sendRate.fiatValue(of: fee),
                        rateAsOf: sendRate.asOf,
                        feePolicy: feePolicy)
    }

    public enum QuoteError: Error, Equatable, Sendable {
        case nonPositiveTip
        case routeDoesNotMatchTip
        case rateAssetMismatch
    }
}
