import SwiftUI
import TipMeCore

/// Tip someone by typing their exact handle, rather than sharing a post.
///
/// The share-sheet flow depends on Instagram/TikTok's share payload actually
/// naming the creator -- a real thing that has needed repeated fixing (see
/// `TipFlow.identify(attachedURLs:...)` and its own history) because
/// Instagram doesn't always hand the share extension a title, and a
/// shortcode Reel's URL carries no username at all. None of that is a
/// question here: a handle that was typed on purpose is unambiguous, so this
/// is both a reliable fallback when a share doesn't resolve, and the
/// simplest possible way to prove -- or use -- that a "Get tipped" link
/// actually works, independent of whatever Instagram's share sheet does.
struct TipByHandleView: View {
    let services: TipMeServices

    @State private var platform: Platform = .instagram
    @State private var username = ""
    @State private var payload: CreatorHandle?

    private var parsedHandle: CreatorHandle? {
        CreatorHandle(platform: platform, rawUsername: username)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                Card {
                    VStack(alignment: .leading, spacing: Theme.spacingSmall) {
                        Text("Who are you tipping?")
                            .font(Theme.headline)
                            .foregroundStyle(Theme.textPrimary)

                        Picker("Platform", selection: $platform) {
                            ForEach(Platform.allCases, id: \.self) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 2) {
                            Text("@").foregroundStyle(Theme.textSecondary)
                            TextField("username", text: $username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(Theme.body)
                        }
                        .padding(.vertical, 8)

                        if !username.isEmpty && parsedHandle == nil {
                            Text("That isn't a valid \(platform.displayName) username.")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.negative)
                        }
                    }
                }
                .padding(.horizontal, Theme.spacing)

                PrimaryButton(title: "Continue", isDisabled: parsedHandle == nil) {
                    payload = parsedHandle
                }
                .padding(.horizontal, Theme.spacing)

                Text("Works the instant the exact same handle has done \u{201C}Get tipped\u{201D} \u{2014} verification is optional and doesn't affect this.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.spacingLarge)
            }
            .padding(.vertical, Theme.spacing)
        }
        .background(Theme.background)
        .navigationTitle("Tip by handle")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $payload) { handle in
            TipByHandleHost(services: services, handle: handle) { payload = nil }
        }
    }
}

/// Runs the same `TipSheetView` the share extension and paste flow use, so
/// this path cannot drift from either of them.
private struct TipByHandleHost: View {
    let services: TipMeServices
    let handle: CreatorHandle
    let onFinish: () -> Void

    @StateObject private var viewModel: TipSheetViewModel

    init(services: TipMeServices, handle: CreatorHandle, onFinish: @escaping () -> Void) {
        self.services = services
        self.handle = handle
        self.onFinish = onFinish
        _viewModel = StateObject(wrappedValue: TipSheetViewModel(services: services,
                                                                 origin: .hostApp,
                                                                 onFinish: onFinish))
    }

    var body: some View {
        TipSheetView(viewModel: viewModel)
            .presentationDetents([.medium, .large])
            .task { await viewModel.start(withHandle: handle) }
    }
}

extension CreatorHandle: Identifiable {
    public var id: String { registryKey }
}
