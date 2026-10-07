import Foundation

/// A touch event forwarded from the mirror view to the device.
public struct TouchCommand: Sendable {
    public enum Phase: Sendable {
        case down
        case move
        case up
    }

    public let phase: Phase
    public let x: Int32
    public let y: Int32
    public let id: Int32

    public init(phase: Phase, x: Int32, y: Int32, id: Int32 = 0) {
        self.phase = phase
        self.x = x
        self.y = y
        self.id = id
    }
}

/// Which video transport the mirror session negotiated.
public enum MirrorTransport: String, Sendable {
    /// Shared-memory transport, the default where it works. Requires emulator
    /// >= 37.2.3 (issue #537802959). The emulator's mmap buffer is
    /// unsynchronized, so `MirrorSession` repairs torn frames from snapshots.
    case mmap
    /// Raw RGBA frames copied by the emulator over gRPC. Works everywhere and
    /// never tears; the fallback for older emulators and any MMAP failure.
    case raw
    /// H.264 from the scrcpy server, decoded with VideoToolbox. The physical
    /// device transport (spec §11.1).
    case h264
    /// An iOS simulator's screen IOSurface, copied through the private
    /// simulator bridge (`SimulatorMirrorSession`).
    case simulatorSurface
    /// An iOS simulator's screen polled with `simctl io screenshot` while
    /// the stage shows it (`SimulatorScreenshotSession`): the view-only
    /// canvas when the bridge cannot run.
    case simulatorScreenshots
    /// A USB-connected iPhone's or iPad's screen through the public
    /// CoreMediaIO + AVFoundation capture
    /// (`PhysicalScreenCaptureSession`): live and view only.
    case physicalScreenCapture
    /// A physical iPhone's screen through the private CoreDevice media stream
    /// (`PhysicalNativeMirrorSession`): live, view only, no Camera permission.
    case physicalNativeMirror
    /// A physical iPhone's or iPad's screen as repeated `devicectl device
    /// capture screenshot` calls (`PhysicalScreenshotSession`): view only,
    /// about one picture every 1.5 s, over any transport CoreDevice has.
    case physicalScreenshots

    public var displayName: String {
        switch self {
        case .mmap: return "mmap (shared memory)"
        case .raw: return "raw RGBA over gRPC"
        case .h264: return "H.264 over scrcpy"
        case .simulatorSurface: return "simulator IOSurface"
        case .simulatorScreenshots: return "simctl screenshots (view only)"
        case .physicalScreenCapture: return "iPhone screen capture (view only)"
        case .physicalNativeMirror: return "iPhone native live view (view only)"
        case .physicalScreenshots: return "devicectl screenshots (view only)"
        }
    }
}
