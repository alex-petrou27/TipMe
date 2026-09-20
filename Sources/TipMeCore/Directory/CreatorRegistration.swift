import Foundation

/// What the registry hands back when a creator claims a handle.
public struct CreatorRegistration: Equatable, Sendable {
    public let handle: CreatorHandle
    public let lightningAddress: LightningAddress
    /// Always false for a fresh registration — anyone can claim any handle, so
    /// the claim has to be checked before it means anything.
    public let verified: Bool
    /// "oauth" (signed into the platform itself), "self" (confirmed a bio
    /// code themselves -- see `CreatorRegistrar.selfVerify`), "admin", or
    /// `nil` when `verified` is false. Kept distinct rather than collapsed
    /// into `verified` because "self" is a real, lesser tier: the client
    /// badges it differently rather than implying Instagram/TikTok
    /// themselves confirmed it.
    public let verifiedVia: String?
    /// Token the creator puts in their bio to prove the handle is theirs.
    public let claimToken: String
    public let verificationInstructions: String
    /// Secret issued **only** on first claim, required to change the record
    /// later. `nil` on an update, because re-issuing it every time would let
    /// anyone who can read one response take the record over.
    ///
    /// Losing this means losing the ability to change where your tips go, so
    /// the app stores it in the keychain rather than showing it once and
    /// hoping.
    public let managementToken: String?

    public init(handle: CreatorHandle, lightningAddress: LightningAddress,
                verified: Bool, verifiedVia: String? = nil, claimToken: String,
                verificationInstructions: String, managementToken: String?) {
        self.handle = handle
        self.lightningAddress = lightningAddress
        self.verified = verified
        self.verifiedVia = verifiedVia
        self.claimToken = claimToken
        self.verificationInstructions = verificationInstructions
        self.managementToken = managementToken
    }
}

public enum CreatorRegistrationError: Error, Equatable, Sendable {
    /// The registry rejected the details, with its reason.
    case rejected(String)
    /// The handle is registered and this caller cannot change it.
    case notYours(String)
    /// Too many new claims from this client.
    case throttled(String)
    case addressUnverified(LightningAddressVerificationError)
    case transport(String)
    case responseMalformed(String)

    public var userFacingReason: String {
        switch self {
        case .rejected(let reason): return reason
        case .notYours(let reason): return reason
        case .throttled(let reason): return reason
        case .addressUnverified(let error): return error.userFacingReason
        case .transport: return "Couldn't reach TipMe. Check your connection and try again."
        case .responseMalformed: return "TipMe gave an unexpected response. Try again in a moment."
        }
    }
}

