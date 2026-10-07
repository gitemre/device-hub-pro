import Foundation
import Observation
import DeviceHubProKit

/// The device the mirror is attached to: which device on which platform,
/// what it can do, its adb serial, the emulator's gRPC port, the AVD behind
/// it, and the generations that tie a late result to the session it was
/// asked for.
///
/// One long-lived instance per `DeviceWorkspace`, shared with the features
/// that act on the active device, so none of them keeps its own copy of the
/// serial or port. Only the workspace writes it: the session hubs
/// (`beginMirrorSession`, `tearDownMirror`) and the AVD-name lookup.
///
/// A feature that works on any platform (the replay ring, the recording,
/// the compact mirror, the live stage) reads `device`. An adb or gRPC path
/// reads `serial` or `port`, which are nil for an Apple device, so its
/// existing `guard let` makes it a no-op there.
@MainActor
@Observable
final class ActiveDeviceContext {
    /// The mirrored device, whatever its platform; nil while nothing is
    /// mirrored.
    var device: DeviceRef?
    /// What the mirrored device can do; empty while nothing is mirrored.
    var capabilities: DeviceCapabilities = []
    /// The mirrored device is a physical iPhone or iPad whose screen is a
    /// view-only session (`PhysicalViewSession`), not a
    /// simulator: its ref is an Apple ref like a simulator's, and the
    /// simulator-only paths (simctl, the canvas, chrome by simulator type)
    /// must leave it alone. Set by the begin hub from the session's type.
    var isPhysicalView = false
    /// The mirrored device when it is a simulator: `device` for an Apple
    /// device that is not a physical view, else nil. The simulator-only
    /// paths read this, never `device?.platform == .apple`.
    var simulatorDevice: DeviceRef? {
        guard let device, device.platform == .apple, !isPhysicalView else { return nil }
        return device
    }
    /// The mirrored device's adb serial: `device`'s id when it is an Android
    /// device, nil for an Apple device and while nothing is mirrored.
    /// Setting it names an Android device.
    var serial: String? {
        get { device?.adbSerial }
        set { device = newValue.map(DeviceRef.android) }
    }
    /// The emulator's gRPC port; nil for a physical device, an Apple device
    /// and while nothing is mirrored.
    var port: Int?
    /// The AVD behind the active mirror; nil for a physical device, before
    /// the lookup answers, and once the mirror is torn down.
    var avdName: String? {
        didSet {
            // Read once per session: `isFoldable` is evaluated by view
            // bodies on every Controls poll, and this is a config.ini read.
            hingeCount = avdName.map { AvdConfig.hingeCount(avdName: $0, avdHome: avdHome) } ?? 0
        }
    }
    /// The active AVD's hinge sensor count, read from its config.ini once
    /// when the AVD becomes known (see `avdName`).
    private(set) var hingeCount = 0
    /// Bumped by every session start and teardown, for results that must
    /// land on the session they were asked for (`AppModel`'s
    /// `mirrorSessionGeneration`).
    var sessionGeneration = 0
    /// Bumped whenever the mirrored device changes (session start and
    /// teardown): a Controls poll started for the previous device applies
    /// nothing.
    var controlsGeneration: UInt64 = 0

    /// The AVD home `avdName`'s config.ini is read from — for the hinge
    /// count here and a framed screenshot's skin — nil for the one the
    /// emulator uses (`AvdConfig.homeURL`).
    let avdHome: URL?

    init(avdHome: URL? = nil) {
        self.avdHome = avdHome
    }

    /// Forgets the device — the device (and with it the serial), its
    /// capabilities, the port, then the AVD (and with it the hinge count).
    /// The generations are left to the hubs, which bump them.
    func clear() {
        device = nil
        capabilities = []
        isPhysicalView = false
        port = nil
        avdName = nil
    }
}
