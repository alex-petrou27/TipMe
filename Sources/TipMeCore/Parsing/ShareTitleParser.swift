import Foundation

/// Where a creator handle came from, which is not a detail — it determines how
/// much we should trust it.
public enum HandleSource: String, Equatable, Sendable {
    /// Read out of the URL path, e.g. `tiktok.com/@user/video/123`. Highest
    /// confidence: the platform put it there.
    case url
    /// Read out of the share sheet's own title, e.g. "Reel from @natgeo".
    /// High confidence, but prose rather than a structured field — which is
    /// why the extraction rules below decline rather than guess. As with every
    /// other source, the handle is shown on the amount picker and again on the
    /// confirm screen before anything is sent.
    case shareTitle
    /// The user typed or pasted a destination themselves.
    case manual
}

/// Recovers a creator handle from the share sheet's title.
///
/// ## Why this matters
///
/// Instagram Reel and post URLs are shortcode-keyed and carry no username, so
/// for a long time the assumption was that those shares were unidentifiable
/// without Meta App Review. That was wrong: **the handle is in the payload, it
/// is just not in the URL.** When Instagram shares a Reel, the system share
/// sheet's header reads "Reel from username", and that string reaches the
/// extension as the item's title.
///
/// So a Reel share is identifiable after all, with no API access at all.
///
/// Confirmed directly against a real device: Instagram's own generated header
/// has **no `@`** before the username at all — "Reel from yahoofinance", not
/// "Reel from @yahoofinance". An earlier version of this parser assumed the
/// `@` would be there, which meant it could never match a real Instagram
/// share and every Reel fell through to manual entry. See
/// `generatedHeaderAttribution` below for the fix and why it stays safe.
///
/// ## Why it is conservative
///
/// Titles are prose, not a structured field. A caption that tags other accounts
/// would let a naive "first @mention wins" rule tip the wrong person, which is
/// unrecoverable. The rules are therefore ordered by confidence and decline
/// rather than guess:
///
/// 0. Instagram's own generated header, anchored to the *entire* title —
///    "Reel from username" and nothing else.
/// 1. An explicit attribution — "Reel **from** @user", "Post **by** @user".
/// 2. "@user **on** Instagram".
/// 3. Instagram's description engagement-count prefix — "N likes, N
///    comments - username **on** <date>".
/// 4. A single unambiguous mention. If the title mentions more than one
///    distinct account, nothing is returned.
public struct ShareTitleParser: Sendable {

    public init() {}

    /// A mention must not follow a word character. Without this,
    /// "support@instagram.com" yields a creator called `instagram.com`.
    private static let mentionPrefix = "(?<![A-Za-z0-9._])@"
    private static let username = "([A-Za-z0-9._]+)"

    /// Instagram's own generated share-sheet header for a Reel or post —
    /// "Reel from yahoofinance" — not user-authored prose, and it has no `@`
    /// before the username. Matching a username with no `@` prefix would
    /// normally be far too loose ("Highlights from today" would "recover" a
    /// creator called `today`), so this is anchored to the *entire* trimmed
    /// title: exactly one leading word (the content type — "Reel", "Post",
    /// "IGTV", whatever Instagram calls it), then "from"/"by", then the
    /// username, then nothing else. A real caption essentially never has
    /// that exact three-token shape, so this is as safe as the `@`-requiring
    /// rules below despite not requiring the `@`.
    private static let generatedHeaderAttribution = try! NSRegularExpression(
        pattern: "^\\S+\\s+(?:from|by)\\s+" + username + "[\\s!.,;:)/]*$",
        options: [.caseInsensitive])

    private static let attribution = try! NSRegularExpression(
        pattern: "\\b(?:from|by)\\s+" + mentionPrefix + username,
        options: [.caseInsensitive])

    // `\)?` tolerates Instagram's own long-standing page-title convention --
    // "Jane Doe (@natgeo) on Instagram: ..." -- where a closing paren sits
    // between the mention and "on Instagram". This is what a fetched
    // og:title looks like, as opposed to the share sheet's own header.
    private static let onPlatform = try! NSRegularExpression(
        pattern: mentionPrefix + username + "\\)?\\s+on\\s+(?:instagram|tiktok)",
        options: [.caseInsensitive])

    /// Instagram's actual current `og:description` convention, confirmed on a
    /// real device fetch: "182K likes, 5,289 comments - vroomjuicy on August
    /// 25, 2026: "caption"" -- the username sits bare, with **no `@`**,
    /// between the comment count and "on <date>" (not "on Instagram" the way
    /// the title-shaped rule above expects). The "N likes, N comments -"
    /// prefix this requires essentially never occurs outside this exact
    /// field, so matching without an `@` is as safe here as it is for
    /// `generatedHeaderAttribution` above.
    private static let descriptionEngagementPrefix = try! NSRegularExpression(
        pattern: "[\\d,.]+\\+?\\s*[KkMm]?\\s+likes?,\\s*[\\d,.]+\\+?\\s*[KkMm]?\\s+comments?\\s*-\\s*"
            + username + "\\s+on\\s",
        options: [.caseInsensitive])

    private static let anyMention = try! NSRegularExpression(
        pattern: mentionPrefix + username,
        options: [])

