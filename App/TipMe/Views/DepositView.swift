import SwiftUI
import TipMeCore

enum DepositMethodChoice: String, CaseIterable {
    case lightning
    case onchain
    case applePay

    var label: String {
        switch self {
        case .lightning: return "Lightning"
        case .onchain: return "On-chain"
        case .applePay: return "Apple Pay"
        }
    }
}

@MainActor
final class DepositViewModel: ObservableObject {
    @Published var method: DepositMethodChoice = .lightning
    @Published var amountText = ""
    @Published private(set) var lightningState: LightningDepositState = .idle
    @Published private(set) var onchainState: OnChainDepositState = .idle
    @Published private(set) var applePayState: ApplePayDepositState = .idle
    @Published private(set) var copied = false

    private let lightningFlow: LightningDepositFlow
    private let onchainFlow: OnChainDepositFlow
    private let applePayFlow: ApplePayDepositFlow
    private let applePayAuthorizer = ApplePayAuthorizer()

    init(services: TipMeServices) {
        self.lightningFlow = services.makeLightningDepositFlow()
        self.onchainFlow = services.makeOnChainDepositFlow()
        self.applePayFlow = services.makeApplePayDepositFlow()
    }

    var isBusy: Bool {
        switch method {
        case .lightning: return lightningState == .creating
        case .onchain: return onchainState == .creating
        case .applePay: return applePayState == .paying
        }
    }

    /// Whether the device can show a real Apple Pay sheet at all -- says
    /// nothing about whether `ApplePayConfiguration.merchantIdentifier` is a
    /// real, registered merchant ID yet. See `ApplePayAuthorizer`.
    var canUseRealApplePay: Bool { ApplePayAuthorizer.canPay() }

    func create() async {
        switch method {
        case .lightning:
            guard let amountSats = Int64(amountText.filter(\.isNumber)), amountSats > 0 else {
                lightningState = .failed("Enter an amount.")
                return
            }
            lightningState = .creating
            lightningState = await lightningFlow.create(amountSats: amountSats)
        case .onchain:
            onchainState = .creating
            onchainState = await onchainFlow.create()
        case .applePay:
            await payWithApplePay()
        }
    }

    /// Dummy funding source -- see the registry's `deposit_apple_pay`
    /// docstring. Shows the real Apple Pay sheet when the device can
    /// present one; either way, what actually credits the ledger is the
    /// same one call with a fresh idempotency reference.
    private func payWithApplePay() async {
        guard let amountMinor = Self.parseDollarsToMinorUnits(amountText), amountMinor > 0 else {
            applePayState = .failed("Enter an amount.")
            return
        }
        applePayState = .paying

        if canUseRealApplePay {
            let dollars = Decimal(amountMinor) / 100
            guard let payment = await applePayAuthorizer.requestPayment(
                amount: dollars, currencyCode: "USD", label: "TipMe balance top-up",
            ) else {
                applePayState = .idle // cancelled or the sheet didn't present -- not a failure
                return
            }
            applePayState = await applePayFlow.pay(
                amountMinor: amountMinor, reference: payment.token.transactionIdentifier)
        } else {
            applePayState = await applePayFlow.pay(
                amountMinor: amountMinor, reference: "test-\(UUID().uuidString)")
        }
    }

    /// "12.34" -> 1234 minor units. Apple Pay's amount is naturally a dollar
    /// figure, unlike Lightning's sats -- this is the one deposit method
    /// here that needs decimal parsing rather than a bare integer.
    private static func parseDollarsToMinorUnits(_ text: String) -> Int64? {
        let normalised = text.replacingOccurrences(of: ",", with: ".")
        guard let dollars = Decimal(string: normalised), dollars > 0 else { return nil }
        return NSDecimalNumber(decimal: dollars * 100).int64Value
    }

    func checkStatus() async {
        switch method {
        case .lightning:
            guard case .awaitingPayment(let paymentRequest, let paymentHash, let amountSats) = lightningState else { return }
            lightningState = .checking(paymentRequest: paymentRequest, paymentHash: paymentHash, amountSats: amountSats)
            lightningState = await lightningFlow.checkStatus(paymentHash: paymentHash, paymentRequest: paymentRequest,
                                                              amountSats: amountSats)
        case .onchain:
            guard case .awaitingPayment(let address) = onchainState else { return }
            onchainState = .checking(address: address)
            onchainState = await onchainFlow.checkStatus(address: address)
        case .applePay:
            return // nothing to poll -- payWithApplePay already resolves synchronously.
        }
    }

    func copy(_ text: String) {
        UIPasteboard.general.string = text
        copied = true
    }

    func reset() {
        amountText = ""
        copied = false
        lightningState = .idle
        onchainState = .idle
        applePayState = .idle
    }
}

/// Adds real funds to the custodial balance, over Lightning (a fixed-amount
/// invoice) or on-chain (an address the sender decides how much to pay).
/// TipMe holds the money once either settles -- see `LightningDepositFlow`
/// and `OnChainDepositFlow`.
struct DepositView: View {
    @StateObject private var viewModel: DepositViewModel
    @Environment(\.dismiss) private var dismiss

