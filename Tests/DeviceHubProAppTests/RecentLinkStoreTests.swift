import XCTest
@testable import DeviceHubProApp

/// The Links group's Recent list: newest first, deduped, capped at 10,
/// persisted per Mac, and emptied by Clear Recents.
@MainActor
final class RecentLinkStoreTests: XCTestCase {
    func testRecordPutsTheNewestFirstAndDedupes() {
        let store = RecentLinkStore(defaults: .scratch())
        store.record("https://example.com/a")
        store.record("myapp://b")
        store.record("https://example.com/a")
        XCTAssertEqual(store.links, ["https://example.com/a", "myapp://b"])
    }

    /// Canonically equal links are one entry (one popover id), with the
    /// newest entry's exact scalars.
    func testCanonicalEquivalentsKeepTheNewestScalars() {
        let store = RecentLinkStore(defaults: .scratch())
        store.record("myapp://\u{E9}")
        store.record("myapp://e\u{301}")
        XCTAssertEqual(store.links.count, 1)
        XCTAssertEqual(Array(store.links[0].unicodeScalars), Array("myapp://e\u{301}".unicodeScalars))
    }

    func testTheListIsCappedAtTen() {
        let store = RecentLinkStore(defaults: .scratch())
        for index in 0..<12 {
            store.record("myapp://item/\(index)")
        }
        XCTAssertEqual(RecentLinkStore.defaultLimit, 10)
        XCTAssertEqual(store.links.count, 10)
        XCTAssertEqual(store.links.first, "myapp://item/11")
        XCTAssertEqual(store.links.last, "myapp://item/2")
    }

    func testTheListPersistsAndClearRemovesTheKey() {
        let defaults = UserDefaults.scratch()
        let store = RecentLinkStore(defaults: defaults)
        store.record("myapp://one")
        store.record("https://example.com/ü")
        XCTAssertEqual(RecentLinkStore(defaults: defaults).links, ["https://example.com/ü", "myapp://one"])
        XCTAssertEqual(defaults.stringArray(forKey: RecentLinkStore.defaultKey), ["https://example.com/ü", "myapp://one"])

        store.clear()
        XCTAssertEqual(store.links, [])
        XCTAssertNil(defaults.object(forKey: RecentLinkStore.defaultKey))
        XCTAssertEqual(RecentLinkStore(defaults: defaults).links, [])
    }

    /// A stored list is re-validated with the larger (API 24+) limit:
    /// entries `LinkRequest` refuses are dropped, duplicates collapse, the
    /// list is capped, and the cleaned list is written back.
    func testLoadDropsInvalidEntriesAndCaps() {
        let defaults = UserDefaults.scratch()
        let long = "myapp://" + String(repeating: "a", count: 30_001)
        var stored = ["myapp://ok", "myapp://line\nbreak", long, "example.com", "myapp://ok"]
        stored += (0..<12).map { "myapp://item/\($0)" }
        defaults.set(stored, forKey: RecentLinkStore.defaultKey)

        let store = RecentLinkStore(defaults: defaults)
        XCTAssertEqual(store.links.count, 10)
        XCTAssertEqual(store.links.first, "myapp://ok")
        XCTAssertFalse(store.links.contains(long))
        XCTAssertFalse(store.links.contains("example.com"))
        XCTAssertEqual(store.links.filter { $0 == "myapp://ok" }.count, 1)
        XCTAssertEqual(defaults.stringArray(forKey: RecentLinkStore.defaultKey), store.links)

        // 29,000 bytes pass at the larger limit.
        let fits = "myapp://" + String(repeating: "b", count: 29_000)
        defaults.set([fits], forKey: RecentLinkStore.defaultKey)
        XCTAssertEqual(RecentLinkStore(defaults: defaults).links, [fits])
    }

    func testAFreshInstallWritesNothing() {
        let defaults = UserDefaults.scratch()
        _ = RecentLinkStore(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: RecentLinkStore.defaultKey))
    }
}
