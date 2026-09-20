import SwiftUI
import TipMeCore

/// One of the four actions on the home screen — Send, Receive, Withdraw,
/// Activity. Icon-over-label, in a soft rounded tile, deliberately identical
/// in weight to each other so none competes with the balance above them.
///
/// Deliberately **not** a `Button`. Every call site wraps this in a
/// `NavigationLink` (or, in principle, a `Button` of its own) — nesting a
/// `Button` inside another tappable container is a real SwiftUI pitfall: two
/// overlapping tap targets fight for the gesture, and the inner one usually
/// wins in a way that makes the outer navigation silently stop working. This
/// stays a plain view so whatever wraps it owns the only tap target.
struct QuickActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 52, height: 52)
                .background(Theme.surfaceRaised, in: Circle())
            Text(title)
                .font(Theme.caption.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
        }
        // No gesture here, on purpose -- a `DragGesture(minimumDistance: 0)`
        // used to sit on this view via `.simultaneousGesture` to drive a
        // press-scale animation, since this is deliberately not a `Button`
        // (see below) and can't use `ButtonStyle`. On a real device that
        // gesture recognizer can win the touch ahead of the wrapping
        // `NavigationLink`'s own tap recognizer, which made the tap silently
        // do nothing some of the time rather than navigate -- confirmed live
        // as "I tap Deposit and nothing happens." Reliability matters far
        // more here than a press-scale flourish, so this is back to a plain,
        // gesture-free view; only the wrapping `NavigationLink` should ever
        // own this touch.
    }
}

/// The one press feedback for anything that *is* a real `Button` but isn't a
/// `PrimaryButton` -- a settings row, a connect/disconnect action. Purely
/// visual (no haptic baked in: `makeBody` re-runs for reasons other than a
/// tap, so a haptic here would fire on the wrong moments) -- callers still
/// fire `Haptics.tap()` from their own action closure.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.motion, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

/// A small icon badge -- the same rounded-square-icon language Apple's own
/// Settings app uses per row, in the app's own brand color rather than a
/// different system color per row, so a Settings screen built from these
/// reads as TipMe rather than a stock settings list. `tint`/`foreground`
/// exist for the rare row that should read as neutral or destructive
/// (see `Theme.negative`) instead -- most call sites should leave them at
/// the default.
struct IconBadge: View {
    let systemImage: String
    var tint: Color = Theme.brand.opacity(0.14)
    var foreground: Color = Theme.brand
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(tint, in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
    }
}

/// The one full-width call-to-action button per screen — Send it, Confirm,
/// Withdraw. There is exactly one of these visible at a time by convention,
/// in `Theme.brand` (same color as `Theme.accent` now, kept as its own token
/// since a button and a tint color are different concepts even when they
/// currently render identically).
struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isLoading: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            if !isDisabled && !isLoading { Haptics.tap() }
            action()
        } label: {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().tint(Theme.onBrand)
                } else {
                    if let systemImage { Image(systemName: systemImage) }
                    Text(title)
                }
            }
            .font(Theme.headline)
            .foregroundStyle(Theme.onBrand)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
        }
        .background(isDisabled ? Theme.textTertiary : Theme.brand, in: Capsule())
        .buttonStyle(.pressable)
        .disabled(isDisabled || isLoading)
    }
}

/// A flat card — the building block for the balance panel, a quote summary, an
/// activity row group. One consistent container so nothing on screen invents
/// its own corner radius or shadow.
///
/// `@ViewBuilder` has to sit on the `init` parameter, not on the stored
/// property — attaching it to a stored `let` does not make Swift's synthesised
/// memberwise initialiser accept trailing-closure builder syntax, which every
/// call site (`Card { ... }`) throughout this UI relies on.
struct Card<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSmall) {
            content
        }
        .padding(Theme.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

/// Segmented BTC/USDT switcher used on Home, Send and Receive so asset
/// selection always looks and behaves the same way.
struct AssetSwitcher: View {
    @Binding var selection: Asset

    var body: some View {
        HStack(spacing: 4) {
            segment(.bitcoin, label: "Bitcoin")
            segment(.usdt, label: "USDT")
        }
        .padding(4)
        .background(Theme.surfaceRaised, in: Capsule())
    }

    private func segment(_ asset: Asset, label: String) -> some View {
        let isSelected = selection == asset
        return Button {
            selection = asset
        } label: {
            Text(label)
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Theme.onAccent : Theme.textSecondary)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(isSelected ? Theme.accent : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A single row in the activity feed — direction arrow, counterparty or note,
/// amount right-aligned with the sign implied by color rather than a literal
/// "+"/"-" prefix cluttering the number.
struct ActivityRow: View {
    let transaction: WalletTransaction

    var body: some View {
        HStack(spacing: Theme.spacingSmall) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 34, height: 34)
                .background(Theme.surfaceRaised, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.body.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text((transaction.isOutgoing ? "-" : "+") + transaction.amount.formatted)
                    .font(Theme.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(transaction.isOutgoing ? Theme.textPrimary : Theme.positive)
                if transaction.status != .completed {
                    Text(transaction.status == .pending ? "Pending" : "Failed")
                        .font(Theme.caption)
                        .foregroundStyle(transaction.status == .failed ? Theme.negative : Theme.warning)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var icon: String {
        switch transaction.kind {
        case .tipSent: return "heart.fill"
        case .send: return "arrow.up"
        case .receive: return "arrow.down"
        case .withdrawal: return "building.columns.fill"
        }
    }

    private var title: String {
        switch transaction.kind {
        case .tipSent: return transaction.counterparty.map { "Tipped \($0)" } ?? "Tip sent"
        case .send: return transaction.counterparty ?? "Sent"
        case .receive: return transaction.counterparty ?? "Received"
        case .withdrawal: return "Bank withdrawal"
        }
    }

    private var subtitle: String {
        transaction.note ?? transaction.timestamp.formatted(date: .abbreviated, time: .shortened)
    }
}
