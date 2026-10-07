import XCTest
@testable import DeviceHubProKit

/// Byte-exact device output under `Fixtures/api37-emulator/conditions`,
/// captured from the API 37 emulator (`emulator-5554`, google_apis_playstore,
/// emulator 37.2.8) with the exact command each call site runs: the probes'
/// `*.command.txt` files are those commands, byte for byte.
enum ConditionsAPI37Fixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/api37-emulator/conditions", isDirectory: true)

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func text(_ name: String) throws -> String {
        let data = try Data(contentsOf: url(name))
        return try XCTUnwrap(String(data: data, encoding: .utf8), "\(name) is UTF-8")
    }
}

/// The Network and App conditions parsers fed that output. Every expected
/// value is what the device reported, read off the capture itself (or, where
/// named, from a second command at capture time); none is computed by the
/// parser under test.
///
/// Recapture with the command in the matching `.command.txt` (for a probe)
/// or the one named in the test, e.g.
/// `adb -s emulator-5554 emu network status > emu-network-status-none.txt`.
final class ConditionsDeviceOutputTests: XCTestCase {
    // MARK: - Probe scripts

    /// The fixtures are the output of the current probe scripts: a script
    /// change needs a recapture.
    ///
    /// One exception, checked on this image: the app probes' process grep
    /// gained `|isFrozen=` (for the API 31–36 freezer line, see
    /// `testTheFreezerLineOfOlderReleases`) and dropped `isPendingFreeze`
    /// from its anchored names after the app-probe captures. On API 37 the
    /// freezer line starts with `isPendingFreeze=` and is the only one with
    /// `isFrozen=`, so both greps keep the same lines: on 2026-09-25 they
    /// printed identical output (`cmp`) over one full `dumpsys activity
    /// processes` of 57 processes, 43 of them frozen.
    func testTheProbeFixturesComeFromTheCurrentProbeScripts() throws {
        XCTAssertEqual(try ConditionsAPI37Fixture.text("network-probe.command.txt"), NetworkConditionsSnapshot.probeScript)
        XCTAssertEqual(
            try ConditionsAPI37Fixture.text("app-probe-music-app.command.txt"),
            AppConditionsSnapshot.probeScript(package: "com.example.musicplayer")
        )
        XCTAssertEqual(
            try ConditionsAPI37Fixture.text("app-probe-docs.command.txt"),
            AppConditionsSnapshot.probeScript(package: "com.example.docs")
        )
        XCTAssertEqual(
            try ConditionsAPI37Fixture.text("app-probe-settings.command.txt"),
            AppConditionsSnapshot.probeScript(package: "com.android.settings")
        )
        XCTAssertEqual(try ConditionsAPI37Fixture.text("app-probe-no-target.command.txt"), AppConditionsSnapshot.probeScript(package: nil))
        XCTAssertEqual(try ConditionsAPI37Fixture.text("foreground.command.txt"), AppConditionsSnapshot.foregroundScript)
    }

    // MARK: - Network probe

    /// Wi-Fi on, mobile data off (the AVD's default): network 107 on
    /// `wlan0` is the only agent, so the meter is not observable.
    func testTheWifiProbe() throws {
        let snapshot = NetworkConditionsSnapshot.parse(try ConditionsAPI37Fixture.text("network-probe-wifi.txt"))
        XCTAssertEqual(snapshot.apiLevel, 37)
        XCTAssertEqual(snapshot.connectivity.defaultNetworkID, 107)
        XCTAssertEqual(snapshot.connectivity.dataPath, .wifi)
        XCTAssertEqual(snapshot.connectivity.defaultAgent?.interfaceName, "wlan0")
        XCTAssertEqual(snapshot.connectivity.defaultAgent?.transports, ["WIFI"])
        XCTAssertTrue(snapshot.connectivity.defaultAgent?.capabilities.contains("NOT_METERED") == true)
        XCTAssertNil(snapshot.connectivity.cellularAgent)
        XCTAssertNil(snapshot.connectivity.isMobileDataMetered)
        XCTAssertEqual(snapshot.cellService?.option, .inService)
        // `ssRsrp = -49 … level = 4`, primary=CellSignalStrengthNr.
        XCTAssertEqual(snapshot.signal, SignalReading(level: 4, dbm: -49))
        XCTAssertEqual(snapshot.wifiOn, "1")
        XCTAssertEqual(snapshot.mobileData, "0")
    }

