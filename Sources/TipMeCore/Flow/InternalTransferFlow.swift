import Foundation

public enum InternalTransferState: Sendable {
    case idle
    case confirming(toEmail: String, amount: Amount)
    case sending
    case succeeded(balances: [Asset: Int64])
    case failed(String)
}

/// Drives a transfer straight to another TipMe account's ledger -- no
/// Lightning, no on-chain, just two balances changing together
/// server-side. Still gated by Face ID like every other spend in this app:
/// it is real money leaving the sender's balance, even though nothing on a
/// network ever sees it move.
public actor InternalTransferFlow {
    private let backend: CustodialPaymentBackend
    private let gate: AuthorizationGate
    private let auditLog: AuditLog
    private let clock: Clock

    public init(backend: CustodialPaymentBackend, gate: AuthorizationGate,
                auditLog: AuditLog, clock: Clock = SystemClock()) {
        self.backend = backend
        self.gate = gate
        self.auditLog = auditLog
        self.clock = clock
    }

    public func confirm(toEmail: String, amount: Amount) -> InternalTransferState {
        .confirming(toEmail: toEmail, amount: amount)
    }

    public func send(toEmail: String, amount: Amount) async -> InternalTransferState {
        let intentID = UUID().uuidString
        let reason = "Send \(amount.formatted) to \(toEmail)"

        do {
            _ = try await gate.authorizeTransfer(reason: reason, intentID: intentID)
        } catch AuthorizationError.declined(.userCancelled) {
            return .confirming(toEmail: toEmail, amount: amount)
        } catch {
            return .failed("Confirmation failed. Nothing has been sent.")
        }

        do {
            let result = try await backend.transfer(toEmail: toEmail, amount: amount)
            await auditLog.append(AuditEvent(
                timestamp: clock.now, intentID: intentID, stage: .internalTransferSucceeded, outcome: .ok,
                origin: PaymentIntent.Origin.hostApp.rawValue,
                asset: amount.asset.rawValue, tipMinorUnits: amount.minorUnits))
            return .succeeded(balances: result.balances)
        } catch let error as PaymentBackendError {
            let message = TipFlow.describe(error)
            await auditLog.append(AuditEvent(
                timestamp: clock.now, intentID: intentID, stage: .internalTransferFailed, outcome: .failed,
                origin: PaymentIntent.Origin.hostApp.rawValue, detail: message))
            return .failed(message)
        } catch {
            return .failed("The transfer didn't go through. Nothing has been sent.")
        }
    }
}
