import Foundation

/// An LNURL-pay address in `name@domain` form.
///
/// Validated on construction because this value ends up in a URL we fetch and
/// then send money to. A permissive parser here is a payment-redirection bug.
public struct LightningAddress: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let name: String
    public let domain: String

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Tolerate the lightning: scheme prefix that some wallets copy.
        let stripped = trimmed.hasPrefix("lightning:") ? String(trimmed.dropFirst("lightning:".count)) : trimmed

        let parts = stripped.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let name = String(parts[0])
        let domain = String(parts[1])

        guard !name.isEmpty, name.count <= 64,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" || $0 == "+") }),
              !name.contains("..")
        else { return nil }

        guard !domain.isEmpty, domain.count <= 253,
              domain.contains("."),
              !domain.hasPrefix("."), !domain.hasSuffix("."),
              !domain.contains(".."),
              domain.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        else { return nil }

        self.name = name
        self.domain = domain
    }

    public var description: String { "\(name)@\(domain)" }

    /// The LUD-16 well-known endpoint. Always https — an LNURL-pay fetched over
    /// plain http could be rewritten in flight to point at a different invoice.
    public var lnurlPayEndpoint: URL? {
        URL(string: "https://\(domain)/.well-known/lnurlp/\(name)")
    }

    /// Redacted form for logs. We audit every payment, and audit logs outlive
    /// the payment, so they should not become a directory of who tipped whom.
    public var redacted: String {
        let visible = name.prefix(2)
        return "\(visible)***@\(domain)"
    }
}
