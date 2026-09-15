import Foundation

/// What a tip can actually be denominated in on the wire.
///
/// Both are supported by Breez SDK Nodeless: Bitcoin settles over Lightning,
/// USDT settles as Liquid USDT. A tip may be *sent* in one and *received* in
/// the other — see `SettlementRoute`.
public enum Asset: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
    case bitcoin
    case usdt

    /// Ticker shown to a human.
    public var symbol: String {
        switch self {
        case .bitcoin: return "sats"
        case .usdt: return "USDT"
        }
    }

    /// How many minor units make one display unit.
    /// Bitcoin is denominated directly in satoshis, so the minor unit *is* the
    /// display unit. USDT is denominated in cents.
    public var minorUnitsPerDisplayUnit: Int64 {
        switch self {
        case .bitcoin: return 1
        case .usdt: return 100
        }
    }

    public var fractionDigits: Int {
        switch self {
        case .bitcoin: return 0
        case .usdt: return 2
        }
    }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }

    public var codingKey: CodingKey { AssetCodingKey(stringValue: rawValue) }
}

private struct AssetCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
