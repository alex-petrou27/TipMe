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
        // Same-asset needs no conversion at all -- a direct route, same as
        // `WalletBackend.prepareSend` already returns for a known-amount
        // destination. Cross-asset conversion (sender pays USDT, creator
        // wants bitcoin) genuinely isn't built yet; that's the one real gap
        // left in `notYetAvailable`, not "sending" in general.
        guard tip.asset == receiveAsset else {
            throw PaymentBackendError.conversionUnavailable(from: tip.asset, to: receiveAsset)
        }
        return .direct(tip, at: clock.now)
    }

    public func send(route: SettlementRoute, to destination: LightningAddress,
                     idempotencyKey: String) async throws -> PaymentReceipt {
        throw PaymentBackendError.network(Self.notYetAvailable)
    }

    /// Tips a creator whose handle is linked to a TipMe account -- one call,
    /// straight ledger-to-ledger, via the registry's `/v1/tip/{platform}/
    /// {username}`. See `PaymentBackend.sendToCreatorAccount` and
    /// `PaymentEngine.execute`, which is what decides to call this instead
    /// of `send`.
    public func sendToCreatorAccount(handle: CreatorHandle, amount: Amount,
                                     idempotencyKey: String) async throws -> PaymentReceipt {
        guard let token = sessionTokenProvider() else {
            throw PaymentBackendError.notConnected
        }
        do {
            try await client.tipCreator(
                platform: handle.platform.rawValue, username: handle.username,
                asset: amount.asset, amountMinor: amount.minorUnits, sessionToken: token)
        } catch {
            throw Self.paymentBackendError(for: error)
        }
        return PaymentReceipt(status: .succeeded, paymentHash: "ledger:\(idempotencyKey)",
                              networkFee: .zero(amount.asset), sentAmount: amount,
                              completedAt: clock.now)
    }

    // MARK: - WalletBackend

    public func availableBalanceForSend(asset: Asset) async throws -> Amount {
        try await availableBalance(for: asset)
    }

    /// Bech32 human-readable prefixes for a native segwit on-chain address,
    /// across every network the registry's on-chain rail might be pointed
    /// at (see Registry's `REGISTRY_BITCOIN_NETWORK`). Legacy (`1...`) and
    /// P2SH (`3...`) addresses aren't recognised here -- the registry's
    /// send side doesn't support them yet either.
    private static let onchainAddressPrefixes = ["bc1", "tb1", "bcrt1"]

    public func resolve(destination raw: String) async throws -> WalletDestination {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        if lowercased.hasPrefix("ln"), let amountSats = BOLT11.amountSats(from: trimmed) {
            return .lightningInvoice(raw: trimmed, amountSat: amountSats, description: nil)
        }
        if Self.onchainAddressPrefixes.contains(where: lowercased.hasPrefix) {
            return .bitcoinAddress(raw: trimmed)
        }
        // Everything else is still unrecognised -- see the type-level note.
        // A Lightning address has nowhere to be resolved *to* yet.
        throw WalletDestinationError.unrecognised
    }

    public func prepareSend(amount: Amount, to destination: WalletDestination) async throws -> SettlementRoute {
        guard amount.asset == .bitcoin else {
            throw PaymentBackendError.conversionUnavailable(from: amount.asset, to: .bitcoin)
        }
        switch destination {
        case .lightningInvoice(_, let invoiceAmountSats, _):
            // Registry's withdraw endpoint only accepts fixed-amount
            // invoices -- `resolve` above never returns one with a nil
            // amount, but the amount an unrelated caller passes in here
            // could still disagree with what the invoice actually asks for.
            if let invoiceAmountSats, amount.minorUnits != invoiceAmountSats {
                throw PaymentBackendError.rejectedByNetwork(
                    "This invoice is fixed at \(Amount.sats(invoiceAmountSats).formatted).")
            }
            return .direct(amount, at: clock.now)
        case .bitcoinAddress:
            // On-chain has no fixed amount to check against -- the sender
            // chooses it, same as any exchange withdrawal.
            return .direct(amount, at: clock.now)
        default:
            throw PaymentBackendError.network(Self.notYetAvailable)
        }
    }

    public func send(route: SettlementRoute, to destination: WalletDestination,
                     idempotencyKey: String) async throws -> PaymentReceipt {
        guard let token = sessionTokenProvider() else {
            throw PaymentBackendError.notConnected
        }
        switch destination {
        case .lightningInvoice(let raw, _, _):
            do {
                let result = try await client.withdrawLightning(paymentRequest: raw, sessionToken: token)
                return PaymentReceipt(status: .succeeded, paymentHash: result.paymentHash,
                                      networkFee: .sats(result.feeSats), sentAmount: .sats(result.amountSats),
                                      completedAt: clock.now)
            } catch {
                throw Self.paymentBackendError(for: error)
            }
        case .bitcoinAddress(let raw):
            do {
                let result = try await client.withdrawBitcoin(toAddress: raw, amountSats: route.debited.minorUnits,
                                                               sessionToken: token)
                return PaymentReceipt(status: .succeeded, paymentHash: result.txid,
                                      networkFee: .sats(result.feeSats), sentAmount: .sats(result.amountSats),
                                      completedAt: clock.now)
            } catch {
                throw Self.paymentBackendError(for: error)
            }
        default:
            throw PaymentBackendError.network(Self.notYetAvailable)
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

    // MARK: - On-chain Bitcoin deposits
    //
    // Same reasoning as the Lightning deposit methods above: generating an
    // address is `receive`'s job in spirit, but polling it for settlement
    // needs its own shape. `OnChainDepositFlow` drives these directly.

    /// Asks the registry for a fresh on-chain address for this account.
    /// Unlike a Lightning invoice it has no fixed amount -- the ledger is
    /// credited with whatever confirmed amount later shows up at it.
    public func createOnChainDeposit() async throws -> String {
        guard let token = sessionTokenProvider() else {
            throw PaymentBackendError.notConnected
        }
        do {
            return try await client.depositBitcoinAddress(sessionToken: token)
        } catch {
            throw Self.paymentBackendError(for: error)
        }
    }

    /// Polls whether a previously-issued on-chain address has received a
    /// confirmed payment. Safe to call repeatedly.
    public func checkOnChainDeposit(address: String) async throws -> AccountClient.DepositStatus {
        guard let token = sessionTokenProvider() else {
            throw PaymentBackendError.notConnected
        }
        do {
            return try await client.checkBitcoinDeposit(address: address, sessionToken: token)
        } catch {
            throw Self.paymentBackendError(for: error)
        }
    }

    // MARK: - Apple Pay deposit
    //
    // Same reasoning as the Lightning/on-chain deposit methods above: a
    // single trusted credit, not a create-then-poll pair, because there is
    // no external settlement to wait on -- see the registry's
    // `deposit_apple_pay` docstring. `ApplePayDepositFlow` drives this
    // directly against the concrete type.

    /// Credits `amount` of USDT to this account. `reference` must be unique
    /// per attempt so a retry after a lost response can't double-credit --
    /// see `AccountClient.depositApplePay`.
    public func depositApplePay(amount: Amount, reference: String) async throws -> AccountClient.ApplePayDepositResult {
        guard let token = sessionTokenProvider() else {
            throw PaymentBackendError.notConnected
        }
        do {
            return try await client.depositApplePay(amountMinor: amount.minorUnits, reference: reference,
                                                     sessionToken: token)
        } catch {
            throw Self.paymentBackendError(for: error)
        }
    }

    // MARK: - Internal transfer
    //
    // Not part of `WalletBackend` or `PaymentBackend` -- sending to another
    // TipMe account by email is a different kind of destination than
    // anything `WalletDestination` models (an invoice, an address), and
    // forcing it through `resolve` would mean guessing whether an arbitrary
    // string is an email. `InternalTransferFlow` drives this directly.

    /// Moves money straight to another TipMe account's ledger -- no
    /// Lightning, no on-chain, no network beyond this one call. Only works
    /// when the recipient already has a TipMe account under that email.
    public func transfer(toEmail: String, amount: Amount) async throws -> AccountClient.TransferResult {
        guard let token = sessionTokenProvider() else {
            throw PaymentBackendError.notConnected
        }
        do {
            return try await client.transfer(toEmail: toEmail, asset: amount.asset,
                                             amountMinor: amount.minorUnits, sessionToken: token)
        } catch {
            throw Self.paymentBackendError(for: error)
        }
    }

    // MARK: - Pending tips (escrow for an unclaimed handle)
    //
    // Not part of `WalletBackend` or `PaymentBackend` -- same reasoning as
    // internal transfer above: there is no `CreatorRecord` for a handle
    // nobody has claimed, so nothing to route through `PaymentEngine`'s
    // intent machinery. `PendingTipFlow` drives these directly.

    /// Debits this account and escrows `amount` against `handle` -- see the
    /// registry's `POST /v1/tip/{platform}/{username}/pending`.
    public func sendPendingTip(handle: CreatorHandle, amount: Amount,
                               note: String?) async throws -> AccountClient.PendingTipSendResult {
        guard let token = sessionTokenProvider() else {
            throw PaymentBackendError.notConnected
        }
        do {
            return try await client.sendPendingTip(
                platform: handle.platform.rawValue, username: handle.username,
                asset: amount.asset, amountMinor: amount.minorUnits, note: note,
                sessionToken: token)
        } catch {
            throw Self.paymentBackendError(for: error)
        }
    }

    /// Every pending tip this account has ever sent -- see the registry's
    /// `GET /v1/tip/pending`.
    public func listPendingTips() async throws -> [AccountClient.PendingTipSummary] {
        guard let token = sessionTokenProvider() else {
            throw PaymentBackendError.notConnected
        }
        do {
            return try await client.listPendingTips(sessionToken: token)
        } catch {
            throw Self.paymentBackendError(for: error)
        }
    }

    /// Takes back a pending tip nobody has claimed yet -- see the
    /// registry's `POST /v1/tip/pending/{id}/reclaim`.
    public func reclaimPendingTip(id: String) async throws -> AccountClient.TransferResult {
        guard let token = sessionTokenProvider() else {
            throw PaymentBackendError.notConnected
        }
        do {
            return try await client.reclaimPendingTip(id: id, sessionToken: token)
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
        case .onchainUnavailable:
            return .network("On-chain sending isn't available on this registry right now.")
        case .onchainError(let detail):
            return .rejectedByNetwork(detail)
        case .recipientNotFound:
            return .rejectedByNetwork("No TipMe account exists with that email.")
        case .requestRejected(let detail):
            return .rejectedByNetwork(detail)
        case .handleAlreadyRegistered:
            return .rejectedByNetwork("That handle is already registered -- pay them directly instead.")
        case .pendingTipNotFound:
            return .rejectedByNetwork("That pending tip can't be found -- it may already be claimed or reclaimed.")
        case .invalidRequest, .emailTaken, .invalidCredentials, .tooManyAttempts,
             .transport, .responseMalformed:
            return .network(String(describing: accountError))
        }
    }
}
