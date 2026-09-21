import XCTest
@testable import TipMeCore

final class SendLimitsAndRecentTipsTests: XCTestCase {
    func testLimitsRoundTripAndRejectInconsistentSets() {
        let store = InMemoryKeyValueStore()
        let prefs = SendLimitsPreference(store: store)
        XCTAssertNil(prefs.saved)

        XCTAssertTrue(prefs.save(.init(perTip: 500, perDay: 2_000, perWeek: 5_000)))
        XCTAssertEqual(prefs.saved, .init(perTip: 500, perDay: 2_000, perWeek: 5_000))

        XCTAssertFalse(prefs.save(.init(perTip: 3_000, perDay: 2_000, perWeek: 5_000)))
        XCTAssertFalse(prefs.save(.init(perTip: 0, perDay: 2_000, perWeek: 5_000)))
        XCTAssertEqual(prefs.saved, .init(perTip: 500, perDay: 2_000, perWeek: 5_000))
    }

    func testRecentTipsAreNewestFirstDeduplicatedAndPerAccount() throws {
        let store = InMemoryKeyValueStore()
        let mine = RecentTipStore(store: store, userID: "me")
        let natgeo = try XCTUnwrap(CreatorHandle(platform: .instagram, rawUsername: "natgeo"))
        let nasa = try XCTUnwrap(CreatorHandle(platform: .instagram, rawUsername: "nasa"))

        mine.record(natgeo, at: Date(timeIntervalSince1970: 1))
        mine.record(nasa, at: Date(timeIntervalSince1970: 2))
        mine.record(natgeo, at: Date(timeIntervalSince1970: 3))

        XCTAssertEqual(mine.all().map(\.handle), [natgeo, nasa])
        XCTAssertTrue(RecentTipStore(store: store, userID: "someone-else").all().isEmpty)

        mine.remove(natgeo)
        XCTAssertEqual(mine.all().map(\.handle), [nasa])
    }

    func testRecentTipsAreCapped() throws {
        let mine = RecentTipStore(store: InMemoryKeyValueStore(), userID: "me")
        for index in 0..<(RecentTipStore.capacity + 5) {
            mine.record(try XCTUnwrap(CreatorHandle(platform: .tiktok, rawUsername: "user\(index)")))
        }
        XCTAssertEqual(mine.all().count, RecentTipStore.capacity)
    }
}
