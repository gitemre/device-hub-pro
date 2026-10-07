import CoreGraphics
import Foundation
import Synchronization

/// The pose of a physical iPhone's stage, and separately which way its interface is
/// turned (measured 2026-09-30 and 2026-10-01 on the test iPhone 12 / iOS 27.0, Device Hub
/// 27.0):
///
/// - the native stream is always the portrait panel (1184x2576, crop 1170x2532);
/// - `devicectl device orientation get` (cheap, allowed) reports the device's
///   pose, not the interface's: a portrait-only app, and the iPhone 12 home
///   screen, stay portrait while the device is landscape;
/// - Device Hub turns the stage's frame and picture with the DEVICE pose it set,
///   whatever the interface does (the home screen shows sideways in a landscape
///   frame), exactly as for a simulator. So `stagePose` is the device pose: the
///   last pose Device Hub Pro set (`noteTurn(to:)`) reconciled with the polled
///   `orientation get`, which is followed when it changes (an external turn). Flat and
///   unknown change nothing;
/// - a `devicectl` screenshot follows the interface, so its pixel aspect says whether
///   the interface is landscape or portrait right now. `interfaceOrientation` is that,
///   and only decides where the home indicator is (`PhysicalControlInputRouter`): at the
///   bottom of the interface, which is the stage bottom only for an interface that
///   turned, else the panel bottom.
///
/// Every `interval` the device pose is read. When it changes to a decisive pose, the stage
/// follows it `settle` later (after the pose was read again, so a quick second turn is
/// not answered twice) and one screenshot is taken to decide the interface. Values are
/// `PhysicalControlOrientation`s limited to portrait, landscapeLeft, landscapeRight and
/// portraitUpsideDown; nil until the first read.
public final class PhysicalInterfaceOrientationTracker: @unchecked Sendable {
    public struct Reads: Sendable {
        /// The device pose (`devicectl device orientation get`).
        public var deviceOrientation: @Sendable () async throws -> PhysicalControlOrientation
        /// The pixel size of a fresh screenshot (`devicectl device capture screenshot`).
        public var screenshotSize: @Sendable () async throws -> CGSize

        public init(
            deviceOrientation: @escaping @Sendable () async throws -> PhysicalControlOrientation,
            screenshotSize: @escaping @Sendable () async throws -> CGSize
        ) {
            self.deviceOrientation = deviceOrientation
            self.screenshotSize = screenshotSize
        }
    }

    private let reads: Reads
    private let interval: Duration
    private let settle: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private struct State {
        var stage: PhysicalControlOrientation?
        var interface: PhysicalControlOrientation?
        var lastDevice: PhysicalControlOrientation?
        /// The pose `noteTurn` set and the polls that disagreed with it since: a read that
        /// differs is the phone still turning (or a stale answer), not an external turn.
        var noted: PhysicalControlOrientation?
        var disagreements = 0
        /// Bumped by every `noteTurn`, so a poll that was waiting when the app turned the
        /// phone does not publish what it read before.
        var turnGeneration = 0
        var task: Task<Void, Never>?
        var observers: [@Sendable () -> Void] = []
    }
    private let state = Mutex(State())

    public init(
        reads: Reads,
        interval: Duration = .seconds(1),
        settle: Duration = .milliseconds(600),
        sleep: @escaping @Sendable (Duration) async throws -> Void = FastInputClock.sleep
    ) {
        self.reads = reads
        self.interval = interval
        self.settle = settle
        self.sleep = sleep
    }

    /// The stage's pose (the device pose): portrait, landscapeLeft, landscapeRight or
    /// portraitUpsideDown; nil before the first read.
    public var stagePose: PhysicalControlOrientation? { state.withLock { $0.stage } }

    /// The interface's orientation (from a screenshot's aspect), nil before the first read.
    public var interfaceOrientation: PhysicalControlOrientation? { state.withLock { $0.interface } }

    /// Whether the interface is turned to a landscape.
    public var interfaceIsLandscape: Bool {
        let value = interfaceOrientation
        return value == .landscapeLeft || value == .landscapeRight
    }

