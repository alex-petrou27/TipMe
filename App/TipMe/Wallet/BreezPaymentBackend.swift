import Foundation
import BreezSDKLiquid
import TipMeCore

/// `PaymentBackend` implemented on Breez SDK — Nodeless (Liquid).
///
/// ## Why Breez Nodeless
///
/// Self-custodial with no node, channel or liquidity management; LNURL-pay and
/// fiat rates built in; Liquid USDT alongside Bitcoin, which is what makes the
/// sender-asset/receiver-asset conversion in `SettlementRoute` possible at all.
/// Breez Native (Greenlight) would mean per-user node provisioning, and
/// `ldk-node` would put channel management on us — both out of scope for a
/// send-only tipping app.
///
/// ## Version pinning
///
/// The SDK call signatures below track the Nodeless API. Pin the version in
/// `project.yml` and re-check these call sites when upgrading — Breez has
/// changed request/response shapes across minor versions before, and a silent
/// mismatch here is a payment bug rather than a build error.
public actor BreezPaymentBackend: PaymentBackend {

    private var sdk: BindingLiquidSdk?
    private let apiKey: String
    private let network: LiquidNetwork
    private let workingDirectory: URL
    private let mnemonicProvider: @Sendable () throws -> String
    private var cachedRates: [String: (rates: [Rate], fetchedAt: Date)] = [:]
    private let clock: Clock

    public init(apiKey: String,
                network: LiquidNetwork,
                workingDirectory: URL,
                clock: Clock = SystemClock(),
                mnemonicProvider: @escaping @Sendable () throws -> String) {
        self.apiKey = apiKey
        self.network = network
        self.workingDirectory = workingDirectory
        self.clock = clock
        self.mnemonicProvider = mnemonicProvider
    }

    // MARK: - Lifecycle

    /// Connects, reusing the working directory in the shared App Group.
    ///
    /// That sharing is what makes the share extension viable: the host app
    /// keeps the Liquid wallet synced, and the extension opens an already-warm
    /// working directory rather than performing a cold sync inside a
    /// memory-capped process with a user waiting. See docs/SHARE_EXTENSION.md.
    public func connect() async throws {
        guard sdk == nil else { return }

        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        var config = try defaultConfig(network: network, breezApiKey: apiKey)
        config.workingDir = workingDirectory.path

        let mnemonic = try mnemonicProvider()
        do {
            sdk = try BreezSDKLiquid.connect(req: ConnectRequest(config: config, mnemonic: mnemonic))
        } catch {
            throw PaymentBackendError.network("connect failed: \(error)")
        }
    }

    public func disconnect() async {
        try? sdk?.disconnect()
        sdk = nil
    }

    /// Incremental sync. Call from the host app on foreground; the extension
    /// relies on this having already happened.
    public func sync() async throws {
        guard let sdk else { throw PaymentBackendError.notConnected }
        do { try sdk.sync() } catch { throw PaymentBackendError.network("sync failed: \(error)") }
    }

    func requireSDK() throws -> BindingLiquidSdk {
        guard let sdk else { throw PaymentBackendError.notConnected }
        return sdk
    }

    // MARK: - Balance

    public func availableBalance(for asset: Asset) async throws -> Amount {
        let sdk = try requireSDK()
        let info: GetInfoResponse
        do { info = try sdk.getInfo() } catch {
            throw PaymentBackendError.network("getInfo failed: \(error)")
        }

        switch asset {
        case .bitcoin:
            return .sats(Int64(info.walletInfo.balanceSat))
        case .usdt:
            guard let assetID = Self.usdtAssetID(for: network) else {
                return .usdtCents(0)
            }
            let balance = info.walletInfo.assetBalances.first { $0.assetId == assetID }
            // `balance` is in the asset's own units; USDT on Liquid carries 8
            // decimals, and we denominate in cents.
            let units = balance?.balance ?? 0
            return .usdtCents(Int64(units) / 1_000_000)
        }
    }

    /// Liquid asset id for Tether USD. Testnet has its own.
    static func usdtAssetID(for network: LiquidNetwork) -> String? {
        switch network {
        case .mainnet:
            return "ce091c998b83c78bb71a632313ba3760f1763d9cfcffae02258ffa9865a37bd2"
        case .testnet:
            return "b612eb46313a2cd6ebabd8b7a8eed5696e29898b87a43bff41c94f51acef9d73"
        default:
            return nil
        }
    }

    // MARK: - Routing

    public func prepareRoute(tip: Amount,
                             to destination: LightningAddress,
                             receiveAsset: Asset) async throws -> SettlementRoute {
        let sdk = try requireSDK()

        // Resolve the lightning address into LNURL-pay request data. This is
        // also where the destination's own min/max sendable are discovered, so
        // an out-of-range amount fails here rather than at spend time.
        let parsed: InputType
        do {
            parsed = try sdk.parse(input: destination.description)
        } catch {
            throw PaymentBackendError.destinationUnreachable("could not resolve \(destination.redacted)")
        }
        guard case .lnUrlPay(let requestData, _) = parsed else {
            throw PaymentBackendError.destinationUnreachable("\(destination.redacted) is not an LNURL-pay address")
        }

        let payAmount = try Self.payAmount(for: tip, receiveAsset: receiveAsset, network: network)

        let prepared: PrepareLnUrlPayResponse
        do {
            prepared = try sdk.prepareLnurlPay(req: PrepareLnUrlPayRequest(
                data: requestData,
                amount: payAmount,
                bip353Address: nil,
                comment: nil,
                validateSuccessActionUrl: true))
        } catch {
            throw Self.mapPrepareError(error, requestData: requestData, tip: tip)
        }

        // `feesSat` is the network's cost of delivering the payment, and for a
        // cross-asset payment it also carries the swap cost. It is disclosed to
        // the user separately from TipMe's fee — conflating the two would make
        // our fee look larger than it is and the network's look invisible.
        let conversionCost = try Self.conversionCost(feesSat: Int64(prepared.feesSat),
                                                     in: tip.asset,
                                                     network: network,
                                                     sdk: sdk)

        let credited = try Self.creditedAmount(from: prepared, receiveAsset: receiveAsset, fallback: tip)

        return SettlementRoute(sendAsset: tip.asset,
                               receiveAsset: receiveAsset,
                               debited: tip,
                               credited: credited,
                               conversionCost: conversionCost,
                               quotedAt: clock.now)
    }

    private static func payAmount(for tip: Amount, receiveAsset: Asset, network: LiquidNetwork) throws -> PayAmount {
        switch receiveAsset {
        case .bitcoin:
            return .bitcoin(receiverAmountSat: UInt64(max(0, tip.minorUnits)))
        case .usdt:
            guard let assetID = usdtAssetID(for: network) else {
                throw PaymentBackendError.conversionUnavailable(from: tip.asset, to: receiveAsset)
            }
            // Cents -> the asset's own 8-decimal units.
            return .asset(assetId: assetID,
                          receiverAmount: Double(tip.minorUnits) / 100.0,
                          estimateAssetFees: true,
                          payWithBitcoin: tip.asset == .bitcoin)
        }
    }

    private static func creditedAmount(from prepared: PrepareLnUrlPayResponse,
                                       receiveAsset: Asset,
                                       fallback: Amount) throws -> Amount {
        switch prepared.amount {
        case .some(.bitcoin(let sats)):
            return .sats(Int64(sats))
        case .some(.asset(_, let amount, _, _)):
            return .usdtCents(Int64((amount * 100).rounded()))
        default:
            guard receiveAsset == fallback.asset else {
                throw PaymentBackendError.conversionUnavailable(from: fallback.asset, to: receiveAsset)
            }
            return fallback
        }
    }

    private static func conversionCost(feesSat: Int64, in asset: Asset,
                                       network: LiquidNetwork, sdk: BindingLiquidSdk) throws -> Amount {
        switch asset {
        case .bitcoin:
            return .sats(feesSat)
        case .usdt:
            // Express the sat-denominated network fee in the asset the sender
            // is actually spending, so the confirm screen has one currency.
            guard let rates = try? sdk.fetchFiatRates(),
                  let usd = rates.first(where: { $0.coin.uppercased() == "USD" }),
                  usd.value > 0
            else { return .usdtCents(0) }
            let usdPerSat = usd.value / 100_000_000.0
            return .usdtCents(Int64((Double(feesSat) * usdPerSat * 100).rounded(.up)))
        }
    }

    private static func mapPrepareError(_ error: Error,
                                        requestData: LnUrlPayRequestData,
                                        tip: Amount) -> PaymentBackendError {
        let minimum = Int64(requestData.minSendable / 1000)
        let maximum = Int64(requestData.maxSendable / 1000)
        if tip.asset == .bitcoin {
            if tip.minorUnits < minimum {
                return .amountBelowDestinationMinimum(minimum: .sats(minimum))
            }
            if tip.minorUnits > maximum {
                return .amountAboveDestinationMaximum(maximum: .sats(maximum))
            }
        }
        return .network("could not prepare payment: \(error)")
    }

    // MARK: - Sending

    public func send(route: SettlementRoute,
                     to destination: LightningAddress,
                     idempotencyKey: String) async throws -> PaymentReceipt {
        let sdk = try requireSDK()

        // Re-prepare immediately before sending. The SDK's prepare response is
        // not durable across process death, and the share extension can be
        // killed between the confirm screen and the tap.
        let prepared = try await reprepare(route: route, to: destination, sdk: sdk)

        let result: LnUrlPayResult
        do {
            result = try sdk.lnurlPay(req: LnUrlPayRequest(prepareResponse: prepared))
        } catch {
            throw PaymentBackendError.rejectedByNetwork(String(describing: error))
        }

        switch result {
        case .endpointSuccess(let data):
            guard let payment = data.payment as Payment? else {
                throw PaymentBackendError.rejectedByNetwork("payment missing from success response")
            }
            return PaymentReceipt(
                status: payment.status == .complete ? .succeeded : .pending,
                paymentHash: payment.txId ?? idempotencyKey,
                networkFee: Amount(asset: route.sendAsset, minorUnits: Int64(payment.feesSat)),
                sentAmount: route.debited,
                completedAt: clock.now)

        case .endpointError(let data):
            throw PaymentBackendError.rejectedByNetwork(data.reason)

        case .payError(let data):
            throw PaymentBackendError.rejectedByNetwork(data.reason)
        }
    }

    private func reprepare(route: SettlementRoute,
                           to destination: LightningAddress,
                           sdk: BindingLiquidSdk) async throws -> PrepareLnUrlPayResponse {
        guard case .lnUrlPay(let requestData, _) = try sdk.parse(input: destination.description) else {
            throw PaymentBackendError.destinationUnreachable("\(destination.redacted) is not an LNURL-pay address")
        }
        let payAmount = try Self.payAmount(for: route.credited,
                                           receiveAsset: route.receiveAsset,
                                           network: network)
        do {
            return try sdk.prepareLnurlPay(req: PrepareLnUrlPayRequest(
                data: requestData,
                amount: payAmount,
                bip353Address: nil,
                comment: nil,
                validateSuccessActionUrl: true))
        } catch {
            throw PaymentBackendError.routeExpired
        }
    }

    // MARK: - Fiat rates

    public func rate(for asset: Asset, in currencyCode: String) async throws -> AssetRate {
        let sdk = try requireSDK()
        let code = currencyCode.uppercased()

        let rates: [Rate]
        if let cached = cachedRates[code], clock.now.timeIntervalSince(cached.fetchedAt) < 30 {
            rates = cached.rates
        } else {
            do { rates = try sdk.fetchFiatRates() } catch {
                throw ExchangeRateError.unavailable(asset: asset, currencyCode: code)
            }
            cachedRates[code] = (rates, clock.now)
        }

        guard let target = rates.first(where: { $0.coin.uppercased() == code }), target.value > 0 else {
            throw ExchangeRateError.unavailable(asset: asset, currencyCode: code)
        }

        switch asset {
        case .bitcoin:
            // `value` is fiat units per BTC. One sat is value/1e8 fiat units,
            // i.e. value*100/1e8 minor units. Scaled by AssetRate.scale (1e8)
            // that is exactly value*100.
            return AssetRate(asset: .bitcoin,
                             currencyCode: code,
                             scaledPricePerMinorUnit: Int64((target.value * 100).rounded()),
                             asOf: clock.now)

        case .usdt:
            // Breez quotes fiat against BTC, not against Liquid USDT. One USDT
            // tracks one USD, so the cross rate is (fiat/BTC) / (USD/BTC).
            guard let usd = rates.first(where: { $0.coin.uppercased() == "USD" }), usd.value > 0 else {
                throw ExchangeRateError.unavailable(asset: .usdt, currencyCode: code)
            }
            let fiatPerUSDT = target.value / usd.value
            // Minor units of fiat per cent of USDT, scaled by 1e8.
            let scaled = fiatPerUSDT * 100.0 / 100.0 * Double(AssetRate.scale)
            return AssetRate(asset: .usdt,
                             currencyCode: code,
                             scaledPricePerMinorUnit: Int64(scaled.rounded()),
                             asOf: clock.now)
        }
    }
}
