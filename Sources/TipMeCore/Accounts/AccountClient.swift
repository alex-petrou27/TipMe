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
    private static func checkStatus(_ response: URLResponse, unauthorizedMeans: AccountError) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AccountError.responseMalformed("non-HTTP response")
        }
        switch http.statusCode {
        case 200, 201, 204:
            return
        case 400:
            throw AccountError.invalidRequest
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
}
