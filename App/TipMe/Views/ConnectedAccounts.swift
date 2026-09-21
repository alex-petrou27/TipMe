import SwiftUI
import TipMeCore

/// The "sending as" accounts a user has connected on this device (see
/// `SenderIdentityStore`), shared by the two screens that care about them:
/// **Get Tipped** offers to connect a platform that isn't connected yet, and
/// **Settings** lists the ones that are, with a way to disconnect each.
///
/// The saved store, not this object, is the source of truth: `handles` is only
/// ever a re-read of it (`reload()`), never edited on its own, and the screens
/// reload whenever they appear. Sign-up's own "connect your socials" step
/// writes straight to the store without going through here, and logging out
/// doesn't tear this object down -- so a copy that only ever read the store
/// once would quietly go stale after a logout/sign-up in the same session.
///
/// One instance is shared between both screens rather than each keeping its
/// own copy -- a tab's content stays alive once shown, so two private copies
/// would only re-sync when something happened to make one re-read the store,
/// and a connect on one tab would not show up on the other. Sharing the
/// object means connecting TikTok on Get Tipped removes its option there and
/// adds it to Settings' list in the same instant.
@MainActor
final class ConnectedAccountsModel: ObservableObject {
    /// Order shown wherever these are listed.
    static let platforms: [Platform] = [.instagram, .tiktok]

    @Published private(set) var handles: [Platform: [String]] = [:]
    @Published private(set) var claimed: [CreatorHandle] = []
    @Published private(set) var connectingPlatform: Platform?
    @Published var error: String?

    private let services: TipMeServices
    private var store: SenderIdentityStore? {
        SenderIdentityStore(appGroup: services.configuration.appGroup)
    }

    private init(services: TipMeServices) {
        self.services = services
        reload()
    }

    private static var instance: ConnectedAccountsModel?

    static func shared(for services: TipMeServices) -> ConnectedAccountsModel {
        if let instance { return instance }
        let made = ConnectedAccountsModel(services: services)
        instance = made
        return made
    }

    struct Account: Hashable {
        let platform: Platform
        let username: String
    }

    var connected: [Account] {
        Self.platforms.flatMap { platform in
            (handles[platform] ?? []).map { Account(platform: platform, username: $0) }
        }
    }

    func reload() {
        claimed = services.ownedClaimedHandles()
            .sorted { ($0.platform.rawValue, $0.username) < ($1.platform.rawValue, $1.username) }
        guard let store else { return }
        var loaded: [Platform: [String]] = [:]
        for platform in Self.platforms {
            let usernames = store.usernames(for: platform)
            if !usernames.isEmpty { loaded[platform] = usernames }
        }
        handles = loaded
    }

    /// Self-declared, unverified -- no network call, nothing to fail. This is
    /// deliberately the primary path rather than a fallback: the badge it sets
    /// never gates a payment (see `SenderIdentityStore`'s own doc), and
    /// requiring platform sign-in just to type your own handle would be
    /// permanently unusable on a personal Instagram account.
    func connect(typedHandle raw: String, for platform: Platform) {
        let username = raw.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !username.isEmpty else { return }
        error = nil
        guard let store else {
            error = "Couldn't save that on this device. Try again."
            return
        }
        store.add(username: username, for: platform)
        reload()
    }

