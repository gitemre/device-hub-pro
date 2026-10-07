import Foundation
import Observation
import DeviceHubProKit

/// Boots AVDs for Start and Power On and keeps the bookkeeping of the
/// starts in flight: which of them show their booting panel, and which the
/// user stopped while they ran.
///
/// It never touches the selection or the sessions: `AppModel`'s
/// `startAndMirror`, `powerOnDevice` and `stopEmulator` orchestrate those
/// and call in here. `AppModel` owns one as `boot`; the tests shorten its
/// `bootTiming` directly. It holds no reference to the model: the
/// consoles' AVD names and the gRPC port cache go through the hooks below,
/// which the model sets once it is built. A boot runs on the emulator its
/// caller hands it, so a boot in flight keeps the binary it started with
/// when Settings swaps it.
@MainActor
@Observable
final class EmulatorBootController {
    /// The starts in flight, the booting panels and the user's stops. Not
    /// observed as a whole: a claim is shown nowhere (attaching to a running
    /// AVD must not show its booting panel), so only `startingAvdNames`
    /// reports changes, through the mutators below.
    @ObservationIgnored private var registry = AvdStartRegistry()

    /// The AVDs an in-app start or restart is booting. The canvas shows
    /// their booting panel until the boot completes (spec §6.4). A set: two
    /// AVDs can boot at once, and one finishing must not end the other's.
    var startingAvdNames: Set<String> {
        access(keyPath: \.startingAvdNames)
        return registry.starting
    }

    private let adbClient: AdbClient?
    private let status: StatusCenter
    private let preferences: AppPreferences

    /// The AVD `device` runs, from its owner's per-transport cache or its
    /// console (`AppModel.avdName(of:)`); nil while the console does not
    /// answer.
    @ObservationIgnored var consoleAvdName: @MainActor (_ device: AndroidDevice) async -> String? = { _ in nil }
    /// Records the gRPC port a booted VM serves under its serial, where the
    /// mirror and the controls look it up (`AppModel`'s gRPC port cache).
    @ObservationIgnored var storeGrpcPort: @MainActor (_ port: Int, _ serial: String) -> Void = { _, _ in }

    /// The AVD's `config.ini` values (`hw.device.name`, the LCD size) for the
    /// device-emulation overlay; the tests answer their own.
    @ObservationIgnored var avdConfig: (_ avd: String) -> [String: String] = { AvdConfig.values(avdName: $0) }

    init(adbClient: AdbClient?, status: StatusCenter, preferences: AppPreferences) {
        self.adbClient = adbClient
        self.status = status
        self.preferences = preferences
    }

    // MARK: - Starts in flight

    /// Claims `avd` for a Start (launch or attach) or Power On, before its
    /// first await: a second request for the same AVD is then a no-op and a
    /// Stop always finds it. False, changing nothing, while a start of it is
    /// in flight: a second launch would shut the booting instance down.
    func claim(_ avd: String) -> Bool {
        registry.claim(avd)
    }

    /// The claimed start is booting a VM: the stage shows its booting panel.
    func markBooting(_ avd: String) {
        withMutation(keyPath: \.startingAvdNames) { registry.markBooting(avd) }
    }

    /// Android finished booting: the booting panel ends, while the claim
    /// holds until `finish(_:)`.
    func markBooted(_ avd: String) {
        withMutation(keyPath: \.startingAvdNames) { registry.markBooted(avd) }
    }

    /// The user stops `avd`. A start of it in flight then ends silently (no
    /// "exited during startup") and never starts a session on the VM being
    /// shut down.
    func requestStop(_ avd: String) {
        registry.requestStop(avd)
    }

    /// The stop failed and the VM lives on, so a boot still waiting on it
    /// must report as usual.
    func withdrawStop(_ avd: String) {
        registry.withdrawStop(avd)
    }

    /// Whether the user stopped the start of `avd` while it was in flight.
    func isStoppedByUser(_ avd: String) -> Bool {
        registry.isStoppedByUser(avd)
    }

    /// The start ended, however it ended: its claim, its booting panel and
    /// its stop mark all go.
    func finish(_ avd: String) {
        withMutation(keyPath: \.startingAvdNames) { registry.finish(avd) }
    }

    // MARK: - Boot

    /// How a boot `bootEmulator` ran ended.
    enum BootOutcome {
        /// Android finished booting (or the boot wait ran out with the VM
        /// still up): its adb serial and the gRPC port it serves.
        case booted(serial: String, port: Int)
        /// The launch failed, the VM exited, or it never came online.
        /// `details` is the emulator log's useful tail, for a disclosure.
        case failed(String, details: String? = nil)
        /// The user stopped the VM while it booted; nothing to report.
        case stoppedByUser
    }

