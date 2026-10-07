import Foundation
import GRPCCore
import GRPCProtobuf

/// Owns a mirror session against one emulator: the video stream (MMAP when
/// the emulator supports it, raw frames otherwise) and the input streams.
///
/// The video stream reconnects by itself with capped backoff until `stop()`;
/// its failures land in `lastError` while `isStreaming` is false. Every
/// `start()` builds fresh input streams, so a session can be restarted. The
/// session's tasks never capture the session itself: dropping it without
/// calling `stop()` still ends them (deinit stops the run).
public final class MirrorSession: MirrorSessionProtocol, @unchecked Sendable {
    public let port: Int
    /// The emulator display to stream and send input to (0 = main).
    public let display: UInt32
    public let frames = FrameStore()

    private let statsCounter = StreamStatsCounter()
    private let runLock = NSLock()
    private var run: Run?
    /// One per `start()`, so a stopped run's task that is still winding down
    /// cannot report into the next run. Kept after `stop()` for `lastError`.
    private var _status = SessionStatus()

    /// The multitouch pressure Android Studio's emulator window sends (the
    /// goldfish multitouch range is 0...0x400); pressure 1 read as a hairline
    /// in pressure-sensitive apps.
    static let touchPressure: Int32 = 0x400

    /// Largest frame the MMAP buffer holds (a 2076×2152 RGBA frame is ~18 MB);
    /// a bigger display falls back to raw frames.
    static let mappingSize = 64 * 1024 * 1024

    /// Backoff between video reconnects: the physical path's
    /// `ReconnectPolicy` shape, capped at a few seconds because an emulator
    /// restarting its stream (snapshot load) is back quickly.
    static let reconnectPolicy = ReconnectPolicy(
        delays: [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(4)],
        maxAttempts: 5
    )

    private let touchSender: MirrorInput.Sender
    private let hardwareKeySender: HardwareKeySender
    /// The keyboard queue's emulator sends; nil for the real ones
    /// (`KeyboardSender.grpc`).
    private let keyboardSender: KeyboardSender?
    /// Where keys go when the guest has no keyboard device for the
    /// emulator's (`EmulatorKeyRoute`); nil keeps every key on the emulator.
    let adbFallback: AdbInputFallback?
    private let adbKeyInput: AdbKeyInput?
    private let adbKeyTiming: AdbHardwareKeys.Timing

    /// Every key goes to the emulator's keyboard, as it always did: an AVD
    /// without one (`hw.keyboard=no`) presses and types nothing. Prefer
    /// `init(port:display:adbFallback:)` where adb is at hand.
    public convenience init(port: Int, display: UInt32 = 0) {
        self.init(port: port, display: display, touchSender: MirrorInput.sendOverGRPC)
    }

    /// Like `init(port:display:)`, and each run asks the guest, as it
    /// starts, whether the emulator's keyboard takes the side buttons and
    /// the typing (`getevent -lp` over `adbFallback`,
    /// `EmulatorKeyRouteProbe`); what it does not take, that run presses or
    /// types through `adb shell input` instead (`EmulatorKeyRoute.adbInput`).
    public convenience init(port: Int, display: UInt32 = 0, adbFallback: AdbInputFallback) {
        self.init(
            port: port,
            display: display,
            touchSender: MirrorInput.sendOverGRPC,
            adbFallback: adbFallback,
            adbKeyInput: adbFallback.keyInput
        )
    }

    /// Test seam: touch frames go to `touchSender`, hardware keys to
    /// `hardwareKeySender` and keyboard commands to `keyboardSender` (the
    /// emulator when nil) instead of the emulator; with `adbKeyInput` the
    /// runs pick their key route from it (`adbFallback` is only kept).
    init(
        port: Int,
        display: UInt32 = 0,
        touchSender: @escaping MirrorInput.Sender,
        hardwareKeySender: HardwareKeySender? = nil,
        keyboardSender: KeyboardSender? = nil,
        adbFallback: AdbInputFallback? = nil,
        adbKeyInput: AdbKeyInput? = nil,
        adbKeyTiming: AdbHardwareKeys.Timing = .android
    ) {
        self.port = port
        self.display = display
        self.touchSender = touchSender
        self.hardwareKeySender = hardwareKeySender ?? .grpc(port: port)
        self.keyboardSender = keyboardSender
        self.adbFallback = adbFallback
        self.adbKeyInput = adbKeyInput
        self.adbKeyTiming = adbKeyTiming
    }

