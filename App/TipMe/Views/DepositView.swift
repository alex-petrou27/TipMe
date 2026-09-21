import SwiftUI
import TipMeCore

enum DepositMethodChoice: String, CaseIterable {
    case applePay
    case lightning
    case onchain

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
    // Apple Pay first: it's the only deposit method that works without real
    // Lightning/on-chain infrastructure configured (Voltage credentials,
    // etc.), which this registry almost certainly doesn't have set up for
    // a prototype. Landing on Lightning by default meant "Deposit" silently
    // failed with a 503 for anyone testing without that configured --
    // confirmed live, read as "it just won't let me deposit."
    @Published var method: DepositMethodChoice = .applePay
    @Published var amountText = ""
    @Published private(set) var lightningState: LightningDepositState = .idle
    @Published private(set) var onchainState: OnChainDepositState = .idle
    @Published private(set) var applePayState: ApplePayDepositState = .idle
    @Published private(set) var copied = false
    /// What was asked for, in the user's own currency -- shown instead of the
    /// sats or USDT it was converted into.
    @Published private(set) var requestedFiat: FiatAmount?

    let currencyCode: String
    private let services: TipMeServices
    private let lightningFlow: LightningDepositFlow
    private let onchainFlow: OnChainDepositFlow
    private let applePayFlow: ApplePayDepositFlow
    private let applePayAuthorizer = ApplePayAuthorizer()

    init(services: TipMeServices) {
        self.services = services
        self.currencyCode = services.currencyCode
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
            guard let fiat = FiatAmount(parsing: amountText, currencyCode: currencyCode) else {
                lightningState = .failed("Enter an amount.")
                return
            }
            lightningState = .creating
            guard let sats = try? await services.assetAmount(for: fiat, in: .bitcoin), sats.minorUnits > 0 else {
                lightningState = .failed("Couldn't get today's exchange rate. Try again in a moment.")
                return
            }
            requestedFiat = fiat
            lightningState = await lightningFlow.create(amountSats: sats.minorUnits)
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
        guard let fiat = FiatAmount(parsing: amountText, currencyCode: currencyCode) else {
            applePayState = .failed("Enter an amount.")
            return
        }
        applePayState = .paying

        guard let usdt = try? await services.assetAmount(for: fiat, in: .usdt), usdt.minorUnits > 0 else {
            applePayState = .failed("Couldn't get today's exchange rate. Try again in a moment.")
            return
        }
        requestedFiat = fiat

        if canUseRealApplePay {
            let amount = Decimal(fiat.minorUnits) / 100
            guard let payment = await applePayAuthorizer.requestPayment(
                amount: amount, currencyCode: currencyCode, label: "TipMe balance top-up",
            ) else {
                applePayState = .idle // cancelled or the sheet didn't present -- not a failure
                return
            }
            applePayState = await applePayFlow.pay(
                amountMinor: usdt.minorUnits, reference: payment.token.transactionIdentifier)
        } else {
            applePayState = await applePayFlow.pay(
                amountMinor: usdt.minorUnits, reference: "test-\(UUID().uuidString)")
        }
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
        requestedFiat = nil
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
        .animation(Theme.motion, value: viewModel.method)
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
        case .awaitingPayment(let paymentRequest, _, _):
            invoiceDisplay(destination: paymentRequest, showAmount: true, isChecking: false)
        case .checking(let paymentRequest, _, _):
            invoiceDisplay(destination: paymentRequest, showAmount: true, isChecking: true)
        case .completed:
            successState()
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
            invoiceDisplay(destination: address, showAmount: false, isChecking: false)
        case .checking(let address):
            invoiceDisplay(destination: address, showAmount: false, isChecking: true)
        case .completed:
            successState()
        case .failed(let message):
            failureState(message)
        }
    }

    @ViewBuilder
    private var applePayContent: some View {
        switch viewModel.applePayState {
        case .idle, .paying:
            amountEntry
        case .completed:
            successState()
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
                    Text("Add money to your TipMe balance over Lightning.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                    TextField("Amount (\(viewModel.currencyCode))", text: $viewModel.amountText)
                        .keyboardType(.decimalPad)
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
                    TextField("Amount (\(viewModel.currencyCode))", text: $viewModel.amountText)
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

    private func invoiceDisplay(destination: String, showAmount: Bool, isChecking: Bool) -> some View {
        VStack(spacing: Theme.spacing) {
            Card {
                VStack(spacing: Theme.spacing) {
                    QRCodeView(content: destination)
                        .frame(width: 220, height: 220)
                        .padding(Theme.spacingSmall)
                        .background(.white, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))

                    if showAmount, let fiat = viewModel.requestedFiat {
                        Text(fiat.formatted)
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

    private func successState() -> some View {
        VStack(spacing: Theme.spacing) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.positive)
            Text("Deposited").font(Theme.title)
            if let fiat = viewModel.requestedFiat {
                Text(fiat.formatted).font(Theme.amountMedium)
            }
            PrimaryButton(title: "Done") { dismiss() }
        }
        .padding(.vertical, 24)
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
