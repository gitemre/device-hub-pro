import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// A model built for tests has exactly the tools it is given: it never
/// locates adb or the SDK emulator, and the `DHP_*` dev hooks come
/// from its `LaunchOptions`, never from the test runner's environment.
@MainActor
final class HermeticConstructionTests: XCTestCase {
    func testTestingModelHasNoAdbAndAnInertEmulator() {
        let model = AppModel.testing()

        XCTAssertFalse(model.adbIsAvailable)
        XCTAssertEqual(model.emulatorManager?.emulatorURL.path, "/usr/bin/false")
        XCTAssertEqual(model.launchOptions, .none)
    }

    /// The convenience init takes nil at its word: no adb found on the Mac,
    /// no SDK emulator, no launch options from the runner, and settings
    /// from the defaults it is handed.
    /// Only `AppEnvironment.live()` names the user's defaults: every store
    /// takes the environment's, with no `.standard` default argument or
    /// fallback that a test forgetting to pass one would silently write
    /// through to the xctest runner's own preferences. A source scan, since
    /// a default argument cannot be observed from a call that passes one.
    func testOnlyTheLiveEnvironmentNamesTheStandardDefaults() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/DeviceHubProApp", isDirectory: true)
        let pattern = try NSRegularExpression(pattern: #"UserDefaults\.standard\b|UserDefaults\??\s*=\s*\.standard\b"#)
        var hits: [String] = []
        var scanned = 0
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
                let code = String(line)
                guard !code.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                let range = NSRange(code.startIndex..., in: code)
                if pattern.firstMatch(in: code, range: range) != nil {
                    hits.append("\(url.lastPathComponent):\(index + 1): \(code.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the scan sees the app's sources")
        XCTAssertEqual(hits.count, 1, "\(hits)")
        XCTAssertTrue(hits.first?.hasPrefix("AppEnvironment.swift:") == true, "\(hits)")
        XCTAssertTrue(hits.first?.hasSuffix("let defaults = UserDefaults.standard") == true, "\(hits)")
    }

    /// No Apple tooling unless a test hands some in: the testing
    /// environment has none, the model's simulator provider is T0, and a
    /// refresh builds no simctl client and lists nothing.
    func testTestingModelHasNoAppleTooling() async {
        XCTAssertNil(AppEnvironment.testing().apple)
        let model = AppModel.testing()
        XCTAssertEqual(model.simulators.tooling, .unavailable)

        await model.refresh()

        XCTAssertNil(model.simulators.simctl)
        XCTAssertNil(model.simulators.toolchain)
        XCTAssertFalse(model.simulators.hasListed)
        XCTAssertEqual(model.simulators.simulators, [])
        XCTAssertNil(model.simulators.logsDirectory)
        let booted = await model.simulatorLifecycle.boot("425BD068-3D87-4F27-BE58-EB56A58B2C3A")
        XCTAssertFalse(booted)
        XCTAssertNil(model.status.errorMessage)
    }

    /// Only `AppEnvironment.live()` probes Xcode and names the user's
    /// simulator set and CoreSimulator logs folder: a source scan, since
    /// the probe and the folders are defaults no test should reach by
    /// leaving a parameter out.
    func testOnlyTheLiveEnvironmentReachesTheUsersSimulators() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/DeviceHubProApp", isDirectory: true)
        let pattern = try NSRegularExpression(
            pattern: #"AppleToolchain\.probe\(|SimulatorWatcher\.defaultDevicesDirectory|AppleTooling\.userLogsDirectory"#
        )
        var hits: [String] = []
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
                let code = String(line)
                guard !code.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                let range = NSRange(code.startIndex..., in: code)
                if pattern.firstMatch(in: code, range: range) != nil {
                    hits.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(hits.count, 3, "\(hits)")
        XCTAssertTrue(hits.allSatisfy { $0.hasPrefix("AppEnvironment.swift:") }, "\(hits)")
    }

    func testConvenienceInitNeverLocatesTheTools() {
        let defaults = UserDefaults.scratch()
        defaults.set(false, forKey: "replayEnabled")

        let model = AppModel(adbClient: nil, defaults: defaults)

        XCTAssertFalse(model.adbIsAvailable)
        XCTAssertNil(model.emulatorManager)
        XCTAssertEqual(model.launchOptions, .none)
        XCTAssertFalse(model.preferences.replayEnabled)
    }

    /// Every environment but `live()` sees only its own process's VMs,
    /// whatever emulator it is handed — the one it starts with and every one
    /// Settings' binary path swaps in — so a test model cannot find, attach
    /// to or signal an emulator its test did not start. The scope `live()`
    /// passes keeps every VM in view.
    func testAnEnvironmentSeesOnlyItsOwnVMsUnlessItSaysOtherwise() throws {
        // The app's view of every VM, handed to an environment that does not
        // say it wants that view.
        let handed = EmulatorManager(emulatorURL: URL(fileURLWithPath: "/usr/bin/false"), processScope: .everyVM)
        let environment = AppEnvironment(
            adbClient: nil,
            emulatorManager: handed,
            defaults: .scratch(),
            launch: .none,
            pasteboard: TestPasteboard(),
            picker: TestPicker()
        )
        XCTAssertEqual(environment.emulatorProcesses, .ownProcesses)
        XCTAssertEqual(environment.emulatorManager?.processScope, .ownProcesses)
        XCTAssertEqual(environment.emulatorManagerForPath("")?.processScope, .ownProcesses)
        XCTAssertEqual(environment.emulatorManagerForPath("/bin/sh")?.emulatorURL.path, "/bin/sh")
        XCTAssertEqual(environment.emulatorManagerForPath("/bin/sh")?.processScope, .ownProcesses)

        let model = AppModel(environment: environment)
        model.setEmulatorBinaryPath("/bin/sh")
        XCTAssertEqual(model.emulatorManager?.emulatorURL.path, "/bin/sh")
        XCTAssertEqual(model.emulatorManager?.processScope, .ownProcesses, "the swapped-in binary sees only its own VMs too")
        XCTAssertEqual(AppModel.testing(emulator: handed).emulatorManager?.processScope, .ownProcesses)

        let app = AppEnvironment(
            adbClient: nil,
            emulatorManager: handed,
            emulatorProcesses: .everyVM,
            defaults: .scratch(),
            launch: .none,
            pasteboard: TestPasteboard(),
            picker: TestPicker()
        )
        XCTAssertTrue(app.emulatorManager === handed, "the app's emulator is used as located")
        XCTAssertEqual(app.emulatorManagerForPath("/bin/sh")?.processScope, .everyVM)
    }

    /// A hot-plugged device on a model without adb gets no Info: there is no
    /// adb for the snapshot's follow-up reads to run.
    func testWatcherSnapshotWithoutAdbReadsNothing() async {
        let model = AppModel.testing()
        let device = AndroidDevice.online("emulator-5554", transport: "1")

        model.inventory.applyWatcherSnapshot([device], degraded: false)
        await model.inventory.loadInfo(for: device)

        XCTAssertEqual(model.inventory.devices.map(\.serial), ["emulator-5554"])
        XCTAssertNil(model.inventory.deviceInfos["emulator-5554"])
    }

    func testLaunchOptionsParseEveryHook() {
        let options = LaunchOptions(environment: [
            "DHP_AUTOMIRROR": "1",
            "DHP_MIRROR_SERIAL": "emulator-5556",
            "DHP_FORCE_PHYSICAL": "emulator-5554",
            "DHP_LOG_SERIAL": "emulator-5558",
            "DHP_CONTROLS": "1",
            "DHP_AUTOPAIR": "1",
            "DHP_PIXEL_SKIN": "pixel_9",
            "DHP_CONTROLS_EXPAND_ALL": "1",
            "DHP_PERF_LOG": "/tmp/perf.jsonl",
            "DHP_APPEARANCE": "dark",
            "DHP_MULTIWINDOW": "0",
        ])

        XCTAssertEqual(options, LaunchOptions(
            autoMirror: true,
            mirrorSerial: "emulator-5556",
            forcePhysical: .serial("emulator-5554"),
            logSerial: "emulator-5558",
            showControls: true,
            autoPair: true,
            pixelSkin: "pixel_9",
            expandAllControlsGroups: true,
            perfLogURL: URL(fileURLWithPath: "/tmp/perf.jsonl"),
            forceDarkAppearance: true
        ))
    }

    /// `DHP_LAUNCH_INACTIVE=1` keeps the app in the background at launch;
    /// any other value does not.
    func testLaunchInactiveHook() {
        XCTAssertTrue(LaunchOptions(environment: ["DHP_LAUNCH_INACTIVE": "1"]).launchInactive)
        XCTAssertFalse(LaunchOptions(environment: ["DHP_LAUNCH_INACTIVE": "yes"]).launchInactive)
        XCTAssertFalse(LaunchOptions.none.launchInactive)
    }

    /// Every hook is off with no variables, except several windows, which
    /// are on by default.
    func testNoVariablesTurnEveryHookOff() {
        var expected = LaunchOptions.none
        expected.multiWindowEnabled = true
        XCTAssertEqual(LaunchOptions(environment: [:]), expected)
    }

    /// A flag is on only for its exact value, and an empty value (a blank
    /// `DHP_MIRROR_SERIAL` included) counts as unset.
    func testOtherValuesAndEmptyValuesLeaveTheHooksOff() {
        let options = LaunchOptions(environment: [
            "DHP_AUTOMIRROR": "true",
            "DHP_MIRROR_SERIAL": "",
            "DHP_FORCE_PHYSICAL": "",
            "DHP_LOG_SERIAL": "",
            "DHP_CONTROLS": "yes",
            "DHP_AUTOPAIR": "0",
            "DHP_PIXEL_SKIN": "",
            "DHP_CONTROLS_EXPAND_ALL": "2",
            "DHP_PERF_LOG": "",
            "DHP_APPEARANCE": "light",
            "DHP_MULTIWINDOW": "0",
        ])

        XCTAssertEqual(options, .none)
    }

    /// `1` forces every device, a serial forces that device, and a blank or
    /// whitespace-only value is off.
    func testForcePhysicalValues() {
        func parse(_ value: String) -> LaunchOptions.ForcedPhysical? {
            LaunchOptions(environment: ["DHP_FORCE_PHYSICAL": value]).forcePhysical
        }
        XCTAssertEqual(parse("1"), .everyDevice)
        XCTAssertEqual(parse("emulator-5554"), .serial("emulator-5554"))
        XCTAssertEqual(parse(" emulator-5554  "), .serial("emulator-5554"))
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("   "))

        let every = LaunchOptions(forcePhysical: .everyDevice)
        XCTAssertTrue(every.forcesPhysicalTransport(serial: "emulator-5554"))
        XCTAssertTrue(every.forcesPhysicalTransport(serial: "emulator-5556"))
        let one = LaunchOptions(forcePhysical: .serial("emulator-5554"))
        XCTAssertTrue(one.forcesPhysicalTransport(serial: "emulator-5554"))
        XCTAssertFalse(one.forcesPhysicalTransport(serial: "emulator-5556"))
        XCTAssertFalse(LaunchOptions.none.forcesPhysicalTransport(serial: "emulator-5554"))
    }

