import Foundation

/// The stage-facing surface of a live mirror session, independent of the
/// transport behind it.
///
/// The emulator sessions (`MirrorSession`, gRPC + mmap/raw) and the physical
/// sessions (`PhysicalMirrorSession`, scrcpy + VideoToolbox) both publish the
/// same `FrameStore` of RGBA frames, so the stage, capture, replay buffer and
/// recording feed work unchanged. `send` methods deliver input; a session that
/// does not support input yet simply drops it.
public protocol MirrorSessionProtocol: AnyObject, Sendable {
    /// The latest-frame store the Metal renderer consumes.
    var frames: FrameStore { get }
    /// The negotiated/implemented video transport, for diagnostics.
    var transport: MirrorTransport { get }
    /// The last stream error, or nil. Sessions keep running after input
    /// errors. A physical session stops itself on a fatal video error and
    /// leaves the message here; an emulator session keeps reconnecting and
    /// reports each failure here until frames flow again.
    var lastError: String? { get }
    /// Whether the session is live: false before `start()`, after `stop()`,
    /// and after a physical session stopped itself on a fatal error. An
    /// emulator session stays running while it reconnects.
    var isRunning: Bool { get }

    /// Starts (or restarts) the video stream. Returns immediately; failures
    /// land in ``lastError``.
    func start()
    /// Stops the video stream and releases its resources. Idempotent.
    func stop()
    /// Repaints the newest frame from a consistent source. Emulator-only
    /// concern (mmap tears); physical sessions may no-op.
    func resync() async
    /// A snapshot of stream statistics for the overlay.
    func stats() async -> MirrorStats

    /// Forwards one touch contact.
    func send(_ command: TouchCommand)
    /// Forwards several contacts as one input frame (pinch/zoom, rotates).
    func send(contacts: [TouchCommand])
    /// Forwards a keyboard command.
    func send(_ command: KeyboardCommand)

    /// Whether `send(_: HardwareKeyEvent)` reaches the device: the frame's
    /// buttons are offered only then.
    var supportsHardwareKeys: Bool { get }
    /// Forwards one edge (down or up) of a hardware key press.
    func send(_ event: HardwareKeyEvent)

    /// Whether the stage should send Mac keys as physical keys
    /// (`send(physical:)`) instead of text.
    var acceptsPhysicalKeys: Bool { get }
    /// Forwards one Mac key event as the same physical key.
    func send(physical event: PhysicalKeyEvent)
}

extension MirrorSessionProtocol {
    /// No hardware-key path: physical sessions press their keys another way
    /// (the Device and Controls menus). The emulator and simulator sessions
    /// implement it.
    public var supportsHardwareKeys: Bool { false }

    public func send(_ event: HardwareKeyEvent) {}

    /// Only a physical iPhone with fast input forwards physical keys.
    public var acceptsPhysicalKeys: Bool { false }

    public func send(physical event: PhysicalKeyEvent) {}
}
