import Foundation
import TipMeCore

/// Live prices for both assets in the user's currency, fetched once and used to
/// show every asset amount as money. Missing rates leave `fiat(for:)` nil so a
/// caller can fall back rather than show a wrong figure.
struct FiatConverter: Sendable {
    let currencyCode: String
    private let rates: [Asset: AssetRate]

    init(currencyCode: String, rates: [Asset: AssetRate] = [:]) {
        self.currencyCode = currencyCode
        self.rates = rates
    }

    func fiat(for amount: Amount) -> FiatAmount? {
        rates[amount.asset]?.fiatValue(of: amount)
    }
}

extension TipMeServices {
    var currencyCode: String { configuration.fiatCurrency }

    func fiatConverter() async -> FiatConverter {
        var rates: [Asset: AssetRate] = [:]
        for asset in [Asset.bitcoin, .usdt] {
            if let rate = try? await backend.rate(for: asset, in: currencyCode) { rates[asset] = rate }
        }
        return FiatConverter(currencyCode: currencyCode, rates: rates)
    }

    /// How much of `asset` an amount in the user's currency buys right now.
    func assetAmount(for fiat: FiatAmount, in asset: Asset) async throws -> Amount {
        try await backend.rate(for: asset, in: fiat.currencyCode).assetAmount(for: fiat)
    }

    func savePreferredCurrency(_ code: String) {
        guard let store = AppGroupKeyValueStore(appGroup: configuration.appGroup) else { return }
        CurrencyPreference(store: store).save(code)
    }
}