    deinit {
        run?.stop()
    }

    private var status: SessionStatus {
        runLock.lock()
        defer { runLock.unlock() }
        return _status
    }

    public var transport: MirrorTransport { status.transport }

    public var lastError: String? { status.lastError }

    /// True from `start()` until `stop()`. The emulator stream never stops
    /// itself: it keeps reconnecting and reports through `lastError` and
    /// `isStreaming`.
    public var isRunning: Bool {
        runLock.lock()
        defer { runLock.unlock() }
        return run != nil
    }

    /// Whether the current stream attempt is delivering frames; false while
    /// the session reconnects after an error or an ended stream.
    public var isStreaming: Bool { status.isStreaming }

    /// Stream attempts since `start()` (test seam).
    var videoAttempts: Int { status.videoAttempts }

    /// Protocol witness for ``MirrorSessionProtocol/start()``: MMAP when the
    /// emulator supports it, raw frames otherwise.
    public func start() {
        start(forceRaw: false, allowMMAP: true)
    }

    /// Whether the current run may negotiate MMAP (test seam).
    var mmapAllowed: Bool? {
        runLock.lock()
        defer { runLock.unlock() }
        return run?.allowsMMAP
    }

    /// Starts (or restarts) the session.
    ///
    /// MMAP is the default: through the app it streams 60 fps with no drops
    /// at 13.5 % CPU where raw frames manage 32 fps, 18 % drops and 41 % CPU
    /// (docs/performance.md). It is used when allowed (`MMAPPolicy`:
    /// `DHP_DISABLE_MMAP=1` turns it off, `DHP_FORCE_MMAP=1` turns it
    /// on even for `allowMMAP: false`) and the emulator is 37.2.3 or newer
    /// (older engines crash on it, issue #537802959). The mapped
    /// buffer is unsynchronized (`ImageTransport`: "the mmap can result in
    /// tearing"), so the first frame and every geometry change come from a
    /// consistent snapshot and a watchdog repairs a torn frame left on a
    /// static screen. Any MMAP failure — the file, the handle, an emulator
    /// that never writes the buffer, a frame too big for it, streams that
    /// keep ending before a written mapped frame (`MirrorVideo.RetryState`) —
    /// falls back to raw frames for the rest of the session.
    public func start(forceRaw: Bool = false, allowMMAP: Bool = true) {
        stop()

        let status = SessionStatus()
        let context = VideoContext(
            port: port,
            display: display,
            frames: frames,
            stats: statsCounter,
            status: status,
            allowMMAP: MMAPPolicy.isAllowed(requested: allowMMAP, forceRaw: forceRaw)
        )
        let newRun = Run(
            context: context,
            touchSender: touchSender,
            hardwareKeySender: hardwareKeySender,
            keyboardSender: keyboardSender,
            adbKeyInput: adbKeyInput,
            adbKeyTiming: adbKeyTiming
        )
        runLock.lock()
        _status = status
        run = newRun
        runLock.unlock()
    }

    /// Stops the session: the video stream and its connection close, the frame
    /// file is removed, the touch queue drains (lifting any contact still
    /// held down), the keyboard queue drops its queued keys, putting back
    /// a clipboard a paste borrowed, and the hardware-key queue drops its
    /// queued presses but still sends its releases and releases every key
    /// left held, before they end. Idempotent.
    public func stop() {
        runLock.lock()
        let old = run
        run = nil
        runLock.unlock()
        old?.stop()
        status.streamStopped()
    }

