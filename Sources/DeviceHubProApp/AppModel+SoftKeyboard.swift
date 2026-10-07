import DeviceHubProKit
import Foundation

extension AppModel {
    /// The emulator whose own soft keyboard must show: the one on the stage
    /// while Keyboard Capture is off. Capture on, no device, or a phone (its
    /// keyboard is not ours to configure) is nil.
    var softKeyboardTarget: String? {
        guard !preferences.keyboardForwardingEnabled,
              let serial = (registry.focused ?? workspace).liveSelectionSerial,
              serial.hasPrefix("emulator-")
        else { return nil }
        return serial
    }

    /// Keeps `SoftKeyboardLease` at `softKeyboardTarget`: re-armed after every
    /// change of the capture toggle or the selection. Deselecting the device
    /// or turning capture on restores the setting; quitting does too
    /// (`prepareForTermination`).
    func watchSoftKeyboard() {
        guard let softKeyboard else { return }
        let target = withObservationTracking {
            softKeyboardTarget
        } onChange: { [weak self] in
            // Fires before the new value is stored; judge on the next turn.
            Task { @MainActor in self?.watchSoftKeyboard() }
        }
        let contact = softKeyboardContact
        Task { await softKeyboard.sync(target: target, contact: contact) }
    }

    /// The emulator on the stage whatever the capture toggle says: where an
    /// earlier run's leftover soft-keyboard setting is put back.
    var softKeyboardContact: String? {
        guard let serial = (registry.focused ?? workspace).liveSelectionSerial,
              serial.hasPrefix("emulator-")
        else { return nil }
        return serial
    }

    /// A change of the focused window: the lease follows its stage.
    func syncSoftKeyboard() {
        guard let softKeyboard else { return }
        let target = softKeyboardTarget
        let contact = softKeyboardContact
        Task { await softKeyboard.sync(target: target, contact: contact) }
    }

    /// The toolbar toggle and the Keyboard menu both come here: stores the
    /// setting and, the first time capture is turned off with an emulator on
    /// the stage, raises the one-time tip.
    func setKeyboardCapture(_ enabled: Bool) {
        preferences.setKeyboardForwarding(enabled)
        if SoftKeyboardHint.shouldShow(
            captureEnabled: enabled,
            serial: (registry.focused ?? workspace).liveSelectionSerial,
            alreadyShown: preferences.softKeyboardHintShown
        ) {
            preferences.markSoftKeyboardHintShown()
            softKeyboardHintVisible = true
        }
    }
}
