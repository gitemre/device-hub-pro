import Foundation
import DeviceHubProKit

/// The Status bar writes. Each runs as the controller's next write (one at a
/// time, holding the write fence), updates what Device Hub Pro sent at once, reads
/// the effect back through the Kit — which throws when SystemUI did not take
/// it — and rolls `sent` back with the error shown when it did not.
extension StatusBarDemoController {
    // MARK: - Demo mode

    /// On: records the keys as found, opens the gate unless SystemUI reports
    /// it open, and enters with the Screenshot preset. Off: ends demo mode
    /// and puts the keys back (the ones recorded, else as they are now, so a
    /// gate found off goes back to off).
    func setDemoMode(_ enabled: Bool) async {
        guard let session = currentSession else { return }
        let avdName = mirroredAvdName
        await performWrite { controller, adbClient in
            guard controller.isCurrent(session) else { return false }
            if enabled {
                return await controller.enter(
                    .screenshot,
                    message: StatusBarRowText.enteredMessage(.screenshot),
                    session: session,
                    avdName: avdName,
                    adbClient: adbClient
                )
            }
            return await controller.exit(session: session, avdName: avdName, adbClient: adbClient)
        }
    }

    // MARK: - Steps

    /// Demo mode on with `preset`, from a fresh probe: records the keys,
    /// opens the gate unless SystemUI reports it open, then the tuner key and
    /// the commands. A refused gate changed nothing, so its record goes; a
    /// gate or demo mode SystemUI did not take is put back at once. Entering
    /// from off makes a record whose demo mode ended elsewhere Device Hub Pro's
    /// own again, before the enter script runs: whatever its read-back says
    /// (SystemUI silent, or entering late), the demo mode that script may
    /// leave is Device Hub Pro's, which the undo or the disconnect ends.
    private func enter(
        _ preset: StatusBarPreset,
        message: String,
        session: DeviceSession,
        avdName: String?,
        adbClient: AdbClient
    ) async -> Bool {
        let previous = sent
        var key: String?
        var recordedNow = false
        // The record's demo mode had ended elsewhere before this enter: the
        // undo realigns the battery that demo mode may have left.
        var endedBeforeEnter = false
        let expectsController = hasReportedController
        do {
            let current = try await adbClient.statusBarDemo(
                serial: session.serial,
                expectsController: expectsController,
                settle: settle
            )
            if isCurrent(session) { apply(current) }
            let deviceKey = await deviceKey(for: session, avdName: avdName)
            key = deviceKey
            recordedNow = record(
                StatusBarDemoOriginal(allowedRaw: current.allowedRaw, onRaw: current.onRaw, wasInDemoMode: current.isInDemoMode),
                key: deviceKey
            )
            let commands = preset.commands(apiLevel: current.apiLevel, handlesNotifications: current.handlesNotifications)
            if isCurrent(session) {
                var optimistic = current.isInDemoMode ? sent : StatusBarDemoSent.entered([])
                optimistic.record(commands)
                optimistic.preset = preset
                sent = optimistic
            }
            let after: StatusBarDemoSnapshot
            if current.isInDemoMode {
                // The switch was behind: SystemUI is in demo mode already.
                after = try await adbClient.sendStatusBarDemo(
                    serial: session.serial,
                    commands: commands,
                    expectsController: expectsController,
                    settle: settle
                )
            } else {
                if !recordedNow { noteGateClosed(current, key: deviceKey) }
                if !(current.controller?.isAllowed ?? current.isAllowedKey) {
                    try await adbClient.allowStatusBarDemo(
                        serial: session.serial,
                        expectsController: expectsController,
                        settle: settle
                    )
                }
                endedBeforeEnter = records[deviceKey]?.demoModeEnded ?? false
                markDemoModeOwned(key: deviceKey)
                after = try await adbClient.enterStatusBarDemo(
                    serial: session.serial,
                    commands: commands,
                    expectsController: expectsController,
                    settle: settle
                )
            }
            guard isCurrent(session) else { return true }
            apply(after)
            status.flash(message)
            return true
        } catch {
            await undoFailedEnter(
                error,
                key: key,
                recordedNow: recordedNow,
                realignBattery: endedBeforeEnter,
                serial: session.serial,
                expectsController: expectsController,
                adbClient: adbClient
            )
            guard isCurrent(session) else { return false }
            sent = previous
            if !error.isCancellation { status.errorMessage = "\(error)" }
            return false
        }
    }

