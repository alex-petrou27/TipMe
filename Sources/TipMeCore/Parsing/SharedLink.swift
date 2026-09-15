import Foundation

/// What a shared URL turned out to be.
public enum SharedLinkKind: String, Equatable, Sendable {
    /// A post/video/photo URL that carried the creator's handle.
    case post
    /// A profile URL.
    case profile
    /// An Instagram story URL (these do carry the handle).
    case story
    /// A short link that must be followed before anything can be read from it.
    case shortLink
    /// Recognised as the platform's, but with no handle anywhere in it.
    case handleNotPresent
}

public struct SharedLink: Equatable, Sendable {
    public let platform: Platform
    public let handle: CreatorHandle?
    public let kind: SharedLinkKind
    public let canonicalURL: URL

    public init(platform: Platform, handle: CreatorHandle?, kind: SharedLinkKind, canonicalURL: URL) {
        self.platform = platform
        self.handle = handle
        self.kind = kind
        self.canonicalURL = canonicalURL
    }

    public var needsRedirectResolution: Bool { kind == .shortLink }
}
