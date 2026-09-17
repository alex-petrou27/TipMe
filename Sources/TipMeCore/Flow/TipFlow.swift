import Foundation

/// What the share sheet should be showing.
public enum TipFlowState: Sendable {
    case parsing
    /// We know who the creator is and they're registered — show the amount picker.
    case ready(CreatorRecord)
    /// Parsed a handle, but nobody has claimed it. Offer manual entry.
    case creatorNotRegistered(CreatorHandle)
    /// Could not get a handle out of the share at all (the Instagram shortcode
    /// case, mostly). Offer manual entry with no creator context.
    case needsManualEntry(reason: String)
    case quoted(CreatorRecord, TipQuote)
    case paying
    case succeeded(TipResult, CreatorRecord)
    case failed(String)
}

/// Drives a single tip from a shared URL to a receipt.
///
/// Lives in core rather than in the extension's view layer so the identical
/// sequence can be driven by the host app, by tests, and (Phase 2) by an App
/// Clip, without any of them re-implementing the ordering of the gates.
public actor TipFlow {
    private let parser: SharedLinkParser
    private let titleParser = ShareTitleParser()
    private let shortLinkResolver: ShortLinkResolver
    private let pageMetadataFetcher: PageMetadataFetching
    private let creatorResolver: CreatorResolver
    private let backend: PaymentBackend
    private let quoteBuilder: TipQuoteBuilder
    private let gate: AuthorizationGate
    private let engine: PaymentEngine
    private let auditLog: AuditLog
    private let clock: Clock
    private let fiatCurrency: String
    private let origin: PaymentIntent.Origin

    public init(parser: SharedLinkParser = SharedLinkParser(),
                shortLinkResolver: ShortLinkResolver,
                pageMetadataFetcher: PageMetadataFetching = URLSessionPageMetadataFetcher(),
                creatorResolver: CreatorResolver,
                backend: PaymentBackend,
                quoteBuilder: TipQuoteBuilder,
                gate: AuthorizationGate,
                engine: PaymentEngine,
                auditLog: AuditLog,
                clock: Clock = SystemClock(),
                fiatCurrency: String = "GBP",
                origin: PaymentIntent.Origin = .shareExtension) {
        self.parser = parser
        self.shortLinkResolver = shortLinkResolver
        self.pageMetadataFetcher = pageMetadataFetcher
        self.creatorResolver = creatorResolver
        self.backend = backend
        self.quoteBuilder = quoteBuilder
        self.gate = gate
        self.engine = engine
        self.auditLog = auditLog
        self.clock = clock
        self.fiatCurrency = fiatCurrency
        self.origin = origin
    }

    // MARK: - Step 1: work out who was shared

    /// Resolves whatever the share sheet gave us into a creator, following one
    /// redirect for short links.
    ///
    /// - Parameter titles: the share item's own title and any link-metadata
    ///   title. These matter more than they look: Instagram's share sheet
    ///   header reads "Reel from @username", which is the only place the handle
    ///   appears for a shortcode Reel or post.
    ///
    /// Never throws for the ordinary sad paths — an unparseable link and an
    /// unregistered creator are both expected outcomes with their own UI, not
    /// errors. The share sheet should never show the user a stack of jargon
    /// because they tipped from a Reel.
    public func identify(attachedURLs: [URL],
                         sharedText: [String],
                         titles: [String] = []) async -> TipFlowState {
        let extractor = SharedPayloadExtractor()
        let candidates = extractor.candidateURLs(attachedURLs: attachedURLs, sharedText: sharedText)

        guard var link = extractor.bestLink(from: candidates, parser: parser) else {
            await note(.linkParsed, .rejected, detail: "no recognised TikTok or Instagram link in share")
            return .needsManualEntry(reason: "That link isn't a TikTok or Instagram post we recognise.")
        }

        if link.needsRedirectResolution {
            do {
                link = try await shortLinkResolver.resolve(link)
            } catch {
                await note(.linkParsed, .failed, detail: "short link resolution failed: \(error)")
                return .needsManualEntry(reason: "Couldn't open that short link. You can enter a Lightning address instead.")
            }
        }

        // Captured before any fallback below can adopt a handle from
        // elsewhere and also stamp a `.url` source — this distinguishes "the
        // share's own link named the creator" (logged below) from a handle
        // recovered later that happens to carry the same trust level.
        let handleWasInTheOriginalLink = link.handle != nil

        // The URL is the preferred source, but a shortcode Reel or post has no
        // handle in it. The share title usually does — "Reel from @natgeo" —
        // so fall back to that before giving up on identifying the creator.
        if link.handle == nil,
           let fromTitle = titleParser.handle(inAnyOf: titles, platform: link.platform) {
            link = link.adoptingHandle(fromTitle, from: .shareTitle)
            await note(.linkParsed, .ok, platform: link.platform.rawValue,
                       handle: fromTitle.username, detail: "handle recovered from share title")
        }

        // Confirmed on a real device: Instagram hands the extension a bare
        // URL and nothing else — no title, no text. iOS's own share-sheet
        // preview text ("Reel from username") is never passed down. The
        // last resort is fetching the page ourselves.
        var fetchedTitle: String?
        var fetchedCanonicalURL: URL?
        var fetchError: String?
        if link.handle == nil {
            do {
                let metadata = try await pageMetadataFetcher.metadata(for: link.canonicalURL)
                fetchedTitle = metadata.title
                fetchedCanonicalURL = metadata.canonicalURL

                // Confirmed on a second real-device fetch: Instagram's title
                // is the account's *display name* ("Pepsi UK on Instagram: …"),
                // not its @username -- so it can't be parsed into a handle to
                // pay. The page's own canonical URL is more reliable: it names
                // the actual username in its path, the same shape a directly
                // shared profile link already carries, so try that first and
                // only fall back to the (unreliable) title.
                if let canonicalURL = metadata.canonicalURL,
                   let recovered = parser.parse(canonicalURL), recovered.platform == link.platform,
                   let fromURL = recovered.handle {
                    link = link.adoptingHandle(fromURL, from: .url)
                    await note(.linkParsed, .ok, platform: link.platform.rawValue,
                               handle: fromURL.username, detail: "handle recovered from fetched canonical URL")
                } else if let fetchedTitle, let fromFetch = titleParser.handle(in: fetchedTitle, platform: link.platform) {
                    link = link.adoptingHandle(fromFetch, from: .shareTitle)
                    await note(.linkParsed, .ok, platform: link.platform.rawValue,
                               handle: fromFetch.username, detail: "handle recovered from fetched page title")
                }
            } catch {
                fetchError = String(describing: error)
            }
        }

        guard let handle = link.handle else {
            await note(.linkParsed, .rejected,
                       platform: link.platform.rawValue,
                       detail: "link carried no handle (kind: \(link.kind.rawValue)) and no title named one")
            return .needsManualEntry(reason: Self.noHandleExplanation(
                for: link, titles: titles, text: sharedText, urls: attachedURLs,
                fetchedTitle: fetchedTitle, fetchedCanonicalURL: fetchedCanonicalURL, fetchError: fetchError))
        }

        if handleWasInTheOriginalLink, link.handleSource == .url {
            await note(.linkParsed, .ok, platform: handle.platform.rawValue, handle: handle.username)
        }

        do {
            let record = try await creatorResolver.resolve(handle)
            await note(.creatorResolved, .ok, platform: handle.platform.rawValue, handle: handle.username)
            return .ready(record)
        } catch CreatorLookupError.notRegistered {
            await note(.creatorResolved, .rejected, platform: handle.platform.rawValue,
                       handle: handle.username, detail: "not registered")
            return .creatorNotRegistered(handle)
        } catch {
            await note(.creatorResolved, .failed, platform: handle.platform.rawValue,
                       handle: handle.username, detail: String(describing: error))
            return .failed("Couldn't look up \(handle.displayName) right now.")
        }
    }

    /// Reached only when neither the URL nor the share title named a creator,
    /// which is now uncommon — most shortcode Reels and posts are identified
    /// from the title.
    private static func noHandleExplanation(for link: SharedLink, titles: [String],
                                            text: [String], urls: [URL],
                                            fetchedTitle: String?, fetchedCanonicalURL: URL?,
                                            fetchError: String?) -> String {
        let base: String
        switch link.platform {
        case .instagram:
            base = "We couldn't tell whose Reel that is. Try sharing from the creator's profile, or enter their Lightning address below."
        case .tiktok:
            base = "That TikTok link doesn't include the creator's username. Try sharing the video itself, or enter their Lightning address below."
        }
        // TEMPORARY diagnostic: shows exactly what the share extension
        // actually received, and what the page-fetch fallback actually
        // returned, so a real failure can be compared against what the
        // parser expects instead of guessed at blind. Remove once the
        // Instagram title-sourcing question is settled either way.
        func dump(_ label: String, _ values: [String]) -> String {
            let joined = values.isEmpty ? "(none)" : values.map { "\"\($0)\"" }.joined(separator: " | ")
            return "\(label): \(joined)"
        }
        let urlStrings = urls.map(\.absoluteString)
        let fetchLine: String = {
            if let fetchError { return "fetched page: error (\(fetchError))" }
            if fetchedTitle == nil && fetchedCanonicalURL == nil { return "fetched page: (not attempted)" }
            let titlePart = fetchedTitle.map { "title: \"\($0)\"" } ?? "title: (none)"
            let urlPart = fetchedCanonicalURL.map { "canonical url: \($0.absoluteString)" } ?? "canonical url: (none)"
            return "fetched page: \(titlePart) / \(urlPart)"
        }()
        return base + "\n\n[debug] " + [
            dump("titles", titles),
            dump("text", text),
            dump("urls", urlStrings),
            fetchLine,
        ].joined(separator: "\n[debug] ")
    }

    /// Manual fallback: the user pastes a Lightning address directly.
    public func manualRecipient(address rawAddress: String,
                                handle: CreatorHandle?,
                                preferredAsset: Asset = .bitcoin) -> TipFlowState {
        guard let address = LightningAddress(rawAddress) else {
            return .failed("That doesn't look like a Lightning address. It should look like name@wallet.com.")
        }
        let record = CreatorRecord(handle: handle ?? CreatorHandle(platform: .tiktok, rawUsername: "manual")!,
                                   lightningAddress: address,
                                   preferredAsset: preferredAsset,
                                   updatedAt: clock.now,
                                   displayName: address.description,
                                   // A pasted address has not been verified by
                                   // anyone; the confirm screen must say so.
                                   verified: false)
        return .ready(record)
    }

    // MARK: - Step 2: price it

    /// Builds the quote the confirm screen renders and the engine spends from.
    public func quote(tip: Amount, for creator: CreatorRecord) async -> TipFlowState {
        if let minimum = creator.minimumTipMinorUnits {
            let minimumAmount = Amount(asset: creator.preferredAsset, minorUnits: minimum)
            if creator.preferredAsset == tip.asset, tip < minimumAmount {
                return .failed("\(creator.handle.displayName) accepts tips of \(minimumAmount.formatted) or more.")
            }
        }

        do {
            let route = try await backend.prepareRoute(tip: tip,
                                                       to: creator.lightningAddress,
                                                       receiveAsset: creator.preferredAsset)
            let rate = try await backend.rate(for: tip.asset, in: fiatCurrency)
            let quote = try quoteBuilder.quote(tip: tip, route: route, sendRate: rate)
            await note(.quotePrepared, .ok,
                       platform: creator.handle.platform.rawValue,
                       handle: creator.handle.username,
                       detail: quote.disclosure)
            return .quoted(creator, quote)
        } catch let error as PaymentBackendError {
            return .failed(Self.describe(error))
        } catch {
            return .failed("Couldn't price that tip. Try again in a moment.")
        }
    }

    // MARK: - Step 3: confirm and pay

    /// Face ID, then spend. There is no variant of this that skips the prompt.
    public func confirmAndPay(quote: TipQuote,
                              creator: CreatorRecord,
                              sourceLink: URL?) async -> TipFlowState {
        let intent = PaymentIntent(quote: quote,
                                   creator: creator,
                                   sourceLink: sourceLink,
                                   origin: origin,
                                   createdAt: clock.now)

        let authorized: AuthorizedIntent
        do {
            authorized = try await gate.authorize(intent)
        } catch AuthorizationError.declined(let outcome) {
            switch outcome {
            case .userCancelled:
                return .quoted(creator, quote) // back to the confirm screen
            case .unavailable(let reason):
                return .failed("Face ID isn't available: \(reason)")
            default:
                return .failed("Confirmation failed. Nothing has been sent.")
            }
        } catch {
            return .failed("Confirmation failed. Nothing has been sent.")
        }

        do {
            let result = try await engine.execute(authorized)
            return .succeeded(result, creator)
        } catch let error as PaymentEngineError {
            return .failed(Self.describe(error))
        } catch {
            return .failed("The payment didn't go through. Nothing has been sent.")
        }
    }

    // MARK: - Error phrasing

    static func describe(_ error: PaymentEngineError) -> String {
        switch error {
        case .intentExpired:
            return "That confirmation timed out. Tap to try again."
        case .intentAlreadyExecuted:
            return "That tip has already been sent."
        case .rateStale:
            return "The exchange rate moved while you were confirming. Check the new amount and try again."
        case .conversionQuoteStale:
            return "The conversion quote expired. Check the new amount and try again."
        case .capExceeded(let decision):
            return decision.userFacingReason ?? "That's over your send limit."
        case .rateLimited(let decision):
            return decision.userFacingReason ?? "You're tipping too quickly."
        case .insufficientFunds(let available, let required):
            return "You need \(required.formatted) but only have \(available.formatted)."
        case .creatorMinimumNotMet(let minimum):
            return "This creator's minimum tip is \(minimum.formatted)."
        case .backend(let backendError):
            return describe(backendError)
        }
    }

    static func describe(_ error: PaymentBackendError) -> String {
        switch error {
        case .notConnected:
            return "Wallet isn't ready. Open TipMe once, then try again."
        case .insufficientFunds(let available, let required):
            return "You need \(required.formatted) but only have \(available.formatted)."
        case .destinationUnreachable(let detail):
            return "Couldn't reach that wallet (\(detail))."
        case .amountBelowDestinationMinimum(let minimum):
            return "Their wallet's minimum is \(minimum.formatted)."
        case .amountAboveDestinationMaximum(let maximum):
            return "Their wallet's maximum is \(maximum.formatted)."
        case .conversionUnavailable(let from, let to):
            return "Can't convert \(from.symbol) to \(to.symbol) right now."
        case .routeExpired:
            return "That quote expired. Try again."
        case .network(let detail), .rejectedByNetwork(let detail):
            return "Payment failed: \(detail)"
        }
    }

    private func note(_ stage: AuditEvent.Stage, _ outcome: AuditEvent.Outcome,
                      platform: String? = nil, handle: String? = nil, detail: String? = nil) async {
        await auditLog.append(AuditEvent(timestamp: clock.now,
                                         intentID: "-",
                                         stage: stage,
                                         outcome: outcome,
                                         origin: origin.rawValue,
                                         platform: platform,
                                         handle: handle,
                                         detail: detail))
    }
}
