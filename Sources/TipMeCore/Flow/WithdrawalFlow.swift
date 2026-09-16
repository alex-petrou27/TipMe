import Foundation

public enum WithdrawalState: Sendable {
    case checkingAvailability
    /// The honest default state with the shipped `UnavailableFiatOffRampProvider`.
    /// See `docs/BANKING.md` for what has to exist before this ever changes.
    case unavailable(reason: String)
    case noBankLinked
    case ready(BankAccount)
    case quoted(WithdrawalQuote, BankAccount)
    case submitting
    case succeeded(WithdrawalReceipt)
    case failed(String)
}

/// Drives bank withdrawal — the one part of this app that cannot be made real
/// by writing more Swift. Every state here is reachable and every transition
/// is real; what is missing is a licensed partner behind `FiatOffRampProvider`,
/// which is a business and compliance undertaking, not an engineering one.
public actor WithdrawalFlow {
    private let provider: FiatOffRampProvider
    private let gate: AuthorizationGate
    private let auditLog: AuditLog
    private let clock: Clock

    public init(provider: FiatOffRampProvider, gate: AuthorizationGate,
                auditLog: AuditLog, clock: Clock = SystemClock()) {
        self.provider = provider
        self.gate = gate
        self.auditLog = auditLog
        self.clock = clock
    }

    public func start() async -> WithdrawalState {
        guard await provider.isAvailable() else {
            do {
                _ = try await provider.linkedBankAccounts()
                return .noBankLinked
            } catch let error as FiatOffRampError {
                await auditLog.append(AuditEvent(timestamp: clock.now, intentID: "-",
                                                 stage: .withdrawalUnavailable, outcome: .rejected,
                                                 origin: "hostApp", detail: error.userFacingReason))
                return .unavailable(reason: error.userFacingReason)
            } catch {
                return .unavailable(reason: "Withdrawals aren't available right now.")
            }
        }

        do {
            let accounts = try await provider.linkedBankAccounts()
            guard let first = accounts.first else { return .noBankLinked }
            return .ready(first)
        } catch let error as FiatOffRampError {
            return .unavailable(reason: error.userFacingReason)
        } catch {
            return .unavailable(reason: "Couldn't check your linked accounts.")
        }
    }

    public func linkAccount() async -> WithdrawalState {
        do {
            let account = try await provider.linkBankAccount()
            return .ready(account)
        } catch let error as FiatOffRampError {
            return .unavailable(reason: error.userFacingReason)
        } catch {
            return .unavailable(reason: "Couldn't link a bank account right now.")
        }
    }

    public func quote(amount: Amount, account: BankAccount) async -> WithdrawalState {
        do {
            let quote = try await provider.quoteWithdrawal(amount: amount, to: account)
            return .quoted(quote, account)
        } catch let error as FiatOffRampError {
            return .failed(error.userFacingReason)
        } catch {
            return .failed("Couldn't price that withdrawal.")
        }
    }

    /// Still gated by Face ID, even though the shipped provider always refuses
    /// — moving money out to a bank account is exactly the kind of spend the
    /// rest of this app never lets through without a live human, and that
    /// does not become optional just because this particular rail is not real
    /// yet.
    public func confirmAndWithdraw(quote: WithdrawalQuote, account: BankAccount) async -> WithdrawalState {
        let intent = PaymentIntent(
            quote: TipQuote(creatorReceives: quote.debited, fee: .zero(quote.debited.asset),
                            route: .direct(quote.debited, at: clock.now), senderPays: quote.debited,
                            fiatTotal: quote.fiatCredited, fiatTip: quote.fiatCredited,
                            fiatFee: quote.feeFiat, rateAsOf: clock.now,
                            feePolicy: FeePolicy(rateBasisPoints: 0,
                                                 bitcoin: FeeAssetRule(minimumFee: 0, waiveTipsBelow: 0),
                                                 usdt: FeeAssetRule(minimumFee: 0, waiveTipsBelow: 0))),
            creator: CreatorRecord(handle: CreatorHandle(platform: .tiktok, rawUsername: "withdrawal")!,
                                   lightningAddress: LightningAddress("withdrawal@tipme.local")!,
                                   preferredAsset: quote.debited.asset, updatedAt: clock.now, verified: true),
            sourceLink: nil, origin: .hostApp, createdAt: clock.now)

        do {
            _ = try await gate.authorize(intent)
        } catch AuthorizationError.declined(.userCancelled) {
            return .quoted(quote, account)
        } catch {
            return .failed("Confirmation failed. Nothing has been withdrawn.")
        }

        await auditLog.append(AuditEvent(timestamp: clock.now, intentID: quote.id,
                                         stage: .withdrawalRequested, outcome: .ok, origin: "hostApp",
                                         asset: quote.debited.asset.rawValue,
                                         tipMinorUnits: quote.debited.minorUnits,
                                         fiatCurrency: quote.fiatCredited.currencyCode,
                                         fiatMinorUnits: quote.fiatCredited.minorUnits))

        do {
            let receipt = try await provider.executeWithdrawal(quote: quote, to: account)
            await auditLog.append(AuditEvent(timestamp: clock.now, intentID: quote.id,
                                             stage: .withdrawalSucceeded, outcome: .ok, origin: "hostApp"))
            return .succeeded(receipt)
        } catch let error as FiatOffRampError {
            await auditLog.append(AuditEvent(timestamp: clock.now, intentID: quote.id,
                                             stage: .withdrawalFailed, outcome: .rejected,
                                             origin: "hostApp", detail: error.userFacingReason))
            return .failed(error.userFacingReason)
        } catch {
            return .failed("The withdrawal didn't go through.")
        }
    }
}
