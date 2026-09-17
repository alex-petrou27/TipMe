import SwiftUI
import TipMeCore

@main
struct TipMeApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            Group {
                switch appModel.phase {
                case .loading:
                    ProgressView().task { await appModel.bootstrap() }
                case .misconfigured(let message):
                    MisconfiguredView(message: message)
                case .onboarding(let services):
                    OnboardingView(services: services) { await appModel.bootstrap() }
                case .ready(let services):
                    HomeView(services: services) {
                        appModel.returnToOnboarding(services: services)
                    }
                }
            }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase {
        case loading
        case misconfigured(String)
        case onboarding(TipMeServices)
        case ready(TipMeServices)
    }

    @Published private(set) var phase: Phase = .loading

    func bootstrap() async {
        do {
            let services = try TipMeServices.make(origin: .hostApp)
            guard services.isSignedIn else {
                phase = .onboarding(services)
                return
            }
            phase = .ready(services)
        } catch {
            phase = .misconfigured(String(describing: error))
        }
    }

    /// Called after logging out — the session is already cleared from the
    /// keychain by the time this runs, so this just moves the UI back to
    /// onboarding rather than needing to rebuild `services` from scratch.
    func returnToOnboarding(services: TipMeServices) {
        phase = .onboarding(services)
    }
}

/// Configuration is validated at launch and fails loudly. A wallet app that
/// boots with a missing fee destination or registry key is one that will
/// misroute money later.
struct MisconfiguredView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "gearshape.badge.xmark")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("TipMe isn't configured")
                .font(.headline)
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("Copy .env.example to .env, fill it in, and regenerate Config/Secrets.xcconfig. See the README.")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
    }
}
