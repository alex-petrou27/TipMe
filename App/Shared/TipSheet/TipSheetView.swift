import SwiftUI
import TipMeCore

/// The sheet the user sees over their feed.
///
/// Designed for the two-second interaction the product promises: a recognisable
/// creator, four preset amounts, one confirm. Everything else — asset switching,
/// custom amounts, manual addresses — is present but out of the primary path.
struct TipSheetView: View {
    @ObservedObject var viewModel: TipSheetViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            card
        }
        .background(Color.black.opacity(0.25).ignoresSafeArea())
        .animation(.snappy, value: String(describing: viewModel.screen))
    }

    private var card: some View {
        VStack(spacing: 20) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            content
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.screen {
        case .loading(let message):
            loading(message)
        case .amount(let creator):
            amountPicker(creator)
        case .manualEntry(let reason, _):
            manualEntry(reason)
        case .confirm(let creator, let quote):
            confirmation(creator, quote)
        case .paying:
            loading("Sending…")
        case .receipt(let result, let creator):
            receipt(result, creator)
        case .error(let message):
            errorState(message)
        }
    }

    // MARK: - Screens

    private func loading(_ message: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(message).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 28)
    }

    private func amountPicker(_ creator: CreatorRecord) -> some View {
        VStack(spacing: 16) {
            creatorHeader(creator)

            if !creator.verified {
                // An unverified record means someone registered this handle but
                // has not proved they own it. Saying so is the difference
                // between a tip and a redirect.
                Label("This handle hasn't been verified yet.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(viewModel.presets, id: \.self) { amount in
                    Button {
                        Task { await viewModel.selectAmount(amount) }
                    } label: {
                        Text(amount.formatted)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 8) {
                TextField("Other amount", text: $viewModel.customAmountText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                Button("Tip") { Task { await viewModel.selectCustomAmount() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.customAmountText.isEmpty)
            }

            Picker("Pay with", selection: Binding(
                get: { viewModel.selectedAsset },
                set: { viewModel.changeAsset($0) })) {
                    Text("Bitcoin").tag(Asset.bitcoin)
                    Text("USDT").tag(Asset.usdt)
                }
                .pickerStyle(.segmented)

            cancelButton
        }
    }

    private func manualEntry(_ reason: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "questionmark.circle")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(reason)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            TextField("name@wallet.com", text: $viewModel.manualAddress)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)

            Button("Continue") { Task { await viewModel.submitManualAddress() } }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(viewModel.manualAddress.isEmpty)

            cancelButton
        }
    }

    /// The disclosure screen. Every number here comes from the same `TipQuote`
    /// the engine spends from, so what is shown and what is charged cannot
    /// drift apart.
    private func confirmation(_ creator: CreatorRecord, _ quote: TipQuote) -> some View {
        VStack(spacing: 16) {
            creatorHeader(creator)

            VStack(spacing: 8) {
                row("They receive", quote.creatorReceives.formatted, emphasised: true)
                row("Tip", quote.fiatTip.formatted)
                if quote.hasFee {
                    row("TipMe fee (\(quote.feePolicy.percentageDescription))", quote.fiatFee.formatted)
                }
                if let conversion = quote.conversionDisclosure {
                    row("Conversion", conversion)
                }
                Divider()
                row("You pay", quote.fiatTotal.formatted, emphasised: true)
            }
            .padding(14)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))

            Button {
                Task { await viewModel.confirm() }
            } label: {
                Label("Confirm with Face ID", systemImage: "faceid")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)

            Button("Change amount") { viewModel.backToAmount() }
                .font(.footnote)
        }
    }

    private func receipt(_ result: TipResult, _ creator: CreatorRecord) -> some View {
        VStack(spacing: 14) {
            Image(systemName: result.tipReceipt.status == .succeeded ? "checkmark.circle.fill" : "clock.fill")
                .font(.system(size: 44))
                .foregroundStyle(result.tipReceipt.status == .succeeded ? .green : .orange)

            Text(result.tipReceipt.status == .succeeded
                 ? "Sent to \(creator.handle.displayName)"
                 : "On its way to \(creator.handle.displayName)")
                .font(.headline)

            Text(result.tipReceipt.sentAmount.formatted)
                .font(.title3.weight(.semibold))

            // Our failure to collect a fee is not the user's problem and is not
            // presented as an error. It is recorded in the audit log.
            if result.feeCollectionFailed != nil {
                Text("Your tip went through in full.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Done") { viewModel.dismiss() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
            Button("Close") { viewModel.dismiss() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Pieces

    private func creatorHeader(_ creator: CreatorRecord) -> some View {
        VStack(spacing: 4) {
            Text(creator.handle.displayName)
                .font(.title3.weight(.semibold))
            Text("on \(creator.handle.platform.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ label: String, _ value: String, emphasised: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(emphasised ? .callout.weight(.semibold) : .callout)
                .foregroundStyle(emphasised ? .primary : .secondary)
            Spacer()
            Text(value)
                .font(emphasised ? .callout.weight(.semibold) : .callout)
                .monospacedDigit()
        }
    }

    private var cancelButton: some View {
        Button("Cancel") { viewModel.dismiss() }
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
