import Darwin
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// A fake emulator (`makeStubEmulator`): its manager, and what it launched.
struct StubEmulator {
    let manager: EmulatorManager
    /// argv lines of every launch, one per line.
    let launchesURL: URL
    let pidsURL: URL

    var launches: [String] {
        ((try? String(contentsOf: launchesURL, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }
}

extension XCTestCase {
    /// A fake emulator binary named like the VM (`qemu-system-…`), so `ps`
    /// lists it with its `-avd`: `-list-avds` answers `avds`, a launch logs
    /// its argv and runs until SIGTERM. Its manager sees only the VMs this
    /// process started, so it finds and stops its own launches and nothing
    /// else running on the Mac.
    func makeStubEmulator(avds: [String]) throws -> StubEmulator {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StubEmulator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let launchesURL = directory.appendingPathComponent("launches.log")
        let pidsURL = directory.appendingPathComponent("pids")
        let url = directory.appendingPathComponent("qemu-system-stub")
        let script = """
        #!/bin/sh
        if [ "$1" = "-list-avds" ]; then
          printf '%s\\n' \(avds.map { "'\($0)'" }.joined(separator: " "))
          exit 0
        fi
        printf '%s\\n' "$*" >> "\(launchesURL.path)"
        echo $$ >> "\(pidsURL.path)"
        trap 'exit 0' TERM
        while :; do sleep 0.1; done
        """
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let manager = EmulatorManager(emulatorURL: url, processScope: .ownProcesses)
        addTeardownBlock {
            // Only the processes this stub started.
            let pids = ((try? String(contentsOf: pidsURL, encoding: .utf8)) ?? "")
                .split(separator: "\n").compactMap { pid_t($0) }
            for pid in pids { kill(pid, SIGKILL) }
            for avd in avds {
                try? FileManager.default.removeItem(at: manager.logFileURL(forAvd: avd))
            }
            try? FileManager.default.removeItem(at: directory)
        }
        return StubEmulator(manager: manager, launchesURL: launchesURL, pidsURL: pidsURL)
    }
}

/// Start and Power On share one boot routine: the booted VM is identified by
/// the AVD name its console answers (never "the first online emulator"), its
/// gRPC token and port come from its discovery file, and a boot the user
/// stops ends silently (F7, F9, F24).
@MainActor
final class EmulatorBootTests: XCTestCase {
    /// An adb for one VM, `emulator-5556`, whose console names `avd`: it
    /// boots at once, and the first device listing after the boot takes a
    /// second. That listing is where Start and Power On sit between the
    /// boot and the session start; `postBootListing` appears when it begins.
    private func slowPostBootAdb(avd: String) throws -> (adb: StubAdb, postBootListing: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PostBoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let booted = directory.appendingPathComponent("booted")
        let listing = directory.appendingPathComponent("post-boot-listing")
        let discovery = directory.appendingPathComponent("discovery.ini")
        let port = try makeOwnedGrpcPort()
        try Data("grpc.port=\(port)\n".utf8).write(to: discovery)
        let adb = try makeStubAdb(arms: """
          "devices -l")
            if [ -e "\(booted.path)" ]; then touch "\(listing.path)"; sleep 1; fi
            printf 'List of devices attached\\n'
            printf 'emulator-5556          device product:sdk model:Target transport_id:8\\n' ;;
          "-s emulator-5556 emu avd name")
            printf '%s\\r\\nOK\\r\\n' "\(avd)" ;;
          "-s emulator-5556 emu avd discoverypath")
            printf '%s\\r\\nOK\\r\\n' "\(discovery.path)" ;;
          "-s emulator-5556 shell getprop")
            touch "\(booted.path)"
            printf '[sys.boot_completed]: [1]\\n' ;;
          "track-devices"*)
            exec sleep 30 ;;
        """)
        return (adb, listing)
    }

    private func fastBoots(_ model: AppModel) {
        let bootTiming = EmulatorBootController.BootTiming(
            startupGrace: .milliseconds(100),
            poll: .milliseconds(100),
            onlineTimeout: .seconds(10),
            bootTimeout: .seconds(10)
        )
        model.boot.bootTiming = bootTiming
        model.apps.bootTiming = bootTiming
    }

    /// Power On with another emulator already online: the relaunched VM is
    /// the one whose console names the AVD, and its session pairs that serial
    /// with the port from its discovery file. (It used to take the first
    /// online emulator — here the other VM.)
    func testPowerOnPairsTheVMWhoseConsoleNamesTheAvd() async throws {
        let target = "Target_\(UUID().uuidString.prefix(6))"
        let other = "Other_\(UUID().uuidString.prefix(6))"
        let emulator = try makeStubEmulator(avds: [target, other])
        let discovery = FileManager.default.temporaryDirectory
            .appendingPathComponent("discovery-\(UUID().uuidString).ini")
        let port = try makeOwnedGrpcPort()
        try Data("grpc.port=\(port)\ngrpc.token=secret\n".utf8).write(to: discovery)
        addTeardownBlock { try? FileManager.default.removeItem(at: discovery) }
        let adb = try makeStubAdb(arms: """
          "devices -l")
            printf 'List of devices attached\\n'
            printf 'emulator-5554          device product:sdk model:Other transport_id:3\\n'
            printf 'emulator-5556          device product:sdk model:Target transport_id:8\\n' ;;
          "-s emulator-5554 emu avd name")
            printf '%s\\r\\nOK\\r\\n' "\(other)" ;;
          "-s emulator-5556 emu avd name")
            printf '%s\\r\\nOK\\r\\n' "\(target)" ;;
          "-s emulator-5556 emu avd discoverypath")
            printf '%s\\r\\nOK\\r\\n' "\(discovery.path)" ;;
          "-s emulator-5556 shell getprop")
            printf '[sys.boot_completed]: [1]\\n' ;;
        """)
        let model = AppModel.testing(adb: adb.client, emulator: emulator.manager)
        fastBoots(model)
        var started: [(serial: String, port: Int?)] = []
        model.workspace.mirror.sessionFactoryOverride = { serial, port in
            started.append((serial, port))
            return FakeMirrorSession()
        }
        model.setActiveAvdName(target)

        await model.powerOnDevice()

        XCTAssertNil(model.workspace.status.errorMessage)
        XCTAssertEqual(started.map(\.serial), ["emulator-5556"], "the VM for \(target), not the first online emulator")
        XCTAssertEqual(started.first?.port, port, "the port the VM's discovery file names")
        XCTAssertEqual(EmulatorControl.token(forPort: port), "secret", "the token is registered before any gRPC call")
        XCTAssertEqual(model.activeAvdName, target)
        let launch = try XCTUnwrap(emulator.launches.first)
        XCTAssertTrue(launch.contains("-grpc-use-token"), launch)
        XCTAssertTrue(launch.contains("-no-snapshot-load"), "a powered-off guest is cold-booted: \(launch)")
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.boot.startingAvdNames.isEmpty)
        model.stopMirror()
        EmulatorControl.registerToken(nil, forPort: port)
    }

    /// Stopping an AVD while it boots ends the boot quietly: no "exited
    /// during startup" alert for a stop the user asked for.
    func testStoppingABootingAvdEndsTheBootSilently() async throws {
        let target = "Booting_\(UUID().uuidString.prefix(6))"
        let emulator = try makeStubEmulator(avds: [target])
        let adb = try makeStubAdb(arms: """
          "devices -l")
            printf 'List of devices attached\\n' ;;
          "track-devices"*)
            exec sleep 30 ;;
        """)
        let model = AppModel.testing(adb: adb.client, emulator: emulator.manager)
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }
        fastBoots(model)
        model.workspace.mirror.sessionFactoryOverride = { _, _ in FakeMirrorSession() }

        let boot = Task { await model.startAndMirror(avd: target) }
        await waitUntil("the AVD never launched") { !emulator.launches.isEmpty }
        XCTAssertTrue(model.avdIsBooting(target))

        await model.stopEmulator(avd: target)
        await boot.value

        XCTAssertNil(model.workspace.status.errorMessage, "a stop the user asked for is not a failed start")
        XCTAssertNil(model.workspace.mirror.session)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.boot.startingAvdNames.isEmpty)
    }

