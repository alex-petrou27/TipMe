import Foundation

/// `ExchangeRateProvider` backed by the registry's `/v1/rates` endpoint.
///
/// Replaces the fiat rates the app used to get for free from the Breez SDK.
/// Now that the app is custodial and does not run a wallet SDK on-device at
/// all, rates have to come from somewhere else -- the server the app
/// already trusts for the ledger is the natural place.
public actor RegistryRateProvider: ExchangeRateProvider {
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var timeout: TimeInterval

        public init(baseURL: URL, timeout: TimeInterval = 10) {
            self.baseURL = baseURL
            self.timeout = timeout
        }
    }

    private let configuration: Configuration
    private let session: URLSession
    private let clock: Clock
    // Keyed by currency code. Mirrors the 30s cache BreezPaymentBackend kept
    // in front of its own rate fetch -- a confirm screen re-reading the rate
    // on every render should not mean a network call on every render.
    private var cache: [String: (bitcoinPrice: Double, usdtPrice: Double, fetchedAt: Date)] = [:]
    private let cacheTTL: TimeInterval = 30

    public init(configuration: Configuration, session: URLSession? = nil, clock: Clock = SystemClock()) {
        self.configuration = configuration
        self.clock = clock
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

    public func rate(for asset: Asset, in currencyCode: String) async throws -> AssetRate {
        let code = currencyCode.uppercased()
        let (bitcoinPrice, usdtPrice) = try await prices(for: code, requestedAsset: asset)

        switch asset {
        case .bitcoin:
            // bitcoinPrice is fiat major units per whole BTC. One sat is
            // bitcoinPrice/1e8 fiat major units, i.e. bitcoinPrice*100/1e8
            // fiat minor units. Scaled by AssetRate.scale (1e8) that is
            // exactly bitcoinPrice*100 -- see AssetRate's own doc comment.
            return AssetRate(asset: .bitcoin, currencyCode: code,
                             scaledPricePerMinorUnit: Int64((bitcoinPrice * 100).rounded()),
                             asOf: clock.now)
        case .usdt:
            // usdtPrice is fiat major units per whole USDT. USDT's minor
            // unit is a cent, i.e. 1/100th of a display unit, so fiat minor
            // units per USDT-cent equals usdtPrice itself (major-per-major
            // cancels the *100/100). Scaled by AssetRate.scale as above.
            return AssetRate(asset: .usdt, currencyCode: code,
                             scaledPricePerMinorUnit: Int64((usdtPrice * Double(AssetRate.scale)).rounded()),
                             asOf: clock.now)
        }
    }

    private func prices(for code: String, requestedAsset: Asset) async throws -> (bitcoinPrice: Double, usdtPrice: Double) {
        if let cached = cache[code], clock.now.timeIntervalSince(cached.fetchedAt) < cacheTTL {
            return (cached.bitcoinPrice, cached.usdtPrice)
        }

        func unavailable() -> ExchangeRateError { .unavailable(asset: requestedAsset, currencyCode: code) }

        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw unavailable()
        }
        components.path = "/v1/rates"
        components.queryItems = [URLQueryItem(name: "currency", value: code)]
        guard let url = components.url else { throw unavailable() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw unavailable()
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw unavailable()
        }

        let decoded: RatesResponse
        do {
            decoded = try JSONDecoder().decode(RatesResponse.self, from: data)
        } catch {
            throw unavailable()
        }

        cache[code] = (decoded.bitcoinPrice, decoded.usdtPrice, clock.now)
        return (decoded.bitcoinPrice, decoded.usdtPrice)
    }

    private struct RatesResponse: Decodable {
        let bitcoinPrice: Double
        let usdtPrice: Double

        enum CodingKeys: String, CodingKey {
            case bitcoinPrice = "bitcoin_price"
            case usdtPrice = "usdt_price"
        }
    }
}
