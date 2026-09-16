import Foundation

public enum WalletSendState: Sendable {
    case idle
    case resolving
    case destinationFound(WalletDestination)
    case unrecognised(reason: String)
    case quoted(WalletDestination, Amount, SettlementRoute, FiatAmount)
    case sending
    case succeeded(WalletSendResult)
    case failed(String)
}

/// Drives "send to anything" — paste an invoice, an address, or a Lightning
/// address, price it, confirm with Face ID, send. The general-purpose sibling
/// of `TipFlow`.
public actor WalletSendFlow {
    private let backend: WalletBackend
    private let gate: AuthorizationGate
    private let engine: WalletSendEngine
    private let clock: Clock
    private let fiatCurrency: String

    public init(backend: WalletBackend, gate: AuthorizationGate, engine: WalletSendEngine,
                clock: Clock = SystemClock(), fiatCurrency: String = "GBP") {
        self.backend = backend
        self.gate = gate
        self.engine = engine
        self.clock = clock
        self.fiatCurrency = fiatCurrency
    }

    public func identify(pasted raw: String) async -> WalletSendState {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unrecognised(reason: "Paste an address, invoice, or Lightning address.") }
        do {
            let destination = try await backend.resolve(destination: trimmed)
            return .destinationFound(destination)
        } catch {
            return .unrecognised(reason: "That doesn't look like a Bitcoin address, Lightning invoice, or Lightning address.")
        }
    }

    public func quote(amount: Amount, for destination: WalletDestination) async -> WalletSendState {
        do {
            let route = try await backend.prepareSend(amount: amount, to: destination)
            let rate: AssetRate
            if let paymentBackend = backend as? ExchangeRateProvider {
                rate = try await paymentBackend.rate(for: amount.asset, in: fiatCurrency)
            } else {
                return .failed("Couldn't price that right now.")
            }
            let fiat = rate.fiatValue(of: route.debited + route.conversionCost)
            return .quoted(destination, amount, route, fiat)
        } catch let error as PaymentBackendError {
            return .failed(TipFlow.describe(error))
        } catch {
            return .failed("Couldn't price that send. Try again in a moment.")
        }
    }

    public func confirmAndSend(destination: WalletDestination, amount: Amount,
                               route: SettlementRoute, fiatAmount: FiatAmount) async -> WalletSendState {
        let intent = WalletSendIntent(destination: destination, amount: amount, route: route,
                                      fiatAmount: fiatAmount, rateAsOf: clock.now, createdAt: clock.now)
        let reason = "Send \(fiatAmount.formatted) to \(destination.displaySummary)"

        let authorized: AuthorizedWalletSend
        do {
            authorized = try await gate.authorize(intent, reason: reason)
        } catch AuthorizationError.declined(.userCancelled) {
            return .quoted(destination, amount, route, fiatAmount)
        } catch {
            return .failed("Confirmation failed. Nothing has been sent.")
        }

        do {
            let result = try await engine.execute(authorized)
            return .succeeded(result)
        } catch let error as WalletSendError {
            return .failed(Self.describe(error))
        } catch {
            return .failed("The send didn't go through. Nothing has been sent.")
        }
    }

    static func describe(_ error: WalletSendError) -> String {
        switch error {
        case .intentExpired: return "That confirmation timed out. Try again."
        case .intentAlreadyExecuted: return "That send has already gone through."
        case .rateStale, .routeStale: return "The rate moved. Check the new amount and try again."
        case .capExceeded(let decision): return decision.userFacingReason ?? "That's over your send limit."
        case .rateLimited(let decision): return decision.userFacingReason ?? "You're sending too quickly."
        case .insufficientFunds(let available, let required):
            return "You need \(required.formatted) but only have \(available.formatted)."
        case .backend(let backendError): return TipFlow.describe(backendError)
        }
    }
}
