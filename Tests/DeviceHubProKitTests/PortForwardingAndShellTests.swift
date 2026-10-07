import XCTest
@testable import DeviceHubProKit

/// Port forwarding and the device shell against a fake `adb`. The inline
/// `--list` text is SOURCE-DERIVED (adb_listeners.cpp `format_listeners`,
/// Android platform/packages/modules/adb); see
/// `PortForwarding.rules(from:direction:)`. The files under
/// `Fixtures/adb-portforward/` are real captures (2026-10-04, running API 35
/// emulator, adb 37.0.0), byte-exact.
final class PortForwardingAndShellTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/adb-portforward", isDirectory: true)

    func testRealCapturesOfBothListings() throws {
        let forwardText = try String(contentsOf: Self.fixtures.appendingPathComponent("forward-list.txt"), encoding: .utf8)
        let reverseText = try String(contentsOf: Self.fixtures.appendingPathComponent("reverse-list.txt"), encoding: .utf8)
        XCTAssertEqual(forwardText, "emulator-5554 tcp:18080 tcp:8080\n")
        XCTAssertEqual(reverseText, "host-16 tcp:18081 tcp:8081\n")
        XCTAssertEqual(
            PortForwarding.rules(from: forwardText, direction: .forward, serial: "emulator-5554"),
            [PortForwardRule(direction: .forward, listen: "tcp:18080", target: "tcp:8080")]
        )
        XCTAssertTrue(PortForwarding.rules(from: forwardText, direction: .forward, serial: "emulator-5556").isEmpty)
        XCTAssertEqual(
            PortForwarding.rules(from: reverseText, direction: .reverse, serial: "emulator-5554"),
            [PortForwardRule(direction: .reverse, listen: "tcp:18081", target: "tcp:8081")]
        )
    }

    func testParsesForwardAndReverseListings() {
        let forward = PortForwarding.rules(
            from: "emulator-5554 tcp:8080 tcp:80\nemulator-5554 tcp:5005 jdwp:1234\n",
            direction: .forward
        )
        XCTAssertEqual(forward, [
            PortForwardRule(direction: .forward, listen: "tcp:8080", target: "tcp:80"),
            PortForwardRule(direction: .forward, listen: "tcp:5005", target: "jdwp:1234"),
        ])
        let reverse = PortForwarding.rules(from: "(reverse) tcp:8081 tcp:8081\nhost-19 localabstract:x tcp:1\n", direction: .reverse)
        XCTAssertEqual(reverse.map(\.listen), ["tcp:8081", "localabstract:x"])
        XCTAssertEqual(reverse.map(\.target), ["tcp:8081", "tcp:1"])
    }

    func testForwardListingKeepsOnlyTheNamedDevice() {
        // host:list-forward answers with every device's listeners.
        let output = "emulator-5554 tcp:8080 tcp:80\nemulator-5556 tcp:9000 tcp:90\n"
        let rules = PortForwarding.rules(from: output, direction: .forward, serial: "emulator-5554")
        XCTAssertEqual(rules, [PortForwardRule(direction: .forward, listen: "tcp:8080", target: "tcp:80")])
        let reverse = PortForwarding.rules(from: "(reverse) tcp:8081 tcp:8081\n", direction: .reverse, serial: "emulator-5554")
        XCTAssertEqual(reverse.count, 1)
    }

    func testEmptyAndMalformedListingsYieldNoRules() {
        XCTAssertTrue(PortForwarding.rules(from: "", direction: .forward).isEmpty)
        XCTAssertTrue(PortForwarding.rules(from: "garbage line\ntwo cols\n", direction: .reverse).isEmpty)
    }

    func testSpecValidation() {
        XCTAssertNil(PortForwarding.validate(spec: "tcp:8080"))
        XCTAssertNil(PortForwarding.validate(spec: "localabstract:chrome_devtools_remote"))
        XCTAssertNotNil(PortForwarding.validate(spec: "tcp:0"))
        XCTAssertNotNil(PortForwarding.validate(spec: "tcp:70000"))
        XCTAssertNotNil(PortForwarding.validate(spec: "tcp:80 80"))
        XCTAssertNotNil(PortForwarding.validate(spec: "8080"))
        XCTAssertNotNil(PortForwarding.validate(spec: "udp:53"))
        XCTAssertNil(PortForwarding.validate(direction: .forward, listen: "tcp:5005", target: "jdwp:42"))
        XCTAssertNotNil(PortForwarding.validate(direction: .reverse, listen: "tcp:5005", target: "jdwp:42"))
    }

    /// A bare port number is read as tcp:<port>, the first thing a tester types.
    func testABarePortIsATcpSocket() {
        XCTAssertEqual(PortForwarding.normalized("8080"), "tcp:8080")
        XCTAssertEqual(PortForwarding.normalized(" 8080 "), "tcp:8080")
        XCTAssertEqual(PortForwarding.normalized("tcp:8080"), "tcp:8080")
        XCTAssertEqual(PortForwarding.normalized("localabstract:x"), "localabstract:x")
        XCTAssertNil(PortForwarding.validate(direction: .forward, listen: "18082", target: "18082"))
        XCTAssertNotNil(PortForwarding.validate(direction: .forward, listen: "99999", target: "80"))
    }

    func testListAddRemoveUseExplicitSerialAndAdbArgumentOrder() async throws {
        let adb = try FakeAdb([
            .init("forward --list", output: "SER tcp:8080 tcp:80\n"),
            .init("reverse --list", output: "(reverse) tcp:8081 tcp:8081\n"),
        ])
        let all = try await adb.client.allPortForwardRules(serial: "SER")
        XCTAssertEqual(all.count, 2)
        try await adb.client.addPortForward(serial: "SER", rule: PortForwardRule(direction: .forward, listen: "tcp:9000", target: "tcp:9001"))
        try await adb.client.addPortForward(serial: "SER", rule: PortForwardRule(direction: .reverse, listen: "tcp:9002", target: "tcp:9003"))
        try await adb.client.removePortForward(serial: "SER", rule: all[0])
        try await adb.client.removePortForward(serial: "SER", rule: all[1])
        XCTAssertEqual(adb.calls, [
            "-s SER forward --list",
            "-s SER reverse --list",
            "-s SER forward tcp:9000 tcp:9001",
            "-s SER reverse tcp:9002 tcp:9003",
            "-s SER forward --remove tcp:8080",
            "-s SER reverse --remove tcp:8081",
        ])
    }

    func testInvalidRuleNeverReachesAdb() async throws {
        let adb = try FakeAdb([])
        do {
            try await adb.client.addPortForward(serial: "SER", rule: PortForwardRule(direction: .forward, listen: "tcp:x", target: "tcp:1"))
            XCTFail("expected a validation error")
        } catch {}
        XCTAssertTrue(adb.calls.isEmpty)
    }

    func testAdbFailureSurfacesItsMessage() async throws {
        let adb = try FakeAdb([.init("forward", stderr: "adb: error: cannot bind", exitCode: 1)])
        do {
            try await adb.client.addPortForward(serial: "SER", rule: PortForwardRule(direction: .forward, listen: "tcp:1", target: "tcp:2"))
            XCTFail("expected a failure")
        } catch let AdbError.commandFailed(_, code, message) {
            XCTAssertEqual(code, 1)
            XCTAssertTrue(message.contains("cannot bind"))
        }
    }

    // MARK: shell

    func testShellRunsOneShotWithSerialAndReportsExitStatus() async throws {
        let adb = try FakeAdb([.init("shell", output: "one\ntwo\n", exitCode: 3)])
        let collected = LineBox()
        let status = try await adb.client.runShell(serial: "SER", command: "ls /sdcard | head") { collected.add($0) }
        XCTAssertEqual(status, 3)
        XCTAssertEqual(collected.lines, ["one", "two"])
        XCTAssertEqual(adb.calls, ["-s SER shell ls /sdcard | head"])
    }

    func testCancelStopsALongRunningShell() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shell-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("adb")
        try "#!/bin/sh\necho started\nexec sleep 60\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let client = AdbClient(adbURL: script)
        let started = Date()
        let task = Task { try await client.runShell(serial: "SER", command: "sleep 60") { _ in } }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }

    func testTranscriptDropsOldestLinesPastItsCap() {
        var transcript = ShellTranscript(capacity: 100)
        for index in 0..<50 { transcript.append("line number \(index)", kind: .output) }
        XCTAssertLessThanOrEqual(transcript.byteCount, 100)
        XCTAssertEqual(transcript.lines.last?.text, "line number 49")
        XCTAssertGreaterThan(transcript.droppedLines, 0)
        XCTAssertEqual(transcript.droppedLines + transcript.lines.count, 50)
    }

    func testTranscriptCutsOneOversizedLine() {
        var transcript = ShellTranscript(capacity: 50)
        transcript.append(String(repeating: "x", count: 500), kind: .output)
        XCTAssertEqual(transcript.lines.count, 1)
        XCTAssertLessThan(transcript.lines[0].text.utf8.count, 60)
    }

    func testHistoryWalksBackAndForwardAndRestoresDraft() {
        var history = ShellHistory()
        history.record("ls")
        history.record("pm list packages")
        history.record("pm list packages")
        XCTAssertEqual(history.entries, ["ls", "pm list packages"])
        XCTAssertEqual(history.previous(current: "dra"), "pm list packages")
        XCTAssertEqual(history.previous(current: "x"), "ls")
        XCTAssertEqual(history.previous(current: "x"), "ls")
        XCTAssertEqual(history.next(current: "x"), "pm list packages")
        XCTAssertEqual(history.next(current: "x"), "dra")
        XCTAssertEqual(history.next(current: "dra"), "dra")
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
