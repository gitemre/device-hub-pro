import XCTest
@testable import DeviceHubProKit

/// The problem log the app keeps for the report.
final class RecentProblemStoreTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ start: Date) { value = start }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
        var now: Date { lock.withLock { value } }
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func store(file: URL? = nil, clock: Clock) -> RecentProblemStore {
        RecentProblemStore(fileURL: file) { clock.now }
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RecentProblems-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testEntriesAreNewestFirstAndCapped() {
        let clock = Clock(start)
        let store = store(clock: clock)
        for index in 0..<(RecentProblemStore.capacity + 5) {
            clock.advance(120)
            store.record(message: "Problem \(index)")
        }
        let entries = store.entries()
        XCTAssertEqual(entries.count, 20)
        XCTAssertEqual(entries.first?.message, "Problem 24")
        XCTAssertEqual(entries.last?.message, "Problem 5")
    }

    func testTheSameMessageWithinAMinuteIsCounted() {
        let clock = Clock(start)
        let store = store(clock: clock)
        store.record(message: "Emulator not responding", revision: 1)
        clock.advance(30)
        store.record(message: "Emulator not responding", revision: 2)
        clock.advance(59)
        store.record(message: "Emulator not responding", revision: 3)
        var entries = store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].count, 3)
        XCTAssertEqual(entries[0].at, start.addingTimeInterval(89), "the time of the last one")

        clock.advance(61)
        store.record(message: "Emulator not responding")
        XCTAssertEqual(store.entries().count, 2, "a minute later it is a new entry")

        store.record(message: "Another")
        store.record(message: "Emulator not responding")
        entries = store.entries()
        XCTAssertEqual(entries.map(\.message), ["Emulator not responding", "Another", "Emulator not responding", "Emulator not responding"], "only the newest entry coalesces")
    }

    func testDetailsAttachByRevisionAndAreSplitIntoLines() {
        let clock = Clock(start)
        let store = store(clock: clock)
        store.record(message: "First", revision: 1)
        clock.advance(100)
        store.record(message: "Second", revision: 2)
        store.attachDetails("line a\nline b", revision: 1)
        let entries = store.entries()
        XCTAssertEqual(entries[0].message, "Second")
        XCTAssertNil(entries[0].details)
        XCTAssertEqual(entries[1].details, ["line a", "line b"])
        store.attachDetails("nobody has this", revision: 99)
        XCTAssertEqual(store.entries().count, 2)

        // A coalesced error takes over the revision.
        clock.advance(10)
        store.record(message: "Second", revision: 3)
        store.attachDetails("fresh", revision: 3)
        XCTAssertEqual(store.entries()[0].details, ["fresh"])
        XCTAssertEqual(store.entries()[0].count, 2)
    }

    func testMessagesAndDetailsAreCapped() {
        let store = store(clock: Clock(start))
        store.record(message: String(repeating: "m", count: 5_000), details: String(repeating: "d", count: 9_000))
        let entry = store.entries()[0]
        XCTAssertEqual(entry.message.count, RecentProblemStore.maxMessageLength)
        XCTAssertEqual(entry.details?.joined(separator: "\n").count, RecentProblemStore.maxDetailsLength)
    }

    func testEntriesSurviveARelaunch() throws {
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("Library/Logs/DeviceHubPro/recent-problems.json")
        XCTAssertEqual(RecentProblemStore.liveFileURL(home: folder), file)
        let clock = Clock(start)
        let first = store(file: file, clock: clock)
        first.record(message: "Pixel_8_Pro did not come online in time.", details: "a\nb")
        clock.advance(300)
        first.record(message: "Emulator not responding")
        first.flush()

        let second = store(file: file, clock: clock)
        let entries = second.entries()
        XCTAssertEqual(entries.map(\.message), ["Emulator not responding", "Pixel_8_Pro did not come online in time."])
        XCTAssertEqual(entries[1].details, ["a", "b"])
        // The file is JSON a human can read.
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("\"message\" : \"Emulator not responding\""))
    }

    func testTheFileAndItsFolderAreForTheUserOnly() throws {
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("logs/recent-problems.json")
        let store = store(file: file, clock: Clock(start))
        store.record(message: "Something")
        store.flush()
        let manager = FileManager.default
        XCTAssertEqual((try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try manager.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        store.record(message: "Something else")
        store.flush()
        XCTAssertEqual((try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600, "a rewrite keeps the mode")
    }

    func testADamagedFileStartsEmpty() throws {
        let folder = try temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("recent-problems.json")
        try "{ this is not json".write(to: file, atomically: true, encoding: .utf8)
        let store = store(file: file, clock: Clock(start))
        XCTAssertEqual(store.entries(), [])
        store.record(message: "After")
        store.flush()
        XCTAssertEqual(self.store(file: file, clock: Clock(start)).entries().map(\.message), ["After"])
    }

    // MARK: Who the errors name

    func testTheIdentifiersOfTheDevicesConnectedAreKeptBesideEachError() {
        let clock = Clock(start)
        let store = store(clock: clock)
        store.record(
            message: "adb -s R58M12345AB reboot failed",
            identifiers: RecentProblemIdentifiers(phones: [["R58M12345AB", "R58M12345AB-hw"]], secrets: ["Emre\u{2019}s iPhone"])
        )
        clock.advance(120)
        store.record(message: "Another", identifiers: RecentProblemIdentifiers(phones: [["ZX1G22ABCD"]]))
        clock.advance(120)
        store.record(message: "Third with none")
        XCTAssertEqual(store.identifiers(), RecentProblemIdentifiers(
            phones: [["ZX1G22ABCD"], ["R58M12345AB", "R58M12345AB-hw"]], secrets: ["Emre\u{2019}s iPhone"]
        ))
        // The same error again within a minute adds what is connected now, without repeating.
        clock.advance(10)
        store.record(message: "Third with none", identifiers: RecentProblemIdentifiers(phones: [["zx1g22abcd"], ["QQ99"]]))
        XCTAssertEqual(store.entries().count, 3)
        XCTAssertEqual(store.identifiers().phones.count, 3, "the same phone in another case is not a new group")
    }

    func testTheIdentifiersSurviveARelaunchButNeverEnterTheReport() throws {
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("recent-problems.json")
        let first = store(file: file, clock: Clock(start))
        first.record(message: "adb -s R58M12345AB reboot failed", identifiers: RecentProblemIdentifiers(phones: [["R58M12345AB"]]))
        first.flush()
        let second = store(file: file, clock: Clock(start))
        XCTAssertEqual(second.identifiers().phones, [["R58M12345AB"]])
        XCTAssertEqual(second.entries().map(\.message), ["adb -s R58M12345AB reboot failed"])
        // The report's own type has no field for them.
        XCTAssertFalse(String(decoding: try ProblemReport.encoder().encode(second.entries()), as: UTF8.self).contains("identifiers"))
    }

    /// A file written before the identifiers were kept (the report's fields only) still loads.
    func testAFileWithoutIdentifiersStillLoads() throws {
        let folder = try temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("recent-problems.json")
        let old = [ProblemReport.RecentProblem(at: start, message: "Old entry", details: ["a"], count: 2)]
        try ProblemReport.encoder().encode(old).write(to: file)
        let store = store(file: file, clock: Clock(start))
        XCTAssertEqual(store.entries(), old)
        XCTAssertTrue(store.identifiers().isEmpty)
    }

    /// A message cut for storage does not end inside a run that looks like the front of a token.
    func testACutDoesNotLeaveTheFrontOfAToken() {
        let store = store(clock: Clock(start))
        let key = String(repeating: "Qk/9xZtLmN", count: 8)
        let message = String(repeating: "word ", count: 400) + key
        XCTAssertGreaterThan(message.count, RecentProblemStore.maxMessageLength)
        let straddling = String(message.prefix(RecentProblemStore.maxMessageLength - 30)) + key
        store.record(message: straddling)
        let kept = store.entries()[0].message
        XCTAssertLessThanOrEqual(kept.count, RecentProblemStore.maxMessageLength)
        XCTAssertFalse(kept.contains("Qk/9"), "the part of the key before the cut is dropped with the rest of it")
    }

    func testWithoutAFileTheStoreIsInMemory() throws {
        let store = store(clock: Clock(start))
        store.record(message: "Only here")
        store.flush()
        XCTAssertEqual(store.entries().count, 1)
    }
}
