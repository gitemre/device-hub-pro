import DeviceHubProNativeMirror
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Synchronization

// The opt-in native live view of a physical iPhone (AGENTS.md, "Private APIs and kill switches"): the frames of the CoreDevice
// media stream, no Camera permission. View only; the stream code is the
// vendored `DeviceHubProNativeMirror` target, behind `NativeMirroring` here so no
// test reaches it.

/// A failure of the native stream, with the ObjC layer's code.
public struct NativeMirrorError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    /// The tunnel is not up yet (`AQNativeMirrorErrorTunnelDown`): retried.
    public static let tunnelDownCode = 4000
    public var isTunnelDown: Bool { code == Self.tunnelDownCode }
    public var description: String { message }
}

/// One started-or-not native stream.
public protocol NativeMirroring: AnyObject, Sendable {
    /// Negotiates and starts; throws `NativeMirrorError`.
    func start() async throws
    func stop()
}

/// Makes a stream for an endpoint; frames and later errors come through the closures.
public typealias NativeMirrorStreamFactory = @Sendable (
    _ endpoint: NativeMirrorEndpoint,
    _ onFrame: @escaping @Sendable (CVPixelBuffer, CGRect) -> Void,
    _ onError: @escaping @Sendable (NativeMirrorError) -> Void
) -> any NativeMirroring

/// The real stream, over `AQNativeMirrorSession`.
final class LiveNativeMirroring: NativeMirroring, @unchecked Sendable {
    private let session: AQNativeMirrorSession

    init(endpoint: NativeMirrorEndpoint, onFrame: @escaping @Sendable (CVPixelBuffer, CGRect) -> Void,
         onError: @escaping @Sendable (NativeMirrorError) -> Void) {
        session = AQNativeMirrorSession(
            coreDeviceUUID: endpoint.coreDeviceIdentifier,
            utun: endpoint.interface,
            hostIP: endpoint.hostAddress,
            deviceIP: endpoint.deviceAddress,
            productType: endpoint.productType
        )
        session.frameHandler = { frame, rect in onFrame(frame, rect) }
        session.errorHandler = { error in
            onError(NativeMirrorError(code: (error as NSError).code, message: error.localizedDescription))
        }
    }