    /// The boot loops' clock, shortened by tests.
    struct BootTiming {
        /// How long a fresh VM gets before an exit counts as a failed start.
        var startupGrace: Duration = .seconds(2)
        var poll: Duration = .seconds(1)
        /// How long adb may take to list the VM online.
        var onlineTimeout: Duration = .seconds(180)
        /// How long Android may take to report `sys.boot_completed`.
        var bootTimeout: Duration = .seconds(180)
    }
    @ObservationIgnored var bootTiming = BootTiming()

    /// Launches `avd` and waits until Android has booted. Shared by Start and
    /// Power On, so both identify their VM the same way: by the AVD name its
    /// console answers, never as "the first new emulator" — with another VM
    /// booting or running, that would pair this VM's gRPC port with the other
    /// one's serial (adb input and controls to one, frames from the other).
    ///
    /// The VM is launched with `-grpc-use-token`. Once adb lists it, its
    /// discovery file is read: that registers the token for the port before
    /// any gRPC call, and its port wins over the requested one. The port's
    /// in-process reservation is released when the launch fails or the VM
    /// exits during startup.
    func bootEmulator(
        avd: String,
        coldBoot: Bool,
        manager: EmulatorManager,
        adbClient: AdbClient,
        launched: () -> Void,
        progress: (String) -> Void
    ) async -> BootOutcome {
        // A Stop that landed before the launch (while Power On killed the
        // broken VM, say) wins: nothing is launched.
        if registry.isStoppedByUser(avd) { return .stoppedByUser }
        if let refusal = await launchRefusal(avd: avd, manager: manager) {
            return .failed(refusal)
        }
        // The check above waited on `ps`: a Stop may have landed meanwhile.
        if registry.isStoppedByUser(avd) { return .stoppedByUser }
        // The manager picks it: a free, reserved port from 8554 on, except
        // on a test's own-process manager (see `reserveGrpcPort()`).
        let requestedPort = manager.reserveGrpcPort()
        let process: Process
        do {
            process = try manager.launch(
                avd: avd,
                grpcPort: requestedPort,
                audioEnabled: emulatorAudioMode.emulatorAudioEnabled,
                coldBoot: coldBoot,
                grpcTokenAuth: true
            )
        } catch {
            EmulatorManager.releasePortReservation(requestedPort)
            return .failed("\(error)")
        }
        launched()

        func exited(_ when: String) -> BootOutcome {
            EmulatorManager.releasePortReservation(requestedPort)
            if registry.consumeStop(avd) { return .stoppedByUser }
            let failure = EmulatorStartFailure.exited(when, logTail: manager.logTail(forAvd: avd, lines: 60))
            return .failed(failure.message, details: failure.details)
        }

        // Fail fast when the emulator exits immediately (bad AVD, lock, crash…).
        try? await Task.sleep(for: bootTiming.startupGrace)
        if !process.isRunning { return exited("during startup") }

        progress("Waiting for the emulator to come online…")
        let onlineDeadline = ContinuousClock.now + bootTiming.onlineTimeout
        var bootedSerial: String?
        while bootedSerial == nil {
            try? await Task.sleep(for: bootTiming.poll)
            // Best effort: a failed read (adb restarting mid-boot) is just
            // polled again; the device list itself belongs to the watcher.
            if let current = try? await adbClient.listDevices() {
                bootedSerial = await serial(forAvd: avd, among: current)
            }
            if bootedSerial != nil { break }
            if !process.isRunning { return exited("during startup") }
            if ContinuousClock.now >= onlineDeadline {
                return .failed(
                    "\(avd) did not come online in time.",
                    details: EmulatorStartFailure.detail(from: manager.logTail(forAvd: avd, lines: 60))
                )
            }
        }
        guard let serial = bootedSerial else {
            return .failed("\(avd) did not come online in time.")
        }

        var port = requestedPort
        if let info = await publishedGrpcInfo(serial: serial, adbClient: adbClient) {
            if info.port != requestedPort {
                EmulatorManager.releasePortReservation(requestedPort)
            }
            port = info.port
        } else {
            errorMessage = "Couldn't get access to \(avd)'s controls, so its mirror and controls may be refused. Restart it from Device Hub Pro if they stay unavailable."
        }
        storeGrpcPort(port, serial)
        progress("Waiting for Android to finish booting…")

        let bootDeadline = ContinuousClock.now + bootTiming.bootTimeout
        var bootCompleted = false
        while ContinuousClock.now < bootDeadline {
            if (try? await adbClient.isBootCompleted(serial: serial)) == true {
                bootCompleted = true
                break
            }
            try? await Task.sleep(for: bootTiming.poll)
            if !process.isRunning { return exited("while booting") }
        }
        if bootCompleted {
            await enableEmulationOverlay(avd: avd, serial: serial, adbClient: adbClient)
            // A cold boot (and a first boot) ends on a dark or locked screen;
            // the user started it to use it. A swipe lock goes, a secure one
            // shows its entry screen. Best effort.
            try? await adbClient.wakeScreen(serial: serial, dismissKeyguard: true)
        }
        return .booted(serial: serial, port: port)
    }

