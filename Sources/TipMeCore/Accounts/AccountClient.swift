import Foundation

/// Talks to the TipMe custodial account API: signup, login, logout, and
/// reading the account's ledger balance.
///
/// TipMe holds the actual money now, not the device -- see the custodial
/// pivot in project docs -- so a session token from here is the one thing
/// standing between someone and another person's balance. `AccountSession`
/// in the app target is what keeps it in the keychain and hands it to this
/// client; this type itself holds no state and trusts nothing it is not
/// explicitly given.
public struct AccountClient: Sendable {
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var timeout: TimeInterval

        public init(baseURL: URL, timeout: TimeInterval = 10) {
            self.baseURL = baseURL
            self.timeout = timeout
        }
    }

    public struct Session: Equatable, Sendable {
        public let userID: String
        public let email: String
        public let sessionToken: String
    }

    public struct AccountBalances: Equatable, Sendable {
        public let userID: String
        public let email: String
        public let balances: [Asset: Int64]
    }

    public enum AccountError: Error, Equatable, Sendable {
        /// The server rejected the email or password as malformed (bad
        /// email shape, password too short). The UI validates both locally
        /// before ever sending a request, so this is a defence-in-depth
        /// path, not the primary way a user learns their password is weak.
        case invalidRequest
        case emailTaken
        case invalidCredentials
        case tooManyAttempts
        case sessionExpired
        case offline
        case transport(String)
        case responseMalformed(String)
        /// `/v1/me/tip`: the sender's TipMe balance can't cover the amount.
        case insufficientFunds
        /// A 400 with a server-supplied reason worth showing verbatim
        /// (e.g. "this creator hasn't linked a TipMe account yet") rather
        /// than the generic `invalidRequest`, which carries no message.
        case requestRejected(String)
    }

    private let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = configuration.timeout
            config.timeoutIntervalForResource = configuration.timeout
            config.httpCookieStorage = nil
            self.session = URLSession(configuration: config)
        }
    }

    public func signup(email: String, password: String) async throws -> Session {
        try await authenticate(path: "/v1/auth/signup", email: email, password: password)
    }

    public func login(email: String, password: String) async throws -> Session {
        try await authenticate(path: "/v1/auth/login", email: email, password: password)
    }

    /// Best effort: the caller deletes its own copy of the token from the
    /// keychain regardless of whether this succeeds, since that -- not
    /// whatever the server does with it -- is what actually makes the
    /// device "logged out."
    public func logout(sessionToken: String) async {
        guard let url = url(path: "/v1/auth/logout") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }

    /// Always succeeds from the caller's point of view, whether or not the
    /// email has an account -- the server deliberately answers the same way
    /// either way (see the registry's own doc comment on this endpoint), so
    /// there is nothing for the UI to branch on beyond "network problem or
    /// not." A reset code, if one was issued, arrives by email.
    public func forgotPassword(email: String) async throws {
        guard let url = url(path: "/v1/auth/forgot-password") else {
            throw AccountError.responseMalformed("could not build registry URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(ForgotPasswordRequest(email: email))

        let (_, response) = try await perform(request)
        try Self.checkStatus(response, unauthorizedMeans: .invalidRequest)
    }

    /// Exchanges a reset code (from `forgotPassword`'s email) for a fresh
    /// session, the same shape `login` returns -- a successful reset logs
    /// the user straight back in rather than making them log in again right
    /// after proving who they are.
    public func resetPassword(code: String, newPassword: String) async throws -> Session {
        guard let url = url(path: "/v1/auth/reset-password") else {
            throw AccountError.responseMalformed("could not build registry URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONEncoder().encode(
            ResetPasswordRequest(code: code, newPassword: newPassword))

        let (data, response) = try await perform(request)
        // A 400 here means "bad or expired code," not "malformed request" --
        // closer to invalidCredentials than invalidRequest from the user's
        // point of view, so the UI can show one consistent message.
        try Self.checkStatus(response, unauthorizedMeans: .invalidCredentials, badRequestMeans: .invalidCredentials)

        do {
            let decoded = try JSONDecoder().decode(AuthResponse.self, from: data)
            return Session(userID: decoded.userID, email: decoded.email, sessionToken: decoded.sessionToken)
        } catch {
            throw AccountError.responseMalformed(String(describing: error))
        }
    }

    /// Changes the password for the currently signed-in account. The
    /// registry keeps this session alive and logs out every other one --
    /// see its own doc comment -- so there is nothing else for this device
    /// to do afterwards.
    public func changePassword(currentPassword: String, newPassword: String, sessionToken: String) async throws {
        guard let url = url(path: "/v1/auth/change-password") else {
            throw AccountError.responseMalformed("could not build registry URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(
            ChangePasswordRequest(currentPassword: currentPassword, newPassword: newPassword))

        let (_, response) = try await perform(request)
        // 401 here is a dead session (drop to login); 403 is "that wasn't
        // your current password" -- genuinely different UI outcomes, so
        // they cannot share one mapping the way login's 401 does.
        guard let http = response as? HTTPURLResponse else {
            throw AccountError.responseMalformed("non-HTTP response")
        }
        switch http.statusCode {
        case 204: return
        case 400: throw AccountError.invalidRequest
        case 401: throw AccountError.sessionExpired
        case 403: throw AccountError.invalidCredentials
        case 429: throw AccountError.tooManyAttempts
        default: throw AccountError.transport("registry returned HTTP \(http.statusCode)")
        }
    }

    /// Links a social handle straight to this account's own balance. See
    /// `POST /v1/me/creators` on the registry -- the "tip a friend who
    /// already has TipMe" path, distinct from `CreatorRegistrar.register`'s
    /// anonymous claim against an external Lightning address.
    public func linkCreator(platform: Platform, username: String, preferredAsset: Asset,
                            sessionToken: String) async throws -> LinkedCreator {
        guard let url = url(path: "/v1/me/creators") else {
            throw AccountError.responseMalformed("could not build registry URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(
            LinkCreatorRequest(platform: platform.rawValue, username: username, preferredAsset: preferredAsset.rawValue))

        let (data, response) = try await perform(request)
        try Self.checkTipStatus(response, data: data, unauthorizedMeans: .sessionExpired)

        do {
            return try JSONDecoder.registry.decode(LinkedCreator.self, from: data)
        } catch {
            throw AccountError.responseMalformed(String(describing: error))
        }
    }

    /// Unlinks a handle this account previously linked via `linkCreator`.
    public func unlinkCreator(platform: Platform, username: String, sessionToken: String) async throws {
        guard let url = url(path: "/v1/me/creators/\(platform.rawValue)/\(username)") else {
            throw AccountError.responseMalformed("could not build registry URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await perform(request)
        try Self.checkTipStatus(response, data: data, unauthorizedMeans: .sessionExpired)
    }

    /// Tells the registry "I've put the code in my bio, please check" --
    /// doesn't verify anything itself (that stays admin-only), just queues
    /// the claim for a human to look at. See `POST
    /// /v1/me/creators/{platform}/{username}/request-verification`.
    public func requestVerification(platform: Platform, username: String, sessionToken: String) async throws {
        guard let url = url(path: "/v1/me/creators/\(platform.rawValue)/\(username)/request-verification") else {
            throw AccountError.responseMalformed("could not build registry URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await perform(request)
        try Self.checkTipStatus(response, data: data, unauthorizedMeans: .sessionExpired)
    }

    /// One-tap automated verification: the registry fetches the creator's
    /// own public profile page itself and checks the real bio text against
    /// the claim code -- no link to paste, no waiting on a human. Instagram
    /// only; TikTok's profile page doesn't serve bio text this way, so that
    /// platform needs `verifyByLink` instead. See `POST
    /// /v1/me/creators/{platform}/{username}/verify-by-bio`.
    public func verifyByBio(platform: Platform, username: String, sessionToken: String) async throws {
        guard let url = url(path: "/v1/me/creators/\(platform.rawValue)/\(username)/verify-by-bio") else {
            throw AccountError.responseMalformed("could not build registry URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await perform(request)
        try Self.checkTipStatus(response, data: data, unauthorizedMeans: .sessionExpired)
    }

    /// Automated verification: the registry fetches `postURL` itself and
    /// checks whether the claim code is really in that post's caption --
    /// nothing here is trusted client-side, this only ever supplies the URL.
    /// Returns once verified; throws `.requestRejected` with the server's
    /// exact reason if the code wasn't found (or the URL couldn't be fetched
    /// at all). See `POST /v1/me/creators/{platform}/{username}/verify-by-link`.
    public func verifyByLink(platform: Platform, username: String, postURL: String, sessionToken: String) async throws {
        guard let url = url(path: "/v1/me/creators/\(platform.rawValue)/\(username)/verify-by-link") else {
            throw AccountError.responseMalformed("could not build registry URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(["post_url": postURL])

        let (data, response) = try await perform(request)
        try Self.checkTipStatus(response, data: data, unauthorizedMeans: .sessionExpired)
    }

    /// The one payment path that actually moves money today: a ledger
    /// transfer to a creator handle linked to its own TipMe account (see
    /// `linkCreator`). Returns the sender's new balance in `asset`.
    public func tip(platform: Platform, username: String, asset: Asset, amountMinorUnits: Int64,
                    sessionToken: String) async throws -> Int64 {
        guard let url = url(path: "/v1/me/tip") else {
            throw AccountError.responseMalformed("could not build registry URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(
            TipRequest(platform: platform.rawValue, username: username,
                      asset: asset.rawValue, amountMinorUnits: amountMinorUnits))

        let (data, response) = try await perform(request)
        try Self.checkTipStatus(response, data: data, unauthorizedMeans: .sessionExpired)

        do {
            let decoded = try JSONDecoder.registry.decode(TipResponsePayload.self, from: data)
            return decoded.newBalanceMinorUnits
        } catch {
            throw AccountError.responseMalformed(String(describing: error))
        }
    }

    public func me(sessionToken: String) async throws -> AccountBalances {
        guard let url = url(path: "/v1/me") else {
            throw AccountError.responseMalformed("could not build registry URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await perform(request)
        try Self.checkStatus(response, unauthorizedMeans: .sessionExpired)

        let decoded: MeResponse
        do {
            decoded = try JSONDecoder().decode(MeResponse.self, from: data)
        } catch {
            throw AccountError.responseMalformed(String(describing: error))
        }
        var balances: [Asset: Int64] = [:]
        for entry in decoded.balances {
            guard let asset = Asset(rawValue: entry.asset) else { continue }
            balances[asset] = entry.balanceMinor
        }
        return AccountBalances(userID: decoded.userID, email: decoded.email, balances: balances)
    }

    // MARK: - Shared plumbing

    private func authenticate(path: String, email: String, password: String) async throws -> Session {
        guard let url = url(path: path) else {
            throw AccountError.responseMalformed("could not build registry URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONEncoder().encode(AuthRequest(email: email, password: password))

        let (data, response) = try await perform(request)
        try Self.checkStatus(response, unauthorizedMeans: .invalidCredentials)

        do {
            let decoded = try JSONDecoder().decode(AuthResponse.self, from: data)
            return Session(userID: decoded.userID, email: decoded.email, sessionToken: decoded.sessionToken)
        } catch {
            throw AccountError.responseMalformed(String(describing: error))
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw AccountError.offline
        } catch {
            throw AccountError.transport(String(describing: error))
        }
    }

    private func url(path: String) -> URL? {
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        return components?.url
    }

    /// `unauthorizedMeans` distinguishes what a 401 actually means at the
    /// call site: on `/v1/auth/login` it is a wrong password, but on an
    /// authenticated endpoint like `/v1/me` it is a session that no longer
    /// exists -- different failures, and the UI needs to tell them apart to
    /// know whether to show "wrong password" or drop back to the login
    /// screen entirely.
    private static func checkStatus(_ response: URLResponse, unauthorizedMeans: AccountError,
                                    badRequestMeans: AccountError = .invalidRequest) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AccountError.responseMalformed("non-HTTP response")
        }
        switch http.statusCode {
        case 200, 201, 204:
            return
        case 400:
            throw badRequestMeans
        case 401:
            throw unauthorizedMeans
        case 409:
            throw AccountError.emailTaken
        case 429:
            throw AccountError.tooManyAttempts
        default:
            throw AccountError.transport("registry returned HTTP \(http.statusCode)")
        }
    }

    /// Status handling for the `/v1/me/creators` and `/v1/me/tip` family,
    /// which unlike the auth endpoints can return a 400/403/404/502 with a
    /// real server-authored reason worth showing the user verbatim -- 502
    /// is `verify-by-link`'s "couldn't fetch that URL at all" case.
    private static func checkTipStatus(_ response: URLResponse, data: Data, unauthorizedMeans: AccountError) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AccountError.responseMalformed("non-HTTP response")
        }
        switch http.statusCode {
        case 200, 201, 204:
            return
        case 400, 403, 404, 502:
            throw AccountError.requestRejected(detail(in: data) ?? "That didn't go through.")
        case 401:
            throw unauthorizedMeans
        case 402:
            throw AccountError.insufficientFunds
        case 429:
            throw AccountError.tooManyAttempts
        default:
            throw AccountError.transport("registry returned HTTP \(http.statusCode)")
        }
    }

    /// FastAPI puts the human-readable reason in `detail`.
    private static func detail(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let detail = object["detail"] as? String { return detail }
        if let details = object["detail"] as? [[String: Any]],
           let first = details.first, let message = first["msg"] as? String {
            return message
        }
        return nil
    }

    // Deliberately not routed through JSONDecoder.registry (RegistryClient.swift):
    // that decoder's .convertFromSnakeCase only matches CodingKeys with no
    // explicit raw value, and every type here needs one (snake_case JSON
    // keys, e.g. "user_id", against Swift's "userID" spelling). Explicit
    // CodingKeys plus the default key strategy is unambiguous; mixing the
    // two is not.
    private struct AuthRequest: Encodable {
        let email: String
        let password: String
    }

    private struct ForgotPasswordRequest: Encodable {
        let email: String
    }

    private struct ResetPasswordRequest: Encodable {
        let code: String
        let newPassword: String

        enum CodingKeys: String, CodingKey {
            case code
            case newPassword = "new_password"
        }
    }

    private struct ChangePasswordRequest: Encodable {
        let currentPassword: String
        let newPassword: String

        enum CodingKeys: String, CodingKey {
            case currentPassword = "current_password"
            case newPassword = "new_password"
        }
    }

    private struct AuthResponse: Decodable {
        let userID: String
        let email: String
        let sessionToken: String

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case email
            case sessionToken = "session_token"
        }
    }

    private struct MeResponse: Decodable {
        let userID: String
        let email: String
        let balances: [BalanceEntry]

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case email
            case balances
        }
    }

    private struct BalanceEntry: Decodable {
        let asset: String
        let balanceMinor: Int64

        enum CodingKeys: String, CodingKey {
            case asset
            case balanceMinor = "balance_minor"
        }
    }

    private struct LinkCreatorRequest: Encodable {
        let platform: String
        let username: String
        let preferredAsset: String

        enum CodingKeys: String, CodingKey {
            case platform, username
            case preferredAsset = "preferred_asset"
        }
    }

    // Decoded with JSONDecoder.registry (convertFromSnakeCase), matching
    // RegistryClient.swift's own payload structs -- no explicit CodingKeys
    // needed since every property name already matches the converted form.
    public struct LinkedCreator: Decodable, Sendable {
        public let platform: String
        public let username: String
        public let preferredAsset: String
        public let verified: Bool
        public let claimToken: String
        public let verificationInstructions: String
    }

    private struct TipRequest: Encodable {
        let platform: String
        let username: String
        let asset: String
        let amountMinorUnits: Int64

        enum CodingKeys: String, CodingKey {
            case platform, username, asset
            case amountMinorUnits = "amount_minor_units"
        }
    }

    private struct TipResponsePayload: Decodable {
        let newBalanceMinorUnits: Int64
    }
}