    /// A gate or demo mode SystemUI did not take is put back now; a silent
    /// SystemUI or a battery it did not show leaves Device Hub Pro's own record
    /// for the disconnect.
    private func undoFailedEnter(
        _ error: any Error,
        key: String?,
        recordedNow: Bool,
        realignBattery: Bool,
        serial: String,
        expectsController: Bool,
        adbClient: AdbClient
    ) async {
        guard let key, let error = error as? StatusBarDemoError else { return }
        switch error {
        case .settingRefused:
            if recordedNow { forgetRecord(key: key) }
        case .notAllowed, .notEntered:
            // Best effort: put the keys back now.
            guard let record = records[key], !record.isSomeoneElses else { return }
            _ = await putBack(
                record,
                key: key,
                serial: serial,
                adbClient: adbClient,
                settle: settle,
                expectsController: expectsController,
                realignBattery: realignBattery
            )
        default:
            break
        }
    }

    /// Ends demo mode and puts the keys back (`AdbClient.exitStatusBarDemo`):
    /// the recorded keys, else — demo mode Device Hub Pro did not start, or its
    /// record was someone else's — the keys as they are now, recorded before
    /// the exit so a failed one is tried again at disconnect.
    private func exit(session: DeviceSession, avdName: String?, adbClient: AdbClient) async -> Bool {
        let expectsController = hasReportedController
        let key = await deviceKey(for: session, avdName: avdName)
        do {
            if records[key].map({ $0.isSomeoneElses }) ?? true {
                // Not Device Hub Pro's: the keys stay as they are now.
                let current = try await adbClient.statusBarDemo(
                    serial: session.serial,
                    expectsController: expectsController,
                    settle: settle
                )
                // Replaces a record of someone else's demo mode.
                record(
                    StatusBarDemoOriginal(allowedRaw: current.allowedRaw, onRaw: current.onRaw, wasInDemoMode: false),
                    key: key
                )
            }
            guard let record = records[key] else { return false }
            let after = try await adbClient.exitStatusBarDemo(
                serial: session.serial,
                original: record.original,
                realignBattery: record.demoModeEnded,
                expectsController: expectsController,
                settle: settle
            )
            if records[key]?.original == record.original { forgetRecord(key: key) }
            guard isCurrent(session) else { return true }
            apply(after)
            endSent()
            status.flash(after.isBatteryStale ? StatusBarRowText.staleBatteryMessage : StatusBarRowText.exitedMessage)
            return true
        } catch {
            guard isCurrent(session) else { return false }
            status.errorMessage = StatusBarRowText.exitFailedMessage(error, keepsRecord: records[key] != nil)
            return false
        }
    }

    // MARK: - Apply to Selected

