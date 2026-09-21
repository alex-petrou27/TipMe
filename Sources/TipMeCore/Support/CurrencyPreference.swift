import Foundation

/// The one currency a person sees everywhere -- balance, deposits, sends,
/// tips and history. Bitcoin and USDT stay behind the scenes as what actually
/// settles.
///
/// Until the user picks one it follows the device's region; once they do, the
/// choice is saved in the shared App Group so the share extension agrees.
public struct CurrencyPreference: Sendable {
    public struct Option: Equatable, Hashable, Sendable {
        public let code: String
        public let name: String
    }

    /// Only currencies with two decimal places: every amount in the app is
    /// held as integer minor units of 1/100.
    public static let supported: [Option] = [
        Option(code: "GBP", name: "British pound (£)"),
        Option(code: "USD", name: "US dollar ($)"),
        Option(code: "EUR", name: "Euro (€)"),
        Option(code: "CAD", name: "Canadian dollar (CA$)"),
        Option(code: "AUD", name: "Australian dollar (A$)"),
        Option(code: "CHF", name: "Swiss franc (CHF)")
    ]

    private static let key = "preferred-currency"
    private let store: KeyValueStore

    public init(store: KeyValueStore) {
        self.store = store
    }

    /// What the user chose, if they have.
    public var saved: String? {
        store.data(forKey: Self.key)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { code in Self.supported.contains { $0.code == code } ? code : nil }
    }

    public func save(_ code: String) {
        let upper = code.uppercased()
        guard Self.supported.contains(where: { $0.code == upper }) else { return }
        store.set(upper.data(using: .utf8), forKey: Self.key)
    }

    /// The device's own currency if we support it, otherwise `fallback`.
    public static func deviceDefault(fallback: String = "USD") -> String {
        let code = Locale.current.currency?.identifier.uppercased()
        if let code, supported.contains(where: { $0.code == code }) { return code }
        return fallback
    }
}

extension FiatAmount {
    /// "12.34" or "12,34" -> 1234 minor units. Nil for anything that isn't a
    /// positive amount with at most two decimal places.
    public init?(parsing text: String, currencyCode: String) {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty,
              let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")),
              value > 0
        else { return nil }
        let scaled = value * 100
        var rounded = Decimal()
        var input = scaled
        NSDecimalRound(&rounded, &input, 0, .plain)
        guard rounded == scaled else { return nil }
        self.init(currencyCode: currencyCode, minorUnits: NSDecimalNumber(decimal: rounded).int64Value)
    }
}
