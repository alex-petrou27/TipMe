import Foundation

/// A bank account a user has linked for withdrawals.
public struct BankAccount: Equatable, Sendable, Identifiable {
    public let id: String
    /// e.g. "Checking ····4821". Never the full account number.
    public let displayName: String
    public let currencyCode: String
    public let verified: Bool

    public init(id: String, displayName: String, currencyCode: String, verified: Bool) {
        self.id = id
        self.displayName = displayName
        self.currencyCode = currencyCode
        self.verified = verified
    }
}

public struct WithdrawalQuote: Equatable, Sendable {
    public let id: String
    public let debited: Amount
    public let fiatCredited: FiatAmount
    public let exchangeRate: AssetRate
    public let feeFiat: FiatAmount
    public let estimatedArrival: DateComponents
    public let expiresAt: Date

    public init(id: String, debited: Amount, fiatCredited: FiatAmount, exchangeRate: AssetRate,
                feeFiat: FiatAmount, estimatedArrival: DateComponents, expiresAt: Date) {
        self.id = id
        self.debited = debited
        self.fiatCredited = fiatCredited
        self.exchangeRate = exchangeRate
        self.feeFiat = feeFiat
        self.estimatedArrival = estimatedArrival
        self.expiresAt = expiresAt
    }
}

public struct WithdrawalReceipt: Equatable, Sendable {
    public let id: String
    public let status: String
    public let fiatCredited: FiatAmount
    public let bankAccount: BankAccount
    public let submittedAt: Date

    public init(id: String, status: String, fiatCredited: FiatAmount,
                bankAccount: BankAccount, submittedAt: Date) {
        self.id = id
        self.status = status
        self.fiatCredited = fiatCredited
        self.bankAccount = bankAccount
        self.submittedAt = submittedAt
    }
}

public enum FiatOffRampError: Error, Equatable, Sendable {
    /// The honest answer, today, everywhere. Converting crypto to fiat and
    /// wiring it to a bank account is regulated money transmission — the
    /// reason Strike itself holds money-transmitter licenses state by state
    /// rather than this being a feature any wallet can simply switch on.
    /// Nothing in this app can make that licensing exist; this case is what
    /// stands in its place until a real licensed partner is integrated.
    case notAvailable(reason: String)
    case accountNotLinked
    case belowMinimum(minimum: FiatAmount)
    case aboveMaximum(maximum: FiatAmount)
    case kycRequired
    case quoteExpired

    public var userFacingReason: String {
        switch self {
        case .notAvailable(let reason): return reason
        case .accountNotLinked: return "Link a bank account first."
        case .belowMinimum(let minimum): return "Minimum withdrawal is \(minimum.formatted)."
        case .aboveMaximum(let maximum): return "Maximum withdrawal is \(maximum.formatted)."
        case .kycRequired: return "Identity verification is required before withdrawing."
        case .quoteExpired: return "That quote expired. Get a new one."
        }
    }
}

/// The seam a real banking partner plugs into.
///
/// `TipMeCore` and the withdrawal UI are built completely against this
/// protocol so that turning on real bank withdrawals later is a matter of
/// writing one new conforming type — a `FiatOffRampProvider` backed by
/// whichever licensed banking-as-a-service or money-transmitter partner is
/// contracted (the kind of role a service like a licensed BaaS/off-ramp
/// provider plays for apps that are not themselves money transmitters) —
/// rather than touching the app's architecture.
///
/// `UnavailableFiatOffRampProvider` is the only implementation shipped in this
/// repository, and it always answers `.notAvailable`. That is not a
/// placeholder to "finish later" by writing fake success responses; it is the
/// honest state of the feature. See `docs/BANKING.md`.
public protocol FiatOffRampProvider: Sendable {
    func isAvailable() async -> Bool
    func linkedBankAccounts() async throws -> [BankAccount]
    func linkBankAccount() async throws -> BankAccount
    func quoteWithdrawal(amount: Amount, to account: BankAccount) async throws -> WithdrawalQuote
    func executeWithdrawal(quote: WithdrawalQuote, to account: BankAccount) async throws -> WithdrawalReceipt
}

/// The only `FiatOffRampProvider` this repository ships. Every method reports
/// the same honest fact: nobody has licensed money transmission for this app
/// yet, so no code path here may pretend otherwise.
public struct UnavailableFiatOffRampProvider: FiatOffRampProvider {
    public let reason: String

    public init(reason: String = "Bank withdrawals need a licensed banking partner, which isn't connected yet.") {
        self.reason = reason
    }

    public func isAvailable() async -> Bool { false }

    public func linkedBankAccounts() async throws -> [BankAccount] {
        throw FiatOffRampError.notAvailable(reason: reason)
    }

    public func linkBankAccount() async throws -> BankAccount {
        throw FiatOffRampError.notAvailable(reason: reason)
    }

    public func quoteWithdrawal(amount: Amount, to account: BankAccount) async throws -> WithdrawalQuote {
        throw FiatOffRampError.notAvailable(reason: reason)
    }

    public func executeWithdrawal(quote: WithdrawalQuote, to account: BankAccount) async throws -> WithdrawalReceipt {
        throw FiatOffRampError.notAvailable(reason: reason)
    }
}
