import CoreGraphics
import Foundation
import ImageIO
import Synchronization

/// The view-only canvas of a simulator: its screen polled with `simctl io
/// <UDID> screenshot` while a view shows it ("Fallback").
///
/// It stands in for `SimulatorMirrorSession` when the private bridge cannot
/// run (no Xcode 27, an untested CoreSimulator, a runtime off the allowlist,
/// `DHP_DISABLE_SIMBRIDGE=1`, or a bridge that failed its smoke check).
/// It publishes the same upright frames (`Frame.rotation` 0, simctl writes
/// the screen as the interface shows it), so the stage draws it like the
/// live canvas; touches, keys and hardware keys are dropped.
///
/// **Only while shown, at most once a second.** Nothing is captured until a
/// view says it shows the session (`setShown(true)`), and the poll waits,
/// without waking, while none does. A capture starts no sooner than
/// `interval` after the previous one started. Each writes a PNG into a
/// temporary file that is removed right after it is read.
///
/// **Lifecycle.** `start()` returns at once. A capture simctl refuses because
/// the simulator is shut down or gone stops the session with
/// `SimulatorMirrorSession.shutDownMessage` in `lastError`, like the live
/// session. Any other failure is kept in `lastError` until a capture works
/// again; the poll goes on. `stop()` is idempotent.
public final class SimulatorScreenshotSession: MirrorSessionProtocol, @unchecked Sendable {
    /// Writes one PNG of the simulator's screen to the destination.
    public typealias Capture = @Sendable (_ destination: URL) async throws -> Void

    public let udid: String
    public let frames = FrameStore()
    public let transport: MirrorTransport

    /// One capture a second at most.
    public static let defaultInterval: Duration = .seconds(1)
    /// A screen that is off makes simctl wait 61 s; a capture gives up
    /// sooner and is tried again.
    public static let captureTimeout: Duration = .seconds(10)

    private let capture: Capture
    private let interval: Duration
    /// What a failed capture is called in `lastError` ("Simulator
    /// screenshot": simctl's; a physical device's polling names its own).
    private let failureLabel: String
    private let clock = ContinuousClock()
    private let state = Mutex(State())

    private struct State {
        var generation: UInt64 = 0
        var running = false
        var lastError: String?
        /// Views showing the session's frames.
        var viewers = 0
        /// The poll, waiting for a viewer.
        var wake: CheckedContinuation<Void, Never>?
        var task: Task<Void, Never>?
        var seq: UInt32 = 0
        var captures = 0
        var published = 0
        var captureMillisecondsSum = 0.0
        var recentPublishes: [ContinuousClock.Instant] = []
    }

    /// Polls `udid` through `simctl`, bounded by `captureTimeout`.
    public convenience init(udid: String, simctl: SimctlClient, interval: Duration = defaultInterval) {
        self.init(udid: udid, interval: interval) { destination in
            try await simctl.screenshot(udid: udid, to: destination, timeout: SimulatorScreenshotSession.captureTimeout)
        }
    }

    /// Test seam: any capture (a fixture copier), any interval.
    public init(
        udid: String,
        interval: Duration = defaultInterval,
        transport: MirrorTransport = .simulatorScreenshots,
        failureLabel: String = "Simulator screenshot",
        capture: @escaping Capture
    ) {
        self.udid = udid
        self.interval = interval
        self.transport = transport
        self.failureLabel = failureLabel
        self.capture = capture
    }

    deinit {
        stop()
    }

    public var lastError: String? {
        state.withLock { $0.lastError }
    }

    public var isRunning: Bool {
        state.withLock { $0.running }
    }

    /// The measured gap between the last publishes, from the newest eight
    /// (nil before two pictures arrived): the cadence a view-only stage shows
    /// instead of a promised one.
    public var measuredInterval: Duration? {
        state.withLock { state in
            let times = state.recentPublishes
            guard times.count >= 2, let first = times.first, let last = times.last else { return nil }
            return first.duration(to: last) / (times.count - 1)
        }
    }

    /// Whether a view shows the session, so it captures.
    public var isShown: Bool {
        state.withLock { $0.viewers > 0 }
    }

    /// Captures taken since the last start, failed ones included.
    public var captureCount: Int {
        state.withLock { $0.captures }
    }

    // MARK: - Lifecycle

    public func start() {
        stop()
        let generation = state.withLock { state -> UInt64 in
            state.generation &+= 1
            state.running = true
            state.lastError = nil
            state.captures = 0
            state.published = 0
            state.captureMillisecondsSum = 0
            state.recentPublishes = []
            return state.generation
        }
        let task = Task.detached(priority: .utility) { [weak self] () -> Void in
            guard let self else { return }
            await self.poll(generation: generation)
        }
        let kept = state.withLock { state -> Bool in
            guard state.running, state.generation == generation else { return false }
            state.task = task
            return true
        }
        if !kept { task.cancel() }
    }

    public func stop() {
        let (task, wake) = state.withLock { state -> (Task<Void, Never>?, CheckedContinuation<Void, Never>?) in
            state.generation &+= 1
            state.running = false
            let task = state.task
            state.task = nil
            let wake = state.wake
            state.wake = nil
            return (task, wake)
        }
        task?.cancel()
        wake?.resume()
    }

