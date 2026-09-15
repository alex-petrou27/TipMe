import Foundation

public enum Platform: String, Codable, Sendable, CaseIterable {
    case tiktok
    case instagram

    public var displayName: String {
        switch self {
        case .tiktok: return "TikTok"
        case .instagram: return "Instagram"
        }
    }
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
        }
    }
}
