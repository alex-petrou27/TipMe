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
                    LaunchScreenView().task { await appModel.bootstrap() }
                case .misconfigured(let message):
                    MisconfiguredView(message: message)
                case .onboarding(let services):
                    OnboardingView(services: services) { appModel.finishedOnboarding(services: services) }
                case .locked(let services):
                    AppLockView { appModel.unlock(services: services) }
                case .ready(let services):
                    MainTabView(services: services,
                                onServicesChange: { appModel.servicesChanged() },
                                onLogout: { appModel.returnToOnboarding(services: services) })
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
        case locked(TipMeServices)
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
            // A signed-in session used to go straight to the balance --
            // no different from an app with nothing worth protecting.
            // TipMe is custodial; re-checking who's holding the phone on
            // every open (not only before a payment) matters here the
            // same way it does in Cash App or Venmo. See AppLockView.
            phase = .locked(services)
        } catch {
            phase = .misconfigured(String(describing: error))
        }
    }

    func unlock(services: TipMeServices) {
        phase = .ready(services)
    }

    /// Signing in already proves someone is present and holding the phone --
    /// re-checking with Face ID one line of code later would be redundant
    /// friction, not the security check `.locked` exists for. That gate is
    /// for a *return visit* to an already-signed-in session, not the moment
    /// right after typing a password.
    func finishedOnboarding(services: TipMeServices) {
        phase = .ready(services)
    }

    /// Rebuilds the services so every screen picks up the newly saved currency.
    func servicesChanged() {
        if let services = try? TipMeServices.make(origin: .hostApp) {
            phase = .ready(services)
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