/// Registers a creator's handle against their wallet.
///
/// Deliberately separate from `RegistryClient`, which senders use: this is the
/// creator-side write path and it runs perhaps once per creator, while lookups
/// run on every tip. Keeping them apart means the sender's hot path carries no
/// code that can write.
public struct CreatorRegistrar: Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let verifier: LightningAddressVerifier

    public init(baseURL: URL,
                verifier: LightningAddressVerifier = LightningAddressVerifier(),
                session: URLSession? = nil,
                timeout: TimeInterval = 10) {
        self.baseURL = baseURL
        self.verifier = verifier
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            config.httpCookieStorage = nil
            self.session = URLSession(configuration: config)
        }
    }

    /// Verifies the address resolves, then registers it.
    ///
    /// The verification step is the point. Registering an address that does not
    /// resolve produces a creator whose every tip fails silently, discovered
    /// weeks later — see `LightningAddressVerifier`. One HTTP request turns
    /// that into an immediate, legible error.
    ///
    /// - Parameter managementToken: required when the handle is already
    ///   registered. Claiming an unclaimed handle is open; changing an existing
    ///   record is not, otherwise anyone could point a registered creator's
    ///   handle at their own wallet and collect their tips.
    /// - Parameter sessionToken: the caller's TipMe session, if signed in.
    ///   Sent as `Authorization: Bearer` so the registry can link this handle
    ///   to the caller's account (`tipme_linked`) -- see the registry's
    ///   `register` docstring. Registering while signed out still works
    ///   exactly as before; the handle just isn't linked to anything.
    /// - Parameter skipAddressVerification: true when `lightningAddress` is
    ///   never actually going to be paid -- a signed-in registration whose
    ///   tips will route ledger-to-ledger once linked, not over Lightning.
    ///   The live-resolves check exists to catch a typo that would make
    ///   *every tip* silently vanish into an unreachable address; that risk
    ///   doesn't exist for an address the payment path never touches.
    public func register(handle: CreatorHandle,
                         lightningAddress: LightningAddress,
                         preferredAsset: Asset,
                         minimumTip: Amount?,
                         displayName: String?,
                         managementToken: String? = nil,
                         sessionToken: String? = nil,
                         skipAddressVerification: Bool = false) async throws -> CreatorRegistration {
        if !skipAddressVerification {
            do {
                _ = try await verifier.verify(lightningAddress)
            } catch let error as LightningAddressVerificationError {
                throw CreatorRegistrationError.addressUnverified(error)
            }
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/v1/creators"
        guard let url = components?.url else {
            throw CreatorRegistrationError.responseMalformed("could not build registry URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let managementToken {
            request.setValue(managementToken, forHTTPHeaderField: "X-Management-Token")
        }
        if let sessionToken {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any?] = [
            "platform": handle.platform.rawValue,
            "username": handle.username,
            "lightning_address": lightningAddress.description,
            "preferred_asset": preferredAsset.rawValue,
            "minimum_tip_minor_units": minimumTip?.minorUnits,
            "display_name": displayName
        ]
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: body.compactMapValues { $0 })

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CreatorRegistrationError.transport(String(describing: error))
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let detail = Self.detail(in: data) ?? "registry returned HTTP \(status)"
            switch status {
            case 403: throw CreatorRegistrationError.notYours(detail)
            case 429: throw CreatorRegistrationError.throttled(detail)
            default: throw CreatorRegistrationError.rejected(detail)
            }
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["claim_token"] as? String,
              let instructions = object["verification_instructions"] as? String,
              let registeredAddress = (object["lightning_address"] as? String)
                  .flatMap(LightningAddress.init)
        else {
            throw CreatorRegistrationError.responseMalformed("missing fields in registration response")
        }

        return CreatorRegistration(
            handle: handle,
            lightningAddress: registeredAddress,
            verified: (object["verified"] as? Bool) ?? false,
            verifiedVia: object["verified_via"] as? String,
            claimToken: token,
            verificationInstructions: instructions,
            managementToken: object["management_token"] as? String)
    }

    /// Confirms a handle registered while signed in, without an admin or a
    /// platform OAuth in the loop -- see the registry's `self_verify`
    /// docstring for why marking it verified this way is safe even though
    /// nothing here ever reads Instagram or TikTok. Requires the caller to
    /// still hold a live session and the claim token their own registration
    /// returned; anyone else gets a 403/400, not a quieter no-op.
    public func selfVerify(handle: CreatorHandle, claimToken: String,
                           sessionToken: String) async throws {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/v1/creators/\(handle.platform.rawValue)/\(handle.username)/self-verify"
        guard let url = components?.url else {
            throw CreatorRegistrationError.responseMalformed("could not build registry URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["claim_token": claimToken])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CreatorRegistrationError.transport(String(describing: error))
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let detail = Self.detail(in: data) ?? "registry returned HTTP \(status)"
            switch status {
            case 403: throw CreatorRegistrationError.notYours(detail)
            default: throw CreatorRegistrationError.rejected(detail)
            }
        }
    }

    /// FastAPI puts the human-readable reason in `detail`.
    private static func detail(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let detail = object["detail"] as? String { return detail }
        // Pydantic validation errors arrive as a list of objects.
        if let details = object["detail"] as? [[String: Any]],
           let first = details.first, let message = first["msg"] as? String {
            return message
        }
        return nil
    }
}