    /// Apply to Selected's Clean Status Bar (`enabled`: demo mode with the
    /// Screenshot preset) or Clear Status Bar on `serial`, any adb device:
    /// the enter and exit above, without a session. The keys are recorded
    /// under the key the panel uses for that device (`batchKey(serial:)`),
    /// so Clear Status Bar, or the put-back of the device's next mirrored
    /// session, finds them. The mirrored device's write queues behind the
    /// panel's own and its rows follow; the other devices' run at once.
    /// Throws when SystemUI did not take it.
    func setDemoModeForBatch(_ enabled: Bool, serial: String) async throws {
        guard let adbClient else { throw BatchPerformerError("The Android tools weren't found.") }
        let key = await batchKey(serial: serial)
        guard let session = currentSession, session.serial == serial else {
            try await batchWrite(enabled, serial: serial, key: key, session: nil, adbClient: adbClient)
            return
        }
        let failure = BatchWriteFailure()
        let written = await performWrite { controller, adbClient in
            do {
                try await controller.batchWrite(enabled, serial: serial, key: key, session: session, adbClient: adbClient)
                return true
            } catch {
                failure.error = error
                return false
            }
        }
        if let error = failure.error { throw error }
        // The queue dropped the write (the controller went away, or the
        // mirror changed first): nothing was sent.
        guard written else { throw BatchPerformerError("The status bar write did not run.") }
    }

    /// The record key of `serial`'s device, as `resolvedDeviceKey` finds it:
    /// an emulator's AVD name, else (a phone, or a console that did not
    /// answer) the serial.
    func batchKey(serial: String) async -> String {
        guard DeviceConditionsController.isEmulatorSerial(serial),
              let adbClient,
              let name = (try? await adbClient.avdName(serial: serial)) ?? nil
        else { return serial }
        return name
    }

    private func batchWrite(
        _ enabled: Bool,
        serial: String,
        key: String,
        session: DeviceSession?,
        adbClient: AdbClient
    ) async throws {
        let settle = self.settle
        guard enabled else {
            if records[key].map({ $0.isSomeoneElses }) ?? true {
                // Not Device Hub Pro's: the keys stay as they are now.
                let current = try await adbClient.statusBarDemo(serial: serial)
                record(
                    StatusBarDemoOriginal(allowedRaw: current.allowedRaw, onRaw: current.onRaw, wasInDemoMode: false),
                    key: key
                )
            }
            guard let record = records[key] else { return }
            let after = try await adbClient.exitStatusBarDemo(
                serial: serial,
                original: record.original,
                realignBattery: record.demoModeEnded,
                settle: settle
            )
            if records[key]?.original == record.original { forgetRecord(key: key) }
            if let session, isCurrent(session) {
                apply(after)
                endSent()
            }
            return
        }
        let current = try await adbClient.statusBarDemo(serial: serial)
        let recordedNow = record(
            StatusBarDemoOriginal(allowedRaw: current.allowedRaw, onRaw: current.onRaw, wasInDemoMode: current.isInDemoMode),
            key: key
        )
        let commands = StatusBarPreset.screenshot.commands(
            apiLevel: current.apiLevel,
            handlesNotifications: current.handlesNotifications
        )
        var endedBeforeEnter = false
        do {
            let after: StatusBarDemoSnapshot
            if current.isInDemoMode {
                after = try await adbClient.sendStatusBarDemo(serial: serial, commands: commands, settle: settle)
            } else {
                if !recordedNow { noteGateClosed(current, key: key) }
                if !(current.controller?.isAllowed ?? current.isAllowedKey) {
                    try await adbClient.allowStatusBarDemo(serial: serial, settle: settle)
                }
                endedBeforeEnter = records[key]?.demoModeEnded ?? false
                markDemoModeOwned(key: key)
                after = try await adbClient.enterStatusBarDemo(serial: serial, commands: commands, settle: settle)
            }
            if let session, isCurrent(session) {
                var shown = current.isInDemoMode ? sent : StatusBarDemoSent.entered([])
                shown.record(commands)
                shown.preset = .screenshot
                sent = shown
                apply(after)
            }
        } catch {
            await undoFailedEnter(
                error,
                key: key,
                recordedNow: recordedNow,
                realignBattery: endedBeforeEnter,
                serial: serial,
                expectsController: false,
                adbClient: adbClient
            )
            throw error
        }
    }
}

/// What a queued Apply to Selected write threw, handed out of the queue.
@MainActor
private final class BatchWriteFailure {
    var error: (any Error)?
}
