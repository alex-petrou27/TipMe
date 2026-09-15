import Foundation

public enum ShortLinkError: Error, Equatable, Sendable {
    case tooManyRedirects
    case leftKnownHosts(URL)
    case transport(String)
    case timedOut
}

/// One hop of redirect following.
///
/// A protocol rather than a hard dependency on `URLSession` so the resolver can
/// be tested without a network or a `URLProtocol` stub. This path is how nearly
/// every real TikTok share arrives — TikTok's own share sheet emits
/// `vm.tiktok.com` links, not canonical ones — so it needs to be exercised by
/// tests rather than only in someone's hand.
public protocol RedirectProbing: Sendable {
    /// Returns the next URL in the chain, or `nil` if this URL is the end of it.
    func nextHop(from url: URL) async throws -> URL?
}

/// Follows `vm.tiktok.com` / `vt.tiktok.com` / `tiktok.com/t/…` short links to
/// the canonical URL that actually contains the handle.
///
/// No authentication is involved — these are public 301/302 redirects. Three
/// deliberate constraints:
///
///  1. A hard redirect cap, so a redirect loop cannot hang the share sheet.
///  2. A short timeout, because this runs inside an app extension where the
///     user is waiting and the OS will kill us for being slow.
///  3. Every hop must stay on a host we recognise. An open redirect off the
///     platform would otherwise let a crafted link walk us somewhere else
///     entirely before we parse a "handle" out of it.
public actor ShortLinkResolver {
    private let probe: RedirectProbing
    private let maximumRedirects: Int
    private let parser = SharedLinkParser()

    public init(probe: RedirectProbing, maximumRedirects: Int = 5) {
        self.probe = probe
        self.maximumRedirects = maximumRedirects
    }

    public init(session: URLSession? = nil, maximumRedirects: Int = 5, timeout: TimeInterval = 6) {
        self.probe = URLSessionRedirectProbe(session: session, timeout: timeout)
        self.maximumRedirects = maximumRedirects
    }

    /// Resolves a short link into a `SharedLink`. Non-short links are returned
    /// unchanged, so callers can pass anything through this.
    public func resolve(_ link: SharedLink) async throws -> SharedLink {
        guard link.needsRedirectResolution else { return link }

        var current = link.canonicalURL
        for _ in 0..<maximumRedirects {
            guard let next = try await probe.nextHop(from: current) else { break }

            // Re-parse every hop. A redirect that leaves the platform is not a
            // link we will follow, however it was reached.
            guard let parsed = parser.parse(next) else {
                throw ShortLinkError.leftKnownHosts(next)
            }
            if !parsed.needsRedirectResolution {
                return parsed
            }
            current = next
        }

        // Ran out of hops, or the chain ended while still on a short link.
        if let parsed = parser.parse(current), !parsed.needsRedirectResolution {
            return parsed
        }
        throw ShortLinkError.tooManyRedirects
    }
}

/// `URLSession`-backed probe.
///
/// Auto-following is disabled so each hop can be inspected before it is taken.
public struct URLSessionRedirectProbe: RedirectProbing {
    private let configuration: URLSessionConfiguration

    public init(session: URLSession? = nil, timeout: TimeInterval = 6) {
        if let session {
            self.configuration = session.configuration
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            config.httpCookieStorage = nil
            config.urlCache = nil
            self.configuration = config
        }
    }

    public func nextHop(from url: URL) async throws -> URL? {
        // HEAD first: it is the cheap request, and short-link services normally
        // answer it with the same redirect they would give a GET.
        if let next = try await request(method: "HEAD", url: url) {
            return next
        }
        // Some link shorteners only redirect on GET, answering HEAD with a 405
        // or a bare 200. Falling back costs one extra request on a link that
        // would otherwise dead-end, and the body of a redirect is negligible.
        return try await request(method: "GET", url: url)
    }

    private func request(method: String, url: URL) async throws -> URL? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // A desktop-ish UA: some shorteners serve an interstitial rather than a
        // redirect to clients they do not recognise.
        request.setValue("Mozilla/5.0 (compatible; TipMe/1.0)", forHTTPHeaderField: "User-Agent")

        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (300...399).contains(http.statusCode),
                  let location = http.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: url)?.absoluteURL
            else { return nil }
            return next
        } catch let error as URLError where error.code == .timedOut {
            throw ShortLinkError.timedOut
        } catch {
            throw ShortLinkError.transport(String(describing: error))
        }
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // inspect each hop ourselves
    }
}
