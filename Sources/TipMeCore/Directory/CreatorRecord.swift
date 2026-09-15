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

    public init(handle: CreatorHandle,
                lightningAddress: LightningAddress,
                preferredAsset: Asset,
                minimumTipMinorUnits: Int64? = nil,
                updatedAt: Date,
                displayName: String? = nil,
                verified: Bool) {
        self.handle = handle
        self.lightningAddress = lightningAddress
        self.preferredAsset = preferredAsset
        self.minimumTipMinorUnits = minimumTipMinorUnits
        self.updatedAt = updatedAt
        self.displayName = displayName
        self.verified = verified
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
