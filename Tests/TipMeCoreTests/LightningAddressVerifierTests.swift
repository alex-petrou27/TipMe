import XCTest
@testable import TipMeCore

/// Verification exists to stop a creator registering an address that cannot
/// receive money. Without it the failure is invisible and slow: every tip fails
/// (or lands somewhere else), and the creator finds out weeks later wondering
/// why they have never been paid.
final class LightningAddressVerifierTests: XCTestCase {

    private struct StubFetcher: HTTPFetching {
        let body: String
        let status: Int
        var error: Error?

        init(_ body: String, status: Int = 200) {
            self.body = body
            self.status = status
        }

        init(error: Error) {
            self.body = ""
            self.status = 0
            self.error = error
        }

        func get(_ url: URL) async throws -> (Data, Int) {
            if let error { throw error }
            return (Data(body.utf8), status)
        }
    }

    private struct URLRecordingFetcher: HTTPFetching {
        let box: Box
        final class Box: @unchecked Sendable { var url: URL? }

        func get(_ url: URL) async throws -> (Data, Int) {
            box.url = url
            return (Data(Self.validPayRequest.utf8), 200)
        }

        static let validPayRequest = """
        {"tag":"payRequest","callback":"https://getalby.com/lnurlp/alice/callback",
         "minSendable":1000,"maxSendable":100000000,
         "metadata":"[[\\"text/plain\\",\\"Pay to alice\\"]]"}
        """
    }

    private func address(_ raw: String = "alice@getalby.com") throws -> LightningAddress {
        try XCTUnwrap(LightningAddress(raw))
    }

    // MARK: - Accepting a working wallet

    func testAcceptsAValidPayRequest() async throws {
        let verifier = LightningAddressVerifier(
            fetcher: StubFetcher(URLRecordingFetcher.validPayRequest))

        let capability = try await verifier.verify(try address())

        // LNURL speaks millisatoshis; we denominate in satoshis.
        XCTAssertEqual(capability.minimum, .sats(1))
        XCTAssertEqual(capability.maximum, .sats(100_000))
        XCTAssertEqual(capability.describedAs, "Pay to alice")
        XCTAssertFalse(capability.acceptsComment)
    }

    func testReadsCommentSupport() async throws {
        let body = """
        {"tag":"payRequest","callback":"https://x.com/cb","minSendable":1000,
         "maxSendable":2000,"commentAllowed":140,"metadata":"[]"}
        """
        let capability = try await LightningAddressVerifier(fetcher: StubFetcher(body))
            .verify(try address())
        XCTAssertTrue(capability.acceptsComment)
    }

    func testQueriesTheWellKnownEndpoint() async throws {
        let box = URLRecordingFetcher.Box()
        _ = try await LightningAddressVerifier(fetcher: URLRecordingFetcher(box: box))
            .verify(try address("alice@getalby.com"))

        XCTAssertEqual(box.url?.absoluteString,
                       "https://getalby.com/.well-known/lnurlp/alice")
    }

    // MARK: - Rejecting a wallet that cannot be paid

    /// The typo case: `charli@getably.com` instead of `charli@getalby.com`.
    func testMissingWalletIsReportedClearly() async throws {
        let verifier = LightningAddressVerifier(fetcher: StubFetcher("not found", status: 404))

        do {
            _ = try await verifier.verify(try address("charli@getably.com"))
            XCTFail("a wallet that does not exist must not be registered")
        } catch let error as LightningAddressVerificationError {
            XCTAssertEqual(error, .notFound)
            XCTAssertTrue(error.userFacingReason.contains("Check the spelling"))
        }
    }

    func testLNURLErrorResponseIsSurfacedWithItsReason() async throws {
        let body = #"{"status":"ERROR","reason":"account disabled"}"#
        do {
            _ = try await LightningAddressVerifier(fetcher: StubFetcher(body)).verify(try address())
            XCTFail("expected the wallet's refusal to surface")
        } catch let error as LightningAddressVerificationError {
            XCTAssertEqual(error, .rejected(reason: "account disabled"))
        }
    }

    func testNonPayEndpointIsRejected() async throws {
        let body = #"{"tag":"withdrawRequest","callback":"https://x.com/cb"}"#
        do {
            _ = try await LightningAddressVerifier(fetcher: StubFetcher(body)).verify(try address())
            XCTFail("a withdraw endpoint cannot receive tips")
        } catch let error as LightningAddressVerificationError {
            XCTAssertEqual(error, .notAPayEndpoint)
        }
    }

    /// An http callback could be rewritten in flight to return an attacker's
    /// invoice, so the tip would settle to the wrong wallet.
    func testNonHTTPSCallbackIsRejected() async throws {
        let body = """
        {"tag":"payRequest","callback":"http://insecure.example/cb",
         "minSendable":1000,"maxSendable":2000,"metadata":"[]"}
        """
        do {
            _ = try await LightningAddressVerifier(fetcher: StubFetcher(body)).verify(try address())
            XCTFail("an http callback must not be accepted")
        } catch let error as LightningAddressVerificationError {
            guard case .malformed(let detail) = error else {
                return XCTFail("expected malformed, got \(error)")
            }
            XCTAssertTrue(detail.contains("https"))
        }
    }

    func testInconsistentSendableRangeIsRejected() async throws {
        let body = """
        {"tag":"payRequest","callback":"https://x.com/cb",
         "minSendable":100000,"maxSendable":1000,"metadata":"[]"}
        """
        do {
            _ = try await LightningAddressVerifier(fetcher: StubFetcher(body)).verify(try address())
            XCTFail("a minimum above the maximum is not a usable wallet")
        } catch let error as LightningAddressVerificationError {
            guard case .malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testNonJSONResponseIsRejected() async throws {
        do {
            _ = try await LightningAddressVerifier(fetcher: StubFetcher("<html>nope</html>"))
                .verify(try address())
            XCTFail("expected a malformed-response error")
        } catch let error as LightningAddressVerificationError {
            guard case .malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testUnreachableWalletIsReportedRatherThanAccepted() async throws {
        struct Boom: Error {}
        do {
            _ = try await LightningAddressVerifier(fetcher: StubFetcher(error: Boom()))
                .verify(try address())
            XCTFail("a wallet we cannot reach must not be silently accepted")
        } catch let error as LightningAddressVerificationError {
            guard case .unreachable = error else {
                return XCTFail("expected unreachable, got \(error)")
            }
        }
    }

    // MARK: - Metadata parsing

    func testExtractsPlainTextDescriptionFromMetadata() {
        let metadata = #"[["text/identifier","alice@getalby.com"],["text/plain","Tip Alice"]]"#
        XCTAssertEqual(LightningAddressVerifier.description(fromMetadata: metadata), "Tip Alice")
    }

    func testToleratesMissingOrMalformedMetadata() {
        XCTAssertNil(LightningAddressVerifier.description(fromMetadata: nil))
        XCTAssertNil(LightningAddressVerifier.description(fromMetadata: "not json"))
        XCTAssertNil(LightningAddressVerifier.description(fromMetadata: "[]"))
        XCTAssertNil(LightningAddressVerifier.description(fromMetadata: #"[["image/png","..."]]"#))
    }
}
