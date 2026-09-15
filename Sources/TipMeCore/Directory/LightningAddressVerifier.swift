import Foundation

/// What a creator's wallet says it will accept.
public struct LNURLPayCapability: Equatable, Sendable {
    /// Smallest payment the destination will accept.
    public let minimum: Amount
    /// Largest payment the destination will accept.
    public let maximum: Amount
    /// Whether the wallet accepts a comment alongside the payment.
    public let acceptsComment: Bool
    /// Description the wallet publishes, if any — shown back to the creator so
    /// they can confirm they have registered the wallet they think they have.
    public let describedAs: String?

    public init(minimum: Amount, maximum: Amount, acceptsComment: Bool, describedAs: String?) {
        self.minimum = minimum
        self.maximum = maximum
        self.acceptsComment = acceptsComment
        self.describedAs = describedAs
    }
}

public enum LightningAddressVerificationError: Error, Equatable, Sendable {
    case notFound
    case notAPayEndpoint
    case rejected(reason: String)
    case malformed(String)
    case unreachable(String)

    public var userFacingReason: String {
        switch self {
        case .notFound:
            return "That wallet doesn't exist. Check the spelling."
        case .notAPayEndpoint:
            return "That address exists but can't receive payments."
        case .rejected(let reason):
            return "That wallet refused the check: \(reason)"
        case .malformed(let detail):
            return "That wallet gave an answer we couldn't read (\(detail))."
        case .unreachable(let detail):
            return "Couldn't reach that wallet (\(detail))."
        }
    }
}

/// Fetches a URL. Injected so verification is testable without a network.
public protocol HTTPFetching: Sendable {
    func get(_ url: URL) async throws -> (Data, Int)
}

/// Checks that a Lightning address actually resolves and can receive money,
/// before a creator registers it.
///
/// ## Why this is not optional
///
/// A creator registers `charli@getably.com` instead of `charli@getalby.com`.
/// Nothing rejects it — the registry stores whatever it is given. Senders share
/// her videos, the app looks the handle up, and every tip fails, or worse, goes
/// to whoever owns the typo'd domain. She finds out weeks later when she
/// wonders why she has never been paid.
///
/// Verifying at registration turns an invisible, slow, expensive failure into
/// an immediate one with a clear message, at the cost of one HTTP request.
public struct LightningAddressVerifier: Sendable {
    private let fetcher: HTTPFetching

    public init(fetcher: HTTPFetching) {
        self.fetcher = fetcher
    }

    public init(timeout: TimeInterval = 8) {
        self.fetcher = URLSessionFetcher(timeout: timeout)
    }

    public func verify(_ address: LightningAddress) async throws -> LNURLPayCapability {
        guard let endpoint = address.lnurlPayEndpoint else {
            throw LightningAddressVerificationError.malformed("could not build LNURL endpoint")
        }

        let data: Data
        let status: Int
        do {
            (data, status) = try await fetcher.get(endpoint)
        } catch {
            throw LightningAddressVerificationError.unreachable(String(describing: error))
        }

        if status == 404 { throw LightningAddressVerificationError.notFound }
        guard (200...299).contains(status) else {
            throw LightningAddressVerificationError.unreachable("HTTP \(status)")
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LightningAddressVerificationError.malformed("response was not JSON")
        }

        // LUD-06 error shape: {"status": "ERROR", "reason": "..."}
        if let responseStatus = object["status"] as? String,
           responseStatus.uppercased() == "ERROR" {
            throw LightningAddressVerificationError.rejected(
                reason: (object["reason"] as? String) ?? "no reason given")
        }

        guard let tag = object["tag"] as? String, tag == "payRequest" else {
            throw LightningAddressVerificationError.notAPayEndpoint
        }

        // The callback is where a sender's wallet will fetch an invoice, so it
        // has to be a real https URL — an http callback could be rewritten in
        // flight to return an attacker's invoice.
        guard let callback = object["callback"] as? String,
              let callbackURL = URL(string: callback),
              callbackURL.scheme?.lowercased() == "https"
        else {
            throw LightningAddressVerificationError.malformed("callback is missing or not https")
        }

        guard let minMillisats = Self.integer(object["minSendable"]),
              let maxMillisats = Self.integer(object["maxSendable"]),
              minMillisats > 0, maxMillisats >= minMillisats
        else {
            throw LightningAddressVerificationError.malformed("sendable range is missing or inconsistent")
        }

        return LNURLPayCapability(
            // LNURL amounts are millisatoshis; we denominate in satoshis.
            minimum: .sats(minMillisats / 1_000),
            maximum: .sats(maxMillisats / 1_000),
            acceptsComment: (Self.integer(object["commentAllowed"]) ?? 0) > 0,
            describedAs: Self.description(fromMetadata: object["metadata"] as? String))
    }

    private static func integer(_ value: Any?) -> Int64? {
        if let number = value as? Int64 { return number }
        if let number = value as? Int { return Int64(number) }
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    /// LUD-06 metadata is a JSON-encoded array of `[mimeType, value]` pairs.
    /// The `text/plain` entry is the human-readable description.
    static func description(fromMetadata metadata: String?) -> String? {
        guard let metadata,
              let data = metadata.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[Any]]
        else { return nil }

        for entry in entries where entry.count >= 2 {
            if let mime = entry[0] as? String, mime == "text/plain",
               let value = entry[1] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

public struct URLSessionFetcher: HTTPFetching {
    private let session: URLSession

    public init(timeout: TimeInterval = 8) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    public func get(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TipMe/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
