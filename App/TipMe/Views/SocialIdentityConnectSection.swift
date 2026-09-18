import SwiftUI
import TipMeCore

/// The "sending as @you" identity-connect Section — proves you control a
/// handle on Instagram/TikTok/YouTube/X without claiming a payable wallet or
/// granting anything beyond basic profile info. Originally lived in
/// Settings; extracted so Get Tipped can embed the same, single
/// implementation rather than a copy of it.
///
/// Self-contained: owns its own connect/disconnect state and reads/writes
/// `SenderIdentityStore` directly, so any screen can just drop this `Section`
/// into a `Form` and it works.
struct SocialIdentityConnectSection: View {
    let services: TipMeServices

    @State private var connectedHandles: [Platform: String] = [:]
    @State private var connectingPlatform: Platform?
    @State private var accountError: String?

    private var identityStore: SenderIdentityStore? {
        SenderIdentityStore(appGroup: services.configuration.appGroup)
    }

    /// Deliberately not `Platform.allCases`, which is scoped to creator
    /// claiming and excludes YouTube/X (see the doc comment on `Platform`).
    private static let identityPlatforms: [Platform] = [.instagram, .tiktok, .youtube, .x]

    var body: some View {
        Section("Your accounts") {
            ForEach(Self.identityPlatforms, id: \.self) { platform in
                accountRow(platform)
            }
            if let accountError {
                Text(accountError).font(.caption).foregroundStyle(.red)
            }
            Text("A \u{201C}Sending as\u{201D} badge only — sending a tip never needs this. TipMe never sees your password; connecting just proves the handle is yours.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { loadIdentities() }
    }

    private func accountRow(_ platform: Platform) -> some View {
        HStack {
            Text(platform.displayName)
            Spacer()
            if connectingPlatform == platform {
                ProgressView()
            } else if let username = connectedHandles[platform] {
                Text("@\(username)")
                    .foregroundStyle(.secondary)
                Button("Disconnect") { disconnect(platform) }
                    .font(.caption)
            } else {
                Button("Connect") { Task { await connect(platform) } }
                    .font(.callout)
            }
        }
    }

    private func loadIdentities() {
        guard let identityStore else { return }
        for platform in Self.identityPlatforms {
            if let username = identityStore.username(for: platform) {
                connectedHandles[platform] = username
            }
        }
    }

    private func connect(_ platform: Platform) async {
        accountError = nil
        connectingPlatform = platform
        defer { connectingPlatform = nil }

        let connector = SocialAccountConnector(baseURL: services.configuration.registryBaseURL)
        do {
            let result = try await connector.connectIdentity(platform: platform)
            identityStore?.set(username: result.username, for: platform)
            connectedHandles[platform] = result.username
        } catch let error as SocialAccountConnector.ConnectorError {
            accountError = error.userFacingReason
        } catch {
            accountError = String(describing: error)
        }
    }

    private func disconnect(_ platform: Platform) {
        identityStore?.clear(platform)
        connectedHandles[platform] = nil
    }
}
