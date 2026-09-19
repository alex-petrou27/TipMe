import XCTest
@testable import TipMeCore

/// Request-building and status-code mapping for `/v1/deposit/apple_pay`,
/// stubbed at the `URLProtocol` level -- same convention as
/// `AccountClientLightningTests`. Response shapes here are the exact JSON
/// the registry's `deposit_apple_pay` returns (see Registry/tipme_registry/
/// app.py and its own test file, tests/test_apple_pay_deposit.py).
final class AccountClientApplePayTests: XCTestCase {
    private func makeClient() -> AccountClient {
        AccountClient(configuration: .init(baseURL: URL(string: "https://registry.test")!),
                     session: StubURLProtocol.session())
    }

    override func tearDown() {
        StubURLProtocol.stubs = []
        super.tearDown()
    }

    func testDepositApplePaySuccess() async throws {
        StubURLProtocol.stubJSON(200, """
        {"status":"completed","balances":[{"asset":"bitcoin","balance_minor":0},{"asset":"usdt","balance_minor":500}]}
        """) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/deposit/apple_pay")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        }

        let result = try await makeClient().depositApplePay(
            amountMinor: 500, reference: "apple-pay-txn-1", sessionToken: "tok-123")
        XCTAssertEqual(result.balances[.usdt], 500)
    }

    func testDepositApplePaySessionExpired() async {
        StubURLProtocol.stubJSON(401, """
        {"detail":"invalid or expired session"}
        """)

        do {
            _ = try await makeClient().depositApplePay(
                amountMinor: 500, reference: "apple-pay-txn-1", sessionToken: "stale-tok")
            XCTFail("expected an error")
        } catch AccountClient.AccountError.sessionExpired {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testDepositApplePayReferenceClaimedByAnotherAccount() async {
        StubURLProtocol.stubJSON(404, """
        {"detail":"no such deposit"}
        """)

        do {
            _ = try await makeClient().depositApplePay(
                amountMinor: 500, reference: "shared-reference", sessionToken: "tok-123")
            XCTFail("expected an error")
        } catch AccountClient.AccountError.depositNotFound {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