    /// Repaints from a consistent screenshot; used right after display changes
    /// (rotate/posture) that can tear the mapped buffer. The screenshot only
    /// replaces the frame that was newest when it was requested — a stream
    /// frame that arrives meanwhile is newer and wins.
    public func resync() async {
        let generation = frames.currentGeneration
        let display = self.display
        let snapshot: Frame? = try? await EmulatorControl.withSharedClient(port: port, retryOnStaleConnection: true) { controller in
            await Self.consistentFrame(controller: controller, display: display)
        }
        guard let snapshot else { return }
        frames.put(snapshot, ifGeneration: generation)
    }

    public func stats() async -> MirrorStats {
        await statsCounter.snapshot()
    }

    public func send(_ command: TouchCommand) {
        currentRun?.touches.yield([translated(command)])
    }

    /// Sends multiple contacts as a single input frame (pinch/zoom, rotates).
    /// Coordinates are in the logical frame; the device rotation is undone for
    /// each contact.
    public func send(contacts: [TouchCommand]) {
        currentRun?.touches.yield(contacts.map(translated))
    }

    public func send(_ command: KeyboardCommand) {
        currentRun?.keys.yield(.command(command))
    }

    /// The emulator presses and releases power and volume through its own
    /// key queue (`HardwareKeyInjector`); on a guest without its keyboard,
    /// adb stands in (`AdbHardwareKeys`).
    public var supportsHardwareKeys: Bool { true }

    public func send(_ event: HardwareKeyEvent) {
        currentRun?.hardwareKeys.yield(event)
    }

    private var currentRun: Run? {
        runLock.lock()
        defer { runLock.unlock() }
        return run
    }

    /// Input views produce frame coordinates (the frame is shown as streamed);
    /// the emulator wants coordinates in the display's upright orientation, so
    /// the frame's physical rotation is undone here.
    private func translated(_ command: TouchCommand) -> TouchCommand {
        guard let frame = frames.current else { return command }
        let point = TouchMapping.nativePoint(
            x: Int(command.x),
            y: Int(command.y),
            frameWidth: frame.width,
            frameHeight: frame.height,
            rotation: frame.rotation
        )
        return TouchCommand(
            phase: command.phase,
            x: Int32(point.x),
            y: Int32(point.y),
            id: command.id
        )
    }

    // MARK: - Run

    /// Everything one `start()` owns. The tasks capture only what they need —
    /// never the session — so the session's deinit can end them.
    private final class Run: Sendable {
        let touches: AsyncStream<[TouchCommand]>.Continuation
        let keys: AsyncStream<KeyboardInjector.Step>.Continuation
        let hardwareKeys: AsyncStream<HardwareKeyEvent>.Continuation
        let allowsMMAP: Bool
        private let video: Task<Void, Never>
        private let keysStop = KeyboardInjector.StopSignal()
        private let hardwareKeysStop = KeyboardInjector.StopSignal()