    /// Two Starts of the same AVD in quick succession: the second is a
    /// no-op even when it lands before the first one's first await (its
    /// `ps` read). Both used to pass the guard and launch; the loser then
    /// exited with "another instance" and ended the winner's booting panel.
    func testSecondStartBeforeTheFirstLaunchesIsANoOp() async throws {
        let target = "Twice_\(UUID().uuidString.prefix(6))"
        let emulator = try makeStubEmulator(avds: [target])
        let adb = try makeStubAdb(arms: """
          "devices -l")
            printf 'List of devices attached\\n' ;;
          "track-devices"*)
            exec sleep 30 ;;
        """)
        let model = AppModel.testing(adb: adb.client, emulator: emulator.manager)
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }
        fastBoots(model)
        model.workspace.mirror.sessionFactoryOverride = { _, _ in FakeMirrorSession() }

        let first = Task { await model.startAndMirror(avd: target) }
        let second = Task { await model.startAndMirror(avd: target) }
        await second.value
        await waitUntil("the AVD never launched") { !emulator.launches.isEmpty }
        // Room for a second launch to show up if one were under way.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(emulator.launches.count, 1, "one VM per AVD: \(emulator.launches)")
        XCTAssertTrue(model.avdIsBooting(target), "the first start still owns its booting panel")

