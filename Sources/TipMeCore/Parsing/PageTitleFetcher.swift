import Foundation

public enum PageTitleFetchError: Error, Equatable, Sendable {
    case transport(String)
    case timedOut
}

/// What fetching the shared page directly turned up.
public struct FetchedPageMetadata: Equatable, Sendable {
    /// The page's `og:title` or `<title>`. Confirmed on a real device to be
    /// the account's **display name**, not its `@username` — "Pepsi UK on
    /// Instagram: caption", not "pepsiuk". Display names commonly don't match
    /// the username at all, so this is not, on its own, a reliable source of
    /// a handle to pay -- see `canonicalURL` below.
    public let title: String?
    /// The page's canonical link (`<link rel="canonical">` or `og:url`).
    /// Confirmed on a real post fetch: Instagram's canonical URL for a post
    /// is `instagram.com/<username>/p/<code>/` -- the *same* shape a
    /// profile-grid "copy link" share already produces, which
    /// `SharedLinkParser` already parses with full confidence.
    ///
    /// A second real fetch, this time of a Reel, confirmed this isn't
    /// universal: a Reel's canonical URL comes back as
    /// `instagram.com/reel/<code>/` -- no username at all, same shape as the
    /// original shortcode link. So this is the *most* reliable source when
    /// it names anyone, but posts and Reels aren't consistent about whether
    /// it does.
    public let canonicalURL: URL?
    /// The page's `og:description` (or `<meta name="description">`).
    /// Instagram's long-standing convention for this field is
    /// "N likes, N comments - Full Name (@username) on Instagram: caption"
    /// -- unlike the title, which only ever showed the display name on a
    /// real device, this is the one field actually known to carry the
    /// `@username` in prose. Last resort when neither of the above names
    /// anyone.
    public let description: String?

    public init(title: String?, canonicalURL: URL?, description: String? = nil) {
        self.title = title
        self.canonicalURL = canonicalURL
        self.description = description
    }
}

/// Recovers what a share's title and canonical link name, the way every
/// link-preview mechanism does: by fetching the page and reading its own
/// metadata, not by running any JavaScript.
///
/// ## Why this exists
///
/// Confirmed directly on a real device: Instagram does not hand a Reel or
/// post's identifying text to the share extension at all. What actually
/// arrives is a bare URL -- `titles` and `text` both empty, `urls` carrying
/// only `instagram.com/reel/<shortcode>/?stkn=...` or `.../p/<shortcode>/`.
/// The text a user sees in the system share sheet's own preview is built by
/// iOS itself and never handed back to the receiving extension.
///
/// A second real-device fetch confirmed *why* the title alone isn't enough:
/// Instagram's title reads "Pepsi UK on Instagram: caption" -- the account's
/// display name, not `@pepsiuk`. So the fetch also reads the page's
/// canonical URL, which -- also confirmed live, for a post -- names the
/// actual username in its path, the same shape `SharedLinkParser` already
/// trusts fully for a directly-shared profile link.
///
/// A third real-device fetch, this time of a Reel, showed that isn't
/// universal either: a Reel's canonical URL comes back with no username at
/// all. So the fetch also reads `og:description`, which follows Instagram's
/// long-standing "N likes, N comments - Name (@username) on Instagram:
/// caption" convention -- the one field actually known to carry the
/// `@username` in prose, used as the last resort of the three.
///
/// ## Constraints
///
/// This runs inside a memory- and time-capped share extension, and the page
/// in question is a multi-megabyte JavaScript application -- so this
/// deliberately:
///
///  - Reads a capped number of bytes rather than the whole response. This
///    metadata is always within the first few KB of `<head>`.
///  - Looks for exactly these fields rather than parsing HTML in any general
///    sense.
///  - Uses a short timeout, matching `ShortLinkResolver`'s.
public protocol PageMetadataFetching: Sendable {
    func metadata(for url: URL) async throws -> FetchedPageMetadata
}

