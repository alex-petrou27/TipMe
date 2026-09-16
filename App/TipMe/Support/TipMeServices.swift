import Foundation
import BreezSDKLiquid
import TipMeCore

/// Composition root, shared by the host app and the share extension.
///
/// Both processes build the identical object graph from the identical
/// configuration. That is not tidiness for its own sake: if the extension
/// assembled its own slightly different graph, it would be the one place where
/// a cap, a rate limit or an audit write could quietly go missing.
public struct TipMeServices: Sendable {
    public let configuration: AppConfiguration
    public let backend: BreezPaymentBackend
    public let creatorResolver: CreatorResolver
    public let auditLog: AuditLog
    public let capLedger: SendCapLedger
    public let rateLimiter: TipRateLimiter
    public let engine: PaymentEngine
    public let gate: AuthorizationGate
    public let quoteBuilder: TipQuoteBuilder
    public let keychain: WalletKeychain
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

    public static func make(configuration: AppConfiguration,
                            origin: PaymentIntent.Origin,
                            clock: Clock = SystemClock()) throws -> TipMeServices {
        guard let store = AppGroupKeyValueStore(appGroup: configuration.appGroup) else {
            throw SharedContainer.ContainerError.appGroupUnavailable(configuration.appGroup)
        }

        let keychain = WalletKeychain(accessGroup: configuration.keychainAccessGroup)
        let workingDirectory = try SharedContainer.walletWorkingDirectory(appGroup: configuration.appGroup)

        let backend = BreezPaymentBackend(
            apiKey: configuration.breezApiKey,
            network: configuration.breezNetwork.lowercased() == "mainnet" ? .mainnet : .testnet,
            workingDirectory: workingDirectory,
            clock: clock,
            mnemonicProvider: { try keychain.loadMnemonic() })

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
            keychain: keychain,
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

    public var isWalletReady: Bool { keychain.hasMnemonic() }
}
