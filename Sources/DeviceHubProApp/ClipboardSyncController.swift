import Foundation
import Observation
import DeviceHubProKit

/// Clipboard sync between the Mac and the active device, on demand (Send,
/// Pull) and automatically while Settings' auto-sync is on: over gRPC to an
/// emulator, over scrcpy's control channel to a physical device, through
/// `simctl pbcopy` / `pbpaste` to a simulator.
///
/// A simulator's auto-sync watches its pasteboard instead of polling it:
/// `simctl spawn <UDID> notifyutil -w com.apple.pasteboard.notify.changed`
/// runs while the sync does and prints a line per change, and only then is
/// the pasteboard read (one `pbpaste`). A poll would cost a simctl spawn per
/// tick (`pbpaste` and `pbinfo` each took about 0.16 s wall and 0.11 s CPU,
/// so 1.2 s ticks come to about 10 % of a core), and `pbinfo` carries no
/// change count to poll cheaply; `simctl pbsync` copies once and has no
/// follow mode. The Mac side is polled as for the other devices. The Mac
/// pasteboard is written only by a Pull or while the auto-sync setting is
/// on.
///
/// One long-lived instance, owned by `AppModel` as `clipboard`. It reads the
/// device from the shared `ActiveDeviceContext`; the physical session is
/// passed in by the model, which owns the mirror session. The echo state and
/// the last pushed device clipboard survive a device switch, so re-enabling
/// sync does not echo; `detach` ends only the loop.
@MainActor
@Observable
final class ClipboardSyncController {
    private let context: ActiveDeviceContext
    private let preferences: AppPreferences
    private let status: StatusCenter
    /// The Mac side: the environment's pasteboard (`NSPasteboard.general` in
    /// the app).
    private let pasteboard: any MacPasteboard
    /// How often auto-sync polls: the emulator's clipboard and the Mac
    /// pasteboard have no change notification.
    private let pollInterval: Duration

    init(
        context: ActiveDeviceContext,
        preferences: AppPreferences,
        status: StatusCenter,
        pasteboard: any MacPasteboard,
        pollInterval: Duration = .milliseconds(1200)
    ) {
        self.context = context
        self.preferences = preferences
        self.status = status
        self.pasteboard = pasteboard
        self.pollInterval = pollInterval
    }

    /// simctl on the listed device set, for a simulator's pasteboard; nil
    /// without Apple tooling. Wired by its owner.
    @ObservationIgnored var simctlSource: @MainActor () -> SimctlClient? = { nil }

    /// Whether clipboard auto-sync is on (the app-level poll reads the Mac
    /// pasteboard only while some workspace has it on).
    var isAutoSyncOn: Bool { preferences.clipboardAutoSyncEnabled }
    /// Whether the stage shows: the device → Mac poll over gRPC pauses while
    /// it does not. Wired by its owner.
    @ObservationIgnored var isStageVisible: @MainActor () -> Bool = { true }

    private var clipboardSyncTask: Task<Void, Never>?
    /// What the sync last saw on, or wrote to, the Mac and the device, so a
    /// text crosses once and is never echoed back.
    private var echo = ClipboardEchoState()
    /// The last clipboard a physical device pushed. scrcpy's control channel
    /// reports the device clipboard whenever it changes and has no read
    /// request, so Pull answers from this.
    private var physicalDeviceClipboard: (serial: String, text: String)?

    /// What auto-sync's Mac → device direction currently pushes to, if
    /// anything: set by `attach`, read by `applyMacPasteboardPoll` (the
    /// app-level Mac-pasteboard poll's fan-out).
    private enum AttachTarget {
        case emulator(port: Int)
        case physical(any PhysicalSessionControlling)
        case simulator(udid: String, simctl: SimctlClient)
    }
    private var attachedTarget: AttachTarget?

    func setAutoSync(_ enabled: Bool, physical: (any PhysicalSessionControlling)?) {
        preferences.setClipboardAutoSync(enabled)
        if enabled {
            attach(physical: physical)
        } else {
            detach()
        }
    }

