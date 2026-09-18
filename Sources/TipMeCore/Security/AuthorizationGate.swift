import Foundation

/// A proposed payment. Anything may construct one of these — describing a
/// payment is harmless.
public struct PaymentIntent: Equatable, Sendable {
    public let id: UUID
    public let quote: TipQuote
    public let creator: CreatorRecord
    public let sourceLink: URL?
    public let origin: Origin
    public let createdAt: Date

    public enum Origin: String, Codable, Sendable {
        case shareExtension
        case hostApp
        case manualEntry
    }

    public init(id: UUID = UUID(), quote: TipQuote, creator: CreatorRecord,
                sourceLink: URL?, origin: Origin, createdAt: Date) {
        self.id = id
        self.quote = quote
        self.creator = creator
        self.sourceLink = sourceLink
        self.origin = origin
        self.createdAt = createdAt
    }
}

/// Result of asking the OS to verify the human.
public enum BiometricOutcome: Equatable, Sendable {
    case succeeded(method: String)
    case userCancelled
    case userFallback
    case unavailable(reason: String)
    case failed(reason: String)
}

/// Performs the platform biometric check. Implemented on iOS by
/// `LocalAuthenticationAuthorizer` (LAContext / Face ID / Touch ID).
public protocol BiometricAuthorizer: Sendable {
    func evaluate(reason: String) async -> BiometricOutcome
}

public enum AuthorizationError: Error, Equatable, Sendable {
    case declined(BiometricOutcome)
    case intentExpired
    case intentAlreadyUsed
}

// ---------------------------------------------------------------------------
// MARK: - The gate
// ---------------------------------------------------------------------------

/// Proof that a specific payment was approved by a present human, just now.
///
/// ## Why this type exists
///
/// `PaymentEngine.execute` accepts **only** an `AuthorizedIntent`, and the only
/// initialiser for `AuthorizedIntent` is `private` to this file. The sole code
/// that can reach it is `AuthorizationGate.authorize(_:)`, which does not
/// return one unless a live biometric check succeeded.
///
/// The consequence is the security property the brief asks for, enforced by the
/// compiler rather than by reviewer vigilance: **there is no code path from a
/// text input, a model response, a URL, a push payload, or any future assistant
/// layer to a spend.** Such a layer can construct a `PaymentIntent` and can ask
/// the gate to authorise it, but the gate always routes through the OS
/// biometric prompt, and the resulting token is single-use and short-lived. An
/// automated caller cannot mint one, cannot forge one, and cannot replay one.
///
/// Adding an assistant later does not weaken this. The worst an assistant can
/// do is *propose* a payment that a human must then physically approve.
public struct AuthorizedIntent: Sendable {
    public let intent: PaymentIntent
    public let authorizedAt: Date
    public let expiresAt: Date
    public let method: String
    /// Single-use marker. `PaymentEngine` burns it on execution.
    public let nonce: UUID

    /// Deliberately private. Do not add a public, internal, or `@testable`
    /// initialiser to this type — doing so removes the guarantee above.
    private init(intent: PaymentIntent, authorizedAt: Date, expiresAt: Date, method: String) {
        self.intent = intent
        self.authorizedAt = authorizedAt
        self.expiresAt = expiresAt
        self.method = method
        self.nonce = UUID()
    }

    fileprivate static func mint(intent: PaymentIntent, authorizedAt: Date,
                                 validFor: TimeInterval, method: String) -> AuthorizedIntent {
        AuthorizedIntent(intent: intent,
                         authorizedAt: authorizedAt,
                         expiresAt: authorizedAt.addingTimeInterval(validFor),
                         method: method)
    }

    public func isExpired(at now: Date) -> Bool { now >= expiresAt }
}

