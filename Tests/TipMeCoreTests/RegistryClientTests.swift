import XCTest
import CryptoKit
@testable import TipMeCore

/// The registry's answer *is* the destination of the money, so these tests are
/// about one question: can anything other than our registry decide where a tip
/// goes?
final class RegistryClientTests: XCTestCase {

    private let signingKey = Curve25519.Signing.PrivateKey()
    private let clock = MutableClock()

    private func makeClient(maximumResponseAge: TimeInterval = 300,
                            publicKey: Data? = nil) -> RegistryClient {
        RegistryClient(
            configuration: .init(baseURL: URL(string: "https://registry.tipme.example")!,
                                 signingPublicKey: publicKey ?? signingKey.publicKey.rawRepresentation,
                                 maximumResponseAge: maximumResponseAge),
            clock: clock)
    }

    private func makeEnvelope(platform: Platform = .tiktok,
                              username: String = "creator",
                              lightningAddress: String = "creator@getalby.com",
                              preferredAsset: Asset = .bitcoin,
                              hasPhoto: Bool = false,
                              signedAt: Date? = nil,
                              signWith key: Curve25519.Signing.PrivateKey? = nil)
    throws -> RegistryClient.SignedEnvelope {
        let payload = RegistryClient.RegistryPayload(
            platform: platform,
            username: username,
            lightningAddress: lightningAddress,
            preferredAsset: preferredAsset,
            minimumTipMinorUnits: nil,
            displayName: username,
            verified: true,
            hasPhoto: hasPhoto,
            updatedAt: clock.now,
            signedAt: signedAt ?? clock.now)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(payload)

        let signature = try (key ?? signingKey).signature(for: bytes)
        return RegistryClient.SignedEnvelope(payload: bytes.base64EncodedString(),
                                             signature: signature.base64EncodedString())
    }

    private func handle(_ username: String = "creator", _ platform: Platform = .tiktok) -> CreatorHandle {
        CreatorHandle(platform: platform, rawUsername: username)!
    }

    // MARK: -

    func testValidSignedRecordIsAccepted() throws {
        let record = try makeClient().verify(try makeEnvelope(), expecting: handle())
        XCTAssertEqual(record.lightningAddress.description, "creator@getalby.com")
        XCTAssertTrue(record.verified)
        XCTAssertNil(record.photoURL)
    }

    func testHasPhotoBuildsAPhotoURLUnderTheSameRegistry() throws {
        let record = try makeClient().verify(try makeEnvelope(hasPhoto: true), expecting: handle())
        XCTAssertEqual(record.photoURL, URL(string: "https://registry.tipme.example/v1/creators/tiktok/creator/photo"))
    }

    /// The attack this stops: a hostile network, a compromised CDN, or a DNS
    /// hijack swapping the creator's address for the attacker's. TLS alone
    /// would not, because it trusts whoever holds a certificate for the host.
    func testRecordSignedByTheWrongKeyIsRejected() throws {
        let attacker = Curve25519.Signing.PrivateKey()
        let envelope = try makeEnvelope(lightningAddress: "attacker@evil.example", signWith: attacker)

        XCTAssertThrowsError(try makeClient().verify(envelope, expecting: handle())) { error in
            XCTAssertEqual(error as? CreatorLookupError, .signatureInvalid)
        }
    }

    func testTamperedPayloadIsRejected() throws {
        var envelope = try makeEnvelope()
        // Re-sign nothing; just swap the payload for a different valid one.
        let other = try makeEnvelope(lightningAddress: "attacker@evil.example")
        envelope = RegistryClient.SignedEnvelope(payload: other.payload, signature: envelope.signature)

        XCTAssertThrowsError(try makeClient().verify(envelope, expecting: handle())) { error in
            XCTAssertEqual(error as? CreatorLookupError, .signatureInvalid)
        }
    }

