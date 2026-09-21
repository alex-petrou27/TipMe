import Foundation

public enum PendingTipState: Sendable {
    case idle
    case confirming(handle: CreatorHandle, amount: Amount, fiatAmount: FiatAmount, note: String?)
    case sending
    /// `pendingTipID` lets the sender find this exact tip again later (to
    /// reclaim it) without re-deriving it from a list.
    case succeeded(handle: CreatorHandle, amount: Amount, pendingTipID: String, balances: [Asset: Int64])
    case failed(String)
}

/// Sends a tip to a handle nobody has claimed on TipMe yet -- the "pay my
/// friend's graduation post before they've ever heard of TipMe" case
/// `TipFlow` hands off here the moment `creatorResolver` comes back
/// `.notRegistered`.
///
/// Modelled directly on `InternalTransferFlow`: no `CreatorRecord` exists
/// for a handle nobody has claimed, so there is no `lightningAddress` to
/// route through and nothing for `PaymentEngine`'s intent machinery to
/// spend against. This is a ledger-only debit, gated by Face ID the same
/// way every other spend in this app is, landing straight in the
/// registry's escrow -- see `CustodialPaymentBackend.sendPendingTip` and
/// the registry's own `_maybe_claim_pending` for what makes it safe to
/// release later.
public actor PendingTipFlow {
    private let backend: CustodialPaymentBackend
    private let gate: AuthorizationGate
    private let auditLog: AuditLog
    private let clock: Clock
    /// Which surface initiated this -- the share extension (tipping straight
    /// from a share) or the host app (Tip by Handle). Unlike
    /// `InternalTransferFlow`, this flow is reachable from both, so it can't
    /// hardcode one the way that flow safely does.
    private let origin: PaymentIntent.Origin

    public init(backend: CustodialPaymentBackend, gate: AuthorizationGate,
               auditLog: AuditLog, clock: Clock = SystemClock(),
               origin: PaymentIntent.Origin) {
        self.backend = backend
        self.gate = gate
        self.auditLog = auditLog
        self.clock = clock
        self.origin = origin
    }

    public func confirm(handle: CreatorHandle, amount: Amount, fiatAmount: FiatAmount,
                        note: String?) -> PendingTipState {
        .confirming(handle: handle, amount: amount, fiatAmount: fiatAmount, note: note)
    }

    public func send(handle: CreatorHandle, amount: Amount, fiatAmount: FiatAmount,
                     note: String?) async -> PendingTipState {
        let intentID = UUID().uuidString
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = "Send \(fiatAmount.formatted) to \(handle.displayName)"

        do {
            _ = try await gate.authorizeTransfer(reason: reason, intentID: intentID)
        } catch AuthorizationError.declined(.userCancelled) {
            return .confirming(handle: handle, amount: amount, fiatAmount: fiatAmount, note: note)
        } catch {
            return .failed("Confirmation failed. Nothing has been sent.")
        }

        do {
            let result = try await backend.sendPendingTip(
                handle: handle, amount: amount,
                note: (trimmedNote?.isEmpty ?? true) ? nil : trimmedNote)
            await auditLog.append(AuditEvent(
                timestamp: clock.now, intentID: intentID, stage: .pendingTipSent, outcome: .ok,
                origin: origin.rawValue,
                platform: handle.platform.rawValue, handle: handle.username,
                asset: amount.asset.rawValue, tipMinorUnits: amount.minorUnits))
            return .succeeded(handle: handle, amount: amount,
                              pendingTipID: result.pendingTipID, balances: result.balances)
        } catch let error as PaymentBackendError {
            let message = TipFlow.describe(error)
            await auditLog.append(AuditEvent(
                timestamp: clock.now, intentID: intentID, stage: .pendingTipFailed, outcome: .failed,
                origin: origin.rawValue,
                platform: handle.platform.rawValue, handle: handle.username, detail: message))
            return .failed(message)
        } catch {
            return .failed("The tip didn't go through. Nothing has been sent.")
        }
    }

    /// Every pending tip this account has ever sent, for an Activity-style
    /// list that also offers "take back" on whichever are still waiting.
    public func listSent() async throws -> [AccountClient.PendingTipSummary] {
        try await backend.listPendingTips()
    }

    /// Takes back a pending tip nobody has claimed yet.
    public func reclaim(id: String) async -> Result<[Asset: Int64], String> {
        do {
            let result = try await backend.reclaimPendingTip(id: id)
            await auditLog.append(AuditEvent(
                timestamp: clock.now, intentID: id, stage: .pendingTipReclaimed, outcome: .ok,
                origin: origin.rawValue))
            return .success(result.balances)
        } catch let error as PaymentBackendError {
            let message = TipFlow.describe(error)
            await auditLog.append(AuditEvent(
                timestamp: clock.now, intentID: id, stage: .pendingTipReclaimFailed, outcome: .failed,
                origin: origin.rawValue, detail: message))
            return .failure(message)
        } catch {
            return .failure("Couldn't take that back right now. Try again in a moment.")
        }
    }
}
