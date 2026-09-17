import XCTest
@testable import TipMeCore

final class LightningDepositFlowTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.stubs = []
        super.tearDown()
    }

    private func makeFlow() -> LightningDepositFlow {
        let baseURL = URL(string: "https://registry.test")!
        let backend = CustodialPaymentBackend(
            client: AccountClient(configuration: .init(baseURL: baseURL), session: StubURLProtocol.session()),
            rateProvider: RegistryRateProvider(configuration: .init(baseURL: baseURL)),
            sessionTokenProvider: { "tok-123" })
        return LightningDepositFlow(backend: backend)
    }

    func testCreateReturnsAwaitingPaymentOnSuccess() async {
        StubURLProtocol.stubJSON(200, """
        {"payment_request":"lntbs10u1p42cer8pp5mock","payment_hash":"hash-1","amount_sats":1000}
        """)

        let state = await makeFlow().create(amountSats: 1000)
        guard case .awaitingPayment(let paymentRequest, let paymentHash, let amountSats) = state else {
            return XCTFail("expected awaitingPayment, got \(state)")
        }
        XCTAssertEqual(paymentRequest, "lntbs10u1p42cer8pp5mock")
        XCTAssertEqual(paymentHash, "hash-1")
        XCTAssertEqual(amountSats, 1000)
    }

    func testCreateSurfacesUnavailableAsFailed() async {
        StubURLProtocol.stubJSON(503, """
        {"detail":"Lightning deposits/withdrawals are not configured on this registry yet"}
        """)

        let state = await makeFlow().create(amountSats: 1000)
        guard case .failed = state else {
            return XCTFail("expected failed, got \(state)")
        }
    }

    func testCheckStatusStaysAwaitingPaymentUntilSettled() async {
        StubURLProtocol.stubJSON(200, """
        {"status":"pending","balances":[{"asset":"bitcoin","balance_minor":0},{"asset":"usdt","balance_minor":0}]}
        """)

        let state = await makeFlow().checkStatus(paymentHash: "hash-1", paymentRequest: "lntbs10u1mock", amountSats: 1000)
        guard case .awaitingPayment(let paymentRequest, let paymentHash, let amountSats) = state else {
            return XCTFail("expected awaitingPayment, got \(state)")
        }
        XCTAssertEqual(paymentRequest, "lntbs10u1mock")
        XCTAssertEqual(paymentHash, "hash-1")
        XCTAssertEqual(amountSats, 1000)
    }

    func testCheckStatusReturnsCompletedOnceSettled() async {
        StubURLProtocol.stubJSON(200, """
        {"status":"completed","balances":[{"asset":"bitcoin","balance_minor":1000},{"asset":"usdt","balance_minor":0}]}
        """)

        let state = await makeFlow().checkStatus(paymentHash: "hash-1", paymentRequest: "lntbs10u1mock", amountSats: 1000)
        guard case .completed(let balances) = state else {
            return XCTFail("expected completed, got \(state)")
        }
        XCTAssertEqual(balances[.bitcoin], 1000)
    }
}
