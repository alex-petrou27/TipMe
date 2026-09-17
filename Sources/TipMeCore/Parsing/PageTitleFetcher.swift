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
    /// Confirmed on the same real device fetch: Instagram's canonical URL for
    /// a post is `instagram.com/<username>/p/<code>/` -- the *same* shape a
    /// profile-grid "copy link" share already produces, which
    /// `SharedLinkParser` already parses with full confidence. This is the
    /// reliable path; `title` is a fallback for pages that omit it.
    public let canonicalURL: URL?

    public init(title: String?, canonicalURL: URL?) {
        self.title = title
        self.canonicalURL = canonicalURL
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
/// canonical URL, which -- also confirmed live -- names the actual username
/// in its path, the same shape `SharedLinkParser` already trusts fully for a
/// directly-shared profile link.
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
        // A generic UA that identifies as a preview fetcher rather than a
        // browser. Sites serve this metadata in server-rendered HTML
        // specifically so a client that never runs JavaScript can still
        // build a preview from it -- that is exactly what this is.
        request.setValue("Mozilla/5.0 (compatible; TipMe/1.0; link-preview)",
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
        FetchedPageMetadata(title: extractTitle(from: html), canonicalURL: extractCanonicalURL(from: html))
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
