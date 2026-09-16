import Foundation

/// One entry in the unified activity feed.
///
/// "Unified" is the point: a tip sent from the share sheet, a general send
/// from the wallet's Send screen, an incoming payment, and a fiat withdrawal
/// all become one of these, so the Activity screen has a single source rather
/// than stitching together the audit log and a separate transaction store.
public struct WalletTransaction: Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case tipSent
        case send
        case receive
        case withdrawal
    }

    public enum Status: String, Codable, Sendable {
        case pending
        case completed
        case failed
    }

    public let id: String
    public let kind: Kind
    public let status: Status
    public let asset: Asset
    /// Always positive; direction comes from `kind`, not the sign.
    public let amount: Amount
    public let networkFee: Amount?
    public let counterparty: String?
    public let note: String?
    public let timestamp: Date

    public init(id: String, kind: Kind, status: Status, asset: Asset, amount: Amount,
                networkFee: Amount? = nil, counterparty: String? = nil,
                note: String? = nil, timestamp: Date) {
        self.id = id
        self.kind = kind
        self.status = status
        self.asset = asset
        self.amount = amount
        self.networkFee = networkFee
        self.counterparty = counterparty
        self.note = note
        self.timestamp = timestamp
    }

    public var isOutgoing: Bool {
        switch kind {
        case .tipSent, .send, .withdrawal: return true
        case .receive: return false
        }
    }
}