    /// Additionally proves it's really you, but only works for a Business or
    /// Creator account -- Instagram offers no sign-in at all for a personal one.
    func connectViaSignIn(_ platform: Platform) async {
        error = nil
        connectingPlatform = platform
        defer { connectingPlatform = nil }

        let connector = SocialAccountConnector(baseURL: services.configuration.registryBaseURL)
        do {
            let result = try await connector.connectIdentity(platform: platform)
            guard let store else {
                error = "Couldn't save that on this device. Try again."
                return
            }
            store.add(username: result.username, for: platform)
            reload()
        } catch let failure as SocialAccountConnector.ConnectorError {
            error = failure.userFacingReason
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Removes the handle from the registry first, so a failure leaves it
    /// linked (and still listed) rather than silently half-removed.
    func unlink(_ handle: CreatorHandle) async {
        error = nil
        guard let token = services.ownedToken(for: handle) else {
            services.creatorTokens.delete(for: handle)
            services.forgetOwner(of: handle)
            reload()
            return
        }
        do {
            try await CreatorUnlinker(baseURL: services.configuration.registryBaseURL)
                .unlink(handle: handle, managementToken: token)
            services.creatorTokens.delete(for: handle)
            services.forgetOwner(of: handle)
            reload()
        } catch {
            self.error = "Couldn't unlink @\(handle.username): \(error.localizedDescription)"
        }
    }

    func disconnect(_ account: Account) {
        store?.remove(username: account.username, for: account.platform)
        reload()
    }
}

private extension Platform {
    var connectionIcon: String { self == .instagram ? "camera.fill" : "music.note" }
}

// MARK: - Get Tipped

/// Connect options for each platform. A platform stays here after it's
/// connected (as "Add another"), since more than one account per platform is
/// allowed; what's connected is listed in Settings.
struct ConnectAccountsCard: View {
    @ObservedObject private var model: ConnectedAccountsModel
    /// Deliberately *not* cleared when the alert closes. SwiftUI may flip the
    /// presentation flag to false before an alert button's action runs, so an
    /// action that read a platform out of the same state the flag clears
    /// could find it already gone and silently save nothing.
    @State private var editingPlatform: Platform?
    @State private var isEditing = false
    @State private var editingUsername = ""

    init(services: TipMeServices) {
        _model = ObservedObject(wrappedValue: .shared(for: services))
    }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: Theme.spacingSmall) {
                    Text("CONNECT YOUR ACCOUNTS")
                        .font(Theme.label)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, Theme.spacing)

                    Card {
                        ForEach(Array(ConnectedAccountsModel.platforms.enumerated()), id: \.element) { index, platform in
                            if index > 0 { Divider().overlay(Theme.divider) }
                            row(platform)
                        }
                        if let error = model.error {
                            Text(error)
                                .font(Theme.caption)
                                .foregroundStyle(Theme.negative)
                                .padding(.top, 4)
                        }
                        Text("A \u{201C}Sending as\u{201D} badge only \u{2014} sending a tip never needs this, and typing your handle is enough. \u{201C}Verify via sign-in\u{201D} additionally proves it's really you, but only works for a Business or Creator account. You can connect more than one account per platform. Connected accounts are managed in Settings.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, Theme.spacing)
            }
        }
        .animation(Theme.motion, value: model.connectingPlatform)
        .animation(Theme.motion, value: model.error)
        .alert("Connect \(editingPlatform?.displayName ?? "")", isPresented: $isEditing) {
            TextField("Your \(editingPlatform?.displayName ?? "") handle", text: $editingUsername)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Connect") {
                if let platform = editingPlatform {
                    model.connect(typedHandle: editingUsername, for: platform)
                }
            }
        }
    }

    private func row(_ platform: Platform) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: platform.connectionIcon)
            Text(platform.displayName)
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if model.connectingPlatform == platform {
                ProgressView()
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    Button(model.handles[platform] == nil ? "Connect" : "Add another") {
                        Haptics.tap()
                        editingUsername = ""
                        editingPlatform = platform
                        isEditing = true
                    }
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.brand)
                    .buttonStyle(.pressable)

                    Button("Verify via sign-in") {
                        Haptics.tap()
                        Task { await model.connectViaSignIn(platform) }
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .buttonStyle(.pressable)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Settings

/// What's currently connected, each with a way to disconnect it. Deliberately
/// has no way to *add* an account: connecting lives on Get Tipped.
struct ConnectedAccountsList: View {
    @ObservedObject private var model: ConnectedAccountsModel

    init(services: TipMeServices) {
        _model = ObservedObject(wrappedValue: .shared(for: services))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.claimed.isEmpty && model.connected.isEmpty {
                Text("No accounts connected yet. Link your accounts from the Get Tipped tab.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            if !model.claimed.isEmpty {
                Text("RECEIVING TIPS TO THIS WALLET")
                    .font(Theme.label)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 6)
                ForEach(Array(model.claimed.enumerated()), id: \.element.registryKey) { index, handle in
                    if index > 0 { Divider().overlay(Theme.divider).padding(.vertical, 6) }
                    HStack(spacing: 12) {
                        IconBadge(systemImage: handle.platform.connectionIcon)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(handle.platform.displayName)
                                .font(Theme.body)
                                .foregroundStyle(Theme.textPrimary)
                            Text("@\(handle.username)")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button("Unlink") {
                            Haptics.tap()
                            Task { await model.unlink(handle) }
                        }
                        .font(Theme.caption.weight(.semibold))
                        .foregroundStyle(Theme.negative)
                        .buttonStyle(.pressable)
                    }
                    .padding(.vertical, 2)
                }
                if let error = model.error {
                    Text(error)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.negative)
                        .padding(.top, 4)
                }
                Text("Every account you link on Get Tipped pays into this one wallet. Unlinking stops tips to that handle reaching you; you can link it again from Get Tipped.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 8)
            }
            if !model.connected.isEmpty {
                Text("SENDING AS")
                    .font(Theme.label)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, model.claimed.isEmpty ? 0 : 16)
                    .padding(.bottom, 6)
                ForEach(Array(model.connected.enumerated()), id: \.element) { index, account in
                    if index > 0 { Divider().overlay(Theme.divider).padding(.vertical, 6) }
                    row(account)
                }
                Text("Disconnecting only removes it from this device. It can be connected again from Get Tipped.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 8)
            }
        }
        .animation(Theme.motion, value: model.connected)
        .animation(Theme.motion, value: model.claimed.map(\.registryKey))
        .onAppear { model.reload() }
    }

    private func row(_ account: ConnectedAccountsModel.Account) -> some View {
        let platform = account.platform
        return HStack(spacing: 12) {
            IconBadge(systemImage: platform.connectionIcon)
            VStack(alignment: .leading, spacing: 1) {
                Text(platform.displayName)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                Text("@\(account.username)")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Disconnect") {
                Haptics.tap()
                model.disconnect(account)
            }
            .font(Theme.caption.weight(.semibold))
            .foregroundStyle(Theme.negative)
            .buttonStyle(.pressable)
        }
        .padding(.vertical, 2)
    }
}
