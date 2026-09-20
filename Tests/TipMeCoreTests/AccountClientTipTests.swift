import XCTest
@testable import TipMeCore

/// Request-building and status-code mapping for
/// `/v1/tip/{platform}/{username}`, stubbed at the `URLProtocol` level --
/// same convention as `AccountClientLightningTests`/`AccountClientApplePayTests`.
final class AccountClientTipTests: XCTestCase {
    private func makeClient() -> AccountClient {
        AccountClient(configuration: .init(baseURL: URL(string: "https://registry.test")!),
                     session: StubURLProtocol.session())
    }

    override func tearDown() {
        StubURLProtocol.stubs = []
        super.tearDown()
    }

    func testTipCreatorSuccess() async throws {
        StubURLProtocol.stubJSON(200, """
        {"balances":[{"asset":"bitcoin","balance_minor":3000},{"asset":"usdt","balance_minor":0}]}
        """) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/tip/tiktok/creator")
        }

        try await makeClient().tipCreator(
            platform: "tiktok", username: "creator", asset: .bitcoin,
            amountMinor: 2000, sessionToken: "tok-123")
        // No throw is the assertion -- the call succeeded.
    }

    func testTipCreatorUnlinkedHandle() async {
        StubURLProtocol.stubJSON(404, """
        {"detail":"@creator on tiktok has no linked TipMe account"}
        """)

        do {
            try await makeClient().tipCreator(
                platform: "tiktok", username: "creator", asset: .bitcoin,
                amountMinor: 2000, sessionToken: "tok-123")
            XCTFail("expected an error")
        } catch AccountClient.AccountError.recipientNotFound {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testTipCreatorInsufficientBalance() async {
        StubURLProtocol.stubJSON(402, """
        {"detail":"insufficient balance"}
        """)

        do {
            try await makeClient().tipCreator(
                platform: "tiktok", username: "creator", asset: .bitcoin,
                amountMinor: 2000, sessionToken: "tok-123")
            XCTFail("expected an error")
        } catch AccountClient.AccountError.insufficientBalance {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
