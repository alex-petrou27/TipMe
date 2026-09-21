import SwiftUI

/// A walkthrough of moving TipMe into the share sheet's main "Favorites" row.
///
/// Purely instructional: iOS offers no API to move an app there, to detect
/// whether the user has, or to open the share sheet's "More > Edit" screen, so
/// the user always does this themselves. The illustrations are drawn here in
/// SwiftUI as simplified stand-ins for the real screens -- they show *where to
/// look*, not a pixel copy of iOS.
///
/// One content view, two homes: the onboarding step embeds `ShareSheetGuide`
/// directly, and Settings pushes `ShareSheetGuideScreen`.
struct ShareSheetGuide: View {
    @State private var page = 0

    fileprivate struct Step {
        let title: String
        let detail: String
        let scene: ShareSheetMock.Scene
    }

    private static let steps: [Step] = [
        Step(title: "Open any app with a Share button",
             detail: "Photos works, or Instagram itself.",
             scene: .app(highlightShare: false)),
        Step(title: "Tap Share",
             detail: "The square with an arrow pointing up.",
             scene: .app(highlightShare: true)),
        Step(title: "Tap “More”",
             detail: "Scroll to the end of the top row of apps and tap More.",
             scene: .row),
        Step(title: "Tap “Edit”",
             detail: "It's in the top right corner.",
             scene: .list(highlight: .edit)),
        Step(title: "Add TipMe to Favorites",
             detail: "If TipMe is under Suggestions, tap its green +. If it's already in the list, drag it up.",
             scene: .list(highlight: .add)),
        Step(title: "Tap Done",
             detail: "That saves it. TipMe now shows up straight away in the share row.",
             scene: .list(highlight: .done))
    ]

    var body: some View {
        VStack(spacing: 14) {
            TabView(selection: $page) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    VStack(spacing: 14) {
                        ShareSheetMock(scene: step.scene)
                            .frame(height: 210)
                            .accessibilityHidden(true)
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(Theme.onBrand)
                                .frame(width: 22, height: 22)
                                .background(Theme.brand, in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text(step.title)
                                    .font(Theme.headline)
                                    .foregroundStyle(Theme.textPrimary)
                                Text(step.detail)
                                    .font(Theme.body)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        Spacer(minLength: 0)
                    }
                    .tag(index)
                    .padding(.horizontal, 2)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 340)

            HStack(spacing: 6) {
                ForEach(0..<Self.steps.count, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Theme.brand : Theme.divider)
                        .frame(width: index == page ? 18 : 6, height: 6)
                }
            }
            .animation(Theme.motion, value: page)
            .accessibilityHidden(true)

            HStack {
                Button("Back") { move(-1) }
                    .opacity(page == 0 ? 0 : 1)
                    .disabled(page == 0)
                Spacer()
                Button(page == Self.steps.count - 1 ? "Start over" : "Next") {
                    if page == Self.steps.count - 1 {
                        withAnimation(Theme.motion) { page = 0 }
                    } else {
                        move(1)
                    }
                }
            }
            .font(Theme.headline)
            .foregroundStyle(Theme.brand)
            .buttonStyle(.pressable)
        }
    }

    private func move(_ delta: Int) {
        Haptics.tap()
        withAnimation(Theme.motion) {
            page = min(max(page + delta, 0), Self.steps.count - 1)
        }
    }
}

/// The Settings destination for the same walkthrough.
struct ShareSheetGuideScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacingLarge) {
                Text("Tipping starts from the Share button in apps like Instagram and TikTok. Moving TipMe into the main Share row means it's there immediately, instead of behind a “More” tap.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
                Card { ShareSheetGuide() }
                Text("You do this in iOS's own share sheet. TipMe can't change it for you or see whether it's done.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.spacing)
        }
        .background(Theme.background)
        .navigationTitle("Add TipMe to your Share Sheet")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Illustrations

/// Simplified drawings of the screens involved, with the thing to tap pulsing.
private struct ShareSheetMock: View {
    enum Highlight { case edit, add, done }

    enum Scene {
        case app(highlightShare: Bool)
        case row
        case list(highlight: Highlight)
    }

    let scene: Scene

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.surface)
            content
                .padding(16)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch scene {
        case .app(let highlightShare): appScene(highlightShare: highlightShare)
        case .row: rowScene
        case .list(let highlight): listScene(highlight: highlight)
        }
    }

    /// Rings the control the user should tap.
    private func ring<V: View>(_ on: Bool, radius: CGFloat = 10, @ViewBuilder _ view: () -> V) -> some View {
        view()
            .padding(4)
            .overlay {
                if on {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(Theme.brand, lineWidth: 3)
                        .scaleEffect(pulse ? 1.12 : 1.0)
                        .opacity(pulse ? 0.35 : 1.0)
                }
            }
    }

    private func appScene(highlightShare: Bool) -> some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surfaceRaised)
                .overlay(Image(systemName: "photo").font(.system(size: 34)).foregroundStyle(Theme.textTertiary))
            HStack(spacing: 26) {
                Image(systemName: "heart")
                Image(systemName: "bubble.right")
                ring(highlightShare) { Image(systemName: "square.and.arrow.up") }
                Spacer()
                Image(systemName: "bookmark")
            }
            .font(.system(size: 20))
            .foregroundStyle(Theme.textSecondary)
        }
    }

    private var rowScene: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share")
                .font(Theme.label)
                .foregroundStyle(Theme.textTertiary)
            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Theme.surfaceRaised).frame(width: 46, height: 46)
                }
                ring(true, radius: 24) {
                    ZStack {
                        Circle().fill(Theme.surfaceRaised).frame(width: 46, height: 46)
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
            }
            Text("Top row ends with More")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listScene(highlight: Highlight) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("Favorites")
                    .font(Theme.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                ring(highlight != .add, radius: 8) {
                    Text(highlight == .edit ? "Edit" : "Done")
                        .font(Theme.headline)
                        .foregroundStyle(Theme.brand)
                }
            }
            Divider().overlay(Theme.divider)
            Text("SUGGESTIONS")
                .font(Theme.label)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                ring(highlight == .add, radius: 16) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.green)
                }
                IconBadge(systemImage: "bolt.fill")
                Text("TipMe")
                    .font(Theme.body.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            Spacer(minLength: 0)
        }
    }
}
