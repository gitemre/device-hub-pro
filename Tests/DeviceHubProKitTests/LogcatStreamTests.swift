import XCTest
@testable import DeviceHubProKit

final class LogcatStreamTests: XCTestCase {
    /// A fake `adb` binary: the stream calls `adbURL -s <serial> logcat -v
    /// threadtime`, so the script ignores its arguments.
    private func makeFakeAdb(script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-logcat-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fake-adb")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }

    /// An adb that dies on its own (device unplugged, adb killed) must
    /// surface as `.stopped` so the UI can show its disconnected state; the
    /// entries it managed to print are kept.
    func testExitedLogcatProcessReportsStopped() async throws {
        let fakeADB = try makeFakeAdb(script: """
        #!/bin/sh
        printf '01-01 00:00:00.000  10  11 I Tag: hello\\n'
        exit 3
        """)

        let stream = LogcatStream(adbURL: fakeADB, serial: "fake-serial")
        stream.start()

        // Polled until both arrive, with room for a loaded machine: the
        // exit and the last line reach the stream on separate paths.
        var reason: String?
        var entries: [LogcatEntry] = []
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if case .stopped(let value) = stream.status {
                reason = value
            }
            entries = stream.tail(10)
            if reason != nil, entries.contains(where: { $0.message == "hello" }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(reason, "logcat exited with status 3", "an exited logcat process must report stopped")
        XCTAssertTrue(entries.contains { $0.message == "hello" })
    }

    /// Output read only after the logcat's exit has been handled is kept,
    /// and the stop is reported once it is in: here a line the fake adb's
    /// child writes after the fake adb itself exited. The pipe used to be
    /// freed with the finished process, taking unread output with it — the
    /// race behind this suite's flaky `testExitedLogcatProcessReportsStopped`,
    /// whose exit could be handled before its one line was read.
    func testOutputReadAfterTheExitIsKeptAndReportedFirst() async throws {
        let fakeADB = try makeFakeAdb(script: """
        #!/bin/sh
        printf '01-01 00:00:00.000  10  11 I Tag: first\\n'
        (sleep 0.5; printf '01-01 00:00:00.001  10  11 I Tag: last\\n') &
        exit 3
        """)
        let stream = LogcatStream(adbURL: fakeADB, serial: "fake-serial")
        stream.start()

        var messagesWhenStopped: [String]?
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if case .stopped = stream.status {
                messagesWhenStopped = stream.snapshot().map(\.message)
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        // Room for a line that would still come (none should).
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(stream.status, .stopped(reason: "logcat exited with status 3"))
        XCTAssertEqual(stream.snapshot().map(\.message), ["first", "last"], "output after the exit was lost")
        XCTAssertEqual(messagesWhenStopped, ["first", "last"], "the stop was reported before the output ended")
    }

    /// A logcat that exits on its own leaves no reader behind: its pipe is
    /// held until end of file, and at the end of file the readability
    /// handler is removed — a handle at end of file calls it again and
    /// again with no data, a core busy for as long as the stream lives.
    func testAnExitedLogcatLeavesNoReaderSpinning() async throws {
        let fakeADB = try makeFakeAdb(script: """
        #!/bin/sh
        printf '01-01 00:00:00.000  10  11 I Tag: bye\\n'
        exit 0
        """)
        let stream = LogcatStream(adbURL: fakeADB, serial: "fake-serial")
        stream.start()
        try await waitUntil(timeout: .seconds(30)) {
            guard case .stopped = stream.status else { return false }
            return stream.snapshot().contains { $0.message == "bye" }
        }
        // Room for the end of the output to be read.
        try await Task.sleep(for: .milliseconds(300))

        let before = Self.processCPUSeconds()
        try await Task.sleep(for: .seconds(1))
        let used = Self.processCPUSeconds() - before

        XCTAssertLessThan(used, 0.5, "the test process used \(used) s of CPU in 1 s of idling after logcat exited")
        withExtendedLifetime(stream) {}
    }

    /// User plus system CPU time this process has used so far.
    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double {
            Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
        }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// A deliberate stop (view closed, package switch) is not a disconnect:
    /// the status stays idle.
    func testDeliberateStopStaysIdle() async throws {
        let fakeADB = try makeFakeAdb(script: """
        #!/bin/sh
        while true; do sleep 1; done
        """)

        let stream = LogcatStream(adbURL: fakeADB, serial: "fake-serial")
        stream.start()
        try await Task.sleep(for: .milliseconds(300))
        stream.stop()
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(stream.status, .idle)
    }

    /// The app stops a stream and drops it in one breath; the terminate used
    /// to be a weak-self block that found the stream gone and left the
    /// `adb logcat` child running forever. A stream released without a stop
    /// must not orphan it either.
    func testStoppingOrReleasingAStreamTerminatesItsLogcat() async throws {
        let device = try FakeFollowDevice()
        var stopped: LogcatStream? = LogcatStream(adbURL: device.adbURL, serial: "fake-serial")
        stopped?.start()
        try await waitUntil { device.runningLogcats() == 1 }

        stopped?.stop()
        stopped = nil
        try await waitUntil { device.runningLogcats() == 0 }

        var released: LogcatStream? = LogcatStream(adbURL: device.adbURL, serial: "fake-serial")
        released?.start()
        try await waitUntil { device.runningLogcats() == 1 }
        try await waitUntil { released?.snapshot().count == 2 }

        released = nil
        try await waitUntil { device.runningLogcats() == 0 }

        // A package-following stream too: its poll loop must not keep it
        // alive.
        device.setPID(100)
        var following: LogcatStream? = LogcatStream(
            adbURL: device.adbURL,
            serial: "fake-serial",
            packageName: "com.example",
            pollInterval: .milliseconds(50)
        )
        following?.start()
        try await waitUntil { device.runningLogcats() == 1 }
        weak let weakFollowing = following
        following = nil
        try await waitUntil { weakFollowing == nil && device.runningLogcats() == 0 }
    }

    // MARK: - Package follow

    /// A followed package whose app is not running must not stream anything:
    /// the status says "waiting" and no logcat runs, so other processes' logs
    /// never reach the view.
    func testFollowedPackageThatIsNotRunningNeverStreamsUnfiltered() async throws {
        let device = try FakeFollowDevice()
        let stream = LogcatStream(
            adbURL: device.adbURL,
            serial: "fake-serial",
            packageName: "com.example",
            pollInterval: .milliseconds(50)
        )
        stream.start()
        defer { stream.stop() }

        try await waitUntil { device.pidofCalls() >= 3 }

        XCTAssertEqual(device.logcatCalls(), [], "no logcat may run while the app is not running")
        XCTAssertEqual(stream.status, .running(pid: nil))
        XCTAssertTrue(stream.snapshot().isEmpty)
    }

    /// The app's process goes away and comes back (here as the same pid,
    /// after a `pidof` hiccup): the stream stops while it is gone, relaunches
    /// with `-T <newest held timestamp>` and drops the boundary line logd
    /// re-sends, so nothing is replayed or duplicated.
    func testFollowRelaunchResumesAfterTheNewestEntryWithoutDuplicates() async throws {
        let device = try FakeFollowDevice()
        device.setPID(100)
        let stream = LogcatStream(
            adbURL: device.adbURL,
            serial: "fake-serial",
            packageName: "com.example",
            pollInterval: .milliseconds(50)
        )
        stream.start()
        defer { stream.stop() }

        try await waitUntil { stream.snapshot().count == 2 }
        XCTAssertEqual(stream.status, .running(pid: 100))

        device.setPID(nil)
        try await waitUntil { stream.status == .running(pid: nil) }
        try await waitUntil { device.runningLogcats() == 0 }

        device.setPID(100)
        try await waitUntil { stream.snapshot().map(\.message).contains("three") }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(stream.snapshot().map(\.message), ["one", "two", "three"])
        XCTAssertEqual(device.logcatCalls(), [
            "-s fake-serial logcat -v threadtime --pid=100",
            "-s fake-serial logcat -v threadtime --pid=100 -T 01-01 00:00:02.000",
        ])
    }

    /// The followed app restarts under a new pid: the previous run's lines
    /// stay, and a marker line separates the two runs.
    func testARestartKeepsThePreviousRunBehindAMarker() async throws {
        let device = try FakeFollowDevice()
        device.setPID(100)
        let stream = LogcatStream(
            adbURL: device.adbURL,
            serial: "fake-serial",
            packageName: "com.example",
            pollInterval: .milliseconds(50)
        )
        stream.start()
        defer { stream.stop() }

        try await waitUntil { stream.snapshot().count == 2 }
        device.setPID(200)
        try await waitUntil { stream.snapshot().map(\.message).contains("second run") }

        let held = stream.snapshot()
        XCTAssertEqual(held.map(\.pid), [100, 100, 200, 200])
        XCTAssertEqual(held[2].tag, LogcatStream.restartMarkerTag)
        XCTAssertEqual(
            held[2].message,
            "── com.example restarted: pid 100 → 200. Lines above are from the previous run. ──"
        )
        XCTAssertEqual(held.map(\.message).filter { $0 != held[2].message }, ["one", "two", "second run"])
    }

    /// `stop()` while a `pidof` is in flight must not relaunch anything: the
    /// cancelled query reads as "no process", which used to queue a stray
    /// unfiltered logcat after the stop.
    func testStopDuringPidQueryNeverRelaunches() async throws {
        let device = try FakeFollowDevice()
        device.setPID(100)
        let stream = LogcatStream(
            adbURL: device.adbURL,
            serial: "fake-serial",
            packageName: "com.example",
            pollInterval: .milliseconds(50)
        )
        stream.start()

        try await waitUntil { stream.status == .running(pid: 100) }
        device.setPIDOfDelay(seconds: 1)
        let calls = device.pidofCalls()
        try await waitUntil { device.pidofCalls() > calls }
        stream.stop()
        try await Task.sleep(for: .milliseconds(1500))

        XCTAssertEqual(stream.status, .idle)
        XCTAssertEqual(device.logcatCalls(), ["-s fake-serial logcat -v threadtime --pid=100"])
        XCTAssertEqual(device.runningLogcats(), 0)
    }

    /// Buffer markers are skipped instead of being glued onto the previous
    /// entry (where "beginning of crash" flagged an unrelated line as a
    /// crash), and a line with invalid UTF-8 is kept, decoded lossily.
    func testMarkersAreSkippedAndInvalidUTF8IsKept() async throws {
        let fakeADB = try makeFakeAdb(script: """
        #!/bin/sh
        printf '01-01 00:00:00.000  10  11 I Choreographer: skipped frames\\n'
        printf -- '--------- beginning of crash\\n'
        printf '01-01 00:00:01.000  10  11 I Tag: caf\\303\\n'
        printf '01-01 00:00:02.000  10  11 I Tag: last\\r\\n'
        exec sleep 30
        """)
        let stream = LogcatStream(adbURL: fakeADB, serial: "fake-serial")
        stream.start()
        defer { stream.stop() }

        try await waitUntil { stream.snapshot().count >= 3 }

        let entries = stream.snapshot()
        XCTAssertEqual(entries.map(\.message), ["skipped frames", "caf\u{FFFD}", "last"])
        XCTAssertFalse(entries.contains { $0.isCrash })
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("condition not met within \(timeout)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A fake `adb` for the package-follow path. `pidof` answers from a state
    /// file (optionally after a delay); `logcat` records its arguments,
    /// emulates logd (a `-T` launch re-sends the boundary line, then prints a
    /// new one) and keeps running until it is terminated.
    private struct FakeFollowDevice {
        let directory: URL
        let adbURL: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("devicehubpro-logcat-follow-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            adbURL = directory.appendingPathComponent("fake-adb")
            let dir = directory.path
            let script = """
            #!/bin/sh
            DIR="\(dir)"
            case "$*" in
              *" shell pidof "*)
                echo x >> "$DIR/pidof-calls"
                if [ -f "$DIR/pidof-delay" ]; then sleep "$(cat "$DIR/pidof-delay")"; fi
                PID="$(cat "$DIR/pid" 2>/dev/null)"
                if [ -n "$PID" ]; then printf '%s\\n' "$PID"; exit 0; fi
                exit 1
                ;;
              *" logcat "*)
                printf '%s\\n' "$*" >> "$DIR/logcat-calls"
                echo x >> "$DIR/logcat-running"
                trap 'echo x >> "$DIR/logcat-exited"; exit 0' TERM
                case "$*" in
                  *"--pid=200 -T "*)
                    printf '01-01 00:00:03.000   200   200 I Tag: second run\\n'
                    ;;
                  *" -T "*)
                    printf '01-01 00:00:02.000   100   100 I Tag: two\\n'
                    printf '01-01 00:00:03.000   100   100 I Tag: three\\n'
                    ;;
                  *)
                    printf -- '--------- beginning of main\\n'
                    printf '01-01 00:00:01.000   100   100 I Tag: one\\n'
                    printf '01-01 00:00:02.000   100   100 I Tag: two\\n'
                    ;;
                esac
                while true; do sleep 0.05; done
                ;;
            esac
            exit 1
            """
            try script.write(to: adbURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adbURL.path)
        }

        func setPID(_ pid: Int?) {
            let url = directory.appendingPathComponent("pid")
            try? (pid.map { "\($0)" } ?? "").write(to: url, atomically: true, encoding: .utf8)
        }

        func setPIDOfDelay(seconds: Double) {
            try? "\(seconds)".write(
                to: directory.appendingPathComponent("pidof-delay"),
                atomically: true,
                encoding: .utf8
            )
        }

        func logcatCalls() -> [String] {
            lines("logcat-calls")
        }

        func pidofCalls() -> Int {
            lines("pidof-calls").count
        }

        func runningLogcats() -> Int {
            lines("logcat-running").count - lines("logcat-exited").count
        }

        private func lines(_ name: String) -> [String] {
            guard let text = try? String(
                contentsOf: directory.appendingPathComponent(name),
                encoding: .utf8
            ) else { return [] }
            return text.split(separator: "\n").map(String.init)
        }
    }

    /// Lines with no logcat header are glued to the entry before them; the
    /// entry's message stops at its cap instead of growing with the flood.
    func testAFloodOfHeaderlessLinesCannotGrowOneMessageWithoutEnd() async throws {
        let fakeADB = try makeFakeAdb(script: """
        #!/usr/bin/perl
        $| = 0; my $i = 0;
        while ($i < 400000) { $i++; print "  at com.example.Frame.method$i(Frame.java:$i) continuation\\n"; }
        """)
        let stream = LogcatStream(adbURL: fakeADB, serial: "fake-serial")
        stream.start()
        defer { stream.stop() }
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if case .stopped = stream.status { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let longest = stream.snapshot().map { $0.message.utf8.count }.max() ?? 0
        XCTAssertGreaterThan(longest, 1_000)
        XCTAssertLessThanOrEqual(longest, LogcatStream.maximumMessageBytes + 200)
    }

    /// Output that never contains a newline is cut into lines, not held whole.
    func testOutputWithoutNewlinesIsCutIntoLines() async throws {
        let fakeADB = try makeFakeAdb(script: """
        #!/usr/bin/perl
        $| = 0; print "x" x 1000000;
        """)
        let stream = LogcatStream(adbURL: fakeADB, serial: "fake-serial")
        stream.start()
        defer { stream.stop() }
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline, stream.snapshot().isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        let longest = stream.snapshot().map { $0.message.utf8.count }.max() ?? 0
        XCTAssertGreaterThan(longest, 0)
        XCTAssertLessThanOrEqual(longest, LogcatStream.maximumMessageBytes + 200)
    }

    /// A producer faster than the parser fills the pipe, not the heap: the
    /// bytes queued for the parser never pass the budget by more than a chunk.
    func testTheQueueForTheParserIsBounded() async throws {
        let fakeADB = try makeFakeAdb(script: """
        #!/usr/bin/perl
        $| = 0; my $i = 0;
        while ($i < 2000000) { $i++; print "10-04 12:00:00.000  1000  1000 I Soak: line $i of a chatty application with a typical message\\n"; }
        """)
        let stream = LogcatStream(adbURL: fakeADB, serial: "fake-serial")
        stream.start()
        defer { stream.stop() }
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if case .stopped = stream.status { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(stream.snapshot().count, 0)
        XCTAssertLessThanOrEqual(stream.peakQueuedBytes, LogcatStream.maximumQueuedBytes + (1 << 20))
    }
}