public actor URLSessionPageMetadataFetcher: PageMetadataFetching {
    private let session: URLSession
    private let maximumBytes: Int

    public init(session: URLSession? = nil, timeout: TimeInterval = 5, maximumBytes: Int = 65_536) {
        self.maximumBytes = maximumBytes
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            config.httpCookieStorage = nil
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
    }

    public func metadata(for url: URL) async throws -> FetchedPageMetadata {
        var request = URLRequest(url: url)
        // Identify as Meta's own preview crawler rather than a generic bot.
        // A post fetch under a made-up UA came back with a title but no
        // canonical link; a Reel fetch under the same UA came back with
        // neither -- consistent with Instagram routing unrecognised
        // requesters to a stripped-down or login-walled page instead of the
        // full server-rendered one. `facebookexternalhit` is the identity
        // Meta's own products use to fetch link-preview metadata for
        // Messenger/WhatsApp/Facebook, so Instagram (Meta-owned) has every
        // reason to keep serving it the real page.
        request.setValue("facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        let html: String
        do {
            html = try await boundedBody(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw PageTitleFetchError.timedOut
        } catch let error as PageTitleFetchError {
            throw error
        } catch {
            throw PageTitleFetchError.transport(String(describing: error))
        }

        return Self.extractMetadata(from: html)
    }

    /// Streams the response and stops as soon as `maximumBytes` is read,
    /// instead of downloading the whole page.
    private func boundedBody(for request: URLRequest) async throws -> String {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PageTitleFetchError.transport("unexpected response")
        }
        var data = Data()
        data.reserveCapacity(maximumBytes)
        for try await byte in bytes {
            data.append(byte)
            if data.count >= maximumBytes { break }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func extractMetadata(from html: String) -> FetchedPageMetadata {
        FetchedPageMetadata(title: extractTitle(from: html),
                           canonicalURL: extractCanonicalURL(from: html),
                           description: extractDescription(from: html))
    }

    /// Prefers `og:title` -- the field every real preview mechanism reads --
    /// and falls back to the page `<title>`.
    static func extractTitle(from html: String) -> String? {
        if let og = firstMatch(ogTitlePattern, in: html) {
            return decodeHTMLEntities(og)
        }
        if let title = firstMatch(titleTagPattern, in: html) {
            return decodeHTMLEntities(title)
        }
        return nil
    }

    /// Prefers `<link rel="canonical">`, falling back to `og:url` -- both
    /// name the same URL in practice, but pages aren't always consistent
    /// about which one they bother to serve.
    static func extractCanonicalURL(from html: String) -> URL? {
        if let href = firstMatch(canonicalLinkPattern, in: html), let url = URL(string: decodeHTMLEntities(href)) {
            return url
        }
        if let href = firstMatch(ogURLPattern, in: html), let url = URL(string: decodeHTMLEntities(href)) {
            return url
        }
        return nil
    }

    /// Prefers `og:description`, falling back to `<meta name="description">`.
    static func extractDescription(from html: String) -> String? {
        if let og = firstMatch(ogDescriptionPattern, in: html) {
            return decodeHTMLEntities(og)
        }
        if let description = firstMatch(descriptionTagPattern, in: html) {
            return decodeHTMLEntities(description)
        }
        return nil
    }

    // Matches either attribute order: `property="og:title" content="..."`
    // or `content="..." property="og:title"` -- pages are not consistent
    // about this.
    private static let ogTitlePattern = try! NSRegularExpression(
        pattern: "<meta\\s+property=[\"']og:title[\"']\\s+content=[\"']([^\"']*)[\"']"
            + "|<meta\\s+content=[\"']([^\"']*)[\"']\\s+property=[\"']og:title[\"']",
        options: [.caseInsensitive])

    private static let titleTagPattern = try! NSRegularExpression(
        pattern: "<title[^>]*>([^<]*)</title>",
        options: [.caseInsensitive])

    private static let canonicalLinkPattern = try! NSRegularExpression(
        pattern: "<link\\s+rel=[\"']canonical[\"']\\s+href=[\"']([^\"']*)[\"']"
            + "|<link\\s+href=[\"']([^\"']*)[\"']\\s+rel=[\"']canonical[\"']",
        options: [.caseInsensitive])

    private static let ogURLPattern = try! NSRegularExpression(
        pattern: "<meta\\s+property=[\"']og:url[\"']\\s+content=[\"']([^\"']*)[\"']"
            + "|<meta\\s+content=[\"']([^\"']*)[\"']\\s+property=[\"']og:url[\"']",
        options: [.caseInsensitive])

    private static let ogDescriptionPattern = try! NSRegularExpression(
        pattern: "<meta\\s+property=[\"']og:description[\"']\\s+content=[\"']([^\"']*)[\"']"
            + "|<meta\\s+content=[\"']([^\"']*)[\"']\\s+property=[\"']og:description[\"']",
        options: [.caseInsensitive])

    private static let descriptionTagPattern = try! NSRegularExpression(
        pattern: "<meta\\s+name=[\"']description[\"']\\s+content=[\"']([^\"']*)[\"']"
            + "|<meta\\s+content=[\"']([^\"']*)[\"']\\s+name=[\"']description[\"']",
        options: [.caseInsensitive])

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        // Each pattern has two alternative capture groups depending on
        // attribute order (one for the title-tag pattern); take whichever matched.
        for groupIndex in 1..<match.numberOfRanges {
            if let captured = Range(match.range(at: groupIndex), in: text) {
                let value = String(text[captured]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// Not general HTML-entity decoding (that needs a full parse) -- just
    /// the handful that actually show up in a title or URL.
    private static func decodeHTMLEntities(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