    /// After `svc wifi disable` + `svc data enable`: network 108 on `eth0`
    /// (CELLULAR), metered (no TEMPORARILY_NOT_METERED).
    func testTheMobileDataProbe() throws {
        let snapshot = NetworkConditionsSnapshot.parse(try ConditionsAPI37Fixture.text("network-probe-mobile-data.txt"))
        XCTAssertEqual(snapshot.connectivity.defaultNetworkID, 108)
        XCTAssertEqual(snapshot.connectivity.dataPath, .mobileData)
        XCTAssertEqual(snapshot.connectivity.cellularAgent?.interfaceName, "eth0")
        XCTAssertEqual(snapshot.connectivity.isMobileDataMetered, true)
        XCTAssertEqual(snapshot.cellService?.option, .inService)
        XCTAssertEqual(snapshot.signal, SignalReading(level: 3, dbm: -68))
        XCTAssertEqual(snapshot.wifiOn, "0")
        XCTAssertEqual(snapshot.mobileData, "1")
    }

    /// After `gsm meter off` (`emu-gsm-meter-off.txt` answered OK): the
    /// mobile agent gained TEMPORARILY_NOT_METERED, not NOT_METERED.
    func testTheMeterOffProbe() throws {
        XCTAssertEqual(try ConditionsAPI37Fixture.text("emu-gsm-meter-off.txt"), "OK\r\n")
        let snapshot = NetworkConditionsSnapshot.parse(try ConditionsAPI37Fixture.text("network-probe-mobile-data-meter-off.txt"))
        XCTAssertEqual(snapshot.connectivity.isMobileDataMetered, false)
        XCTAssertFalse(snapshot.connectivity.cellularAgent?.capabilities.contains("NOT_METERED") == true)
        XCTAssertEqual(snapshot.signal, SignalReading(level: 2, dbm: -83))
    }

    /// After `gsm data unregistered` + `gsm voice unregistered`: both
    /// domains out of service; the mobile network is still the default.
    func testTheNoServiceProbe() throws {
        let snapshot = NetworkConditionsSnapshot.parse(try ConditionsAPI37Fixture.text("network-probe-no-service.txt"))
        XCTAssertEqual(snapshot.cellService?.option, .noService)
        XCTAssertEqual(snapshot.cellService?.voiceName, "OUT_OF_SERVICE")
        XCTAssertEqual(snapshot.cellService?.dataState, 1)
        XCTAssertEqual(snapshot.connectivity.dataPath, .mobileData)
        XCTAssertEqual(snapshot.signal, SignalReading(level: 1, dbm: -92))
    }

    /// After `svc wifi disable` with mobile data already off: no default
    /// network and no agent, while the modem stays registered.
    func testTheNoNetworkProbe() throws {
        let snapshot = NetworkConditionsSnapshot.parse(try ConditionsAPI37Fixture.text("network-probe-no-network.txt"))
        XCTAssertTrue(snapshot.connectivity.answered)
        XCTAssertNil(snapshot.connectivity.defaultNetworkID)
        XCTAssertEqual(snapshot.connectivity.agents, [])
        XCTAssertEqual(snapshot.connectivity.dataPath, .noNetwork)
        XCTAssertNil(snapshot.connectivity.isMobileDataMetered)
        XCTAssertEqual(snapshot.cellService?.option, .inService)
        XCTAssertEqual(snapshot.signal, SignalReading(level: 4, dbm: -59))
        XCTAssertEqual(snapshot.wifiOn, "0")
        XCTAssertEqual(snapshot.mobileData, "0")
    }

    // MARK: - Console

    /// `adb -s emulator-5554 emu avd discoverypath` from a later process of
    /// the same AVD than `adb-core/emu-avd-discoverypath.txt` (pid 71988):
    /// the file name carries the emulator's process id, which is what tells
    /// two emulators on one serial apart. The home directory is replaced by
    /// a same-length placeholder.
    func testASecondProcessNamesItsOwnDiscoveryFile() throws {
        XCTAssertEqual(
            AdbParsing.discoveryPath(from: try ConditionsAPI37Fixture.text("emu-avd-discoverypath-second-process.txt")),
            "/Users/testeruser/Library/Caches/TemporaryItems/avd/running/pid_20284.ini"
        )
    }

    // MARK: - App probe

