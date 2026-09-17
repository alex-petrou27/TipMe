import SwiftUI
import TipMeCore

/// First run: create an account or log in, then a couple of optional setup
/// steps before landing on the balance screen.
///
/// TipMe is custodial: there is no recovery phrase to write down or verify.
/// An email and password are all that stand between someone and their
/// balance, so the account itself gets the up-front weight the seed phrase
/// used to have here — everything else (adding TipMe to the share sheet,
/// connecting Instagram/TikTok) is explicitly skippable.
struct OnboardingView: View {
    let services: TipMeServices
    let onComplete: () async -> Void

    @State private var mode: Mode = .welcome
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    @State private var connectedHandles: [Platform: String] = [:]
    @State private var connectingPlatform: Platform?
    @State private var socialError: String?

    private enum Mode { case welcome, signup, login, shareSetup, connectSocials }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .welcome: welcome
                case .signup: signup
                case .login: login
                case .shareSetup: shareSetup
                case .connectSocials: connectSocials
                }
            }
            .padding(24)
            .navigationTitle("TipMe")
            .tint(Theme.accent)
        }
    }

    // MARK: - Welcome

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.textPrimary)
            Text("Tip creators from the share sheet")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Sign up with your email — no recovery phrase, no crypto knowledge needed. TipMe holds your balance for you.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()

            Button("Create account") { errorMessage = nil; mode = .signup }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

            Button("I already have an account") { errorMessage = nil; mode = .login }
                .font(.footnote)
        }
    }

    // MARK: - Signup / login

    private var signup: some View {
        credentialsForm(
            title: "Create your account",
            subtitle: "This is what you'll use to log in on any device — pick a password you'll remember.",
            submitTitle: "Create account",
            passwordFieldContentType: .newPassword,
            submit: signUp,
            switchPrompt: "Already have an account?",
            switchTitle: "Log in",
            switchMode: .login)
    }

    private var login: some View {
        credentialsForm(
            title: "Log in",
            subtitle: nil,
            submitTitle: "Log in",
            passwordFieldContentType: .password,
            submit: logIn,
            switchPrompt: "New to TipMe?",
            switchTitle: "Create an account",
            switchMode: .signup)
    }

    private func credentialsForm(title: String, subtitle: String?, submitTitle: String,
                                 passwordFieldContentType: UITextContentType,
                                 submit: @escaping () async -> Void,
                                 switchPrompt: String, switchTitle: String,
                                 switchMode: Mode) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.semibold))
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }

            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            SecureField("Password", text: $password)
                .textContentType(passwordFieldContentType)
                .padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(Theme.negative)
            }

            Button {
                Task { await submit() }
            } label: {
                Group {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text(submitTitle)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSubmitting || email.isEmpty || password.isEmpty)

            HStack(spacing: 4) {
                Text(switchPrompt).foregroundStyle(.secondary)
                Button(switchTitle) { errorMessage = nil; password = ""; mode = switchMode }
            }
            .font(.footnote)

            Button("Back") { errorMessage = nil; password = ""; mode = .welcome }
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private func signUp() async {
        await authenticate { try await services.accountClient.signup(email: email, password: password) }
    }

    private func logIn() async {
        await authenticate { try await services.accountClient.login(email: email, password: password) }
    }

    private func authenticate(_ call: @escaping () async throws -> AccountClient.Session) async {
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let session = try await call()
            try services.accountKeychain.store(.init(session))
            password = ""
            mode = .shareSetup
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        guard let accountError = error as? AccountClient.AccountError else {
            return "Something went wrong. Check your connection and try again."
        }
        switch accountError {
        case .invalidRequest:
            return "Enter a valid email and a password of at least 8 characters."
        case .emailTaken:
            return "An account with that email already exists. Try logging in instead."
        case .invalidCredentials:
            return "Incorrect email or password."
        case .tooManyAttempts:
            return "Too many attempts. Try again in a little while."
        case .sessionExpired:
            return "Your session expired. Try again."
        case .offline:
            return "You're offline. Check your connection and try again."
        case .transport, .responseMalformed:
            return "Couldn't reach TipMe. Try again."
        }
    }

    // MARK: - Add to share sheet

    /// Prompts the user to enable TipMe in the share sheet, right after their
    /// account exists and before they land on Home — the same cadence apps use
    /// for a notifications-permission prompt.
    ///
    /// There is no real equivalent to that prompt here. Notifications, camera,
    /// location all have a genuine system permission API a third-party app can
    /// trigger (`UNUserNotificationCenter.requestAuthorization`, and so on).
    /// Whether TipMe is favourited in the share sheet is not a permission at
    /// all — Apple exposes no API, no deep link, and no Settings.app entry for
    /// it; it is edited only from inside the share sheet's own "More → Edit"
    /// screen, which an app cannot open or complete on the user's behalf.
    ///
    /// So this does the closest real thing: it presents the *actual* system
    /// share sheet via `ShareLink`, at the one moment we can walk someone
    /// through what to do inside it. We cannot detect whether they actually
    /// toggled TipMe on afterwards — there is no API for that either — so the
    /// copy says what to do rather than confirming that it happened.
    private var shareSetup: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "square.and.arrow.up.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.primary)

            Text("Add TipMe to your share sheet")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("This is a one-time setup so TipMe shows up right away next time, instead of behind “More”.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 14) {
                shareSetupStep(1, "Tap the button below to open the real share sheet.")
                shareSetupStep(2, "Scroll the icon row to the end and tap **More**.")
                shareSetupStep(3, "Turn on **TipMe**, then drag it to the top.")
            }
            .padding(18)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))

            Spacer()

            // The genuine system share sheet — not a lookalike. What the user
            // shares here doesn't matter; this exists to put them inside the
            // real "More → Edit" screen where the actual toggle lives.
            ShareLink(item: "I just set up TipMe to tip creators straight from my share sheet ⚡️") {
                Label("Open the share sheet", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(.primary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Button("Continue") { mode = .connectSocials }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

            Button("I'll do this later") { mode = .connectSocials }
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func shareSetupStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(Color(uiColor: .systemBackground))
                .frame(width: 20, height: 20)
                .background(.primary, in: Circle())
            Text(.init(text))
                .font(.callout)
        }
    }

    // MARK: - Connect socials

    private var connectSocials: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 56))
                .foregroundStyle(.primary)

            Text("Connect your accounts")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("So people can see it's really you when you tip. You can always do this later in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                connectRow(.instagram)
                connectRow(.tiktok)
            }
            .padding(18)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))

            if let socialError {
                Text(socialError).font(.caption).foregroundStyle(Theme.negative)
            }

            Spacer()

            Button("Continue to TipMe") { Task { await onComplete() } }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

            Button("I'll do this later") { Task { await onComplete() } }
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func connectRow(_ platform: Platform) -> some View {
        HStack {
            Text(platform.displayName)
            Spacer()
            if connectingPlatform == platform {
                ProgressView()
            } else if let username = connectedHandles[platform] {
                Label("@\(username)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                Button("Connect") { Task { await connectSocial(platform) } }
                    .font(.callout)
            }
        }
    }

    private func connectSocial(_ platform: Platform) async {
        socialError = nil
        connectingPlatform = platform
        defer { connectingPlatform = nil }

        let connector = SocialAccountConnector(baseURL: services.configuration.registryBaseURL)
        do {
            let result = try await connector.connectIdentity(platform: platform)
            SenderIdentityStore(appGroup: services.configuration.appGroup)?
                .set(username: result.username, for: platform)
            connectedHandles[platform] = result.username
        } catch let error as SocialAccountConnector.ConnectorError {
            socialError = error.userFacingReason
        } catch {
            socialError = String(describing: error)
        }
    }
}
