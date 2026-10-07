import Foundation
import DeviceHubProKit

/// The Controls panel's writes: the 13 settings writes (the network
/// toggles, Data Saver, the developer toggles, Appearance, Text Size,
/// Reduce Motion, Increase Contrast, Show Borders and TalkBack) and the
/// Sound knob's live volume stepping and commit. Each write shows its
/// value at once, holds the write fence while it runs, and rolls back and
/// raises the error when adb fails; the reconciles and read-backs it ends
/// with are in `DeviceControlsController.swift`.
extension DeviceControlsController {
    func toggleBatterySaver() async {
        guard let adbClient, let serial = activeSerial else { return }
        let current = stillShowing(serial)
        let previous = controls.batterySaverEnabled
        let wanted = !(previous ?? false)
        beginSettingsWrite()
        defer { endSettingsWrite() }
        controls.batterySaverEnabled = wanted
        do {
            try await adbClient.setBatterySaver(serial: serial, enabled: wanted)
            await reconcileGlobalSettings(serial: serial) {
                controls.batterySaverEnabled == wanted
            }
        } catch {
            if current() { controls.batterySaverEnabled = previous }
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    func toggleAirplaneMode() async {
        guard let adbClient, let serial = activeSerial else { return }
        let current = stillShowing(serial)
        let previous = controls.airplaneModeEnabled
        let wanted = !(previous ?? false)
        beginSettingsWrite()
        defer { endSettingsWrite() }
        controls.airplaneModeEnabled = wanted
        do {
            try await adbClient.setAirplaneMode(serial: serial, enabled: wanted)
            await reconcileGlobalSettings(serial: serial) {
                controls.airplaneModeEnabled == wanted
            }
        } catch {
            if current() { controls.airplaneModeEnabled = previous }
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    func toggleWifi() async {
        guard let adbClient, let serial = activeSerial else { return }
        let current = stillShowing(serial)
        let previous = controls.wifiEnabled
        let wanted = !(previous ?? false)
        beginSettingsWrite()
        defer { endSettingsWrite() }
        controls.wifiEnabled = wanted
        do {
            try await adbClient.setWifi(serial: serial, enabled: wanted)
            await reconcileGlobalSettings(serial: serial) {
                controls.wifiEnabled == wanted
            }
        } catch {
            if current() { controls.wifiEnabled = previous }
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    func toggleBluetooth() async {
        guard let adbClient, let serial = activeSerial else { return }
        let current = stillShowing(serial)
        let previous = controls.bluetoothEnabled
        let wanted = !(previous ?? false)
        beginSettingsWrite()
        defer { endSettingsWrite() }
        controls.bluetoothEnabled = wanted
        do {
            try await adbClient.setBluetooth(serial: serial, enabled: wanted)
            await reconcileGlobalSettings(serial: serial) {
                controls.bluetoothEnabled == wanted
            }
        } catch {
            if current() { controls.bluetoothEnabled = previous }
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    func toggleMobileData() async {
        guard let adbClient, let serial = activeSerial else { return }
        let current = stillShowing(serial)
        let previous = controls.mobileDataEnabled
        let wanted = !(previous ?? false)
        beginSettingsWrite()
        defer { endSettingsWrite() }
        controls.mobileDataEnabled = wanted
        do {
            try await adbClient.setMobileData(serial: serial, enabled: wanted)
            await reconcileGlobalSettings(serial: serial) {
                controls.mobileDataEnabled == wanted
            }
        } catch {
            if current() { controls.mobileDataEnabled = previous }
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    /// Applies Data Saver (`cmd netpolicy set restrict-background`) and reads
    /// it back.
    func setDataSaver(_ enabled: Bool) async {
        guard let adbClient, let serial = activeSerial else { return }
        let current = stillShowing(serial)
        let previous = controls.dataSaverEnabled
        beginSettingsWrite()
        defer { endSettingsWrite() }
        controls.dataSaverEnabled = enabled
        do {
            try await adbClient.setDataSaver(serial: serial, enabled: enabled)
            flashStatus(enabled ? "Data Saver turned on" : "Data Saver turned off")
            await reconcileDataSaver(serial: serial, expecting: enabled)
        } catch {
            if current() { controls.dataSaverEnabled = previous }
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    /// Applies one developer toggle (`settings put`) and reads its namespace
    /// back.
    func setToggle(_ toggle: DeviceToggle, enabled: Bool) async {
        guard let adbClient, let serial = activeSerial else { return }
        let current = stillShowing(serial)
        let previous = deviceSettings.reading(for: toggle)
        beginSettingsWrite()
        defer { endSettingsWrite() }
        deviceSettings.setReading(enabled ? .on : .off, for: toggle)
        do {
            let outcome = try await adbClient.setToggle(serial: serial, toggle: toggle, enabled: enabled)
            flashStatus(outcome.statusMessage(label: toggle.label, enabled: enabled))
            await reconcileSettings(for: toggle) {
                deviceSettings.reading(for: toggle)?.isOn == enabled
            }
        } catch {
            if current() { deviceSettings.setReading(previous, for: toggle) }
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    /// Applies a new device appearance (`cmd uimode night`) and reads it back.
    func setAppearance(_ mode: AppearanceMode) async {
        guard let adbClient, let serial = activeSerial else { return }
        let current = stillShowing(serial)
        let previous = controls.appearance
        beginSettingsWrite()
        defer { endSettingsWrite() }
        controls.appearance = .mode(mode)
        do {
            try await adbClient.setAppearanceMode(serial: serial, mode)
            flashStatus("Appearance set to \(mode.label)")
            await reconcileAppearance(serial: serial, expecting: mode)
        } catch {
            if current() { controls.appearance = previous }
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    /// Applies one of Android's stock text-size steps and reads it back.
    func setTextSize(_ step: FontScaleStep) async {
        guard let adbClient, let serial = activeSerial else { return }
        let current = stillShowing(serial)
        let previous = deviceSettings.fontScale
        beginSettingsWrite()
        defer { endSettingsWrite() }
        deviceSettings.fontScale = .value(step.rawValue)
        do {
            try await adbClient.setFontScale(serial: serial, scale: step.rawValue)
            flashStatus("Text size set to \(step.label)")
            await reconcileSystemSettings(serial: serial) {
                deviceSettings.fontScale?.value == step.rawValue
            }
        } catch {
            if current() { deviceSettings.fontScale = previous }
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    /// Turns Reduce Motion on/off (all three animation scales) and reads back.
    func setReduceMotion(_ enabled: Bool) async {
        guard let adbClient, let serial = activeSerial else { return }
        let current = stillShowing(serial)
        let previous = deviceSettings.reduceMotion
        beginSettingsWrite()
        defer { endSettingsWrite() }
        deviceSettings.reduceMotion = enabled ? .enabled : .disabled
        do {
            // The scales the user had are read before the first write and
            // given back by Off (not reset to 1.0).
            var remembered = animationScalesBeforeReduceMotion[serial]
            if enabled, remembered == nil, let read = await adbClient.animationScales(serial: serial), !read.allZero {
                remembered = read
                animationScalesBeforeReduceMotion[serial] = read
            }
            try await adbClient.setReduceMotion(serial: serial, enabled: enabled, restoring: enabled ? nil : remembered)
            if !enabled { animationScalesBeforeReduceMotion[serial] = nil }
            flashStatus(enabled ? "Reduce Motion turned on" : "Reduce Motion turned off")
            await reconcileGlobalSettings(serial: serial) {
                deviceSettings.reduceMotion?.isEnabled == enabled
            }
        } catch {
            if current() { deviceSettings.reduceMotion = previous }
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    /// Turns Android's high-text-contrast setting on/off and reads it back.
    func setIncreaseContrast(_ enabled: Bool) async {
        guard let adbClient, let serial = activeSerial else { return }
        let current = stillShowing(serial)
        let previous = deviceSettings.increaseContrast
        beginSettingsWrite()
        defer { endSettingsWrite() }
        deviceSettings.increaseContrast = enabled ? .on : .off
        do {
            try await adbClient.setHighTextContrast(serial: serial, enabled: enabled)
            flashStatus(enabled ? "Increase Contrast turned on" : "Increase Contrast turned off")
            let package = deviceSettings.talkBackPackage
            await reconcileSecureSettings(serial: serial, talkBackPackage: package) {
                deviceSettings.increaseContrast?.isOn == enabled
            }
        } catch {
            if current() { deviceSettings.increaseContrast = previous }
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    /// Turns the layout bounds overlay on/off and reads it back.
    func setShowBorders(_ enabled: Bool) async {
        guard let adbClient, let serial = activeSerial else { return }
        let current = stillShowing(serial)
        let previous = deviceSettings.showBorders
        beginSettingsWrite()
        defer { endSettingsWrite() }
        deviceSettings.showBorders = enabled ? .on : .off
        do {
            try await adbClient.setDebugLayout(serial: serial, enabled: enabled)
            flashStatus(enabled ? "Show Borders turned on" : "Show Borders turned off")
            await reconcileGlobalSettings(serial: serial) {
                deviceSettings.showBorders?.isOn == enabled
            }
        } catch {
            if current() { deviceSettings.showBorders = previous }
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    /// Turns TalkBack on/off (accessibility flag + service entry) and reads
    /// back. Only reachable while the device reports TalkBack installed.
    func setTalkBack(_ enabled: Bool) async {
        guard let adbClient, let serial = activeSerial,
              let packageID = deviceSettings.talkBackPackage
        else { return }
        let current = stillShowing(serial)
        let previous = deviceSettings.voiceOver
        beginSettingsWrite()
        defer { endSettingsWrite() }
        deviceSettings.voiceOver = enabled ? .on : .off
        do {
            try await adbClient.setTalkBack(serial: serial, enabled: enabled, packageID: packageID)
            flashStatus(enabled ? "TalkBack turned on" : "TalkBack turned off")
            await reconcileSecureSettings(serial: serial, talkBackPackage: packageID) {
                deviceSettings.voiceOver?.isOn == enabled
            }
        } catch {
            if current() { deviceSettings.voiceOver = previous }
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    /// Applies a drag's volume change immediately: the Sound knob displays the
    /// new index at once and a worker walks the device to it with the volume
    /// keys (current images ignore the absolute write), so the media volume
    /// follows the knob while it moves. The commit reconciles afterwards.
    func setMediaVolumeLive(_ index: Int) {
        let reading = deviceSettings.mediaVolume
        if volumeAppliedIndex == nil {
            volumeAppliedIndex = reading?.index ?? index
        }
        volumeTarget = index
        deviceSettings.mediaVolume = MediaVolumeReading(
            index: index,
            minimum: reading?.minimum ?? 0,
            maximum: reading?.maximum ?? 15
        )
        guard volumeStepTask == nil, let adbClient, let serial = activeSerial else { return }

        volumeStepTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.activeSerial == serial,
                      let target = self.volumeTarget,
                      let applied = self.volumeAppliedIndex,
                      applied != target
                else { break }
                let key = applied < target ? "24" : "25"
                // Best effort: a lost key press is corrected by the release's
                // reconcile; a phone that denies injected input is not, and
                // ends the drag's stepping with the phone's own message.
                if await self.sendKeyEvent(key, serial: serial, adb: adbClient) == .denied {
                    self.volumeStepTask = nil
                    self.volumeTarget = nil
                    self.volumeAppliedIndex = nil
                    return
                }
                // A cancelled worker's step belongs to a drag that already
                // ended: `stopLiveVolumeStepping` reset the index, and the
                // next drag must seed it afresh.
                guard !Task.isCancelled else { return }
                self.volumeAppliedIndex = applied < target ? applied + 1 : applied - 1
                // Best effort: the sleep fails only on cancellation, checked by the loop.
                try? await Task.sleep(for: .milliseconds(45))
            }
            // Only a worker that ran out on its own still owns the handle; a
            // cancelled one was replaced (or cleared) by its canceller.
            guard !Task.isCancelled else { return }
            self?.volumeStepTask = nil
        }
    }

    /// Ends the live stepping (the release owns the state from here).
    func stopLiveVolumeStepping() {
        volumeStepTask?.cancel()
        volumeStepTask = nil
        volumeTarget = nil
        volumeAppliedIndex = nil
    }

    /// Sets the media stream volume and reads it back. The knob commits to
    /// the new index immediately, then reconciles.
    ///
    /// Current images deny the absolute write — `cmd media_session volume
    /// --stream 3 --set N` answers without error but keeps the old index —
    /// so when the read-back does not match, the row steps to the target with
    /// the volume keys, which still work.
    func setMediaVolume(_ index: Int) async {
        guard let adbClient, let serial = activeSerial else { return }
        let current = stillShowing(serial)
        let previous = deviceSettings.mediaVolume
        beginSettingsWrite()
        stopLiveVolumeStepping()
        defer { endSettingsWrite() }
        deviceSettings.mediaVolume = MediaVolumeReading(
            index: index,
            minimum: previous?.minimum ?? 0,
            maximum: previous?.maximum ?? 15
        )
        do {
            try await adbClient.setMediaVolume(serial: serial, index: index)
            let applied = await settleSetting(
                attempts: 2,
                delay: .milliseconds(120),
                attemptTimeout: Self.settleCallTimeout,
                isCurrent: current,
                attempt: {
                    let readings = await readMediaVolume(serial: serial)
                    guard current() else { return }
                    applyVolume(readings, to: &deviceSettings)
                },
                settled: {
                    deviceSettings.mediaVolume?.index == index
                }
            )
            if !applied, current() {
                // The absolute write was ignored: read where the device is
                // (a drag may already have moved it) and step the remainder.
                let readings = await readMediaVolume(serial: serial)
                guard current() else { return }
                applyVolume(readings, to: &deviceSettings)
                if let atIndex = deviceSettings.mediaVolume?.index, atIndex != index {
                    await stepMediaVolume(serial: serial, from: atIndex, to: index, isCurrent: current)
                }
            }
            flashStatus("Volume set to \(index)")
        } catch {
            if current() { deviceSettings.mediaVolume = previous }
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    /// Moves the media volume to `index` with the volume-key events and reads
    /// the result back. Used when the absolute write was ignored.
    private func stepMediaVolume(serial: String, from current: Int, to index: Int, isCurrent: () -> Bool) async {
        guard let adbClient else { return }
        for event in volumeKeyEvents(from: current, to: index) {
            guard isCurrent() else { return }
            if await sendKeyEvent(event, serial: serial, adb: adbClient) == .denied { return }
            try? await Task.sleep(for: .milliseconds(40))
        }
        let readings = await readMediaVolume(serial: serial)
        guard isCurrent() else { return }
        applyVolume(readings, to: &deviceSettings)
    }

    /// How one injected key event ended.
    enum KeyEventOutcome: Equatable {
        case sent
        case failed
        /// A MIUI or HyperOS phone said no (the SecurityException naming
        /// the inject permission): "USB debugging (Security settings)" is off.
        case denied
    }

    /// Sends `input keyevent <key>`. A Xiaomi phone's denial raises the same
    /// message as the stage's banner (`XiaomiInputBlock.bannerText`), once,
    /// instead of the knob moving with nothing happening.
    func sendKeyEvent(_ key: String, serial: String, adb: AdbClient) async -> KeyEventOutcome {
        let text: String
        var failed = false
        do {
            text = try await adb.shell(serial: serial, ["input", "keyevent", key])
        } catch AdbError.commandFailed(_, _, let message) {
            text = message
            failed = true
        } catch {
            return .failed
        }
        if XiaomiInputBlock.isInjectionDenied(logLine: text) {
            if errorMessage != XiaomiInputBlock.bannerText { errorMessage = XiaomiInputBlock.bannerText }
            return .denied
        }
        return failed ? .failed : .sent
    }

    // MARK: Status

    private var errorMessage: String? {
        get { status.errorMessage }
        set { status.errorMessage = newValue }
    }

    private func flashStatus(_ message: String) {
        status.flash(message)
    }
}
