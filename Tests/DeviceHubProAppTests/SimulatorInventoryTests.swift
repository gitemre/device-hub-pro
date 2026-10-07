import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The simulator provider on a stub simctl that replays real captures: what
/// it lists and hides (Device Hub hides the never-used devices CoreSimulator
/// created by itself), the names it adds from the catalogs, the tier it
/// reports, and that without Apple tooling it runs nothing.
@MainActor
final class SimulatorInventoryTests: XCTestCase {
    /// A stub simctl answering the three listings with the default
    /// set (`simctl-list-j-devices.default-set.json`) and Xcode 27.0's
    /// runtime and device-type catalogs.
    private func defaultSetSimctl(listFile: String? = nil) throws -> StubTool {
        let list = listFile.map { "cat " + SimulatorFixtures.quoted($0) }
            ?? SimulatorFixtures.cat("simctl-list-j-devices.default-set.json")
        return try makeStubTool("simctl", arms: """
          *"list -j devices")
            \(list) ;;
          *"list -j runtimes")
            \(SimulatorFixtures.cat("simctl-list-j-runtimes.json")) ;;
          *"list -j devicetypes")
            \(SimulatorFixtures.cat("simctl-list-j-devicetypes.json")) ;;
        """)
    }

    /// A device-set folder holding the default set's real `device_set.plist`.
    private func defaultSetFolder() throws -> URL {
        let folder = try makeTemporaryFolder("set")
        try FileManager.default.copyItem(
            at: SimulatorFixtures.url("device_set.plist.default-set"),
            to: folder.appendingPathComponent("device_set.plist")
        )
        return folder
    }

    private func inventory(
        simctl: StubTool?,
        devicectl: StubTool? = nil,
        devicesDirectory: URL,
        privateSet: Bool = true,
        preferences: AppPreferences = AppPreferences(defaults: .scratch())
    ) throws -> SimulatorInventory {
        let inventory = SimulatorInventory(
            apple: .stubbed(
                simctl: simctl,
                devicectl: devicectl,
                devicesDirectory: devicesDirectory,
                logsDirectory: try makeTemporaryFolder("logs"),
                privateSet: privateSet
            ),
            preferences: preferences
        )
        addTeardownBlock { @MainActor in inventory.stop() }
        return inventory
    }

    // MARK: - No tooling

    /// Without Apple tooling (the testing environment's default) the
    /// provider is T0 with the setup card's text, and a refresh runs
    /// nothing and lists nothing.
    func testWithoutAppleToolingNothingRuns() async {
        let inventory = SimulatorInventory(apple: nil, preferences: AppPreferences(defaults: .scratch()))

        await inventory.refresh()

        XCTAssertEqual(inventory.tooling, .unavailable)
        XCTAssertEqual(inventory.tooling.tier, .t0)
        XCTAssertEqual(inventory.tooling.setupAdvice, "iOS simulators and iPhones need Xcode.")
        XCTAssertNil(inventory.simctl)
        XCTAssertNil(inventory.toolchain)
        XCTAssertFalse(inventory.hasListed)
        XCTAssertEqual(inventory.simulators, [])
    }

    /// A physical iPhone is drawn in the chrome of the device type that has
    /// its model identifier (`iPhone13,2` is Xcode's iPhone 12); an unknown
    /// or missing identifier finds none, and nothing is read for it.
    func testADeviceTypeIsFoundByAPhysicalDevicesModelIdentifier() async throws {
        let inventory = try inventory(simctl: try defaultSetSimctl(), devicesDirectory: try defaultSetFolder())
        XCTAssertNil(inventory.deviceType(forModelIdentifier: "iPhone13,2"), "no device types before the catalog is read")

        await inventory.refresh()

        let type = try XCTUnwrap(inventory.deviceType(forModelIdentifier: "iPhone13,2"))
        XCTAssertEqual(type.identifier, "com.apple.CoreSimulator.SimDeviceType.iPhone-12")
        XCTAssertNil(inventory.deviceType(forModelIdentifier: "iPhone0,0"))
        XCTAssertNil(inventory.deviceType(forModelIdentifier: nil))
        XCTAssertNil(inventory.deviceType(forModelIdentifier: ""))
        XCTAssertNil(inventory.chromeFrame(forModelIdentifier: "iPhone13,2"), "the chrome is read when the stage asks")
        XCTAssertNil(inventory.displayShape(forModelIdentifier: "iPhone13,2"))
    }

