import Foundation

public enum Platform: String, Codable, Sendable, CaseIterable {
    case tiktok
    case instagram
    // YouTube and X exist only for the identity-only "sending as" connect
    // flow in Settings (see SocialAccountConnector.connectIdentity) --
    // signing in proves a username, nothing more, so none of the creator
    // claiming/tipping machinery (handles.py's PLATFORMS, CreatorHandle
    // validation) needs to know about them. `allCases` is overridden below
    // to exclude them for exactly that reason: every other picker in the
    // app that iterates `Platform.allCases` is a creator-claim picker, and
    // showing a platform there that the registry can't actually validate
    // a handle for would fail with a confusing "unknown platform" error
    // instead of the honest "not configured yet" the connect buttons give.
    case youtube
    case x

    public var displayName: String {
        switch self {
        case .tiktok: return "TikTok"
        case .instagram: return "Instagram"
        case .youtube: return "YouTube"
        case .x: return "X"
        }
    }

    public static var allCases: [Platform] { [.tiktok, .instagram] }
}

/// A validated creator handle, always stored lower-cased so that registry
/// lookups and rate-limit buckets can't be split by casing.
public struct CreatorHandle: Equatable, Hashable, Codable, Sendable {
    public let platform: Platform
    public let username: String

    /// Fails for anything that isn't a plausible username on that platform.
    /// Rejecting here rather than at the network edge means a malformed or
    /// hostile share payload can never reach the registry client.
    public init?(platform: Platform, rawUsername: String) {
        var candidate = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if candidate.hasPrefix("@") { candidate.removeFirst() }
        // Trailing dots are legal to type but not part of the handle, and a
        // path segment of ".." must never survive into a URL we construct.
        while candidate.hasSuffix(".") { candidate.removeLast() }

        guard !candidate.isEmpty,
              !candidate.contains(".."),
              candidate.count <= platform.maximumUsernameLength,
              candidate.allSatisfy({ $0.isASCII && (($0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "_" || $0 == ".") }),
              !platform.reservedPathSegments.contains(candidate)
        else { return nil }

        self.platform = platform
        self.username = candidate
    }

    public var displayName: String { "@" + username }

    /// Stable key for rate limiting and audit correlation.
    public var registryKey: String { "\(platform.rawValue):\(username)" }
}

extension Platform {
    var maximumUsernameLength: Int {
        switch self {
        case .tiktok: return 24
        case .instagram: return 30
        // Not reachable via CreatorHandle today (see the doc comment on
        // `Platform` above) -- real platform values kept anyway so this
        // switch stays exhaustive without a `default` hiding a future gap.
        case .youtube: return 30
        case .x: return 15
        }
    }

    /// Path segments that are routes, not people. Without this, a share of
    /// `instagram.com/accounts/login/` would resolve to a "creator" called
    /// `accounts` and we would happily look it up.
    var reservedPathSegments: Set<String> {
        switch self {
        case .tiktok:
            return ["t", "v", "embed", "music", "tag", "discover", "foryou",
                    "following", "live", "upload", "search", "about", "legal",
                    "business", "creators", "node", "share"]
        case .instagram:
            return ["p", "reel", "reels", "tv", "stories", "explore", "share",
                    "accounts", "direct", "about", "developer", "legal",
                    "privacy", "terms", "s", "challenge", "emails", "sessions",
                    "web", "api", "oauth", "graphql", "invites", "help", "press"]
        case .youtube:
            return ["watch", "channel", "c", "feed", "results", "playlist",
                    "shorts", "live", "about", "upload", "gaming"]
        case .x:
            return ["home", "explore", "notifications", "messages", "i",
                    "search", "settings", "compose", "login", "signup"]
        }
    }
}
