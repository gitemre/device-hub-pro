import XCTest
@testable import DeviceHubProKit

/// The Network and App conditions mechanisms against a live emulator, each
/// write read back from where Android applies it (ConnectivityService,
/// telephony.registry, the activity manager), never from the command's
/// answer. Only an online emulator is used (`LiveTestDevices.allowed`, then
/// emulators only), never a phone, whatever `DHP_SCRCPY_SERIAL` names.
///
/// Every setting is recorded first and restored in a teardown block: the
/// latency, the Wi-Fi and mobile-data switches, the cell registration, the
/// meter and the memory factor. What cannot be restored, and why:
/// - the signal: the modem changes it on its own every 10 s, so the test
///   ends by setting profile 4 (full, the modem's start state);
/// - `am send-trim-memory` and `am kill` act on a cached background process
///   of an app that is already running (a trim level only climbs until the
///   process dies; a killed cached app restarts when next needed);
final class ConditionsIntegrationTests: XCTestCase {
    private func onlineEmulator() async throws -> (AdbClient, String) {
        guard let adb = AdbClient.locate() else { throw XCTSkip("adb not found") }
        let devices = try await adb.listDevices()
        guard let serial = LiveTestDevices.allowed(devices).first(where: \.isEmulator)?.serial else {
            throw XCTSkip("no online emulator")
        }
        return (adb, serial)
    }

