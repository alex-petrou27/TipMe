import SwiftUI
import TipMeCore

@MainActor
final class WithdrawViewModel: ObservableObject {
    @Published var amountText = ""
    // Same reasoning as SendViewModel's default: Apple Pay's top-up (the
    // only funding path in this build) only ever credits USDT.
    @Published var selectedAsset: Asset = .usdt
    @Published private(set) var state: WithdrawalState = .checkingAvailability

    private let flow: WithdrawalFlow

    init(services: TipMeServices) {
        self.flow = services.makeWithdrawalFlow()
    }

    func start() async { state = await flow.start() }
    func linkAccount() async { state = await flow.linkAccount() }

    func requestQuote(account: BankAccount) async {
        guard let minorUnits = Int64(amountText.filter(\.isNumber)), minorUnits > 0 else { return }
        state = await flow.quote(amount: Amount(asset: selectedAsset, minorUnits: minorUnits), account: account)
    }

    func confirm(quote: WithdrawalQuote, account: BankAccount) async {
        state = .submitting
        state = await flow.confirmAndWithdraw(quote: quote, account: account)
    }
}

/// Withdraw to a bank account.
///
/// This is the one screen in the app that cannot be made to actually move
/// money by writing more Swift. Every state below is real and reachable; what
/// is missing is a licensed banking partner behind `FiatOffRampProvider`. See
/// docs/BANKING.md. The screen tells the truth about that rather than faking
/// a success state, because a wallet app lying about a bank transfer is a
/// far worse outcome than a wallet app saying "not yet."
struct WithdrawView: View {
    @StateObject private var viewModel: WithdrawViewModel

    init(services: TipMeServices) {
        _viewModel = StateObject(wrappedValue: WithdrawViewModel(services: services))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                content
            }
            .padding(Theme.spacing)
        }
        .background(Theme.background)
        .navigationTitle("Withdraw")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.start() }
        .animation(Theme.motion, value: String(describing: viewModel.state))
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .checkingAvailability:
            ProgressView().padding(.vertical, 40)

        case .unavailable(let reason):
            unavailableState(reason)

        case .noBankLinked:
            noBankLinkedState

        case .ready(let account):
            amountEntry(account)

        case .quoted(let quote, let account):
            confirmation(quote: quote, account: account)

        case .submitting:
            VStack(spacing: Theme.spacing) {
                ProgressView()
                Text("Submitting…").foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, 40)

        case .succeeded(let receipt):
            successState(receipt)

        case .failed(let message):
            VStack(spacing: Theme.spacing) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text(message).multilineTextAlignment(.center)
                PrimaryButton(title: "Back") { Task { await viewModel.start() } }
            }
        }
    }

    private func unavailableState(_ reason: String) -> some View {
        VStack(spacing: Theme.spacing) {
            Image(systemName: "building.columns")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textTertiary)
            Text("Bank withdrawals aren't available yet")
                .font(Theme.headline)
            Text(reason)
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Text("Your Bitcoin and USDT are still yours — send them to any wallet or exchange that supports off-ramping in the meantime.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 24)
    }

    private var noBankLinkedState: some View {
        VStack(spacing: Theme.spacing) {
            Image(systemName: "building.columns")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accent)
            Text("Link a bank account to withdraw").font(Theme.headline)
            PrimaryButton(title: "Link bank account", systemImage: "plus") {
                Task { await viewModel.linkAccount() }
            }
        }
        .padding(.vertical, 24)
    }

    private func amountEntry(_ account: BankAccount) -> some View {
        VStack(spacing: Theme.spacing) {
            Card {
                HStack(spacing: 12) {
                    IconBadge(systemImage: "building.columns.fill")
                    Text(account.displayName)
                        .font(Theme.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            AssetSwitcher(selection: $viewModel.selectedAsset)
            TextField("Amount", text: $viewModel.amountText)
                .keyboardType(.numberPad)
                .font(Theme.amountLarge)
                .multilineTextAlignment(.center)
            PrimaryButton(title: "Review") {
                Task { await viewModel.requestQuote(account: account) }
            }
        }
    }

    private func confirmation(quote: WithdrawalQuote, account: BankAccount) -> some View {
        VStack(spacing: Theme.spacing) {
            Card {
                VStack(alignment: .leading, spacing: Theme.spacingSmall) {
                    row("You send", quote.debited.formatted)
                    row("Fee", quote.feeFiat.formatted)
                    Divider()
                    row("Arrives as", quote.fiatCredited.formatted, emphasised: true)
                    row("To", account.displayName)
                }
            }
            PrimaryButton(title: "Confirm with Face ID", systemImage: "faceid") {
                Task { await viewModel.confirm(quote: quote, account: account) }
            }
        }
    }

    private func successState(_ receipt: WithdrawalReceipt) -> some View {
        VStack(spacing: Theme.spacing) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.positive)
            Text("Withdrawal submitted").font(Theme.title)
            Text(receipt.fiatCredited.formatted).font(Theme.amountMedium)
            Text("To \(receipt.bankAccount.displayName)")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 24)
    }

    private func row(_ label: String, _ value: String, emphasised: Bool = false) -> some View {
        HStack {
            Text(label).font(Theme.body).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(emphasised ? Theme.body.weight(.bold) : Theme.body.weight(.medium))
        }
    }
}
