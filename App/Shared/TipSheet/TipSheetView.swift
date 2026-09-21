import SwiftUI
import TipMeCore

/// The sheet the user sees over their feed.
///
/// Designed for the two-second interaction the product promises: a recognisable
/// creator, four preset amounts, one confirm. Everything else — asset switching,
/// custom amounts, manual addresses — is present but out of the primary path.
///
/// Drawn entirely from `Theme`/the shared components, not raw SwiftUI defaults
/// — this is the one screen a new user judges the whole product by, so it
/// reads as the same product as the rest of the app, not a system sheet with
/// TipMe's words in it.
struct TipSheetView: View {
    @ObservedObject var viewModel: TipSheetViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            card
        }
        .background(Color.black.opacity(0.32).ignoresSafeArea())
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: String(describing: viewModel.screen))
    }

    private var card: some View {
        VStack(spacing: 22) {
            Capsule()
                .fill(Theme.textTertiary)
                .frame(width: 36, height: 5)
                .padding(.top, 10)

            content
                .frame(maxWidth: .infinity)
        }
        .padding(22)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
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
        case .manualEntry(let reason):
            manualEntry(reason)
        case .confirm(let creator, let quote):
            confirmation(creator, quote)
        case .paying:
            loading("Sending…")
        case .receipt(let result, let creator):
            receipt(result, creator)
        case .pendingAmount(let handle):
            pendingAmountPicker(handle)
        case .pendingConfirm(let handle, let amount, let fiat):
            pendingConfirmation(handle, amount, fiat)
        case .pendingReceipt(let handle, let amount):
            pendingReceiptView(handle, amount)
        case .error(let message):
            errorState(message)
        }
    }

    // MARK: - Screens

    private func loading(_ message: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(Theme.brand)
            Text(message)
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 36)
    }

    private func amountPicker(_ creator: CreatorRecord) -> some View {
        VStack(spacing: 20) {
            creatorHeader(creator)

            if !creator.verified {
                // An unverified record means someone registered this handle but
                // has not proved they own it. Saying so is the difference
                // between a tip and a redirect.
                Label("This handle hasn't been verified yet.", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.warning)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(viewModel.presets, id: \.self) { fiat in
                    PresetAmountButton(title: fiat.formatted) {
                        Haptics.tap()
                        Task { await viewModel.selectAmount(fiat) }
                    }
                }
            }

            HStack(spacing: 10) {
                TextField("Other amount", text: $viewModel.customAmountText)
                    .keyboardType(.decimalPad)
                    .font(Theme.headline)
                    .padding(.vertical, 13)
                    .padding(.horizontal, 16)
                    .background(Theme.surfaceRaised, in: Capsule())

                Button {
                    Haptics.tap()
                    Task { await viewModel.selectCustomAmount() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.onBrand)
                        .frame(width: 46, height: 46)
                        .background(
                            viewModel.customAmountText.isEmpty ? Theme.textTertiary : Theme.brand, in: Circle())
                }
                .disabled(viewModel.customAmountText.isEmpty)
            }

            cancelButton
        }
    }

    /// Reached only when the share itself couldn't be identified at all (a
    /// news article, an unrecognised link) -- there genuinely is no handle
    /// to look up, so a manual address is the only way forward. A share
    /// that *did* name a handle but found nobody registered goes to
    /// `pendingAmountPicker` instead, never here -- see `TipFlowState
    /// .creatorNotRegistered`.
    private func manualEntry(_ reason: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textTertiary)
            Text(reason)
                .font(Theme.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)

            TextField("name@wallet.com", text: $viewModel.manualAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .font(Theme.body)
                .padding(.vertical, 13)
                .padding(.horizontal, 16)
                .background(Theme.surfaceRaised, in: Capsule())

            PrimaryButton(title: "Continue", isDisabled: viewModel.manualAddress.isEmpty) {
                Task { await viewModel.submitManualAddress() }
            }

            cancelButton
        }
    }

    /// A handle nobody has claimed on TipMe yet. The tip still sends right
    /// now -- it sits in escrow against this exact handle until whoever
    /// owns it proves it and claims it (see `PendingTipFlow`) -- so this
    /// looks like the ordinary amount picker, not a dead end.
    private func pendingAmountPicker(_ handle: CreatorHandle) -> some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                IconBadge(systemImage: "clock.fill", size: 72)
                Text(handle.displayName)
                    .font(Theme.title)
                    .foregroundStyle(Theme.textPrimary)
                Text("Hasn't set up TipMe yet — this will be waiting for them the moment they do.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(viewModel.presets, id: \.self) { fiat in
                    PresetAmountButton(title: fiat.formatted) {
                        Haptics.tap()
                        Task { await viewModel.selectPendingAmount(fiat) }
                    }
                }
            }

            HStack(spacing: 10) {
                TextField("Other amount", text: $viewModel.customAmountText)
                    .keyboardType(.decimalPad)
                    .font(Theme.headline)
                    .padding(.vertical, 13)
                    .padding(.horizontal, 16)
                    .background(Theme.surfaceRaised, in: Capsule())

                Button {
                    Haptics.tap()
                    Task { await viewModel.selectPendingCustomAmount() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.onBrand)
                        .frame(width: 46, height: 46)
                        .background(
                            viewModel.customAmountText.isEmpty ? Theme.textTertiary : Theme.brand, in: Circle())
                }
                .disabled(viewModel.customAmountText.isEmpty)
            }

            cancelButton
        }
    }

    private func pendingConfirmation(_ handle: CreatorHandle, _ amount: Amount, _ fiat: FiatAmount) -> some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                IconBadge(systemImage: "clock.fill", size: 72)
                Text(handle.displayName)
                    .font(Theme.title)
                    .foregroundStyle(Theme.textPrimary)
            }

            VStack(spacing: 4) {
                Text("You send")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text(fiat.formatted)
                    .font(Theme.amountLarge)
                    .foregroundStyle(Theme.textPrimary)
            }

            Card {
                Text("Held for \(handle.displayName) until they set up TipMe. You can take it back any time before then.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            TextField("Leave a message (optional)", text: $viewModel.pendingNoteText, axis: .vertical)
                .font(Theme.body)
                .padding(.vertical, 13)
                .padding(.horizontal, 16)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous))
                .lineLimit(1...3)

            PrimaryButton(title: "Confirm with Face ID", systemImage: "faceid") {
                Haptics.confirm()
                Task { await viewModel.confirmPendingTip() }
            }

            Button("Change amount") { viewModel.backToPendingAmount() }
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func pendingReceiptView(_ handle: CreatorHandle, _ amount: Amount) -> some View {
        VStack(spacing: 16) {
            SuccessBadge(size: 72)

            Text("On its way to \(handle.displayName)")
                .font(Theme.headline)
                .foregroundStyle(Theme.textPrimary)

            Text(viewModel.sentFiat?.formatted ?? amount.formatted)
                .font(Theme.amountMedium)
                .foregroundStyle(Theme.brand)

            Text("They'll get it the moment they set up TipMe.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            PrimaryButton(title: "Done") { viewModel.dismiss() }
        }
        .padding(.vertical, 4)
    }

    /// The disclosure screen. Every number here comes from the same `TipQuote`
    /// the engine spends from, so what is shown and what is charged cannot
    /// drift apart. "You pay" is the hero number — everything else is
    /// context underneath it, not a list of equals.
    private func confirmation(_ creator: CreatorRecord, _ quote: TipQuote) -> some View {
        VStack(spacing: 20) {
            creatorHeader(creator)

            VStack(spacing: 4) {
                Text("You pay")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text(quote.fiatTotal.formatted)
                    .font(Theme.amountLarge)
                    .foregroundStyle(Theme.textPrimary)
            }

            Card {
                if quote.hasFee {
                    row("TipMe fee (\(quote.feePolicy.percentageDescription))", "-" + quote.fiatFee.formatted)
                }
                row("They receive", quote.fiatTip.formatted, emphasised: true)
            }

            if viewModel.needsApplePayTopUp, let shortfall = viewModel.applePayShortfall {
                VStack(spacing: 12) {
                    Text("Add \(shortfall.formatted) to send this")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                    PrimaryButton(title: "Pay with Apple Pay", systemImage: "apple.logo",
                                 isLoading: viewModel.isFundingWithApplePay) {
                        Task { await viewModel.payShortfallWithApplePayThenConfirm() }
                    }
                }
            } else {
                PrimaryButton(title: "Confirm with Face ID", systemImage: "faceid") {
                    Haptics.confirm()
                    Task { await viewModel.confirm() }
                }
            }

            Button("Change amount") { viewModel.backToAmount() }
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func receipt(_ result: TipResult, _ creator: CreatorRecord) -> some View {
        let succeeded = result.tipReceipt.status == .succeeded
        return VStack(spacing: 16) {
            if succeeded {
                SuccessBadge(size: 72)
            } else {
                Image(systemName: "clock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.warning)
            }

            Text(succeeded ? "Sent to \(creator.handle.displayName)" : "On its way to \(creator.handle.displayName)")
                .font(Theme.headline)
                .foregroundStyle(Theme.textPrimary)

            Text(viewModel.sentFiat?.formatted ?? result.tipReceipt.sentAmount.formatted)
                .font(Theme.amountMedium)
                .foregroundStyle(succeeded ? Theme.brand : Theme.textPrimary)

            // Our failure to collect a fee is not the user's problem and is not
            // presented as an error. It is recorded in the audit log.
            if result.feeCollectionFailed != nil {
                Text("Your tip went through in full.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            PrimaryButton(title: "Done") { viewModel.dismiss() }
        }
        .padding(.vertical, 4)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Theme.negative)
            Text(message)
                .font(Theme.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textPrimary)
            PrimaryButton(title: "Close") { viewModel.dismiss() }
        }
        .onAppear { Haptics.error() }
    }

    // MARK: - Pieces

    private func creatorHeader(_ creator: CreatorRecord) -> some View {
        VStack(spacing: 10) {
            CreatorAvatarView(url: creator.photoURL, initials: creator.handle.username)
                .frame(width: 72, height: 72)

            Text(creator.displayName ?? creator.handle.displayName)
                .font(Theme.title)
                .foregroundStyle(Theme.textPrimary)
            Text("\(creator.handle.displayName) on \(creator.handle.platform.displayName)")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func row(_ label: String, _ value: String, emphasised: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(emphasised ? Theme.body.weight(.semibold) : Theme.caption)
                .foregroundStyle(emphasised ? Theme.textPrimary : Theme.textSecondary)
            Spacer()
            Text(value)
                .font((emphasised ? Theme.body.weight(.semibold) : Theme.caption).monospacedDigit())
                .foregroundStyle(emphasised ? Theme.textPrimary : Theme.textSecondary)
        }
    }

    private var cancelButton: some View {
        Button("Cancel") { viewModel.dismiss() }
            .font(Theme.caption)
            .foregroundStyle(Theme.textSecondary)
    }
}

/// One preset amount tile. `.pressable` -- the same tap feedback used
/// everywhere else in the app now, not a one-off tuned just for this tile.
private struct PresetAmountButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.headline.monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous))
        }
        .buttonStyle(.pressable)
    }
}

