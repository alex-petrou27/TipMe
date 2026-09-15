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
    /// Where `handle` came from. Recorded in the audit log so a
    /// misidentification can be traced back to the source that produced it.
    public let handleSource: HandleSource?

    public init(platform: Platform, handle: CreatorHandle?, kind: SharedLinkKind,
                canonicalURL: URL, handleSource: HandleSource? = nil) {
        self.platform = platform
        self.handle = handle
        self.kind = kind
        self.canonicalURL = canonicalURL
        self.handleSource = handleSource ?? (handle == nil ? nil : .url)
    }

    /// Returns a copy carrying a handle recovered from somewhere other than the
    /// URL — used when the URL is shortcode-only but the share title names the
    /// creator.
    public func adoptingHandle(_ handle: CreatorHandle, from source: HandleSource) -> SharedLink {
        SharedLink(platform: platform,
                   handle: handle,
                   kind: kind == .handleNotPresent ? .post : kind,
                   canonicalURL: canonicalURL,
                   handleSource: source)
    }

    public var needsRedirectResolution: Bool { kind == .shortLink }
}
