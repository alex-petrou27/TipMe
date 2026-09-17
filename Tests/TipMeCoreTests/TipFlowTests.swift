import XCTest
@testable import TipMeCore

/// End-to-end tests of the share-sheet sequence, from "the OS handed us a
/// payload" through to a receipt.
final class TipFlowTests: XCTestCase {

    private struct Harness {
        let flow: TipFlow
        let clock: MutableClock
        let backend: FakePaymentBackend
        let audit: InMemoryAuditLog
    }

    /// Scripted redirect chain, so the TikTok short-link path is exercised
    /// here rather than only in ShortLinkResolverTests.
    private struct StubProbe: RedirectProbing {
        let chain: [String: String]
        func nextHop(from url: URL) async throws -> URL? {
            chain[url.absoluteString].map { URL(string: $0)! }
        }
    }

    /// Stands in for a real network fetch so tests stay deterministic and
    /// never touch the network — by default it behaves like a share whose
    /// URL doesn't resolve to any usable metadata, same as a real failed fetch.
    private struct StubPageMetadataFetcher: PageMetadataFetching {
        var title: String?
        var canonicalURL: URL?
        var description: String?
        var error: Error?
        func metadata(for url: URL) async throws -> FetchedPageMetadata {
            if let error { throw error }
            return FetchedPageMetadata(title: title, canonicalURL: canonicalURL, description: description)
        }
    }

    private func makeHarness(records: [CreatorRecord] = [.stub()],
                             authorizer: BiometricAuthorizer = FakeAuthorizer(),
                             lookupError: CreatorLookupError? = nil,
                             redirects: [String: String] = [:],
                             pageMetadataFetcher: PageMetadataFetching = StubPageMetadataFetcher()) -> Harness {
        let clock = MutableClock()
        let backend = FakePaymentBackend(clock: clock)
        let audit = InMemoryAuditLog()
        let store = InMemoryKeyValueStore()

        var table: [CreatorHandle: CreatorRecord] = [:]
        for record in records { table[record.handle] = record }

        let capLedger = SendCapLedger(store: store, clock: clock)
        let rateLimiter = TipRateLimiter(store: store, clock: clock)

        let flow = TipFlow(
            shortLinkResolver: ShortLinkResolver(probe: StubProbe(chain: redirects)),
            pageMetadataFetcher: pageMetadataFetcher,
            creatorResolver: FakeCreatorResolver(records: table, error: lookupError),
            backend: backend,
            quoteBuilder: TipQuoteBuilder(feePolicy: .standard),
            gate: AuthorizationGate(authorizer: authorizer, clock: clock, auditLog: audit),
            engine: PaymentEngine(backend: backend, capLedger: capLedger,
                                  rateLimiter: rateLimiter, auditLog: audit,
                                  feeDestination: Fixtures.feeDestination, clock: clock),
            auditLog: audit,
            clock: clock)

        return Harness(flow: flow, clock: clock, backend: backend, audit: audit)
    }

    // MARK: - Identification

    func testTikTokShareIdentifiesTheCreator() async {
        let harness = makeHarness()
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://www.tiktok.com/@creator/video/123")!],
            sharedText: [])