    /// Gives Android the display shape of the AVD's device (rounded corners,
    /// camera cutout) when the image knows no overlay for it: see
    /// `EmulationOverlay`. Idempotent and best effort.
    func enableEmulationOverlay(avd: String, serial: String, adbClient: AdbClient) async {
        let values = avdConfig(avd)
        await EmulationOverlay.apply(
            deviceName: values["hw.device.name"],
            lcdWidth: values["hw.lcd.width"].flatMap { Int($0) },
            lcdHeight: values["hw.lcd.height"].flatMap { Int($0) }
        ) { arguments in
            try await adbClient.shell(serial: serial, arguments)
        }
    }

    /// The VM's discovery file once its console publishes it (it can lag
    /// adb's "device" state by a moment); nil after a few tries.
    private func publishedGrpcInfo(serial: String, adbClient: AdbClient) async -> EmulatorGRPCInfo? {
        for attempt in 0..<10 {
            if let info = await EmulatorDiscovery.grpcInfo(serial: serial, adbClient: adbClient) {
                return info
            }
            if attempt < 9 {
                try? await Task.sleep(for: bootTiming.poll / 2)
            }
        }
        return nil
    }

    /// Why `avd` must not be launched (or have its display repaired) now,
    /// or nil when it may: a VM already runs it, or whether one does cannot
    /// be read. Any VM on the Mac counts, also one outside `manager`'s
    /// process scope (a test's model sees only its own VMs): a second VM of
    /// a running AVD takes the first one down, and Start's display repair
    /// would rewrite the `config.ini` it runs on. In the app, where every VM
    /// is in scope, this answers only when a VM of the AVD appeared after
    /// Start looked for one to attach to.
    func launchRefusal(avd: String, manager: EmulatorManager) async -> String? {
        do {
            guard try await manager.isAnyVMRunning(avd: avd) else { return nil }
            return "\(avd) is already running, so a second instance was not started."
        } catch {
            return "Couldn't verify whether \(avd) is already running, so it was not started — try again."
        }
    }

    func runningEmulator(named avd: String, manager: EmulatorManager) async -> RunningEmulator? {
        let running = (try? await manager.runningEmulators()) ?? []
        return running.first { $0.avd == avd }
    }

    func serial(forAvd avd: String, adbClient: AdbClient) async -> String? {
        // Best effort: without a device list no console can be asked.
        guard let current = try? await adbClient.listDevices() else { return nil }
        return await serial(forAvd: avd, among: current)
    }

    /// The online emulator in `devices` whose console names `avd`.
    private func serial(forAvd avd: String, among devices: [AndroidDevice]) async -> String? {
        for device in devices where device.isEmulator && device.isOnline {
            if await avdName(of: device) == avd {
                return device.serial
            }
        }
        return nil
    }

    /// Stops `avd`'s VM on `manager` (`EmulatorManager.stop`): the console
    /// `kill` through `serial` when it is known, then signals. What the stop
    /// means for the mirror and the starts in flight is
    /// `AppModel.stopEmulator(avd:)`'s.
    func stop(avd: String, serial: String?, manager: EmulatorManager) async throws -> EmulatorStopResult {
        try await manager.stop(avd: avd, serial: serial, adb: adbClient)
    }

    // MARK: - Shims

    // Its owner's settings, console answers and `StatusCenter` under the
    // names the moved call sites use, so their text is unchanged.

    private var emulatorAudioMode: EmulatorAudioMode { preferences.emulatorAudioMode }

    private var errorMessage: String? {
        get { status.errorMessage }
        set { status.errorMessage = newValue }
    }

    private func avdName(of device: AndroidDevice) async -> String? {
        await consoleAvdName(device)
    }
}
