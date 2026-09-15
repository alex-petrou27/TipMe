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

    private func makeHarness(records: [CreatorRecord] = [.stub()],
                             authorizer: BiometricAuthorizer = FakeAuthorizer(),
                             lookupError: CreatorLookupError? = nil) -> Harness {
        let clock = MutableClock()
        let backend = FakePaymentBackend(clock: clock)
        let audit = InMemoryAuditLog()
        let store = InMemoryKeyValueStore()

        var table: [CreatorHandle: CreatorRecord] = [:]
        for record in records { table[record.handle] = record }

        let capLedger = SendCapLedger(store: store, clock: clock)
        let rateLimiter = TipRateLimiter(store: store, clock: clock)

        let flow = TipFlow(
            shortLinkResolver: ShortLinkResolver(),
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

    /// The known Instagram gap, surfaced as a graceful fallback rather than an
    /// error. Shortcode URLs contain no username and no unauthenticated lookup
    /// exists, so manual entry is the honest answer.
    func testInstagramShortcodeFallsBackToManualEntryWithAnHonestExplanation() async {
        let harness = makeHarness()
        let state = await harness.flow.identify(
            attachedURLs: [URL(string: "https://www.instagram.com/reel/DFxYzAbCdEf/")!],
            sharedText: [])

        guard case .needsManualEntry(let reason) = state else {
            return XCTFail("expected manual entry, got \(state)")
        }
        XCTAssertTrue(reason.contains("don't include the creator's username"))
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
