import AppKit
import Foundation
import Observation
import DeviceHubProKit

/// The emulator hardware of the Controls tab and the stage's fold strip:
/// the battery level (debounced) and the charger, the fold posture
/// animation and the hinge sender, the Device menu's fold toggle, and the
/// resizable display's presets (offered only for an AVD with a resizable
/// display, `isResizableAvd`).
///
/// One long-lived instance, owned by `DeviceWorkspace` as `hardware`; the
/// views read it there. It
/// acts on the shared `ActiveDeviceContext`, writes the Controls panel's
/// state (`DeviceControlsController.controls`) and runs its refresh, and
/// reports through `StatusCenter`. It holds no reference to the model: the
/// mirror it repaints, the device list and the model's AVD names go
/// through the hooks below, which the model sets once it is built. The
/// session hubs drive it: `startResizePresetsLoad()` when an emulator
/// session starts, `detach()` when the mirror goes away.
@MainActor
@Observable
final class EmulatorHardwareController {
    private let adbClient: AdbClient?
    private let context: ActiveDeviceContext
    private let controlsPanel: DeviceControlsController
    private let status: StatusCenter

    init(
        adbClient: AdbClient?,
        context: ActiveDeviceContext,
        controlsPanel: DeviceControlsController,
        status: StatusCenter
    ) {
        self.adbClient = adbClient
        self.context = context
        self.controlsPanel = controlsPanel
        self.status = status
    }

    /// Repaints the mirror from a consistent snapshot once a fold settles.
    /// `AppModel` wires it to its session's `resync()`.
    @ObservationIgnored var resync: @MainActor () async -> Void = {}
    /// The adb device list, which tells the resize presets whether the
    /// mirrored serial is an emulator. `AppModel` wires it to `devices`.
    @ObservationIgnored var devicesSource: @MainActor () -> [AndroidDevice] = { [] }
    /// The AVD a listed emulator runs, from the model's per-transport cache
    /// or its console. `AppModel` wires it to its AVD-name lookup.
    @ObservationIgnored var avdNameLookup: @MainActor (_ device: AndroidDevice) async -> String? = { _ in nil }

    /// Per-device workers, cancelled when the mirror goes away so none of
    /// them acts on the next device. Readable for tests.
    private(set) var batteryApplyTask: Task<Void, Never>?
    private(set) var hingeSendTask: Task<Void, Never>?
    private var pendingHingeAngle: Double?
    private(set) var postureAnimationTask: Task<Void, Never>?

    var isFoldable: Bool {
        controls.isFoldable || activeHingeCount > 0
    }

    /// The fold control strip only for foldable emulators (spec §9).
    var showsFoldControls: Bool {
        activeSerial != nil && isFoldable
    }

    func setBatteryLevel(_ level: Int) {
        controls.battery?.level = level
        batteryApplyTask?.cancel()
        // Bound to this device: the worker is cancelled with the mirror, and
        // never picks up the next device's port.
        guard let port = activePort else { return }
        batteryApplyTask = Task { [weak self] in
            // Best effort: the sleep fails only on cancellation, checked next.
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            let charging = self.controls.battery?.isCharging ?? true
            let applied = await EmulatorControls.setBattery(port: port, level: level, charging: charging)
            guard !Task.isCancelled else { return }
            if !applied {
                self.flashStatus("The emulator rejected the battery level")
            }
        }
    }

    func toggleCharging() async {
        guard let battery = controls.battery, let port = activePort else { return }
        let wanted = !battery.isCharging
        controls.battery?.isCharging = wanted
        guard await EmulatorControls.setBattery(port: port, level: battery.level, charging: wanted) else {
            controls.battery?.isCharging = battery.isCharging
            return
        }
        if let fresh = await EmulatorControls.battery(port: port) {
            controls.battery = fresh
        }
    }

    /// Animates the hinge to the posture's angle so folding looks gradual
    /// instead of jumping in one step.
    func setPostureAnimated(_ target: PostureKind) {
        postureAnimationTask?.cancel()
        // Bound to this device, like the battery and hinge workers: the
        // animation runs on the port (or console) mirrored now, never on
        // whatever device a later session puts in the context before the
        // task first runs.
        let port = activePort
        let serial = activeSerial
        postureAnimationTask = Task { [weak self] in
            await self?.runPostureAnimation(target, port: port, serial: serial)
            if !Task.isCancelled {
                self?.postureAnimationTask = nil
            }
        }
    }

