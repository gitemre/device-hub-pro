import XCTest
@testable import DeviceHubProKit

/// Live checks against a real simulator, behind `DHP_IOS_LIVE=1` (they
/// skip otherwise). Run them alone, never beside the Android live suite:
///
///     DHP_IOS_LIVE=1 swift test --filter AppleLive
///
/// `testCreateBootReadAndDeleteLeavesNothingBehind` creates an iPhone in a
/// private device set (`LiveTestSimulators`), boots it (a first boot takes
/// 25–45 s), reads it through every client, and deletes it: no
/// device, no set folder and no `~/Library/Logs/CoreSimulator` folder for
/// its UDID may remain. It also checks, as a canary, that CoreDevice still
/// does not see private-set simulators. It runs only the real binaries: the
/// wrapper timings in the plan were a one-off measurement, since a
/// wrapper can start `xcodebuild -runFirstLaunch`.
final class AppleLiveTests: XCTestCase {
    func testCreateBootReadAndDeleteLeavesNothingBehind() async throws {
        let toolchain = try await LiveTestSimulators.toolchain()
        let logsBefore = Set(Self.logFolders())
        let session = try LiveTestSimulators.Session(toolchain: toolchain)
        var udid: String?
        do {
            let device = try await session.createDevice(name: "DeviceHubPro-Live-\(UUID().uuidString.prefix(8))")
            udid = device.udid
            // Printed so a run's cleanup can be audited by UDID afterwards.
            print("AppleLive: created \(device.udid) in \(session.setDirectory.path)")
            XCTAssertEqual(device.state, .shutdown)
            try await exercise(session: session, device: device)
        } catch {
            let leftovers = await session.tearDown()
            XCTAssertEqual(leftovers, [])
            throw error
        }
        let leftovers = await session.tearDown()
        XCTAssertEqual(leftovers, [])

        // Nothing may come back once CoreSimulatorService settles.
        try await Task.sleep(for: .seconds(2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.setDirectory.path))
        let udids = Set([udid].compactMap { $0 })
        for udid in udids {
            let logs = LiveTestSimulators.logsDirectory.appendingPathComponent(udid).path
            XCTAssertFalse(FileManager.default.fileExists(atPath: logs), "log folder left behind: \(logs)")
        }
        // Only this run's folders count: other tools (Xcode, Device Hub,
        // another session's simulators) may add their own meanwhile.
        let added = Set(Self.logFolders()).subtracting(logsBefore)
        XCTAssertEqual(added.intersection(udids), [], "new log folders of this run")
        if !added.subtracting(udids).isEmpty {
            print("AppleLive: log folders added by other tools meanwhile (not this run's): \(added.subtracting(udids).sorted())")
        }
    }

