import Foundation
import BreezSDKLiquid
import TipMeCore

/// `WalletBackend` conformance for `BreezPaymentBackend` — send to any
/// destination, receive, and read history. Kept in its own file/extension
/// because `BreezPaymentBackend.swift` is already large with the tip-specific
/// LNURL path; this is the general wallet surface layered on the same actor
/// and the same underlying SDK connection.
///
/// Checked field by field against the 0.12.4 bindings, the same way the
/// LNURL path was — see the comment at the top of `BreezPaymentBackend.swift`.
extension BreezPaymentBackend: WalletBackend {

    public func availableBalanceForSend(asset: Asset) async throws -> TipMeCore.Amount {
        try await availableBalance(for: asset)
    }

    // MARK: - Resolving what was pasted or scanned

    public func resolve(destination raw: String) async throws -> WalletDestination {
        let sdk = try requireSDK()
        let parsed: InputType
        do {
            parsed = try sdk.parse(input: raw)
        } catch {
            throw WalletDestinationError.unrecognised
        }

        switch parsed {
        case .lnUrlPay(let data, _):
            guard let address = data.lnAddress.flatMap(LightningAddress.init) else {
                throw WalletDestinationError.unrecognised
            }
            return .lightningAddress(address)

        case .bolt11(let invoice):
            // InputType.bolt11 carries only the invoice — no bip353Address
            // here (that field exists on a different enum, SendDestination's
            // own bolt11 case, not this one).
            return .lightningInvoice(raw: raw,
                                     amountSat: invoice.amountMsat.map { Int64($0 / 1_000) },
                                     description: invoice.description)

        case .bitcoinAddress(let data):
            return .bitcoinAddress(raw: data.address)

        case .liquidAddress(let data):
            let assetHint = data.assetId.flatMap { id in
                id == Self.assetID(for: .usdt, network: network) ? Asset.usdt : nil
            }
            return .liquidAddress(raw: data.address, assetHint: assetHint)

        default:
            // Withdraw requests, auth requests, node ids, and bolt12 offers are
            // real InputType cases but not things this wallet sends money to.
            throw WalletDestinationError.unrecognised
        }
    }

    // MARK: - Pricing and sending to a resolved destination

    public func prepareSend(amount: TipMeCore.Amount, to destination: WalletDestination) async throws -> SettlementRoute {
        let sdk = try requireSDK()

        if case .lightningAddress(let address) = destination {
            // Identical rail to a tip: an LNURL-pay address can specify a
            // receive asset different from what the sender is spending.
            return try await prepareRoute(tip: amount, to: address, receiveAsset: amount.asset)
        }

        // Every other destination is single-asset: an on-chain Bitcoin
        // address, a BOLT-11 invoice, and a Liquid address (absent an asset
        // hint pointing elsewhere) all accept exactly the asset being sent.
        // There is no conversion to quote — the destination itself fixes it.
        let prepared: PrepareSendResponse
        do {
            prepared = try sdk.prepareSendPayment(req: PrepareSendRequest(
                destination: Self.rawDestinationString(for: destination),
                amount: try Self.payAmount(tip: amount, receiveAsset: amount.asset, network: network),
                disableMrh: nil, paymentTimeoutSec: nil))
        } catch {
            throw PaymentBackendError.network("could not prepare send: \(error)")
        }

        let feesSat = Int64(prepared.feesSat ?? 0)
        return SettlementRoute(sendAsset: amount.asset, receiveAsset: amount.asset,
                               debited: amount, credited: amount,
                               conversionCost: TipMeCore.Amount(asset: amount.asset, minorUnits: feesSat),
                               quotedAt: Date())
    }

    public func send(route: SettlementRoute, to destination: WalletDestination,
                     idempotencyKey: String) async throws -> PaymentReceipt {
        if case .lightningAddress(let address) = destination {
            return try await send(route: route, to: address, idempotencyKey: idempotencyKey)
        }

        let sdk = try requireSDK()
        let prepared: PrepareSendResponse
        do {
            prepared = try sdk.prepareSendPayment(req: PrepareSendRequest(
                destination: Self.rawDestinationString(for: destination),
                amount: try Self.payAmount(tip: route.debited, receiveAsset: route.receiveAsset, network: network),
                disableMrh: nil, paymentTimeoutSec: nil))
        } catch {
            throw PaymentBackendError.routeExpired
        }

        let response: SendPaymentResponse
        do {
            response = try sdk.sendPayment(req: SendPaymentRequest(
                prepareResponse: prepared, useAssetFees: nil, payerNote: nil))
        } catch {
            throw PaymentBackendError.rejectedByNetwork(String(describing: error))
        }

        let payment = response.payment
        return PaymentReceipt(
            status: payment.status == .complete ? .succeeded : .pending,
            paymentHash: payment.txId ?? idempotencyKey,
            networkFee: TipMeCore.Amount(asset: route.sendAsset, minorUnits: Int64(payment.feesSat)),
            sentAmount: route.debited,
            completedAt: Date())
    }

