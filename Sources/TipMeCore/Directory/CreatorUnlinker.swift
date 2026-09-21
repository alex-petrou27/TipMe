import Foundation

/// Unlinks a handle from the wallet (`DELETE /v1/creators/{platform}/{username}`),
/// authorised by the handle's own management token.
public struct CreatorUnlinker: Sendable {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession? = nil, timeout: TimeInterval = 15) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            config.httpCookieStorage = nil
            self.session = URLSession(configuration: config)
        }
    }

    /// A 404 counts as success: the handle is already gone from the registry.
    public func unlink(handle: CreatorHandle, managementToken: String) async throws {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/v1/creators/\(handle.platform.rawValue)/\(handle.username)"
        guard let url = components?.url else {
            throw SocialOAuthError.responseMalformed("could not build registry URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(managementToken, forHTTPHeaderField: "X-Management-Token")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SocialOAuthError.transport(String(describing: error))
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 204 || status == 404 else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw SocialOAuthError.rejected(detail ?? "registry returned HTTP \(status)")
        }
    }
}
