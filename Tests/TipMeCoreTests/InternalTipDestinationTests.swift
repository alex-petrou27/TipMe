import XCTest
@testable import TipMeCore

/// The synthetic-address encoding that lets a TipMe-account-linked creator
/// flow through the same `LightningAddress`-keyed send pipeline as a real
/// external wallet, without a parallel code path. See CreatorRecord.swift.
final class InternalTipDestinationTests: XCTestCase {
    func testRoundTripsPlatformAndUsername() {
        let address = InternalTipDestination.address(platform: .instagram, username: "natgeo")
        XCTAssertNotNil(address)

        let decoded = InternalTipDestination.handle(in: address!)
        XCTAssertEqual(decoded?.platform, .instagram)
        XCTAssertEqual(decoded?.username, "natgeo")
    }

    func testRoundTripsUsernamesWithDotsAndUnderscores() {
        let address = InternalTipDestination.address(platform: .tiktok, username: "a.b_c123")
        let decoded = InternalTipDestination.handle(in: address!)
        XCTAssertEqual(decoded?.username, "a.b_c123")
    }

    func testARealExternalLightningAddressIsNotMistakenForAnInternalOne() {
        let real = LightningAddress("natgeo@getalby.com")!
        XCTAssertNil(InternalTipDestination.handle(in: real))
    }

    func testDifferentPlatformsWithTheSameUsernameEncodeDifferently() {
        let instagram = InternalTipDestination.address(platform: .instagram, username: "same")!
        let tiktok = InternalTipDestination.address(platform: .tiktok, username: "same")!
        XCTAssertNotEqual(instagram, tiktok)
    }
}