    /// A music app cached and frozen (`curProcState=19`), trim level 0,
    /// its newest exit a package update.
    func testACachedAppProbe() throws {
        let package = "com.example.musicplayer"
        let snapshot = AppConditionsSnapshot.parse(try ConditionsAPI37Fixture.text("app-probe-music-app-cached.txt"), package: package)
        XCTAssertEqual(snapshot.apiLevel, 37)
        XCTAssertEqual(snapshot.pids, [3310])
        XCTAssertEqual(
            snapshot.runningProcess,
            AppProcessState(processName: package, pid: 3310, trimMemoryLevel: 0, procState: 19, isFrozen: true)
        )
        XCTAssertEqual(snapshot.mainPid, 3310)
        XCTAssertEqual(snapshot.lastExit?.reason, 16)
        XCTAssertEqual(snapshot.lastExit?.reasonName, "PACKAGE UPDATED")
        XCTAssertEqual(snapshot.lastExit?.pid, 23633)
        XCTAssertEqual(snapshot.memoryFactor, .normal)
        XCTAssertEqual(TrimMemoryGate.evaluate(.runningLow, process: snapshot.runningProcess, apiLevel: 37), .allowed)
        XCTAssertEqual(TrimMemoryGate.evaluate(.complete, process: snapshot.runningProcess, apiLevel: 37), .allowed)
    }

    /// After `am send-trim-memory --user current … RUNNING_LOW` (exit 0,
    /// no output): the process records level 10, so 5 and 10 are refused.
    func testATrimmedAppProbe() throws {
        let package = "com.example.musicplayer"
        let snapshot = AppConditionsSnapshot.parse(try ConditionsAPI37Fixture.text("app-probe-music-app-trimmed.txt"), package: package)
        XCTAssertEqual(snapshot.runningProcess?.trimMemoryLevel, 10)
        XCTAssertEqual(TrimMemoryGate.evaluate(.runningLow, process: snapshot.runningProcess, apiLevel: 37), .notHigher(current: 10))
        XCTAssertEqual(TrimMemoryGate.evaluate(.runningModerate, process: snapshot.runningProcess, apiLevel: 37), .notHigher(current: 10))
        XCTAssertEqual(TrimMemoryGate.evaluate(.runningCritical, process: snapshot.runningProcess, apiLevel: 37), .allowed)
    }

    /// After `am kill --user current …` (exit 0): no pid, and the newest
    /// exit record is that pid's USER REQUESTED / KILL BACKGROUND.
    func testAKilledAppProbe() throws {
        let package = "com.example.musicplayer"
        let snapshot = AppConditionsSnapshot.parse(try ConditionsAPI37Fixture.text("app-probe-music-app-killed.txt"), package: package)
        XCTAssertEqual(snapshot.pids, [])
        XCTAssertFalse(snapshot.isRunning)
        XCTAssertNil(snapshot.process)
        XCTAssertEqual(
            snapshot.lastExit,
            ProcessExitRecord(
                timestamp: "2026-09-25 13:36:21.126",
                pid: 3310,
                processName: package,
                reason: ProcessExitRecord.userRequestedReason,
                reasonName: "USER REQUESTED",
                subreason: 24,
                subreasonName: "KILL BACKGROUND",
                description: "kill background"
            )
        )
        XCTAssertEqual(snapshot.lastExit?.summary, "USER REQUESTED · KILL BACKGROUND")
        XCTAssertEqual(TrimMemoryGate.evaluate(.runningLow, process: snapshot.runningProcess, apiLevel: 37), .notRunning)
    }

    /// Drive cached and frozen; then `am crash 29437` (exit 0): `pidof` is
    /// empty while AMS still lists the dead record, and the newest exit is
    /// the crash.
    func testACrashedAppProbe() throws {
        let package = "com.example.docs"
        let before = AppConditionsSnapshot.parse(try ConditionsAPI37Fixture.text("app-probe-docs-frozen.txt"), package: package)
        XCTAssertEqual(before.mainPid, 29437)
        XCTAssertEqual(before.runningProcess?.isFrozen, true)

        let after = AppConditionsSnapshot.parse(try ConditionsAPI37Fixture.text("app-probe-docs-crashed.txt"), package: package)
        XCTAssertEqual(after.pids, [])
        XCTAssertEqual(after.process?.pid, 29437, "AMS still lists the record")
        XCTAssertNil(after.runningProcess, "but pidof decides")
        XCTAssertNil(after.mainPid)
        XCTAssertEqual(after.lastExit?.pid, 29437)
        XCTAssertEqual(after.lastExit?.reason, ProcessExitRecord.crashReason)
        XCTAssertEqual(after.lastExit?.reasonName, "APP CRASH(EXCEPTION)")
        XCTAssertEqual(after.lastExit?.description, "crash")
        XCTAssertEqual(after.lastExit?.summary, "APP CRASH(EXCEPTION)")
    }