    /// The mirrored simulator's UDID; nil for an adb device or none.
    private var simulatorUDID: String? {
        guard let device = context.simulatorDevice else { return nil }
        return device.id
    }

    /// Sends the Mac clipboard to the device on demand: over gRPC to an
    /// emulator, over scrcpy's control channel to a physical device,
    /// `simctl pbcopy` to a simulator.
    func send(physical: (any PhysicalSessionControlling)?) async {
        if let udid = simulatorUDID {
            await sendToSimulator(udid)
            return
        }
        guard context.port != nil || physical != nil else {
            status.errorMessage = "Connect a device before syncing the clipboard."
            return
        }
        guard let text = pasteboard.string(), !text.isEmpty else {
            status.flash("The Mac clipboard is empty")
            return
        }
        if let port = context.port {
            guard await EmulatorControls.setClipboard(port: port, text: text) else {
                status.errorMessage = "The emulator rejected the clipboard update."
                return
            }
        } else if let physical {
            guard physical.usesControlSocket else {
                status.errorMessage = "The clipboard travels over the mirror's control channel, which is not connected for this device."
                return
            }
            physical.setDeviceClipboard(text, paste: false)
        }
        echo.noteSynced(text)
        status.flash("Clipboard sent to the device")
    }

    /// Copies the device clipboard to the Mac on demand. A physical device's
    /// clipboard is the one it last pushed (see `physicalDeviceClipboard`).
    func pull(physical: (any PhysicalSessionControlling)?) async {
        if let udid = simulatorUDID {
            await pullFromSimulator(udid)
            return
        }
        let text: String
        if let port = context.port {
            guard let read = await EmulatorControls.clipboard(port: port) else {
                status.errorMessage = "Could not read the device clipboard."
                return
            }
            text = read
        } else if let physical {
            guard let pushed = physicalDeviceClipboard, pushed.serial == physical.serial else {
                status.errorMessage = "The device has not shared its clipboard yet. Copy something on the device, then try again."
                return
            }
            text = pushed.text
        } else {
            status.errorMessage = "Connect a device before syncing the clipboard."
            return
        }
        pasteboard.setString(text)
        echo.noteSynced(text)
        status.flash("Clipboard pulled from the device")
    }

    /// Device → Mac for a physical device: scrcpy pushes the device clipboard
    /// on every change (the session hands it here on the main queue). With
    /// auto-sync on it replaces the Mac clipboard; either way Pull can use it.
    func receive(_ text: String, serial: String) {
        guard serial == context.serial else { return }
        physicalDeviceClipboard = (serial, text)
        guard echo.acceptDeviceText(text) else { return }
        guard preferences.clipboardAutoSyncEnabled, echo.macNeeds(text) else { return }
        pasteboard.setString(text)
        echo.noteMacWritten(text)
    }

    /// Starts auto-sync on the device the context names, replacing a running
    /// loop: the emulator's clipboard over gRPC when there is a port, the
    /// Mac side for `physical` otherwise. Nothing starts while auto-sync is
    /// off.
    func attach(physical: (any PhysicalSessionControlling)?) {
        clipboardSyncTask?.cancel()
        clipboardSyncTask = nil
        attachedTarget = nil
        guard preferences.clipboardAutoSyncEnabled else { return }

        if let port = context.port {
            attachedTarget = .emulator(port: port)
            clipboardSyncTask = Task { [weak self, pollInterval] in
                // Seed both sides so enabling sync does not produce an instant
                // overwrite in either direction.
                await self?.seedClipboardState(port: port)
                while !Task.isCancelled {
                    // Device → Mac only: the Mac → device direction is
                    // driven by the app-level Mac-pasteboard poll's fan-out
                    // (`applyMacPasteboardPoll`), not read here.
                    if self?.isStageVisible() ?? true {
                        await self?.syncDeviceToMacOnce(port: port)
                    }
                    // Best effort: the sleep fails only on cancellation, checked by the loop.
                    try? await Task.sleep(for: pollInterval)
                }
            }
        } else if let physical {
            // Device → Mac arrives through `receive`, pushed by the
            // session; Mac → device is driven by the app-level poll's
            // fan-out (`applyMacPasteboardPoll`), so no loop is needed here.
            attachedTarget = .physical(physical)
            echo.seedMac(pasteboard.string())
        } else if let udid = simulatorUDID, let simctl = simctlSource() {
            attachedTarget = .simulator(udid: udid, simctl: simctl)
            echo.seedMac(pasteboard.string())
            clipboardSyncTask = Task { [weak self] in
                await self?.watchSimulatorPasteboard(udid, simctl: simctl)
            }
        }
    }

