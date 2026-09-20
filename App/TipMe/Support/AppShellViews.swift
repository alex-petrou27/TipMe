import SwiftUI
import TipMeCore

/// The first thing anyone sees, however briefly `bootstrap()` takes. A bare
/// `ProgressView()` on a plain background was the single most visible way
/// this read as unfinished -- the moment before the app decides where to
/// send you is not a moment to skip.
struct LaunchScreenView: View {
    var body: some View {
        ZStack {
            Theme.brand.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 36, weight: .black))
                    .foregroundStyle(Theme.onBrand)
                Text("TipMe")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.onBrand)
            }
        }
    }
}

/// Stands between a signed-in session and the balance screen. TipMe is
/// custodial -- the account behind this screen holds real money -- and
/// re-opening the app used to go straight to the balance with nothing in
/// between, no different from a session-less app with nothing to protect.
/// Every mainstream wallet (Cash App, Venmo) re-checks who's holding the
/// phone on every open, not only before a payment; this is that check.
struct AppLockView: View {
    let onUnlocked: () -> Void

    @State private var isAuthenticating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Image(systemName: "bolt.fill")
                .font(.system(size: 30, weight: .black))
                .foregroundStyle(Theme.onBrand)
                .frame(width: 78, height: 78)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            Text("TipMe")
                .font(Theme.balance(32))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            if let errorMessage {
                Text(errorMessage)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.negative)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.spacingLarge)
            }

            PrimaryButton(title: isAuthenticating ? "Checking…" : "Unlock",
                         systemImage: "faceid", isLoading: isAuthenticating) {
                Task { await authenticate() }
            }
            .padding(.horizontal, Theme.spacingLarge)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        // Attempted immediately, not only on a tap -- the button exists for
        // when this fails or gets cancelled, not as the primary path.
        .task { await authenticate() }
    }

    private func authenticate() async {
        errorMessage = nil
        isAuthenticating = true
        defer { isAuthenticating = false }

        switch await LocalAuthenticationAuthorizer().evaluate(reason: "Unlock TipMe") {
        case .succeeded:
            Haptics.tap()
            onUnlocked()
        case .userCancelled, .userFallback:
            break // stay on this screen; the button is right there
        case .unavailable(let reason), .failed(let reason):
            errorMessage = reason
        }
    }
}
