import Foundation
import SwiftUI
import TipMeCore

/// Whatever a surface managed to collect about what the user is tipping on.
///
/// Shared because two surfaces produce one: the share extension (from
/// `NSExtensionItem` attachments) and the host app's paste flow (from a link
/// the user copied with TikTok's or Instagram's own "Copy link" button).
struct SharedPayload: Sendable {
    let urls: [URL]
    let text: [String]
    /// The share item's own title, plus any link-metadata title.
    ///
    /// Carried separately from `text` because it is the only place an
    /// Instagram Reel's creator appears — the share sheet header reads
    /// "Reel from @username" — and because a title is a far more trustworthy
    /// place to look for a handle than a caption, which may tag other accounts.
    let titles: [String]

    init(urls: [URL], text: [String], titles: [String] = []) {
        self.urls = urls
        self.text = text
        self.titles = titles
    }

    static let empty = SharedPayload(urls: [], text: [], titles: [])
}

/// Drives the share sheet.
///
/// Holds no payment logic of its own — every decision comes from `TipFlow` in
/// core. The view model's job is to turn flow states into something renderable
/// and to keep the amount picker's arithmetic identical to the engine's, by
/// never doing any arithmetic of its own.
@MainActor
final class TipSheetViewModel: ObservableObject {

    enum Screen {
        case loading(String)
        case amount(CreatorRecord)
        case manualEntry(reason: String, handle: CreatorHandle?)
        case confirm(CreatorRecord, TipQuote)
        case paying
        case receipt(TipResult, CreatorRecord)
        case error(String)
    }

    @Published private(set) var screen: Screen = .loading("Reading link…")
    @Published var manualAddress: String = ""

    /// Preset tips, in the currency the sender actually thinks in -- never an
    /// asset. There is no "which crypto do you want to send" choice anywhere
    /// in this flow: a tip always settles in whatever the creator already
    /// asked to be paid in (`CreatorRecord.preferredAsset`), converted at
    /// spend time. The sender never sees or picks that asset -- see
    /// `selectAmount`.
    @Published private(set) var presets: [FiatAmount]
    @Published var customAmountText: String = ""

    private let services: TipMeServices
    private let flow: TipFlow
    private let onFinish: () -> Void
    private var sourceLink: URL?
    /// The sender's own currency -- `AppConfiguration.fiatCurrency` defaults
    /// to the device's locale, not a hardcoded one, so this reads as "how
    /// much" in whatever currency the sender actually uses day to day.
    private let fiatCurrency: String

    init(services: TipMeServices,
         origin: PaymentIntent.Origin,
         onFinish: @escaping () -> Void) {
        self.services = services
        self.flow = services.makeFlow(origin: origin)
        self.onFinish = onFinish
        let currency = services.configuration.fiatCurrency
        self.fiatCurrency = currency
        self.presets = Self.defaultPresets(currencyCode: currency)
    }

    private static func defaultPresets(currencyCode: String) -> [FiatAmount] {
        [100, 200, 500, 1_000].map { FiatAmount(currencyCode: currencyCode, minorUnits: $0) }
    }

    // MARK: - Step 1: identify

    func start(with payload: SharedPayload) async {
        sourceLink = payload.urls.first
        screen = .loading("Reading link…")
        let state = await flow.identify(attachedURLs: payload.urls,
                                        sharedText: payload.text,
                                        titles: payload.titles)
        apply(state)
    }

    // MARK: - Step 2: amount

    /// Converts a fiat figure into whatever the creator actually gets paid
    /// in, at the current rate, then quotes exactly that -- the one place a
    /// dollar amount ever becomes a crypto one in this flow.
    func selectAmount(_ fiat: FiatAmount) async {
        guard case .amount(let creator) = screen else { return }
        screen = .loading("Checking amount…")
        do {
            let rate = try await services.backend.rate(for: creator.preferredAsset, in: fiatCurrency)
            apply(await flow.quote(tip: rate.assetAmount(for: fiat), for: creator))
        } catch {
            screen = .error("Couldn't price that tip. Try again in a moment.")
        }
    }

    func selectCustomAmount() async {
        let normalised = customAmountText.replacingOccurrences(of: ",", with: ".")
        guard let value = Decimal(string: normalised), value > 0 else {
            screen = .error("Enter an amount.")
            return
        }
        let minorUnits = NSDecimalNumber(decimal: value * 100).int64Value
        await selectAmount(FiatAmount(currencyCode: fiatCurrency, minorUnits: minorUnits))
    }

    // MARK: - Manual fallback

    func submitManualAddress() async {
        guard case .manualEntry(_, let handle) = screen else { return }
        apply(await flow.manualRecipient(address: manualAddress, handle: handle))
    }

    // MARK: - Step 3: confirm

    func confirm() async {
        guard case .confirm(let creator, let quote) = screen else { return }
        screen = .paying
        apply(await flow.confirmAndPay(quote: quote, creator: creator, sourceLink: sourceLink))
    }

    func backToAmount() {
        if case .confirm(let creator, _) = screen {
            screen = .amount(creator)
        }
    }

    func dismiss() {
        onFinish()
    }

    // MARK: - State mapping

    private func apply(_ state: TipFlowState) {
        switch state {
        case .parsing:
            screen = .loading("Reading link…")
        case .ready(let creator):
            screen = .amount(creator)
        case .creatorNotRegistered(let handle):
            screen = .manualEntry(
                reason: "\(handle.displayName) hasn't set up TipMe yet. You can still tip them if you know their Lightning address.",
                handle: handle)
        case .needsManualEntry(let reason):
            screen = .manualEntry(reason: reason, handle: nil)
        case .quoted(let creator, let quote):
            screen = .confirm(creator, quote)
        case .paying:
            screen = .paying
        case .succeeded(let result, let creator):
            screen = .receipt(result, creator)
        case .failed(let message):
            screen = .error(message)
        }
    }
}
