import Foundation
import BreezSDKLiquid
import TipMeCore

/// `PaymentBackend` implemented on Breez SDK — Nodeless (Liquid).
///
/// ## Why Breez Nodeless
///
/// Self-custodial with no node, channel or liquidity management; LNURL-pay and
/// fiat rates built in; Liquid assets alongside Bitcoin, which is what makes
/// the sender-asset/receiver-asset conversion in `SettlementRoute` possible at
/// all. Breez Native (Greenlight) would mean per-user node provisioning, and
/// `ldk-node` would put channel management on us — both out of scope for a
/// send-only tipping app.
///
/// ## Version
///
/// Written against **0.12.4**, pinned exactly in `project.yml`. The call sites
/// below were checked field by field against that release's generated bindings.
/// Breez changes request and response shapes across minor versions, so re-check
/// them on upgrade — a mismatch here is a payment bug, not a build error.
public actor BreezPaymentBackend: PaymentBackend {

    private var sdk: BindingLiquidSdk?
    private let apiKey: String
    private let network: LiquidNetwork
    private let workingDirectory: URL
    private let mnemonicProvider: @Sendable () throws -> String
    private var cachedRates: (rates: [Rate], fetchedAt: Date)?
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

        do {
            var config = try defaultConfig(network: network, breezApiKey: apiKey)
            config.workingDir = workingDirectory.path
            sdk = try BreezSDKLiquid.connect(req: ConnectRequest(config: config,
                                                                 mnemonic: try mnemonicProvider()))
        } catch {
            throw PaymentBackendError.network("connect failed: \(error)")
        }
    }

    public func disconnect() async {
        try? sdk?.disconnect()
        sdk = nil
    }

    /// Incremental sync. Called from the host app on foreground; the extension
    /// relies on this having already happened.
    public func sync() async throws {
        guard let sdk else { throw PaymentBackendError.notConnected }
        do { try sdk.sync() } catch { throw PaymentBackendError.network("sync failed: \(error)") }
    }

    func requireSDK() throws -> BindingLiquidSdk {
        guard let sdk else { throw PaymentBackendError.notConnected }
        return sdk
    }

    // MARK: - Assets

    /// Liquid asset id for Tether USD. Testnet has its own.
    static func assetID(for asset: Asset, network: LiquidNetwork) -> String? {
        switch asset {
        case .bitcoin:
            return nil // L-BTC is the network's base asset, addressed as `nil`
        case .usdt:
            switch network {
            case .mainnet:
                return "ce091c998b83c78bb71a632313ba3760f1763d9cfcffae02258ffa9865a37bd2"
            case .testnet:
                return "b612eb46313a2cd6ebabd8b7a8eed5696e29898b87a43bff41c94f51acef9d73"
            case .regtest:
                return nil
            }
        }
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
            guard let id = Self.assetID(for: .usdt, network: network),
                  let entry = info.walletInfo.assetBalances.first(where: { $0.assetId == id })
            else { return .usdtCents(0) }

            // `balance` is the amount in the asset's own units (so 12.34 USDT),
            // and is optional because it is only populated when the SDK knows
            // the asset's metadata. `balanceSat` on an asset balance is *not*
            // a USDT figure, so it must not be used here.
            guard let units = entry.balance else { return .usdtCents(0) }
            return .usdtCents(Int64((units * 100).rounded()))
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

        try Self.checkSendableRange(tip: tip, receiveAsset: receiveAsset, requestData: requestData)

        let prepared: PrepareLnUrlPayResponse
        do {
            prepared = try sdk.prepareLnurlPay(req: PrepareLnUrlPayRequest(
                data: requestData,
                amount: try Self.payAmount(tip: tip, receiveAsset: receiveAsset, network: network),
                bip353Address: nil,
                comment: nil,
                validateSuccessActionUrl: true))
        } catch {
            throw PaymentBackendError.network("could not prepare payment: \(error)")
        }

        // `feesSat` is the network's cost of delivering the payment, and for a
        // cross-asset payment it also carries the swap cost. It is disclosed to
        // the user separately from TipMe's fee — conflating the two would make
        // our fee look larger than it is and the network's look invisible.
        let conversionCost = try Self.cost(feesSat: Int64(prepared.feesSat),
                                           denominatedIn: tip.asset,
                                           sdk: sdk)

        return SettlementRoute(sendAsset: tip.asset,
                               receiveAsset: receiveAsset,
                               debited: tip,
                               credited: Self.credited(from: prepared.amount, fallback: tip),
                               conversionCost: conversionCost,
                               quotedAt: clock.now)
    }

    /// LNURL advertises its limits in millisatoshis, so the check only applies
    /// to a Bitcoin-denominated payment.
    private static func checkSendableRange(tip: Amount,
                                           receiveAsset: Asset,
                                           requestData: LnUrlPayRequestData) throws {
        guard receiveAsset == .bitcoin else { return }
        let minimum = Int64(requestData.minSendable / 1_000)
        let maximum = Int64(requestData.maxSendable / 1_000)
        if tip.minorUnits < minimum {
            throw PaymentBackendError.amountBelowDestinationMinimum(minimum: .sats(minimum))
        }
        if tip.minorUnits > maximum {
            throw PaymentBackendError.amountAboveDestinationMaximum(maximum: .sats(maximum))
        }
    }

    /// What the *receiver* gets, expressed the way Breez wants it.
    ///
    /// `toAsset` is what lands with the creator and `fromAsset` is what leaves
    /// the sender; passing both is what asks the SDK to swap in flight. A `nil`
    /// asset means L-BTC, the Liquid base asset.
    private static func payAmount(tip: Amount,
                                  receiveAsset: Asset,
                                  network: LiquidNetwork) throws -> PayAmount {
        switch receiveAsset {
        case .bitcoin:
            return .bitcoin(receiverAmountSat: UInt64(max(0, tip.minorUnits)))

        case .usdt:
            guard let toAsset = assetID(for: .usdt, network: network) else {
                throw PaymentBackendError.conversionUnavailable(from: tip.asset, to: receiveAsset)
            }
            return .asset(toAsset: toAsset,
                          receiverAmount: Double(tip.minorUnits) / 100.0,
                          estimateAssetFees: true,
                          fromAsset: assetID(for: tip.asset, network: network))
        }
    }

    private static func credited(from amount: PayAmount, fallback: Amount) -> Amount {
        switch amount {
        case .bitcoin(let sats):
            return .sats(Int64(sats))
        case .asset(_, let receiverAmount, _, _):
            return .usdtCents(Int64((receiverAmount * 100).rounded()))
        case .drain:
            // Not a route we ever construct; a drain has no fixed receiver
            // amount, so the requested tip is the best available answer.
            return fallback
        }
    }

    /// Expresses the sat-denominated network fee in whatever the sender is
    /// actually spending, so the confirm screen speaks one currency.
    private static func cost(feesSat: Int64,
                             denominatedIn asset: Asset,
                             sdk: BindingLiquidSdk) throws -> Amount {
        switch asset {
        case .bitcoin:
            return .sats(feesSat)
        case .usdt:
            guard let rates = try? sdk.fetchFiatRates(),
                  let usd = rates.first(where: { $0.coin.uppercased() == "USD" }),
                  usd.value > 0
            else { return .usdtCents(0) }
            let usdPerSat = usd.value / 100_000_000.0
            return .usdtCents(Int64((Double(feesSat) * usdPerSat * 100).rounded(.up)))
        }
    }

    // MARK: - Sending

    public func send(route: SettlementRoute,
                     to destination: LightningAddress,
                     idempotencyKey: String) async throws -> PaymentReceipt {
        let sdk = try requireSDK()

        // Re-prepare immediately before sending. A prepare response is not
        // durable across process death, and the share extension can be killed
        // between the confirm screen and the tap.
        let prepared = try reprepare(route: route, to: destination, sdk: sdk)

        let result: LnUrlPayResult
        do {
            result = try sdk.lnurlPay(req: LnUrlPayRequest(prepareResponse: prepared))
        } catch {
            throw PaymentBackendError.rejectedByNetwork(String(describing: error))
        }

        switch result {
        case .endpointSuccess(let data):
            let payment = data.payment
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
                           sdk: BindingLiquidSdk) throws -> PrepareLnUrlPayResponse {
        guard case .lnUrlPay(let requestData, _) = try sdk.parse(input: destination.description) else {
            throw PaymentBackendError.destinationUnreachable("\(destination.redacted) is not an LNURL-pay address")
        }
        do {
            return try sdk.prepareLnurlPay(req: PrepareLnUrlPayRequest(
                data: requestData,
                amount: try Self.payAmount(tip: route.credited,
                                           receiveAsset: route.receiveAsset,
                                           network: network),
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
        if let cached = cachedRates, clock.now.timeIntervalSince(cached.fetchedAt) < 30 {
            rates = cached.rates
        } else {
            do { rates = try sdk.fetchFiatRates() } catch {
                throw ExchangeRateError.unavailable(asset: asset, currencyCode: code)
            }
            cachedRates = (rates, clock.now)
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
            // Fiat minor units per cent of USDT, scaled by AssetRate.scale.
            return AssetRate(asset: .usdt,
                             currencyCode: code,
                             scaledPricePerMinorUnit: Int64((fiatPerUSDT * Double(AssetRate.scale)).rounded()),
                             asOf: clock.now)
        }
    }
}
