import XCTest
@testable import TipMeCore

/// `prepareRoute`'s same-asset case and `sendToCreatorAccount` -- the two
/// pieces of `PaymentBackend` that make tipping a TipMe-linked creator work
/// without Lightning. Cross-asset conversion is deliberately still
/// unimplemented; see `prepareRoute`'s own comment.
final class CustodialPaymentBackendTipTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.stubs = []
        super.tearDown()
    }

    private func makeBackend(clock: Clock = MutableClock()) -> CustodialPaymentBackend {
        let baseURL = URL(string: "https://registry.test")!
        return CustodialPaymentBackend(
            client: AccountClient(configuration: .init(baseURL: baseURL), session: StubURLProtocol.session()),
            rateProvider: RegistryRateProvider(configuration: .init(baseURL: baseURL)),
            sessionTokenProvider: { "tok-123" },
            clock: clock)
    }

    func testPrepareRouteReturnsDirectForSameAsset() async throws {
        let route = try await makeBackend().prepareRoute(
            tip: .sats(2_000), to: LightningAddress("creator@getalby.com")!, receiveAsset: .bitcoin)
        XCTAssertFalse(route.requiresConversion)
        XCTAssertEqual(route.debited, .sats(2_000))
        XCTAssertEqual(route.credited, .sats(2_000))
    }

    func testPrepareRouteThrowsForCrossAssetConversion() async {
        do {
            _ = try await makeBackend().prepareRoute(
                tip: .usdtCents(500), to: LightningAddress("creator@getalby.com")!, receiveAsset: .bitcoin)
            XCTFail("expected an error")
        } catch PaymentBackendError.conversionUnavailable(let from, let to) {
            XCTAssertEqual(from, .usdt)
            XCTAssertEqual(to, .bitcoin)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testSendToCreatorAccountSuccess() async throws {
        StubURLProtocol.stubJSON(200, """
        {"balances":[{"asset":"bitcoin","balance_minor":8000},{"asset":"usdt","balance_minor":0}]}
        """) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/tip/tiktok/creator")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        }

        let handle = CreatorHandle(platform: .tiktok, rawUsername: "creator")!
        let receipt = try await makeBackend().sendToCreatorAccount(
            handle: handle, amount: .sats(2_000), idempotencyKey: "idem-1")
        XCTAssertEqual(receipt.status, .succeeded)
        XCTAssertEqual(receipt.sentAmount, .sats(2_000))
        XCTAssertEqual(receipt.networkFee, .zero(.bitcoin))
    }

    func testSendToCreatorAccountSurfacesAnUnlinkedCreatorAsRejected() async {
        StubURLProtocol.stubJSON(404, """
        {"detail":"@creator on tiktok has no linked TipMe account"}
        """)

        let handle = CreatorHandle(platform: .tiktok, rawUsername: "creator")!
        do {
            _ = try await makeBackend().sendToCreatorAccount(
                handle: handle, amount: .sats(2_000), idempotencyKey: "idem-1")
            XCTFail("expected an error")
        } catch PaymentBackendError.rejectedByNetwork {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
