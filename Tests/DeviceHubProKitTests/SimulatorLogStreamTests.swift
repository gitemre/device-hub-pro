import XCTest
@testable import DeviceHubProKit

/// `SimulatorLogParsing` and `SimulatorLogStream` fed the real
/// `log stream --style ndjson` output.
///
/// `Fixtures/ios27-simulator/logs/simctl-spawn-log-stream-ndjson.trimmed.ndjson`
/// is the stdout of `simctl --set <set> spawn <udid> log stream --style
/// ndjson --level debug` on the private-set iPhone 17 Pro of
/// `SimctlFixtureTests` (iOS 27.0 24A434, Xcode 27.0 27A266a, tr_TR /
/// Europe/Istanbul, so timestamps carry +0300), stopped with SIGINT after
/// 4 s while Settings launched. The full capture was 48,058 lines (79 MB:
/// about 14,500 events/s right after the first boot). Trimmed to 32 lines,
/// kept byte-exact and in their original order: the first 24 events, the
/// first two of every message type and of the activity records not already
/// among them, and the stream's last lines (an empty line, then
/// `{"count":48055,"finished":1}`). The macOS user name inside one message
/// (a path) is replaced with the same-length `aqauser001`, and that path's
/// scratch-folder segment with the same-length placeholder
/// `SimctlFixtureTests` describes.
/// `simctl-spawn-log-stream.stderr.txt` is the run's whole stderr.
final class SimulatorLogStreamTests: XCTestCase {
    private static let ndjson = SimctlFixtureTests.url("logs", "simctl-spawn-log-stream-ndjson.trimmed.ndjson")
    private static let stderr = SimctlFixtureTests.url("logs", "simctl-spawn-log-stream.stderr.txt")

    private static func lines() throws -> [String] {
        let text = try XCTUnwrap(String(data: try Data(contentsOf: ndjson), encoding: .utf8))
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }

    func testEveryLineParses() throws {
        let parsed = try Self.lines().map(SimulatorLogParsing.parse)
        let entries = parsed.compactMap { line -> SimulatorLogEntry? in
            if case .entry(let entry) = line { return entry }
            return nil
        }
        XCTAssertEqual(entries.count, 29)
        XCTAssertEqual(parsed.filter { $0 == .ignored }.count, 2, "the empty line and the trailing newline")
        XCTAssertEqual(parsed.last { $0 != .ignored }, .finished(count: 48055))

        let counts = Dictionary(grouping: entries, by: { $0.messageType ?? "activity" }).mapValues(\.count)
        XCTAssertEqual(counts, ["Debug": 16, "Default": 4, "Info": 3, "Error": 2, "Fault": 2, "activity": 2])
    }

    /// The first event, field by field, and its logcat shape.
    func testFirstEvent() throws {
        guard case .entry(let entry) = SimulatorLogParsing.parse(try Self.lines()[0]) else {
            return XCTFail("the first line is an event")
        }
        XCTAssertEqual(entry.timestamp, "2026-09-25 15:06:19.359577+0300")
        XCTAssertEqual(entry.processID, 76609)
        XCTAssertEqual(entry.threadID, 5_018_536)
        XCTAssertEqual(entry.process, "ExtragalacticPoster")
        XCTAssertEqual(entry.subsystem, "com.apple.defaults")
        XCTAssertEqual(entry.category, "User Defaults")
        XCTAssertEqual(entry.messageType, "Debug")
        XCTAssertEqual(entry.eventType, "logEvent")
        XCTAssertTrue(entry.message.hasPrefix("found no value for key EnhancedBackgroundContrastEnabled"))

        let logcat = entry.logcatEntry
        XCTAssertEqual(logcat.timestamp, "09-25 15:06:19.359")
        XCTAssertEqual(logcat.pid, 76609)
        XCTAssertEqual(logcat.tid, 5_018_536)
        XCTAssertEqual(logcat.level, .debug)
        XCTAssertEqual(logcat.tag, "ExtragalacticPoster")
        XCTAssertEqual(logcat.message, entry.message)
        XCTAssertEqual(logcat.subsystem, "com.apple.defaults", "kept for the log view's search")
    }

