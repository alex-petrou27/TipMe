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
    @State private var editingPlatform: Platform?
    @State private var editingUsername = ""

    private enum Mode: Equatable { case welcome, signup, login, shareSetup, connectSocials }

    var body: some View {
        NavigationStack {
            ScrollView {
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
            }
            .background(Theme.background)
            .animation(Theme.motion, value: mode)
            .tint(Theme.brand)
        }
    }

    // MARK: - Welcome

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 60)

            Image(systemName: "bolt.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.onBrand)
                .frame(width: 76, height: 76)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            Text("TipMe")
                .font(Theme.balance(34))
                .foregroundStyle(Theme.textPrimary)

            Text("Tip creators straight from the share sheet")
                .font(Theme.headline)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text("Sign up with your email — no recovery phrase, no crypto knowledge needed. TipMe holds your balance for you.")
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Spacer(minLength: 40)

            PrimaryButton(title: "Create account") { errorMessage = nil; mode = .signup }

            Button("Log in") { errorMessage = nil; mode = .login }
                .font(Theme.headline)
                .foregroundStyle(Theme.brand)
                .buttonStyle(.pressable)
                .padding(.vertical, 4)
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
        VStack(alignment: .leading, spacing: 20) {
            Button {
                errorMessage = nil; password = ""; mode = .welcome
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Theme.surfaceRaised, in: Circle())
            }
            .buttonStyle(.pressable)

            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Theme.title).foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle).font(Theme.body).foregroundStyle(Theme.textSecondary)
                }
            }

            Card {
                VStack(spacing: 0) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Theme.body)
                        .padding(.vertical, 13)

                    Divider().overlay(Theme.divider)

                    SecureField("Password", text: $password)
                        .textContentType(passwordFieldContentType)
                        .font(Theme.body)
                        .padding(.vertical, 13)
                }
            }

            if let errorMessage {
                Text(errorMessage).font(Theme.caption).foregroundStyle(Theme.negative)
            }

            PrimaryButton(title: submitTitle, isLoading: isSubmitting,
                         isDisabled: email.isEmpty || password.isEmpty) {
                Task { await submit() }
            }

            HStack(spacing: 4) {
                Text(switchPrompt).foregroundStyle(Theme.textSecondary)
                Button(switchTitle) { errorMessage = nil; password = ""; mode = switchMode }
                    .foregroundStyle(Theme.brand)
                    .fontWeight(.semibold)
            }
            .font(Theme.caption)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
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
        case .lightningUnavailable, .lightningRequestInvalid, .insufficientBalance,
             .invoiceAlreadyPaid, .depositNotFound, .lightningNodeError,
             .onchainUnavailable, .onchainError, .recipientNotFound:
            // Signup/login never produces these -- they're specific to the
            // deposit/withdraw/transfer endpoints -- but the switch must
            // stay exhaustive over the whole shared error enum.
            return "Something went wrong. Check your connection and try again."
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
            Spacer(minLength: 40)

            IconBadge(systemImage: "square.and.arrow.up.fill", size: 64)

            Text("Add TipMe to your share sheet")
                .font(Theme.title)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text("This is a one-time setup so TipMe shows up right away next time, instead of behind “More”.")
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Card {
                VStack(alignment: .leading, spacing: 14) {
                    shareSetupStep(1, "Tap the button below to open the real share sheet.")
                    shareSetupStep(2, "Scroll the icon row to the end and tap **More**.")
                    shareSetupStep(3, "Turn on **TipMe**, then drag it to the top.")
                }
            }

            Spacer(minLength: 20)

            // The genuine system share sheet — not a lookalike. What the user
            // shares here doesn't matter; this exists to put them inside the
            // real "More → Edit" screen where the actual toggle lives.
            ShareLink(item: "I just set up TipMe to tip creators straight from my share sheet ⚡️") {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Open the share sheet")
                }
                .font(Theme.headline)
                .foregroundStyle(Theme.onBrand)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background(Theme.brand, in: Capsule())
            }
            .buttonStyle(.pressable)

            PrimaryButton(title: "Continue") { mode = .connectSocials }

            Button("I'll do this later") { mode = .connectSocials }
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
                .buttonStyle(.pressable)
        }
    }

    private func shareSetupStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.onBrand)
                .frame(width: 20, height: 20)
                .background(Theme.brand, in: Circle())
            Text(.init(text))
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    // MARK: - Connect socials

    private var connectSocials: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 40)

            IconBadge(systemImage: "person.crop.circle.badge.checkmark", size: 64)

            Text("Connect your accounts")
                .font(Theme.title)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text("So people can see it's really you when you tip. You can always do this later in Settings.")
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Card {
                VStack(spacing: 12) {
                    connectRow(.instagram)
                    Divider().overlay(Theme.divider)
                    connectRow(.tiktok)
                }
            }

            if let socialError {
                Text(socialError).font(Theme.caption).foregroundStyle(Theme.negative)
            }

            Text("This is a \u{201C}Sending as\u{201D} badge, not a security check \u{2014} typing your handle is enough. \u{201C}Verify via sign-in\u{201D} proves it too, but only works for a Business or Creator account.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)

            Spacer(minLength: 20)

            PrimaryButton(title: "Continue to TipMe") { Task { await onComplete() } }

            Button("I'll do this later") { Task { await onComplete() } }
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
                .buttonStyle(.pressable)
        }
        .alert("Sending as", isPresented: editingAlertBinding) {
            TextField("Your \(editingPlatform?.displayName ?? "") handle", text: $editingUsername)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveTypedHandle() }
        }
    }

    private var editingAlertBinding: Binding<Bool> {
        Binding(get: { editingPlatform != nil }, set: { if !$0 { editingPlatform = nil } })
    }

    private func connectRow(_ platform: Platform) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: platform == .instagram ? "camera.fill" : "music.note")
            Text(platform.displayName)
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if connectingPlatform == platform {
                ProgressView()
            } else if let username = connectedHandles[platform] {
                Text("@\(username)")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Set") {
                        editingUsername = ""
                        editingPlatform = platform
                    }
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.brand)
                    .buttonStyle(.pressable)

                    Button("Verify via sign-in") { Task { await connectSocial(platform) } }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .buttonStyle(.pressable)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func saveTypedHandle() {
        guard let platform = editingPlatform else { return }
        let username = editingUsername.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !username.isEmpty else { return }
        SenderIdentityStore(appGroup: services.configuration.appGroup)?
            .set(username: username, for: platform)
        connectedHandles[platform] = username
        editingPlatform = nil
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