    /// A Mac whose Xcode has no simctl: the probe answers T0 with its
    /// advice, and nothing is listed.
    func testAToolchainWithoutSimctlIsT0() async throws {
        let inventory = try inventory(simctl: nil, devicesDirectory: try makeTemporaryFolder("set"))
        XCTAssertEqual(inventory.tooling, .probing)

        await inventory.refresh()

        XCTAssertTrue(inventory.tooling.isProbed)
        XCTAssertEqual(inventory.tooling.tier, .t0)
        XCTAssertEqual(inventory.tooling.setupAdvice, "iOS simulators and iPhones need Xcode.")
        XCTAssertNil(inventory.simctl)
        XCTAssertFalse(inventory.hasListed)
    }

    // MARK: - Listing

    /// The the default set: 28 simulators, 16 of them defaults nobody
    /// booted, which are hidden; the 12 listed include the iPhone 11 the
    /// owner added. Each gets its runtime's and device type's names.
    func testTheDefaultSetListsWhatDeviceHubShows() async throws {
        let simctl = try defaultSetSimctl()
        let inventory = try inventory(simctl: simctl, devicesDirectory: try defaultSetFolder())
        var changes = 0
        inventory.listChanged = { changes += 1 }

        await inventory.refresh()

        XCTAssertEqual(inventory.tooling.tier, .t1)
        XCTAssertNil(inventory.tooling.setupAdvice)
        XCTAssertEqual(inventory.tooling.xcodeBuild, "27A266a")
        XCTAssertTrue(inventory.hasListed)
        XCTAssertGreaterThanOrEqual(changes, 1)
        XCTAssertEqual(inventory.simulators.count, 28)
        XCTAssertEqual(inventory.simulators.filter(\.isDefaultCreated).count, 27)
        XCTAssertEqual(inventory.simulators.filter(\.isUnusedDefault).count, 16)
        XCTAssertEqual(inventory.visibleSimulators.count, 12)
        XCTAssertFalse(inventory.visibleSimulators.contains(where: \.isUnusedDefault))

        let added = try XCTUnwrap(inventory.entry(udid: "472F358C-177D-4C25-82CC-5982BC4D3729"))
        XCTAssertEqual(added.name, "iPhone 11")
        XCTAssertFalse(added.isDefaultCreated)
        XCTAssertEqual(added.platform, "iOS")
        XCTAssertEqual(added.osVersion, "26.5")
        XCTAssertEqual(added.osBuild, "23F77")
        XCTAssertEqual(added.osLabel, "iOS 26.5")
        XCTAssertEqual(added.modelName, "iPhone 11")
        XCTAssertEqual(added.productFamily, "iPhone")
        XCTAssertEqual(added.modelIdentifier, "iPhone12,1")
        XCTAssertTrue(inventory.visibleSimulators.contains(added))

        // A default that was used stays listed; one nobody used is hidden.
        let used = try XCTUnwrap(inventory.entry(udid: "3B3FA51B-8FD0-4B8D-A28A-4F43A9A5A57A"))
        XCTAssertTrue(used.isDefaultCreated)
        XCTAssertFalse(used.isUnusedDefault)
        XCTAssertEqual(used.modelName, "iPhone 17 Pro")
        let unused = try XCTUnwrap(inventory.entry(udid: "C3BDDECE-CD59-4D1C-8123-A1DC8E3898AB"))
        XCTAssertTrue(unused.isUnusedDefault)
        XCTAssertEqual(unused.osLabel, "iOS 27.0")
        XCTAssertFalse(inventory.visibleSimulators.contains(unused))
        let tv = try XCTUnwrap(inventory.entry(udid: "68B047F5-1119-4A8F-8FBB-B9D0F9C9E7BE"))
        XCTAssertEqual(tv.osLabel, "tvOS 26.5")
        XCTAssertEqual(tv.productFamily, "Apple TV")

        // Only reads: the refresh's and the watcher's listings and the catalogs.
        XCTAssertEqual(Set(simctl.calls), ["list -j devices", "list -j runtimes", "list -j devicetypes"])
    }