    /// The runner's environment does not reach a model built for tests: with
    /// `DHP_AUTOPAIR=1` set in the process, `refresh()` on `none` opens
    /// no Pair Device sheet.
    func testRefreshIgnoresTheProcessEnvironment() async {
        setenv("DHP_AUTOPAIR", "1", 1)
        defer { unsetenv("DHP_AUTOPAIR") }
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        defer { model.inventory.stopDeviceLifecycle() }

        await model.refresh()

        XCTAssertFalse(model.workspace.window.isPairSheetPresented)
    }

    /// The same hook, asked for through the model's own launch options.
    func testRefreshAppliesTheLaunchOptions() async {
        let model = AppModel.testing(
            adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")),
            launch: LaunchOptions(autoPair: true)
        )
        defer { model.inventory.stopDeviceLifecycle() }

        await model.refresh()

        XCTAssertTrue(model.workspace.window.isPairSheetPresented)
    }

    /// The smoke scripts' auto-mirror (`DHP_AUTOMIRROR=1` with
    /// `DHP_MIRROR_SERIAL`), asked for through the launch options:
    /// refresh() mirrors the preferred device, not the first online
    /// emulator. Forced through the physical transport so the test resolves
    /// no gRPC port.
    func testRefreshAutoMirrorsThePreferredSerial() async throws {
        let adb = try makeStubAdb(arms: """
          "devices -l")
            printf 'List of devices attached\\n'
            printf 'emulator-5554          device product:sdk model:First transport_id:3\\n'
            printf 'emulator-5556          device product:sdk model:Preferred transport_id:8\\n' ;;
          "track-devices"*)
            exec sleep 30 ;;
        """)
        let model = AppModel.testing(
            adb: adb.client,
            launch: LaunchOptions(autoMirror: true, mirrorSerial: "emulator-5556", forcePhysical: .everyDevice)
        )
        defer { model.inventory.stopDeviceLifecycle() }
        let session = FakeMirrorSession()
        var started: [String] = []
        model.workspace.mirror.sessionFactoryOverride = { serial, _ in
            started.append(serial)
            return session
        }

        await model.refresh()

        XCTAssertEqual(started, ["emulator-5556"])
        XCTAssertEqual(model.activeDeviceSerial, "emulator-5556")
        model.stopMirror()
    }

