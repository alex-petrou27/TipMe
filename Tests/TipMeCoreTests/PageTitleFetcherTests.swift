import XCTest
@testable import TipMeCore

/// `extractTitle` and `extractCanonicalURL` are the pure parts of the
/// fetcher — no network needed — and they're what actually has to match
/// real page HTML, so they're tested directly against the shapes real sites
/// are known to serve.
final class PageTitleFetcherTests: XCTestCase {

    private func extractTitle(_ html: String) -> String? {
        URLSessionPageMetadataFetcher.extractTitle(from: html)
    }

    private func extractCanonicalURL(_ html: String) -> URL? {
        URLSessionPageMetadataFetcher.extractCanonicalURL(from: html)
    }

    // MARK: - Title

    func testPrefersOgTitleOverTitleTag() {
        let html = """
        <html><head>
        <title>Instagram</title>
        <meta property="og:title" content="Pepsi UK on Instagram: &quot;Caption&quot;">
        </head></html>
        """
        XCTAssertEqual(extractTitle(html), "Pepsi UK on Instagram: \"Caption\"")
    }

    func testOgTitleWithReversedAttributeOrder() {
        let html = """
        <meta content="Pepsi UK on Instagram" property="og:title">
        """
        XCTAssertEqual(extractTitle(html), "Pepsi UK on Instagram")
    }

    func testFallsBackToTitleTagWhenNoOgTitlePresent() {
        let html = "<html><head><title>Some Video - TikTok</title></head></html>"
        XCTAssertEqual(extractTitle(html), "Some Video - TikTok")
    }

    func testDecodesCommonHtmlEntities() {
        let html = #"<meta property="og:title" content="Fish &amp; Chips &#39;n&#39; more &lt;3">"#
        XCTAssertEqual(extractTitle(html), "Fish & Chips 'n' more <3")
    }

    func testTitleReturnsNilWhenNeitherIsPresent() {
        XCTAssertNil(extractTitle("<html><head></head><body>nothing here</body></html>"))
        XCTAssertNil(extractTitle(""))
    }

    func testEmptyOgTitleFallsBackToTitleTag() {
        let html = """
        <meta property="og:title" content="">
        <title>Real Title</title>
        """
        XCTAssertEqual(extractTitle(html), "Real Title")
    }

    func testTrimsWhitespaceAroundTheTitle() {
        let html = #"<meta property="og:title" content="  Padded Title  ">"#
        XCTAssertEqual(extractTitle(html), "Padded Title")
    }

    // MARK: - Canonical URL
    //
    // Confirmed against a real Instagram post fetch: the title alone names
    // only the account's display name ("Pepsi UK on Instagram: ..."), not
    // its @username, so identifying the creator actually depends on this.

    func testPrefersCanonicalLinkOverOgURL() {
        let html = """
        <link rel="canonical" href="https://www.instagram.com/pepsiuk/p/Dc3nAkhAftj/">
        <meta property="og:url" content="https://www.instagram.com/p/Dc3nAkhAftj/">
        """
        XCTAssertEqual(extractCanonicalURL(html)?.absoluteString,
                       "https://www.instagram.com/pepsiuk/p/Dc3nAkhAftj/")
    }

    func testCanonicalLinkWithReversedAttributeOrder() {
        let html = """
        <link href="https://www.instagram.com/pepsiuk/p/Dc3nAkhAftj/" rel="canonical">
        """
        XCTAssertEqual(extractCanonicalURL(html)?.absoluteString,
                       "https://www.instagram.com/pepsiuk/p/Dc3nAkhAftj/")
    }

    func testFallsBackToOgURLWhenNoCanonicalLinkPresent() {
        let html = """
        <meta property="og:url" content="https://www.instagram.com/pepsiuk/p/Dc3nAkhAftj/">
        """
        XCTAssertEqual(extractCanonicalURL(html)?.absoluteString,
                       "https://www.instagram.com/pepsiuk/p/Dc3nAkhAftj/")
    }

    func testCanonicalURLReturnsNilWhenNeitherIsPresent() {
        XCTAssertNil(extractCanonicalURL("<html><head></head></html>"))
        XCTAssertNil(extractCanonicalURL(""))
    }

    func testMetadataCombinesBothFields() {
        let html = """
        <meta property="og:title" content="Pepsi UK on Instagram: &quot;Caption&quot;">
        <link rel="canonical" href="https://www.instagram.com/pepsiuk/p/Dc3nAkhAftj/">
        """
        let metadata = URLSessionPageMetadataFetcher.extractMetadata(from: html)
        XCTAssertEqual(metadata.title, "Pepsi UK on Instagram: \"Caption\"")
        XCTAssertEqual(metadata.canonicalURL?.absoluteString, "https://www.instagram.com/pepsiuk/p/Dc3nAkhAftj/")
    }
}
