import Foundation

/// How a tip gets from the sender's chosen asset to the creator's chosen asset.
///
/// The sender picks what they want to spend; the creator has already recorded
/// what they want to receive. When those differ, the payment is converted in
/// flight rather than forcing either side to hold an asset they didn't ask for.
public struct SettlementRoute: Equatable, Codable, Sendable {
    public let sendAsset: Asset
    public let receiveAsset: Asset
    /// What the sender is debited for the tip itself, in `sendAsset`.
    public let debited: Amount
    /// What the creator is credited, in `receiveAsset`. For a same-asset route
    /// this equals `debited`.
    public let credited: Amount
    /// Conversion spread and network cost, in `sendAsset`. Zero for same-asset.
    /// This is *not* our fee — it's the cost of the swap, and it is disclosed
    /// separately on the confirm screen so the two are never conflated.
    public let conversionCost: Amount
    /// When the conversion terms were quoted. Conversion quotes expire.
    public let quotedAt: Date

    public init(sendAsset: Asset, receiveAsset: Asset, debited: Amount,
                credited: Amount, conversionCost: Amount, quotedAt: Date) {
        precondition(debited.asset == sendAsset, "debited must be in sendAsset")
        precondition(credited.asset == receiveAsset, "credited must be in receiveAsset")
        precondition(conversionCost.asset == sendAsset, "conversion cost must be in sendAsset")
        self.sendAsset = sendAsset
        self.receiveAsset = receiveAsset
        self.debited = debited
        self.credited = credited
        self.conversionCost = conversionCost
        self.quotedAt = quotedAt
    }

    public var requiresConversion: Bool { sendAsset != receiveAsset }

    /// A direct, same-asset route.
    public static func direct(_ amount: Amount, at quotedAt: Date) -> SettlementRoute {
        SettlementRoute(sendAsset: amount.asset,
                        receiveAsset: amount.asset,
                        debited: amount,
                        credited: amount,
                        conversionCost: .zero(amount.asset),
                        quotedAt: quotedAt)
    }

    public func isStale(at now: Date, tolerance: TimeInterval) -> Bool {
        requiresConversion && now.timeIntervalSince(quotedAt) > tolerance
    }
}
