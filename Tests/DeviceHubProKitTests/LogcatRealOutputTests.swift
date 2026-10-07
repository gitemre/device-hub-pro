import XCTest
@testable import DeviceHubProKit

/// `LogcatParser` and `LogcatStream` against real `adb logcat -v threadtime`
/// output of an API 37 emulator (see `LogcatSdkApkFixtures`). Expected values
/// were read off the fixtures independently (the tag is everything before the
/// first `": "` of logprint's `"%s %5d %5d %c %-8s: "` header).
final class LogcatRealOutputTests: XCTestCase {
    private func lines(_ name: String) throws -> [String] {
        let text = try LogcatSdkApkFixtures.text(name)
        XCTAssertTrue(text.hasSuffix("\n"), "logcat ends every line with LF")
        XCTAssertFalse(text.contains("\r"), "adb's shell v2 protocol delivers no CR")
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    private func entries(_ name: String) throws -> [LogcatEntry] {
        try lines(name).compactMap { line in
            guard case .entry(let entry) = LogcatParser.parse(line) else { return nil }
            return entry
        }
    }

    /// `adb -s emulator-5554 logcat -d -v threadtime -t 300`: every line is a
    /// header line or one of the two buffer markers.
    func testEveryLineOfARealThreadtimeTailParses() throws {
        let lines = try lines("logcat-d-v-threadtime-t-300.txt")
        XCTAssertEqual(lines.count, 302)
        XCTAssertEqual(lines.filter(LogcatParser.isBufferMarker), [
            "--------- beginning of main",
            "--------- beginning of system",
        ])
        for line in lines where !LogcatParser.isBufferMarker(line) {
            guard case .entry = LogcatParser.parse(line) else {
                return XCTFail("not parsed as an entry: \(line)")
            }
        }

        let entries = try entries("logcat-d-v-threadtime-t-300.txt")
        XCTAssertEqual(entries.count, 300)
        var levels: [LogcatLevel: Int] = [:]
        for entry in entries { levels[entry.level, default: 0] += 1 }
        XCTAssertEqual(levels, [.verbose: 18, .debug: 100, .info: 158, .warning: 11, .error: 13])

        let first = try XCTUnwrap(entries.first)
        XCTAssertEqual(first.timestamp, "09-24 23:14:06.068")
        XCTAssertEqual(first.pid, 8241)
        XCTAssertEqual(first.tid, 8241)
        XCTAssertEqual(first.level, .warning)
        XCTAssertEqual(first.tag, "libbinder.BackendUnifiedServiceManager")
        XCTAssertEqual(
            first.message,
            "Thread Pool max thread count is 0. Cannot cache binder as linkToDeath cannot be implemented. serviceName: SurfaceFlinger"
        )

        // The dump records its own request: adbd's padded 4-letter tag.
        let last = try XCTUnwrap(entries.last)
        XCTAssertEqual(last.timestamp, "09-24 23:14:36.882")
        XCTAssertEqual(last.pid, 525)
        XCTAssertEqual(last.tid, 525)
        XCTAssertEqual(last.level, .info)
        XCTAssertEqual(last.tag, "adbd")
        XCTAssertEqual(
            last.message,
            "adbd service requested 'shell,v2:export ANDROID_LOG_TAGS=''; exec logcat '-d' '-v' 'threadtime' '-t' '300''"
        )
    }

    /// `logcat -d -v threadtime --pid=495` (audioserver): its tags contain
    /// colons (`AF::TrackHandle`). The tag ends at the first `": "`; cutting
    /// at the first colon turned every one of them into tag `AF` with a
    /// `:TrackHandle: …` message, so a tag filter never matched them.
    func testTagsContainingColonsKeepTheirFullName() throws {
        let entries = try entries("logcat-d-v-threadtime-pid-495.txt")
        XCTAssertEqual(entries.count, 140)
        XCTAssertTrue(entries.allSatisfy { $0.pid == 495 })

        var tags: [String: Int] = [:]
        for entry in entries { tags[entry.tag, default: 0] += 1 }
        XCTAssertEqual(tags, [
            "libbinder.IPCThreadState": 42,
            "AudioFlinger": 36,
            "APM_AudioPolicyManager": 22,
            "AF::AfPlaybackCommon": 13,
            "AudioPolicyInterfaceImpl": 10,
            "AudioTrackShared": 10,
            "audioserver_main": 6,
            "AF::TrackHandle": 1,
        ])

        let handle = try XCTUnwrap(entries.first { $0.tag == "AF::TrackHandle" })
        XCTAssertEqual(handle.timestamp, "09-24 22:56:44.536")
        XCTAssertEqual(handle.tid, 507)
        XCTAssertEqual(handle.level, .info)
        // The message keeps the trailing space the device logged.
        XCTAssertEqual(handle.message, "opChanged OP_PLAY_AUDIO callback received for ")

        let playback = try XCTUnwrap(entries.first { $0.tag == "AF::AfPlaybackCommon" })
        XCTAssertEqual(playback.timestamp, "09-24 22:56:44.528")
        XCTAssertEqual(playback.tid, 726)
        XCTAssertEqual(
            playback.message,
            "AfPlaybackCommon: creating track with enforcement level 0 reason PRIVILEGED_APP shouldHarden 1"
        )
    }

    /// `logcat -d -v threadtime --pid=7774`
    /// (com.example.messages:rcs): ART's default tag is the
    /// truncated process name, colon included; short tags are padded to
    /// eight columns before the colon.
    func testProcessNameTagsAndPaddedShortTags() throws {
        let entries = try entries("logcat-d-v-threadtime-pid-7774.txt")
        XCTAssertEqual(entries.count, 88)
        XCTAssertEqual(entries.filter { $0.tag == "s.messaging:rcs" }.count, 4)
        XCTAssertFalse(entries.contains { $0.tag == "s.messaging" })

        let gc = try XCTUnwrap(entries.first { $0.tag == "s.messaging:rcs" })
        XCTAssertEqual(gc.timestamp, "09-24 23:08:36.390")
        XCTAssertEqual(gc.message, "Using generational CollectorTypeCMC GC.")

        let stetho = try XCTUnwrap(entries.first { $0.tag == "stetho" })
        XCTAssertEqual(stetho.tid, 7813)
        XCTAssertEqual(
            stetho.message,
            "Listening on @stetho_com.example.messages:rcs_devtools_remote"
        )
        let bugle = try XCTUnwrap(entries.first { $0.tag == "Bugle" })
        XCTAssertEqual(
            bugle.message,
            "BugleApplicationBase: Bugle version: messages.android_20260903_04_rc04.phone_dynamic , Bugle version code: 322660063"
        )
    }

    /// `logcat -d -v threadtime --pid=4628` (android.process.acore): a
    /// message with non-ASCII text (`…`, Greek capitals) and a tag padded
    /// past a short name (`Looper  :`).
    func testNonASCIIMessagesAndThePaddedLastLine() throws {
        let entries = try entries("logcat-d-v-threadtime-pid-4628.txt")
        XCTAssertEqual(entries.count, 61)

        let labels = try XCTUnwrap(entries.first { $0.tag == "ContactLocale" })
        XCTAssertEqual(labels.timestamp, "09-24 23:05:44.069")
        XCTAssertEqual(labels.tid, 4646)
        XCTAssertTrue(
            labels.message.hasPrefix("AddressBook Labels [[en_US]]: […, A, B, C, D,"),
            labels.message
        )
        XCTAssertTrue(labels.message.contains("Z, Α, Β, Γ, Δ, Ε, Ζ, Η, Θ"), labels.message)

        let last = try XCTUnwrap(entries.last)
        XCTAssertEqual(last.tag, "Looper")
        XCTAssertEqual(last.level, .warning)
        XCTAssertEqual(last.message, "Drained")
    }

    /// SOURCE-DERIVED (the emulator's crash buffer was empty): an app crash
    /// as `RuntimeInit.logUncaught` (frameworks/base, `TAG =
    /// "AndroidRuntime"`) logs it — one multi-line message, which logprint
    /// prints with the full threadtime header on every line, stack frames
    /// starting with a tab.
    func testAppCrashLinesInThreadtimeLayout() throws {
        let lines = [
            "09-24 23:40:01.123  4321  4321 E AndroidRuntime: FATAL EXCEPTION: main",
            "09-24 23:40:01.123  4321  4321 E AndroidRuntime: Process: com.example.crash, PID: 4321",
            "09-24 23:40:01.123  4321  4321 E AndroidRuntime: java.lang.IllegalStateException: boom",
            "09-24 23:40:01.123  4321  4321 E AndroidRuntime: \tat com.example.crash.MainActivity.onCreate(MainActivity.kt:12)",
        ]
        let entries = lines.compactMap { line -> LogcatEntry? in
            guard case .entry(let entry) = LogcatParser.parse(line) else { return nil }
            return entry
        }
        XCTAssertEqual(entries.count, 4)
        XCTAssertTrue(entries.allSatisfy { $0.tag == "AndroidRuntime" && $0.level == .error })
        XCTAssertEqual(entries.map(\.isCrash), [true, true, false, false])
        XCTAssertEqual(entries[3].message, "\tat com.example.crash.MainActivity.onCreate(MainActivity.kt:12)")
    }

    // MARK: - LogcatStream on real bytes

    /// The stream ingests a real dump end to end: markers dropped, every
    /// entry parsed with its full tag, nothing glued onto a neighbour.
    func testStreamIngestsARealDump() async throws {
        let directory = try LogcatSdkApkFixtures.temporaryDirectory(self, prefix: "logcat-real")
        let fixture = LogcatSdkApkFixtures.url("logcat-d-v-threadtime-pid-495.txt")
        let adb = try LogcatSdkApkFixtures.script("""
            #!/bin/sh
            cat "\(fixture.path)"
            exec sleep 30
            """, named: "adb", in: directory)

        let stream = LogcatStream(adbURL: adb, serial: "emulator-5554")
        stream.start()
        defer { stream.stop() }
        try await waitUntil { stream.snapshot().count >= 140 }
        try await Task.sleep(for: .milliseconds(200))

        let entries = stream.snapshot()
        XCTAssertEqual(entries.count, 140)
        XCTAssertFalse(entries.contains { $0.message.contains("---------") })
        XCTAssertFalse(entries.contains { $0.message.contains("\n") })
        XCTAssertEqual(entries.filter { $0.tag == "AF::AfPlaybackCommon" }.count, 13)
    }

    /// `adb shell pidof init` answers `1 102\n` (two processes share the
    /// name): the stream follows the first pid.
    func testFollowedPackageUsesTheFirstPidOfARealPidofAnswer() async throws {
        XCTAssertEqual(try LogcatSdkApkFixtures.data("shell-pidof-init.txt"), Data("1 102\n".utf8))
        let (stream, calls) = try makeFollowStream(pidof: "shell-pidof-init.txt", exitCode: 0)
        stream.start()
        defer { stream.stop() }

        try await waitUntil { stream.status == .running(pid: 1) }
        try await waitUntil { (try? String(contentsOf: calls, encoding: .utf8))?.isEmpty == false }
        XCTAssertEqual(
            try String(contentsOf: calls, encoding: .utf8),
            "-s emulator-5554 logcat -v threadtime --pid=1\n"
        )
    }

    /// `adb shell pidof com.android.systemui` answers `906\n`.
    func testFollowedPackageUsesARealSinglePid() async throws {
        let (stream, _) = try makeFollowStream(pidof: "shell-pidof-com.android.systemui.txt", exitCode: 0)
        stream.start()
        defer { stream.stop() }
        try await waitUntil { stream.status == .running(pid: 906) }
    }

    /// A package that is not running: `pidof` prints nothing and exits 1
    /// (captured for `com.example.messages` after it stopped).
    /// No logcat may run.
    func testAPackageThatIsNotRunningStreamsNothing() async throws {
        XCTAssertEqual(try LogcatSdkApkFixtures.data("shell-pidof-not-running.txt"), Data())
        let (stream, calls) = try makeFollowStream(pidof: "shell-pidof-not-running.txt", exitCode: 1)
        stream.start()
        defer { stream.stop() }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(stream.status, .running(pid: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path))
    }

    // MARK: - Helpers

    private func makeFollowStream(pidof fixture: String, exitCode: Int32) throws -> (LogcatStream, URL) {
        let directory = try LogcatSdkApkFixtures.temporaryDirectory(self, prefix: "logcat-follow-real")
        let calls = directory.appendingPathComponent("logcat-calls")
        let pidof = LogcatSdkApkFixtures.url(fixture)
        let adb = try LogcatSdkApkFixtures.script("""
            #!/bin/sh
            case "$*" in
              *" shell pidof "*) cat "\(pidof.path)"; exit \(exitCode) ;;
              *" logcat "*) printf '%s\\n' "$*" >> "\(calls.path)"; exec sleep 30 ;;
            esac
            exit 1
            """, named: "adb", in: directory)
        let stream = LogcatStream(
            adbURL: adb,
            serial: "emulator-5554",
            packageName: "com.example.followed",
            pollInterval: .milliseconds(100)
        )
        return (stream, calls)
    }

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
}
