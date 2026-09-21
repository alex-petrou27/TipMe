import XCTest
@testable import TipMeCore

final class CurrencyPreferenceTests: XCTestCase {
    func testNothingSavedByDefault() {
        XCTAssertNil(CurrencyPreference(store: InMemoryKeyValueStore()).saved)
    }

    func testSavedChoiceIsReadBack() {
        let store = InMemoryKeyValueStore()
        CurrencyPreference(store: store).save("eur")
        XCTAssertEqual(CurrencyPreference(store: store).saved, "EUR")
    }

    func testUnsupportedCurrencyIsIgnored() {
        let store = InMemoryKeyValueStore()
        CurrencyPreference(store: store).save("JPY")
        XCTAssertNil(CurrencyPreference(store: store).saved)
    }

    func testParsingAmounts() {
        func minor(_ text: String) -> Int64? { FiatAmount(parsing: text, currencyCode: "GBP")?.minorUnits }
        XCTAssertEqual(minor("12.34"), 1234)
        XCTAssertEqual(minor("12,34"), 1234)
        XCTAssertEqual(minor("5"), 500)
        XCTAssertEqual(minor("0.5"), 50)
        XCTAssertNil(minor("0"))
        XCTAssertNil(minor("-3"))
        XCTAssertNil(minor("1.234"))
        XCTAssertNil(minor("abc"))
        XCTAssertNil(minor(""))
    }
}
