import XCTest
@testable import TipMeCore

/// Instagram Reel and post URLs are shortcode-keyed and name nobody, but the
/// share sheet header reads "Reel from username" — confirmed on a real device,
/// no `@` — and that string reaches the extension as the item's title. These
/// tests cover the only place the creator appears for a Reel share.
final class ShareTitleParserTests: XCTestCase {

    private let parser = ShareTitleParser()

    private func handle(_ title: String, _ platform: Platform = .instagram) -> String? {
        parser.handle(in: title, platform: platform)?.username
    }

    // MARK: - The shapes Instagram and TikTok actually produce

    func testReelFromAttribution() {
        XCTAssertEqual(handle("Reel from @natgeo"), "natgeo")
        XCTAssertEqual(handle("Reel from @charli.damelio"), "charli.damelio")
        XCTAssertEqual(handle("Post from @natgeo"), "natgeo")
        XCTAssertEqual(handle("Photo from @nat_geo.official"), "nat_geo.official")
        XCTAssertEqual(handle("Video from @someone"), "someone")
    }

    /// The actual, confirmed-on-device shape: Instagram's own generated
    /// header has no `@` at all. This was broken for a while — every real
    /// Reel share fell through to "we couldn't tell whose Reel that is"
    /// because every rule required an `@` that Instagram never sends.
    func testRealInstagramGeneratedHeaderHasNoAtSign() {
        XCTAssertEqual(handle("Reel from yahoofinance"), "yahoofinance")
        XCTAssertEqual(handle("Post from natgeo"), "natgeo")
        XCTAssertEqual(handle("Reel from charli.damelio"), "charli.damelio")
        XCTAssertEqual(handle("IGTV from someone"), "someone")
    }

    func testGeneratedHeaderWithTrailingPunctuation() {
        XCTAssertEqual(handle("Reel from yahoofinance."), "yahoofinance")
        XCTAssertEqual(handle("Reel from yahoofinance!"), "yahoofinance")
        XCTAssertEqual(handle("Reel from yahoofinance "), "yahoofinance")
    }

    /// The no-@ rule is anchored to the whole title specifically so it
    /// cannot misfire on ordinary prose that happens to contain "from" —
    /// this is the false-positive risk that made requiring @ seem necessary
    /// in the first place.
    func testGeneratedHeaderRuleDoesNotMisfireOnOrdinaryProse() {
        XCTAssertNil(handle("Highlights from today's game"))
        XCTAssertNil(handle("Clips from my trip to Rome"))
        XCTAssertNil(handle("A message from the team"))
        XCTAssertNil(handle("Reel from my favourite creator this week"))
    }

    func testByAttribution() {
        XCTAssertEqual(handle("Reel by @zachking"), "zachking")
    }

    func testOnPlatformForm() {
        XCTAssertEqual(handle("@natgeo on Instagram"), "natgeo")
        XCTAssertEqual(handle("@zachking on TikTok", .tiktok), "zachking")
    }

    /// Instagram's own long-standing page-title convention for a fetched
    /// og:title, as opposed to the share sheet's own generated header:
    /// "Jane Doe (@natgeo) on Instagram: caption text".
    func testOnPlatformFormWithParenthesesAroundTheMention() {
        XCTAssertEqual(handle("Jane Doe (@natgeo) on Instagram: \"Caption text\""), "natgeo")
        XCTAssertEqual(handle("Some Creator (@zachking) on TikTok", .tiktok), "zachking")
    }

    /// Instagram's actual current `og:description` convention, confirmed on
    /// a real device fetch of a Reel: "182K likes, 5,289 comments -
    /// vroomjuicy on August 25, 2026: caption" -- the username sits bare, no
    /// `@`, between the comment count and "on <date>" rather than
    /// "on Instagram".
    func testDescriptionEngagementCountPrefix() {
        XCTAssertEqual(
            handle("182K likes, 5,289 comments - vroomjuicy on August 25, 2026: \"You not slick unc\""),
            "vroomjuicy")
        XCTAssertEqual(handle("50 likes, 2 comments - natgeo on March 3, 2023: \"caption\""), "natgeo")
        XCTAssertEqual(handle("1 like, 1 comment - zachking on Jan 1, 2024", .tiktok), "zachking")
    }

