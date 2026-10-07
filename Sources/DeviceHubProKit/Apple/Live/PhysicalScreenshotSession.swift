import Foundation

/// The wireless (and any-transport) view of a physical iPhone or iPad: its
/// screen as repeated public `devicectl device capture screenshot` calls,
/// shown while the USB capture cannot run
/// (Wi-Fi, no capture device, no Camera permission).
///
/// It is `SimulatorScreenshotSession`'s poll with a device's screenshot in
/// place of simctl's: **one capture at a time, never overlapping**; the next
/// starts as soon as the previous one finished, and no sooner than
/// `minimumInterval` (0.5 s) after the previous one *started*; nothing is
/// captured until a view shows the session (`setShown`), so a hidden window
/// asks the phone for nothing. Each picture goes through a temporary PNG that
/// is removed right after it is read (never accumulated). Measured on the
/// dedicated test iPhone over Wi-Fi: 1.35 to 1.67 s per picture, about 0.7
/// per second (`measuredInterval` reports what this run sees).
///
/// View only: input is dropped, unless Control is on (`inputRoute`, Phase
/// 9E-2). The stream stops for good only when the
/// session is stopped; a failed capture is kept in `lastError` and the next
/// one is tried.
public final class PhysicalScreenshotSession: MirrorSessionProtocol, PhysicalViewSession, ShownTrackingSession, @unchecked Sendable {
    /// Writes one PNG of the phone's screen to the destination.
    public typealias Capture = SimulatorScreenshotSession.Capture

    /// The floor between two captures' starts.
    public static let minimumInterval: Duration = .milliseconds(500)

    public let hardwareUDID: String
    public var viewKind: PhysicalViewKind { .screenshots }
    public let inputRoute = PhysicalInputRoute()
    private let poll: SimulatorScreenshotSession

    public init(hardwareUDID: String, interval: Duration = minimumInterval, capture: @escaping Capture) {
        self.hardwareUDID = hardwareUDID
        poll = SimulatorScreenshotSession(
            udid: hardwareUDID,
            interval: interval,
            transport: .physicalScreenshots,
            failureLabel: "Screenshot",
            capture: capture
        )
    }

    public var frames: FrameStore { poll.frames }
    public var transport: MirrorTransport { .physicalScreenshots }
    public var lastError: String? { poll.lastError }
    public var isRunning: Bool { poll.isRunning }
    /// Whether a view shows the session, so it captures.
    public var isShown: Bool { poll.isShown }
    /// Captures taken since the last start, failed ones included.
    public var captureCount: Int { poll.captureCount }
    /// The measured gap between the last pictures; nil before two arrived.
    public var measuredInterval: Duration? { poll.measuredInterval }

    public func start() { poll.start() }
    public func stop() { poll.stop() }
    public func setShown(_ shown: Bool) { poll.setShown(shown) }
    public func resync() async { await poll.resync() }
    public func stats() async -> MirrorStats { await poll.stats() }

    public func send(_ command: TouchCommand) { inputRoute.receive(contacts: [command]) }
    public func send(contacts: [TouchCommand]) { inputRoute.receive(contacts: contacts) }
    public func send(_ command: KeyboardCommand) { inputRoute.receive(command) }
    public var acceptsPhysicalKeys: Bool { inputRoute.acceptsPhysicalKeys }
    public func send(physical event: PhysicalKeyEvent) { inputRoute.receive(physical: event) }

    public func send(button: SimulatorHardwareButton, isDown: Bool) {
        inputRoute.receive(button: button, isDown: isDown)
    }

    public var acceptsButtons: Bool { inputRoute.acceptsButtons }

    /// "about every 1.5 s" from the measured cadence; nil before two
    /// pictures arrived. One decimal, never a promised number.
    public static func cadenceText(_ interval: Duration?, locale: Locale = .current) -> String? {
        guard let interval else { return nil }
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        guard seconds > 0 else { return nil }
        return "about every \(seconds.formatted(.number.precision(.fractionLength(1)).locale(locale))) s"
    }
}

/// A session whose capture runs only while a view shows it
/// (`SimulatorScreenshotSession`, `PhysicalScreenshotSession`): the stage
/// tells it when it is on screen in a visible window.
public protocol ShownTrackingSession: MirrorSessionProtocol {
    /// A view that draws the session's frames appeared (`true`) or went away
    /// (`false`); calls pair up.
    func setShown(_ shown: Bool)
}

extension SimulatorScreenshotSession: ShownTrackingSession {}
