import Foundation

/// Extracts a creator handle from a shared TikTok or Instagram URL.
///
/// ## What is and isn't recoverable
///
/// TikTok puts the handle in the path (`/@user/video/123`), so almost every
/// TikTok share resolves. Short links (`vm.tiktok.com`, `vt.tiktok.com`,
/// `tiktok.com/t/...`) resolve after one redirect, which `ShortLinkResolver`
/// follows without authentication.
///
/// Instagram is the hard case, and it is a product constraint rather than a
/// parsing bug: `instagram.com/p/<shortcode>/` and `/reel/<shortcode>/` are
/// keyed by shortcode and contain **no username at all**. There is no
/// unauthenticated way to map one to the other — the web page is behind a login
/// wall and the official oEmbed endpoint requires an app token gated behind
/// Meta App Review. Those shares fall through to manual entry by design.
///
/// Instagram shares that *do* carry the handle, and which we therefore parse:
///   - `/<user>/p/<code>/` and `/<user>/reel/<code>/` (the "copy link" form
///     produced from a profile grid)
///   - `/stories/<user>/<id>/`
///   - bare profile links
public struct SharedLinkParser: Sendable {

    public init() {}

    private static let tiktokHosts: Set<String> = ["tiktok.com", "www.tiktok.com", "m.tiktok.com"]
    private static let tiktokShortHosts: Set<String> = ["vm.tiktok.com", "vt.tiktok.com"]
    private static let instagramHosts: Set<String> = ["instagram.com", "www.instagram.com",
                                                      "m.instagram.com", "instagr.am", "www.instagr.am"]
    private static let instagramShortHosts: Set<String> = ["ig.me", "l.instagram.com"]

    /// Parses a URL. Returns `nil` when the link isn't one of ours at all —
    /// which is different from "ours but unparseable", the latter being a
    /// `SharedLink` with a `nil` handle that the UI can offer manual entry for.
    public func parse(_ url: URL) -> SharedLink? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = normalisedHost(of: url)
        else { return nil }

        let segments = url.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }

        if Self.tiktokShortHosts.contains(host) {
            return SharedLink(platform: .tiktok, handle: nil, kind: .shortLink, canonicalURL: url)
        }
        if Self.tiktokHosts.contains(host) {
            return parseTikTok(segments: segments, url: url)
        }
        if Self.instagramShortHosts.contains(host) {
            return SharedLink(platform: .instagram, handle: nil, kind: .shortLink, canonicalURL: url)
        }
        if Self.instagramHosts.contains(host) {
            return parseInstagram(segments: segments, url: url)
        }
        return nil
    }

    // MARK: - Platform rules

    private func parseTikTok(segments: [String], url: URL) -> SharedLink {
        if let first = segments.first, first.hasPrefix("@") {
            let handle = CreatorHandle(platform: .tiktok, rawUsername: String(first.dropFirst()))
            let kind: SharedLinkKind = handle == nil ? .handleNotPresent
                                                     : (segments.count > 1 ? .post : .profile)
            return SharedLink(platform: .tiktok, handle: handle, kind: kind, canonicalURL: url)
        }
        // tiktok.com/t/ZTRxyz123/ is the web-surfaced short form.
        if segments.first == "t" {
            return SharedLink(platform: .tiktok, handle: nil, kind: .shortLink, canonicalURL: url)
        }
        // /v/<id>.html, /embed/..., /music/... carry no handle.
        return SharedLink(platform: .tiktok, handle: nil, kind: .handleNotPresent, canonicalURL: url)
    }

    private func parseInstagram(segments: [String], url: URL) -> SharedLink {
        guard let first = segments.first else {
            return SharedLink(platform: .instagram, handle: nil, kind: .handleNotPresent, canonicalURL: url)
        }

        if first == "stories", segments.count > 1 {
            let handle = CreatorHandle(platform: .instagram, rawUsername: segments[1])
            return SharedLink(platform: .instagram, handle: handle,
                              kind: handle == nil ? .handleNotPresent : .story, canonicalURL: url)
        }

        // A reserved first segment means shortcode-only: /p/, /reel/, /share/...
        if Platform.instagram.reservedPathSegments.contains(first.lowercased()) {
            return SharedLink(platform: .instagram, handle: nil, kind: .handleNotPresent, canonicalURL: url)
        }

        guard let handle = CreatorHandle(platform: .instagram, rawUsername: first) else {
            return SharedLink(platform: .instagram, handle: nil, kind: .handleNotPresent, canonicalURL: url)
        }

        if segments.count > 1, ["p", "reel", "reels", "tv"].contains(segments[1].lowercased()) {
            return SharedLink(platform: .instagram, handle: handle, kind: .post, canonicalURL: url)
        }
        if segments.count == 1 {
            return SharedLink(platform: .instagram, handle: handle, kind: .profile, canonicalURL: url)
        }
        return SharedLink(platform: .instagram, handle: nil, kind: .handleNotPresent, canonicalURL: url)
    }

    // MARK: - Host handling

    /// Lower-cases the host and strips userinfo/port. Note this matches the host
    /// *exactly* against an allow-list; `tiktok.com.evil.co` must not be treated
    /// as TikTok, which a naive `hasSuffix("tiktok.com")` check would allow.
    private func normalisedHost(of url: URL) -> String? {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        return host.isEmpty ? nil : host
    }
}