    /// Following one app: `log stream --predicate` on its process name, the
    /// string literal escaped.
    func testProcessPredicate() {
        XCTAssertEqual(SimulatorLogStream.processPredicate("MobileSafari"), #"process == "MobileSafari""#)
        XCTAssertEqual(SimulatorLogStream.processPredicate(#"My "App"\X"#), #"process == "My \"App\"\\X""#)
    }

    /// Activity records carry no messageType (and empty subsystem and
    /// category); they map to Verbose. Error and Fault map to E and F.
    func testLevelsAndActivityRecords() throws {
        let entries = try Self.lines().compactMap { line -> SimulatorLogEntry? in
            if case .entry(let entry) = SimulatorLogParsing.parse(line) { return entry }
            return nil
        }
        let activities = entries.filter { $0.eventType == "activityCreateEvent" }
        XCTAssertFalse(activities.isEmpty)
        XCTAssertTrue(activities.allSatisfy { $0.messageType == nil && $0.level == .verbose && $0.subsystem.isEmpty })
        XCTAssertEqual(activities.first?.message, "invalidateAssertionWithIdentifier")
        XCTAssertEqual(Set(entries.filter { $0.messageType == "Error" }.map(\.level)), [.error])
        XCTAssertEqual(Set(entries.filter { $0.messageType == "Fault" }.map(\.level)), [.fatal])
        XCTAssertEqual(Set(entries.filter { $0.messageType == "Default" }.map(\.level)), [.info])
        XCTAssertEqual(Set(entries.filter { $0.messageType == "Info" }.map(\.level)), [.info])
    }

    /// `simctl spawn` writes `getpwuid_r did not find a match for uid 501` on
    /// stderr (the host uid has no account in the simulator); it is not an
    /// event.
    func testStderrNoiseIsIgnored() throws {
        let noise = try XCTUnwrap(String(data: try Data(contentsOf: Self.stderr), encoding: .utf8))
        XCTAssertEqual(noise, "getpwuid_r did not find a match for uid 501\n")
        XCTAssertEqual(SimulatorLogParsing.parse("getpwuid_r did not find a match for uid 501"), .ignored)
        XCTAssertEqual(SimulatorLogParsing.parse("{not json"), .ignored)
    }

    func testTimestampConversionLeavesOddValuesAlone() {
        XCTAssertEqual(SimulatorLogParsing.logcatTimestamp("2026-09-25 15:06:19.359577+0300"), "09-25 15:06:19.359")
        XCTAssertEqual(SimulatorLogParsing.logcatTimestamp(""), "")
        XCTAssertEqual(SimulatorLogParsing.logcatTimestamp("yesterday"), "yesterday")
    }

    // MARK: Stream

    private func makeFakeSimctl(exitCode: Int32 = 0) throws -> FakeTool {
        try FakeTool(name: "simctl", rules: [
            .init("log stream", stdoutFile: Self.ndjson, stderrFile: Self.stderr, exitCode: exitCode),
        ])
    }

    /// A stream that ends on its own (the replayed capture): every event is
    /// kept, the noise is counted, and the status says why it stopped.
    func testStreamCollectsTheCaptureAndReportsTheExit() async throws {
        let fake = try makeFakeSimctl(exitCode: 0)
        let set = FileManager.default.temporaryDirectory.appendingPathComponent("SimulatorLogStreamTests-set")
        let simctl = SimctlClient(simctlURL: fake.executableURL, deviceSet: set)
        let stream = SimulatorLogStream(simctl: simctl, udid: SimctlFixtureTests.udid, level: .debug)
        stream.start()
        try await waitUntil { stream.status != .running }

        XCTAssertEqual(stream.status, .stopped(reason: "log stream exited with status 0"))
        let entries = stream.snapshot()
        XCTAssertEqual(entries.count, 29)
        XCTAssertEqual(entries.map(\.id), Array(1...29))
        XCTAssertEqual(stream.ignoredLineCount, 1, "the stderr line")
        XCTAssertEqual(stream.logcatSnapshot().first?.timestamp, "09-25 15:06:19.359")
        XCTAssertEqual(fake.invocations, [[
            "--set", set.path, "spawn", SimctlFixtureTests.udid, "log", "stream", "--style", "ndjson", "--level", "debug",
        ]])
    }

    /// A followed process that restarts under a new pid keeps its previous
    /// run behind a marker event. The input is the capture's first event
    /// twice, then the same event with its `processID` changed in the test
    /// (a restart cannot be captured into the trimmed fixture).
    func testAFollowedProcessRestartKeepsThePreviousRunBehindAMarker() async throws {
        let first = try XCTUnwrap(try Self.lines().first { $0.hasPrefix("{") && $0.contains("\"processID\"") })
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        let oldPID = try XCTUnwrap(object["processID"] as? Int)
        object["processID"] = oldPID + 1
        let restarted = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
        let input = FileManager.default.temporaryDirectory
            .appendingPathComponent("restart-\(UUID().uuidString).ndjson")
        try [first, first, restarted, ""].joined(separator: "\n").write(to: input, atomically: true, encoding: .utf8)
        let fake = try FakeTool(name: "simctl", rules: [.init("log stream", stdoutFile: input, exitCode: 0)])

        let stream = SimulatorLogStream(
            simctl: SimctlClient(simctlURL: fake.executableURL),
            udid: SimctlFixtureTests.udid,
            predicate: SimulatorLogStream.processPredicate("App")
        )
        stream.start()
        try await waitUntil { stream.status != .running }

        let held = stream.snapshot()
        XCTAssertEqual(held.map(\.processID), [oldPID, oldPID, oldPID + 1, oldPID + 1])
        XCTAssertEqual(held[2].process, SimulatorLogStream.restartMarkerProcess)
        XCTAssertEqual(
            held[2].message,
            "── \(held[0].process) restarted: pid \(oldPID) → \(oldPID + 1). Lines above are from the previous run. ──"
        )

        // The whole log (no process followed) never gets a marker.
        let whole = SimulatorLogStream(simctl: SimctlClient(simctlURL: fake.executableURL), udid: SimctlFixtureTests.udid)
        whole.start()
        try await waitUntil { whole.status != .running }
        XCTAssertEqual(whole.snapshot().count, 3)
    }

    func testCapacityKeepsTheNewestEntries() async throws {
        let fake = try makeFakeSimctl()
        let simctl = SimctlClient(simctlURL: fake.executableURL)
        let stream = SimulatorLogStream(simctl: simctl, udid: SimctlFixtureTests.udid, capacity: 4)
        stream.start()
        try await waitUntil { stream.status != .running }
        XCTAssertEqual(stream.snapshot().map(\.id), [26, 27, 28, 29])
        XCTAssertEqual(stream.tail(2).map(\.id), [28, 29])
        XCTAssertEqual(stream.logcatTail(2).map(\.id), [28, 29])
        XCTAssertEqual(stream.logcatTail(2), stream.tail(2).map(\.logcatEntry))
        stream.clear()
        XCTAssertEqual(stream.snapshot(), [])
    }

    /// `entries(after:)` returns what a reader that has seen up to an id has
    /// not read, as far as the history holds it.
    func testEntriesAfterAnIDAreTheUnreadOnes() async throws {
        let fake = try makeFakeSimctl()
        let stream = SimulatorLogStream(
            simctl: SimctlClient(simctlURL: fake.executableURL),
            udid: SimctlFixtureTests.udid,
            capacity: 4
        )
        XCTAssertEqual(stream.entries(after: 0), [], "nothing streamed yet")
        stream.start()
        try await waitUntil { stream.status != .running }
        XCTAssertEqual(
            stream.entries(after: 0).map(\.id),
            [25, 26, 27, 28, 29],
            "the held history, trimmed in chunks: up to a quarter over the capacity"
        )
        XCTAssertEqual(stream.entries(after: 25).map(\.id), [26, 27, 28, 29])
        XCTAssertEqual(stream.entries(after: 27).map(\.id), [28, 29])
        XCTAssertEqual(stream.entries(after: 29), [])
        XCTAssertEqual(stream.entries(after: 100), [])
        XCTAssertEqual(stream.logcatEntries(after: 27), stream.tail(2).map(\.logcatEntry))
    }

    /// A boot's burst: the capture's first boot streamed about 14,500
    /// events a second. The capture's 29 events, repeated to 14,500 lines
    /// (built at run time, not a fixture), all come through the reader in
    /// order and the history keeps the newest `capacity`, ids unbroken.
    func testABurstKeepsTheNewestEntriesInOrder() async throws {
        let events = try Self.lines().filter { line in
            if case .entry = SimulatorLogParsing.parse(line) { return true }
            return false
        }
        XCTAssertEqual(events.count, 29)
        guard case .entry(let newest) = SimulatorLogParsing.parse(events[(14_500 - 1) % events.count]) else {
            return XCTFail("the burst's last line is an event")
        }
        let burst = (0..<14_500).map { events[$0 % events.count] }.joined(separator: "\n") + "\n"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorLogStreamTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Best effort: a leftover temporary folder must not fail the test.
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("burst.ndjson")
        try Data(burst.utf8).write(to: file)
        let fake = try FakeTool(name: "simctl", rules: [.init("log stream", stdoutFile: file)])

        let stream = SimulatorLogStream(simctl: SimctlClient(simctlURL: fake.executableURL), udid: SimctlFixtureTests.udid)
        let started = Date()
        stream.start()
        try await waitUntil(timeout: 60) { stream.status != .running }
        let seconds = Date().timeIntervalSince(started)

        let kept = stream.snapshot()
        XCTAssertEqual(kept.count, 4000)
        XCTAssertEqual(kept.first?.id, 10_501)
        XCTAssertEqual(kept.last?.id, 14_500)
        XCTAssertEqual(kept.map(\.id), Array(10_501...14_500))
        XCTAssertEqual(kept.last?.message, newest.message)
        print("SimulatorLogStream burst: 14500 events in \(String(format: "%.2f", seconds)) s")
    }

    func testPredicateIsPassedToLogStream() {
        let simctl = SimctlClient(simctlURL: URL(fileURLWithPath: "/usr/bin/false"))
        let stream = SimulatorLogStream(
            simctl: simctl,
            udid: SimctlFixtureTests.udid,
            level: .info,
            predicate: "process == \"MobileSafari\""
        )
        XCTAssertEqual(stream.arguments, [
            "spawn", SimctlFixtureTests.udid, "log", "stream", "--style", "ndjson", "--level", "info",
            "--predicate", "process == \"MobileSafari\"",
        ])
    }

    func testAnInvalidUDIDNeverStarts() {
        let simctl = SimctlClient(simctlURL: URL(fileURLWithPath: "/usr/bin/false"))
        let stream = SimulatorLogStream(simctl: simctl, udid: "booted")
        stream.start()
        guard case .stopped = stream.status else { return XCTFail("\(stream.status)") }
    }

    /// Stopping ends the child and returns the stream to idle.
    func testStopEndsARunningStream() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorLogStreamTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Best effort: a leftover temporary folder must not fail the test.
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("simctl")
        let pidFile = directory.appendingPathComponent("pid")
        let first = try Self.lines()[0]
        // `exec` keeps the pid the stub records, so it is the child's.
        try Data("""
        #!/bin/sh
        echo $$ > \(FakeTool.quoted(pidFile.path))
        printf '%s\\n' \(FakeTool.quoted(first))
        exec sleep 30

        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let stream = SimulatorLogStream(simctl: SimctlClient(simctlURL: script), udid: SimctlFixtureTests.udid)
        stream.start()
        try await waitUntil { stream.snapshot().count == 1 }
        let pid = try XCTUnwrap(Int32(
            try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        XCTAssertEqual(kill(pid, 0), 0, "the child runs")
        stream.stop()
        XCTAssertEqual(stream.status, .idle)
        // The child is gone well within the SIGKILL grace period.
        try await waitUntil(timeout: 3) { kill(pid, 0) != 0 }
        XCTAssertEqual(stream.status, .idle, "a cancelled stream does not report a stop reason")
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                return XCTFail("condition not met within \(timeout) s")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