    /// The engagement-count anchor is specific enough that it shouldn't
    /// misfire on ordinary prose that happens to mention likes or comments.
    func testDescriptionEngagementPrefixDoesNotMisfireOnOrdinaryProse() {
        XCTAssertNil(handle("I really liked the comments on this one"))
        XCTAssertNil(handle("Likes and comments are turned off"))
    }

    func testCasingIsNormalised() {
        XCTAssertEqual(handle("Reel from @NatGeo"), "natgeo")
        XCTAssertEqual(handle("REEL FROM @NATGEO"), "natgeo")
    }

    func testTrailingPunctuationIsNotPartOfTheHandle() {
        XCTAssertEqual(handle("Reel from @natgeo."), "natgeo")
        XCTAssertEqual(handle("Reel from @natgeo!"), "natgeo")
        XCTAssertEqual(handle("Reel from @natgeo (2024)"), "natgeo")
        XCTAssertEqual(handle("Reel from @natgeo/"), "natgeo")
    }

    func testSingleBareMentionIsAccepted() {
        XCTAssertEqual(handle("@natgeo"), "natgeo")
        XCTAssertEqual(handle("Check out @zachking", .tiktok), "zachking")
    }

    // MARK: - Declining rather than guessing

    /// Paying the wrong creator is unrecoverable, so an ambiguous title yields
    /// nothing and the user is offered manual entry instead.
    func testMultipleDistinctMentionsAreRefused() {
        XCTAssertNil(handle("@natgeo tagged @nasa and @esa"))
        XCTAssertNil(handle("@nasa @esa @natgeo"))
    }

    /// An explicit attribution still wins when other accounts are mentioned:
    /// "Reel from @natgeo ft. @nasa" is unambiguously about @natgeo.
    func testExplicitAttributionBeatsOtherMentions() {
        XCTAssertEqual(handle("Reel from @natgeo ft. @nasa"), "natgeo")
        XCTAssertEqual(handle("Reel from @natgeo, questions to help@instagram.com"), "natgeo")
    }

    /// Without a lookbehind on the `@`, "support@instagram.com" yields a
    /// creator called `instagram.com` and tips would go to whoever claimed it.
    func testEmailAddressesAreNotMentions() {
        XCTAssertNil(handle("Contact support@instagram.com"))
        XCTAssertNil(handle("email me at hi@natgeo.com"))
        XCTAssertNil(handle("user@example.com", .tiktok))
    }

    func testTitlesWithNoHandleYieldNothing() {
        XCTAssertNil(handle("Reel"))
        XCTAssertNil(handle("Instagram"))
        XCTAssertNil(handle(""))
        XCTAssertNil(handle("   "))
        XCTAssertNil(handle("Shared via Instagram"))
    }

    func testReservedWordsAreNotCreators() {
        XCTAssertNil(handle("Reel from @explore"))
        XCTAssertNil(handle("Post from @accounts"))
        XCTAssertNil(handle("Video from @discover", .tiktok))
    }

    func testPlatformLengthLimitsApply() {
        XCTAssertEqual(handle("Reel from @" + String(repeating: "a", count: 30)),
                       String(repeating: "a", count: 30))
        XCTAssertNil(handle("Reel from @" + String(repeating: "a", count: 31)))
        XCTAssertNil(handle("Video from @" + String(repeating: "a", count: 25), .tiktok))
    }

    // MARK: - Multiple candidate titles

    func testTriesEveryCandidateTitleInOrder() {
        let handle = parser.handle(inAnyOf: ["Instagram", "", "Reel from @natgeo"],
                                   platform: .instagram)
        XCTAssertEqual(handle?.username, "natgeo")
    }

    func testReturnsNilWhenNoCandidateNamesAnyone() {
        XCTAssertNil(parser.handle(inAnyOf: ["Instagram", "Reel", ""], platform: .instagram))
    }