    /// A view that draws the session's frames appeared (`true`) or went away
    /// (`false`). Calls pair up; the poll runs while at least one view shows
    /// the session.
    public func setShown(_ shown: Bool) {
        let wake = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.viewers = max(0, state.viewers + (shown ? 1 : -1))
            guard state.viewers > 0 else { return nil }
            let wake = state.wake
            state.wake = nil
            return wake
        }
        wake?.resume()
    }

    // MARK: - Polling

    private func isCurrent(_ generation: UInt64) -> Bool {
        state.withLock { $0.running && $0.generation == generation }
    }

    private func poll(generation: UInt64) async {
        var lastStart: ContinuousClock.Instant?
        while isCurrent(generation) {
            await waitUntilShown(generation: generation)
            guard isCurrent(generation) else { return }
            if let lastStart {
                let due = lastStart.advanced(by: interval)
                if clock.now < due {
                    do {
                        try await Task.sleep(until: due, clock: clock)
                    } catch {
                        return
                    }
                }
                // Hidden meanwhile: wait for a viewer again.
                guard isCurrent(generation), isShown else { continue }
            }
            lastStart = clock.now
            await captureOnce(generation: generation)
        }
    }

    /// Returns at once while a view shows the session or it stopped;
    /// otherwise waits, without polling, until one of the two happens.
    private func waitUntilShown(generation: UInt64) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                guard state.running, state.generation == generation, state.viewers == 0 else { return true }
                state.wake = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    private func captureOnce(generation: UInt64) async {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceHubPro-view-\(UUID().uuidString).png")
        defer {
            // Best effort: a leftover temporary file is harmless.
            try? FileManager.default.removeItem(at: file)
        }
        let started = clock.now
        do {
            try await capture(file)
            guard let image = Self.rgbaImage(fromPNGAt: file) else {
                throw SimulatorScreenshotError.unreadableImage
            }
            let elapsed = started.duration(to: clock.now)
            let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            let seq = state.withLock { state -> UInt32? in
                guard state.running, state.generation == generation else { return nil }
                state.captures += 1
                state.published += 1
                state.captureMillisecondsSum += milliseconds
                state.seq &+= 1
                state.lastError = nil
                state.recentPublishes.append(clock.now)
                if state.recentPublishes.count > 8 { state.recentPublishes.removeFirst(state.recentPublishes.count - 8) }
                return state.seq
            }
            guard let seq else { return }
            frames.put(Frame(data: image.bytes, width: image.width, height: image.height, seq: seq))
        } catch let failure as SimctlFailure where failure.kind == .invalidState || failure.kind == .invalidDevice {
            // Shut down or deleted: nothing to show any more.
            state.withLock { state in
                guard state.running, state.generation == generation else { return }
                state.captures += 1
                state.running = false
                state.generation &+= 1
                state.lastError = SimulatorMirrorSession.shutDownMessage
                state.task = nil
            }
        } catch is CancellationError {
            return
        } catch {
            state.withLock { state in
                guard state.running, state.generation == generation else { return }
                state.captures += 1
                state.lastError = "\(failureLabel) failed: \((error as? SimctlFailure)?.message ?? "\(error)")"
            }
        }
    }

    /// The PNG decoded into straight RGBA8 rows (`Frame(data:)`'s layout),
    /// in sRGB, which is what simctl tags its screenshots with.
    static func rgbaImage(fromPNGAt url: URL) -> (bytes: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = Data(count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // An opaque screen: set the skipped alpha bytes to 255.
        bytes.withUnsafeMutableBytes { buffer in
            let pixels = buffer.bindMemory(to: UInt8.self)
            var index = 3
            while index < pixels.count {
                pixels[index] = 255
                index += 4
            }
        }
        return (bytes, width, height)
    }

    // MARK: - Session surface

    /// Captures now, while running, shown or not: the stage asks after a
    /// rotation so the new orientation shows without waiting for the poll.
    public func resync() async {
        let generation = state.withLock { $0.running ? $0.generation : nil }
        guard let generation else { return }
        await captureOnce(generation: generation)
    }

    public func stats() async -> MirrorStats {
        let now = clock.now
        return state.withLock { state in
            let lastSecond = state.recentPublishes.filter { $0.duration(to: now) < .seconds(1) }.count
            return MirrorStats(
                fps: Double(lastSecond),
                totalFrames: state.published,
                dropped: 0,
                averageLatencyMs: state.published > 0 ? state.captureMillisecondsSum / Double(state.published) : 0
            )
        }
    }

    /// View only: touches and keys never reach the simulator.
    public func send(_ command: TouchCommand) {}

    public func send(contacts: [TouchCommand]) {}

    public func send(_ command: KeyboardCommand) {}
}

/// A view-only capture that could not be used.
public enum SimulatorScreenshotError: Error, Equatable, CustomStringConvertible {
    /// simctl wrote no PNG the app could decode.
    case unreadableImage

    public var description: String {
        switch self {
        case .unreadableImage: return "the screenshot could not be read"
        }
    }
}