    /// A correctly-signed record for a *different* creator is still a valid
    /// signature. Without this check, a registry bug or a swapped response pays
    /// the wrong person.
    func testCorrectlySignedRecordForADifferentCreatorIsRejected() throws {
        let envelope = try makeEnvelope(username: "someoneelse")

        XCTAssertThrowsError(try makeClient().verify(envelope, expecting: handle("creator"))) { error in
            guard case .responseMalformed(let detail)? = error as? CreatorLookupError else {
                return XCTFail("expected responseMalformed, got \(error)")
            }
            XCTAssertTrue(detail.contains("different handle"))
        }
    }

    func testRecordForTheRightNameOnTheWrongPlatformIsRejected() throws {
        let envelope = try makeEnvelope(platform: .instagram, username: "creator")
        XCTAssertThrowsError(try makeClient().verify(envelope, expecting: handle("creator", .tiktok)))
    }

    /// Stops a captured response being replayed after a creator has moved wallet.
    func testStaleSignatureIsRejected() throws {
        let envelope = try makeEnvelope(signedAt: clock.now.addingTimeInterval(-3_600))

        XCTAssertThrowsError(try makeClient(maximumResponseAge: 300).verify(envelope, expecting: handle())) { error in
            guard case .responseMalformed(let detail)? = error as? CreatorLookupError else {
                return XCTFail("expected responseMalformed, got \(error)")
            }
            XCTAssertTrue(detail.contains("old"))
        }
    }

    func testMalformedLightningAddressInASignedRecordIsStillRejected() throws {
        // Even a legitimately signed record must not put garbage on the payment path.
        let envelope = try makeEnvelope(lightningAddress: "not-an-address")
        XCTAssertThrowsError(try makeClient().verify(envelope, expecting: handle()))
    }

    func testNonBase64FieldsAreRejected() {
        let envelope = RegistryClient.SignedEnvelope(payload: "!!!not base64!!!", signature: "???")
        XCTAssertThrowsError(try makeClient().verify(envelope, expecting: handle()))
    }
}

final class CachingCreatorResolverTests: XCTestCase {

    private actor CountingResolver: CreatorResolver {
        private(set) var calls = 0
        func resolve(_ handle: CreatorHandle) async throws -> CreatorRecord {
            calls += 1
            return .stub(username: handle.username)
        }
        func callCount() -> Int { calls }
    }

    func testRepeatLookupsAreServedFromCache() async throws {
        let upstream = CountingResolver()
        let clock = MutableClock()
        let resolver = CachingCreatorResolver(upstream: upstream, clock: clock, ttl: 600)
        let handle = CreatorHandle(platform: .tiktok, rawUsername: "creator")!

        _ = try await resolver.resolve(handle)
        _ = try await resolver.resolve(handle)

        let calls = await upstream.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testCacheExpires() async throws {
        let upstream = CountingResolver()
        let clock = MutableClock()
        let resolver = CachingCreatorResolver(upstream: upstream, clock: clock, ttl: 600)
        let handle = CreatorHandle(platform: .tiktok, rawUsername: "creator")!

        _ = try await resolver.resolve(handle)
        clock.advance(by: 601)
        _ = try await resolver.resolve(handle)

        let calls = await upstream.callCount()
        XCTAssertEqual(calls, 2,
                       "a creator may have changed wallet; the cache must not be permanent")
    }

    /// The share extension is memory-capped, so an unbounded cache there is a
    /// crash rather than a speedup.
    func testCacheIsBounded() async throws {
        let upstream = CountingResolver()
        let clock = MutableClock()
        let resolver = CachingCreatorResolver(upstream: upstream, clock: clock, ttl: 600, capacity: 2)

        for name in ["a", "b", "c"] {
            _ = try await resolver.resolve(CreatorHandle(platform: .tiktok, rawUsername: name)!)
        }
        // "a" should have been evicted, so resolving it again hits upstream.
        _ = try await resolver.resolve(CreatorHandle(platform: .tiktok, rawUsername: "a")!)
        let calls = await upstream.callCount()
        XCTAssertEqual(calls, 4)
    }
}
