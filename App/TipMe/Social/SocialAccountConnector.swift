import AuthenticationServices
import UIKit
import TipMeCore

/// Drives "Connect Instagram" / "Connect TikTok" from `CreatorSetupView`.
///
/// `ASWebAuthenticationSession` is the only piece of this flow that has to
/// live in the app target rather than `TipMeCore`: it presents the platform's
/// own login page in a system browser sheet (so TipMe never sees a password)
/// and intercepts the final redirect to our `tipme://` URL scheme. Everything
/// before and after that — building the start request, parsing what comes
/// back — is `SocialOAuthClient`, plain Foundation, shared and unit tested.
@MainActor
public final class SocialAccountConnector: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let client: SocialOAuthClient
    private let callbackScheme = "tipme"
    private var activeSession: ASWebAuthenticationSession?

    public init(baseURL: URL) {
        self.client = SocialOAuthClient(baseURL: baseURL)
    }

    public enum ConnectorError: Error {
        case cancelled
        case platformDeclined(reason: String)
        case oauth(SocialOAuthError)
        case sessionFailed(String)

        public var userFacingReason: String {
            switch self {
            case .cancelled:
                return "Sign-in was cancelled."
            case .platformDeclined(let reason):
                switch reason {
                case "account_mismatch":
                    return "That's a different account than the one you're trying to verify. Sign in with the account that actually posts as this handle."
                case "access_denied":
                    return "Sign-in was cancelled."
                case "not_configured":
                    return "This platform's sign-in isn't set up yet. Use the bio-code option below instead."
                default:
                    return "Sign-in didn't go through. Try again."
                }
            case .oauth(let error):
                return error.userFacingReason
            case .sessionFailed:
                return "Couldn't open the sign-in page. Check your connection and try again."
            }
        }
    }

    /// Runs the full connect flow: asks the registry for an authorize URL,
    /// presents it, and collects the result once the registry's own
    /// `/callback` hands control back to this app.
    public func connect(platform: Platform,
                        username: String,
                        lightningAddress: LightningAddress,
                        preferredAsset: Asset,
                        minimumTip: Amount?,
                        displayName: String?) async throws -> SocialOAuthClient.SessionResult {
        let start: SocialOAuthClient.StartResult
        do {
            start = try await client.start(platform: platform,
                                           username: username,
                                           lightningAddress: lightningAddress,
                                           preferredAsset: preferredAsset,
                                           minimumTip: minimumTip,
                                           displayName: displayName)
        } catch let error as SocialOAuthError {
            throw ConnectorError.oauth(error)
        }

        return try await presentAndCollect(authorizeURL: start.authorizeURL) { sessionID in
            try await self.client.fetchSession(sessionID: sessionID)
        }
    }

    /// Proves "this is me" for a sender who wants a "Sending as @handle"
    /// badge — no wallet, no handle claimed, nothing written to the registry
    /// beyond the sign-in itself.
    public func connectIdentity(platform: Platform) async throws -> SocialOAuthClient.IdentityResult {
        let start: SocialOAuthClient.StartResult
        do {
            start = try await client.startIdentity(platform: platform)
        } catch let error as SocialOAuthError {
            throw ConnectorError.oauth(error)
        }

        return try await presentAndCollect(authorizeURL: start.authorizeURL) { sessionID in
            try await self.client.fetchIdentitySession(sessionID: sessionID)
        }
    }

    /// Shared tail of both flows: present the browser, then hand the
    /// resulting `session_id` to whichever endpoint the caller needs.
    private func presentAndCollect<T>(authorizeURL: URL,
                                      fetch: (String) async throws -> T) async throws -> T {
        let callbackURL = try await presentSession(authorizeURL: authorizeURL)
        guard let result = OAuthCallbackResult(url: callbackURL) else {
            throw ConnectorError.oauth(.responseMalformed("could not read the sign-in result"))
        }

        switch result.status {
        case .failure(let reason):
            throw ConnectorError.platformDeclined(reason: reason)
        case .success(let sessionID):
            do {
                return try await fetch(sessionID)
            } catch let error as SocialOAuthError {
                throw ConnectorError.oauth(error)
            }
        }
    }

    private func presentSession(authorizeURL: URL) async throws -> URL {
        defer { activeSession = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authorizeURL, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let authError = error as? ASWebAuthenticationSessionError,
                          authError.code == .canceledLogin {
                    continuation.resume(throwing: ConnectorError.cancelled)
                } else {
                    continuation.resume(throwing: ConnectorError.sessionFailed(
                        error?.localizedDescription ?? "unknown error"))
                }
            }
            // Not ephemeral: a creator already signed into Instagram/TikTok in
            // Safari should not have to re-enter their password here.
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            activeSession = session
            if !session.start() {
                continuation.resume(throwing: ConnectorError.cancelled)
            }
        }
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene,
               let window = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return window
            }
        }
        return ASPresentationAnchor()
    }
}