    /// Pushes `text` to whichever device `attach` last targeted, when
    /// auto-sync is on and the text is new: the receiving
    /// end of the app's one Mac-pasteboard poll (`AppServices.clipboardPoll`),
    /// fanned out to every workspace's controller. A workspace with sync
    /// off, or with nothing attached, does nothing — same as before, just
    /// driven from outside instead of the controller's own timer.
    func applyMacPasteboardPoll(_ text: String?) {
        guard preferences.clipboardAutoSyncEnabled, let attachedTarget, let text, !text.isEmpty else { return }
        switch attachedTarget {
        case .emulator(let port):
            guard echo.acceptMacText(text), echo.deviceNeeds(text) else { return }
            // The text counts as written before the call completes, so its
            // own report back through a later poll reads as an echo.
            echo.noteDeviceWritten(text)
            Task {
                // Best effort: the next poll sends it again if this fails.
                _ = await EmulatorControls.setClipboard(port: port, text: text)
            }
        case .physical(let physical):
            // Waits for the control socket, same as before: while it is
            // down the echo state is left untouched, so the text is still
            // "new" once the socket comes back — `acceptMacText` (which
            // marks it seen) is not called until this guard passes.
            guard physical.usesControlSocket, echo.acceptMacText(text), echo.deviceNeeds(text) else { return }
            echo.noteDeviceWritten(text)
            physical.setDeviceClipboard(text, paste: false)
        case .simulator(let udid, let simctl):
            guard echo.acceptMacText(text), echo.deviceNeeds(text) else { return }
            // The text counts as written before the copy, so its own
            // change notification reads back as an echo.
            echo.noteDeviceWritten(text)
            Task {
                // Best effort: the next poll sends it again if this fails.
                try? await simctl.setPasteboard(udid: udid, text: text)
            }
        }
    }

    // MARK: - Physical iPhones and iPads

    /// Sends the Mac clipboard to the physical iPhone the Controls panel is
    /// attached to (`devicectl device pasteboard copy`), on demand only.
    func sendToPhysicalApple(_ controls: AppleControlsController) async {
        guard let text = pasteboard.string(), !text.isEmpty else {
            status.flash("The Mac clipboard is empty")
            return
        }
        // The controller says why on failure.
        guard await controls.sendPasteboard(text) else { return }
        echo.noteSynced(text)
        status.flash("Clipboard sent to the device")
    }

    /// Copies the physical iPhone's pasteboard text to the Mac
    /// (`devicectl device pasteboard paste`), on demand only.
    func pullFromPhysicalApple(_ controls: AppleControlsController) async {
        // The controller says why on failure.
        guard let text = await controls.pullPasteboard() else { return }
        guard !text.isEmpty else {
            status.flash("The phone's clipboard has no text")
            return
        }
        pasteboard.setString(text)
        echo.noteSynced(text)
        status.flash("Clipboard pulled from the device")
    }

    // MARK: - Simulators

    private func sendToSimulator(_ udid: String) async {
        guard let simctl = simctlSource() else {
            status.errorMessage = "Connect a device before syncing the clipboard."
            return
        }
        guard let text = pasteboard.string(), !text.isEmpty else {
            status.flash("The Mac clipboard is empty")
            return
        }
        do {
            try await simctl.setPasteboard(udid: udid, text: text)
        } catch {
            status.errorMessage = "Could not send the clipboard: \(Self.reason(error))"
            return
        }
        echo.noteSynced(text)
        status.flash("Clipboard sent to the device")
    }