/// Proof that a specific internal transfer (TipMe account to TipMe account,
/// by email) was approved by a present human, just now.
///
/// Neither `PaymentIntent` (a registered creator's Lightning address) nor
/// `WalletSendIntent` (a `WalletDestination` -- an invoice, an address)
/// actually fits "send to another TipMe account's email" without
/// conflating it with an external payment rail it has nothing to do with.
/// This is a separate, narrower proof for that one case, minted the same
/// way and with the same guarantee as the other two: the sole initialiser
/// is `private` to this file, and the sole minting call
/// (`AuthorizationGate.authorizeTransfer`) lives here too.
public struct AuthorizedTransfer: Sendable {
    public let authorizedAt: Date
    public let expiresAt: Date
    public let nonce: UUID

    private init(authorizedAt: Date, expiresAt: Date) {
        self.authorizedAt = authorizedAt
        self.expiresAt = expiresAt
        self.nonce = UUID()
    }

    fileprivate static func mint(authorizedAt: Date, validFor: TimeInterval) -> AuthorizedTransfer {
        AuthorizedTransfer(authorizedAt: authorizedAt, expiresAt: authorizedAt.addingTimeInterval(validFor))
    }

    public func isExpired(at now: Date) -> Bool { now >= expiresAt }
}

/// The only route from a proposed payment to an executable one.
public actor AuthorizationGate {
    /// How long an approval stays good. Short on purpose: it exists to cover
    /// the moment between Face ID succeeding and the payment leaving, not to
    /// let an approval sit around and be spent later.
    public static let approvalValidity: TimeInterval = 60

    private let authorizer: BiometricAuthorizer
    private let clock: Clock
    private let auditLog: AuditLog

    public init(authorizer: BiometricAuthorizer, clock: Clock = SystemClock(), auditLog: AuditLog) {
        self.authorizer = authorizer
        self.clock = clock
        self.auditLog = auditLog
    }

    /// Prompts the human and, only on success, mints a single-use token.
    ///
    /// The prompt string names the creator and the exact total, so the system
    /// biometric sheet itself states what is being approved — the user does not
    /// have to trust that our screen and our payment agree.
    public func authorize(_ intent: PaymentIntent) async throws -> AuthorizedIntent {
        await auditLog.append(AuditEvent(
            timestamp: clock.now,
            intentID: intent.id.uuidString,
            stage: .authorizationRequested,
            outcome: .ok,
            origin: intent.origin.rawValue,
            platform: intent.creator.handle.platform.rawValue,
            handle: intent.creator.handle.username,
            destination: intent.creator.lightningAddress.redacted,
            asset: intent.quote.senderPays.asset.rawValue,
            tipMinorUnits: intent.quote.creatorReceives.minorUnits,
            feeMinorUnits: intent.quote.fee.minorUnits,
            fiatCurrency: intent.quote.fiatTotal.currencyCode,
            fiatMinorUnits: intent.quote.fiatTotal.minorUnits))

        let reason = "Send \(intent.quote.fiatTotal.formatted) to \(intent.creator.handle.displayName)"
        let outcome = await authorizer.evaluate(reason: reason)

        guard case .succeeded(let method) = outcome else {
            await auditLog.append(AuditEvent(
                timestamp: clock.now,
                intentID: intent.id.uuidString,
                stage: .authorizationDenied,
                outcome: .rejected,
                origin: intent.origin.rawValue,
                platform: intent.creator.handle.platform.rawValue,
                handle: intent.creator.handle.username,
                detail: String(describing: outcome)))
            throw AuthorizationError.declined(outcome)
        }

        await auditLog.append(AuditEvent(
            timestamp: clock.now,
            intentID: intent.id.uuidString,
            stage: .authorizationGranted,
            outcome: .ok,
            origin: intent.origin.rawValue,
            platform: intent.creator.handle.platform.rawValue,
            handle: intent.creator.handle.username,
            detail: method))

        return AuthorizedIntent.mint(intent: intent,
                                     authorizedAt: clock.now,
                                     validFor: Self.approvalValidity,
                                     method: method)
    }

    /// Authorises a general wallet send through the identical biometric path a
    /// tip uses — same gate, same single-use expiring token shape, same
    /// "declined means no code path to a spend" guarantee. `reason` is what
    /// the system biometric sheet actually displays, so callers pass something
    /// concrete ("Send £50.00 to bc1q…"), not the type's own description of
    /// itself.
    public func authorize(_ send: WalletSendIntent, reason: String) async throws -> AuthorizedWalletSend {
        await auditLog.append(AuditEvent(
            timestamp: clock.now, intentID: send.id.uuidString,
            stage: .authorizationRequested, outcome: .ok, origin: PaymentIntent.Origin.hostApp.rawValue,
            destination: send.destination.displaySummary, asset: send.amount.asset.rawValue,
            tipMinorUnits: send.amount.minorUnits, fiatCurrency: send.fiatAmount.currencyCode,
            fiatMinorUnits: send.fiatAmount.minorUnits))

        let outcome = await authorizer.evaluate(reason: reason)
        guard case .succeeded = outcome else {
            await auditLog.append(AuditEvent(
                timestamp: clock.now, intentID: send.id.uuidString,
                stage: .authorizationDenied, outcome: .rejected, origin: PaymentIntent.Origin.hostApp.rawValue,
                detail: String(describing: outcome)))
            throw AuthorizationError.declined(outcome)
        }

        await auditLog.append(AuditEvent(
            timestamp: clock.now, intentID: send.id.uuidString,
            stage: .authorizationGranted, outcome: .ok, origin: PaymentIntent.Origin.hostApp.rawValue))

        return AuthorizedWalletSend.mint(intent: send, authorizedAt: clock.now,
                                         validFor: Self.approvalValidity)
    }

    /// Authorises an internal transfer through the identical biometric path
    /// every other spend in this app uses. `reason` is what the system
    /// biometric sheet displays -- pass something concrete ("Send £5.00 to
    /// friend@example.com"), not a generic label.
    public func authorizeTransfer(reason: String, intentID: String) async throws -> AuthorizedTransfer {
        await auditLog.append(AuditEvent(
            timestamp: clock.now, intentID: intentID,
            stage: .authorizationRequested, outcome: .ok, origin: PaymentIntent.Origin.hostApp.rawValue))

        let outcome = await authorizer.evaluate(reason: reason)
        guard case .succeeded = outcome else {
            await auditLog.append(AuditEvent(
                timestamp: clock.now, intentID: intentID,
                stage: .authorizationDenied, outcome: .rejected, origin: PaymentIntent.Origin.hostApp.rawValue,
                detail: String(describing: outcome)))
            throw AuthorizationError.declined(outcome)
        }

        await auditLog.append(AuditEvent(
            timestamp: clock.now, intentID: intentID,
            stage: .authorizationGranted, outcome: .ok, origin: PaymentIntent.Origin.hostApp.rawValue))

        return AuthorizedTransfer.mint(authorizedAt: clock.now, validFor: Self.approvalValidity)
    }
}

