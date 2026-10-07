import XCTest
@testable import DeviceHubProKit

final class AdbClientTests: XCTestCase {
    func testDataPathMapsPackageToOnDeviceDirectory() {
        XCTAssertEqual(
            AdbClient.dataPath(package: "com.example.app"),
            "/data/data/com.example.app"
        )
        XCTAssertEqual(
            AdbClient.dataPath(package: "com.example.automation.server"),
            "/data/data/com.example.automation.server"
        )
    }

    func testRecordingFileNameUsesTheDeviceAndTimestamp() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 17, hour: 12, minute: 34, second: 56
        ))!

        XCTAssertEqual(
            AdbClient.recordingFileName(
                device: "Medium Phone",
                date: date,
                timeZone: calendar.timeZone
            ),
            "Medium-Phone-20260917-123456.mp4"
        )
        XCTAssertEqual(
            AdbClient.recordingFileName(
                device: "R58/M:123",
                date: date,
                timeZone: calendar.timeZone
            ),
            "R58-M-123-20260917-123456.mp4"
        )
    }

    func testStopAndPullInterruptsPullsAndDeletesTheDeviceCopy() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdbClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fakeClip = directory.appendingPathComponent("fake.mp4")
        try Data("mp4-bytes".utf8).write(to: fakeClip)
        let traceURL = directory.appendingPathComponent("calls.log")
        let adbURL = directory.appendingPathComponent("adb")

        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(traceURL.path)"
        case "$*" in
          *"shell pkill -INT -f "*) exit 0 ;;
          *"pull "*) for last; do :; done; cp "\(fakeClip.path)" "$last" ;;
          *"shell rm -f /sdcard/devicehubpro-rec-1.mp4") exit 0 ;;
          *) printf 'unexpected: %s\\n' "$*" >&2; exit 1 ;;
        esac
        """
        try Data(script.utf8).write(to: adbURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: adbURL.path
        )

        let destination = directory.appendingPathComponent("out.mp4")
        let client = AdbClient(adbURL: adbURL)
        try await client.stopScreenRecordAndPull(
            serial: "emulator-5554",
            remotePath: "/sdcard/devicehubpro-rec-1.mp4",
            to: destination,
            settle: .zero
        )

        let calls = try String(contentsOf: traceURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        // Only the recorder writing this clip is interrupted (F12): the
        // pattern names the path, and `[s]` keeps it from matching the
        // device shell that runs pkill.
        XCTAssertEqual(calls, [
            "-s emulator-5554 shell pkill -INT -f '[s]creenrecord.*/sdcard/devicehubpro-rec-1.mp4'",
            "-s emulator-5554 pull /sdcard/devicehubpro-rec-1.mp4 \(destination.path)",
            "-s emulator-5554 shell rm -f /sdcard/devicehubpro-rec-1.mp4",
        ])
        XCTAssertEqual(try Data(contentsOf: destination), Data("mp4-bytes".utf8))
    }

    /// `screenrecord` stops by itself at 180 s unless given `--time-limit 0`,
    /// which only newer builds accept (older ones refuse to start). The
    /// device-side line picks the form the build supports and `exec`s, so the
    /// recording process is screenrecord itself with the path it writes.
    func testScreenRecordLiftsTheTimeLimitWhereTheDeviceSupportsIt() {
        let command = AdbClient.screenRecordCommand(
            remotePath: "/sdcard/devicehubpro-rec-2.mp4",
            bitRate: 8_000_000
        )
        XCTAssertEqual(
            command,
            "if screenrecord --help 2>&1 | grep -q 'remove the time limit'; "
                + "then exec screenrecord --bit-rate 8000000 --time-limit 0 /sdcard/devicehubpro-rec-2.mp4; "
                + "else exec screenrecord --bit-rate 8000000 /sdcard/devicehubpro-rec-2.mp4; fi"
        )
    }

    /// The line runs as written under a POSIX shell, taking the unlimited
    /// branch only when the help text offers it.
    func testScreenRecordCommandPicksTheBranchFromTheHelpText() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdbClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = AdbClient.screenRecordCommand(remotePath: "/sdcard/x.mp4", bitRate: 4)

        for (help, expected) in [
            ("Set the maximum recording time. Default is 180. Set to 0\\n to remove the time limit.", "--bit-rate 4 --time-limit 0 /sdcard/x.mp4"),
            ("Set the maximum recording time, in seconds. Default / maximum is 180.", "--bit-rate 4 /sdcard/x.mp4"),
        ] {
            let fake = directory.appendingPathComponent("screenrecord")
            let script = """
            #!/bin/sh
            if [ "$1" = "--help" ]; then printf '\(help)\\n' >&2; exit 0; fi
            echo "$@"
            """
            try Data(script.utf8).write(to: fake)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ["PATH": "\(directory.path):/usr/bin:/bin"]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            process.waitUntilExit()
            let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(printed.trimmingCharacters(in: .whitespacesAndNewlines), expected)
        }
    }

    func testDiscardInterruptsOnlyItsRecorderAndDeletesTheFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdbClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let traceURL = directory.appendingPathComponent("calls.log")
        let adbURL = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(traceURL.path)"
        """
        try Data(script.utf8).write(to: adbURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adbURL.path)

        await AdbClient(adbURL: adbURL).discardScreenRecord(
            serial: "R58M",
            remotePath: "/sdcard/devicehubpro-rec-3.mp4"
        )

        let calls = try String(contentsOf: traceURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(calls, [
            "-s R58M shell pkill -INT -f '[s]creenrecord.*/sdcard/devicehubpro-rec-3.mp4'",
            "-s R58M shell rm -f /sdcard/devicehubpro-rec-3.mp4",
        ])
    }

    func testRunReturnsStandardOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdbClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let traceURL = directory.appendingPathComponent("calls.log")
        let adbURL = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(traceURL.path)"
        printf '27183\\n'
        """
        try Data(script.utf8).write(to: adbURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: adbURL.path
        )

        let client = AdbClient(adbURL: adbURL)
        let output = try await client.run(["-s", "emulator-5554", "forward", "tcp:0", "localabstract:scrcpy"])

        XCTAssertEqual(output, "27183\n")
        let calls = try String(contentsOf: traceURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(calls, "-s emulator-5554 forward tcp:0 localabstract:scrcpy")
    }

    // MARK: - TalkBack and shell quoting (F4)

    /// A fake adb that logs its argv and answers `settings get` from
    /// `servicesReply` (or fails it with exit 1 when nil).
    private func makeSettingsStub(servicesReply: String?) throws -> (client: AdbClient, calls: () -> [String]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdbClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let traceURL = directory.appendingPathComponent("calls.log")
        let replyURL = directory.appendingPathComponent("reply")
        if let servicesReply {
            try Data(servicesReply.utf8).write(to: replyURL)
        }
        let adbURL = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(traceURL.path)"
        case "$*" in
          *"settings get secure enabled_accessibility_services")
            if [ -f "\(replyURL.path)" ]; then cat "\(replyURL.path)"; exit 0; fi
            printf 'error: closed\\n' >&2
            exit 1 ;;
        esac
        exit 0
        """
        try Data(script.utf8).write(to: adbURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adbURL.path)
        let calls = {
            ((try? String(contentsOf: traceURL, encoding: .utf8)) ?? "")
                .split(separator: "\n")
                .map(String.init)
        }
        return (AdbClient(adbURL: adbURL), calls)
    }

    /// A failed read of the service list must abort the toggle: treating it
    /// as "no services" would replace the list with TalkBack alone (enable)
    /// or delete every enabled service (disable).
    func testTalkBackToggleAbortsWhenTheServiceListCannotBeRead() async throws {
        for enabled in [true, false] {
            let stub = try makeSettingsStub(servicesReply: nil)
            do {
                try await stub.client.setTalkBack(
                    serial: "R58M",
                    enabled: enabled,
                    packageID: TalkBack.gmsPackageID
                )
                XCTFail("expected the failed read to throw")
            } catch is AdbError {
                // expected
            }
            XCTAssertEqual(
                stub.calls(),
                ["-s R58M shell settings get secure enabled_accessibility_services"],
                "nothing may be written after a failed read (enabled: \(enabled))"
            )
        }
    }

    /// Other services survive the toggle, and a component with shell syntax
    /// (a nested-class service `pkg/.Outer$Svc`) is quoted so the device's
    /// `sh` cannot expand `$Svc` to nothing.
    func testTalkBackKeepsOtherServicesAndQuotesThemForTheDeviceShell() async throws {
        let stub = try makeSettingsStub(servicesReply: "com.x/.Outer$Svc\n")
        try await stub.client.setTalkBack(
            serial: "R58M",
            enabled: true,
            packageID: TalkBack.gmsPackageID
        )
        let talkBack = TalkBack.serviceComponent(for: TalkBack.gmsPackageID)
        XCTAssertEqual(stub.calls(), [
            "-s R58M shell settings get secure enabled_accessibility_services",
            "-s R58M shell settings put secure enabled_accessibility_services 'com.x/.Outer$Svc:\(talkBack)'",
            "-s R58M shell settings put secure accessibility_enabled 1",
        ])
    }

    func testShellQuotingLeavesPlainWordsAndQuotesTheRest() {
        XCTAssertEqual(AdbClient.shellQuoted("1"), "1")
        XCTAssertEqual(AdbClient.shellQuoted("1.0"), "1.0")
        XCTAssertEqual(
            AdbClient.shellQuoted("com.a/.A:com.b/com.b.B"),
            "com.a/.A:com.b/com.b.B"
        )
        XCTAssertEqual(AdbClient.shellQuoted("pkg/.Outer$Svc"), "'pkg/.Outer$Svc'")
        XCTAssertEqual(AdbClient.shellQuoted("two words"), "'two words'")
        XCTAssertEqual(AdbClient.shellQuoted("it's"), "'it'\\''s'")
        XCTAssertEqual(AdbClient.shellQuoted(""), "''")
    }

    func testRunThrowsOnANonZeroExit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdbClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let adbURL = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        printf 'adb: error: cannot bind listener\\n' >&2
        exit 1
        """
        try Data(script.utf8).write(to: adbURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: adbURL.path
        )

        let client = AdbClient(adbURL: adbURL)
        do {
            _ = try await client.run(["-s", "serial", "forward", "tcp:0", "localabstract:scrcpy"])
            XCTFail("expected the non-zero exit to throw")
        } catch let error as AdbError {
            XCTAssertTrue(
                error.description.contains("cannot bind listener"),
                "the failure must carry adb's stderr: \(error.description)"
            )
        }
    }
}
