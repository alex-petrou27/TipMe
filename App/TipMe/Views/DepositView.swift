import SwiftUI
import TipMeCore

@MainActor
final class DepositViewModel: ObservableObject {
    @Published var amountText = ""
    @Published private(set) var state: LightningDepositState = .idle
    @Published private(set) var copied = false

    private let flow: LightningDepositFlow

    init(services: TipMeServices) {
        self.flow = services.makeLightningDepositFlow()
    }

    func create() async {
        guard let amountSats = Int64(amountText.filter(\.isNumber)), amountSats > 0 else {
            state = .failed("Enter an amount.")
            return
        }
        state = .creating
        state = await flow.create(amountSats: amountSats)
    }

    func checkStatus() async {
        guard case .awaitingPayment(let paymentRequest, let paymentHash, let amountSats) = state else { return }
        state = .checking(paymentRequest: paymentRequest, paymentHash: paymentHash, amountSats: amountSats)
        state = await flow.checkStatus(paymentHash: paymentHash, paymentRequest: paymentRequest, amountSats: amountSats)
    }

    func copy(_ paymentRequest: String) {
        UIPasteboard.general.string = paymentRequest
        copied = true
    }

    func reset() {
        amountText = ""
        copied = false
        state = .idle
    }
}

/// Adds real funds to the custodial balance over Lightning: create an
/// invoice via the registry, let the human pay it from any wallet, then poll
/// for settlement. Unlike a self-custodial receive, TipMe holds the money
/// once this completes -- see `LightningDepositFlow`.
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
        switch viewModel.state {
        case .idle, .creating:
            amountEntry

        case .awaitingPayment(let paymentRequest, _, let amountSats):
            invoiceDisplay(paymentRequest: paymentRequest, amountSats: amountSats, isChecking: false)

        case .checking(let paymentRequest, _, let amountSats):
            invoiceDisplay(paymentRequest: paymentRequest, amountSats: amountSats, isChecking: true)

        case .completed(let balances):
            successState(balances)

        case .failed(let message):
            failureState(message)
        }
    }

    private var amountEntry: some View {
        VStack(spacing: Theme.spacing) {
            Card {
                Text("Add real sats to your TipMe balance over Lightning.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                TextField("Amount (sats)", text: $viewModel.amountText)
                    .keyboardType(.numberPad)
                    .font(Theme.amountLarge)
                    .multilineTextAlignment(.center)
            }

            PrimaryButton(title: "Create invoice", isLoading: viewModel.state == .creating) {
                Task { await viewModel.create() }
            }
        }
    }

    private func invoiceDisplay(paymentRequest: String, amountSats: Int64, isChecking: Bool) -> some View {
        VStack(spacing: Theme.spacing) {
            Card {
                VStack(spacing: Theme.spacing) {
                    QRCodeView(content: paymentRequest)
                        .frame(width: 220, height: 220)
                        .padding(Theme.spacingSmall)
                        .background(.white, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))

                    Text(TipMeCore.Amount.sats(amountSats).formatted)
                        .font(Theme.amountMedium)

                    Text(paymentRequest)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    PrimaryButton(title: viewModel.copied ? "Copied" : "Copy invoice",
                                 systemImage: viewModel.copied ? "checkmark" : "doc.on.doc") {
                        viewModel.copy(paymentRequest)
                    }
                }
            }

            PrimaryButton(title: "I've paid — check now", isLoading: isChecking) {
                Task { await viewModel.checkStatus() }
            }

            Text("Pay this invoice from any Lightning wallet. TipMe holds the funds once it settles.")
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