    /// A private set has no `device_set.plist`: a never-booted device there
    /// is one somebody created, so it is listed.
    func testASetWithoutDefaultsHidesNothing() async throws {
        let list = SimulatorFixtures.url("simctl-list-j-devices.cloned.json").path
        let inventory = try inventory(
            simctl: try defaultSetSimctl(listFile: list),
            devicesDirectory: try makeTemporaryFolder("set")
        )

        await inventory.refresh()

        XCTAssertEqual(inventory.simulators.map(\.udid), [SimulatorFixtures.udid, SimulatorFixtures.cloneUDID])
        XCTAssertEqual(inventory.visibleSimulators.count, 2)
        XCTAssertTrue(inventory.simulators.allSatisfy { !$0.isDefaultCreated && $0.lastUsedAt == nil })
        XCTAssertEqual(inventory.simulators.first?.dataPath?.hasSuffix("/simtier/set/\(SimulatorFixtures.udid)/data"), true)
        XCTAssertEqual(
            inventory.simulators.first?.logPath,
            "/Users/aqauser001/Library/Logs/CoreSimulator/\(SimulatorFixtures.udid)"
        )
    }

    /// A list read that fails keeps the last list: an empty one would read
    /// as "every simulator deleted".
    func testAFailedListKeepsTheLastOne() async throws {
        let folder = try makeTemporaryFolder("answers")
        let answer = folder.appendingPathComponent("list.json")
        try FileManager.default.copyItem(at: SimulatorFixtures.url("simctl-list-j-devices.cloned.json"), to: answer)
        let inventory = try inventory(
            simctl: try defaultSetSimctl(listFile: answer.path),
            devicesDirectory: try makeTemporaryFolder("set")
        )
        await inventory.refresh()
        XCTAssertEqual(inventory.simulators.count, 2)

        try FileManager.default.removeItem(at: answer)
        await inventory.reloadList()

        XCTAssertEqual(inventory.simulators.count, 2)
    }

    /// The watcher publishes a change on its own: a device folder appearing
    /// in the set wakes it (FSEvents, else the 5 s poll), and its listing
    /// replaces the last one.
    func testTheWatcherPublishesAChangeWithoutARefresh() async throws {
        let folder = try makeTemporaryFolder("answers")
        let answer = folder.appendingPathComponent("list.json")
        try FileManager.default.copyItem(at: SimulatorFixtures.url("simctl-list-j-devices.shutdown.json"), to: answer)
        let set = try makeTemporaryFolder("set")
        let inventory = try inventory(simctl: try defaultSetSimctl(listFile: answer.path), devicesDirectory: set)
        await inventory.refresh()
        XCTAssertEqual(inventory.simulators.map(\.state), [.shutdown])

        try FileManager.default.removeItem(at: answer)
        try FileManager.default.copyItem(at: SimulatorFixtures.url("simctl-list-j-devices.booted.json"), to: answer)
        let device = set.appendingPathComponent("95D9676B-3317-4BA5-8CF6-3CDD0488CACA", isDirectory: true)
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: SimulatorFixtures.url("device.plist.booted"),
            to: device.appendingPathComponent("device.plist")
        )

