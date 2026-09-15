import Foundation

/// Outcome of a complete tip.
public struct TipResult: Equatable, Sendable {
    public let intentID: UUID
    public let tipReceipt: PaymentReceipt
    /// `nil` when no fee was charged (a waived small tip).
    public let feeReceipt: PaymentReceipt?
    /// Set when the tip landed but our fee collection did not.
    ///
    /// This is deliberately not an error. The creator has been paid, which is
    /// what the user asked for; TipMe simply failed to collect. Surfacing this
    /// as a failed tip would be a lie, and retrying the user's money without
    /// a fresh approval would be worse.
    public let feeCollectionFailed: String?

    public var creatorWasPaid: Bool {
        tipReceipt.status == .succeeded || tipReceipt.status == .pending
    }
}

public enum PaymentEngineError: Error, Equatable, Sendable {
    case intentExpired
    case intentAlreadyExecuted
    case rateStale(asOf: Date)
    case conversionQuoteStale(quotedAt: Date)
    case capExceeded(SendCapDecision)
    case rateLimited(RateLimitDecision)
    case insufficientFunds(available: Amount, required: Amount)
    case backend(PaymentBackendError)
    case creatorMinimumNotMet(minimum: Amount)
}

/// Executes authorised tips.
///
/// Phase 2 note: this type has no UIKit, no SwiftUI and no knowledge of the
/// share extension. An App Clip, an Instant App, or a server-side Instagram
/// comment webhook can drive exactly this engine. See `docs/PHASE2.md` for the
/// one genuine obstacle to the server-side case (a server cannot hold the
/// user's non-custodial keys), which is an architectural problem rather than a
/// packaging one.
public actor PaymentEngine {
    private let backend: PaymentBackend
    private let capLedger: SendCapLedger
    private let rateLimiter: TipRateLimiter
    private let auditLog: AuditLog
    private let clock: Clock
    private let feeDestination: LightningAddress

    /// Nonces of intents already executed. Prevents a token being replayed
    /// within its validity window.
    private var consumedNonces: Set<UUID> = []

    public init(backend: PaymentBackend,
                capLedger: SendCapLedger,
                rateLimiter: TipRateLimiter,
                auditLog: AuditLog,
                feeDestination: LightningAddress,
                clock: Clock = SystemClock()) {
        self.backend = backend
        self.capLedger = capLedger
        self.rateLimiter = rateLimiter
        self.auditLog = auditLog
        self.feeDestination = feeDestination
        self.clock = clock
    }

    /// The only way to spend money in this app.
    ///
    /// Note what happens before anything is sent: every gate is re-evaluated
    /// *here*, at spend time, not merely when the confirm screen was drawn. The
    /// screen may have been sitting open; the rate may have moved; the user may
    /// have tipped from the host app in another window. Checking only at render
    /// time would make all of these gates advisory.
    @discardableResult
    public func execute(_ authorized: AuthorizedIntent) async throws -> TipResult {
        let intent = authorized.intent
        let now = clock.now

        // --- Replay and freshness -----------------------------------------
        guard !consumedNonces.contains(authorized.nonce) else {
            throw PaymentEngineError.intentAlreadyExecuted
        }
        guard !authorized.isExpired(at: now) else {
            await log(.tipPaymentFailed, .rejected, intent, detail: "authorization expired")
            throw PaymentEngineError.intentExpired
        }
        consumedNonces.insert(authorized.nonce)

        let quote = intent.quote

        // The £ figure the user approved must still be the £ figure we spend.
        if now.timeIntervalSince(quote.rateAsOf) > RateFreshness.spendTolerance {
            await log(.tipPaymentFailed, .rejected, intent, detail: "exchange rate stale")
            throw PaymentEngineError.rateStale(asOf: quote.rateAsOf)
        }
        if quote.route.isStale(at: now, tolerance: RateFreshness.spendTolerance) {
            await log(.tipPaymentFailed, .rejected, intent, detail: "conversion quote stale")
            throw PaymentEngineError.conversionQuoteStale(quotedAt: quote.route.quotedAt)
        }

        // --- Hard gates, re-checked at spend time --------------------------
        let capDecision = await capLedger.evaluate(requested: quote.fiatTotal)
        await log(.capsEvaluated, capDecision.isAllowed ? .ok : .rejected, intent,
                  detail: capDecision.userFacingReason)
        guard capDecision.isAllowed else {
            throw PaymentEngineError.capExceeded(capDecision)
        }

        let handleKey = intent.creator.handle.registryKey
        let rateDecision = await rateLimiter.evaluate(handleKey: handleKey)
        await log(.rateLimitEvaluated, rateDecision.isAllowed ? .ok : .rejected, intent,
                  detail: rateDecision.userFacingReason)
        guard rateDecision.isAllowed else {
            throw PaymentEngineError.rateLimited(rateDecision)
        }

        // --- Funds -----------------------------------------------------------
        let available: Amount
        do {
            available = try await backend.availableBalance(for: quote.senderPays.asset)
        } catch let error as PaymentBackendError {
            throw PaymentEngineError.backend(error)
        }
        guard !(available < quote.senderPays) else {
            await log(.tipPaymentFailed, .rejected, intent, detail: "insufficient funds")
            throw PaymentEngineError.insufficientFunds(available: available, required: quote.senderPays)
        }

        // Count the attempt before the money moves. An attempt that fails after
        // this point still consumed a slot — otherwise a caller could retry a
        // failing payment without limit and never trip the limiter.
        await rateLimiter.record(handleKey: handleKey)
        await capLedger.record(spent: quote.fiatTotal)

        // --- Payment 1 of 2: the tip -----------------------------------------
        //
        // Sent first, always. LNURL-pay has no split primitive, so collecting a
        // sender-side fee while guaranteeing the creator receives the full tip
        // requires two separate payments. Ordering matters: if only one of the
        // two can succeed, it must be the creator's.
        await log(.tipPaymentAttempted, .ok, intent)
        let tipReceipt: PaymentReceipt
        do {
            tipReceipt = try await backend.send(route: quote.route,
                                                to: intent.creator.lightningAddress,
                                                idempotencyKey: "\(intent.id.uuidString):tip")
        } catch let error as PaymentBackendError {
            await log(.tipPaymentFailed, .failed, intent, detail: String(describing: error))
            throw PaymentEngineError.backend(error)
        }
        await log(.tipPaymentSucceeded, .ok, intent, paymentHash: tipReceipt.paymentHash)

        // --- Payment 2 of 2: our fee -----------------------------------------
        var feeReceipt: PaymentReceipt?
        var feeFailure: String?

        if quote.fee.isPositive {
            await log(.feePaymentAttempted, .ok, intent)
            do {
                let feeRoute = SettlementRoute.direct(quote.fee, at: now)
                feeReceipt = try await backend.send(route: feeRoute,
                                                    to: feeDestination,
                                                    idempotencyKey: "\(intent.id.uuidString):fee")
                await log(.feePaymentSucceeded, .ok, intent, paymentHash: feeReceipt?.paymentHash)
            } catch {
                // The creator has already been paid. We do not unwind, we do not
                // retry against the user's balance without a fresh approval, and
                // we do not report the tip as failed. We record it and move on.
                feeFailure = String(describing: error)
                await log(.feePaymentFailed, .failed, intent, detail: feeFailure)
            }
        }

        await log(.settled, .ok, intent, paymentHash: tipReceipt.paymentHash)

        return TipResult(intentID: intent.id,
                         tipReceipt: tipReceipt,
                         feeReceipt: feeReceipt,
                         feeCollectionFailed: feeFailure)
    }

    private func log(_ stage: AuditEvent.Stage,
                     _ outcome: AuditEvent.Outcome,
                     _ intent: PaymentIntent,
                     paymentHash: String? = nil,
                     detail: String? = nil) async {
        await auditLog.append(AuditEvent(
            timestamp: clock.now,
            intentID: intent.id.uuidString,
            stage: stage,
            outcome: outcome,
            origin: intent.origin.rawValue,
            platform: intent.creator.handle.platform.rawValue,
            handle: intent.creator.handle.username,
            destination: intent.creator.lightningAddress.redacted,
            asset: intent.quote.senderPays.asset.rawValue,
            tipMinorUnits: intent.quote.creatorReceives.minorUnits,
            feeMinorUnits: intent.quote.fee.minorUnits,
            fiatCurrency: intent.quote.fiatTotal.currencyCode,
            fiatMinorUnits: intent.quote.fiatTotal.minorUnits,
            paymentHash: paymentHash,
            detail: detail))
    }
}
