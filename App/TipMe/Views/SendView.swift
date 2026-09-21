import SwiftUI
import TipMeCore

@MainActor
final class SendViewModel: ObservableObject {
    @Published var destinationText = ""
    @Published var amountText = ""
    // USDT, not bitcoin: the only funding path in this build is Apple Pay's
    // top-up, which only ever credits USDT (no Lightning node is configured
    // to actually acquire sats) -- defaulting to bitcoin here silently set
    // every send up to fail with "insufficient funds" for a balance there
    // was never a way to hold in the first place. Same reasoning as
    // register()'s own default on the registry side.
    @Published var selectedAsset: Asset = .usdt
    @Published private(set) var state: WalletSendState = .idle

    private let flow: WalletSendFlow

    init(services: TipMeServices) {
        self.flow = services.makeWalletSendFlow()
    }

    func resolveDestination() async {
        guard !destinationText.isEmpty else { return }
        state = .resolving
        state = await flow.identify(pasted: destinationText)
    }

    func requestQuote() async {
        guard case .destinationFound(let destination) = state else { return }
        guard let minorUnits = Int64(amountText.filter(\.isNumber)), minorUnits > 0 else {
            state = .failed("Enter an amount.")
            return
        }
        let amount = Amount(asset: selectedAsset, minorUnits: minorUnits)
        state = await flow.quote(amount: amount, for: destination)
    }

    func confirm() async {
        guard case .quoted(let destination, let amount, let route, let fiat) = state else { return }
        state = .sending
        state = await flow.confirmAndSend(destination: destination, amount: amount,
                                          route: route, fiatAmount: fiat)
    }

    func reset() {
        destinationText = ""
        amountText = ""
        state = .idle
    }
}

/// Send to anything: a Lightning invoice, an on-chain Bitcoin address, a
/// Liquid address, or a Lightning address. The general-purpose sibling of the
/// tip-sending flow in the share extension — same biometric gate, same
/// two-step price-then-confirm shape, wider set of destinations.
struct SendView: View {
    @StateObject private var viewModel: SendViewModel
    @Environment(\.dismiss) private var dismiss

    init(services: TipMeServices) {
        _viewModel = StateObject(wrappedValue: SendViewModel(services: services))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                content
            }
            .padding(Theme.spacing)
        }
        .background(Theme.background)
        .navigationTitle("Send")
        .navigationBarTitleDisplayMode(.inline)
        .animation(Theme.motion, value: String(describing: viewModel.state))
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .unrecognised, .resolving:
            destinationEntry

        case .destinationFound(let destination):
            amountEntry(destination)

        case .quoted(let destination, let amount, _, let fiat):
            confirmation(destination: destination, amount: amount, fiat: fiat)

        case .sending:
            VStack(spacing: Theme.spacing) {
                ProgressView()
                Text("Sending…").font(Theme.body).foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, 40)

        case .succeeded(let result):
            successState(result)

        case .failed(let message):
            failureState(message)
        }
    }

    private var destinationEntry: some View {
        VStack(spacing: Theme.spacing) {
            Card {
                Text("Paste a Lightning invoice, a Bitcoin address, a Liquid address, or a Lightning address.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                TextField("Paste or type a destination", text: $viewModel.destinationText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Theme.body.monospaced())
            }

            if case .unrecognised(let reason) = viewModel.state {
                Text(reason).font(Theme.caption).foregroundStyle(Theme.negative)
            }
            if case .resolving = viewModel.state {
                ProgressView()
            }

            PrimaryButton(title: "Continue", isDisabled: viewModel.destinationText.isEmpty) {
                Task { await viewModel.resolveDestination() }
            }
        }
    }

    private func amountEntry(_ destination: WalletDestination) -> some View {
        VStack(spacing: Theme.spacing) {
            Card {
                HStack(spacing: 12) {
                    IconBadge(systemImage: "arrow.up.right")
                    Text(destination.displaySummary)
                        .font(Theme.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                }
            }

            if !destination.requiresManualAmount {
                Text("This invoice already specifies an amount.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                AssetSwitcher(selection: $viewModel.selectedAsset)
                TextField("Amount", text: $viewModel.amountText)
                    .keyboardType(.numberPad)
                    .font(Theme.amountLarge)
                    .multilineTextAlignment(.center)
            }

            PrimaryButton(title: "Review") {
                Task { await viewModel.requestQuote() }
            }
        }
    }

    private func confirmation(destination: WalletDestination, amount: Amount, fiat: FiatAmount) -> some View {
        VStack(spacing: Theme.spacing) {
            Card {
                VStack(alignment: .leading, spacing: Theme.spacingSmall) {
                    row("Sending", amount.formatted)
                    row("To", destination.displaySummary)
                    Divider()
                    row("Total", fiat.formatted, emphasised: true)
                }
            }

            PrimaryButton(title: "Confirm with Face ID", systemImage: "faceid") {
                Task { await viewModel.confirm() }
            }

            Button("Cancel") { viewModel.reset() }
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func successState(_ result: WalletSendResult) -> some View {
        VStack(spacing: Theme.spacing) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.positive)
            Text("Sent").font(Theme.title)
            Text(result.receipt.sentAmount.formatted).font(Theme.amountMedium)
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

    private func row(_ label: String, _ value: String, emphasised: Bool = false) -> some View {
        HStack {
            Text(label).font(Theme.body).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(emphasised ? Theme.body.weight(.bold) : Theme.body.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
        }
    }
}
