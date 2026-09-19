import XCTest
@testable import TipMeCore

final class ApplePayDepositFlowTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.stubs = []
        super.tearDown()
    }

    private func makeFlow() -> ApplePayDepositFlow {
        let baseURL = URL(string: "https://registry.test")!
        let backend = CustodialPaymentBackend(
            client: AccountClient(configuration: .init(baseURL: baseURL), session: StubURLProtocol.session()),
            rateProvider: RegistryRateProvider(configuration: .init(baseURL: baseURL)),
            sessionTokenProvider: { "tok-123" })
        return ApplePayDepositFlow(backend: backend)
    }

    func testPayReturnsCompletedOnSuccess() async {
        StubURLProtocol.stubJSON(200, """
        {"status":"completed","balances":[{"asset":"bitcoin","balance_minor":0},{"asset":"usdt","balance_minor":500}]}
        """)

        let state = await makeFlow().pay(amountMinor: 500, reference: "test-ref-1")
        guard case .completed(let balances) = state else {
            return XCTFail("expected completed, got \(state)")
        }
        XCTAssertEqual(balances[.usdt], 500)
    }

    func testPayRejectsNonPositiveAmountLocallyWithoutANetworkCall() async {
        // A stub that would fail the test if actually consumed -- proves the
        // zero-amount guard returns before any request is made.
        StubURLProtocol.stubJSON(500, "{}")

        let state = await makeFlow().pay(amountMinor: 0, reference: "test-ref-1")
        guard case .failed = state else {
            return XCTFail("expected failed, got \(state)")
        }
        XCTAssertEqual(StubURLProtocol.stubs.count, 1, "no request should have consumed the stub")
    }

    func testPaySurfacesAClaimedReferenceAsFailed() async {
        StubURLProtocol.stubJSON(404, """
        {"detail":"no such deposit"}
        """)

        let state = await makeFlow().pay(amountMinor: 500, reference: "already-claimed")
        guard case .failed = state else {
            return XCTFail("expected failed, got \(state)")
        }
    }
}
