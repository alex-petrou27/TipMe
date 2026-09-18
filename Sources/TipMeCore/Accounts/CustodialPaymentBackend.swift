import Foundation

/// `PaymentBackend` + `WalletBackend` backed by TipMe's custodial ledger.
///
/// TipMe holds the actual money now, not the device -- balance reads go
/// straight to the registry's ledger via `AccountClient`. Sending does not
/// yet: the shared operational wallet that would actually move real
/// sats/USDT in and out on a user's behalf does not exist yet, so every
/// send-shaped method here throws rather than pretending to work. Wiring
/// that up is the next piece of the custodial build, not this one -- see
/// the conversation that led here for why the two were deliberately kept
/// separate.
public actor CustodialPaymentBackend: PaymentBackend, WalletBackend {
    private static let notYetAvailable = "Sending isn't available yet — the shared TipMe wallet that actually moves money is still being built."

    private let client: AccountClient
    private let rateProvider: RegistryRateProvider
    private let sessionTokenProvider: @Sendable () -> String?

    public init(client: AccountClient,
                rateProvider: RegistryRateProvider,
                sessionTokenProvider: @escaping @Sendable () -> String?) {
        self.client = client
        self.rateProvider = rateProvider
        self.sessionTokenProvider = sessionTokenProvider
    }

    // MARK: - PaymentBackend

    public func availableBalance(for asset: Asset) async throws -> Amount {
        let balances = try await fetchBalances()
        return Amount(asset: asset, minorUnits: balances[asset] ?? 0)
    }

    public func prepareRoute(tip: Amount, to destination: LightningAddress,
                             receiveAsset: Asset) async throws -> SettlementRoute {
        // A handle linked to a TipMe account (see InternalTipDestination's
        // doc comment) settles as a ledger transfer inside this same
        // registry, not a real Lightning send -- which is exactly the piece
        // of "the shared wallet isn't built yet" that a transfer between two
        // TipMe balances never needed in the first place.
        guard InternalTipDestination.handle(in: destination) != nil else {
            throw PaymentBackendError.network(Self.notYetAvailable)
        }
        // No conversion path exists yet for an internal transfer -- only
        // same-asset tips can be quoted until one is built.
        guard tip.asset == receiveAsset else {
            throw PaymentBackendError.conversionUnavailable(from: tip.asset, to: receiveAsset)
        }
        return SettlementRoute.direct(tip, at: Date())
    }

    public func send(route: SettlementRoute, to destination: LightningAddress,
                     idempotencyKey: String) async throws -> PaymentReceipt {
        guard let handle = InternalTipDestination.handle(in: destination) else {
            throw PaymentBackendError.network(Self.notYetAvailable)
        }
        guard let token = sessionTokenProvider() else {
            throw PaymentBackendError.notConnected
        }

        do {
            _ = try await client.tip(platform: handle.platform, username: handle.username, asset: route.sendAsset,
                                     amountMinorUnits: route.debited.minorUnits, sessionToken: token)
        } catch AccountClient.AccountError.insufficientFunds {
            let available = (try? await availableBalance(for: route.sendAsset)) ?? .zero(route.sendAsset)
            throw PaymentBackendError.insufficientFunds(available: available, required: route.debited)
        } catch AccountClient.AccountError.requestRejected(let detail) {
            throw PaymentBackendError.rejectedByNetwork(detail)
        } catch AccountClient.AccountError.sessionExpired {
            throw PaymentBackendError.notConnected
        } catch AccountClient.AccountError.offline {
            throw PaymentBackendError.network("You're offline.")
        } catch {
            throw PaymentBackendError.network(String(describing: error))
        }

        // `/v1/me/tip` has no notion of a payment hash -- the idempotency
        // key stands in as this transfer's unique identifier, the same role
        // a hash plays for a real Lightning payment.
        return PaymentReceipt(status: .succeeded, paymentHash: "internal-\(idempotencyKey)",
                              networkFee: .zero(route.sendAsset), sentAmount: route.debited,
                              completedAt: Date())
    }

    // MARK: - WalletBackend

    public func availableBalanceForSend(asset: Asset) async throws -> Amount {
        try await availableBalance(for: asset)
    }

    public func resolve(destination raw: String) async throws -> WalletDestination {
        // Nothing can be classified as sendable while there is nowhere to
        // send it -- see the type-level note.
        throw WalletDestinationError.unrecognised
    }

    public func prepareSend(amount: Amount, to destination: WalletDestination) async throws -> SettlementRoute {
        throw PaymentBackendError.network(Self.notYetAvailable)
    }

    public func send(route: SettlementRoute, to destination: WalletDestination,
                     idempotencyKey: String) async throws -> PaymentReceipt {
        throw PaymentBackendError.network(Self.notYetAvailable)
    }

    public func receive(amount: Amount?, method: ReceiveMethod) async throws -> ReceiveRequest {
        throw PaymentBackendError.network(Self.notYetAvailable)
    }

    public func transactionHistory(limit: Int) async throws -> [WalletTransaction] {
        // No ledger-entries endpoint yet either. An empty history is the
        // honest answer -- "we don't know of any transactions" -- rather
        // than a fabricated one.
        []
    }

    // MARK: - ExchangeRateProvider

    public func rate(for asset: Asset, in currencyCode: String) async throws -> AssetRate {
        try await rateProvider.rate(for: asset, in: currencyCode)
    }

    // MARK: - Shared

    private func fetchBalances() async throws -> [Asset: Int64] {
        guard let token = sessionTokenProvider() else {
            throw PaymentBackendError.notConnected
        }
        do {
            return try await client.me(sessionToken: token).balances
        } catch AccountClient.AccountError.sessionExpired {
            throw PaymentBackendError.notConnected
        } catch AccountClient.AccountError.offline {
            throw PaymentBackendError.network("You're offline.")
        } catch {
            throw PaymentBackendError.network(String(describing: error))
        }
    }
}
