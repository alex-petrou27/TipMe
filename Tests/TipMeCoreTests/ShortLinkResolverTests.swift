import XCTest
@testable import TipMeCore

/// Short-link resolution is the TikTok critical path: TikTok's own share sheet
/// emits `vm.tiktok.com` links rather than canonical ones, so for most real
/// TikTok shares this is what stands between a share and a creator.
final class ShortLinkResolverTests: XCTestCase {

    /// Scripted redirect chain. Records every URL probed so the tests can
    /// assert on how far the resolver walked, not just where it landed.
    private actor ScriptedProbe: RedirectProbing {
        private let chain: [String: String]
        private let failure: Error?
        private(set) var probed: [URL] = []

        init(chain: [String: String], failure: Error? = nil) {
            self.chain = chain
            self.failure = failure
        }

        func nextHop(from url: URL) async throws -> URL? {
            probed.append(url)
            if let failure { throw failure }
            guard let next = chain[url.absoluteString] else { return nil }
            return URL(string: next)!
        }

        func probedURLs() -> [URL] { probed }
    }

    private let parser = SharedLinkParser()

    private func shortLink(_ raw: String) throws -> SharedLink {
        let link = try XCTUnwrap(parser.parse(URL(string: raw)!))
        XCTAssertTrue(link.needsRedirectResolution, "\(raw) should have parsed as a short link")
        return link
    }

    // MARK: - The happy paths

    func testVMShortLinkResolvesToTheCreator() async throws {
        let probe = ScriptedProbe(chain: [
            "https://vm.tiktok.com/ZMhvJqKXn/":
                "https://www.tiktok.com/@zachking/video/7234567890123456789"
        ])
        let resolver = ShortLinkResolver(probe: probe)

        let resolved = try await resolver.resolve(try shortLink("https://vm.tiktok.com/ZMhvJqKXn/"))

        XCTAssertEqual(resolved.handle?.username, "zachking")
        XCTAssertEqual(resolved.kind, .post)
    }

    func testVTShortLinkResolves() async throws {
        let probe = ScriptedProbe(chain: [
            "https://vt.tiktok.com/ZSJqKXnab/":
                "https://www.tiktok.com/@charli.damelio/video/123"
        ])
        let resolved = try await ShortLinkResolver(probe: probe)
            .resolve(try shortLink("https://vt.tiktok.com/ZSJqKXnab/"))

        XCTAssertEqual(resolved.handle?.username, "charli.damelio")
    }

    func testWebShortFormResolves() async throws {
        let probe = ScriptedProbe(chain: [
            "https://www.tiktok.com/t/ZTRxyz123/":
                "https://www.tiktok.com/@khaby.lame/photo/7300000000000000000"
        ])
        let resolved = try await ShortLinkResolver(probe: probe)
            .resolve(try shortLink("https://www.tiktok.com/t/ZTRxyz123/"))

        XCTAssertEqual(resolved.handle?.username, "khaby.lame")
        XCTAssertEqual(resolved.kind, .post)
    }

    /// TikTok short links routinely bounce more than once before landing.
    func testFollowsAMultiHopChain() async throws {
        let probe = ScriptedProbe(chain: [
            "https://vm.tiktok.com/ZMabc/": "https://vt.tiktok.com/ZSdef/",
            "https://vt.tiktok.com/ZSdef/": "https://www.tiktok.com/t/ZTghi/",
            "https://www.tiktok.com/t/ZTghi/": "https://www.tiktok.com/@creator/video/1"
        ])
        let resolved = try await ShortLinkResolver(probe: probe)
            .resolve(try shortLink("https://vm.tiktok.com/ZMabc/"))

        XCTAssertEqual(resolved.handle?.username, "creator")
        XCTAssertEqual(await probe.probedURLs().count, 3)
    }

    func testResolvedTrackingParametersDoNotBreakParsing() async throws {
        let probe = ScriptedProbe(chain: [
            "https://vm.tiktok.com/ZMhvJqKXn/":
                "https://www.tiktok.com/@zachking/video/123?_r=1&_t=8abcDEF&is_from_webapp=1"
        ])
        let resolved = try await ShortLinkResolver(probe: probe)
            .resolve(try shortLink("https://vm.tiktok.com/ZMhvJqKXn/"))

        XCTAssertEqual(resolved.handle?.username, "zachking")
    }

