import XCTest
@testable import TipMeCore

/// `resolve`/`prepareSend` for a raw Lightning invoice never touch the
/// network -- the amount comes from decoding the invoice locally (see
/// `BOLT11Tests`) -- so these are pure logic tests. `send` is covered
/// end-to-end via `StubURLProtocol` in `CustodialPaymentBackendSendTests`.
final class CustodialPaymentBackendLightningTests: XCTestCase {
    private let real300SatInvoice =
        "lntbs3u1p42c6qapp5ekjg0cnv3tgnahk02tyvf0td4074plmrl9zc69rhxvduzkq3j55qd" +
        "qqcqzzsxqrrsssp58677fv2z9lm6je0pme4y8pqnp4htc8aqp4lm2kmakdx5cjuxdzys9qx" +
        "pqysgq6sccgfxzdzn9c2vxpzd6q7ezy4c3hmwhpz8dp0gyve7mzxj34tys9qe0hww6l2cg8" +
        "u64alp938eckge69atlkh7s4hkhz084pya3r8cq3g9ecj"

    private func makeBackend(clock: Clock = MutableClock()) -> CustodialPaymentBackend {
        CustodialPaymentBackend(
            client: AccountClient(configuration: .init(baseURL: URL(string: "https://registry.test")!)),
            rateProvider: RegistryRateProvider(configuration: .init(baseURL: URL(string: "https://registry.test")!)),
            sessionTokenProvider: { "tok-123" },
            clock: clock)
    }

    func testResolveRecognisesAFixedAmountInvoice() async throws {
        let destination = try await makeBackend().resolve(destination: real300SatInvoice)
        guard case .lightningInvoice(let raw, let amountSat, _) = destination else {
            return XCTFail("expected a lightningInvoice destination")
        }
        XCTAssertEqual(raw, real300SatInvoice)
        XCTAssertEqual(amountSat, 300)
    }

    func testResolveTrimsWhitespaceAndIsCaseInsensitive() async throws {
        let destination = try await makeBackend().resolve(destination: "  \(real300SatInvoice.uppercased())\n")
        guard case .lightningInvoice(_, let amountSat, _) = destination else {
            return XCTFail("expected a lightningInvoice destination")
        }
        XCTAssertEqual(amountSat, 300)
    }