// MARK: - Wallet sends

/// Proof that a specific general wallet send was approved by a present human,
/// just now. The counterpart to `AuthorizedIntent` for the "send to anything"
/// path rather than the tip path.
///
/// Same enforcement as `AuthorizedIntent`, for the same reason: the sole
/// initialiser is `private` to this file, and the sole minting call
/// (`AuthorizationGate.authorize(_:reason:)` above) lives in this same file.
/// Nothing outside `AuthorizationGate.swift` can construct one without a live
/// biometric check having just succeeded.
public struct AuthorizedWalletSend: Sendable {
    public let intent: WalletSendIntent
    public let authorizedAt: Date
    public let expiresAt: Date
    public let nonce: UUID

    private init(intent: WalletSendIntent, authorizedAt: Date, expiresAt: Date) {
        self.intent = intent
        self.authorizedAt = authorizedAt
        self.expiresAt = expiresAt
        self.nonce = UUID()
    }

    fileprivate static func mint(intent: WalletSendIntent, authorizedAt: Date,
                                 validFor: TimeInterval) -> AuthorizedWalletSend {
        AuthorizedWalletSend(intent: intent, authorizedAt: authorizedAt,
                             expiresAt: authorizedAt.addingTimeInterval(validFor))
    }

    public func isExpired(at now: Date) -> Bool { now >= expiresAt }
}
