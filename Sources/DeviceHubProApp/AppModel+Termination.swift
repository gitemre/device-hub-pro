import DeviceHubProKit
import Foundation

/// Quit cleanup: the app delegate's `applicationShouldTerminate` answers
/// `.terminateLater` and runs `prepareForTermination()`; the `willTerminate`
/// observer keeps `terminationBackstop()` for a termination that skipped it.
extension AppModel {
    /// What quitting now would interrupt, in plain words; nil when nothing
    /// long-running is under way.
    var quitInterruptionNotice: String? {
        Self.quitInterruptionNotice(
            jobPhases: avdCreation.jobs.map(\.phase),
            directDownload: avdCreation.directDownloadPackage != nil,
            setupRunning: androidSetup.isRunning
        )
    }

    /// The sentence for a quit during a download, an emulator creation or the
    /// Android setup (failed jobs are over, so they do not count).
    static func quitInterruptionNotice(
        jobPhases: [AvdCreationJob.Phase],
        directDownload: Bool,
        setupRunning: Bool
    ) -> String? {
        var lines: [String] = []
        if setupRunning {
            lines.append("The Android tools are still being installed. Quitting stops the install; what was already downloaded is kept.")
        }
        let active = jobPhases.filter { if case .failed = $0 { return false } else { return true } }
        let downloading = directDownload || active.contains { $0 == .waiting || $0 == .downloading }
        if downloading {
            lines.append("A system image is still downloading. If you quit now, the download is discarded and starts over next time.")
        }
        if active.contains(where: { $0 == .waitingToCreate || $0 == .creating }) {
            lines.append("An emulator is still being created. Quitting now may leave it unfinished.")
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// The quit's bound: the conditions' put-back alone may take
    /// `DeviceConditionsController.cleanupWaitLimit`.
    static let quitCleanupLimit: Duration = DeviceConditionsController.cleanupWaitLimit + .seconds(3)

    /// Everything the app started for its devices ends before it exits, in a
    /// bounded time, in every workspace: a running recording is finalized
    /// and saved (to the auto-save directory, without asking), logcat stops,
    /// the mirror is torn down — a physical session's sockets and device
    /// server, and a live simulator session's queues, waited for —, the
    /// emulator's control connection closes, and the watcher's
    /// `track-devices` child is stopped, as are the simulator watcher and
    /// the simulators' readiness waits (their `bootstatus` children).
    /// The simulators Device Hub Pro started are shut down when this quit's choice
    /// says so (`SimulatorLifecycleController.quitChoice`: the app menu's
    /// Option alternate, else Settings' default), after their canvas is
    /// torn down; a simulator Device Hub Pro did not boot never is.
    ///
    /// Every workspace's teardown begins before any is waited for
    /// (`DeviceWorkspace.beginQuitTeardown`): their transports' blocking
    /// stops run side by side off the main actor and are awaited together,
    /// so several sessions cost the slowest one, not their sum.
    /// Whatever is still pending after `timeout` is abandoned, so quitting
    /// never hangs.
    func prepareForTermination(timeout: Duration = AppModel.quitCleanupLimit) async {
        services.clipboardPoll.stop()
        // The soft keyboards' put-back is independent of every teardown
        // below, so it starts first and runs beside them.
        let keyboardRestore = Task { @MainActor [softKeyboard] in await softKeyboard?.restoreAll() }
        let workspaces = registry.workspaces
        let ports = workspaces.compactMap(\.context.port)
        let quitChoice = simulatorLifecycle.quitChoice(shutsDownByDefault: preferences.shutsDownStartedSimulatorsOnQuit)
        let startedSimulators = quitChoice == .shutDownStarted ? simulatorLifecycle.bootedByDeviceHubPro : []
        let simctl = simulators.simctl
        for workspace in workspaces {
            workspace.logcat.stopLogcat()
        }
        // Which simulator each workspace shows, read before its teardown
        // clears the context: a simulator's shutdown waits for its own
        // canvas's stop only, never another window's (a phone's stop may
        // take its full 2 s).
        var canvasStops: [String: Task<Void, Never>] = [:]
        var stops: [Task<Void, Never>] = []
        for workspace in workspaces {
            let shown = workspace.context.device.flatMap { $0.platform == .apple ? $0.id : nil }
            guard let stop = workspace.beginQuitTeardown() else { continue }
            stops.append(stop)
            if let shown { canvasStops[shown] = stop }
        }
        inventory.stopDeviceLifecycle()
        stopSimulatorProvider()
        // The physical-device poll ends with the app (idempotent).
        physicalInventory.stop()
        // Beside the rest, each once its canvas is torn down: a shutdown
        // takes about 3.5 s.
        let shutdowns = Task {
            guard let simctl, !startedSimulators.isEmpty else { return }
            await withTaskGroup(of: Void.self) { group in
                for udid in startedSimulators {
                    let canvasStop = canvasStops[udid]
                    group.addTask {
                        await canvasStop?.value
                        _ = await SimulatorLifecycleController.shutDownForQuit([udid], simctl: simctl)
                    }
                }
            }
        }
        // The conditions' put-back (meter, Wi-Fi and mobile data, tc, unroot)
        // can take `cleanupWaitLimit`; every workspace's runs side by side
        // with the teardown instead of after it.
        let conditionsCleanups = workspaces.map { workspace in
            Task { @MainActor in await workspace.conditions.waitForPendingCleanup() }
        }
        await Self.awaitBounded(timeout) { [self] in
            for cleanup in conditionsCleanups {
                await cleanup.value
            }
            await keyboardRestore.value
            for port in ports {
                await EmulatorControls.closeConnections(port: port)
            }
            for stop in stops {
                await stop.value
            }
            await recordingFinalizer.waitForRecordingsToFinish()
            await shutdowns.value
        }
    }

    /// The synchronous part of the cleanup, for `willTerminate`: nothing
    /// asynchronous runs after it, so it only stops what stops at once.
    /// Idempotent — after `prepareForTermination` there is nothing left.
    func terminationBackstop() {
        for workspace in registry.workspaces {
            if workspace.mirror.session != nil {
                workspace.tearDownMirror(cause: .quit)
            }
            workspace.logcat.stopLogcat()
        }
        inventory.stopDeviceLifecycle()
        stopSimulatorProvider()
        // The physical-device poll ends with the app (idempotent).
        physicalInventory.stop()
    }

    /// Stops the simulator watcher and every readiness wait. Idempotent.
    func stopSimulatorProvider() {
        simulators.stop()
        simulatorLifecycle.stop()
    }

    /// Returns when `work` finishes or `timeout` passes, whichever is first;
    /// the work itself is not waited for beyond that.
    static func awaitBounded(
        _ timeout: Duration,
        _ work: @escaping @MainActor () async -> Void
    ) async {
        let gate = BoundedWaitGate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.continuation = continuation
            Task { @MainActor in
                await work()
                gate.open()
            }
            Task { @MainActor in
                // Best effort: the sleep fails only on cancellation, and the
                // gate opens either way.
                try? await Task.sleep(for: timeout)
                gate.open()
            }
        }
    }
}

/// Resumes its continuation once, whichever side opens it first.
@MainActor
private final class BoundedWaitGate {
    var continuation: CheckedContinuation<Void, Never>?

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