    func start() async throws {
        let session = session
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.start { error in
                if let error {
                    continuation.resume(throwing: NativeMirrorError(code: (error as NSError).code, message: error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func stop() { session.stop() }
}

/// A live, view-only mirror of one iPhone over the CoreDevice media stream:
/// each frame is cropped to the screen (the encoder pads it) and published into
/// a `FrameStore` like the capture session's, upright for the phone's
/// orientation (a frame size change is the phone turning).
///
/// `start()` returns at once; the tunnel lease, the endpoint and the stream come
/// up on a task, and a failure lands in `lastError` (the controller then falls
/// back to the public capture). While the tunnel is not up yet the start is
/// retried a few times. Any stream error or a 12 s stall ends the session.
public final class PhysicalNativeMirrorSession: MirrorSessionProtocol, PhysicalViewSession, @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var tunnelAttempts = 6
        public var tunnelRetryDelay: Duration = .milliseconds(1500)
        public init() {}
    }

    public let hardwareUDID: String
    public let inputRoute = PhysicalInputRoute()
    public let frames = FrameStore()
    public var transport: MirrorTransport { .physicalNativeMirror }
    public var viewKind: PhysicalViewKind { .nativeLive }

    private let endpointProvider: @Sendable () async throws -> NativeMirrorEndpoint
    private let lease: any FastInputLease
    private let makeStream: NativeMirrorStreamFactory
    private let configuration: Configuration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let orientationTracker: PhysicalInterfaceOrientationTracker?
    private let cropper = NativeMirrorFrameCropper()
    private let rgbaPool = RGBAFramePool()
    private let clock = ContinuousClock()
    private let state = Mutex(State())

    private struct State {
        var generation: UInt64 = 0
        var running = false
        var lastError: String?
        var stream: (any NativeMirroring)?
        var task: Task<Void, Never>?
        var seq: UInt32 = 0
        var published = 0
        var recentPublishes: [ContinuousClock.Instant] = []
    }

    public init(
        hardwareUDID: String,
        endpointProvider: @escaping @Sendable () async throws -> NativeMirrorEndpoint,
        lease: any FastInputLease,
        makeStream: @escaping NativeMirrorStreamFactory,
        configuration: Configuration = Configuration(),
        orientationTracker: PhysicalInterfaceOrientationTracker? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = FastInputClock.sleep
    ) {
        self.orientationTracker = orientationTracker
        self.hardwareUDID = hardwareUDID
        self.endpointProvider = endpointProvider
        self.lease = lease
        self.makeStream = makeStream
        self.configuration = configuration
        self.sleep = sleep
    }

    deinit { stop() }

    public var lastError: String? { state.withLock { $0.lastError } }
    public var isRunning: Bool { state.withLock { $0.running } }

    // MARK: Lifecycle

    /// Single use: a session that ran (or is running) does not start again, and
    /// the controller makes a new one.
    public func start() {
        let generation = state.withLock { state -> UInt64? in
            guard !state.running, state.generation == 0 else { return nil }
            state.generation &+= 1
            state.running = true
            state.lastError = nil
            state.published = 0
            state.recentPublishes = []
            return state.generation
        }
        guard let generation else { return }
        orientationTracker?.start()
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.bringUp(generation: generation)
        }
        state.withLock { if $0.generation == generation { $0.task = task } else { task.cancel() } }
    }

    public func stop() {
        orientationTracker?.stop()
        let taken = state.withLock { state -> (any NativeMirroring, Task<Void, Never>?)? in
            state.generation &+= 1
            state.running = false
            let stream = state.stream, task = state.task
            state.stream = nil
            state.task = nil
            task?.cancel()
            return stream.map { ($0, task) }
        }
        taken?.0.stop()
        let lease = lease
        Task { await lease.stop() }
    }

    /// Stops and waits for the lease's child to end: the app's quit.
    public func stopAndWait(timeout: TimeInterval) {
        stop()
        lease.terminateNow()
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        state.withLock { $0.running && $0.generation == generation }
    }

    private func bringUp(generation: UInt64) async {
        do {
            try await lease.start()
            var attempt = 0
            while true {
                attempt += 1
                guard isCurrent(generation) else { return }
                do {
                    let endpoint = try await endpointProvider()
                    let stream = makeStream(
                        endpoint,
                        { [weak self] frame, rect in self?.didReceive(frame, rect: rect, generation: generation) },
                        { [weak self] error in self?.fail(error.message, generation: generation) }
                    )
                    let kept = state.withLock { state -> Bool in
                        guard state.running, state.generation == generation else { return false }
                        state.stream = stream
                        return true
                    }
                    guard kept else { stream.stop(); return }
                    try await stream.start()
                    return
                } catch {
                    let retryable = (error as? NativeMirrorError)?.isTunnelDown == true
                        || (error as? NativeMirrorEndpoint.ResolveError) == .noHostInterface
                        || (error as? NativeMirrorEndpoint.ResolveError) == .noTunnelAddress
                    guard retryable, attempt < configuration.tunnelAttempts else { throw error }
                    let ending = state.withLock { state -> (any NativeMirroring)? in
                        defer { state.stream = nil }
                        return state.stream
                    }
                    ending?.stop()
                    try await sleep(configuration.tunnelRetryDelay)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            fail("\(error)", generation: generation)
        }
    }

    private func fail(_ message: String, generation: UInt64) {
        let stream = state.withLock { state -> (any NativeMirroring)?? in
            guard state.running, state.generation == generation else { return nil }
            state.running = false
            state.generation &+= 1
            state.lastError = message
            let stream = state.stream
            state.stream = nil
            state.task?.cancel()
            state.task = nil
            return .some(stream)
        }
        guard let stream else { return }
        stream?.stop()
        let lease = lease
        Task { await lease.stop() }
    }

    // MARK: Frames

    /// The last decoded frame's size before cropping, and the crop rect (for
    /// the live tests and diagnostics: the stream's orientation handling).
    public var lastRawFrame: (size: CGSize, crop: CGRect)? { rawFrame.withLock { $0 } }
    private let rawFrame = Mutex<(size: CGSize, crop: CGRect)?>(nil)

    /// Measurement hooks for the live latency tests: each raw decoded frame with
    /// its arrival instant (before cropping), each published frame right after it
    /// entered the store, and the cropper's time per frame. Not used by the app.
    struct Diagnostics: Sendable {
        var onRaw: @Sendable (CVPixelBuffer, CGRect, ContinuousClock.Instant) -> Void = { _, _, _ in }
        var onPublished: @Sendable (CVPixelBuffer, ContinuousClock.Instant) -> Void = { _, _ in }
        var onCrop: @Sendable (Duration) -> Void = { _ in }
        init() {}
    }
    private let diagnosticsBox = Mutex<Diagnostics?>(nil)
    var diagnostics: Diagnostics? {
        get { diagnosticsBox.withLock { $0 } }
        set { diagnosticsBox.withLock { $0 = newValue } }
    }

    private func didReceive(_ buffer: CVPixelBuffer, rect: CGRect, generation: UInt64) {
        let arrival = clock.now
        let diagnostics = diagnostics
        diagnostics?.onRaw(buffer, rect, arrival)
        rawFrame.withLock { $0 = (CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)), rect) }
        // The stream is always the portrait panel (measured, PhysicalInterfaceOrientationTracker):
        // it turns with the stage's frame (the device pose, as Device Hub does). A stream that ever delivers a
        // landscape rect is already upright and is left alone.
        let stage = rect.height >= rect.width ? PhysicalStageRotation.rotation(for: orientationTracker?.stagePose) : .identity
        guard isCurrent(generation) else { return }
        let cropStart = clock.now
        guard let cropped = cropper.crop(buffer, to: rect, stage: stage) else { return }
        let now = clock.now
        diagnostics?.onCrop(cropStart.duration(to: now))
        let seq = state.withLock { state -> UInt32? in
            guard state.running, state.generation == generation else { return nil }
            state.seq &+= 1
            state.published += 1
            state.recentPublishes.append(now)
            if state.recentPublishes.count > 120 {
                state.recentPublishes.removeFirst(state.recentPublishes.count - 120)
            }
            return state.seq
        }
        guard let seq else { return }
        let pool = rgbaPool
        frames.put(Frame(pixelBuffer: cropped, seq: seq) { PhysicalMirrorSession.rgbaFrame(from: $0, pool: pool)?.data })
        diagnostics?.onPublished(cropped, clock.now)
    }

    // MARK: Session surface

    public func resync() async {}

    public func stats() async -> MirrorStats {
        let now = clock.now
        return state.withLock { state in
            let lastSecond = state.recentPublishes.filter { $0.duration(to: now) < .seconds(1) }.count
            return MirrorStats(fps: Double(lastSecond), totalFrames: state.published, dropped: 0, averageLatencyMs: 0)
        }
    }

    public func send(_ command: TouchCommand) { inputRoute.receive(contacts: [command]) }
    public func send(contacts: [TouchCommand]) { inputRoute.receive(contacts: contacts) }
    public func send(_ command: KeyboardCommand) { inputRoute.receive(command) }
    public var acceptsPhysicalKeys: Bool { inputRoute.acceptsPhysicalKeys }
    public func send(physical event: PhysicalKeyEvent) { inputRoute.receive(physical: event) }
    public func send(button: SimulatorHardwareButton, isDown: Bool) { inputRoute.receive(button: button, isDown: isDown) }
    public var acceptsButtons: Bool { inputRoute.acceptsButtons }

    public var stagePose: PhysicalControlOrientation? { orientationTracker?.stagePose }
    public var interfaceIsLandscape: Bool { orientationTracker?.interfaceIsLandscape ?? false }
    public func observeStagePose(_ handler: @escaping @Sendable () -> Void) {
        orientationTracker?.observe(handler)
    }
    public func noteTurn(to pose: PhysicalControlOrientation) async {
        await orientationTracker?.noteTurn(to: pose)
    }
}

/// What a live session needs of the phone, made when the session starts (the
/// inventory's client and the toolchain come from async reads).
final class NativeMirrorPreparation: @unchecked Sendable {
    typealias Made = (client: DevicectlPhysicalClient, lease: any FastInputLease)
    private let prepare: @Sendable () async throws -> (DevicectlPhysicalClient, AppleToolchain)
    private let made = Mutex<Made?>(nil)

    init(prepare: @escaping @Sendable () async throws -> (DevicectlPhysicalClient, AppleToolchain)) {
        self.prepare = prepare
    }

    var current: Made? { made.withLock { $0 } }

    func ensure() async throws -> Made {
        if let current { return current }
        let (client, toolchain) = try await prepare()
        // One tunnel lease per phone, shared with fast input.
        let devicectlURL = client.devicectlURL
        let identifier = client.device.coreDeviceIdentifier
        let developerDirectory = toolchain.developerDirectory
        let lease = SharedTunnelLeases.shared.lease(for: identifier) {
            TunnelLeaseKeeper(
                devicectlURL: devicectlURL,
                coreDeviceIdentifier: identifier,
                developerDirectory: developerDirectory,
                launcher: ProcessFastInputChildLauncher()
            )
        }
        return made.withLock { state in
            if let state { return state }
            state = (client, lease)
            return (client, lease)
        }
    }
}

/// The tunnel lease of a `NativeMirrorPreparation`, made on first use.
final class DeferredTunnelLease: FastInputLease, @unchecked Sendable {
    private let preparation: NativeMirrorPreparation
    init(_ preparation: NativeMirrorPreparation) { self.preparation = preparation }
    func start() async throws { try await preparation.ensure().lease.start() }
    func stop() async { await preparation.current?.lease.stop() }
    func terminateNow() { preparation.current?.lease.terminateNow() }
}

extension PhysicalNativeMirrorSession {
    /// The real session for a phone: endpoint from `device info details` and this
    /// Mac's interfaces, the tunnel lease from `TunnelLeaseKeeper`, the stream from
    /// the vendored target. `prepare` runs when the session starts. Throws
    /// `.disabled` under the kill switch.
    public static func live(
        hardwareUDID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        prepare: @escaping @Sendable () async throws -> (DevicectlPhysicalClient, AppleToolchain)
    ) throws -> PhysicalNativeMirrorSession {
        guard !NativeMirrorEndpoint.isDisabled(environment: environment) else {
            throw NativeMirrorEndpoint.ResolveError.disabled
        }
        let preparation = NativeMirrorPreparation(prepare: prepare)
        let tracker = PhysicalInterfaceOrientationTracker(reads: .init(
            deviceOrientation: {
                let name = try await preparation.ensure().client.orientation().value.deviceOrientation
                return name.flatMap(PhysicalControlOrientation.init(rawValue:)) ?? .unknown
            },
            screenshotSize: {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("aqa-interface-\(UUID().uuidString).png")
                defer { try? FileManager.default.removeItem(at: url) }
                _ = try await preparation.ensure().client.screenshot(to: url)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int
                else { throw NativeMirrorError(code: 0, message: "no screenshot size") }
                return CGSize(width: width, height: height)
            }
        ))
        return PhysicalNativeMirrorSession(
            hardwareUDID: hardwareUDID,
            endpointProvider: {
                let details = try await preparation.ensure().client.details().value
                return try NativeMirrorEndpoint.resolve(details: details, interfaces: NativeMirrorEndpoint.currentHostAddresses())
            },
            lease: DeferredTunnelLease(preparation),
            makeStream: { endpoint, onFrame, onError in
                LiveNativeMirroring(endpoint: endpoint, onFrame: onFrame, onError: onError)
            },
            orientationTracker: tracker
        )
    }
}