    /// The forced-physical hook sends that emulator through the scrcpy
    /// transport: its session is built without a gRPC port.
    func testForcedSerialMirrorsThroughThePhysicalTransport() async {
        let model = AppModel.testing(
            adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")),
            launch: LaunchOptions(forcePhysical: .serial("emulator-5554"))
        )
        let session = FakeMirrorSession()
        var requests: [(serial: String, port: Int?)] = []
        model.workspace.mirror.sessionFactoryOverride = { serial, port in
            requests.append((serial, port))
            return session
        }

        await model.mirror(device: .online("emulator-5554", transport: "1"))

        XCTAssertEqual(requests.map(\.serial), ["emulator-5554"])
        XCTAssertEqual(requests.map(\.port), [nil])
        XCTAssertTrue(model.workspace.mirror.session === session)
        XCTAssertNil(model.workspace.context.port)
        model.stopMirror()
    }

    // MARK: Workspace

    /// The model's per-device members are its one workspace's: the same
    /// instances, not copies, so nothing a view or a test reaches through
    /// the old names differs from what the workspace holds.
    func testPerDeviceMembersAreTheWorkspaces() {
        let model = AppModel.testing()
        let workspace = model.workspace

        XCTAssertTrue(model.context === workspace.context)
        XCTAssertTrue(model.mirror === workspace.mirror)
        XCTAssertTrue(model.window === workspace.window)
        XCTAssertTrue(model.controlsPanel === workspace.controlsPanel)
        XCTAssertTrue(model.hardware === workspace.hardware)
        XCTAssertTrue(model.extras === workspace.extras)
        XCTAssertTrue(model.conditions === workspace.conditions)
        XCTAssertTrue(model.links === workspace.links)
        XCTAssertTrue(model.location === workspace.location)
        XCTAssertTrue(model.capture === workspace.capture)
        XCTAssertTrue(model.media === workspace.media)
        XCTAssertTrue(model.clipboard === workspace.clipboard)
        XCTAssertTrue(model.logcat === workspace.logcat)
        XCTAssertTrue(model.apps === workspace.apps)
        XCTAssertTrue(model.simulatorApps === workspace.simulatorApps)
        XCTAssertTrue(model.simulatorCrashReports === workspace.simulatorCrashReports)
        XCTAssertTrue(model.appleControls === workspace.appleControls)
        XCTAssertTrue(model.simulatorCanvas === workspace.simulatorCanvas)
        XCTAssertTrue(model.workspace === workspace, "one workspace for the model's life")
    }