    /// Extracts a handle, or `nil` if the title does not unambiguously name one.
    public func handle(in title: String, platform: Platform) -> CreatorHandle? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 0. Instagram's own generated header — "Reel from yahoofinance",
        //    no @ at all. This is what a real Reel share actually produces,
        //    so it goes first.
        if let handle = firstMatch(Self.generatedHeaderAttribution, in: trimmed, platform: platform) {
            return handle
        }

        // 1. Explicit attribution wins even when other accounts are mentioned:
        //    "Reel from @natgeo ft. @nasa" is about @natgeo.
        if let handle = firstMatch(Self.attribution, in: trimmed, platform: platform) {
            return handle
        }

        // 2. "@natgeo on Instagram"
        if let handle = firstMatch(Self.onPlatform, in: trimmed, platform: platform) {
            return handle
        }

        // 3. Instagram's description engagement-count prefix -- "N likes, N
        //    comments - username on <date>: caption". No @ sign, but the
        //    distinctive "likes, ... comments -" anchor keeps this safe.
        if let handle = firstMatch(Self.descriptionEngagementPrefix, in: trimmed, platform: platform) {
            return handle
        }

        // 4. A single distinct mention is unambiguous. Several are not, and
        //    guessing between them risks paying the wrong person.
        let mentions = allMatches(Self.anyMention, in: trimmed, platform: platform)
        let distinct = Set(mentions.map(\.username))
        return distinct.count == 1 ? mentions.first : nil
    }

    /// Tries several candidate strings in order — a share may provide a title,
    /// a subject and link metadata, and only one of them may carry the handle.
    public func handle(inAnyOf titles: [String], platform: Platform) -> CreatorHandle? {
        for title in titles {
            if let handle = handle(in: title, platform: platform) { return handle }
        }
        return nil
    }

    // MARK: - Fetched page metadata: who *posted* it, never who it mentions

    // Everything above is written for the share sheet's own generated header
    // ("Reel from yahoofinance") -- short text with no caption in it. A page
    // we fetch ourselves is different: its og:title is `Display Name on
    // Instagram: "<the whole caption>"` and its description is `75K likes,
    // 449 comments - natgeo on September 10, 2026: "<the whole caption>"`.
    // Run through the rules above, the caption wins: "Photograph by
    // @renan_ozturk" reads as an attribution, "Presented by @Rolex" as
    // another, and a single tagged account as an "unambiguous mention" --
    // so the tip goes to the photographer or the sponsor instead of the
    // account that posted. Measured against 32 real posts and Reels from
    // three accounts, that picked the wrong account 11 times and the right
    // one 21; anchoring on the poster's own slot picked right 32 of 32.
    //
    // These two never look inside the caption at all.

    /// `[likes,] [comments] - <author> on <date>` at the very start of the
    /// text. Likes and comments are each optional (an account can hide
    /// either), and the date shape is required so a multi-word display name
    /// before "on Instagram" can never satisfy the single-token username.
    private static let fetchedDescriptionAuthor = try! NSRegularExpression(
        pattern: #"^\s*(?:[\d,.]+\+?\s*[KkMmBb]?\s+likes?\s*,?\s*)?(?:[\d,.]+\+?\s*[KkMmBb]?\s+comments?\s*)?(?:-\s*)?([A-Za-z0-9._]+)\s+on\s+(?:[A-Z][a-z]+\s+\d{1,2},\s*\d{4}|\d{1,2}\s+[A-Z][a-z]+\s+\d{4})"#,
        options: [])

    /// Everything before `on Instagram:` -- the part that names the account,
    /// as opposed to the caption after it.
    private static let fetchedTitlePrefix = try! NSRegularExpression(
        pattern: #"^(.*?)\s+on\s+(?:Instagram|TikTok)\s*:"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    private static let parenthesisedMention = try! NSRegularExpression(
        pattern: #"\(@([A-Za-z0-9._]+)\)"#,
        options: [])

    /// The account that posted, from a fetched page's description. Returns
    /// nil rather than guessing when the text doesn't start with that shape.
    public func authorHandle(inFetchedDescription description: String, platform: Platform) -> CreatorHandle? {
        firstMatch(Self.fetchedDescriptionAuthor, in: description, platform: platform)
    }

    /// The account that posted, from a fetched page's title -- only if the
    /// title puts `(@username)` *before* `on Instagram:`. Instagram's
    /// current titles usually carry a display name and no username there, so
    /// this often finds nothing; that is the point, since the alternative is
    /// reading a username out of the caption.
    public func authorHandle(inFetchedTitle title: String, platform: Platform) -> CreatorHandle? {
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        guard let match = Self.fetchedTitlePrefix.firstMatch(in: title, options: [], range: range),
              let prefixRange = Range(match.range(at: 1), in: title)
        else { return nil }
        return firstMatch(Self.parenthesisedMention, in: String(title[prefixRange]), platform: platform)
    }

    // MARK: - Matching

    private func firstMatch(_ regex: NSRegularExpression,
                            in text: String,
                            platform: Platform) -> CreatorHandle? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let captured = Range(match.range(at: 1), in: text)
        else { return nil }
        return CreatorHandle(platform: platform, rawUsername: String(text[captured]))
    }

    private func allMatches(_ regex: NSRegularExpression,
                            in text: String,
                            platform: Platform) -> [CreatorHandle] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let captured = Range(match.range(at: 1), in: text) else { return nil }
            return CreatorHandle(platform: platform, rawUsername: String(text[captured]))
        }
    }
}
