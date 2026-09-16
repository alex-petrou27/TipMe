import Foundation

public struct WalletSendResult: Equatable, Sendable {
    public let receipt: PaymentReceipt
    public let destination: WalletDestination
}

public enum WalletSendError: Error, Equatable, Sendable {
    case intentExpired
    case intentAlreadyExecuted
    case rateStale(asOf: Date)
    case routeStale(quotedAt: Date)
    case capExceeded(SendCapDecision)
    case rateLimited(RateLimitDecision)
    case insufficientFunds(available: Amount, required: Amount)
    case backend(PaymentBackendError)
}

/// A proposed general send, mirroring `PaymentIntent` but for any destination
/// rather than a registered creator.
public struct WalletSendIntent: Equatable, Sendable {
    public let id: UUID
    public let destination: WalletDestination
    public let amount: Amount
    public let route: SettlementRoute
    public let fiatAmount: FiatAmount
    public let rateAsOf: Date
    public let createdAt: Date

    public init(id: UUID = UUID(), destination: WalletDestination, amount: Amount,
                route: SettlementRoute, fiatAmount: FiatAmount, rateAsOf: Date, createdAt: Date) {
        self.id = id
        self.destination = destination
        self.amount = amount
        self.route = route
        self.fiatAmount = fiatAmount
        self.rateAsOf = rateAsOf
        self.createdAt = createdAt
    }
}

/// Executes authorised general sends: any Lightning invoice, on-chain address,
/// Liquid address, or Lightning address — not only a registered creator.
///
/// Deliberately a sibling of `PaymentEngine`, not a refactor of it. Tips carry
/// obligations general sends do not (the mandatory sender fee, the two-payment
/// split, per-creator rate limiting), and general sends carry one tips do not
/// (fee-free, single payment, no notion of "the same creator"). Forcing both
/// through one method would mean threading tip-only concepts through every
/// wallet send, or wallet-only concepts through every tip. Keeping them
/// separate keeps each engine's job legible; both still route through the same
/// `AuthorizationGate`, the same audit log, and their own `SendCapLedger`.
public actor WalletSendEngine {
    private let backend: WalletBackend
    private let capLedger: SendCapLedger
    private let auditLog: AuditLog
    private let clock: Clock

    private var consumedNonces: Set<UUID> = []

    public init(backend: WalletBackend, capLedger: SendCapLedger,
                auditLog: AuditLog, clock: Clock = SystemClock()) {
        self.backend = backend
        self.capLedger = capLedger
        self.auditLog = auditLog
        self.clock = clock
    }

    @discardableResult
    public func execute(_ authorized: AuthorizedWalletSend) async throws -> WalletSendResult {
        let intent = authorized.intent
        let now = clock.now

        guard !consumedNonces.contains(authorized.nonce) else {
            throw WalletSendError.intentAlreadyExecuted
        }
        guard !authorized.isExpired(at: now) else {
            throw WalletSendError.intentExpired
        }
        consumedNonces.insert(authorized.nonce)

        if now.timeIntervalSince(intent.rateAsOf) > RateFreshness.spendTolerance {
            throw WalletSendError.rateStale(asOf: intent.rateAsOf)
        }
        if intent.route.isStale(at: now, tolerance: RateFreshness.spendTolerance) {
            throw WalletSendError.routeStale(quotedAt: intent.route.quotedAt)
        }

        let capDecision = await capLedger.evaluate(requested: intent.fiatAmount)
        guard capDecision.isAllowed else {
            await log(.capsEvaluated, .rejected, intent, detail: capDecision.userFacingReason)
            throw WalletSendError.capExceeded(capDecision)
        }

        let available: Amount
        do {
            available = try await backend.availableBalanceForSend(asset: intent.amount.asset)
        } catch let error as PaymentBackendError {
            throw WalletSendError.backend(error)
        }
        guard !(available < intent.route.debited) else {
            await log(.walletSendFailed, .rejected, intent, detail: "insufficient funds")
            throw WalletSendError.insufficientFunds(available: available, required: intent.route.debited)
        }

        await capLedger.record(spent: intent.fiatAmount)

        await log(.walletSendAttempted, .ok, intent)
        do {
            let receipt = try await backend.send(route: intent.route, to: intent.destination,
                                                 idempotencyKey: intent.id.uuidString)
            await log(.walletSendSucceeded, .ok, intent, paymentHash: receipt.paymentHash)
            return WalletSendResult(receipt: receipt, destination: intent.destination)
        } catch let error as PaymentBackendError {
            await log(.walletSendFailed, .failed, intent, detail: String(describing: error))
            throw WalletSendError.backend(error)
        }
    }

    private func log(_ stage: AuditEvent.Stage, _ outcome: AuditEvent.Outcome,
                     _ intent: WalletSendIntent, paymentHash: String? = nil, detail: String? = nil) async {
        await auditLog.append(AuditEvent(
            timestamp: clock.now, intentID: intent.id.uuidString, stage: stage, outcome: outcome,
            origin: PaymentIntent.Origin.hostApp.rawValue,
            destination: intent.destination.displaySummary,
            asset: intent.amount.asset.rawValue,
            tipMinorUnits: intent.amount.minorUnits,
            fiatCurrency: intent.fiatAmount.currencyCode,
            fiatMinorUnits: intent.fiatAmount.minorUnits,
            detail: detail))
    }
}