    /// The workspace's features act on its one context: a serial written
    /// through the model is the one the features' shared context holds.
    func testWorkspaceFeaturesShareOneContext() {
        let model = AppModel.testing()

        model.context.serial = "emulator-5554"

        XCTAssertEqual(model.workspace.context.serial, "emulator-5554")
        XCTAssertEqual(model.activeDeviceSerial, "emulator-5554")
    }

    /// The workspace reads the app's tools through `services`, the same
    /// instances the model holds, and never holds the model itself.
    func testWorkspaceServicesAreTheModelsAndItHoldsNoModel() {
        let model = AppModel.testing()
        let services = model.workspace.services

        XCTAssertTrue(services === model.services)
        XCTAssertTrue(services.inventory === model.inventory)
        XCTAssertTrue(services.catalog === model.catalog)
        XCTAssertTrue(services.grpcPorts === model.grpcPorts)
        XCTAssertTrue(services.simulators === model.simulators)
        XCTAssertTrue(services.preferences === model.preferences)
        XCTAssertTrue(services.status === model.status)
        XCTAssertEqual(services.launchOptions, model.launchOptions)
        let held = Mirror(reflecting: model.workspace).children.map { type(of: $0.value) }
        XCTAssertFalse(held.contains { $0 == AppModel.self }, "\(held)")
    }

    /// The one exception: `services.status` is the
    /// app-global center, but every per-device controller `workspace`
    /// builds is on the workspace's own — never `services.status` — so a
    /// mirror/attach, controls, capture/recording, apps, logs, clipboard or
    /// simulator canvas/apps/controls flow never lands on the app-global
    /// line other windows would also read.
    func testWorkspaceOwnsItsStatusCenterNotServices() {
        let model = AppModel.testing()

        XCTAssertFalse(model.workspace.status === model.services.status)
        XCTAssertTrue(model.workspace.mirror.session == nil, "sanity: no session to mask a shared center's writes")

        model.workspace.status.errorMessage = "a per-device failure"
        XCTAssertNil(model.services.status.errorMessage, "never reaches the app-global center")
        XCTAssertNil(model.status.errorMessage, "AppModel.errorMessage stays the app-global center's value")
    }

    /// The session hubs are the workspace's: a session begun through it is
    /// the model's session, and the model's teardown ends it.
    func testSessionHubsRunOnTheWorkspace() {
        let model = AppModel.testing()
        let session = FakeMirrorSession()

        model.workspace.beginMirrorSession(
            session,
            device: .android("emulator-5554"),
            port: 8554,
            avdName: "Pixel_9",
            capabilities: .android(emulatorGrpc: true)
        )
        XCTAssertTrue(model.workspace.mirror.session === session)
        XCTAssertEqual(model.workspace.context.port, 8554)
        XCTAssertEqual(model.activeAvdName, "Pixel_9")

        let generation = model.mirrorSessionGeneration
        model.tearDownMirror(cause: .replaced)
        XCTAssertNil(model.workspace.mirror.session)
        XCTAssertNil(model.workspace.context.device)
        XCTAssertEqual(model.mirrorSessionGeneration, generation + 1)
    }
}