    private func runPostureAnimation(_ target: PostureKind, port: Int?, serial: String?) async {
        // A teardown (or a newer animation) cancelled it before it ran: its
        // first write must not go out either.
        guard !Task.isCancelled else { return }
        // Fallback without gRPC: use the emulator console command. This is
        // what keeps the fold strip's preset buttons enabled console-only
        // (spec §10: presets snap after settle; only the slider is disabled
        // without a gRPC port — `FoldControlStrip` relies on this branch).
        guard let port else {
            guard let adbClient, let serial else { return }
            _ = try? await adbClient.emuCommand(
                serial: serial,
                ["posture", "\(target.protobufValue)"]
            )
            controls.posture = target
            try? await Task.sleep(for: .milliseconds(600))
            await refreshControls()
            return
        }

        let targetAngle = target.hingeAngle

        // Opening from fully closed: the emulator only powers the inner display
        // once the posture changes, so set it first; the reported hinge angle
        // then becomes the start of the visual animation.
        if controls.posture == .closed, target != .closed {
            controls.posture = target
            _ = await EmulatorControls.setPosture(port: port, posture: target)
            try? await Task.sleep(for: .milliseconds(500))
            let state = await EmulatorControls.state(port: port)
            controls.hingeAngle = state.hingeAngle ?? targetAngle
            await refreshControls()
            return
        }

        controls.posture = target

        // Reduce Motion: jump straight to the target angle.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            controls.hingeAngle = targetAngle
            _ = await EmulatorControls.setHingeAngle(port: port, degrees: targetAngle)
            await refreshControls()
            return
        }

        let startAngle = controls.hingeAngle ?? targetAngle

        // Manual hinge input or a new animation cancels any in-flight sender.
        pendingHingeAngle = nil
        hingeSendTask?.cancel()
        hingeSendTask = nil

        let stepInterval = MotionMetrics.foldStepInterval
        let steps = max(Int(MotionMetrics.foldDuration / stepInterval), 1)
        for step in 1...steps {
            if Task.isCancelled { return }
            let progress = Double(step) / Double(steps)
            let eased = 1 - pow(1 - progress, 3)
            let angle = startAngle + (targetAngle - startAngle) * eased
            _ = await EmulatorControls.setHingeAngle(port: port, degrees: angle)
            controls.hingeAngle = angle
            try? await Task.sleep(for: .seconds(stepInterval))
        }

