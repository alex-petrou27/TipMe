import SwiftUI
import TipMeCore

@MainActor
final class SendViewModel: ObservableObject {
    @Published var destinationText = ""
    @Published var amountText = ""
    @Published private(set) var state: WalletSendState = .idle
    @Published private(set) var sentFiat: FiatAmount?

    let currencyCode: String
    private let services: TipMeServices
    private let flow: WalletSendFlow

    init(services: TipMeServices) {
        self.services = services
        self.currencyCode = services.currencyCode
        self.flow = services.makeWalletSendFlow()
    }

    func resolveDestination() async {
        guard !destinationText.isEmpty else { return }
        state = .resolving
        state = await flow.identify(pasted: destinationText)
    }

    func requestQuote() async {
        guard case .destinationFound(let destination) = state else { return }

        let amount: Amount
        if case .lightningInvoice(_, let amountSat?, _) = destination {
            amount = .sats(amountSat)
        } else {
            guard let fiat = FiatAmount(parsing: amountText, currencyCode: currencyCode) else {
                state = .failed("Enter an amount.")
                return
            }
            // Bitcoin unless the destination is specifically a USDT address:
            // the person picks how much money to send, not which coin.
            var asset = Asset.bitcoin
            if case .liquidAddress(_, let hint?) = destination { asset = hint }
            guard let converted = try? await services.assetAmount(for: fiat, in: asset),
                  converted.minorUnits > 0 else {
                state = .failed("Couldn't get today's exchange rate. Try again in a moment.")
                return
            }
            amount = converted
        }
        state = await flow.quote(amount: amount, for: destination)
    }

    func confirm() async {
        guard case .quoted(let destination, let amount, let route, let fiat) = state else { return }
        sentFiat = fiat
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
                TextField("Amount (\(viewModel.currencyCode))", text: $viewModel.amountText)
                    .keyboardType(.decimalPad)
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
            if let fiat = viewModel.sentFiat {
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
