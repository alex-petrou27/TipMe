import Foundation

/// What the registry knows about a creator.
///
/// The handle-to-wallet link is made once, when the creator onboards, and
/// persists until they delete it — senders never re-establish it per payment.
public struct CreatorRecord: Equatable, Codable, Sendable {
    public let handle: CreatorHandle
    /// Where tips are delivered.
    public let lightningAddress: LightningAddress
    /// What the creator has chosen to actually receive. A sender paying in USDT
    /// to a creator who wants Bitcoin is converted in flight; see
    /// `SettlementRoute`.
    public let preferredAsset: Asset
    /// Creator-set floor, if any, in their preferred asset's minor units.
    public let minimumTipMinorUnits: Int64?
    /// Server-side timestamp; used to reject replayed registry responses.
    public let updatedAt: Date
    /// Display name for the confirm screen, if the creator supplied one.
    public let displayName: String?
    /// Whether the creator has verified ownership of the social handle. An
    /// unverified record is still payable but the UI must say so — otherwise
    /// anyone could register `@charlidamelio` and collect her tips.
    public let verified: Bool
    /// Where the confirm screen can fetch the creator's photo, if they set
    /// one. Built by `RegistryClient` from the signed record's `has_photo`
    /// flag, not carried in the signature itself — cosmetic only, so it rides
    /// an ordinary HTTPS GET rather than the Ed25519-verified payment fields.
    public let photoURL: URL?
    /// Set when this handle is linked straight to a TipMe account's own
    /// balance (see `POST /v1/me/creators`) rather than an external wallet.
    /// A tip to a record like this is a ledger transfer inside TipMe, never
    /// a real Lightning send — see `CustodialPaymentBackend`'s handling of
    /// `lightningAddress` for how that stays plumbed through the existing
    /// send pipeline (caps, Face ID, audit log) without a parallel path.
    public let tipmeUserID: String?

    public init(handle: CreatorHandle,
                lightningAddress: LightningAddress,
                preferredAsset: Asset,
                minimumTipMinorUnits: Int64? = nil,
                updatedAt: Date,
                displayName: String? = nil,
                verified: Bool,
                photoURL: URL? = nil,
                tipmeUserID: String? = nil) {
        self.handle = handle
        self.lightningAddress = lightningAddress
        self.preferredAsset = preferredAsset
        self.minimumTipMinorUnits = minimumTipMinorUnits
        self.updatedAt = updatedAt
        self.displayName = displayName
        self.verified = verified
        self.photoURL = photoURL
        self.tipmeUserID = tipmeUserID
    }
}

/// Encodes a TipMe user id into a syntactically-valid `LightningAddress` and
/// back, so a `tipmeUserID`-linked creator can flow through the entire
/// existing send pipeline (`PaymentBackend.prepareRoute`/`send`, the Face
/// ID gate, spend caps, the audit log) unchanged — those all key off a
/// `LightningAddress`, and duplicating that whole pipeline for one
/// alternate destination type would be a second, parallel place for the
/// same bugs to hide. `CustodialPaymentBackend` is the one place that
/// decodes this back out, right where it decides whether to actually send
/// over Lightning or do a `transfer_balance` ledger move instead.
enum InternalTipDestination {
    static let domain = "tipme.internal"

    /// Encodes the *handle*, not the user id. `POST /v1/me/tip` re-resolves
    /// by platform/username server-side rather than trusting a client-held
    /// id — the same "don't trust a snapshot taken at quote time" instinct
    /// `RateFreshness` applies to the exchange rate elsewhere in this
    /// module, here applied to "does this handle still point at the same
    /// account it did when the quote was built."
    static func address(platform: Platform, username: String) -> LightningAddress? {
        // Usernames are `[A-Za-z0-9._]+` (see ShareTitleParser/handles.py) --
        // no `-`, so it is a safe, unambiguous delimiter here. Still guarded
        // with `?` rather than `!`: this is the one place a value that
        // hasn't already been through `CreatorHandle` validation could reach
        // this encoder if that ever changes.
        LightningAddress("u-\(platform.rawValue)-\(username)@\(domain)")
    }

    static func handle(in address: LightningAddress) -> (platform: Platform, username: String)? {
        guard address.domain == domain, address.name.hasPrefix("u-") else { return nil }
        let rest = address.name.dropFirst(2)
        guard let separator = rest.firstIndex(of: "-") else { return nil }
        let platformRaw = String(rest[rest.startIndex..<separator])
        let username = String(rest[rest.index(after: separator)...])
        guard let platform = Platform(rawValue: platformRaw), !username.isEmpty else { return nil }
        return (platform, username)
    }
}

public enum CreatorLookupError: Error, Equatable, Sendable {
    /// Handle parsed fine, but nobody has claimed it. This is the common case
    /// and must be a friendly dead end with manual entry, not an error screen.
    case notRegistered(CreatorHandle)
    case signatureInvalid
    case responseMalformed(String)
    case transport(String)
    case offline
}

/// Where a creator's payment details come from.
///
/// A protocol rather than a concrete client so the share extension can be
/// driven from fixtures in tests, and so a future on-device cache or an
/// alternative directory can be dropped in without touching the payment path.
public protocol CreatorResolver: Sendable {
    func resolve(_ handle: CreatorHandle) async throws -> CreatorRecord
}