    // MARK: - Fetched page: the poster, never the caption's mentions
    //
    // Every string below is a real Instagram description/title fetched live
    // (captions trimmed). Each of these was resolved to the *wrong* account
    // by the share-sheet rules -- `handle(in:)` -- before these existed.

    private func author(inDescription text: String) -> String? {
        parser.authorHandle(inFetchedDescription: text, platform: .instagram)?.username
    }

    func testPhotoCreditInTheCaptionDoesNotBecomeTheCreator() {
        // Real: natgeo's post, credited to a photographer.
        XCTAssertEqual(author(inDescription:
            "70K likes, 128 comments - natgeo on September 19, 2026: \"Some snowy mountain tops. Photograph by @renan_ozturk\""),
            "natgeo")
        // ...and the old rules do exactly the wrong thing with the same text,
        // which is the whole reason the new ones exist.
        XCTAssertEqual(parser.handle(in:
            "70K likes, 128 comments - natgeo on September 19, 2026: \"Some snowy mountain tops. Photograph by @renan_ozturk\"",
            platform: .instagram)?.username, "renan_ozturk")
    }

    func testSponsorTagInTheCaptionDoesNotBecomeTheCreator() {
        XCTAssertEqual(author(inDescription:
            "75K likes, 449 comments - natgeo on September 10, 2026: \"Presented by @Rolex. Welcome to Africa\""),
            "natgeo")
    }

    func testCollaboratorPostIsAttributedToItsOwnPoster() {
        // Real: appears on nasa's grid but is astro_jessica's post, and the
        // caption mentions @iss.
        XCTAssertEqual(author(inDescription:
            "9,210 likes, 61 comments - astro_jessica on September 12, 2026: \"Working aboard @iss\""),
            "astro_jessica")
    }

    func testAccountsThatHideLikesOrCommentsAreStillRecognised() {
        XCTAssertEqual(author(inDescription: "449 comments - natgeo on September 10, 2026: \"x\""), "natgeo")
        XCTAssertEqual(author(inDescription: "75K likes - natgeo on September 10, 2026: \"x\""), "natgeo")
        XCTAssertEqual(author(inDescription: "natgeo on September 10, 2026: \"x\""), "natgeo")
    }

    func testCountFormatsAreAllRecognised() {
        XCTAssertEqual(author(inDescription: "1M likes, 3,102 comments - natgeo on September 18, 2026: \"x\""), "natgeo")
        XCTAssertEqual(author(inDescription: "1.2M likes, 45K comments - a.b_c on 3 September 2026: \"x\""), "a.b_c")
    }

    func testAMultiWordDisplayNameBeforeOnInstagramIsNotAUsername() {
        XCTAssertNil(author(inDescription: "500 likes, 12 comments - Luke Hamnett on Instagram: \"caption\""))
    }

    func testCaptionTextAloneNeverNamesAnyone() {
        XCTAssertNil(author(inDescription: "Photograph by @renan_ozturk on September 19, 2026"))
        XCTAssertNil(author(inDescription: "Follow @natgeo on Instagram"))
        XCTAssertNil(author(inDescription: ""))
    }

    func testFetchedTitleOnlyReadsTheAccountNamedBeforeOnInstagram() {
        // Real shape: display name, no username, credit inside the caption.
        XCTAssertNil(parser.authorHandle(inFetchedTitle:
            "National Geographic on Instagram: \"Some snowy mountain tops. Photograph by @renan_ozturk\"",
            platform: .instagram))
        XCTAssertNil(parser.authorHandle(inFetchedTitle:
            "National Geographic on Instagram: \"Follow @someone on Instagram: for more\"",
            platform: .instagram))
        // The older, username-bearing shape is still honoured.
        XCTAssertEqual(parser.authorHandle(inFetchedTitle:
            "National Geographic (@natgeo) on Instagram: \"caption\"", platform: .instagram)?.username,
            "natgeo")
    }
}
