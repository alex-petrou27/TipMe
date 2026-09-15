import Foundation

public enum ShortLinkError: Error, Equatable, Sendable {
    case tooManyRedirects
    case leftKnownHosts(URL)
    case transport(String)
    case timedOut
}

/// Follows `vm.tiktok.com` / `vt.tiktok.com` / `tiktok.com/t/...` short links to
/// the canonical URL that actually contains the handle.
///
/// No authentication is involved — these are public 301/302 redirects. Three
/// deliberate constraints:
///
///  1. A hard redirect cap, so a redirect loop can't hang the share sheet.
///  2. A short timeout, because this runs inside an app extension where the
///     user is waiting and the OS will kill us for being slow.
///  3. Every hop must stay on a host we recognise. An open redirect off the
///     platform would otherwise let a crafted link walk us somewhere else
///     entirely before we parse a "handle" out of it.
public actor ShortLinkResolver {
    private let session: URLSession
    private let maximumRedirects: Int
    private let parser = SharedLinkParser()

    public init(session: URLSession? = nil, maximumRedirects: Int = 5, timeout: TimeInterval = 6) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            config.httpCookieStorage = nil
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
        self.maximumRedirects = maximumRedirects
    }

    /// Resolves a short link into a `SharedLink`. Non-short links are returned
    /// unchanged, so callers can pass anything through this.
    public func resolve(_ link: SharedLink) async throws -> SharedLink {
        guard link.needsRedirectResolution else { return link }

        var current = link.canonicalURL
        for _ in 0..<maximumRedirects {
            let next = try await singleHop(from: current)
            guard let next else { break }

            guard let parsed = parser.parse(next) else {
                throw ShortLinkError.leftKnownHosts(next)
            }
            if !parsed.needsRedirectResolution {
                return parsed
            }
            current = next
        }

        // Ran out of hops, or the destination was still a short link.
        if let parsed = parser.parse(current), !parsed.needsRedirectResolution {
            return parsed
        }
        throw ShortLinkError.tooManyRedirects
    }

    /// Performs one request without letting URLSession auto-follow, so we can
    /// inspect each hop. Returns `nil` when the response was not a redirect.
    private func singleHop(from url: URL) async throws -> URL? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("TipMe/1.0", forHTTPHeaderField: "User-Agent")

        let delegate = NoRedirectDelegate()
        let hopSession = URLSession(configuration: session.configuration,
                                    delegate: delegate, delegateQueue: nil)
        defer { hopSession.finishTasksAndInvalidate() }

        do {
            let (_, response) = try await hopSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard (300...399).contains(http.statusCode),
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