    /// SOURCE-DERIVED: API 31–36 print the freezer state on a line that
    /// does not start with `isPendingFreeze=`, and only the API 37 emulator
    /// may be used here, so these layouts cannot be captured. From
    /// `services/core/java/com/android/server/am/ProcessCachedOptimizerRecord.java`
    /// `dump()`: android-12.0.0_r1 (L208–210) starts the line with
    /// `isFreezeExempt=`; android-13.0.0_r1 (L220–225), android-15.0.0_r1
    /// (L350–355) and android-16.0.0_r1 (L434–439) print
    /// `hasPendingCompaction=` with no newline, so the line starts there.
    /// Each layout replaces the API 37 capture's freezer line. The dropped
    /// lines below are from the same API 37 process's full dump
    /// (2026-09-25). The host's `grep -E` stands in for the device's
    /// (toybox); the pattern is plain POSIX ERE.
    func testTheFreezerLineOfOlderReleases() throws {
        let package = "com.example.docs"
        let pattern = AppConditionsSnapshot.processLinesPattern
        let capture = try ConditionsAPI37Fixture.text("app-probe-docs-frozen.txt")
        let api37Line = "    isPendingFreeze=false isFrozen=true \n"
        XCTAssertTrue(capture.contains(api37Line))
        XCTAssertEqual(try grepE(pattern, api37Line), api37Line)

        for line in [
            "    isFreezeExempt=false isPendingFreeze=false isFrozen=true\n",
            "    hasPendingCompaction=false    isFreezeExempt=false isPendingFreeze=false isFrozen=true\n",
        ] {
            XCTAssertEqual(try grepE(pattern, line), line, "the probe keeps the line")
            let snapshot = AppConditionsSnapshot.parse(capture.replacingOccurrences(of: api37Line, with: line), package: package)
            XCTAssertEqual(snapshot.runningProcess?.isFrozen, true, line)
            XCTAssertEqual(snapshot.runningProcess?.trimMemoryLevel, 0, "the other fields still parse")
        }

        let dropped = "    lastCompactTime=13737660 lastCompactProfile=FULL \n    hasPendingCompaction=false \n    earliestFreezableTimeMs=-7m34s795ms\n"
        XCTAssertEqual(try grepE(pattern, dropped), "")
    }

    /// Settings on top (`curProcState=2`): background levels are gated,
    /// matching AMS's refusal in `am-send-trim-memory-foreground.stderr.txt`.
    func testAForegroundAppProbe() throws {
        let snapshot = AppConditionsSnapshot.parse(
            try ConditionsAPI37Fixture.text("app-probe-settings-foreground.txt"),
            package: "com.android.settings"
        )
        XCTAssertEqual(snapshot.runningProcess?.procState, 2)
        XCTAssertEqual(snapshot.runningProcess?.isFrozen, false)
        XCTAssertEqual(TrimMemoryGate.evaluate(.uiHidden, process: snapshot.runningProcess, apiLevel: 37), .foreground(procState: 2))
        XCTAssertEqual(TrimMemoryGate.evaluate(.runningModerate, process: snapshot.runningProcess, apiLevel: 37), .allowed)
        XCTAssertEqual(snapshot.lastExit?.subreasonName, "FORCE STOP")
        XCTAssertEqual(AppProcessState.procStateName(2, apiLevel: 37), "top")
    }

    /// `am kill` of Drive ended two processes: the newest record is the
    /// `:primes_lifeboat` process, so a kill is confirmed by its own pid
    /// (502), not by the newest record.
    func testExitRecordsFindTheKilledPid() throws {
        XCTAssertEqual(
            try ConditionsAPI37Fixture.text("exit-records-docs.command.txt"),
            AppConditionsSnapshot.exitRecordsScript(package: "com.example.docs")
        )
        let records = ProcessExitRecord.parse(try ConditionsAPI37Fixture.text("exit-records-docs-after-kill.txt"))
        XCTAssertEqual(records.map(\.pid), [1462, 502, 29437, 3038, 21303, 9167])
        XCTAssertEqual(records.first?.processName, "com.example.docs:primes_lifeboat")
        let killed = try XCTUnwrap(records.first { $0.pid == 502 })
        XCTAssertEqual(killed.processName, "com.example.docs")
        XCTAssertEqual(killed.reason, ProcessExitRecord.userRequestedReason)
        XCTAssertEqual(killed.subreason, 24)
        XCTAssertEqual(records.first { $0.pid == 29437 }?.reason, ProcessExitRecord.crashReason)
        XCTAssertNil(records.last?.description, "description=null")
        XCTAssertEqual(records.last?.reasonName, "SIGNALED")
    }

