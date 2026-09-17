import XCTest
@testable import TipMeCore

/// `extractTitle` is the pure part of the fetcher — no network needed — and
/// it's the part that actually has to match real page HTML, so it's tested
/// directly against the shapes real sites are known to serve.
final class PageTitleFetcherTests: XCTestCase {

    private func extract(_ html: String) -> String? {
        URLSessionPageTitleFetcher.extractTitle(from: html)
    }

    func testPrefersOgTitleOverTitleTag() {
        let html = """
        <html><head>
        <title>Instagram</title>
        <meta property="og:title" content="Jane Doe (@natgeo) on Instagram: &quot;Caption&quot;">
        </head></html>
        """
        XCTAssertEqual(extract(html), "Jane Doe (@natgeo) on Instagram: \"Caption\"")
    }

    func testOgTitleWithReversedAttributeOrder() {
        let html = """
        <meta content="Jane Doe (@natgeo) on Instagram" property="og:title">
        """
        XCTAssertEqual(extract(html), "Jane Doe (@natgeo) on Instagram")
    }

    func testFallsBackToTitleTagWhenNoOgTitlePresent() {
        let html = "<html><head><title>Some Video - TikTok</title></head></html>"
        XCTAssertEqual(extract(html), "Some Video - TikTok")
    }

    func testDecodesCommonHtmlEntities() {
        let html = #"<meta property="og:title" content="Fish &amp; Chips &#39;n&#39; more &lt;3">"#
        XCTAssertEqual(extract(html), "Fish & Chips 'n' more <3")
    }

    func testReturnsNilWhenNeitherIsPresent() {
        XCTAssertNil(extract("<html><head></head><body>nothing here</body></html>"))
        XCTAssertNil(extract(""))
    }

    func testEmptyOgTitleFallsBackToTitleTag() {
        let html = """
        <meta property="og:title" content="">
        <title>Real Title</title>
        """
        XCTAssertEqual(extract(html), "Real Title")
    }

    func testTrimsWhitespaceAroundTheTitle() {
        let html = #"<meta property="og:title" content="  Padded Title  ">"#
        XCTAssertEqual(extract(html), "Padded Title")
    }
}