        init(
            context: VideoContext,
            touchSender: @escaping MirrorInput.Sender,
            hardwareKeySender: HardwareKeySender,
            keyboardSender: KeyboardSender?,
            adbKeyInput: AdbKeyInput?,
            adbKeyTiming: AdbHardwareKeys.Timing
        ) {
            let (touchStream, touches) = AsyncStream<[TouchCommand]>.makeStream()
            let (keyStream, keys) = AsyncStream<KeyboardInjector.Step>.makeStream()
            let (hardwareKeyStream, hardwareKeys) = AsyncStream<HardwareKeyEvent>.makeStream()
            self.touches = touches
            self.keys = keys
            self.hardwareKeys = hardwareKeys
            self.allowsMMAP = context.allowMMAP

            video = Task.detached {
                await MirrorVideo.run(context)
            }

            let port = context.port
            let display = context.display
            let status = context.status
            let keysStop = self.keysStop
            let hardwareKeysStop = self.hardwareKeysStop

            // The key routes are read from the guest as the run starts and
            // kept for the run; without adb every key stays on the emulator.
            var routedHardwareKeys = hardwareKeySender
            var routedKeyboard = keyboardSender
            if let adbKeyInput {
                let probe = EmulatorKeyRouteProbe(readInputDevices: adbKeyInput.readInputDevices)
                probe.prefetch()
                let adbKeys = AdbHardwareKeys(
                    press: { key, longPress in
                        try await adbKeyInput.run(AdbHardwareKeys.arguments(for: key, longPress: longPress))
                    },
                    stopSignal: hardwareKeysStop,
                    timing: adbKeyTiming,
                    reportError: { status.inputFailed("hardware key: \($0)") }
                )
                routedHardwareKeys = .routed(
                    emulatorKeyboard: hardwareKeySender,
                    adb: .adb(adbKeys),
                    route: { await probe.routes().sideButtons }
                )
                let emulatorKeyboard = keyboardSender ?? .grpc(port: port)
                routedKeyboard = .routed(
                    emulatorKeyboard: emulatorKeyboard,
                    adb: .adb(run: adbKeyInput.run, readSdkLevel: adbKeyInput.readSdkLevel, clipboard: emulatorKeyboard),
                    route: { await probe.routes().typing }
                )
            }
            let hardwareKeySender = routedHardwareKeys
            let keyboardSender = routedKeyboard
            // The input tasks are not cancelled by `stop()`: finishing their
            // streams lets the touches drain and lift held contacts, the
            // keyboard skip its queued keys but restore a borrowed clipboard,
            // and the hardware keys skip their queued presses but release
            // every key still down.
            Task.detached {
                await MirrorInput.run(
                    port: port,
                    display: display,
                    contacts: touchStream,
                    send: touchSender,
                    reportError: { status.inputFailed($0) }
                )
            }
            Task.detached {
                await KeyboardInjector.run(
                    port: port,
                    steps: keyStream,
                    schedule: { keys.yield($0) },
                    reportError: { status.inputFailed($0) },
                    stopSignal: keysStop,
                    sender: keyboardSender
                )
            }
            Task.detached {
                await HardwareKeyInjector.run(
                    events: hardwareKeyStream,
                    stopSignal: hardwareKeysStop,
                    sender: hardwareKeySender,
                    reportError: { status.inputFailed($0) }
                )
            }
        }

        func stop() {
            touches.finish()
            keysStop.stop()
            keys.finish()
            hardwareKeysStop.stop()
            hardwareKeys.finish()
            video.cancel()
        }
    }

    // MARK: - Snapshots

    /// A one-shot screenshot: frames whose pixels always match their metadata,
    /// used to repair the unsynchronized MMAP buffer.
    static func consistentFrame(
        controller: EmulatorClient,
        display: UInt32
    ) async -> Frame? {
        let image: Android_Emulation_Control_Image? = try? await controller.getScreenshot(
            .with {
                $0.format = .rgba8888
                $0.display = display
            },
            options: .emulatorFrames
        )
        guard
            let image,
            image.format.width > 0,
            image.format.height > 0,
            !image.image.isEmpty
        else {
            return nil
        }
        return Frame(
            data: image.image,
            width: Int(image.format.width),
            height: Int(image.format.height),
            seq: image.seq,
            rotation: Int(image.format.rotation.rotation.rawValue)
        )
    }
}

// MARK: - Session state

/// The session's observable state, shared with its tasks.
final class SessionStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var _transport: MirrorTransport = .raw
    private var videoError: String?
    private var inputError: String?
    private var streaming = false
    private var attempts = 0

    /// Stream attempts since `start()` (test seam for the reconnect loop).
    var videoAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func attemptStarted() {
        lock.lock()
        attempts += 1
        lock.unlock()
    }

    var transport: MirrorTransport {
        lock.lock()
        defer { lock.unlock() }
        return _transport
    }

    /// The video failure while the stream is down, else the last input error.
    var lastError: String? {
        lock.lock()
        defer { lock.unlock() }
        return videoError ?? inputError
    }

    var isStreaming: Bool {
        lock.lock()
        defer { lock.unlock() }
        return streaming
    }

    func setTransport(_ value: MirrorTransport) {
        lock.lock()
        _transport = value
        lock.unlock()
    }

    /// A frame arrived: the stream is live and any reconnect error is over.
    func frameDelivered() {
        lock.lock()
        streaming = true
        videoError = nil
        lock.unlock()
    }

    func videoFailed(_ message: String) {
        lock.lock()
        streaming = false
        videoError = message
        lock.unlock()
    }

    func streamStopped() {
        lock.lock()
        streaming = false
        lock.unlock()
    }

    func inputFailed(_ message: String) {
        lock.lock()
        inputError = message
        lock.unlock()
    }
}

