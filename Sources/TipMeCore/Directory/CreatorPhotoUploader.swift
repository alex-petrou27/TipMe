import Foundation

/// Sets a creator's confirm-screen photo (`PUT /v1/creators/{platform}/{username}/photo`).
///
/// Deliberately not a `CreatorRegistrar` method: a photo is cosmetic, never
/// reaches the payment path, and a creator can update one without touching
/// their wallet details — keeping the two apart means a bug in one cannot
/// silently affect the other.
public struct CreatorPhotoUploader: Sendable {
    public enum ImageFormat: String, Sendable {
        case jpeg = "image/jpeg"
        case png = "image/png"
    }

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

    /// Requires the record's management token, the same secret every other
    /// change to it needs — otherwise a stranger could deface a creator's
    /// confirm card without ever holding their wallet's keys.
    public func upload(handle: CreatorHandle, imageData: Data, format: ImageFormat,
                       managementToken: String) async throws {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/v1/creators/\(handle.platform.rawValue)/\(handle.username)/photo"
        guard let url = components?.url else {
            throw SocialOAuthError.responseMalformed("could not build registry URL")
        }

        let boundary = "tipme-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(managementToken, forHTTPHeaderField: "X-Management-Token")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(boundary: boundary, imageData: imageData, format: format)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SocialOAuthError.transport(String(describing: error))
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 204 else {
            throw SocialOAuthError.rejected(Self.detail(in: data) ?? "registry returned HTTP \(status)")
        }
    }

    static func multipartBody(boundary: String, imageData: Data, format: ImageFormat) -> Data {
        var body = Data()
        func append(_ string: String) {
            body.append(string.data(using: .utf8) ?? Data())
        }
        let filename = format == .png ? "photo.png" : "photo.jpg"
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"photo\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(format.rawValue)\r\n\r\n")
        body.append(imageData)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

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
}
