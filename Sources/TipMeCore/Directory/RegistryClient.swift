import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Talks to the TipMe creator registry.
///
/// Every response is Ed25519-signed by the registry and verified here before a
/// single byte of it reaches the payment path. This matters more than it might
/// look: the registry's answer *is* the destination of the money. A hostile
/// network, a compromised CDN, or a DNS hijack that could swap
/// `charli@getalby.com` for an attacker's address would otherwise silently
/// redirect every tip in the app. TLS alone is not enough, because it trusts
/// whoever currently holds a certificate for the registry hostname.
public struct RegistryClient: CreatorResolver {
    public struct Configuration: Sendable {
        public var baseURL: URL
        /// Raw 32-byte Ed25519 public key.
        public var signingPublicKey: Data
        public var timeout: TimeInterval
        /// Reject records whose signature is older than this, to stop a captured
        /// response being replayed after a creator has changed their wallet.
        public var maximumResponseAge: TimeInterval

        public init(baseURL: URL,
                    signingPublicKey: Data,
                    timeout: TimeInterval = 6,
                    maximumResponseAge: TimeInterval = 300) {
            self.baseURL = baseURL
            self.signingPublicKey = signingPublicKey
            self.timeout = timeout
            self.maximumResponseAge = maximumResponseAge
        }
    }

    private let configuration: Configuration
    private let session: URLSession
    private let clock: Clock

    public init(configuration: Configuration, session: URLSession? = nil, clock: Clock = SystemClock()) {
        self.configuration = configuration
        self.clock = clock
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = configuration.timeout
            config.timeoutIntervalForResource = configuration.timeout
            config.httpCookieStorage = nil
            self.session = URLSession(configuration: config)
        }
    }

    public func resolve(_ handle: CreatorHandle) async throws -> CreatorRecord {
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/v1/creators/\(handle.platform.rawValue)/\(handle.username)"
        guard let url = components?.url else {
            throw CreatorLookupError.responseMalformed("could not build registry URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TipMe/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw CreatorLookupError.offline
        } catch {
            throw CreatorLookupError.transport(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw CreatorLookupError.responseMalformed("non-HTTP response")
        }
        if http.statusCode == 404 { throw CreatorLookupError.notRegistered(handle) }
        guard http.statusCode == 200 else {
            throw CreatorLookupError.transport("registry returned HTTP \(http.statusCode)")
        }

        let envelope: SignedEnvelope
        do {
            envelope = try JSONDecoder.registry.decode(SignedEnvelope.self, from: data)
        } catch {
            throw CreatorLookupError.responseMalformed(String(describing: error))
        }

        return try verify(envelope, expecting: handle)
    }

    /// Verifies signature, freshness, and that the record actually answers the
    /// question we asked. The last check is easy to forget and important: a
    /// correctly-signed record for a *different* creator is still a valid
    /// signature, and without this check a registry bug or a swapped response
    /// would pay the wrong person.
    func verify(_ envelope: SignedEnvelope, expecting handle: CreatorHandle) throws -> CreatorRecord {
        guard let payloadData = Data(base64Encoded: envelope.payload),
              let signature = Data(base64Encoded: envelope.signature)
        else { throw CreatorLookupError.responseMalformed("payload or signature not base64") }

        #if canImport(CryptoKit)
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: configuration.signingPublicKey),
              key.isValidSignature(signature, for: payloadData)
        else { throw CreatorLookupError.signatureInvalid }
        #else
        #error("RegistryClient requires CryptoKit (or swift-crypto) for Ed25519 verification")
        #endif

        let payload: RegistryPayload
        do {
            payload = try JSONDecoder.registry.decode(RegistryPayload.self, from: payloadData)
        } catch {
            throw CreatorLookupError.responseMalformed(String(describing: error))
        }

        let age = clock.now.timeIntervalSince(payload.signedAt)
        guard age <= configuration.maximumResponseAge else {
            throw CreatorLookupError.responseMalformed("registry response is \(Int(age))s old")
        }

        guard let recordHandle = CreatorHandle(platform: payload.platform, rawUsername: payload.username),
              recordHandle == handle
        else { throw CreatorLookupError.responseMalformed("registry answered for a different handle") }

        guard let address = LightningAddress(payload.lightningAddress) else {
            throw CreatorLookupError.responseMalformed("invalid lightning address in registry record")
        }

        var photoURL: URL?
        if payload.hasPhoto {
            var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
            components?.path = "/v1/creators/\(recordHandle.platform.rawValue)/\(recordHandle.username)/photo"
            photoURL = components?.url
        }

        return CreatorRecord(handle: recordHandle,
                             lightningAddress: address,
                             preferredAsset: payload.preferredAsset,
                             minimumTipMinorUnits: payload.minimumTipMinorUnits,
                             updatedAt: payload.updatedAt,
                             displayName: payload.displayName,
                             verified: payload.verified,
                             photoURL: photoURL,
                             tipmeLinked: payload.tipmeLinked)
    }

    struct SignedEnvelope: Codable, Sendable {
        /// base64 of the exact JSON bytes that were signed. Signing the encoded
        /// bytes rather than re-serialising avoids any canonicalisation
        /// disagreement between server and client.
        let payload: String
        /// base64 Ed25519 signature over those bytes.
        let signature: String
    }

    struct RegistryPayload: Codable, Sendable {
        let platform: Platform
        let username: String
        let lightningAddress: String
        let preferredAsset: Asset
        let minimumTipMinorUnits: Int64?
        let displayName: String?
        let verified: Bool
        let hasPhoto: Bool
        let tipmeLinked: Bool
        let updatedAt: Date
        let signedAt: Date
    }
}

extension JSONDecoder {
    static var registry: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Wraps another resolver with a short-lived in-memory cache.
///
/// Bounded deliberately: the share extension is memory-capped and an unbounded
/// cache there is a crash, not a speedup.
public actor CachingCreatorResolver: CreatorResolver {
    private let upstream: CreatorResolver
    private let clock: Clock
    private let ttl: TimeInterval
    private let capacity: Int
    private var entries: [CreatorHandle: (record: CreatorRecord, storedAt: Date)] = [:]
    private var insertionOrder: [CreatorHandle] = []

    public init(upstream: CreatorResolver, clock: Clock = SystemClock(),
                ttl: TimeInterval = 600, capacity: Int = 64) {
        self.upstream = upstream
        self.clock = clock
        self.ttl = ttl
        self.capacity = capacity
    }

    public func resolve(_ handle: CreatorHandle) async throws -> CreatorRecord {
        if let entry = entries[handle], clock.now.timeIntervalSince(entry.storedAt) < ttl {
            return entry.record
        }
        let record = try await upstream.resolve(handle)
        store(record, for: handle)
        return record
    }

    private func store(_ record: CreatorRecord, for handle: CreatorHandle) {
        if entries[handle] == nil {
            insertionOrder.append(handle)
            while insertionOrder.count > capacity {
                entries.removeValue(forKey: insertionOrder.removeFirst())
            }
        }
        entries[handle] = (record, clock.now)
    }
}
