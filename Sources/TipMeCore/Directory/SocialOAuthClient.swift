import Foundation

/// Talks to the registry's platform sign-in endpoints (`/v1/oauth/...`), so a
/// creator can prove they control an Instagram or TikTok handle by actually
/// signing in, rather than pasting a code into their bio and waiting for a
/// human to check it.
///
/// Deliberately Foundation-only, like `CreatorRegistrar`: the part of this
/// flow that has to run in the app target is driving `ASWebAuthenticationSession`
/// (a UIKit-adjacent, Apple-platform-only API), which does not belong in this
/// package. Everything before and after that browser hop — building the start
/// request, parsing what comes back — is plain networking and belongs here so
/// it can be unit tested without a simulator.
public struct SocialOAuthClient: Sendable {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession? = nil, timeout: TimeInterval = 10) {
        self.baseURL = baseURL
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

    /// What `/v1/oauth/{platform}/start` hands back: the URL to open in a
    /// browser, and how long the pending claim behind it stays valid.
    public struct StartResult: Sendable {
        public let authorizeURL: URL
        public let expiresIn: TimeInterval
    }

    /// Begins sign-in for a handle the creator wants to claim or already owns.
    ///
    /// Carries the full registration payload, not just the handle: the
    /// registry holds it against the `state` it returns, and only writes the
    /// record once the platform confirms identity in `/callback`. So a
    /// creator who has never registered before can go straight from "connect
    /// Instagram" to a verified record in one flow, no unverified interim
    /// step required.
    public func start(platform: Platform,
                      username: String,
                      lightningAddress: LightningAddress,
                      preferredAsset: Asset,
                      minimumTip: Amount?,
                      displayName: String?) async throws -> StartResult {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/v1/oauth/\(platform.rawValue)/start"
        guard let url = components?.url else {
            throw SocialOAuthError.responseMalformed("could not build registry URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: Any?] = [
            "platform": platform.rawValue,
            "username": username,
            "lightning_address": lightningAddress.description,
            "preferred_asset": preferredAsset.rawValue,
            "minimum_tip_minor_units": minimumTip?.minorUnits,
            "display_name": displayName
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body.compactMapValues { $0 })

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SocialOAuthError.transport(String(describing: error))
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 503 {
                throw SocialOAuthError.notConfigured(platform)
            }
            throw SocialOAuthError.rejected(Self.detail(in: data) ?? "registry returned HTTP \(status)")
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = object["authorize_url"] as? String,
              let authorizeURL = URL(string: urlString)
        else {
            throw SocialOAuthError.responseMalformed("missing authorize_url in start response")
        }
        let expiresIn = (object["expires_in"] as? Double) ?? 600

        return StartResult(authorizeURL: authorizeURL, expiresIn: expiresIn)
    }

    /// What a completed sign-in leaves behind, fetched once via
    /// `/v1/oauth/session/{id}` — never read out of the callback URL itself.
    public struct SessionResult: Sendable, Equatable {
        public let handle: CreatorHandle
        public let lightningAddress: LightningAddress
        public let verified: Bool
        public let claimToken: String?
        public let managementToken: String?
    }

    /// Collects the result of a sign-in the app just completed.
    ///
    /// Single use by design — the registry deletes the entry the moment this
    /// call succeeds, so this must only be called once per sign-in, right
    /// after `ASWebAuthenticationSession` returns.
    public func fetchSession(sessionID: String) async throws -> SessionResult {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/v1/oauth/session/\(sessionID)"
        guard let url = components?.url else {
            throw SocialOAuthError.responseMalformed("could not build registry URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SocialOAuthError.transport(String(describing: error))
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw SocialOAuthError.sessionExpired
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let platformRaw = object["platform"] as? String,
              let platform = Platform(rawValue: platformRaw),
              let username = object["username"] as? String,
              let handle = CreatorHandle(platform: platform, rawUsername: username),
              let addressString = object["lightning_address"] as? String,
              let address = LightningAddress(addressString),
              let verified = object["verified"] as? Bool
        else {
            throw SocialOAuthError.responseMalformed("missing fields in oauth session response")
        }

        return SessionResult(handle: handle,
                             lightningAddress: address,
                             verified: verified,
                             claimToken: object["claim_token"] as? String,
                             managementToken: object["management_token"] as? String)
    }

    private static func detail(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let detail = object["detail"] as? String { return detail }
        if let details = object["detail"] as? [[String: Any]],
           let first = details.first, let message = first["msg"] as? String {
            return message
        }
        return nil
    }
}

public enum SocialOAuthError: Error, Equatable, Sendable {
    /// The registry has no client id/secret for this platform yet.
    case notConfigured(Platform)
    case rejected(String)
    case transport(String)
    case responseMalformed(String)
    /// The one-time session was already collected, or its five-minute window
    /// has passed.
    case sessionExpired

    public var userFacingReason: String {
        switch self {
        case .notConfigured(let platform):
            return "\(platform.displayName) sign-in isn't set up yet. Use the bio-code option below instead."
        case .rejected(let reason): return reason
        case .transport: return "Couldn't reach TipMe. Check your connection and try again."
        case .responseMalformed: return "TipMe gave an unexpected response. Try again in a moment."
        case .sessionExpired: return "That sign-in took too long. Try connecting again."
        }
    }
}

/// Parses `{scheme}://oauth-complete?...`, the URL the registry's
/// `/callback` endpoint redirects to once it has (or has not) verified a
/// sign-in. Pure string parsing — kept here, rather than inline in the app
/// target's `ASWebAuthenticationSession` completion handler, so the redirect
/// contract between registry and app has one place both sides' tests can
/// point at.
public struct OAuthCallbackResult: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case success(sessionID: String)
        case failure(reason: String)
    }
    public let platform: Platform
    public let status: Status

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        guard let platformRaw = value("platform"), let platform = Platform(rawValue: platformRaw),
              let statusRaw = value("status")
        else { return nil }

        self.platform = platform
        switch statusRaw {
        case "success":
            guard let sessionID = value("session_id") else { return nil }
            self.status = .success(sessionID: sessionID)
        default:
            self.status = .failure(reason: value("reason") ?? "unknown_error")
        }
    }
}