    func testTheNoTargetProbeReadsOnlyTheDevice() throws {
        let snapshot = AppConditionsSnapshot.parse(try ConditionsAPI37Fixture.text("app-probe-no-target.txt"), package: nil)
        XCTAssertEqual(snapshot, AppConditionsSnapshot(apiLevel: 37, memoryFactor: .normal))
        // After `am memory-factor set LOW` (then reset at capture time).
        let low = AppConditionsSnapshot.parse(try ConditionsAPI37Fixture.text("app-probe-no-target-memory-low.txt"), package: nil)
        XCTAssertEqual(low.memoryFactor, .low)
    }

    func testTheForegroundPackage() throws {
        XCTAssertEqual(
            AppConditionsSnapshot.foregroundPackage(fromActivities: try ConditionsAPI37Fixture.text("foreground-settings.txt")),
            "com.android.settings"
        )
    }

    /// `am memory-factor show` after `set MODERATE`.
    func testMemoryFactorShow() throws {
        XCTAssertEqual(MemoryFactor.parse(try ConditionsAPI37Fixture.text("am-memory-factor-show-moderate.txt")), .moderate)
    }

    // MARK: - Refusals

    /// The activity manager's refusals, from each capture's stderr (exit 255).
    func testRefusalReasonsComeFromTheActivityManager() throws {
        XCTAssertEqual(
            AppConditionsError.reason(fromOutput: try ConditionsAPI37Fixture.text("am-send-trim-memory-not-higher.stderr.txt")),
            "Unable to set a higher trim level than current level"
        )
        XCTAssertEqual(
            AppConditionsError.reason(fromOutput: try ConditionsAPI37Fixture.text("am-send-trim-memory-foreground.stderr.txt")),
            "Unable to set a background trim level on a foreground process"
        )
        XCTAssertEqual(
            AppConditionsError.reason(fromOutput: try ConditionsAPI37Fixture.text("am-send-trim-memory-ui-hidden.stderr.txt")),
            "Unknown level option: UI_HIDDEN"
        )
        XCTAssertEqual(
            AppConditionsError.reason(fromOutput: try ConditionsAPI37Fixture.text("am-memory-factor-set-bogus.stderr.txt")),
            "Unknown level option: BOGUS"
        )
    }

    /// A refused trim reaches the caller as `AppConditionsError` with the
    /// manager's reason, not the whole stack trace.
    func testARefusedTrimThrowsTheReason() async throws {
        let adb = try ConditionsStubAdb(arms: [
            .init(
                match: "shell am send-trim-memory",
                stderrFixture: "am-send-trim-memory-not-higher.stderr.txt",
                exitCode: 255
            ),
        ])
        do {
            try await adb.client.sendTrimMemory(serial: "emulator-5554", package: "com.example", level: .runningLow)
            XCTFail("a refusal must throw")
        } catch let error as AppConditionsError {
            XCTAssertEqual(error, .refused(command: "Trim memory", reason: "Unable to set a higher trim level than current level"))
        }
    }

    /// `grep -E pattern` over `input` (empty when nothing matches).
    private func grepE(_ pattern: String, _ input: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = ["-E", pattern]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// A fake adb whose arms answer with a fixture on stdout and/or stderr and
/// an exit code (FakeAdb has stdout only). Unmatched calls exit 0 silently.
struct ConditionsStubAdb {
    struct Arm {
        let match: String
        var stdoutFixture: String?
        var stderrFixture: String?
        var exitCode: Int32 = 0
    }

    let client: AdbClient
    let directory: URL
    private let callsURL: URL

    init(arms: [Arm]) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConditionsStubAdb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        callsURL = directory.appendingPathComponent("calls.log")
        let branches = arms.map { arm -> String in
            var body = ""
            if let stdout = arm.stdoutFixture {
                body += "cat \(AdbClient.shellQuoted(ConditionsAPI37Fixture.url(stdout).path)); "
            }
            if let stderr = arm.stderrFixture {
                body += "cat \(AdbClient.shellQuoted(ConditionsAPI37Fixture.url(stderr).path)) >&2; "
            }
            return "  *\"\(arm.match)\"*) \(body)exit \(arm.exitCode) ;;"
        }
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(callsURL.path)"
        case "$*" in
        \(branches.joined(separator: "\n"))
          *) exit 0 ;;
        esac
        """
        let adbURL = directory.appendingPathComponent("adb")
        try Data(script.utf8).write(to: adbURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adbURL.path)
        client = AdbClient(adbURL: adbURL)
    }

    var calls: [String] {
        ((try? String(contentsOf: callsURL, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .map(String.init)
    }
}
