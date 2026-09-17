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
}
