import Foundation
import Observation
import Synchronization
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// `EmulatorBootController` on its own: a boot reports through its hooks and
/// its caller's closures only (the selection and the sessions stay with
/// `AppModel`'s orchestrators), a start is claimed once, a stop before the
/// launch wins, only the booting panel is observed, and the next boot runs
/// on the emulator binary Settings picked last.
@MainActor
final class EmulatorBootControllerTests: XCTestCase {
    /// Set once by an observation's `onChange`, which may run anywhere.
    private final class ChangeFlag: Sendable {
        private let fired = Mutex(false)

        var isSet: Bool { fired.withLock { $0 } }

        func set() {
            fired.withLock { $0 = true }
        }
    }

    private static let fastBoots = EmulatorBootController.BootTiming(
        startupGrace: .milliseconds(100),
        poll: .milliseconds(100),
        onlineTimeout: .seconds(10),
        bootTimeout: .seconds(10)
    )

    private func makeController(adb: AdbClient? = nil, status: StatusCenter = StatusCenter()) -> EmulatorBootController {
        let boot = EmulatorBootController(
            adbClient: adb,
            status: status,
            preferences: AppPreferences(defaults: .scratch())
        )
        boot.bootTiming = Self.fastBoots
        return boot
    }

    /// An adb for one VM, `emulator-5556`, online at once and booted at
    /// once, whose discovery file names `port` (no token). Its console
    /// answers `avd` for a model's lookup; a controller on its own asks its
    /// `consoleAvdName` hook instead.
    private func bootingAdb(avd: String, port: Int, extraArms: String = "") throws -> StubAdb {
        let discovery = FileManager.default.temporaryDirectory
            .appendingPathComponent("discovery-\(UUID().uuidString).ini")
        try Data("grpc.port=\(port)\n".utf8).write(to: discovery)
        addTeardownBlock { try? FileManager.default.removeItem(at: discovery) }
        return try makeStubAdb(arms: """
          "devices -l")
            printf 'List of devices attached\\n'
            printf 'emulator-5556          device product:sdk model:Target transport_id:8\\n' ;;
          "-s emulator-5556 emu avd name")
            printf '%s\\r\\nOK\\r\\n' "\(avd)" ;;
          "-s emulator-5556 emu avd discoverypath")
            printf '%s\\r\\nOK\\r\\n' "\(discovery.path)" ;;
          "-s emulator-5556 shell getprop")
            printf '[sys.boot_completed]: [1]\\n' ;;
          "track-devices"*)
            exec sleep 30 ;;
        \(extraArms)
        """)
    }

    /// Whether `body` changed anything a view reading `startingAvdNames`
    /// tracks.
    private func notifiesBootingPanel(_ boot: EmulatorBootController, _ body: () -> Void) -> Bool {
        let changed = ChangeFlag()
        withObservationTracking {
            _ = boot.startingAvdNames
        } onChange: {
            changed.set()
        }
        body()
        return changed.isSet
    }

    // MARK: - Boot

    /// A boot's only outlets are its hooks (the console lookup, the gRPC
    /// port) and its caller's `launched`/`progress` closures: it finds the
    /// VM whose console names the AVD, records the discovery file's port
    /// under that serial, and leaves the booting panel to its caller.
    func testABootReportsThroughItsHooksAndTheCallersClosuresOnly() async throws {
        let target = "Hooked_\(UUID().uuidString.prefix(6))"
        let emulator = try makeStubEmulator(avds: [target])
        let discoveryPort = try makeOwnedGrpcPort()
        let adb = try bootingAdb(avd: target, port: discoveryPort)
        let status = StatusCenter()
        let boot = makeController(adb: adb.client, status: status)
        var asked: [String] = []
        boot.consoleAvdName = { device in
            asked.append(device.serial)
            return device.serial == "emulator-5556" ? target : nil
        }
        var stored: [String] = []
        boot.storeGrpcPort = { port, serial in stored.append("\(serial):\(port)") }
        XCTAssertTrue(boot.claim(target))
        boot.markBooting(target)
        var launched = 0
        var progress: [String] = []

        let outcome = await boot.bootEmulator(
            avd: target,
            coldBoot: false,
            manager: emulator.manager,
            adbClient: adb.client,
            launched: { launched += 1 },
            progress: { progress.append($0) }
        )

        guard case .booted(let serial, let port) = outcome else {
            return XCTFail("expected a booted VM, got \(outcome)")
        }
        XCTAssertEqual(serial, "emulator-5556")
        XCTAssertEqual(port, discoveryPort, "the port the VM's discovery file names")
        XCTAssertEqual(launched, 1)
        XCTAssertEqual(emulator.launches.count, 1)
        XCTAssertEqual(asked, ["emulator-5556"], "the VM is identified by its console")
        XCTAssertEqual(stored, ["emulator-5556:\(discoveryPort)"])
        XCTAssertEqual(progress, ["Waiting for the emulator to come online…", "Waiting for Android to finish booting…"])
        XCTAssertNil(status.errorMessage)
        XCTAssertEqual(boot.startingAvdNames, [target], "the caller ends the booting panel")
        boot.finish(target)
    }

