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

        let capLedger = SendCapLedger(store: store, clock: clock, policy: configuration.capPolicy)
        let rateLimiter = TipRateLimiter(store: store, clock: clock, policy: configuration.rateLimitPolicy)

        let resolver = CachingCreatorResolver(
            upstream: RegistryClient(
                configuration: .init(baseURL: configuration.registryBaseURL,
                                     signingPublicKey: configuration.registryPublicKey),
                clock: clock),
            clock: clock)

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
            gate: AuthorizationGate(authorizer: LocalAuthenticationAuthorizer(),
                                    clock: clock,
                                    auditLog: auditLog),
            quoteBuilder: TipQuoteBuilder(feePolicy: configuration.feePolicy),
            keychain: keychain,
            creatorTokens: CreatorTokenStore(accessGroup: configuration.keychainAccessGroup))
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

    public var isWalletReady: Bool { keychain.hasMnemonic() }
}
