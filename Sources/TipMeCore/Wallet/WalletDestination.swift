import Foundation

/// What a sender pasted, scanned, or typed, classified into something the
/// wallet can act on.
///
/// Deliberately SDK-agnostic — this is Foundation-only, so `TipMeCore` never
/// has to know Breez's `InputType` shape. `WalletBackend.resolve(_:)` is the
/// only place that translation happens.
public enum WalletDestination: Equatable, Sendable {
    /// A `name@domain` LNURL-pay address — the same rail tips already use.
    case lightningAddress(LightningAddress)
    /// A BOLT-11 Lightning invoice. Carries its own fixed amount when the
    /// invoice specifies one, so the UI can skip asking.
    case lightningInvoice(raw: String, amountSat: Int64?, description: String?)
    /// An on-chain Bitcoin address.
    case bitcoinAddress(raw: String)
    /// A Liquid address (L-BTC or a Liquid asset such as USDT).
    case liquidAddress(raw: String, assetHint: Asset?)

    public var requiresManualAmount: Bool {
        if case .lightningInvoice(_, let amountSat, _) = self {
            return amountSat == nil
        }
        return true
    }

    /// One line describing what was recognised, for the send screen's
    /// "You're sending to…" line. Never shows the raw string for a Lightning
    /// address — that already has a friendly `description`.
    public var displaySummary: String {
        switch self {
        case .lightningAddress(let address):
            return address.description
        case .lightningInvoice(_, let amountSat, let description):
            if let description, !description.isEmpty { return description }
            if let amountSat { return "Lightning invoice for \(Amount.sats(amountSat).formatted)" }
            return "Lightning invoice"
        case .bitcoinAddress(let raw):
            return Self.truncated(raw)
        case .liquidAddress(let raw, _):
            return Self.truncated(raw)
        }
    }

    private static func truncated(_ raw: String) -> String {
        guard raw.count > 20 else { return raw }
        return "\(raw.prefix(10))…\(raw.suffix(6))"
    }
}

public enum WalletDestinationError: Error, Equatable, Sendable {
    case unrecognised
    case wrongNetwork
    case expired
}