    /// After Android has booted, a Pixel 10 Pro AVD (no overlay of its own on an
    /// API 35 image) gets the Pixel 9 Pro's emulation overlays, the framework
    /// one and the system UI one, from the real `cmd overlay list` capture;
    /// the AVD's name and LCD come from its `config.ini` values.
    func testABootEnablesTheEmulationOverlayOfTheDevice() async throws {
        let target = "Overlay_\(UUID().uuidString.prefix(6))"
        let emulator = try makeStubEmulator(avds: [target])
        let discoveryPort = try makeOwnedGrpcPort()
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DeviceHubProKitTests/Fixtures/api35-emulator/cmd-overlay-list.txt")
        let adb = try bootingAdb(avd: target, port: discoveryPort, extraArms: """
          "-s emulator-5556 shell cmd overlay list")
            cat '\(fixture.path)' ;;
          "-s emulator-5556 shell cmd overlay enable "*)
            printf 'Success\\n' ;;
        """)
        let boot = makeController(adb: adb.client)
        boot.consoleAvdName = { $0.serial == "emulator-5556" ? target : nil }
        boot.avdConfig = { _ in
            ["hw.device.name": "pixel_10_pro", "hw.lcd.width": "1280", "hw.lcd.height": "2856"]
        }
        XCTAssertTrue(boot.claim(target))

        let outcome = await boot.bootEmulator(
            avd: target,
            coldBoot: false,
            manager: emulator.manager,
            adbClient: adb.client,
            launched: {},
            progress: { _ in }
        )

        guard case .booted = outcome else { return XCTFail("expected a booted VM, got \(outcome)") }
        XCTAssertEqual(adb.calls(containing: "cmd overlay"), [
            "-s emulator-5556 shell cmd overlay list",
            "-s emulator-5556 shell cmd overlay enable com.android.internal.emulation.pixel_9_pro",
            "-s emulator-5556 shell cmd overlay enable com.android.systemui.emulation.pixel_9_pro",
        ])
        boot.finish(target)
    }

    /// Booted through a model's controller, the VM changes nothing on the
    /// stage: the selection is its caller's to write (Start's `launched`
    /// closure), and no session starts.
    func testABootLeavesTheSelectionAndTheSessionToItsCaller() async throws {
        let target = "Unselected_\(UUID().uuidString.prefix(6))"
        let emulator = try makeStubEmulator(avds: [target])
        let discoveryPort = try makeOwnedGrpcPort()
        let adb = try bootingAdb(avd: target, port: discoveryPort)
        let model = AppModel.testing(adb: adb.client, emulator: emulator.manager)
        model.boot.bootTiming = Self.fastBoots
        model.apps.bootTiming = Self.fastBoots
        model.workspace.mirror.sessionFactoryOverride = { _, _ in
            XCTFail("a boot started a session")
            return FakeMirrorSession()
        }
        model.deviceSelection = .device("emulator-5554")

        let outcome = await model.boot.bootEmulator(
            avd: target,
            coldBoot: false,
            manager: emulator.manager,
            adbClient: adb.client,
            launched: {},
            progress: { _ in }
        )

        guard case .booted = outcome else {
            return XCTFail("expected a booted VM, got \(outcome)")
        }
        XCTAssertEqual(model.deviceSelection, .device("emulator-5554"))
        XCTAssertNil(model.workspace.mirror.session)
        XCTAssertNil(model.status.errorMessage)
    }

    // MARK: - Starts in flight