// MARK: - Input

enum MirrorInput {
    /// Delivers one input frame (all contacts move together) to a port and
    /// display.
    typealias Sender = @Sendable (_ contacts: [TouchCommand], _ port: Int, _ display: UInt32) async throws -> Void

    /// Forwards touch frames until the stream finishes, then lifts every
    /// contact still down: a contact whose up was lost (the view went away
    /// mid-drag) would otherwise stay pressed, and the next tap with that id
    /// would arrive as a move from the stale point.
    static func run(
        port: Int,
        display: UInt32,
        contacts: AsyncStream<[TouchCommand]>,
        send: Sender = sendOverGRPC,
        reportError: @escaping @Sendable (String) -> Void
    ) async {
        var held: [Int32: TouchCommand] = [:]
        for await frame in contacts {
            guard !frame.isEmpty else { continue }
            for contact in frame {
                if contact.phase == .up {
                    held[contact.id] = nil
                } else {
                    held[contact.id] = contact
                }
            }
            do {
                try await send(frame, port, display)
            } catch {
                reportError("input: \(error)")
            }
        }

        let released = held.values
            .sorted { $0.id < $1.id }
            .map { TouchCommand(phase: .up, x: $0.x, y: $0.y, id: $0.id) }
        if !released.isEmpty {
            try? await send(released, port, display)
        }
    }

    /// The emulator-side contact. Expiration stays at the default (a slot
    /// idle for 120 s is released by the emulator) instead of `neverExpire`,
    /// which would pin a slot forever if its release were lost.
    static func touch(for contact: TouchCommand) -> Android_Emulation_Control_Touch {
        .with {
            $0.x = contact.x
            $0.y = contact.y
            $0.identifier = contact.id
            $0.pressure = contact.phase == .up ? 0 : MirrorSession.touchPressure
        }
    }

    static let sendOverGRPC: Sender = { contacts, port, display in
        let event = Android_Emulation_Control_TouchEvent.with {
            $0.touches = contacts.map(touch(for:))
            $0.display = Int32(display)
        }
        try await EmulatorControl.withSharedClient(port: port) { controller in
            _ = try await controller.sendTouch(event, options: .controls)
        }
    }
}

// MARK: - Video

struct VideoContext: Sendable {
    let port: Int
    let display: UInt32
    let frames: FrameStore
    let stats: StreamStatsCounter
    let status: SessionStatus
    let allowMMAP: Bool
}

enum MirrorVideo {
    /// Why an MMAP attempt cannot go on; the session switches to raw frames.
    struct MMAPUnavailable: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    /// How one stream attempt ended.
    enum Outcome {
        case cancelled
        /// The emulator closed the stream (shutdown, snapshot load).
        case ended
        case failed(Error)
        /// MMAP never worked on this emulator; retry with raw frames.
        case mmapUnavailable(String)
    }

    /// Counters one attempt shares with its stream handler.
    final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var _delivered = 0
        private var _streamed = 0
        private var _mmapVerified = false
        private var _unwrittenFrames = 0

        /// Every frame the attempt stored, snapshots included.
        var delivered: Int { lock.withLock { _delivered } }
        /// Frames from the stream itself: raw frames and written mapped
        /// frames, not the consistent snapshots.
        var streamed: Int { lock.withLock { _streamed } }
        /// A mapped frame the emulator really wrote was read.
        var mmapVerified: Bool { lock.withLock { _mmapVerified } }