        if Task.isCancelled { return }
        _ = await EmulatorControls.setPosture(port: port, posture: target)
        try? await Task.sleep(for: .milliseconds(400))
        await refreshControls()
        await resync()
    }

    /// Sends hinge changes while the slider is dragged, immediately and then at
    /// most every 50 ms, so dragging folds the device smoothly.
    func setHingeAngle(_ degrees: Double) {
        postureAnimationTask?.cancel()
        postureAnimationTask = nil

        controls.hingeAngle = degrees
        pendingHingeAngle = degrees

        // The slider needs gRPC (`FoldControlStrip` hides it without); the
        // worker is bound to this device's port and cancelled with it.
        guard hingeSendTask == nil, let port = activePort else { return }
        hingeSendTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let angle = self.pendingHingeAngle {
                    self.pendingHingeAngle = nil
                    _ = await EmulatorControls.setHingeAngle(port: port, degrees: angle)
                    // Best effort: the sleep fails only on cancellation, checked by the loop.
                    try? await Task.sleep(for: .milliseconds(50))
                    continue
                }
                // Drained: repaint once. A drag that resumed during the
                // repaint found this worker still registered and only queued
                // its angle, so the worker goes on instead of dropping it.
                await self.resync()
                guard !Task.isCancelled else { return }
                if self.pendingHingeAngle == nil {
                    // Still its own handle: a cancelled worker returned above.
                    self.hingeSendTask = nil
                    return
                }
            }
        }
    }

    /// Device Manager's fold/unfold action: collapses an open device and opens
    /// a folded one.
    func toggleFold() {
        let target: PostureKind = controls.posture == .closed ? .opened : .closed
        setPostureAnimated(target)
    }

    // MARK: - Resizable emulator form factors

    var resizePresets: [ResizePreset] = []
    var selectedResizePreset: Int?
    /// The preset read every emulator session starts with. Teardown clears
    /// the presets, and a re-attach to the same serial (Mirror again, the
    /// stage's Retry, Start of the mirrored AVD) happens within one
    /// main-actor turn, so ControlsView's serial-keyed task does not run
    /// again to reload them. Readable for tests.
    @ObservationIgnored private(set) var resizePresetsTask: Task<Void, Never>?

    func refreshResizePresets() async {
        guard let adbClient, let serial = activeSerial else {
            resizePresets = []
            return
        }
        let generation = lifecycleGeneration

        let device = devices.first(where: { $0.serial == serial })
        let isEmulator = device?.isEmulator ?? serial.hasPrefix("emulator-")
        var presets: [ResizePreset] = []
        // The console lists the same presets for every AVD, so only an AVD
        // with a resizable display offers them, and any other skips the read.
        // Best effort: an emulator that does not answer offers no presets.
        if isEmulator,
           let avd = await resizePresetsAvdName(serial: serial, device: device),
           isResizableAvd(avd),
           let offered = try? await adbClient.resizeDisplayPresets(serial: serial) {
            presets = offered
        }
        // A slow answer about a session that has since ended must not land
        // on the next one.
        guard generation == lifecycleGeneration else { return }
        resizePresets = presets
    }

    /// Whether the AVD has a resizable display (`AvdConfig.isResizable`).
    /// The console lists the same presets for every AVD, so only a
    /// resizable one offers them. Tests point it at fixture AVD configs.
    @ObservationIgnored var isResizableAvd: (_ avdName: String) -> Bool = { AvdConfig.isResizable(avdName: $0) }

    /// The AVD behind the mirrored emulator: the one the session was started
    /// with, else the console's answer (a session attached to a running
    /// emulator learns its AVD only after it starts).
    private func resizePresetsAvdName(serial: String, device: AndroidDevice?) async -> String? {
        if let activeAvdName { return activeAvdName }
        if let device { return await avdName(of: device) }
        // Best effort: an unanswered console leaves the AVD unknown.
        return try? await adbClient?.avdName(serial: serial)
    }

    func applyResizePreset(_ preset: ResizePreset) async {
        guard let adbClient, let serial = activeSerial else { return }
        do {
            _ = try await adbClient.emuCommand(serial: serial, ["resize-display", "\(preset.index)"])
        } catch {
            errorMessage = "Could not resize the display: \(error)"
            return
        }
        selectedResizePreset = preset.index
        // Best effort: the sleep only lets the new size settle before the read.
        try? await Task.sleep(for: .milliseconds(900))
        await refreshControls()
    }

    // MARK: - Session

    /// Reads the new emulator session's resize presets (see
    /// `resizePresetsTask`).
    func startResizePresetsLoad() {
        resizePresetsTask = Task { [weak self] in await self?.refreshResizePresets() }
    }

    /// Cancels the emulator hardware workers (the battery write, the hinge
    /// sender, the posture animation and the resize-preset read) and
    /// forgets the pending hinge angle and the device's resize presets.
    func detach() {
        batteryApplyTask?.cancel()
        batteryApplyTask = nil
        hingeSendTask?.cancel()
        hingeSendTask = nil
        pendingHingeAngle = nil
        postureAnimationTask?.cancel()
        postureAnimationTask = nil
        resizePresetsTask?.cancel()
        resizePresetsTask = nil
        resizePresets = []
        selectedResizePreset = nil
    }

    // MARK: - Device and status

    /// The mirrored device's adb serial; nil while nothing is mirrored.
    private var activeSerial: String? { context.serial }

    /// The active emulator's gRPC port; nil for a physical device and while
    /// nothing is mirrored.
    private var activePort: Int? { context.port }

    /// The AVD behind the active mirror, once known.
    private var activeAvdName: String? { context.avdName }

    /// The active AVD's hinge sensor count.
    private var activeHingeCount: Int { context.hingeCount }

    /// Bumped by the session hubs at every session start and teardown.
    private var lifecycleGeneration: Int { context.sessionGeneration }

    /// The adb device list (`devicesSource`).
    private var devices: [AndroidDevice] { devicesSource() }

    /// The AVD `device` runs (`avdNameLookup`).
    private func avdName(of device: AndroidDevice) async -> String? {
        await avdNameLookup(device)
    }

    /// The Controls panel's state, which the battery and fold workers write.
    private var controls: DeviceControlsState {
        get { controlsPanel.controls }
        set { controlsPanel.controls = newValue }
    }

    private func refreshControls() async {
        await controlsPanel.refreshControls()
    }

    private var errorMessage: String? {
        get { status.errorMessage }
        set { status.errorMessage = newValue }
    }

    private func flashStatus(_ message: String) {
        status.flash(message)
    }
}

extension EmulatorHardwareController: FoldControlDriving {
    var hingeAngle: Double? { controls.hingeAngle }
}
