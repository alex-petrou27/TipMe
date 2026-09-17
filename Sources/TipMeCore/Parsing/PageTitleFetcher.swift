import Foundation

public enum PageTitleFetchError: Error, Equatable, Sendable {
    case transport(String)
    case timedOut
}

/// Recovers a share's title the way every link-preview mechanism does: by
/// fetching the page and reading its Open Graph title, not by running any
/// JavaScript.
///
/// ## Why this exists
///
/// Confirmed directly on a real device: Instagram does not hand a Reel's
/// "Reel from username" text to the share extension at all. What actually
/// arrives is a bare URL — `titles` and `text` both empty, `urls` carrying
/// only `instagram.com/reel/<shortcode>/?stkn=...`. The text a user sees in
/// the system share sheet's own preview is something iOS builds itself, and
/// it is never hands back to the receiving extension.
///
/// iOS's preview almost certainly works the same way every other client
/// that renders a link preview without running JavaScript does — Messages,
/// WhatsApp, Slack, Twitter — by fetching the page and reading the
/// `og:title` meta tag Instagram serves in the plain server-rendered HTML
/// specifically so that those previews can exist at all. This does the
/// same fetch.
///
/// ## Constraints
///
/// This runs inside a memory- and time-capped share extension, and the
/// page in question is a multi-megabyte JavaScript application — so this
/// deliberately:
///
///  - Reads a capped number of bytes rather than the whole response. The
///    title is always within the first few KB of `<head>`.
///  - Looks for exactly one thing (`og:title`, falling back to `<title>`)
///    rather than parsing HTML in any general sense.
///  - Uses a short timeout, matching `ShortLinkResolver`'s.
public protocol PageTitleFetching: Sendable {
    func title(for url: URL) async throws -> String?
}

public actor URLSessionPageTitleFetcher: PageTitleFetching {
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

    public func title(for url: URL) async throws -> String? {
        var request = URLRequest(url: url)
        // A generic UA that identifies as a preview fetcher rather than a
        // browser. Sites serve Open Graph tags in server-rendered HTML
        // specifically so a client that never runs JavaScript can still
        // build a preview from them -- that is exactly what this is.
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

        return Self.extractTitle(from: html)
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

    /// Prefers `og:title` — the field every real preview mechanism reads —
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

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        // og:title's pattern has two alternative capture groups depending on
        // attribute order; <title>'s has one. Take whichever matched.
        for groupIndex in 1..<match.numberOfRanges {
            if let captured = Range(match.range(at: groupIndex), in: text) {
                let value = String(text[captured]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// Not general HTML-entity decoding (that needs a full parse) -- just
    /// the handful that actually show up in a title.
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