    init(services: TipMeServices) {
        _viewModel = StateObject(wrappedValue: DepositViewModel(services: services))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                content
            }
            .padding(Theme.spacing)
        }
        .background(Theme.background)
        .navigationTitle("Deposit")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.method {
        case .lightning:
            lightningContent
        case .onchain:
            onchainContent
        case .applePay:
            applePayContent
        }
    }

    @ViewBuilder
    private var lightningContent: some View {
        switch viewModel.lightningState {
        case .idle, .creating:
            amountEntry
        case .awaitingPayment(let paymentRequest, _, let amountSats):
            invoiceDisplay(destination: paymentRequest, amountSats: amountSats, isChecking: false)
        case .checking(let paymentRequest, _, let amountSats):
            invoiceDisplay(destination: paymentRequest, amountSats: amountSats, isChecking: true)
        case .completed(let balances):
            successState(balances)
        case .failed(let message):
            failureState(message)
        }
    }

    @ViewBuilder
    private var onchainContent: some View {
        switch viewModel.onchainState {
        case .idle, .creating:
            amountEntry
        case .awaitingPayment(let address):
            invoiceDisplay(destination: address, amountSats: nil, isChecking: false)
        case .checking(let address):
            invoiceDisplay(destination: address, amountSats: nil, isChecking: true)
        case .completed(let balances):
            successState(balances)
        case .failed(let message):
            failureState(message)
        }
    }

    @ViewBuilder
    private var applePayContent: some View {
        switch viewModel.applePayState {
        case .idle, .paying:
            amountEntry
        case .completed(let balances):
            successState(balances, asset: .usdt)
        case .failed(let message):
            failureState(message)
        }
    }

    private var methodPicker: some View {
        Picker("Method", selection: $viewModel.method) {
            ForEach(DepositMethodChoice.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var amountEntry: some View {
        VStack(spacing: Theme.spacing) {
            methodPicker

            Card {
                switch viewModel.method {
                case .lightning:
                    Text("Add real sats to your TipMe balance over Lightning.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                    TextField("Amount (sats)", text: $viewModel.amountText)
                        .keyboardType(.numberPad)
                        .font(Theme.amountLarge)
                        .multilineTextAlignment(.center)
                case .onchain:
                    Text("Get a real Bitcoin address. Send whatever amount you like to it from any wallet.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                case .applePay:
                    Text(viewModel.canUseRealApplePay
                         ? "Add funds with Apple Pay."
                         : "Apple Pay isn't set up on this device. Add test funds instead — no card needed.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                    TextField("Amount (USD)", text: $viewModel.amountText)
                        .keyboardType(.decimalPad)
                        .font(Theme.amountLarge)
                        .multilineTextAlignment(.center)
                }
            }

            PrimaryButton(title: amountEntryButtonTitle, isLoading: viewModel.isBusy) {
                Task { await viewModel.create() }
            }
        }
    }

    private var amountEntryButtonTitle: String {
        switch viewModel.method {
        case .lightning: return "Create invoice"
        case .onchain: return "Get address"
        case .applePay: return viewModel.canUseRealApplePay ? "Pay with Apple Pay" : "Add test funds"
        }
    }

    private func invoiceDisplay(destination: String, amountSats: Int64?, isChecking: Bool) -> some View {
        VStack(spacing: Theme.spacing) {
            Card {
                VStack(spacing: Theme.spacing) {
                    QRCodeView(content: destination)
                        .frame(width: 220, height: 220)
                        .padding(Theme.spacingSmall)
                        .background(.white, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))

                    if let amountSats {
                        Text(TipMeCore.Amount.sats(amountSats).formatted)
                            .font(Theme.amountMedium)
                    }

                    Text(destination)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    PrimaryButton(title: viewModel.copied ? "Copied" : "Copy",
                                 systemImage: viewModel.copied ? "checkmark" : "doc.on.doc") {
                        viewModel.copy(destination)
                    }
                }
            }

            PrimaryButton(title: "I've paid — check now", isLoading: isChecking) {
                Task { await viewModel.checkStatus() }
            }

            Text(viewModel.method == .lightning
                 ? "Pay this invoice from any Lightning wallet. TipMe holds the funds once it settles."
                 : "Send from any Bitcoin wallet. On-chain takes real confirmation time, unlike Lightning — this can take a while.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.spacingLarge)
        }
    }

    private func successState(_ balances: [Asset: Int64], asset: Asset = .bitcoin) -> some View {
        VStack(spacing: Theme.spacing) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.positive)
            Text("Deposited").font(Theme.title)
            if let minorUnits = balances[asset] {
                Text(Self.formatted(minorUnits, asset: asset)).font(Theme.amountMedium)
            }
            PrimaryButton(title: "Done") { dismiss() }
        }
        .padding(.vertical, 24)
    }

    private static func formatted(_ minorUnits: Int64, asset: Asset) -> String {
        switch asset {
        case .bitcoin: return TipMeCore.Amount.sats(minorUnits).formatted
        case .usdt: return TipMeCore.Amount.usdtCents(minorUnits).formatted
        }
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: Theme.spacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.warning)
            Text(message).font(Theme.body).multilineTextAlignment(.center)
            PrimaryButton(title: "Try again") { viewModel.reset() }
        }
        .padding(.vertical, 24)
    }
}
