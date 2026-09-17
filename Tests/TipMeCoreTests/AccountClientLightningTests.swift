import XCTest
@testable import TipMeCore

/// Request-building and status-code mapping for the three Lightning
/// deposit/withdraw endpoints, stubbed at the `URLProtocol` level. Response
/// shapes here are the exact JSON the registry returned during live testing
/// against a real Voltage account (see Registry/tipme_registry/app.py and
/// that testing session), not invented shapes.
final class AccountClientLightningTests: XCTestCase {
    private func makeClient() -> AccountClient {
        AccountClient(configuration: .init(baseURL: URL(string: "https://registry.test")!),
                     session: StubURLProtocol.session())
    }

    override func tearDown() {
        StubURLProtocol.stubs = []
        super.tearDown()
    }

    // MARK: - Deposit

    func testDepositLightningInvoiceSuccess() async throws {
        StubURLProtocol.stubJSON(200, """
        {"payment_request":"lntbs10u1p42cer8pp5mock","payment_hash":"20a160eb-6362-43d2-8275-9c96b0f3b4c3","amount_sats":1000}
        """) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/deposit/lightning")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        }

        let invoice = try await makeClient().depositLightningInvoice(amountSats: 1000, sessionToken: "tok-123")
        XCTAssertEqual(invoice.paymentRequest, "lntbs10u1p42cer8pp5mock")
        XCTAssertEqual(invoice.paymentHash, "20a160eb-6362-43d2-8275-9c96b0f3b4c3")
        XCTAssertEqual(invoice.amountSats, 1000)
    }

    func testDepositLightningInvoiceUnavailable() async {
        StubURLProtocol.stubJSON(503, """
        {"detail":"Lightning deposits/withdrawals are not configured on this registry yet"}
        """)

        do {
            _ = try await makeClient().depositLightningInvoice(amountSats: 1000, sessionToken: "tok-123")
            XCTFail("expected an error")
        } catch AccountClient.AccountError.lightningUnavailable {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Check deposit

    func testCheckLightningDepositStillPending() async throws {
        StubURLProtocol.stubJSON(200, """
        {"status":"pending","balances":[{"asset":"bitcoin","balance_minor":0},{"asset":"usdt","balance_minor":0}]}
        """)

        let status = try await makeClient().checkLightningDeposit(paymentHash: "hash-1", sessionToken: "tok-123")
        XCTAssertFalse(status.completed)
        XCTAssertEqual(status.balances[.bitcoin], 0)
    }

    func testCheckLightningDepositCompleted() async throws {
        StubURLProtocol.stubJSON(200, """
        {"status":"completed","balances":[{"asset":"bitcoin","balance_minor":1000},{"asset":"usdt","balance_minor":0}]}
        """)

        let status = try await makeClient().checkLightningDeposit(paymentHash: "hash-1", sessionToken: "tok-123")
        XCTAssertTrue(status.completed)
        XCTAssertEqual(status.balances[.bitcoin], 1000)
    }

    func testCheckLightningDepositNotFound() async {
        StubURLProtocol.stubJSON(404, """
        {"detail":"no such deposit"}
        """)

        do {
            _ = try await makeClient().checkLightningDeposit(paymentHash: "hash-1", sessionToken: "tok-123")
            XCTFail("expected an error")
        } catch AccountClient.AccountError.depositNotFound {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Withdraw

    func testWithdrawLightningSuccess() async throws {
        StubURLProtocol.stubJSON(200, """
        {"payment_hash":"44dabd8f-d166-4e5b-96dd-82386a9cd53a","amount_sats":300,"fee_sats":0,"balances":[{"asset":"bitcoin","balance_minor":700},{"asset":"usdt","balance_minor":0}]}
        """) { request in
            XCTAssertEqual(request.url?.path, "/v1/withdraw/lightning")
        }

        let result = try await makeClient().withdrawLightning(paymentRequest: "lntbs3u1mock", sessionToken: "tok-123")
        XCTAssertEqual(result.paymentHash, "44dabd8f-d166-4e5b-96dd-82386a9cd53a")
        XCTAssertEqual(result.amountSats, 300)
        XCTAssertEqual(result.feeSats, 0)
        XCTAssertEqual(result.balances[.bitcoin], 700)
    }

    func testWithdrawLightningInsufficientBalance() async {
        StubURLProtocol.stubJSON(402, """
        {"detail":"insufficient balance"}
        """)

        do {
            _ = try await makeClient().withdrawLightning(paymentRequest: "lntbs3u1mock", sessionToken: "tok-123")
            XCTFail("expected an error")
        } catch AccountClient.AccountError.insufficientBalance {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testWithdrawLightningAlreadyPaid() async {
        StubURLProtocol.stubJSON(409, """
        {"detail":"this invoice has already been paid"}
        """)

        do {
            _ = try await makeClient().withdrawLightning(paymentRequest: "lntbs3u1mock", sessionToken: "tok-123")
            XCTFail("expected an error")
        } catch AccountClient.AccountError.invoiceAlreadyPaid {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testWithdrawLightningInvalidRequestSurfacesDetail() async {
        StubURLProtocol.stubJSON(400, """
        {"detail":"invoice must be for at least 100 sats"}
        """)

        do {
            _ = try await makeClient().withdrawLightning(paymentRequest: "lntbs1u1mock", sessionToken: "tok-123")
            XCTFail("expected an error")
        } catch AccountClient.AccountError.lightningRequestInvalid(let detail) {
            XCTAssertEqual(detail, "invoice must be for at least 100 sats")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testWithdrawLightningNodeErrorSurfacesDetail() async {
        StubURLProtocol.stubJSON(502, """
        {"detail":"Voltage returned 400: insufficient credit"}
        """)

        do {
            _ = try await makeClient().withdrawLightning(paymentRequest: "lntbs3u1mock", sessionToken: "tok-123")
            XCTFail("expected an error")
        } catch AccountClient.AccountError.lightningNodeError(let detail) {
            XCTAssertEqual(detail, "Voltage returned 400: insufficient credit")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
