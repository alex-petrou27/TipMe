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
                ForEach(viewModel.presets, id: \.self) { amount in
                    PresetAmountButton(title: amount.formatted) {
                        Haptics.tap()
                        Task { await viewModel.selectAmount(amount) }
                    }
                }
            }

            HStack(spacing: 10) {
                TextField("Other amount", text: $viewModel.customAmountText)
                    .keyboardType(.numberPad)
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

            AssetSwitcher(selection: Binding(
                get: { viewModel.selectedAsset },
                set: { viewModel.changeAsset($0) }))

            cancelButton
        }
    }

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
                row("They receive", quote.creatorReceives.formatted, emphasised: true)
                if quote.hasFee {
                    row("TipMe fee (\(quote.feePolicy.percentageDescription))", quote.fiatFee.formatted)
                }
                if let conversion = quote.conversionDisclosure {
                    row("Conversion", conversion)
                }
            }

            PrimaryButton(title: "Confirm with Face ID", systemImage: "faceid") {
                Haptics.confirm()
                Task { await viewModel.confirm() }
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

            Text(result.tipReceipt.sentAmount.formatted)
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

/// One preset amount tile. A plain tap target rather than `.buttonStyle`, so
/// the press animation (a slight scale-down) can be tuned to feel snappy
/// without fighting a system button style for the same property.
private struct PresetAmountButton: View {
    let title: String
    let action: () -> Void
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.headline.monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(pressed ? 0.96 : 1)
        .animation(.easeOut(duration: 0.12), value: pressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
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
