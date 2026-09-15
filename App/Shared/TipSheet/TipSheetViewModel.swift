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
    @Published var selectedAsset: Asset = .bitcoin

    /// Preset tips, in the sender's asset. Chosen so the common case is one tap.
    @Published private(set) var presets: [Amount] = [.sats(1_000), .sats(2_000), .sats(5_000), .sats(10_000)]
    @Published var customAmountText: String = ""

    private let services: TipMeServices
    private let flow: TipFlow
    private let onFinish: () -> Void
    private var sourceLink: URL?

    init(services: TipMeServices,
         origin: PaymentIntent.Origin,
         onFinish: @escaping () -> Void) {
        self.services = services
        self.flow = services.makeFlow(origin: origin)
        self.onFinish = onFinish
    }

    // MARK: - Step 1: identify

    func start(with payload: SharedPayload) async {
        sourceLink = payload.urls.first
        screen = .loading("Reading link…")

        // Connect while we parse — these are independent, and in an extension
        // the user is watching a spinner for every millisecond we serialise
        // work that didn't need to be serialised.
        async let connected: Void = connectWallet()
        let state = await flow.identify(attachedURLs: payload.urls,
                                        sharedText: payload.text,
                                        titles: payload.titles)
        await connected

        apply(state)
    }

    private func connectWallet() async {
        do {
            try await services.backend.connect()
            try await services.backend.sync()
        } catch {
            // Surfaced when the first payment is attempted rather than here —
            // a connection warning over someone's feed before they have even
            // chosen an amount is noise.
        }
    }

    // MARK: - Step 2: amount

    func selectAmount(_ amount: Amount) async {
        guard case .amount(let creator) = screen else { return }
        screen = .loading("Checking amount…")
        apply(await flow.quote(tip: amount, for: creator))
    }

    func selectCustomAmount() async {
        guard case .amount(let creator) = screen else { return }
        guard let value = Int64(customAmountText.filter(\.isNumber)), value > 0 else {
            screen = .error("Enter a whole number of \(selectedAsset.symbol).")
            return
        }
        screen = .loading("Checking amount…")
        apply(await flow.quote(tip: Amount(asset: selectedAsset, minorUnits: value), for: creator))
    }

    func changeAsset(_ asset: Asset) {
        selectedAsset = asset
        presets = asset == .bitcoin
            ? [.sats(1_000), .sats(2_000), .sats(5_000), .sats(10_000)]
            : [.usdtCents(50), .usdtCents(100), .usdtCents(250), .usdtCents(500)]
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
        Task { await services.backend.disconnect() }
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
