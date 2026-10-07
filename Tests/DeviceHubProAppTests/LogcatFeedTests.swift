import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// The Logcat view's incremental feed (F7/F8): only unseen entries are
/// filtered, the history outlives one snapshot window up to the stream's
/// capacity, and anything that is not a continuation starts over.
@MainActor
final class LogcatFeedTests: XCTestCase {
    func testOnlyUnseenEntriesAreAppended() {
        let feed = LogcatFeed()
        feed.ingest(entries(1...3))
        feed.ingest(entries(2...5))

        XCTAssertEqual(feed.entries.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(feed.matches.map(\.id), [1, 2, 3, 4, 5])
    }

    func testTheHistoryReachesBeyondOneSnapshot() {
        // The model publishes a sliding window (tail(1500)); a crash that has
        // left the window must still be found by the level filter.
        let feed = LogcatFeed()
        feed.ingest([entry(1, level: .error, message: "FATAL EXCEPTION: main")] + entries(2...3))
        feed.ingest(entries(3...5))
        feed.ingest(entries(5...7))

        feed.setFilter(level: .error, search: "")

        XCTAssertEqual(feed.entries.count, 7)
        XCTAssertEqual(feed.matches.map(\.id), [1])
    }

    func testCapacityDropsTheOldestEntriesAndTheirMatches() {
        let feed = LogcatFeed(capacity: 4)
        feed.setFilter(level: .debug, search: "even")
        feed.ingest((1...6).map { entry(UInt64($0), message: $0 % 2 == 0 ? "even" : "odd") })

        XCTAssertEqual(feed.entries.map(\.id), [3, 4, 5, 6])
        XCTAssertEqual(feed.matches.map(\.id), [4, 6])
    }

    func testAnEmptySnapshotStartsOver() {
        let feed = LogcatFeed()
        feed.ingest(entries(1...3))
        feed.ingest([])

        XCTAssertTrue(feed.entries.isEmpty)
        XCTAssertTrue(feed.matches.isEmpty)
    }

    func testANewStreamStartsOver() {
        let feed = LogcatFeed()
        feed.ingest(entries(10...12))
        feed.ingest(entries(1...2))

        XCTAssertEqual(feed.entries.map(\.id), [1, 2])
    }

    func testTheSameIdOnAnotherLineStartsOver() {
        let feed = LogcatFeed()
        feed.ingest(entries(1...3))
        let other = [entry(2, message: "another stream"), entry(3, message: "another stream"), entry(4)]
        feed.ingest(other)

        XCTAssertEqual(feed.entries, other)
    }

    /// Entries that came and went between two snapshots leave a marker in
    /// their place, which every filter keeps and Export writes: the list
    /// used to join both sides as if nothing were missing.
    func testAGapBetweenSnapshotsKeepsBothSidesAndMarksIt() {
        let feed = LogcatFeed()
        feed.ingest(entries(1...3))
        feed.ingest(entries(10...11))

        XCTAssertEqual(feed.entries.map(\.id), [1, 2, 3, 9, 10, 11])
        let marker = feed.entries[3]
        XCTAssertEqual(marker.tag, "DeviceHubPro")
        XCTAssertEqual(marker.level, .warning)
        XCTAssertEqual(marker.message, "6 lines not shown: the device logged faster than the log view keeps up")
        XCTAssertEqual(marker.timestamp, feed.entries[4].timestamp)

        feed.setFilter(level: .error, search: "no such text")
        XCTAssertEqual(feed.matches.map(\.id), [9], "the gap shows whatever the filter")
        feed.ingest(entries(11...12))
        XCTAssertEqual(feed.entries.map(\.id), [1, 2, 3, 9, 10, 11, 12], "a continuation adds no marker")
    }

    /// A gap right after the entry the feed holds, inside a snapshot that
    /// overlaps it (a poll after a pause); one entry reads in the singular.
    func testAGapInsideAnOverlappingSnapshotIsMarked() {
        let feed = LogcatFeed()
        feed.ingest(entries(1...3))
        feed.ingest(entries(2...3) + entries(5...6))

        XCTAssertEqual(feed.entries.map(\.id), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(feed.entries[3].message, "1 line not shown: the device logged faster than the log view keeps up")
        feed.ingest([])
        feed.ingest(entries(8...9))
        XCTAssertEqual(feed.entries.map(\.id), [8, 9], "a new start marks nothing")
    }

    func testTheSearchIgnoresCaseOnTagAndMessage() {
        let feed = LogcatFeed()
        feed.ingest([
            entry(1, tag: "ActivityManager", message: "Start proc"),
            entry(2, tag: "Zygote", message: "forked ACTIVITY"),
            entry(3, tag: "art", message: "gc"),
        ])

        feed.setFilter(level: .debug, search: "activity")
        XCTAssertEqual(feed.matches.map(\.id), [1, 2])

        feed.ingest([entry(3, tag: "art", message: "gc"), entry(4, tag: "x", message: "an Activity line")])
        XCTAssertEqual(feed.matches.map(\.id), [1, 2, 4], "new entries are filtered as they arrive")

        feed.setFilter(level: .debug, search: "")
        XCTAssertEqual(feed.matches.map(\.id), [1, 2, 3, 4])
    }

    func testTheLevelFilterKeepsMoreSevereEntries() {
        let feed = LogcatFeed()
        feed.ingest([
            entry(1, level: .verbose),
            entry(2, level: .debug),
            entry(3, level: .warning),
            entry(4, level: .fatal),
        ])

        feed.setFilter(level: .warning, search: "")

        XCTAssertEqual(feed.matches.map(\.id), [3, 4])
    }

    func testTheSnapshotKeyTellsSnapshotsApart() {
        XCTAssertEqual(LogcatFeed.SnapshotKey(entries(1...3)), LogcatFeed.SnapshotKey(entries(1...3)))
        XCTAssertNotEqual(LogcatFeed.SnapshotKey(entries(1...3)), LogcatFeed.SnapshotKey(entries(2...4)))
        XCTAssertNotEqual(LogcatFeed.SnapshotKey(entries(1...3)), LogcatFeed.SnapshotKey([]))
    }

    func testExportWritesOneLinePerEntry() {
        let text = LogcatController.logcatExportText([
            entry(1, level: .error, tag: "AndroidRuntime", message: "FATAL EXCEPTION: main"),
            entry(2, level: .info, tag: "ActivityManager", message: "Start proc"),
        ])

        XCTAssertEqual(
            text,
            "09-24 12:00:00.000 E AndroidRuntime: FATAL EXCEPTION: main\n"
                + "09-24 12:00:00.000 I ActivityManager: Start proc"
        )
    }

    // MARK: - Helpers

    private func entries(_ ids: ClosedRange<UInt64>) -> [LogcatEntry] {
        ids.map { entry($0) }
    }

    private func entry(
        _ id: UInt64,
        level: LogcatLevel = .info,
        tag: String = "Tag",
        message: String? = nil
    ) -> LogcatEntry {
        LogcatEntry(
            id: id,
            timestamp: "09-24 12:00:00.000",
            pid: 100,
            tid: 100,
            level: level,
            tag: tag,
            message: message ?? "line \(id)"
        )
    }
}