    func testResolveRejectsGarbage() async {
        do {
            _ = try await makeBackend().resolve(destination: "not a destination")
            XCTFail("expected an error")
        } catch WalletDestinationError.unrecognised {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testResolveRejectsZeroAmountInvoices() async {
        do {
            _ = try await makeBackend().resolve(destination: "lntbs1p42cer8pp5mockdata")
            XCTFail("expected an error")
        } catch WalletDestinationError.unrecognised {
            // expected -- fixed-amount invoices only, see WithdrawLightningRequest
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testPrepareSendReturnsADirectRouteMatchingTheInvoiceAmount() async throws {
        let clock = MutableClock()
        let backend = makeBackend(clock: clock)
        let destination = try await backend.resolve(destination: real300SatInvoice)

        let route = try await backend.prepareSend(amount: .sats(300), to: destination)
        XCTAssertEqual(route.sendAsset, .bitcoin)
        XCTAssertEqual(route.receiveAsset, .bitcoin)
        XCTAssertEqual(route.debited, .sats(300))
        XCTAssertEqual(route.credited, .sats(300))
        XCTAssertEqual(route.conversionCost, .zero(.bitcoin))
        XCTAssertEqual(route.quotedAt, clock.now)
    }

    func testPrepareSendRejectsAnAmountThatDisagreesWithTheInvoice() async throws {
        let backend = makeBackend()
        let destination = try await backend.resolve(destination: real300SatInvoice)

        do {
            _ = try await backend.prepareSend(amount: .sats(500), to: destination)
            XCTFail("expected an error")
        } catch PaymentBackendError.rejectedByNetwork {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testPrepareSendRejectsTheWrongAsset() async throws {
        let backend = makeBackend()
        let destination = try await backend.resolve(destination: real300SatInvoice)

        do {
            _ = try await backend.prepareSend(amount: .usdtCents(300), to: destination)
            XCTFail("expected an error")
        } catch PaymentBackendError.conversionUnavailable {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testResolveRecognisesAnOnChainAddress() async throws {
        let destination = try await makeBackend().resolve(destination: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")
        guard case .bitcoinAddress(let raw) = destination else {
            return XCTFail("expected a bitcoinAddress destination")
        }
        XCTAssertEqual(raw, "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")
    }

    func testResolveRecognisesTestnetAndRegtestOnChainPrefixes() async throws {
        let testnet = try await makeBackend().resolve(destination: "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx")
        guard case .bitcoinAddress = testnet else { return XCTFail("expected a bitcoinAddress destination") }

        let regtest = try await makeBackend().resolve(destination: "bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080")
        guard case .bitcoinAddress = regtest else { return XCTFail("expected a bitcoinAddress destination") }
    }

    func testPrepareSendForAnOnChainAddressHasNoFixedAmountToDisagreeWith() async throws {
        let backend = makeBackend()
        let destination = try await backend.resolve(destination: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")

        let route = try await backend.prepareSend(amount: .sats(4200), to: destination)
        XCTAssertEqual(route.debited, .sats(4200))
        XCTAssertEqual(route.credited, .sats(4200))
    }

    func testPrepareSendRejectsOtherDestinationKinds() async {
        let backend = makeBackend()
        do {
            _ = try await backend.prepareSend(amount: .sats(300), to: .liquidAddress(raw: "VJL...mock", assetHint: nil))
            XCTFail("expected an error")
        } catch PaymentBackendError.network {
            // expected -- only a raw Lightning invoice or on-chain Bitcoin
            // address are wired up so far
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

/// `send` for a raw Lightning invoice does hit the network (the registry's
/// real `/v1/withdraw/lightning`), stubbed here the same way
/// `AccountClientLightningTests` stubs the client directly.
final class CustodialPaymentBackendSendTests: XCTestCase {
    private let real300SatInvoice =
        "lntbs3u1p42c6qapp5ekjg0cnv3tgnahk02tyvf0td4074plmrl9zc69rhxvduzkq3j55qd" +
        "qqcqzzsxqrrsssp58677fv2z9lm6je0pme4y8pqnp4htc8aqp4lm2kmakdx5cjuxdzys9qx" +
        "pqysgq6sccgfxzdzn9c2vxpzd6q7ezy4c3hmwhpz8dp0gyve7mzxj34tys9qe0hww6l2cg8" +
        "u64alp938eckge69atlkh7s4hkhz084pya3r8cq3g9ecj"

    override func tearDown() {
        StubURLProtocol.stubs = []
        super.tearDown()
    }

    private func makeBackend() -> CustodialPaymentBackend {
        let baseURL = URL(string: "https://registry.test")!
        return CustodialPaymentBackend(
            client: AccountClient(configuration: .init(baseURL: baseURL), session: StubURLProtocol.session()),
            rateProvider: RegistryRateProvider(configuration: .init(baseURL: baseURL)),
            sessionTokenProvider: { "tok-123" })
    }

    func testSendPaysTheInvoiceAndReturnsAReceipt() async throws {
        StubURLProtocol.stubJSON(200, """
        {"payment_hash":"44dabd8f-d166-4e5b-96dd-82386a9cd53a","amount_sats":300,"fee_sats":0,"balances":[{"asset":"bitcoin","balance_minor":700},{"asset":"usdt","balance_minor":0}]}
        """)

        let backend = makeBackend()
        let destination = try await backend.resolve(destination: real300SatInvoice)
        let route = try await backend.prepareSend(amount: .sats(300), to: destination)
        let receipt = try await backend.send(route: route, to: destination, idempotencyKey: "idem-1")

        XCTAssertEqual(receipt.status, .succeeded)
        XCTAssertEqual(receipt.paymentHash, "44dabd8f-d166-4e5b-96dd-82386a9cd53a")
        XCTAssertEqual(receipt.sentAmount, .sats(300))
        XCTAssertEqual(receipt.networkFee, .sats(0))
    }

    func testSendSurfacesInsufficientBalanceAsRejectedByNetwork() async throws {
        StubURLProtocol.stubJSON(402, """
        {"detail":"insufficient balance"}
        """)

        let backend = makeBackend()
        let destination = try await backend.resolve(destination: real300SatInvoice)
        let route = try await backend.prepareSend(amount: .sats(300), to: destination)

        do {
            _ = try await backend.send(route: route, to: destination, idempotencyKey: "idem-1")
            XCTFail("expected an error")
        } catch PaymentBackendError.rejectedByNetwork {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testSendPaysAnOnChainAddressAndReturnsAReceipt() async throws {
        StubURLProtocol.stubJSON(200, """
        {"txid":"abc123","amount_sats":4200,"fee_sats":250,"balances":[{"asset":"bitcoin","balance_minor":1000},{"asset":"usdt","balance_minor":0}]}
        """)

        let backend = makeBackend()
        let destination = try await backend.resolve(destination: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")
        let route = try await backend.prepareSend(amount: .sats(4200), to: destination)
        let receipt = try await backend.send(route: route, to: destination, idempotencyKey: "idem-1")

        XCTAssertEqual(receipt.status, .succeeded)
        XCTAssertEqual(receipt.paymentHash, "abc123")
        XCTAssertEqual(receipt.sentAmount, .sats(4200))
        XCTAssertEqual(receipt.networkFee, .sats(250))
    }

    func testSendWithNoSessionTokenThrowsNotConnected() async throws {
        let baseURL = URL(string: "https://registry.test")!
        let backend = CustodialPaymentBackend(
            client: AccountClient(configuration: .init(baseURL: baseURL), session: StubURLProtocol.session()),
            rateProvider: RegistryRateProvider(configuration: .init(baseURL: baseURL)),
            sessionTokenProvider: { nil })
        let destination = try await backend.resolve(destination: real300SatInvoice)
        let route = try await backend.prepareSend(amount: .sats(300), to: destination)

        do {
            _ = try await backend.send(route: route, to: destination, idempotencyKey: "idem-1")
            XCTFail("expected an error")
        } catch PaymentBackendError.notConnected {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
