import Foundation

/// Pulls candidate URLs out of whatever the OS share sheet handed us.
///
/// This is messier than it sounds. TikTok's "Share to" does not always provide
/// a clean `public.url` attachment: frequently it provides `public.plain-text`
/// containing marketing copy with the link embedded, e.g.
///
///     "Check out this video! https://vm.tiktok.com/ZMhvJqKXn/  #fyp"
///
/// Safari and Chrome provide a proper URL attachment. Instagram varies by
/// version. So we accept both shapes and scan text for links rather than
/// assuming a well-formed payload.
public struct SharedPayloadExtractor: Sendable {

    public init() {}

    /// Ordered candidates: explicit URL attachments first, then anything found
    /// inside shared text. Order matters — an explicit attachment is more
    /// trustworthy than a link scraped out of a caption that may itself contain
    /// other people's links.
    public func candidateURLs(attachedURLs: [URL], sharedText: [String]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        func append(_ url: URL) {
            let key = url.absoluteString.lowercased()
            if seen.insert(key).inserted { result.append(url) }
        }

        for url in attachedURLs { append(url) }
        for text in sharedText {
            for url in Self.urls(in: text) { append(url) }
        }
        return result
    }

    /// Finds http(s) URLs inside free text.
    public static func urls(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: range).compactMap { match in
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return nil }
            return url
        }
    }

    /// Runs the candidates through the parser and returns the best one: a link
    /// with a handle beats a short link that still needs resolving, which beats
    /// a recognised-but-unparseable link.
    public func bestLink(from candidates: [URL], parser: SharedLinkParser = SharedLinkParser()) -> SharedLink? {
        let parsed = candidates.compactMap { parser.parse($0) }
        return parsed.first(where: { $0.handle != nil })
            ?? parsed.first(where: { $0.needsRedirectResolution })
            ?? parsed.first
    }
}