    /// A raw destination is whatever the user pasted; `WalletDestination`
    /// keeps it for exactly this purpose. Lightning addresses are the one case
    /// excluded here because they route through the LNURL path above instead.
    private static func rawDestinationString(for destination: WalletDestination) -> String {
        switch destination {
        case .lightningAddress(let address): return address.description
        case .lightningInvoice(let raw, _, _): return raw
        case .bitcoinAddress(let raw): return raw
        case .liquidAddress(let raw, _): return raw
        }
    }

    // MARK: - Receiving

    public func receive(amount: TipMeCore.Amount?, method: ReceiveMethod) async throws -> ReceiveRequest {
        let sdk = try requireSDK()

        let paymentMethod: PaymentMethod = {
            switch method {
            case .lightning: return .bolt11Invoice
            case .bitcoin: return .bitcoinAddress
            case .liquid: return .liquidAddress
            }
        }()

        let receiveAmount: ReceiveAmount? = amount.map {
            switch $0.asset {
            case .bitcoin: return .bitcoin(payerAmountSat: UInt64(max(0, $0.minorUnits)))
            case .usdt:
                guard let assetID = Self.assetID(for: .usdt, network: network) else { return nil }
                return .asset(assetId: assetID, payerAmount: Double($0.minorUnits) / 100.0)
            }
        } ?? nil

        let prepared: PrepareReceiveResponse
        do {
            prepared = try sdk.prepareReceivePayment(
                req: PrepareReceiveRequest(paymentMethod: paymentMethod, amount: receiveAmount))
        } catch {
            throw PaymentBackendError.network("could not prepare receive: \(error)")
        }

        let response: ReceivePaymentResponse
        do {
            response = try sdk.receivePayment(req: ReceivePaymentRequest(
                prepareResponse: prepared, description: nil, descriptionHash: nil, payerNote: nil))
        } catch {
            throw PaymentBackendError.network("could not create receive request: \(error)")
        }

        let lightningLimits = method == .lightning ? try? sdk.fetchLightningLimits() : nil
        return ReceiveRequest(
            method: method,
            destination: response.destination,
            feeSat: Int64(prepared.feesSat),
            minimum: prepared.minPayerAmountSat.map { TipMeCore.Amount.sats(Int64($0)) }
                ?? lightningLimits.map { .sats(Int64($0.receive.minSat)) },
            maximum: prepared.maxPayerAmountSat.map { TipMeCore.Amount.sats(Int64($0)) }
                ?? lightningLimits.map { .sats(Int64($0.receive.maxSat)) })
    }

    // MARK: - History

    public func transactionHistory(limit: Int) async throws -> [WalletTransaction] {
        let sdk = try requireSDK()
        let payments: [Payment]
        do {
            payments = try sdk.listPayments(req: ListPaymentsRequest(
                filters: nil, states: nil, fromTimestamp: nil, toTimestamp: nil,
                offset: 0, limit: UInt32(limit), details: nil, sortAscending: false))
        } catch {
            throw PaymentBackendError.network("could not list payments: \(error)")
        }
        return payments.map(Self.transaction(from:))
    }

    private static func transaction(from payment: Payment) -> WalletTransaction {
        let usdtID = assetID(for: .usdt, network: .mainnet) // testnet id checked below too
        let (asset, amount, fee): (Asset, TipMeCore.Amount, TipMeCore.Amount) = {
            if case .liquid(let assetId, _, _, let info, _, _, _) = payment.details,
               (assetId == usdtID || assetId == assetID(for: .usdt, network: .testnet)),
               let info {
                let feeAmount = info.fees.map { TipMeCore.Amount.usdtCents(Int64(($0 * 100).rounded())) }
                    ?? .sats(Int64(payment.feesSat))
                return (.usdt, .usdtCents(Int64((info.amount * 100).rounded())), feeAmount)
            }
            return (.bitcoin, .sats(Int64(payment.amountSat)), .sats(Int64(payment.feesSat)))
        }()

        let status: WalletTransaction.Status
        switch payment.status {
        case .complete: status = .completed
        case .failed, .timedOut: status = .failed
        default: status = .pending
        }

        let counterparty: String? = {
            switch payment.details {
            case .lightning(_, _, _, _, _, _, _, let pubkey, _, _, _, _, _, _, _): return pubkey
            case .liquid(_, let destination, _, _, _, _, _): return destination
            case .bitcoin(_, let address, _, _, _, _, _, _, _, _): return address
            }
        }()

        let note: String? = {
            switch payment.details {
            case .lightning(_, let description, _, _, _, _, _, _, _, _, _, _, _, _, _),
                 .liquid(_, _, let description, _, _, _, _),
                 .bitcoin(_, _, let description, _, _, _, _, _, _, _):
                return description.isEmpty ? nil : description
            }
        }()

        return WalletTransaction(
            id: payment.txId ?? "\(payment.timestamp)-\(payment.amountSat)",
            kind: payment.paymentType == .send ? .send : .receive,
            status: status, asset: asset, amount: amount, networkFee: fee,
            counterparty: counterparty, note: note,
            timestamp: Date(timeIntervalSince1970: TimeInterval(payment.timestamp)))
    }
}