    /// Polls `read` until `done` holds, up to `seconds`.
    private static func waitFor<Value>(
        _ seconds: Double,
        read: () async throws -> Value,
        until done: (Value) -> Bool
    ) async throws -> Value {
        let deadline = Date().addingTimeInterval(seconds)
        var value = try await read()
        while !done(value), Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
            value = try await read()
        }
        return value
    }

    // MARK: - Network conditions

    /// The console names the emulator the records are kept against: its
    /// AVD and its process's discovery file. Read-only.
    func testTheConsoleNamesTheEmulatorProcess() async throws {
        let (adb, serial) = try await onlineEmulator()
        let read = await adb.emulatorInstance(serial: serial)
        let instance = try XCTUnwrap(read)
        XCTAssertFalse(instance.avdName.isEmpty)
        XCTAssertTrue(instance.discoveryPath.hasSuffix(".ini"), instance.discoveryPath)
        XCTAssertTrue(
            URL(fileURLWithPath: instance.discoveryPath).lastPathComponent.hasPrefix("pid_"),
            instance.discoveryPath
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: instance.discoveryPath), "the emulator's own discovery file")
        let again = await adb.emulatorInstance(serial: serial)
        XCTAssertEqual(again, instance, "one emulator process answers the same")
    }

    /// Moves the traffic to mobile data (the only path the emulator
    /// shapes), then drives the meter, and
    /// puts everything back.
    func testMobileDataConditionsTakeEffect() async throws {
        let (adb, serial) = try await onlineEmulator()
        let before = try await adb.networkConditions(serial: serial)
        let wifiWasOn = before.wifiOn == "1" || before.wifiOn == "2"
        let dataWasOn = before.mobileData == "1"
        addTeardownBlock {
            try? await adb.setMobileData(serial: serial, enabled: dataWasOn)
            try? await adb.setWifi(serial: serial, enabled: wifiWasOn)
            if wifiWasOn {
                // Leave only once Wi-Fi carries the traffic again.
                _ = try? await Self.waitFor(40, read: { try await adb.networkConditions(serial: serial) }) {
                    $0.connectivity.dataPath == .wifi
                }
            }
        }

        // The data path: `svc wifi disable` + `svc data enable`.
        try await adb.setWifi(serial: serial, enabled: false)
        try await adb.setMobileData(serial: serial, enabled: true)
        let onMobile = try await Self.waitFor(30, read: { try await adb.networkConditions(serial: serial) }) {
            $0.connectivity.dataPath == .mobileData
        }
        XCTAssertEqual(onMobile.connectivity.dataPath, .mobileData, "mobile data must become the default network")
        XCTAssertEqual(onMobile.connectivity.defaultAgent?.interfaceName, "eth0")
        guard let meteredBefore = onMobile.connectivity.isMobileDataMetered else {
            return XCTFail("the mobile network's capabilities must be readable")
        }
        addTeardownBlock {
            try? await adb.setEmulatorMobileDataMetered(serial: serial, metered: meteredBefore)
        }

        // The meter: TEMPORARILY_NOT_METERED on the mobile agent.
        try await adb.setEmulatorMobileDataMetered(serial: serial, metered: !meteredBefore)
        let flipped = try await Self.waitFor(15, read: { try await adb.networkConditions(serial: serial) }) {
            $0.connectivity.isMobileDataMetered == !meteredBefore
        }
        XCTAssertEqual(flipped.connectivity.isMobileDataMetered, !meteredBefore)
        try await adb.setEmulatorMobileDataMetered(serial: serial, metered: meteredBefore)
        let restoredMeter = try await Self.waitFor(15, read: { try await adb.networkConditions(serial: serial) }) {
            $0.connectivity.isMobileDataMetered == meteredBefore
        }
        XCTAssertEqual(restoredMeter.connectivity.isMobileDataMetered, meteredBefore)
    }

    // MARK: - App conditions

    /// A running, cached (curProcState 16–19) process of a stock app whose
    /// trim level can still climb: Device Hub Pro's trim and kill act on such
    /// background processes without disturbing the app on screen.
    private func cachedTarget(_ adb: AdbClient, _ serial: String) async throws -> (String, AppConditionsSnapshot) {
        let candidates = [
            "com.example.musicplayer",
            "com.example.docs",
            "com.example.photos",
            "com.google.android.calendar",
            "com.google.android.deskclock",
            "com.google.android.contacts",
            "com.devicehubpro.verifier",
        ]
        for package in candidates {
            let snapshot = try await adb.appConditions(serial: serial, package: package)
            if let process = snapshot.runningProcess, let state = process.procState, (16...19).contains(state),
               (process.trimMemoryLevel ?? 0) < TrimMemoryLevel.moderate.rawValue {
                return (package, snapshot)
            }
        }
        throw XCTSkip("no cached background app to act on")
    }

    func testTrimMemoryIsRecordedOnTheProcess() async throws {
        let (adb, serial) = try await onlineEmulator()
        let (package, snapshot) = try await cachedTarget(adb, serial)
        if (snapshot.apiLevel ?? 0) >= 31 {
            // The freezer line (`isFrozen=`) is dumped from API 31, each
            // release with its own line start: the probe must keep it.
            XCTAssertNotNil(snapshot.runningProcess?.isFrozen, "\(package)")
        }
        let current = snapshot.runningProcess?.trimMemoryLevel ?? 0
        let level = try XCTUnwrap(TrimMemoryLevel.allCases.first { $0.rawValue > current })
        XCTAssertEqual(TrimMemoryGate.evaluate(level, process: snapshot.runningProcess, apiLevel: snapshot.apiLevel), .allowed)

        try await adb.sendTrimMemory(serial: serial, package: package, level: level)
        let after = try await adb.appConditions(serial: serial, package: package)
        XCTAssertEqual(after.runningProcess?.trimMemoryLevel, level.rawValue, "\(package)")

        // The same level again is refused by the activity manager.
        do {
            try await adb.sendTrimMemory(serial: serial, package: package, level: level)
            XCTFail("a level not above the current one must be refused")
        } catch let error as AppConditionsError {
            XCTAssertEqual(error, .refused(command: "Trim memory", reason: "Unable to set a higher trim level than current level"))
        }
    }

    func testKillEndsACachedProcessAsUserRequested() async throws {
        let (adb, serial) = try await onlineEmulator()
        let (package, snapshot) = try await cachedTarget(adb, serial)
        let pid = try XCTUnwrap(snapshot.mainPid)

        try await adb.killBackgroundProcesses(serial: serial, package: package)
        let after = try await Self.waitFor(5, read: { try await adb.appConditions(serial: serial, package: package) }) {
            !$0.pids.contains(pid)
        }
        XCTAssertFalse(after.pids.contains(pid), "\(package) pid \(pid) must be gone")
        if (after.apiLevel ?? 0) >= ProcessExitRecord.minimumAPI {
            // One kill can end several processes of the package: the
            // killed pid's own record is the proof.
            let record = try await adb.processExitRecords(serial: serial, package: package).first { $0.pid == pid }
            XCTAssertEqual(record?.reason, ProcessExitRecord.userRequestedReason)
            XCTAssertEqual(record?.description, "kill background")
        }
    }
}