    func testNonShortLinksPassStraightThrough() async throws {
        let probe = ScriptedProbe(chain: [:])
        let direct = try XCTUnwrap(parser.parse(URL(string: "https://www.tiktok.com/@creator/video/1")!))

        let resolved = try await ShortLinkResolver(probe: probe).resolve(direct)

        XCTAssertEqual(resolved.handle?.username, "creator")
        XCTAssertTrue(await probe.probedURLs().isEmpty, "a canonical link needs no network round trip")
    }

    // MARK: - Refusals

    /// The attack: a crafted short link that bounces off the platform, so that
    /// whatever we parse a "handle" out of is under someone else's control.
    func testRedirectLeavingTheKnownHostsIsRefused() async throws {
        let probe = ScriptedProbe(chain: [
            "https://vm.tiktok.com/ZMhvJqKXn/": "https://evil.example/@victim/video/1"
        ])
        let resolver = ShortLinkResolver(probe: probe)

        do {
            _ = try await resolver.resolve(try shortLink("https://vm.tiktok.com/ZMhvJqKXn/"))
            XCTFail("a redirect off the platform must not be followed")
        } catch ShortLinkError.leftKnownHosts(let url) {
            XCTAssertEqual(url.host, "evil.example")
        }
    }

    func testRedirectToALookalikeHostIsRefused() async throws {
        let probe = ScriptedProbe(chain: [
            "https://vm.tiktok.com/ZMhvJqKXn/": "https://tiktok.com.evil.co/@victim/video/1"
        ])
        do {
            _ = try await ShortLinkResolver(probe: probe)
                .resolve(try shortLink("https://vm.tiktok.com/ZMhvJqKXn/"))
            XCTFail("tiktok.com.evil.co is not TikTok")
        } catch ShortLinkError.leftKnownHosts {
            // expected
        }
    }

    func testRedirectLoopTerminates() async throws {
        let probe = ScriptedProbe(chain: [
            "https://vm.tiktok.com/ZMa/": "https://vm.tiktok.com/ZMb/",
            "https://vm.tiktok.com/ZMb/": "https://vm.tiktok.com/ZMa/"
        ])
        do {
            _ = try await ShortLinkResolver(probe: probe, maximumRedirects: 4)
                .resolve(try shortLink("https://vm.tiktok.com/ZMa/"))
            XCTFail("a redirect loop must not hang the share sheet")
        } catch ShortLinkError.tooManyRedirects {
            XCTAssertEqual(await probe.probedURLs().count, 4, "capped, not unbounded")
        }
    }

    func testChainEndingWithoutAHandleIsReportedNotGuessed() async throws {
        // Ends on a real TikTok URL that simply carries no username.
        let probe = ScriptedProbe(chain: [
            "https://vm.tiktok.com/ZMhvJqKXn/": "https://m.tiktok.com/v/7234567890123456789.html"
        ])
        let resolved = try await ShortLinkResolver(probe: probe)
            .resolve(try shortLink("https://vm.tiktok.com/ZMhvJqKXn/"))

        XCTAssertNil(resolved.handle)
        XCTAssertEqual(resolved.kind, .handleNotPresent,
                       "the UI offers manual entry; it must not invent a creator")
    }

    func testDeadEndShortLinkIsReported() async throws {
        let probe = ScriptedProbe(chain: [:]) // no redirect at all
        do {
            _ = try await ShortLinkResolver(probe: probe)
                .resolve(try shortLink("https://vm.tiktok.com/ZMhvJqKXn/"))
            XCTFail("a short link that never resolves cannot be treated as resolved")
        } catch ShortLinkError.tooManyRedirects {
            // expected
        }
    }

    func testTransportFailuresPropagate() async throws {
        let probe = ScriptedProbe(chain: [:], failure: ShortLinkError.timedOut)
        do {
            _ = try await ShortLinkResolver(probe: probe)
                .resolve(try shortLink("https://vm.tiktok.com/ZMhvJqKXn/"))
            XCTFail("expected the timeout to surface")
        } catch ShortLinkError.timedOut {
            // expected — TipFlow turns this into the manual-entry fallback
        }
    }
}
