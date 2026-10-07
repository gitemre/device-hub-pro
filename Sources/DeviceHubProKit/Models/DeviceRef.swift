import Foundation

/// The platform a device belongs to, which decides the tools that reach it:
/// adb and the emulator's gRPC for Android, simctl, devicectl and the
/// simulator bridge for Apple.
public enum DevicePlatform: String, Sendable, Hashable, Codable, CaseIterable {
    case android
    case apple
}

/// What kind of machine a device is.
public enum DeviceKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// An Android Virtual Device the emulator runs.
    case emulator
    /// An Apple simulator (CoreSimulator).
    case simulator
    /// Hardware: an Android phone over adb, or a physical iPhone or iPad
    /// (CoreDevice, manage-only).
    case physical
}

/// How far a boot has got, as the device's tools report it.
///
/// A simulator's phases come from `simctl bootstatus`; `simctl list` already
/// says Booted about a second into a boot that can take 25–45 s, so the
/// listing alone never says how far a boot is.
public enum DeviceBootPhase: Sendable, Hashable {
    /// The boot was asked for; nothing has reported a phase yet.
    case launching
    /// `bootstatus`: backboardd is not up yet.
    case waitingOnBackBoard
    /// `bootstatus`: data migration, which a first boot (or the first after
    /// a runtime update) runs for 15–20 s.
    case migratingData
    /// `bootstatus`: waiting for the system app (SpringBoard) to check in.
    case waitingOnSystemApp
    /// `bootstatus` reported Finished; the home screen app is not up yet.
    case waitingOnHomeScreen
    /// A phase this build does not know, verbatim.
    case other(String)
}

/// Where a device is in its life, on any platform.
public enum DeviceRunState: Sendable, Hashable {
    /// Not running.
    case stopped
    /// Starting: running, not usable yet.
    case booting(DeviceBootPhase)
    /// Usable. A simulator is ready once its boot status is Finished,
    /// SpringBoard runs and its screen shows the home screen
    /// (`SimulatorReadiness`), not when it is listed Booted.
    case ready
    case shuttingDown
    /// A lost connection the app is re-establishing.
    case reconnecting
    /// Running, but not answering.
    case unreachable
    /// A phone that has not authorized this Mac.
    case unauthorized
}

/// One device as a platform-neutral list or Info panel shows it.
public struct DeviceSummary: Sendable, Hashable, Identifiable {
    public let ref: DeviceRef
    public let kind: DeviceKind
    /// The name the user sees (a simulator's own name, an AVD's display name).
    public let name: String
    /// "iOS", "tvOS", "Android".
    public let osName: String?
    /// "27.0".
    public let osVersion: String?
    /// The hardware model: "iPhone 17 Pro".
    public let model: String?
    public let runState: DeviceRunState
    /// False for a device its tools cannot run (a simulator whose runtime
    /// is missing).
    public let isAvailable: Bool

    public var id: DeviceRef { ref }

    public init(
        ref: DeviceRef,
        kind: DeviceKind,
        name: String,
        osName: String?,
        osVersion: String?,
        model: String?,
        runState: DeviceRunState,
        isAvailable: Bool
    ) {
        self.ref = ref
        self.kind = kind
        self.name = name
        self.osName = osName
        self.osVersion = osVersion
        self.model = model
        self.runState = runState
        self.isAvailable = isAvailable
    }
}

/// A device on any platform, by the identifier its tools use.
///
/// - Android: the adb serial (`emulator-5554`, a phone's serial or its
///   `ip:port`). The serial is reused by whichever VM boots next; the adb
///   side tells them apart by transport id, not through this reference.
/// - Apple simulator: its UDID, stable across boot and shutdown.
/// - Apple physical device: its hardware UDID, upper-cased (stable across
///   connections; the CoreDevice identifier stays inside the Kit's
///   `ApplePhysicalDevice`). Its `DeviceKind` is `.physical`.
public struct DeviceRef: Sendable, Hashable, Codable {
    public let platform: DevicePlatform
    public let id: String

    public init(platform: DevicePlatform, id: String) {
        self.platform = platform
        self.id = id
    }

    /// An Android device by its adb serial.
    public static func android(_ serial: String) -> DeviceRef {
        DeviceRef(platform: .android, id: serial)
    }

    /// An Apple device by its UDID (a simulator) or CoreDevice identifier.
    public static func apple(_ id: String) -> DeviceRef {
        DeviceRef(platform: .apple, id: id)
    }

    /// An Apple physical device by its hardware UDID (`DeviceKind.physical`,
    /// never an adb serial or a simulator).
    public static func physicalApple(_ hardwareUDID: String) -> DeviceRef {
        DeviceRef(platform: .apple, id: hardwareUDID.uppercased())
    }