        await waitUntil(timeout: 12, "the watcher's listing") { inventory.simulators.map(\.state) == [.booted] }
    }

    // MARK: - Refresh cost and quit

    /// The Android flows that end in a refresh (an AVD's create, delete or
    /// rename, a pairing, a Stop) re-read Android alone: none waits
    /// for the simulator provider, whose first refresh waits on the Xcode
    /// probe (`xcodebuild`, up to 15 s) and later ones on simctl (up to
    /// 30 s a call). The launch refresh still reads both.
    func testAndroidFlowsDoNotWaitForTheSimulatorProvider() async throws {
        let simctl = try defaultSetSimctl()
        let gate = ProbeGate()
        var apple = AppleTooling.stubbed(
            simctl: simctl,
            devicesDirectory: try defaultSetFolder(),
            logsDirectory: try makeTemporaryFolder("logs")
        )
        let probe = apple.probe
        apple.probe = {
            await gate.wait()
            return await probe()
        }
        let model = AppModel.testing(apple: apple)
        addTeardownBlock { @MainActor in
            gate.open()
            model.stopSimulatorProvider()
        }

        let launch = Task { await model.refresh() }
        await waitUntil("the launch refresh waits on the probe") { gate.isEntered }

        await assertFinishes("an AVD change's refresh") { await model.catalog.refresh() }
        await assertFinishes("a pairing's refresh") { await model.pairing.refresh() }
        await assertFinishes("an emulator's Stop") { await model.stopEmulator(avd: "Pixel_9") }
        XCTAssertFalse(model.simulators.tooling.isProbed)
        XCTAssertEqual(simctl.calls, [])

        gate.open()
        await launch.value
        XCTAssertTrue(model.simulators.hasListed)
    }

    /// A Mac with Xcode but no simulator runtime downloaded lists no
    /// runtimes: the catalogs are still read once per provider start, not
    /// on every refresh. (The runtime listing is the real capture trimmed to
    /// its first two and last two lines: its envelope, no runtime.)
    func testACatalogWithoutRuntimesIsReadOnce() async throws {
        let runtimes = SimulatorFixtures.quoted(SimulatorFixtures.url("simctl-list-j-runtimes.json").path)
        let simctl = try makeStubTool("simctl", arms: """
          *"list -j devices")
            \(SimulatorFixtures.cat("simctl-list-j-devices.empty-set.json")) ;;
          *"list -j runtimes")
            head -n 2 \(runtimes); tail -n 2 \(runtimes) ;;
          *"list -j devicetypes")
            \(SimulatorFixtures.cat("simctl-list-j-devicetypes.json")) ;;
        """)
        let inventory = try inventory(simctl: simctl, devicesDirectory: try makeTemporaryFolder("set"))

        await inventory.refresh()
        await inventory.refresh()
        await inventory.refresh()

        XCTAssertTrue(inventory.hasListed)
        XCTAssertEqual(inventory.runtimes, [])
        XCTAssertFalse(inventory.deviceTypes.isEmpty)
        XCTAssertEqual(simctl.calls.filter { $0 == "list -j runtimes" }.count, 1)
        XCTAssertEqual(simctl.calls.filter { $0 == "list -j devicetypes" }.count, 1)
    }

    /// Quit stops the provider for good: a refresh that was waiting on the
    /// probe when it stopped (the launch refresh, or a ⌘R) starts no
    /// watcher, lists nothing and tells nobody when the probe answers, and a
    /// later refresh starts nothing either.
    func testARefreshResumingAfterStopStartsNothing() async throws {
        let simctl = try defaultSetSimctl()
        let gate = ProbeGate()
        var apple = AppleTooling.stubbed(
            simctl: simctl,
            devicesDirectory: try defaultSetFolder(),
            logsDirectory: try makeTemporaryFolder("logs")
        )
        let probe = apple.probe
        apple.probe = {
            await gate.wait()
            return await probe()
        }
        let inventory = SimulatorInventory(apple: apple, preferences: AppPreferences(defaults: .scratch()))
        addTeardownBlock { @MainActor in
            gate.open()
            inventory.stop()
        }
        var changes = 0
        inventory.listChanged = { changes += 1 }

        let refresh = Task { await inventory.refresh() }
        await waitUntil("the refresh waits on the probe") { gate.isEntered }
        inventory.stop()
        gate.open()
        await refresh.value
        await inventory.refresh()
        // The watcher would have listed at once, and polls every 5 s.
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(simctl.calls, [])
        XCTAssertFalse(inventory.hasListed)
        XCTAssertEqual(changes, 0)
    }

    /// Fails unless `work` finishes within `timeout` seconds; the work goes
    /// on (and is awaited by nobody) when it does not.
    private func assertFinishes(
        _ what: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ work: @escaping @MainActor () async -> Void
    ) async {
        let done = Flag()
        Task { @MainActor in
            await work()
            done.value = true
        }
        await waitUntil(timeout: timeout, "\(what) finishes", file: file, line: line) { done.value }
    }

    @MainActor
    private final class Flag {
        var value = false
    }

    // MARK: - Tiers

    /// devicectl answering `device info details` for a listed default-set
    /// simulator makes T2; it is asked with `--device <UDID>`, never to list
    /// devices.
    func testADevicectlAnswerMakesT2() async throws {
        let devicectl = try makeStubTool("devicectl", arms: """
          "device info details --device 472F358C-177D-4C25-82CC-5982BC4D3729 -j - -t 30")
            \(SimulatorFixtures.cat("devicectl-device-info-details.json", folder: "devicectl")) ;;
        """)
        let inventory = try inventory(
            simctl: try defaultSetSimctl(),
            devicectl: devicectl,
            devicesDirectory: try defaultSetFolder(),
            privateSet: false
        )
        await inventory.refresh()
        XCTAssertEqual(inventory.tooling.tier, .t1)

        let unknown = await inventory.probeDevicectl(udid: "00000000-0000-0000-0000-000000000000")
        XCTAssertFalse(unknown, "only a listed simulator is asked")
        let answered = await inventory.probeDevicectl(udid: "472F358C-177D-4C25-82CC-5982BC4D3729")

        XCTAssertTrue(answered)
        XCTAssertEqual(inventory.devicectlProbe?.jsonVersion, 5)
        XCTAssertEqual(inventory.tooling.tier, .t2)
        XCTAssertEqual(devicectl.calls, ["device info details --device 472F358C-177D-4C25-82CC-5982BC4D3729 -j - -t 30"])

        inventory.setCanvasReady(true, udid: "472F358C-177D-4C25-82CC-5982BC4D3729")
        XCTAssertEqual(inventory.tooling.tier, .t3)
        inventory.setCanvasReady(false, udid: "472F358C-177D-4C25-82CC-5982BC4D3729")
        XCTAssertEqual(inventory.tooling.tier, .t2)
    }

    /// The live canvas's readiness is tracked per simulator: one simulator's
    /// canvas failing does not turn off another's.
    func testCanvasReadinessIsPerSimulator() async throws {
        let inventory = try inventory(
            simctl: try defaultSetSimctl(),
            devicectl: nil,
            devicesDirectory: try defaultSetFolder(),
            privateSet: false
        )
        await inventory.refresh()
        inventory.setCanvasReady(true, udid: "A")
        inventory.setCanvasReady(true, udid: "B")
        inventory.setCanvasReady(false, udid: "A")
        XCTAssertTrue(inventory.canvasReady)
        inventory.setCanvasReady(false, udid: "B")
        XCTAssertFalse(inventory.canvasReady)
    }

    /// CoreDevice cannot see a private set, so devicectl is never asked there.
    func testAPrivateSetNeverAsksDevicectl() async throws {
        let devicectl = try makeStubTool("devicectl", arms: "")
        let list = SimulatorFixtures.url("simctl-list-j-devices.cloned.json").path
        let inventory = try inventory(
            simctl: try defaultSetSimctl(listFile: list),
            devicectl: devicectl,
            devicesDirectory: try makeTemporaryFolder("set")
        )
        await inventory.refresh()

        let answered = await inventory.probeDevicectl(udid: SimulatorFixtures.udid)

        XCTAssertFalse(answered)
        XCTAssertEqual(devicectl.calls, [])
        XCTAssertEqual(inventory.tooling.tier, .t1)
    }

    // MARK: - Entries

    /// An entry's platform-neutral summary.
    func testAnEntrySummarizesAsAnAppleSimulator() throws {
        let entry = try SimulatorFixtures.entry("simctl-list-j-devices.booted-after-rename.json", udid: SimulatorFixtures.udid)

        let summary = entry.summary(runState: .booting(.migratingData))

        XCTAssertEqual(summary.ref, .apple(SimulatorFixtures.udid))
        XCTAssertNil(summary.ref.adbSerial)
        XCTAssertEqual(summary.kind, .simulator)
        XCTAssertEqual(summary.name, "DeviceHubPro-UI-core-renamed")
        XCTAssertEqual(summary.osName, "iOS", "read from the runtime identifier without a catalog")
        XCTAssertEqual(summary.osVersion, "27.0")
        XCTAssertNil(summary.model)
        XCTAssertEqual(summary.runState, .booting(.migratingData))
        XCTAssertTrue(summary.isAvailable)
        XCTAssertEqual(entry.statusLine(runState: .booting(.migratingData), operation: nil), "Starting")
        XCTAssertEqual(entry.statusLine(runState: .ready, operation: nil), "iOS 27.0")
        // DH's stopped simulator reads just the OS label, no "· Stopped"
        // suffix.
        XCTAssertEqual(entry.statusLine(runState: .stopped, operation: nil), "iOS 27.0")
        XCTAssertEqual(entry.statusLine(runState: .ready, operation: .erasing), "Erasing")
    }
}