        guard case .ready(let record) = state else {
            return XCTFail("expected a ready state, got \(state)")
        }
        XCTAssertEqual(record.handle.username, "creator")
    }

    func testTikTokShareSentAsTextStillWorks() async {
        let harness = makeHarness()
        let state = await harness.flow.identify(
            attachedURLs: [],
            sharedText: ["Check this out https://www.tiktok.com/@creator/video/123 #fyp"])

        guard case .ready = state else {
            return XCTFail("expected a ready state, got \(state)")
        }
    }

    /// The share-sheet header reads "Reel from @username", so a shortcode Reel
    /// URL that names nobody is still identifiable from the title. This is the
    /// common real Instagram share.
    func testInstagramReelIsIdentifiedFromTheShareTitle() async {
        let harness = makeHarness(records: [.stub(username: "natgeo", platform: .instagram)])
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://www.instagram.com/reel/DFxYzAbCdEf/")!],
            sharedText: [],
            titles: ["Reel from @natgeo"])

        guard case .ready(let record) = state else {
            return XCTFail("expected a ready state, got \(state)")
        }
        XCTAssertEqual(record.handle.username, "natgeo")
    }

    func testInstagramShortcodePostIsIdentifiedFromTheShareTitle() async {
        let harness = makeHarness(records: [.stub(username: "natgeo", platform: .instagram)])
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://www.instagram.com/p/DFxYzAbCdEf/")!],
            sharedText: [],
            titles: ["Post from @natgeo"])

        guard case .ready = state else {
            return XCTFail("expected a ready state, got \(state)")
        }
    }

    /// The URL is the more trustworthy source, so it must win when both name
    /// someone — a title is prose and could name a tagged account.
    func testURLHandleWinsOverTheTitle() async {
        let harness = makeHarness(records: [
            .stub(username: "natgeo", platform: .instagram),
            .stub(username: "nasa", platform: .instagram)
        ])
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://www.instagram.com/natgeo/reel/DFxYzAbCdEf/")!],
            sharedText: [],
            titles: ["Reel from @nasa"])

        guard case .ready(let record) = state else {
            return XCTFail("expected a ready state, got \(state)")
        }
        XCTAssertEqual(record.handle.username, "natgeo", "the URL is the stronger signal")
    }

    /// Without a title naming anyone, a shortcode Reel still has to fall back.
    func testInstagramShortcodeWithoutAUsableTitleFallsBackToManualEntry() async {
        let harness = makeHarness()
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://www.instagram.com/reel/DFxYzAbCdEf/")!],
            sharedText: [],
            titles: ["Instagram"])

        guard case .needsManualEntry(let reason) = state else {
            return XCTFail("expected manual entry, got \(state)")
        }
        XCTAssertTrue(reason.contains("couldn't tell whose Reel"))
    }

    /// An ambiguous title must not be guessed at — paying the wrong creator is
    /// unrecoverable.
    func testAmbiguousTitleFallsBackRatherThanGuessing() async {
        let harness = makeHarness()
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://www.instagram.com/reel/DFxYzAbCdEf/")!],
            sharedText: [],
            titles: ["@natgeo tagged @nasa and @esa"])

        guard case .needsManualEntry = state else {
            return XCTFail("expected manual entry, got \(state)")
        }
    }

    /// Confirmed on a real device: Instagram hands the share extension a bare
    /// URL with no title or text at all, so the share-title fallback above
    /// never fires. A second real fetch confirmed the title alone is *also*
    /// no good -- Instagram's title names the account's display name
    /// ("Pepsi UK on Instagram: caption"), not its @username. What actually
    /// recovers the creator is the page's own canonical URL, which -- also
    /// confirmed live -- carries the real username in its path, just like a
    /// directly shared profile link does.
    func testInstagramReelIsIdentifiedFromFetchedCanonicalURLWhenShareCarriesNoTitleAtAll() async {
        let harness = makeHarness(
            records: [.stub(username: "pepsiuk", platform: .instagram)],
            pageMetadataFetcher: StubPageMetadataFetcher(
                title: "Pepsi UK on Instagram: \"New Pepsi Ice cream flavours\"",
                canonicalURL: URL(string: "https://www.instagram.com/pepsiuk/p/Dc3nAkhAftj/")))
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://www.instagram.com/p/Dc3nAkhAftj/")!],
            sharedText: [],
            titles: [])

        guard case .ready(let record) = state else {
            return XCTFail("expected a ready state, got \(state)")
        }
        XCTAssertEqual(record.handle.username, "pepsiuk")
    }

    /// When the fetch turns up a title but no canonical URL, the title is
    /// still worth trying -- some pages carry a handle in the title even
    /// without a parseable username-bearing URL.
    func testHandleIsRecoveredFromFetchedTitleWhenNoCanonicalURLIsAvailable() async {
        let harness = makeHarness(
            records: [.stub(username: "natgeo", platform: .instagram)],
            pageMetadataFetcher: StubPageMetadataFetcher(
                title: "Jane Doe (@natgeo) on Instagram: \"Caption text here\"",
                canonicalURL: nil))
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://www.instagram.com/reel/DFxYzAbCdEf/")!],
            sharedText: [],
            titles: [])

        guard case .ready(let record) = state else {
            return XCTFail("expected a ready state, got \(state)")
        }
        XCTAssertEqual(record.handle.username, "natgeo")
    }

    /// The real, confirmed shape: a title with no @-mention in it at all
    /// (just a display name) and no canonical URL either -- still degrades
    /// cleanly to manual entry rather than misreading the display name as a
    /// username.
    func testFetchedTitleWithNoMentionAndNoCanonicalURLFallsBackToManualEntry() async {
        let harness = makeHarness(
            pageMetadataFetcher: StubPageMetadataFetcher(
                title: "Pepsi UK on Instagram: \"New Pepsi Ice cream flavours\"",
                canonicalURL: nil))
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://www.instagram.com/p/Dc3nAkhAftj/")!],
            sharedText: [],
            titles: [])

        guard case .needsManualEntry(let reason) = state else {
            return XCTFail("expected manual entry, got \(state)")
        }
        XCTAssertTrue(reason.contains("couldn't tell whose Reel"))
    }

    /// The real, confirmed shape for a Reel specifically: unlike a post, its
    /// canonical URL comes back with no username at all
    /// ("instagram.com/reel/<code>/", same shape as the original shortcode
    /// link) and its title is the same unusable display name shape. What
    /// recovers the creator here is the description -- confirmed live to
    /// read "N likes, N comments - username on <date>: caption", the bare
    /// username with no `@`.
    func testInstagramReelIsIdentifiedFromFetchedDescriptionWhenTitleAndCanonicalURLAreBothUnusable() async {
        let harness = makeHarness(
            records: [.stub(username: "vroomjuicy", platform: .instagram)],
            pageMetadataFetcher: StubPageMetadataFetcher(
                title: "vroom on Instagram: \"caption\"",
                canonicalURL: URL(string: "https://www.instagram.com/reel/Dcef_2PMxDJ/"),
                description: "182K likes, 5,289 comments - vroomjuicy on August 25, 2026: \"caption\""))
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://www.instagram.com/reel/Dcef_2PMxDJ/")!],
            sharedText: [],
            titles: [])

        guard case .ready(let record) = state else {
            return XCTFail("expected a ready state, got \(state)")
        }
        XCTAssertEqual(record.handle.username, "vroomjuicy")
    }

    /// The real, confirmed failure shape: title, canonical URL, and
    /// description all fail to name anyone -- still degrades cleanly to
    /// manual entry. A multi-word display name directly before "on" doesn't
    /// satisfy the description rule's single-token username shape, so this
    /// isn't accidentally treated as a match either.
    func testFetchedDescriptionWithNoMentionStillFallsBackToManualEntry() async {
        let harness = makeHarness(
            pageMetadataFetcher: StubPageMetadataFetcher(
                title: "Luke Hamnett on Instagram: \"caption\"",
                canonicalURL: URL(string: "https://www.instagram.com/reel/DbWliK9tPPs/"),
                description: "500 likes, 12 comments - Luke Hamnett on Instagram: \"caption\""))
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://www.instagram.com/reel/DbWliK9tPPs/")!],
            sharedText: [],
            titles: [])

        guard case .needsManualEntry(let reason) = state else {
            return XCTFail("expected manual entry, got \(state)")
        }
        XCTAssertTrue(reason.contains("couldn't tell whose Reel"))
    }

    /// A fetch failure (network down, timeout, blocked) must not crash the
    /// flow — it degrades to the same manual-entry offer as any other
    /// unidentifiable share.
    func testFailedPageMetadataFetchStillFallsBackToManualEntry() async {
        let harness = makeHarness(
            pageMetadataFetcher: StubPageMetadataFetcher(error: PageTitleFetchError.timedOut))
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://www.instagram.com/reel/DFxYzAbCdEf/")!],
            sharedText: [],
            titles: [])

        guard case .needsManualEntry(let reason) = state else {
            return XCTFail("expected manual entry, got \(state)")
        }
        XCTAssertTrue(reason.contains("couldn't tell whose Reel"))
    }

    /// The fetch fallback only runs when nothing already named a creator —
    /// a URL or share-title hit must short-circuit it.
    func testFetchedPageMetadataIsNotConsultedWhenTheUrlAlreadyNamedACreator() async {
        let harness = makeHarness(
            records: [.stub(username: "natgeo", platform: .instagram)],
            pageMetadataFetcher: StubPageMetadataFetcher(
                title: "Someone Else on Instagram: \"nope\"",
                canonicalURL: URL(string: "https://www.instagram.com/nasa/p/xyz/")))
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://www.instagram.com/natgeo/reel/DFxYzAbCdEf/")!],
            sharedText: [])

        guard case .ready(let record) = state else {
            return XCTFail("expected a ready state, got \(state)")
        }
        XCTAssertEqual(record.handle.username, "natgeo")
    }

    /// A canonical URL from a different platform than the shared link (a
    /// redirect gone astray, a malformed page) must not be trusted -- the
    /// platform check exists specifically to keep that from silently mixing
    /// up TikTok and Instagram creators.
    func testFetchedCanonicalURLFromAMismatchedPlatformIsIgnored() async {
        let harness = makeHarness(
            records: [.stub(username: "creator", platform: .tiktok)],
            pageMetadataFetcher: StubPageMetadataFetcher(
                title: nil,
                canonicalURL: URL(string: "https://www.tiktok.com/@someoneelse/video/1")))
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://www.instagram.com/reel/DFxYzAbCdEf/")!],
            sharedText: [],
            titles: [])

        guard case .needsManualEntry = state else {
            return XCTFail("expected manual entry, got \(state)")
        }
    }

    func testInstagramLinkCarryingTheHandleIsIdentified() async {
        let harness = makeHarness(records: [.stub(username: "natgeo", platform: .instagram)])
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://www.instagram.com/natgeo/reel/DFxYzAbCdEf/")!],
            sharedText: [])

        guard case .ready(let record) = state else {
            return XCTFail("expected a ready state, got \(state)")
        }
        XCTAssertEqual(record.handle.username, "natgeo")
    }

    /// The most common real TikTok share: the app's own share sheet emits a
    /// vm.tiktok.com link, not a canonical one.
    func testTikTokShortLinkShareIdentifiesTheCreator() async {
        let harness = makeHarness(redirects: [
            "https://vm.tiktok.com/ZMhvJqKXn/": "https://www.tiktok.com/@creator/video/123"
        ])
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://vm.tiktok.com/ZMhvJqKXn/")!],
            sharedText: [])

        guard case .ready(let record) = state else {
            return XCTFail("expected a ready state, got \(state)")
        }
        XCTAssertEqual(record.handle.username, "creator")
    }

    /// TikTok's "copy link" pasted into a message: a short link wrapped in text.
    func testTikTokShortLinkInsideSharedTextIdentifiesTheCreator() async {
        let harness = makeHarness(redirects: [
            "https://vm.tiktok.com/ZMhvJqKXn/": "https://www.tiktok.com/@creator/video/123"
        ])
        let state = await harness.flow.identify(
            attachedURLs: [],
            sharedText: ["Check this out https://vm.tiktok.com/ZMhvJqKXn/ 😂"])

        guard case .ready = state else {
            return XCTFail("expected a ready state, got \(state)")
        }
    }

    /// A short link that cannot be followed must not dead-end the user.
    func testUnresolvableShortLinkFallsBackToManualEntry() async {
        let harness = makeHarness(redirects: [:]) // nothing resolves
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://vm.tiktok.com/ZMhvJqKXn/")!],
            sharedText: [])

        guard case .needsManualEntry = state else {
            return XCTFail("expected manual entry, got \(state)")
        }
    }

    func testTikTokProfileShareIdentifiesTheCreator() async {
        let harness = makeHarness()
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://www.tiktok.com/@creator")!],
            sharedText: [])

        guard case .ready = state else {
            return XCTFail("expected a ready state, got \(state)")
        }
    }

    func testInstagramStoryShareIdentifiesTheCreator() async {
        let harness = makeHarness(records: [.stub(username: "natgeo", platform: .instagram)])
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://www.instagram.com/stories/natgeo/3512345678901234567/")!],
            sharedText: [])

        guard case .ready(let record) = state else {
            return XCTFail("expected a ready state, got \(state)")
        }
        XCTAssertEqual(record.handle.username, "natgeo")
    }

    func testInstagramProfileShareIdentifiesTheCreator() async {
        let harness = makeHarness(records: [.stub(username: "natgeo", platform: .instagram)])
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://www.instagram.com/natgeo/")!],
            sharedText: [])

        guard case .ready = state else {
            return XCTFail("expected a ready state, got \(state)")
        }
    }

    func testUnregisteredCreatorIsItsOwnState() async {
        let harness = makeHarness(records: [])
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://www.tiktok.com/@nobody/video/1")!],
            sharedText: [])

        guard case .creatorNotRegistered(let handle) = state else {
            return XCTFail("expected creatorNotRegistered, got \(state)")
        }
        XCTAssertEqual(handle.username, "nobody")
    }

    func testUnrelatedLinkOffersManualEntry() async {
        let harness = makeHarness()
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://news.example.com/article")!],
            sharedText: [])

        guard case .needsManualEntry = state else {
            return XCTFail("expected manual entry, got \(state)")
        }
    }

    /// End to end for the clipboard path: the user taps TikTok's own "Copy
    /// link", opens TipMe, and pastes. Same flow, different origin.
    func testPastedTikTokLinkIdentifiesTheCreator() async {
        let harness = makeHarness(redirects: [
            "https://vm.tiktok.com/ZMhvJqKXn/": "https://www.tiktok.com/@creator/video/123"
        ])
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://vm.tiktok.com/ZMhvJqKXn/")!],
            sharedText: [])

        guard case .ready(let record) = state else {
            return XCTFail("expected a ready state, got \(state)")
        }
        XCTAssertEqual(record.handle.username, "creator")
    }

    // MARK: - Manual entry

    func testManualLightningAddressIsAccepted() async {
        let harness = makeHarness()
        let state = await harness.flow.manualRecipient(address: "alice@getalby.com", handle: nil)

        guard case .ready(let record) = state else {
            return XCTFail("expected a ready state, got \(state)")
        }
        XCTAssertEqual(record.lightningAddress.description, "alice@getalby.com")
        XCTAssertFalse(record.verified, "a pasted address has been verified by nobody")
    }

    func testManualEntryRejectsGarbageWithAReadableMessage() async {
        let harness = makeHarness()
        let state = await harness.flow.manualRecipient(address: "not an address", handle: nil)

        guard case .failed(let message) = state else {
            return XCTFail("expected failure, got \(state)")
        }
        XCTAssertTrue(message.contains("name@wallet.com"))
    }

    // MARK: - Quote and pay

    func testFullShareToReceiptJourney() async throws {
        let harness = makeHarness()
        let creator = CreatorRecord.stub()

        let identified = await harness.flow.identify(
            attachedURLs: [URL(string: "https://www.tiktok.com/@creator/video/123")!],
            sharedText: [])
        guard case .ready(let record) = identified else {
            return XCTFail("identification failed: \(identified)")
        }

        let quoted = await harness.flow.quote(tip: .sats(2_000), for: record)
        guard case .quoted(_, let quote) = quoted else {
            return XCTFail("quoting failed: \(quoted)")
        }
        XCTAssertEqual(quote.disclosure, "£1.00 tip + £0.03 fee = £1.03")

        let paid = await harness.flow.confirmAndPay(quote: quote, creator: record, sourceLink: nil)
        guard case .succeeded(let result, _) = paid else {
            return XCTFail("payment failed: \(paid)")
        }
        XCTAssertTrue(result.creatorWasPaid)

        let sends = await harness.backend.recordedSends()
        XCTAssertEqual(sends.count, 2)
        XCTAssertEqual(sends[0].destination, creator.lightningAddress)
    }

    func testCancellingFaceIDReturnsToTheConfirmScreen() async {
        let harness = makeHarness(authorizer: FakeAuthorizer(.userCancelled))
        let record = CreatorRecord.stub()

        let quoted = await harness.flow.quote(tip: .sats(2_000), for: record)
        guard case .quoted(_, let quote) = quoted else { return XCTFail("quoting failed") }

        let result = await harness.flow.confirmAndPay(quote: quote, creator: record, sourceLink: nil)
        guard case .quoted = result else {
            return XCTFail("cancelling should return to the confirm screen, not an error state")
        }
        let sends = await harness.backend.recordedSends()
        XCTAssertTrue(sends.isEmpty)
    }

    func testCreatorMinimumIsRespected() async {
        let harness = makeHarness()
        let record = CreatorRecord.stub(minimum: 5_000)

        let state = await harness.flow.quote(tip: .sats(1_000), for: record)
        guard case .failed(let message) = state else {
            return XCTFail("expected the minimum to bind, got \(state)")
        }
        XCTAssertTrue(message.contains("5,000 sats"))
    }

    func testBackendPricingFailureIsReadable() async {
        let harness = makeHarness()
        await harness.backend.setPrepareRouteError(.destinationUnreachable("LNURL endpoint 502"))

        let state = await harness.flow.quote(tip: .sats(2_000), for: .stub())
        guard case .failed(let message) = state else {
            return XCTFail("expected failure, got \(state)")
        }
        XCTAssertTrue(message.contains("Couldn't reach that wallet"))
    }
}
