import Foundation
import TipMeCore

/// Composition root, shared by the host app and the share extension.
///
/// Both processes build the identical object graph from the identical
/// configuration. That is not tidiness for its own sake: if the extension
/// assembled its own slightly different graph, it would be the one place where
/// a cap, a rate limit or an audit write could quietly go missing.
public struct TipMeServices: Sendable {
    public let configuration: AppConfiguration
    public let backend: CustodialPaymentBackend
    public let creatorResolver: CreatorResolver
    public let auditLog: AuditLog
    public let capLedger: SendCapLedger
    public let rateLimiter: TipRateLimiter
    public let engine: PaymentEngine
    public let gate: AuthorizationGate
    public let quoteBuilder: TipQuoteBuilder
    public let accountKeychain: AccountKeychain
    public let accountClient: AccountClient
    public let creatorTokens: CreatorTokenStore
    /// Separate from `capLedger`: general wallet spending and tip spending are
    /// deliberately independent budgets — see `SendCapLedger`'s `namespace`.
    public let walletCapLedger: SendCapLedger
    public let walletEngine: WalletSendEngine
    /// The only shipped implementation always refuses. See docs/BANKING.md.
    public let offRampProvider: FiatOffRampProvider

    public static func make(origin: PaymentIntent.Origin,
                            bundle: Bundle = .main,
                            clock: Clock = SystemClock()) throws -> TipMeServices {
        let configuration = try AppConfiguration.load(from: bundle.infoDictionary ?? [:])
        return try make(configuration: configuration, origin: origin, clock: clock)
    }

    public static func make(configuration baseConfiguration: AppConfiguration,
                            origin: PaymentIntent.Origin,
                            clock: Clock = SystemClock()) throws -> TipMeServices {
        guard let store = AppGroupKeyValueStore(appGroup: baseConfiguration.appGroup) else {
            throw SharedContainer.ContainerError.appGroupUnavailable(baseConfiguration.appGroup)
        }

        // The user's own currency choice wins over the build's default. The
        // send caps are held in whole units of that currency (the same
        // numbers, not converted), so they follow it.
        var configuration = baseConfiguration
        if let chosen = CurrencyPreference(store: store).saved {
            configuration.fiatCurrency = chosen
        }
        configuration.capPolicy.currencyCode = configuration.fiatCurrency
        if let limits = SendLimitsPreference(store: store).saved {
            configuration.capPolicy.perTip = limits.perTip
            configuration.capPolicy.perDay = limits.perDay
            configuration.capPolicy.perWeek = limits.perWeek
        }

        let accountKeychain = AccountKeychain(accessGroup: configuration.keychainAccessGroup)
        let accountClient = AccountClient(configuration: .init(baseURL: configuration.registryBaseURL))
        let rateProvider = RegistryRateProvider(configuration: .init(baseURL: configuration.registryBaseURL),
                                                clock: clock)

        // Reads the keychain synchronously on every call rather than caching
        // the token in memory, so a log-out in one process (app or share
        // extension) is picked up by the other on its very next request
        // instead of after a relaunch.
        let backend = CustodialPaymentBackend(
            client: accountClient,
            rateProvider: rateProvider,
            sessionTokenProvider: { try? accountKeychain.loadSession().sessionToken },
            clock: clock)

        let auditLog = JSONLinesAuditLog(
            fileURL: try SharedContainer.auditLogURL(appGroup: configuration.appGroup))

        let capLedger = SendCapLedger(store: store, clock: clock, policy: configuration.capPolicy,
                                      namespace: "tips")
        let rateLimiter = TipRateLimiter(store: store, clock: clock, policy: configuration.rateLimitPolicy)
        // Wallet sends get a materially higher ceiling than tips — this is now
        // a general wallet, and a tip-sized daily cap would make an ordinary
        // withdrawal-sized send impossible. 20x the tip cap is a starting
        // point, not a considered regulatory figure; operators should tune it.
        let walletCapLedger = SendCapLedger(
            store: store, clock: clock,
            policy: SendCapPolicy(currencyCode: configuration.capPolicy.currencyCode,
                                  perTip: configuration.capPolicy.perTip * 20,
                                  perDay: configuration.capPolicy.perDay * 20,
                                  perWeek: configuration.capPolicy.perWeek * 20),
            namespace: "wallet")

        let resolver = CachingCreatorResolver(
            upstream: RegistryClient(
                configuration: .init(baseURL: configuration.registryBaseURL,
                                     signingPublicKey: configuration.registryPublicKey),
                clock: clock),
            clock: clock)

        let gate = AuthorizationGate(authorizer: LocalAuthenticationAuthorizer(),
                                    clock: clock, auditLog: auditLog)

        return TipMeServices(
            configuration: configuration,
            backend: backend,
            creatorResolver: resolver,
            auditLog: auditLog,
            capLedger: capLedger,
            rateLimiter: rateLimiter,
            engine: PaymentEngine(backend: backend,
                                  capLedger: capLedger,
                                  rateLimiter: rateLimiter,
                                  auditLog: auditLog,
                                  feeDestination: configuration.feeDestination,
                                  clock: clock),
            gate: gate,
            quoteBuilder: TipQuoteBuilder(feePolicy: configuration.feePolicy),
            accountKeychain: accountKeychain,
            accountClient: accountClient,
            creatorTokens: CreatorTokenStore(accessGroup: configuration.keychainAccessGroup),
            walletCapLedger: walletCapLedger,
            walletEngine: WalletSendEngine(backend: backend, capLedger: walletCapLedger,
                                           auditLog: auditLog, clock: clock),
            // Real bank withdrawals need a licensed partner integration, which
            // is a business and compliance undertaking, not something this
            // constructor can create. See docs/BANKING.md.
            offRampProvider: UnavailableFiatOffRampProvider())
    }

    public func makeFlow(origin: PaymentIntent.Origin, clock: Clock = SystemClock()) -> TipFlow {
        TipFlow(shortLinkResolver: ShortLinkResolver(),
                creatorResolver: creatorResolver,
                backend: backend,
                quoteBuilder: quoteBuilder,
                gate: gate,
                engine: engine,
                auditLog: auditLog,
                clock: clock,
                fiatCurrency: configuration.fiatCurrency,
                origin: origin)
    }

    public func makeWalletSendFlow(clock: Clock = SystemClock()) -> WalletSendFlow {
        WalletSendFlow(backend: backend, gate: gate, engine: walletEngine,
                       clock: clock, fiatCurrency: configuration.fiatCurrency)
    }

    public func makeWithdrawalFlow(clock: Clock = SystemClock()) -> WithdrawalFlow {
        WithdrawalFlow(provider: offRampProvider, gate: gate, auditLog: auditLog, clock: clock)
    }

    public func makeLightningDepositFlow() -> LightningDepositFlow {
        LightningDepositFlow(backend: backend)
    }

    public func makeOnChainDepositFlow() -> OnChainDepositFlow {
        OnChainDepositFlow(backend: backend)
    }

    public func makeApplePayDepositFlow() -> ApplePayDepositFlow {
        ApplePayDepositFlow(backend: backend)
    }

    public func makeInternalTransferFlow(clock: Clock = SystemClock()) -> InternalTransferFlow {
        InternalTransferFlow(backend: backend, gate: gate, auditLog: auditLog, clock: clock)
    }

    public func makePendingTipFlow(origin: PaymentIntent.Origin,
                                   clock: Clock = SystemClock()) -> PendingTipFlow {
        PendingTipFlow(backend: backend, gate: gate, auditLog: auditLog, clock: clock, origin: origin)
    }

    public var isSignedIn: Bool { accountKeychain.hasSession() }
}
