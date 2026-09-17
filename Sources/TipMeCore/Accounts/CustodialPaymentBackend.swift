import Foundation

/// `PaymentBackend` + `WalletBackend` backed by TipMe's custodial ledger.
///
/// TipMe holds the actual money now, not the device -- balance reads go
/// straight to the registry's ledger via `AccountClient`. Sending to a
/// registered creator's Lightning address (`PaymentBackend`) and sending to
/// anything else except a raw Lightning invoice (`WalletBackend`) still
/// throw: the shared operational wallet that would resolve and pay an
/// arbitrary destination does not exist yet. Paying a raw BOLT11 invoice is
/// the one send-shaped path that is real, because the registry's own
/// `/v1/withdraw/lightning` -- built and live-tested against Voltage -- does
/// exactly that already; see `resolve`/`prepareSend`/`send` below.
public actor CustodialPaymentBackend: PaymentBackend, WalletBackend {
    private static let notYetAvailable = "Sending isn't available yet — the shared TipMe wallet that actually moves money is still being built."

    private let client: AccountClient
    private let rateProvider: RegistryRateProvider
    private let sessionTokenProvider: @Sendable () -> String?
    private let clock: Clock

    public init(client: AccountClient,
                rateProvider: RegistryRateProvider,
                sessionTokenProvider: @escaping @Sendable () -> String?,
                clock: Clock = SystemClock()) {
        self.client = client
        self.rateProvider = rateProvider
        self.sessionTokenProvider = sessionTokenProvider
        self.clock = clock
    }

    // MARK: - PaymentBackend

    public func availableBalance(for asset: Asset) async throws -> Amount {
        let balances = try await fetchBalances()
        return Amount(asset: asset, minorUnits: balances[asset] ?? 0)
    }

    public func prepareRoute(tip: Amount, to destination: LightningAddress,
                             receiveAsset: Asset) async throws -> SettlementRoute {
        throw PaymentBackendError.network(Self.notYetAvailable)
    }

    public func send(route: SettlementRoute, to destination: LightningAddress,
                     idempotencyKey: String) async throws -> PaymentReceipt {
        throw PaymentBackendError.network(Self.notYetAvailable)
    }

    // MARK: - WalletBackend

    public func availableBalanceForSend(asset: Asset) async throws -> Amount {
        try await availableBalance(for: asset)
    }

    public func resolve(destination raw: String) async throws -> WalletDestination {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Everything except a raw BOLT11 invoice is still unrecognised --
        // see the type-level note. A Lightning address or an on-chain
        // address has nowhere to be resolved *to* yet.
        guard trimmed.lowercased().hasPrefix("ln"), let amountSats = BOLT11.amountSats(from: trimmed) else {
            throw WalletDestinationError.unrecognised
        }
        return .lightningInvoice(raw: trimmed, amountSat: amountSats, description: nil)
    }

    public func prepareSend(amount: Amount, to destination: WalletDestination) async throws -> SettlementRoute {
        guard case .lightningInvoice(_, let invoiceAmountSats, _) = destination else {
            throw PaymentBackendError.network(Self.notYetAvailable)
        }
        guard amount.asset == .bitcoin else {
            throw PaymentBackendError.conversionUnavailable(from: amount.asset, to: .bitcoin)
        }
        // Registry's withdraw endpoint only accepts fixed-amount invoices --
        // `resolve` above never returns one with a nil amount, but the
        // amount an unrelated caller passes in here could still disagree
        // with what the invoice actually asks for.
        if let invoiceAmountSats, amount.minorUnits != invoiceAmountSats {
            throw PaymentBackendError.rejectedByNetwork(
                "This invoice is fixed at \(Amount.sats(invoiceAmountSats).formatted).")
        }
        return .direct(amount, at: clock.now)
    }

    public func send(route: SettlementRoute, to destination: WalletDestination,
                     idempotencyKey: String) async throws -> PaymentReceipt {
        guard case .lightningInvoice(let raw, _, _) = destination else {
            throw PaymentBackendError.network(Self.notYetAvailable)
        }
        guard let token = sessionTokenProvider() else {
            throw PaymentBackendError.notConnected
        }
        do {
            let result = try await client.withdrawLightning(paymentRequest: raw, sessionToken: token)
            return PaymentReceipt(status: .succeeded, paymentHash: result.paymentHash,
                                  networkFee: .sats(result.feeSats), sentAmount: .sats(result.amountSats),
                                  completedAt: clock.now)
        } catch {
            throw Self.paymentBackendError(for: error)
        }
    }

    public func receive(amount: Amount?, method: ReceiveMethod) async throws -> ReceiveRequest {
        throw PaymentBackendError.network(Self.notYetAvailable)
    }

    // MARK: - Lightning deposits
    //
    // Not part of `WalletBackend`: generating something to be paid is that
    // protocol's job (`receive(amount:method:)`), but a custodial Lightning
    // deposit needs its own explicit "has it settled yet?" poll that no
    // other receive method here has a shape for. `LightningDepositFlow`
    // drives these two directly against the concrete type.

    /// Asks the registry for a real invoice to add `amountSats` to this
    /// account. Nothing is credited until `checkLightningDeposit` reports it
    /// settled.
    public func createLightningDeposit(amountSats: Int64) async throws -> AccountClient.DepositInvoice {
        guard let token = sessionTokenProvider() else {
            throw PaymentBackendError.notConnected
        }
        do {
            return try await client.depositLightningInvoice(amountSats: amountSats, sessionToken: token)
        } catch {
            throw Self.paymentBackendError(for: error)
        }
    }

    /// Polls whether a previously-created deposit invoice has settled. Safe
    /// to call repeatedly.
    public func checkLightningDeposit(paymentHash: String) async throws -> AccountClient.DepositStatus {
        guard let token = sessionTokenProvider() else {
            throw PaymentBackendError.notConnected
        }
        do {
            return try await client.checkLightningDeposit(paymentHash: paymentHash, sessionToken: token)
        } catch {
            throw Self.paymentBackendError(for: error)
        }
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
        } catch {
            throw Self.paymentBackendError(for: error)
        }
    }

    /// Shared `AccountClient.AccountError` -> `PaymentBackendError` mapping
    /// for every call this backend makes. `.network`/`.rejectedByNetwork`
    /// both render through `TipFlow.describe`, so the distinction here is
    /// just "is this the user's fault" -- a rejected invoice or an
    /// insufficient balance is `.rejectedByNetwork`; everything about the
    /// connection or the registry itself is `.network`.
    private static func paymentBackendError(for error: Error) -> PaymentBackendError {
        guard let accountError = error as? AccountClient.AccountError else {
            return .network(String(describing: error))
        }
        switch accountError {
        case .sessionExpired:
            return .notConnected
        case .offline:
            return .network("You're offline.")
        case .lightningUnavailable:
            return .network("Lightning isn't available on this registry right now.")
        case .lightningNodeError(let detail):
            return .network(detail)
        case .lightningRequestInvalid(let detail):
            return .rejectedByNetwork(detail)
        case .insufficientBalance:
            return .rejectedByNetwork("You don't have enough balance for that.")
        case .invoiceAlreadyPaid:
            return .rejectedByNetwork("That invoice has already been paid.")
        case .depositNotFound:
            return .rejectedByNetwork("That deposit could not be found.")
        case .invalidRequest, .emailTaken, .invalidCredentials, .tooManyAttempts,
             .transport, .responseMalformed:
            return .network(String(describing: accountError))
        }
    }
}
