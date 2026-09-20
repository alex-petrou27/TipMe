import XCTest
@testable import TipMeCore

final class FeePolicyTests: XCTestCase {

    private let policy = FeePolicy.standard // 3.00%

    /// The exact example from the product brief: "£1.00 tip + £0.03 fee = £1.03".
    /// At £50,000/BTC a £1.00 tip is 2,000 sats and 3% of that is 60 sats,
    /// which is £0.03. This test exists to keep that headline promise honest.
    func testBriefExampleAddsUp() throws {
        let tip = Amount.sats(2_000)
        let fee = policy.fee(on: tip)
        XCTAssertEqual(fee, .sats(60))

        let rate = AssetRate(asset: .bitcoin, currencyCode: "GBP",
                             scaledPricePerMinorUnit: 5_000_000, asOf: Date())
        XCTAssertEqual(rate.fiatValue(of: tip).formatted, "£1")
        XCTAssertEqual(rate.fiatValue(of: fee).formatted, "£0.03")
        XCTAssertEqual(rate.fiatValue(of: policy.total(on: tip)).formatted, "£1.03")
    }

    func testFeeIsAddedOnTopNeverDeducted() {
        let tip = Amount.sats(10_000)
        XCTAssertEqual(policy.total(on: tip).minorUnits, 10_000 + policy.fee(on: tip).minorUnits,
                       "the creator's amount must be untouched by the fee")
    }

    func testSmallTipsAreWaived() {
        // Below 1,000 sats a 3% fee is a few sats and routing costs more than
        // we would collect, so we charge nothing.
        XCTAssertEqual(policy.fee(on: .sats(999)), .sats(0))
        XCTAssertEqual(policy.fee(on: .sats(1_000)), .sats(30))
    }

    func testFeeIsCappedAtMaximum() {
        let huge = Amount.sats(100_000_000)
        XCTAssertEqual(policy.fee(on: huge), .sats(25_000), "fee must clamp to the configured ceiling")
    }

    func testFeeRoundsHalfUp() {
        // 1,050 sats * 3% = 31.5 -> 32
        XCTAssertEqual(policy.fee(on: .sats(1_050)), .sats(32))
        // 1,010 sats * 3% = 30.3 -> 30
        XCTAssertEqual(policy.fee(on: .sats(1_010)), .sats(30))
    }

    func testZeroAndNegativeTipsProduceNoFee() {
        XCTAssertEqual(policy.fee(on: .sats(0)), .sats(0))
        XCTAssertEqual(policy.fee(on: .sats(-100)), .sats(0))
    }

    func testFeeRateIsConfigurableNotHardcoded() {
        let cheaper = FeePolicy(rateBasisPoints: 100,
                                bitcoin: FeeAssetRule(minimumFee: 0, waiveTipsBelow: 0),
                                usdt: FeeAssetRule(minimumFee: 0, waiveTipsBelow: 0))
        XCTAssertEqual(cheaper.fee(on: .sats(10_000)), .sats(100))
        XCTAssertEqual(cheaper.percentageDescription, "1%")
    }

    func testFeeAppliesPerAssetRules() {
        // USDT uses cents, so its thresholds are different from Bitcoin's.
        XCTAssertEqual(policy.fee(on: .usdtCents(49)), .usdtCents(0), "below the USDT waiver")
        XCTAssertEqual(policy.fee(on: .usdtCents(100)), .usdtCents(3))
    }
}

final class AmountTests: XCTestCase {

    func testFormattingIsAssetAppropriate() {
        XCTAssertEqual(Amount.sats(1_234_567).formatted, "1,234,567 sats")
        XCTAssertEqual(Amount.usdtCents(1_234).formatted, "12.34 USDT")
        XCTAssertEqual(Amount.usdtCents(5).formatted, "0.05 USDT")
    }

    func testFiatFormatting() {
        XCTAssertEqual(FiatAmount.gbp(pence: 103).formatted, "£1.03")
        XCTAssertEqual(FiatAmount.gbp(pence: 5).formatted, "£0.05")
        XCTAssertEqual(FiatAmount.gbp(pence: 2_000).formatted, "£20")
        XCTAssertEqual(FiatAmount.gbp(pence: 0).formatted, "£0")
    }

    func testArithmeticWithinAnAsset() {
        XCTAssertEqual(Amount.sats(100) + Amount.sats(23), .sats(123))
        XCTAssertEqual(Amount.sats(100) - Amount.sats(23), .sats(77))
    }

    func testRateConversionRoundsHalfUp() {
        let rate = AssetRate(asset: .bitcoin, currencyCode: "GBP",
                             scaledPricePerMinorUnit: 5_000_000, asOf: Date())
        // 1 sat = 0.05p -> rounds to 0p
        XCTAssertEqual(rate.fiatValue(of: .sats(1)).minorUnits, 0)
        // 10 sats = 0.5p -> rounds half up to 1p
        XCTAssertEqual(rate.fiatValue(of: .sats(10)).minorUnits, 1)
        // 30 sats = 1.5p -> 2p
        XCTAssertEqual(rate.fiatValue(of: .sats(30)).minorUnits, 2)
    }

    func testRateStaleness() {
        let now = Date()
        let rate = AssetRate(asset: .bitcoin, currencyCode: "GBP",
                             scaledPricePerMinorUnit: 5_000_000,
                             asOf: now.addingTimeInterval(-200))
        XCTAssertTrue(rate.isStale(at: now, tolerance: RateFreshness.spendTolerance))
        XCTAssertFalse(rate.isStale(at: now, tolerance: 300))
    }
}

final class LightningAddressTests: XCTestCase {

    func testAcceptsOrdinaryAddresses() {
        XCTAssertEqual(LightningAddress("alice@getalby.com")?.description, "alice@getalby.com")
        XCTAssertEqual(LightningAddress("  Bob@Strike.me  ")?.description, "bob@strike.me")
        XCTAssertEqual(LightningAddress("lightning:carol@walletofsatoshi.com")?.description,
                       "carol@walletofsatoshi.com")
        XCTAssertNotNil(LightningAddress("first.last+tag@sub.domain.co.uk"))
    }

    /// This value ends up inside a URL we fetch and then send money to, so the
    /// parser has to be strict rather than forgiving.
    func testRejectsMalformedAndHostileInput() {
        XCTAssertNil(LightningAddress(""))
        XCTAssertNil(LightningAddress("nodomain"))
        XCTAssertNil(LightningAddress("@getalby.com"))
        XCTAssertNil(LightningAddress("alice@"))
        XCTAssertNil(LightningAddress("alice@localhost"), "must have a dotted domain")
        XCTAssertNil(LightningAddress("a@b@c.com"))
        XCTAssertNil(LightningAddress("../../etc@passwd.com"))
        XCTAssertNil(LightningAddress("alice@evil..com"))
        XCTAssertNil(LightningAddress("alice@.evil.com"))
        XCTAssertNil(LightningAddress("alice/../bob@x.com"))
        XCTAssertNil(LightningAddress("alice@x.com/path"))
    }

    func testEndpointIsAlwaysHTTPS() throws {
        let address = try XCTUnwrap(LightningAddress("alice@getalby.com"))
        XCTAssertEqual(address.lnurlPayEndpoint?.absoluteString,
                       "https://getalby.com/.well-known/lnurlp/alice")
    }

    func testRedactionKeepsLogsFromBecomingADirectory() throws {
        let address = try XCTUnwrap(LightningAddress("charlidamelio@getalby.com"))
        XCTAssertEqual(address.redacted, "ch***@getalby.com")
        XCTAssertFalse(address.redacted.contains("charlidamelio"))
    }
}