/// The one animated moment in the product: a landed tip. Springs in, then
/// draws its checkmark a beat later, paired with a single success haptic —
/// the entire "delight" budget for this screen spent on the one instant
/// that has actually earned it.
private struct SuccessBadge: View {
    let size: CGFloat
    @State private var scale: CGFloat = 0.55
    @State private var opacity: Double = 0
    @State private var checkTrim: CGFloat = 0

    var body: some View {
        ZStack {
            Circle().fill(Theme.brand)
            CheckmarkShape()
                .trim(from: 0, to: checkTrim)
                .stroke(Theme.onBrand, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round, lineJoin: .round))
                .padding(size * 0.28)
        }
        .frame(width: size, height: size)
        .scaleEffect(scale)
        .opacity(opacity)
        .onAppear {
            Haptics.success()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.62)) {
                scale = 1
                opacity = 1
            }
            withAnimation(.easeOut(duration: 0.35).delay(0.18)) {
                checkTrim = 1
            }
        }
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
        return path
    }
}

/// The confirm screen's face for a creator: their real photo when they've set
/// one, a plain initial otherwise. Never blocks the flow on a slow or failed
/// image load — the fallback renders instantly and the photo is purely
/// cosmetic, not a trust signal (that's what `verified` is for).
private struct CreatorAvatarView: View {
    let url: URL?
    let initials: String

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .clipShape(Circle())
    }

    private var placeholder: some View {
        Circle()
            .fill(Theme.surfaceRaised)
            .overlay {
                Text(initials.prefix(1).uppercased())
                    .font(Theme.title)
                    .foregroundStyle(Theme.textSecondary)
            }
    }
}
