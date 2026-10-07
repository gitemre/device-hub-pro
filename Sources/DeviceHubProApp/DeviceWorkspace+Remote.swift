import DeviceHubProKit

extension DeviceWorkspace {
    /// Presses one remote button on the shown TV.
    ///
    /// An emulator whose AVD has the keyboard device takes it through the
    /// emulator's own key queue (gRPC `sendKey`, the fastest path: no process
    /// to spawn); any other TV, and an emulator that refuses the call, takes
    /// `adb shell input keyevent`, which needs no keyboard device and sends
    /// the real `DPAD_CENTER` for Select (`RemoteKey.evdevCode`).
    func pressRemote(_ key: RemoteKey) {
        guard let device = context.device else { return }
        if device.platform == .apple {
            // An Apple TV simulator's remote: HID keys on its input channel.
            simulatorCanvas.pressRemote(key)
            return
        }
        guard let serial = device.adbSerial else { return }
        let port = context.port
        let keyboardOff = context.avdName.flatMap { AvdConfig.hardwareKeyboard(avdName: $0) } == false
        let adb = services.adbClient
        Task {
            if let port, !keyboardOff {
                do {
                    try await RemoteKeys.press(key, port: port)
                    return
                } catch {
                    // Fall through to adb.
                }
            }
            if let adb {
                try? await RemoteKeys.press(key, adb: adb, serial: serial)
            }
        }
    }

    /// What a Mac key press does on the shown TV: the button it stands for
    /// is pressed and true is returned; false leaves the key to the
    /// keyboard path (text, Tab).
    func forwardKeyToRemote(_ command: KeyboardCommand) -> Bool {
        guard let family = remoteFamily, case .specialKey(let macKeyCode) = command,
              let key = RemoteKey(macKeyCode: macKeyCode),
              family != .appleTV || key.appleTVKeyUsage != nil
        else { return false }
        pressRemote(key)
        return true
    }
}