    /// The adb serial: the id of an Android device, nil for any other, so a
    /// path that talks to adb can never be handed an Apple identifier.
    public var adbSerial: String? {
        platform == .android ? id : nil
    }
}

/// What a device can do, as far as the app offers it.
///
/// The neutral bits describe features every platform may have. The Apple
/// bits are declared for the simulator tier and not read yet. Android keeps
/// three coarse buckets, because its existing gates already key on the adb
/// serial and the emulator's gRPC port and keep working as they are.
public struct DeviceCapabilities: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    // MARK: Neutral

    /// A live picture of the screen.
    public static let mirror = DeviceCapabilities(rawValue: 1 << 0)
    /// Touches on the picture reach the device.
    public static let touch = DeviceCapabilities(rawValue: 1 << 1)
    /// Mac key presses reach the device.
    public static let keyboard = DeviceCapabilities(rawValue: 1 << 2)
    /// The device can be turned in 90° steps.
    public static let rotate = DeviceCapabilities(rawValue: 1 << 3)
    /// A still of the screen from the device's own tools.
    public static let screenshot = DeviceCapabilities(rawValue: 1 << 4)
    /// A recording of the screen.
    public static let record = DeviceCapabilities(rawValue: 1 << 5)
    /// Installed apps are listed, installed and removed.
    public static let apps = DeviceCapabilities(rawValue: 1 << 6)
    /// The device's log streams live.
    public static let logs = DeviceCapabilities(rawValue: 1 << 7)
    /// The clipboard is shared with the Mac.
    public static let clipboard = DeviceCapabilities(rawValue: 1 << 8)
    /// A simulated location can be set.
    public static let location = DeviceCapabilities(rawValue: 1 << 9)
    /// A URL or deep link opens on the device.
    public static let openURL = DeviceCapabilities(rawValue: 1 << 10)

    // MARK: Apple (declared, not read yet)

    /// Status bar overrides (`simctl status_bar`).
    public static let statusBar = DeviceCapabilities(rawValue: 1 << 16)
    /// Privacy permissions granted or revoked per app (`simctl privacy`).
    public static let privacy = DeviceCapabilities(rawValue: 1 << 17)
    /// Simulated push notifications (`simctl push`).
    public static let push = DeviceCapabilities(rawValue: 1 << 18)
    /// Home, side and volume buttons.
    public static let hardwareButtons = DeviceCapabilities(rawValue: 1 << 19)
    /// A simulated shake (UIKit's simulator-shake notification):
    /// experimental.
    public static let shake = DeviceCapabilities(rawValue: 1 << 20)

    // MARK: Android buckets

    /// Settings and shell commands through adb.
    public static let adbSettings = DeviceCapabilities(rawValue: 1 << 32)
    /// The emulator's gRPC control channel (battery, sensors, posture, …).
    public static let emulatorGrpc = DeviceCapabilities(rawValue: 1 << 33)
    /// Android key events through adb (power, volume, Back, Home, Recents).
    public static let androidKeys = DeviceCapabilities(rawValue: 1 << 34)

    /// What an adb device offers: an emulator mirrored over gRPC
    /// (`emulatorGrpc` true) adds the gRPC bucket and what only an emulator
    /// does (its rotation, a simulated location); a phone, or an emulator
    /// forced through scrcpy, has neither.
    public static func android(emulatorGrpc: Bool) -> DeviceCapabilities {
        var capabilities: DeviceCapabilities = [
            .mirror, .touch, .keyboard, .screenshot, .record, .apps, .logs, .clipboard, .openURL,
            .adbSettings, .androidKeys,
        ]
        if emulatorGrpc {
            capabilities.formUnion([.emulatorGrpc, .rotate, .location])
        }
        return capabilities
    }

    /// What a physical iPhone or iPad offers (manage-only): no live
    /// picture and no input; a screenshot, and a recording unless the device
    /// reports the capability missing (`supportsRecording`).
    public static func physicalApple(supportsRecording: Bool) -> DeviceCapabilities {
        supportsRecording ? [.screenshot, .record] : [.screenshot]
    }

    /// What a mirrored simulator offers. The live canvas (the private
    /// bridge) takes touches and keys and presses the hardware buttons; the
    /// view-only canvas (`simctl io screenshot`) takes neither. Either can
    /// shake (a Darwin notification through simctl). A rotation goes through
    /// devicectl, which only sees the default device set, or through the
    /// bridge, so `rotatesWithoutBridge` says whether the view-only canvas
    /// can rotate.
    public static func simulator(liveCanvas: Bool, rotatesWithoutBridge: Bool) -> DeviceCapabilities {
        var capabilities: DeviceCapabilities = [.mirror, .shake]
        if liveCanvas {
            capabilities.formUnion([.touch, .keyboard, .rotate, .hardwareButtons])
        } else if rotatesWithoutBridge {
            capabilities.insert(.rotate)
        }
        return capabilities
    }
}