    /// Called (from any thread) whenever `stagePose` or `interfaceOrientation` changes.
    public func observe(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.observers.append(handler) }
    }

    public func start() {
        state.withLock { state in
            guard state.task == nil else { return }
            state.task = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.poll()
                    do { try await self.sleep(self.interval) } catch { return }
                }
            }
        }
    }

    public func stop() {
        state.withLock { state in
            state.task?.cancel()
            state.task = nil
        }
    }

    /// True for a pose that says something about the interface.
    private static func isDecisive(_ pose: PhysicalControlOrientation) -> Bool {
        pose == .portrait || pose == .landscapeLeft || pose == .landscapeRight || pose == .portraitUpsideDown
    }

    /// One step: read the pose and, when it changed to a decisive one, follow it.
    func poll() async {
        guard let device = try? await reads.deviceOrientation(), Self.isDecisive(device) else { return }
        guard state.withLock({ $0.lastDevice }) != device else { return }
        if holdsForNotedTurn(read: device) { return }
        let generation = state.withLock { $0.turnGeneration }
        do { try await sleep(settle) } catch { return }
        // A second turn during the wait is the one to answer.
        let latest = (try? await reads.deviceOrientation()) ?? device
        guard Self.isDecisive(latest) else { return }
        if state.withLock({ $0.lastDevice }) == latest { return }
        // The app turned the phone while this poll waited: its reads are older than the turn.
        guard state.withLock({ $0.turnGeneration }) == generation else { return }
        if holdsForNotedTurn(read: latest) { return }
        state.withLock { $0.lastDevice = latest }
        publish(stage: latest)
        await resolveInterface(device: latest)
    }

    /// After `orientation set <pose>` the app asked for a turn: the stage takes the pose at
    /// once (`orientation get` does not follow `set`, measured, so the polled value only
    /// counts when it changes), and `settle` later a fresh screenshot decides the
    /// interface (a portrait-only app keeps its side).
    public func noteTurn(to pose: PhysicalControlOrientation) async {
        guard Self.isDecisive(pose) else { return }
        state.withLock { state in
            state.turnGeneration += 1
            state.noted = pose
            state.disagreements = 0
        }
        publish(stage: pose)
        do { try await sleep(settle) } catch { return }
        await resolveInterface(device: pose)
    }

    /// How many polled reads that disagree with the pose the app set are taken for the phone
    /// still turning before they count as an external turn (about that many seconds).
    private static let patience = 4

    /// True when `read` should be ignored because the app just turned the phone to another
    /// pose: the phone passes through or reports another pose for a moment after `set`.
    /// A read that equals the noted pose ends the wait; so do enough disagreeing reads.
    private func holdsForNotedTurn(read: PhysicalControlOrientation) -> Bool {
        state.withLock { state in
            guard let noted = state.noted else { return false }
            if read == noted {
                state.noted = nil
                return false
            }
            state.disagreements += 1
            if state.disagreements > Self.patience {
                state.noted = nil
                return false
            }
            return true
        }
    }

    /// Decides the interface for the device pose `device` from a screenshot's aspect.
    private func resolveInterface(device: PhysicalControlOrientation) async {
        let size = try? await reads.screenshotSize()
        let previous = state.withLock { $0.interface }
        let interface: PhysicalControlOrientation
        if let size, size.width > size.height {
            switch device {
            case .landscapeLeft, .landscapeRight: interface = device
            default: interface = previous == .landscapeRight ? .landscapeRight : .landscapeLeft
            }
        } else if size != nil {
            interface = .portrait
        } else {
            // No screenshot: the interface follows the device, but never upside down.
            interface = device == .portraitUpsideDown ? (previous ?? .portrait) : device
        }
        publish(interface: interface)
    }

    private func publish(stage: PhysicalControlOrientation) {
        let observers = state.withLock { state -> [@Sendable () -> Void] in
            guard state.stage != stage else { return [] }
            state.stage = stage
            return state.observers
        }
        observers.forEach { $0() }
    }

    private func publish(interface: PhysicalControlOrientation) {
        let observers = state.withLock { state -> [@Sendable () -> Void] in
            guard state.interface != interface else { return [] }
            state.interface = interface
            return state.observers
        }
        observers.forEach { $0() }
    }
}

/// How the panel image turns into the stage's upright picture for the stage's pose
/// (the device pose, which the frame turns with): the inverse of
/// `FastInputPanelMapping.rotation(for:)` (panel = rotate(stage)). landscapeLeft turns
/// the panel image 90 degrees counter-clockwise (the panel's top-right corner becomes the
/// stage's top-left), landscapeRight 90 degrees clockwise, and upside down half a turn.
public enum PhysicalStageRotation {
    /// The stage-to-panel rotation for a stage pose; identity for portrait and for
    /// anything the stage cannot be.
    public static func rotation(for pose: PhysicalControlOrientation?) -> FastInputPanelMapping.Rotation {
        switch pose {
        case .landscapeLeft?: .clockwise90
        case .landscapeRight?: .counterClockwise90
        case .portraitUpsideDown?: .turn180
        default: .identity
        }
    }

    /// The stage picture's size for a panel picture of `panel`.
    public static func stageSize(panel: CGSize, pose: PhysicalControlOrientation?) -> CGSize {
        switch rotation(for: pose) {
        case .clockwise90, .counterClockwise90: CGSize(width: panel.height, height: panel.width)
        case .identity, .turn180: panel
        }
    }
}
