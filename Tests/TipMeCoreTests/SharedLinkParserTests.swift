import XCTest
@testable import TipMeCore

/// Parsing tests run against a fixture corpus of real share URLs rather than
/// invented ones, because the failure mode that matters is "TikTok changed
/// their link shape and we silently stopped identifying creators".
final class SharedLinkParserTests: XCTestCase {

    private struct Corpus: Decodable {
        struct Case: Decodable {
            let url: String
            let platform: String
            let handle: String?
            let kind: String
        }
        let cases: [Case]
        let rejected: [String]
    }

    private let parser = SharedLinkParser()

    private func loadCorpus() throws -> Corpus {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/shared-links", withExtension: "json"),
                                "fixture corpus missing from test bundle")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    func testCorpusParsesAsExpected() throws {
        for testCase in try loadCorpus().cases {
            let url = try XCTUnwrap(URL(string: testCase.url), "unparseable fixture URL \(testCase.url)")
            let link = try XCTUnwrap(parser.parse(url), "expected \(testCase.url) to be recognised")

            XCTAssertEqual(link.platform.rawValue, testCase.platform, "platform for \(testCase.url)")
            XCTAssertEqual(link.handle?.username, testCase.handle, "handle for \(testCase.url)")
            XCTAssertEqual(link.kind.rawValue, testCase.kind, "kind for \(testCase.url)")
        }
    }

    func testHostileURLsAreNotRecognised() throws {
        for raw in try loadCorpus().rejected {
            guard let url = URL(string: raw) else { continue }
            XCTAssertNil(parser.parse(url), "\(raw) must not be treated as a platform link")
        }
    }

    /// The specific attack a `hasSuffix("tiktok.com")` host check would allow.
    func testLookalikeHostIsRejected() {
        let url = URL(string: "https://tiktok.com.evil.co/@victim/video/1")!
        XCTAssertNil(parser.parse(url))
    }

    func testHandleIsCaseNormalised() {
        let upper = parser.parse(URL(string: "https://www.tiktok.com/@ZachKing/video/1")!)
        let lower = parser.parse(URL(string: "https://www.tiktok.com/@zachking/video/1")!)
        XCTAssertEqual(upper?.handle, lower?.handle,
                       "casing must not split a creator into two rate-limit buckets")
    }

    func testTrailingDotsAreStrippedFromHandles() {
        let handle = CreatorHandle(platform: .tiktok, rawUsername: "someone..")
        XCTAssertNil(handle, "consecutive dots must not survive into a registry URL")

        let trailing = CreatorHandle(platform: .tiktok, rawUsername: "someone.")
        XCTAssertEqual(trailing?.username, "someone")
    }

    func testReservedSegmentsAreNotTreatedAsCreators() {
        XCTAssertNil(CreatorHandle(platform: .instagram, rawUsername: "accounts"))
        XCTAssertNil(CreatorHandle(platform: .instagram, rawUsername: "explore"))
        XCTAssertNil(CreatorHandle(platform: .tiktok, rawUsername: "discover"))
    }

    func testOverlongHandlesAreRejected() {
        XCTAssertNil(CreatorHandle(platform: .tiktok, rawUsername: String(repeating: "a", count: 25)))
        XCTAssertNotNil(CreatorHandle(platform: .tiktok, rawUsername: String(repeating: "a", count: 24)))
        XCTAssertNil(CreatorHandle(platform: .instagram, rawUsername: String(repeating: "a", count: 31)))
    }

    func testNonASCIIHandlesAreRejected() {
        XCTAssertNil(CreatorHandle(platform: .tiktok, rawUsername: "créator"))
        XCTAssertNil(CreatorHandle(platform: .tiktok, rawUsername: "用户"))
    }
}

/// TikTok in particular often shares marketing text with the link embedded
/// rather than a clean URL attachment.
final class SharedPayloadExtractorTests: XCTestCase {

    private let extractor = SharedPayloadExtractor()

    func testFindsLinkInsideSharedText() {
        let text = "Check out this video! https://vm.tiktok.com/ZMhvJqKXn/  #fyp #foryou"
        let urls = SharedPayloadExtractor.urls(in: text)
        XCTAssertEqual(urls.first?.absoluteString, "https://vm.tiktok.com/ZMhvJqKXn/")
    }

    func testAttachedURLsRankAheadOfScrapedText() {
        let attached = URL(string: "https://www.tiktok.com/@realcreator/video/1")!
        let text = "stolen link https://www.tiktok.com/@someoneelse/video/2"
        let candidates = extractor.candidateURLs(attachedURLs: [attached], sharedText: [text])

        XCTAssertEqual(candidates.first, attached,
                       "an explicit attachment is more trustworthy than a link in a caption")
        XCTAssertEqual(extractor.bestLink(from: candidates)?.handle?.username, "realcreator")
    }

    func testPrefersLinkThatCarriesAHandle() {
        // A share containing both a shortcode Reel and a profile link: the one
        // we can actually identify should win.
        let candidates = [
            URL(string: "https://www.instagram.com/reel/ABC123/")!,
            URL(string: "https://www.instagram.com/natgeo/")!
        ]
        XCTAssertEqual(extractor.bestLink(from: candidates)?.handle?.username, "natgeo")
    }

    func testDeduplicatesCandidates() {
        let url = URL(string: "https://www.tiktok.com/@a/video/1")!
        let candidates = extractor.candidateURLs(attachedURLs: [url, url],
                                                 sharedText: ["https://www.tiktok.com/@a/video/1"])
        XCTAssertEqual(candidates.count, 1)
    }

    /// The clipboard path: TikTok's and Instagram's own share rows both have a
    /// "Copy link" button, which is the one prominent slot TipMe can act on
    /// even though it cannot appear in that row itself. What lands on the
    /// clipboard is exactly what these cases cover.
    func testCopiedTikTokLinkIsRecognised() {
        for copied in ["https://vm.tiktok.com/ZMhvJqKXn/",
                       "https://www.tiktok.com/@creator/video/123",
                       "https://www.tiktok.com/@creator/video/123?_r=1&_t=8abc"] {
            let url = URL(string: copied)!
            let candidates = extractor.candidateURLs(attachedURLs: [url], sharedText: [])
            XCTAssertNotNil(extractor.bestLink(from: candidates), "should recognise \(copied)")
        }
    }

    func testCopiedInstagramProfileLinkIsRecognised() {
        let url = URL(string: "https://www.instagram.com/natgeo/")!
        let candidates = extractor.candidateURLs(attachedURLs: [url], sharedText: [])
        XCTAssertEqual(extractor.bestLink(from: candidates)?.handle?.username, "natgeo")
    }

    /// Guards the paste card against offering to tip on an unrelated link the
    /// user happened to have copied.
    func testCopiedUnrelatedLinkIsNotOfferedAsATip() {
        for copied in ["https://news.example.com/article",
                       "https://github.com/anthropics/claude-code",
                       "https://tiktok.com.evil.co/@victim/video/1"] {
            let url = URL(string: copied)!
            let candidates = extractor.candidateURLs(attachedURLs: [url], sharedText: [])
            XCTAssertNil(extractor.bestLink(from: candidates), "should not offer a tip for \(copied)")
        }
    }

    func testEmptyShareYieldsNothing() {
        XCTAssertTrue(extractor.candidateURLs(attachedURLs: [], sharedText: []).isEmpty)
        XCTAssertNil(extractor.bestLink(from: []))
    }
}
