import Foundation

/// Queues canned HTTP responses for `URLSession`-based clients under test.
/// None of `AccountClient`/`RegistryClient`'s existing tests exercise the
/// network layer directly (see their own test files' comments); the
/// Lightning deposit/withdraw paths move real money, so this exists to give
/// their request-building and status-code mapping direct coverage too.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let body: Data
        let validate: ((URLRequest) -> Void)?
    }

    // Test-only, single-threaded XCTest execution -- not a concurrency hazard.
    nonisolated(unsafe) static var stubs: [Stub] = []

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func stubJSON(_ statusCode: Int, _ json: String, validate: ((URLRequest) -> Void)? = nil) {
        stubs.append(Stub(statusCode: statusCode, body: Data(json.utf8), validate: validate))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard !Self.stubs.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let stub = Self.stubs.removeFirst()
        stub.validate?(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.statusCode,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
