import SwiftUI
import TipMeCore

enum DepositMethodChoice: String, CaseIterable {
    case lightning
    case onchain

    var label: String {
        switch self {
        case .lightning: return "Lightning"
        case .onchain: return "On-chain"
        }
    }
}

@MainActor
final class DepositViewModel: ObservableObject {
    @Published var method: DepositMethodChoice = .lightning
    @Published var amountText = ""
    @Published private(set) var lightningState: LightningDepositState = .idle
    @Published private(set) var onchainState: OnChainDepositState = .idle
    @Published private(set) var copied = false

    private let lightningFlow: LightningDepositFlow
    private let onchainFlow: OnChainDepositFlow

    init(services: TipMeServices) {
        self.lightningFlow = services.makeLightningDepositFlow()
        self.onchainFlow = services.makeOnChainDepositFlow()
    }

    var isBusy: Bool {
        switch method {
        case .lightning: return lightningState == .creating
        case .onchain: return onchainState == .creating
        }
    }

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
                }
            }

            PrimaryButton(title: viewModel.method == .lightning ? "Create invoice" : "Get address",
                         isLoading: viewModel.isBusy) {
                Task { await viewModel.create() }
            }
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

    private func successState(_ balances: [Asset: Int64]) -> some View {
        VStack(spacing: Theme.spacing) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.positive)
            Text("Deposited").font(Theme.title)
            if let sats = balances[.bitcoin] {
                Text(TipMeCore.Amount.sats(sats).formatted).font(Theme.amountMedium)
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