    /// A second Start of an AVD whose start is in flight is a no-op; another
    /// AVD starts independently, and a finished start frees the AVD.
    func testASecondStartWhileOneIsInFlightIsANoOp() {
        let boot = makeController()

        XCTAssertTrue(boot.claim("Pixel_A"))
        boot.markBooting("Pixel_A")
        XCTAssertFalse(boot.claim("Pixel_A"), "a second Start of the same AVD")
        XCTAssertEqual(boot.startingAvdNames, ["Pixel_A"], "the refused Start changes nothing")
        XCTAssertTrue(boot.claim("Pixel_B"), "another AVD starts independently")

        boot.finish("Pixel_A")
        XCTAssertEqual(boot.startingAvdNames, [])
        XCTAssertTrue(boot.claim("Pixel_A"), "a finished start frees the AVD")
    }

    /// A Stop that lands before the launch (while Power On kills the broken
    /// VM, say) wins: nothing is launched and the boot ends as the user's
    /// stop, not as a failure.
    func testAStopBeforeTheLaunchReturnsStoppedByUser() async throws {
        let target = "Early_\(UUID().uuidString.prefix(6))"
        let emulator = try makeStubEmulator(avds: [target])
        let adb = AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false"))
        let status = StatusCenter()
        let boot = makeController(adb: adb, status: status)
        XCTAssertTrue(boot.claim(target))
        boot.requestStop(target)
        var launched = 0

        let outcome = await boot.bootEmulator(
            avd: target,
            coldBoot: true,
            manager: emulator.manager,
            adbClient: adb,
            launched: { launched += 1 },
            progress: { _ in }
        )

        guard case .stoppedByUser = outcome else {
            return XCTFail("expected the user's stop, got \(outcome)")
        }
        XCTAssertEqual(launched, 0)
        XCTAssertEqual(emulator.launches, [], "nothing is launched")
        XCTAssertNil(status.errorMessage)
        XCTAssertTrue(boot.isStoppedByUser(target), "the mark holds until the start finishes")
        boot.finish(target)
        XCTAssertFalse(boot.isStoppedByUser(target))
    }

    /// Only the booting panel is observed: a claim and a stop mark show
    /// nowhere (attaching to a running AVD must not show its booting
    /// panel), so they must not invalidate the views that read it.
    func testOnlyTheBootingPanelIsObserved() {
        let boot = makeController()

        XCTAssertFalse(notifiesBootingPanel(boot) { _ = boot.claim("Pixel_A") })
        XCTAssertFalse(notifiesBootingPanel(boot) { boot.requestStop("Pixel_A") })
        XCTAssertFalse(notifiesBootingPanel(boot) { boot.withdrawStop("Pixel_A") })
        XCTAssertTrue(notifiesBootingPanel(boot) { boot.markBooting("Pixel_A") })
        XCTAssertTrue(notifiesBootingPanel(boot) { boot.markBooted("Pixel_A") })
        XCTAssertTrue(notifiesBootingPanel(boot) { boot.finish("Pixel_A") })
    }

    // MARK: - Emulator binary

    /// Settings' emulator binary applies from the next boot on: Start runs
    /// the binary picked last, never the one the model was built with.
    func testTheNextBootRunsTheEmulatorBinaryPickedLast() async throws {
        let target = "Binary_\(UUID().uuidString.prefix(6))"
        let original = try makeStubEmulator(avds: [target])
        let picked = try makeStubEmulator(avds: [target])
        let adb = try makeStubAdb(arms: """
          "devices -l")
            printf 'List of devices attached\\n' ;;
          "track-devices"*)
            exec sleep 30 ;;
        """)
        let model = AppModel.testing(adb: adb.client, emulator: original.manager)
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }
        model.boot.bootTiming = Self.fastBoots
        model.apps.bootTiming = Self.fastBoots
        model.workspace.mirror.sessionFactoryOverride = { _, _ in FakeMirrorSession() }

        model.setEmulatorBinaryPath(picked.manager.emulatorURL.path)
        let start = Task { await model.startAndMirror(avd: target) }
        await waitUntil("the AVD never launched") { !picked.launches.isEmpty }
        await model.stopEmulator(avd: target)
        await start.value

        XCTAssertEqual(picked.launches.count, 1)
        XCTAssertEqual(original.launches, [], "the binary the model was built with")
        XCTAssertNil(model.workspace.status.errorMessage)
        XCTAssertTrue(model.boot.startingAvdNames.isEmpty)
    }
}