/// A probe that answers only once the test opens the gate; it records that
/// a probe is waiting.
final class ProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var entered = false

    var isEntered: Bool { lock.withLock { entered } }

    func open() { lock.withLock { opened = true } }

    func wait() async {
        lock.withLock { entered = true }
        while !lock.withLock({ opened }) {
            // Best effort: the sleep fails only on cancellation; the loop re-checks.
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Xcode's first launch not done: the inventory runs nothing from Xcode, shows
/// the hint, and takes the finished setup when the app becomes active again.
@MainActor
final class SimulatorInventorySetupRecheckTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        private var value: AppleToolchain
        private(set) var probes = 0
        init(_ value: AppleToolchain) { self.value = value }
        func get() -> AppleToolchain { lock.lock(); defer { lock.unlock() }; probes += 1; return value }
        func set(_ new: AppleToolchain) { lock.lock(); value = new; lock.unlock() }
    }

    private func toolchain(simctl: URL?) -> AppleToolchain {
        let app = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer", isDirectory: true)
        return AppleToolchain(
            developerDirectory: app,
            xcodeVersion: "27.0",
            xcodeBuild: "27A266a",
            firstLaunchComplete: simctl != nil,
            simctl: simctl.map {
                .init(binary: $0, installedVersion: "1", expectedVersion: "1", needsFirstLaunch: false)
            } ?? .init(binary: nil, installedVersion: nil, expectedVersion: "1", needsFirstLaunch: true),
            devicectl: .missing
        )
    }

    func testPendingFirstLaunchShowsTheHintAndRecheckPicksUpTheFinishedSetup() async throws {
        let stub = try makeStubTool("simctl", arms: "*) exit 0 ;;")
        let box = Box(toolchain(simctl: nil))
        let folder = try makeTemporaryFolder("set")
        let apple = AppleTooling(
            probe: { box.get() },
            deviceSet: folder,
            devicesDirectory: folder,
            logsDirectory: try makeTemporaryFolder("logs")
        )
        let inventory = SimulatorInventory(apple: apple, preferences: AppPreferences(defaults: .scratch()))
        addTeardownBlock { @MainActor in inventory.stop() }

        await inventory.refresh()
        XCTAssertNil(inventory.simctl, "no simctl client while first launch is pending")
        XCTAssertEqual(inventory.tooling.tier, .t0)
        XCTAssertEqual(
            inventory.tooling.setupAdvice,
            "Open Xcode, accept the license and let it install its components (a few minutes), then come back."
        )
        XCTAssertEqual(inventory.tooling.guidance?.actionTitle, "Open Xcode\u{2026}")

        var recheck = await inventory.recheckSetupIfPending()
        XCTAssertFalse(recheck, "still pending: nothing changed")

        box.set(toolchain(simctl: stub.url))
        recheck = await inventory.recheckSetupIfPending()
        XCTAssertTrue(recheck)
        XCTAssertNotNil(inventory.simctl)
        XCTAssertNil(inventory.tooling.guidance)

        let probes = box.probes
        let again = await inventory.recheckSetupIfPending()
        XCTAssertFalse(again)
        XCTAssertEqual(box.probes, probes, "a usable toolchain is not probed again")
    }
}