    /// Pull from a simulator: an empty pasteboard leaves the Mac's as it is.
    private func pullFromSimulator(_ udid: String) async {
        guard let simctl = simctlSource() else {
            status.errorMessage = "Connect a device before syncing the clipboard."
            return
        }
        let text: String
        do {
            text = try await simctl.pasteboard(udid: udid)
        } catch {
            status.errorMessage = "Could not read the device clipboard: \(Self.reason(error))"
            return
        }
        guard !text.isEmpty else {
            status.flash("The device clipboard is empty")
            return
        }
        pasteboard.setString(text)
        echo.noteSynced(text)
        status.flash("Clipboard pulled from the device")
    }

    /// A simulator's device → Mac auto-sync until cancelled: its
    /// pasteboard's change notifications (coalesced: a burst reads it once)
    /// bring its text to the Mac. The simulator side is seeded first, so
    /// turning sync on does not overwrite it. Mac → device is driven by the
    /// app-level Mac-pasteboard poll's fan-out (`applyMacPasteboardPoll`),
    /// not polled here.
    private func watchSimulatorPasteboard(_ udid: String, simctl: SimctlClient) async {
        // Best effort: an unreadable pasteboard seeds as unknown.
        echo.seedDevice(try? await simctl.pasteboard(udid: udid))
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let watch = Task.detached {
            // Ends with the sync (cancelled), or when the simulator shuts down.
            _ = try? await simctl.watchDarwinNotification(
                udid: udid,
                name: SimctlClient.pasteboardChangedNotification
            ) {
                continuation.yield()
            }
            continuation.finish()
        }
        let pullChanges = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await self?.pullSimulatorChange(udid, simctl: simctl)
            }
        }
        // Waits until cancelled (`detach`): the work happens in `watch` and
        // `pullChanges` above.
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        watch.cancel()
        pullChanges.cancel()
        continuation.finish()
    }

    /// Device → Mac for a simulator, after its pasteboard changed.
    private func pullSimulatorChange(_ udid: String, simctl: SimctlClient) async {
        // Best effort: the next change reads it again.
        guard let text = try? await simctl.pasteboard(udid: udid), !text.isEmpty,
              !Task.isCancelled,
              echo.acceptDeviceText(text),
              preferences.clipboardAutoSyncEnabled,
              echo.macNeeds(text)
        else { return }
        pasteboard.setString(text)
        echo.noteMacWritten(text)
    }

    private static func reason(_ error: any Error) -> String {
        (error as? SimctlFailure)?.message ?? "\(error)"
    }

    /// Ends the auto-sync loop. The echo state and `physicalDeviceClipboard`
    /// stay, so re-enabling sync on the same texts does not echo. Clears
    /// `attachedTarget`, so a Mac-pasteboard poll fan-out already in flight
    /// pushes nothing more.
    func detach() {
        clipboardSyncTask?.cancel()
        clipboardSyncTask = nil
        attachedTarget = nil
    }

    private func seedClipboardState(port: Int) async {
        echo.seedMac(pasteboard.string())
        let deviceText = await EmulatorControls.clipboard(port: port)
        echo.seedDevice(deviceText)
    }

    /// Device → Mac for an emulator, on this controller's own cadence (each
    /// device differs, so this stays per workspace). Mac → device is driven
    /// by the app-level Mac-pasteboard poll's fan-out
    /// (`applyMacPasteboardPoll`), not read here.
    private func syncDeviceToMacOnce(port: Int) async {
        guard let deviceText = await EmulatorControls.clipboard(port: port),
              echo.acceptDeviceText(deviceText),
              echo.macNeeds(deviceText)
        else { return }
        pasteboard.setString(deviceText)
        echo.noteMacWritten(deviceText)
    }
}