    private func exercise(session: LiveTestSimulators.Session, device: SimulatorDevice) async throws {
        let simctl = session.simctl
        let udid = device.udid

        // The watcher sees the set, then the boot.
        let watcher = SimulatorWatcher(simctl: simctl, pollInterval: .seconds(5))
        let states = StateLog()
        let stream = watcher.events()
        let watching = Task {
            for await event in stream {
                if case .snapshot(let devices, _) = event, let state = devices.first(where: { $0.udid == udid })?.state {
                    states.append(state)
                }
            }
        }
        watcher.start()
        defer {
            watcher.stop()
            watching.cancel()
        }

        try await waitUntil(timeout: .seconds(15)) { !states.values.isEmpty }

        // Boot and follow the boot status to Finished.
        let bootStarted = ContinuousClock.now
        try await simctl.boot(udid: udid)
        let finished = try await simctl.bootStatus(udid: udid)
        XCTAssertEqual(finished?.isFinished, true)
        print("AppleLive: boot → Finished in \(ContinuousClock.now - bootStarted)")

        // The rest of the ready signal: SpringBoard runs once the boot
        // finished, a second bootstatus reports nothing left to wait for, and
        // the screen comes to show the home screen.
        let jobs = try await simctl.launchdJobs(udid: udid)
        let springBoard = SimulatorReadiness.homeScreenPID(in: jobs)
        XCTAssertNotNil(springBoard, "SpringBoard runs after Finished")
        let again = try await simctl.bootStatus(udid: udid, timeout: .seconds(30))
        XCTAssertTrue(SimulatorReadiness.bootFinished(lastUpdate: again), "\(String(describing: again))")
        let screen = session.setDirectory.appendingPathComponent("screen.png")
        var shown = false
        let homeDeadline = ContinuousClock.now + .seconds(60)
        while !shown, ContinuousClock.now < homeDeadline {
            try await simctl.screenshot(udid: udid, to: screen, timeout: .seconds(20))
            shown = SimulatorReadiness.showsHomeScreen(imageAt: screen) == true
        }
        XCTAssertTrue(SimulatorReadiness.isReady(bootFinished: true, homeScreenPID: springBoard, showsHomeScreen: shown))
        print("AppleLive: boot → home screen in \(ContinuousClock.now - bootStarted)")

        try await waitUntil(timeout: .seconds(15)) { states.values.contains(.booted) }
        XCTAssertEqual(states.values.first, .shutdown)

        // Reads through the clients.
        let appearance = try await simctl.appearance(udid: udid)
        XCTAssertTrue([.light, .dark].contains(appearance), "\(appearance)")
        let contrast = try await simctl.increaseContrast(udid: udid)
        XCTAssertTrue([.enabled, .disabled].contains(contrast), "\(contrast)")
        let size = try await simctl.contentSize(udid: udid)
        XCTAssertTrue(SimulatorContentSize.settable.contains(size), "\(size)")
        let overrides = try await simctl.statusBarOverrides(udid: udid)
        XCTAssertTrue(overrides.isEmpty)
        let scenarios = try await simctl.locationScenarios(udid: udid)
        XCTAssertTrue(scenarios.map(\.name).contains("City Run"), "\(scenarios)")
        let apps = try await simctl.listApps(udid: udid)
        XCTAssertTrue(apps.contains { $0.bundleIdentifier == "com.apple.mobilesafari" })
        let listed = try await simctl.listDevices()
        XCTAssertEqual(listed.map(\.udid), [udid], "the private set holds only this device")

        // The unified log streams.
        let log = SimulatorLogStream(simctl: simctl, udid: udid, level: .info)
        log.start()
        try await waitUntil(timeout: .seconds(20)) { !log.snapshot().isEmpty }
        log.stop()
        XCTAssertFalse(log.logcatSnapshot().isEmpty)

        // Canary: CoreDevice does not see private-set simulators (error 1000).
        if let devicectl = try session.toolchain.makeDevicectlClient(for: device) {
            do {
                _ = try await devicectl.details()
                XCTFail("CoreDevice now sees private-set simulators: devicectl live tests could use the private set")
            } catch let error as DevicectlError {
                XCTAssertEqual(error.code, DevicectlError.Code.deviceNotFound)
            }
        }
    }

    /// devicectl against a default-set simulator named in `DHP_SIM_UDID`
    /// (read-only: details, appearance and orientation).
    func testDevicectlReadsAPinnedDefaultSetSimulator() async throws {
        let toolchain = try await LiveTestSimulators.toolchain()
        let device = try await LiveTestSimulators.pinnedDefaultSetSimulator(toolchain: toolchain)
        guard device.isBooted else { throw XCTSkip("DHP_SIM_UDID \(device.udid) is not booted") }
        let devicectl = try XCTUnwrap(try toolchain.makeDevicectlClient(for: device))

        let details = try await devicectl.details()
        XCTAssertEqual(details.value.identifier, device.udid)
        XCTAssertTrue(details.value.isSimulator)
        XCTAssertGreaterThanOrEqual(details.info.jsonVersion, AppleToolchain.minimumDevicectlJSONVersion)
        XCTAssertEqual(toolchain.tier(devicectlProbe: details.info), .t2)
        let appearance = try await devicectl.appearance()
        XCTAssertNotNil(appearance.value.userInterfaceStyle)
        let orientation = try await devicectl.orientation()
        XCTAssertNotNil(orientation.value.deviceOrientationNonFlat)
    }

    // MARK: Helpers

    private static func logFolders() -> [String] {
        // Best effort: no folder yet means no log folders.
        (try? FileManager.default.contentsOfDirectory(atPath: LiveTestSimulators.logsDirectory.path)) ?? []
    }

    private func waitUntil(timeout: Duration, _ condition: @escaping () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { return XCTFail("condition not met within \(timeout)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private final class StateLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [SimulatorState] = []

        func append(_ state: SimulatorState) {
            lock.lock()
            stored.append(state)
            lock.unlock()
        }

        var values: [SimulatorState] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}