        await model.stopEmulator(avd: target)
        await first.value
        XCTAssertNil(model.workspace.status.errorMessage)
        XCTAssertTrue(model.boot.startingAvdNames.isEmpty)
    }

    /// A Stop that lands after the boot, while Start still reads the device
    /// list and the gallery, ends the start without a session: one on the
    /// VM being shut down would read its exit as a disconnect (ghost row,
    /// auto-resume, "interrupted" recording).
    func testStopAfterTheBootStartsNoSession() async throws {
        let target = "Stopped_\(UUID().uuidString.prefix(6))"
        let emulator = try makeStubEmulator(avds: [target])
        let (adb, postBootListing) = try slowPostBootAdb(avd: target)
        let model = AppModel.testing(adb: adb.client, emulator: emulator.manager)
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }
        fastBoots(model)
        var started: [String] = []
        model.workspace.mirror.sessionFactoryOverride = { serial, _ in
            started.append(serial)
            return FakeMirrorSession()
        }

        let boot = Task { await model.startAndMirror(avd: target) }
        await waitUntil("the boot never finished") {
            FileManager.default.fileExists(atPath: postBootListing.path)
        }
        await model.stopEmulator(avd: target)
        await boot.value

        XCTAssertEqual(started, [], "no session on the VM the user stopped")
        XCTAssertNil(model.workspace.mirror.session)
        XCTAssertNil(model.workspace.status.errorMessage)
        XCTAssertFalse(model.isBusy)
    }

    /// The same window in Power On.
    func testStopAfterAPowerOnBootStartsNoSession() async throws {
        let target = "PowerStop_\(UUID().uuidString.prefix(6))"
        let emulator = try makeStubEmulator(avds: [target])
        let (adb, postBootListing) = try slowPostBootAdb(avd: target)
        let model = AppModel.testing(adb: adb.client, emulator: emulator.manager)
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }
        fastBoots(model)
        var started: [String] = []
        model.workspace.mirror.sessionFactoryOverride = { serial, _ in
            started.append(serial)
            return FakeMirrorSession()
        }
        model.setActiveAvdName(target)

        let powerOn = Task { await model.powerOnDevice() }
        await waitUntil("the boot never finished") {
            FileManager.default.fileExists(atPath: postBootListing.path)
        }
        await model.stopEmulator(avd: target)
        await powerOn.value

        XCTAssertEqual(started, [], "no session on the VM the user stopped")
        XCTAssertNil(model.workspace.mirror.session)
        XCTAssertNil(model.workspace.status.errorMessage)
    }

    /// Start of an AVD that is already running attaches to it; a Stop that
    /// lands while the attach reads the VM's discovery file ends it without
    /// a session (the attach used to be invisible to Stop).
    func testStopDuringAnAttachStartsNoSession() async throws {
        let target = "Attach_\(UUID().uuidString.prefix(6))"
        let emulator = try makeStubEmulator(avds: [target])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Attach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let reading = directory.appendingPathComponent("reading-discovery")
        let discovery = directory.appendingPathComponent("discovery.ini")
        let port = try makeOwnedGrpcPort()
        try Data("grpc.port=\(port)\n".utf8).write(to: discovery)
        let adb = try makeStubAdb(arms: """
          "devices -l")
            printf 'List of devices attached\\n'
            printf 'emulator-5556          device product:sdk model:Target transport_id:8\\n' ;;
          "-s emulator-5556 emu avd name")
            printf '%s\\r\\nOK\\r\\n' "\(target)" ;;
          "-s emulator-5556 emu avd discoverypath")
            touch "\(reading.path)"
            sleep 1
            printf '%s\\r\\nOK\\r\\n' "\(discovery.path)" ;;
          "track-devices"*)
            exec sleep 30 ;;
        """)
        // The VM runs before the Start (as if started earlier or elsewhere).
        _ = try emulator.manager.launch(avd: target, grpcPort: port)
        await waitUntil("the VM never started") { !emulator.launches.isEmpty }
        let model = AppModel.testing(adb: adb.client, emulator: emulator.manager)
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }
        fastBoots(model)
        var started: [String] = []
        model.workspace.mirror.sessionFactoryOverride = { serial, _ in
            started.append(serial)
            return FakeMirrorSession()
        }

        let attach = Task { await model.startAndMirror(avd: target) }
        await waitUntil("the attach never read the discovery file") {
            FileManager.default.fileExists(atPath: reading.path)
        }
        await model.stopEmulator(avd: target)
        await attach.value

        XCTAssertEqual(started, [], "no session on the VM the user stopped")
        XCTAssertEqual(emulator.launches.count, 1, "an attach launches nothing")
        XCTAssertNil(model.workspace.mirror.session)
        XCTAssertNil(model.workspace.status.errorMessage)
    }

    /// Start of an AVD that is already running attaches to it; if the user
    /// selects another device while the attach reads the device list and the
    /// gallery, the attach ends without a session, as a boot that finishes
    /// after they moved on does. (It used to start the AVD's session anyway,
    /// replacing whatever the stage showed for the device they picked.)
    func testSelectingAnotherDeviceDuringAnAttachStartsNoSession() async throws {
        let target = "Moved_\(UUID().uuidString.prefix(6))"
        let emulator = try makeStubEmulator(avds: [target])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachMoved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let discovered = directory.appendingPathComponent("discovered")
        let listing = directory.appendingPathComponent("post-attach-listing")
        let discovery = directory.appendingPathComponent("discovery.ini")
        let port = try makeOwnedGrpcPort()
        try Data("grpc.port=\(port)\n".utf8).write(to: discovery)
        // The first listing after the discovery read is the attach's own
        // re-read before it refreshes the gallery: it takes a second.
        let adb = try makeStubAdb(arms: """
          "devices -l")
            if [ -e "\(discovered.path)" ]; then touch "\(listing.path)"; sleep 1; fi
            printf 'List of devices attached\\n'
            printf 'emulator-5556          device product:sdk model:Target transport_id:8\\n' ;;
          "-s emulator-5556 emu avd name")
            printf '%s\\r\\nOK\\r\\n' "\(target)" ;;
          "-s emulator-5556 emu avd discoverypath")
            touch "\(discovered.path)"
            printf '%s\\r\\nOK\\r\\n' "\(discovery.path)" ;;
          "track-devices"*)
            exec sleep 30 ;;
        """)
        // The VM runs before the Start (as if started earlier or elsewhere).
        _ = try emulator.manager.launch(avd: target, grpcPort: port)
        await waitUntil("the VM never started") { !emulator.launches.isEmpty }
        let model = AppModel.testing(adb: adb.client, emulator: emulator.manager)
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }
        fastBoots(model)
        var started: [String] = []
        model.workspace.mirror.sessionFactoryOverride = { serial, _ in
            started.append(serial)
            return FakeMirrorSession()
        }

        let attach = Task { await model.startAndMirror(avd: target) }
        await waitUntil("the attach never re-read the device list") {
            FileManager.default.fileExists(atPath: listing.path)
        }
        XCTAssertEqual(model.deviceSelection, .avd(target), "the attach selects its AVD first")
        model.deviceSelection = .device("emulator-5554")
        await attach.value

        XCTAssertEqual(started, [], "no session for an AVD the user moved away from")
        XCTAssertEqual(model.deviceSelection, .device("emulator-5554"))
        XCTAssertNil(model.workspace.mirror.session)
        XCTAssertNil(model.workspace.status.errorMessage)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(emulator.launches.count, 1, "an attach launches nothing")
    }
}