        /// A raw frame or a written mapped frame.
        func frameDelivered() {
            lock.withLock {
                _delivered += 1
                _streamed += 1
            }
        }

        /// A consistent snapshot (`getScreenshot`), which every MMAP attempt
        /// opens with: it shows the emulator answers, not that the stream or
        /// the mapped buffer works.
        func snapshotDelivered() { lock.withLock { _delivered += 1 } }

        func verifyMMAP() { lock.withLock { _mmapVerified = true } }

        /// Counts a mapped frame the emulator never wrote; returns the count.
        func unwrittenFrame() -> Int {
            lock.withLock {
                _unwrittenFrames += 1
                return _unwrittenFrames
            }
        }
    }

    /// Mapped frames that may stay unwritten before MMAP is given up on (an
    /// engine that accepts the handle but never writes it: issue #537802959
    /// on 37.2.1).
    static let unwrittenFrameLimit = 3

    /// The reconnect loop's decisions between attempts: whether the next
    /// one may use MMAP, and how many failures its backoff counts. Both are
    /// judged on evidence from the stream: every MMAP attempt opens with a
    /// consistent snapshot, and that proves neither that the stream works
    /// nor that the emulator writes the mapped buffer.
    struct RetryState {
        /// MMAP attempts in a row that reached the emulator but never read a
        /// written mapped frame, tolerated before the session settles on raw
        /// frames (a stream that ends on a static screen, before the screen
        /// changes, is one).
        static let unprovenMMAPAttemptLimit = 3

        /// Whether the next attempt may negotiate MMAP.
        private(set) var mmapCandidate: Bool
        /// Failed attempts since frames last streamed (the backoff step).
        private(set) var failures = 0
        /// Some attempt of this mirror session read a written mapped frame.
        private(set) var mmapProven = false
        private var unprovenMMAPAttempts = 0

        init(allowMMAP: Bool) {
            mmapCandidate = allowMMAP
        }

        /// The attempt could not create its connection.
        mutating func connectionFailed() {
            failures += 1
        }

        /// The emulator reported its build; a known-old engine stays old, so
        /// it is never asked again.
        mutating func engineChecked(supportsMMAP: Bool) {
            mmapCandidate = supportsMMAP
        }

        /// The attempt found MMAP unusable here (no frame file, a frame too
        /// big for it, a buffer the emulator never writes).
        mutating func mmapUnavailable() {
            mmapCandidate = false
        }

        /// A stream attempt ended or failed.
        mutating func streamStopped(usedMMAP: Bool, progress: Progress) {
            if usedMMAP, !keepsMMAP(progress) {
                mmapCandidate = false
            }
            // Only frames from the stream itself show it works; an attempt
            // that got no further than its opening snapshot backs off more.
            if progress.streamed > 0 {
                failures = 0
            }
            failures += 1
        }

        private mutating func keepsMMAP(_ progress: Progress) -> Bool {
            if progress.mmapVerified {
                mmapProven = true
                unprovenMMAPAttempts = 0
                return true
            }
            guard progress.delivered > 0 else {
                // Not even the snapshot: where MMAP never worked, the engine
                // refused the handle; where it did, the emulator is away (a
                // restart), which says nothing about MMAP.
                return mmapProven
            }
            unprovenMMAPAttempts += 1
            return unprovenMMAPAttempts < Self.unprovenMMAPAttemptLimit
        }
    }

    /// Streams until cancelled, reconnecting with capped backoff
    /// (`RetryState`).
    static func run(_ context: VideoContext) async {
        var state = RetryState(allowMMAP: context.allowMMAP)

        while !Task.isCancelled {
            context.status.attemptStarted()
            let connection: EmulatorConnection
            do {
                connection = try EmulatorConnection(
                    port: context.port,
                    token: EmulatorControl.token(forPort: context.port)
                )
            } catch {
                context.status.videoFailed("video: \(error)")
                state.connectionFailed()
                guard await backoff(state.failures) else { return }
                continue
            }

            var useMMAP = false
            if state.mmapCandidate {
                if let version = await emulatorVersion(connection.controller) {
                    useMMAP = EmulatorVersion.supportsMMAP(version)
                    state.engineChecked(supportsMMAP: useMMAP)
                }
            }

            let progress = Progress()
            let outcome = await attempt(context, connection: connection, useMMAP: useMMAP, progress: progress)
            connection.shutdown()

            switch outcome {
            case .cancelled:
                return
            case .mmapUnavailable(let reason):
                state.mmapUnavailable()
                context.status.setTransport(.raw)
                context.status.videoFailed("mmap: \(reason); using raw frames")
                continue
            case .ended, .failed:
                state.streamStopped(usedMMAP: useMMAP, progress: progress)
                if case .failed(let error) = outcome {
                    context.status.videoFailed("video: \(error)")
                } else {
                    context.status.videoFailed("video: the emulator ended the stream")
                }
                guard await backoff(state.failures) else { return }
            }
        }
    }

    /// Sleeps before reconnect `failures`; false when cancelled meanwhile.
    private static func backoff(_ failures: Int) async -> Bool {
        let policy = MirrorSession.reconnectPolicy
        let delay = policy.delay(attempt: min(failures, policy.maxAttempts)) ?? .seconds(4)
        do {
            try await Task.sleep(for: delay)
            return true
        } catch {
            return false
        }
    }

    /// The emulator build (for the MMAP gate), or nil when it did not answer
    /// within the control timeout.
    private static func emulatorVersion(_ controller: EmulatorClient) async -> String? {
        let status: Android_Emulation_Control_EmulatorStatus? = try? await controller.getStatus(
            .init(),
            options: .controls
        )
        return status?.version
    }

    private static func attempt(
        _ context: VideoContext,
        connection: EmulatorConnection,
        useMMAP: Bool,
        progress: Progress
    ) async -> Outcome {
        let mapping: MappedFile?
        if useMMAP {
            do {
                mapping = try MappedFile.makePrivate(
                    port: context.port,
                    display: context.display,
                    size: MirrorSession.mappingSize
                )
            } catch {
                return .mmapUnavailable("\(error)")
            }
        } else {
            mapping = nil
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await stream(context, connection: connection, mapping: mapping, progress: progress)
                }
                if mapping != nil {
                    group.addTask {
                        await watchdog(context, controller: connection.controller)
                    }
                }
                // The stream finishes first; the watchdog only ever stops
                // when cancelled.
                try await group.next()
                group.cancelAll()
            }
        } catch is CancellationError {
            return .cancelled
        } catch let error as MMAPUnavailable {
            return .mmapUnavailable(error.reason)
        } catch {
            if Task.isCancelled { return .cancelled }
            return .failed(error)
        }
        if Task.isCancelled { return .cancelled }
        return .ended
    }

    private static func stream(
        _ context: VideoContext,
        connection: EmulatorConnection,
        mapping: MappedFile?,
        progress: Progress
    ) async throws {
        let frames = context.frames
        let stats = context.stats
        let status = context.status
        let display = context.display
        let controller = connection.controller
        // Every attempt starts as raw frames; MMAP is reported only once this
        // attempt's mapping has delivered a written frame.
        status.setTransport(.raw)

        let format = EmuImageFormat.with {
            $0.format = .rgba8888
            $0.display = display
            if let mapping {
                $0.transport.channel = .mmap
                $0.transport.handle = "file://" + mapping.path
            }
        }

        try await controller.streamScreenshot(format, options: .emulatorFrames) { response in
            var geometry: (width: Int, height: Int, rotation: Int)?
            for try await image in response.messages {
                guard image.format.width > 0, image.format.height > 0 else { continue }
                let width = Int(image.format.width)
                let height = Int(image.format.height)
                let rotation = Int(image.format.rotation.rotation.rawValue)

                guard let mapping else {
                    // Raw frames carry their own pixels, always consistent
                    // with the metadata.
                    guard !image.image.isEmpty else { continue }
                    if frames.isPaused {
                        progress.frameDelivered()
                        status.frameDelivered()
                        await stats.record(seq: image.seq, timestampUs: image.timestampUs)
                        continue
                    }
                    frames.put(Frame(data: image.image, width: width, height: height, seq: image.seq, rotation: rotation))
                    progress.frameDelivered()
                    status.frameDelivered()
                    await stats.record(seq: image.seq, timestampUs: image.timestampUs)
                    continue
                }

                // The mapped buffer can still hold the previous frame (or
                // session) on the first frame and around a geometry or
                // rotation change, which reads as torn rows that a static
                // screen never repaints: take a consistent snapshot instead.
                let changed = geometry.map { $0 != (width, height, rotation) } ?? true
                geometry = (width, height, rotation)
                if changed, let snapshot = await MirrorSession.consistentFrame(
                    controller: controller,
                    display: display
                ) {
                    frames.put(snapshot)
                    progress.snapshotDelivered()
                    status.frameDelivered()
                    await stats.record(seq: image.seq, timestampUs: image.timestampUs)
                    continue
                }

                // Nobody sees the stage (and nothing records): count the
                // frame but skip the copy; showing it again resyncs.
                if progress.mmapVerified, frames.isPaused {
                    progress.frameDelivered()
                    status.frameDelivered()
                    await stats.record(seq: image.seq, timestampUs: image.timestampUs)
                    continue
                }
                let count = width * height * 4
                guard count <= mapping.size else {
                    throw MMAPUnavailable(
                        reason: "a \(width)×\(height) frame does not fit the \(mapping.size)-byte buffer"
                    )
                }
                let data = mapping.data(offset: 0, count: count)
                if !progress.mmapVerified {
                    // Only a buffer the emulator really writes proves MMAP;
                    // the fresh file is all zeros until then.
                    guard MappedFrameCheck.isWritten(data) else {
                        if progress.unwrittenFrame() >= unwrittenFrameLimit {
                            throw MMAPUnavailable(reason: "the emulator does not write the shared buffer")
                        }
                        continue
                    }
                    progress.verifyMMAP()
                    status.setTransport(.mmap)
                }
                frames.put(Frame(data: data, width: width, height: height, seq: image.seq, rotation: rotation))
                progress.frameDelivered()
                status.frameDelivered()
                await stats.record(seq: image.seq, timestampUs: image.timestampUs)
            }
        }
    }

    /// Repairs a torn MMAP frame left on a static screen. Once the stream has
    /// been idle for a full tick, the newest frame is compared with one
    /// consistent screenshot (only once per frame, not every tick) and
    /// replaced when they disagree — unless a newer stream frame arrived
    /// during the screenshot.
    static func watchdog(_ context: VideoContext, controller: EmulatorClient) async {
        let frames = context.frames
        var lastSeen: UInt64?
        var lastChecked: UInt64?
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let current = frames.current else { continue }
            let generation = current.generation
            guard generation != lastChecked else { continue }
            guard generation == lastSeen else {
                // Frames are still arriving; the next one repairs any tear.
                lastSeen = generation
                continue
            }
            guard let snapshot = await MirrorSession.consistentFrame(
                controller: controller,
                display: context.display
            ) else {
                continue
            }
            let differs = snapshot.width != current.width
                || snapshot.height != current.height
                || snapshot.rotation != current.rotation
                || snapshot.data != current.data
            if differs, frames.put(snapshot, ifGeneration: generation) {
                lastChecked = frames.currentGeneration
            } else {
                lastChecked = generation
            }
            lastSeen = lastChecked
        }
    }
}

/// Whether a frame read from the mapped buffer was written by the emulator.
enum MappedFrameCheck {
    /// The fresh frame file is all zeros; real RGBA frames are not (the
    /// screen is opaque, so every alpha byte is 0xFF).
    static func isWritten(_ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            buffer.contains { $0 != 0 }
        }
    }
}
