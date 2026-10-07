import Foundation
import DeviceHubProKit

extension SimulatorCanvasController {
    /// Where an Apple TV remote's presses are sent from: never the main
    /// queue (every bridge entry point refuses it).
    private static let remoteQueue = DispatchQueue(label: "DeviceHubPro.AppleTVRemote", qos: .userInitiated)

    /// Presses one Apple TV remote button on the shown simulator, as a key on
    /// its HID keyboard (`RemoteKey.appleTVKeyUsage`). The view-only canvas
    /// (tvOS has no live canvas: its framebuffer has no display of class 0)
    /// takes the same channel; the screen follows at the canvas's own pace.
    ///
    /// Connecting dtuhidd is the first input, as for the live canvas:
    /// the user pressed the button. The bridge's own gates
    /// apply: no bridge, an untested CoreSimulator or a stale one sends
    /// nothing.
    func pressRemote(_ key: RemoteKey) {
        guard let usage = key.appleTVKeyUsage,
              let device = activeDevice(), device.platform == .apple,
              let entry = simulators.entry(udid: device.id),
              entry.platform == "tvOS",
              let bridge = simulators.bridge,
              simulators.bridgeVerdict().allowsBridge,
              !simulators.bridgeIsStale()
        else { return }
        let udid = entry.udid
        let address = SimulatorAddress(udid: udid, deviceSetPath: simulators.deviceSet?.path)
        let existing = memory.remoteInputs[udid]
        let events = SimulatorKeyStroke(usage: usage).events
        Self.remoteQueue.async { [weak self] in
            // The bridge makes its channels off the main queue only.
            let input = existing ?? bridge.makeInput(for: address)
            // Best effort: a press that fails is a press that did nothing.
            for event in events {
                try? input.send(event)
            }
            try? input.flush(timeout: .seconds(2))
            guard existing == nil else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.memory.remoteInputs[udid] == nil else {
                        Self.remoteQueue.async { input.disconnect() }
                        return
                    }
                    self.memory.remoteInputs[udid] = input
                }
            }
        }
    }
}
