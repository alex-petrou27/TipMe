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
    }
}

/// The one accented, full-width button per screen — Send it, Confirm,
/// Withdraw. There is exactly one of these visible at a time by convention.
struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isLoading: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().tint(Theme.onAccent)
                } else {
                    if let systemImage { Image(systemName: systemImage) }
                    Text(title)
                }
            }
            .font(Theme.headline)
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
        }
        .background(isDisabled ? Theme.textTertiary : Theme.accent, in: Capsule())
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
