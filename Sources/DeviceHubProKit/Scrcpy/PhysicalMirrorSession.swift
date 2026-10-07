import Accelerate
import CoreVideo
import Darwin
import Foundation

/// A live mirror session against an adb device that is not an emulator,
/// speaking scrcpy's server protocol (spec §11.1–11.2).
///
/// `ScrcpyServerLauncher` pushes/launches the vendored server and hands over
/// the tunneled video socket (dummy byte already consumed) and, when the
/// server runs with `control`, the control socket. A dedicated serial queue
/// reads the video socket, `ScrcpyStreamReader` frames it and
/// `ScrcpyVideoDecoder` turns the H.264 packets into `CVPixelBuffer`s. Each
/// decoded buffer is stored as a `Frame` as it is (the renderer samples it
/// without a copy); its RGBA bytes, which capture, replay and recording read,
/// are converted on first request.
///
/// Input goes over the control socket when there is one (streamed as it
/// happens, multi-touch included, in video coordinates the server maps to the
/// display); otherwise it falls back to `adb shell input`.
///
/// Ownership of the connection: once claimed, only the read loop tears it
/// down. `stop()` merely shuts the sockets down, which wakes the loop; the
/// loop then stops using the descriptors and closes them. Closing them from
/// `stop()` could hand a recycled descriptor number to a loop still inside
/// `poll`/`read`.
///
/// The emulator's gRPC path (`MirrorSession`) is untouched; this mirror session is
/// selected only for non-emulator devices (or by an explicit test force).
public final class PhysicalMirrorSession: MirrorSessionProtocol, @unchecked Sendable {
    public let serial: String
    public let frames = FrameStore()

    /// How long the server may take to send the stream header once the
    /// sockets are connected.
    static let defaultHeaderTimeout: TimeInterval = 10
    /// How long the first decoded frame may take once the sockets are
    /// connected. With `control` the server turns the screen on first, so a
    /// healthy device always produces one well within it.
    static let defaultFirstFrameTimeout: TimeInterval = 15
    /// The bound on one `adb shell input` invocation of the fallback path.
    static let defaultInputCommandTimeout: Duration = .seconds(8)
    /// How long a clipboard paste may wait for the server's ACK before the
    /// input behind it goes out anyway.
    static let defaultPasteAcknowledgementTimeout: Duration = .seconds(1)
    /// How long the focused app gets, after the ACK, to handle the injected
    /// `KEYCODE_PASTE` (it reads the clipboard only then) before another
    /// SET_CLIPBOARD may replace the text.
    static let defaultPasteSettleDelay: Duration = .milliseconds(80)

    private let adb: AdbClient?
    /// Test seam: overrides how one fallback input invocation runs, so a
    /// buffer-after-stop sequence can be observed without a freshly-launched
    /// child's SIGTERM race masking it. Production wraps `adb`.
    private let inputRunner: (@Sendable ([String]) async throws -> Void)?
    /// Test seam: the display's natural size for the fallback's scaling.
    /// Production asks `adb shell wm size`.
    private let displaySizeProvider: (@Sendable () async -> (width: Int, height: Int)?)?
    private let launchConnection: @Sendable () async throws -> ScrcpyServerConnection
    private let stallTimeout: TimeInterval
    private let headerTimeout: TimeInterval
    private let firstFrameTimeout: TimeInterval
    private let inputCommandTimeout: Duration
    private let pasteAcknowledgementTimeout: Duration
    private let pasteSettleDelay: Duration
    private let statsCounter = ScrcpyStreamStats()
    private let framePool = RGBAFramePool()

    /// One stage input event, consumed in order so gestures cannot overtake
    /// each other. Contact frames carry the host time they were sent at, so
    /// the fallback measures a gesture's duration from event time even when
    /// its consumer is busy.
    private enum InputEvent: Sendable {
        case contacts([TouchCommand], at: Date)
        case keyboard(KeyboardCommand)
        case scroll(x: Int32, y: Int32, horizontal: Float, vertical: Float)
        case backOrScreenOn
        case navigationKey(NavigationKey)
        case clipboard(String, paste: Bool)
    }

    /// The wake-up signal of one attempt's input consumer. `startInput`
    /// compares the channel it installed by identity, so a superseded attempt
    /// cannot adopt its task and leave the current attempt untracked.
    private final class InputChannel: @unchecked Sendable {
        let wake: AsyncStream<Void>.Continuation

        init(_ wake: AsyncStream<Void>.Continuation) {
            self.wake = wake
        }
    }

    /// The input consumer's per-attempt state.
    private struct InputState {
        /// Control socket: which pointers are down.
        var pointers = PhysicalPointerFilter()
        /// Fallback: the gesture being accumulated and the display size.
        var tracker = PhysicalGestureTracker()
        var naturalDisplaySize: (width: Int, height: Int)?
        var displaySizeLooked = false
    }

    private let stateLock = NSLock()
    /// The reader speaks a non-thread-safe incremental parser, so every socket
    /// read and packet feed happens on this serial queue (Task 2 review).
    /// Internal so tests can hold it to order a `stop()` before the loop.
    let readQueue = DispatchQueue(label: "com.devicehubpro.scrcpy.video")
    /// Entered for every dispatched read loop, left when it has let go of
    /// its connection; `stopAndWait` waits on it.
    private let readLoops = DispatchGroup()
    /// Entered for every start attempt, left once its launch has either
    /// handed the connection to a read loop, torn down a connection the
    /// session no longer wanted, or failed; `stopAndWait` waits on it too.
    private let launches = DispatchGroup()
    /// The read loop waits at most this long before checking the stream's
    /// deadlines.
    private static let readPollMilliseconds: Int32 = 250

    private var _transport: MirrorTransport = .h264
    private var _lastError: String?
    private var _connection: ScrcpyServerConnection?
    private var _decoder: ScrcpyVideoDecoder?
    private var _inputChannel: InputChannel?
    private var _inputQueue: [InputEvent] = []
    private var _inputTask: Task<Void, Never>?
    private var _running = false
    /// Bumped on every `stop()`; a start attempt only owns the session when the
    /// generation it captured is still current, so overlapping starts cannot
    /// both claim (and a stale read loop cannot fail a newer stream).
    private var _generation: UInt64 = 0
    private var _headerValidated = false
    private var _firstFrameDecoded = false
    private var _seq: UInt32 = 0
    /// Packet arrival times keyed by PTS, consumed by the async decode
    /// callback to measure decode latency.
    private var _pendingArrivals: [Int64: Date] = [:]
    private var _onDecodedFrame: (@Sendable (Int64, Date) -> Void)?
    private var _onDeviceClipboard: (@Sendable (String) -> Void)?
    private var _onInputAttempt: (@Sendable () -> Void)?

    public convenience init(
        serial: String,
        adb: AdbClient,
        options: ScrcpyServer.Options = ScrcpyServer.Options()
    ) {
        self.init(serial: serial, adb: adb) {
            try await ScrcpyServerLauncher(
                serial: serial,
                adb: adb,
                options: options
            ).start()
        }
    }

    /// Test seam: injects connection production so stream teardown and
    /// overlapping starts can be exercised without a device. `adb` carries the
    /// fallback input path; `inputRunner` overrides how an invocation runs (so
    /// a test can observe it without the child-process timing); without
    /// either, fallback input is dropped. A connection with a control socket
    /// carries input without either.
    init(
        serial: String,
        adb: AdbClient? = nil,
        stallTimeout: TimeInterval = ScrcpyFraming.defaultStallTimeout,
        headerTimeout: TimeInterval = PhysicalMirrorSession.defaultHeaderTimeout,
        firstFrameTimeout: TimeInterval = PhysicalMirrorSession.defaultFirstFrameTimeout,
        inputCommandTimeout: Duration = PhysicalMirrorSession.defaultInputCommandTimeout,
        pasteAcknowledgementTimeout: Duration = PhysicalMirrorSession.defaultPasteAcknowledgementTimeout,
        pasteSettleDelay: Duration = PhysicalMirrorSession.defaultPasteSettleDelay,
        inputRunner: (@Sendable ([String]) async throws -> Void)? = nil,
        displaySizeProvider: (@Sendable () async -> (width: Int, height: Int)?)? = nil,
        launchConnection: @escaping @Sendable () async throws -> ScrcpyServerConnection
    ) {
        self.serial = serial
        self.adb = adb
        self.stallTimeout = stallTimeout
        self.headerTimeout = headerTimeout
        self.firstFrameTimeout = firstFrameTimeout
        self.inputCommandTimeout = inputCommandTimeout
        self.pasteAcknowledgementTimeout = pasteAcknowledgementTimeout
        self.pasteSettleDelay = pasteSettleDelay
        self.inputRunner = inputRunner
        self.displaySizeProvider = displaySizeProvider
        self.launchConnection = launchConnection
    }

    deinit {
        stop()
    }

    /// Test seam: receives `(pts, host receive time)` after every decoded
    /// frame, for the end-to-end latency measurement.
    var onDecodedFrame: (@Sendable (Int64, Date) -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _onDecodedFrame
        }
        set {
            stateLock.lock()
            _onDecodedFrame = newValue
            stateLock.unlock()
        }
    }

    /// Receives the device clipboard whenever it changes on the device
    /// (scrcpy's clipboard autosync; control socket only). Runs on the
    /// control channel's delivery queue, never on the thread reading the
    /// socket; later device messages wait for it, so it should hand the text
    /// off (e.g. `DispatchQueue.main.async`) rather than block.
    public var onDeviceClipboard: (@Sendable (String) -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _onDeviceClipboard
        }
        set {
            stateLock.lock()
            _onDeviceClipboard = newValue
            stateLock.unlock()
        }
    }

    /// Called when a touch goes down on the stage, from the thread that sent
    /// it: the app re-checks a blocked phone's input switch here.
    public var onInputAttempt: (@Sendable () -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _onInputAttempt
        }
        set {
            stateLock.lock()
            _onInputAttempt = newValue
            stateLock.unlock()
        }
    }

    /// Whether the device server reported refusing an injected input event
    /// (see ``ScrcpyServerLog/injectionDenied``).
    public var inputInjectionDenied: Bool {
        stateLock.lock()
        let log = _connection?.serverLog
        stateLock.unlock()
        return log?.injectionDenied ?? false
    }

    /// Forgets a seen refusal.
    public func clearInputInjectionDenied() {
        stateLock.lock()
        let log = _connection?.serverLog
        stateLock.unlock()
        log?.clearInjectionDenied()
    }

    public var transport: MirrorTransport {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _transport
    }

    public var lastError: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _lastError
    }

    /// Whether the stream is live. A fatal video/transport error stops the
    /// session itself (leaving the message in ``lastError``); the non-fatal
    /// input errors leave it running.
    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _running
    }

    /// Whether input currently travels over scrcpy's control socket (false
    /// before the connection is up, and on the `adb shell input` fallback).
    public var usesControlSocket: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _running && _connection?.control?.isUsable == true
    }

    // MARK: - Lifecycle

    public func start() {
        stop()
        setError(nil)
        let generation = beginAttempt()
        startInput(generation: generation)

        let launches = self.launches
        launches.enter()
        Task { [weak self] in
            defer { launches.leave() }
            guard let self else { return }
            do {
                let connection = try await self.launchConnection()
                guard self.claim(connection, generation: generation) else {
                    // Stopped (or superseded) while launching: nobody else
                    // owns this connection. Its teardown finishes before the
                    // launch counts as done, so `stopAndWait` covers it.
                    await connection.stop()
                    return
                }
                let readLoops = self.readLoops
                self.readQueue.async { [weak self] in
                    guard let self else {
                        // The session is gone: nobody else will close it.
                        Task { await connection.stop() }
                        readLoops.leave()
                        return
                    }
                    self.readLoop(connection, generation: generation)
                }
            } catch {
                self.fail("scrcpy: \(error)", generation: generation)
            }
        }
    }

    public func stop() {
        stateLock.lock()
        _generation &+= 1
        let connection = _connection
        let decoder = _decoder
        let inputTask = _inputTask
        let inputChannel = _inputChannel
        _connection = nil
        _decoder = nil
        _inputTask = nil
        _inputChannel = nil
        _inputQueue.removeAll()
        _running = false
        _headerValidated = false
        _firstFrameDecoded = false
        _pendingArrivals.removeAll()
        stateLock.unlock()

        inputTask?.cancel()
        inputChannel?.wake.finish()
        decoder?.invalidate()
        // Wakes the read loop (its `read` returns 0); the loop then closes
        // the sockets and tears the connection down.
        connection?.shutdownSockets()
    }

    /// Stops the session and completes the connection's teardown (sockets
    /// closed, device server killed) before returning, waiting at most
    /// `timeout`. For the app's termination path, where an asynchronous
    /// teardown would never run. A launch still in flight is waited for as
    /// well: once it connects it finds the session stopped and tears its
    /// connection down. A launch that is still connecting when `timeout`
    /// runs out is left behind (its forward and `adb shell` outlive a quit).
    /// Must not be called from the session's own callbacks.
    public func stopAndWait(timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        stateLock.lock()
        let connection = _connection
        stateLock.unlock()

        stop()
        _ = launches.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow))
        _ = readLoops.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow))
        connection?.stopSynchronously(timeout: max(0.1, deadline.timeIntervalSinceNow))
    }

    public func resync() async {
        // The H.264 stream is always a complete, self-consistent frame; there
        // is no torn shared buffer to repaint from.
    }

    public func stats() async -> MirrorStats {
        await statsCounter.snapshot()
    }

    // MARK: - Input

    public func send(_ command: TouchCommand) {
        noteInputAttempt([command])
        enqueue(.contacts([command], at: Date()))
    }

    public func send(contacts: [TouchCommand]) {
        noteInputAttempt(contacts)
        enqueue(.contacts(contacts, at: Date()))
    }

    private func noteInputAttempt(_ contacts: [TouchCommand]) {
        guard contacts.contains(where: { $0.phase == .down }) else { return }
        onInputAttempt?()
    }

    public func send(_ command: KeyboardCommand) {
        enqueue(.keyboard(command))
    }

    /// Scrolls at a frame point by wheel steps in [-1, 1] (positive
    /// `vertical` scrolls up, like a mouse wheel). Control socket only; the
    /// `adb shell input` fallback has no scroll and drops it.
    public func sendScroll(x: Int32, y: Int32, horizontal: Float, vertical: Float) {
        enqueue(.scroll(x: x, y: y, horizontal: horizontal, vertical: vertical))
    }

    /// BACK, or POWER when the device screen is off (scrcpy's right click).
    /// The fallback sends `KEYCODE_BACK`.
    public func sendBackOrScreenOn() {
        enqueue(.backOrScreenOn)
    }

    /// One navigation key (Back, Home or Recents) as a press and release on
    /// the control socket; the fallback sends `input keyevent`.
    public func sendNavigationKey(_ key: NavigationKey) {
        enqueue(.navigationKey(key))
    }

    /// Sets the device clipboard, optionally pasting it into the focused
    /// field. Control socket only. A paste holds the input queued behind it
    /// until the server has acknowledged it (see ``send(_:over:)``).
    public func setDeviceClipboard(_ text: String, paste: Bool = false) {
        enqueue(.clipboard(text, paste: paste))
    }

    private func enqueue(_ event: InputEvent) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard _running, let channel = _inputChannel else { return }
        _inputQueue.append(event)
        channel.wake.yield()
    }

    /// Everything queued for `generation`, or nil once it is stale.
    private func takeInput(generation: UInt64) -> [InputEvent]? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard _running, _generation == generation else { return nil }
        let events = _inputQueue
        _inputQueue.removeAll(keepingCapacity: true)
        return events
    }

    /// Starts this attempt's input consumer: a single task drains the queue
    /// in order. Each wake-up takes every queued event at once, so a burst of
    /// keystrokes that arrived while an earlier one was being delivered (an
    /// `adb shell input` call, a clipboard paste being acknowledged) is sent
    /// as one text. Failures are non-fatal and land in `lastError` (the
    /// session keeps mirroring; the app surface is the same as for video
    /// errors).
    private func startInput(generation: UInt64) {
        let (wake, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let channel = InputChannel(continuation)

        stateLock.lock()
        guard _running, _generation == generation else {
            // A `stop()` already landed between `start()` and here.
            stateLock.unlock()
            continuation.finish()
            return
        }
        _inputChannel = channel
        _inputQueue.removeAll()
        stateLock.unlock()

        let runner = resolvedInputRunner()
        let displaySize = resolvedDisplaySizeProvider()
        let task = Task { [weak self] in
            var state = InputState()
            for await _ in wake {
                // `stop()` finishes the stream, but `AsyncStream` still
                // delivers a wake-up buffered before it; the stale generation
                // refuses the events, which would reach a device this mirror session
                // no longer owns.
                guard let self, let events = self.takeInput(generation: generation) else {
                    break
                }
                for event in Self.coalescingText(events) {
                    guard self.isCurrent(generation), !Task.isCancelled else { return }
                    await self.deliver(
                        event,
                        generation: generation,
                        runner: runner,
                        displaySize: displaySize,
                        state: &state
                    )
                }
            }
        }

        stateLock.lock()
        // `stop()` may have run while the task was being created and replaced
        // the channel; only the attempt whose channel is still installed may
        // adopt its task, or a later `stop()` would cancel the wrong one.
        if _running, _inputChannel === channel {
            _inputTask = task
        } else {
            task.cancel()
        }
        stateLock.unlock()
    }

    /// Merges runs of typed text: one `input text` (or INJECT_TEXT) per burst
    /// instead of one per keystroke. Other events keep their place.
    private static func coalescingText(_ events: [InputEvent]) -> [InputEvent] {
        var merged: [InputEvent] = []
        merged.reserveCapacity(events.count)
        for event in events {
            if case .keyboard(.text(let text)) = event,
               case .keyboard(.text(let previous))? = merged.last {
                merged[merged.count - 1] = .keyboard(.text(previous + text))
            } else {
                merged.append(event)
            }
        }
        return merged
    }

    private func deliver(
        _ event: InputEvent,
        generation: UInt64,
        runner: (@Sendable ([String]) async throws -> Void)?,
        displaySize: (@Sendable () async -> (width: Int, height: Int)?)?,
        state: inout InputState
    ) async {
        if let control = currentControl(generation: generation) {
            await send(controlMessages(for: event, pointers: &state.pointers), over: control)
            return
        }

        // `adb shell input` fallback: no control socket (yet).
        guard let runner else { return }
        do {
            switch event {
            case .contacts(let contacts, let time):
                guard let gesture = state.tracker.accept(translated(contacts), at: time) else {
                    return
                }
                let scaled = await scaledToDisplay(
                    gesture,
                    displaySize: displaySize,
                    state: &state
                )
                try await runner(PhysicalInput.arguments(for: scaled, serial: serial))

            case .keyboard(let command):
                guard let arguments = PhysicalInput.arguments(
                    forKeyboard: command,
                    serial: serial
                ) else { return }
                try await runner(arguments)

            case .backOrScreenOn:
                try await runner(PhysicalInput.backArguments(serial: serial))

            case .navigationKey(let key):
                try await runner(key.adbArguments(serial: serial))

            case .scroll, .clipboard:
                // No `adb shell input` equivalent.
                return
            }
        } catch {
            reportInputError("input: \(error)", generation: generation)
        }
    }

    private func controlMessages(
        for event: InputEvent,
        pointers: inout PhysicalPointerFilter
    ) -> [ScrcpyControlMessage] {
        switch event {
        case .contacts(let contacts, _):
            // Without a frame there is no video size to position against;
            // the contacts are dropped before the filter records them.
            guard let size = frames.currentSize else { return [] }
            return PhysicalInput.controlMessages(
                forContacts: pointers.accept(translated(contacts)),
                videoWidth: size.width,
                videoHeight: size.height
            )

        case .keyboard(let command):
            return PhysicalInput.controlMessages(forKeyboard: command)

        case .scroll(let x, let y, let horizontal, let vertical):
            guard let size = frames.currentSize,
                  size.width > 0, size.height > 0,
                  size.width <= Int(UInt16.max), size.height <= Int(UInt16.max)
            else { return [] }
            return [
                .injectScroll(
                    position: ScrcpyPosition(
                        x: max(0, min(Int32(size.width - 1), x)),
                        y: max(0, min(Int32(size.height - 1), y)),
                        screenWidth: UInt16(size.width),
                        screenHeight: UInt16(size.height)
                    ),
                    horizontal: horizontal,
                    vertical: vertical
                )
            ]

        case .backOrScreenOn:
            return [.backOrScreenOn(action: .down), .backOrScreenOn(action: .up)]

        case .navigationKey(let key):
            let keycode = Int32(key.androidKeyCode)
            return [.injectKeycode(action: .down, keycode: keycode), .injectKeycode(action: .up, keycode: keycode)]

        case .clipboard(let text, let paste):
            return [.setClipboard(sequence: ScrcpyControl.sequenceInvalid, paste: paste, text: text)]
        }
    }

    /// Writes `messages` in order, holding everything after a clipboard
    /// paste until the paste has landed.
    ///
    /// The server injects `KEYCODE_PASTE` asynchronously and the focused app
    /// reads the clipboard only when it handles that key, so a second
    /// SET_CLIPBOARD right behind the first could replace the text before the
    /// first paste reads it (typing "ış" would insert "şş"). A paste
    /// therefore asks for an ACK, which the server sends once the paste key
    /// is injected, and the app gets a short settle delay on top; keystrokes
    /// typed meanwhile queue up and go out together as the next paste.
    private func send(
        _ messages: [ScrcpyControlMessage],
        over control: ScrcpyControlChannel
    ) async {
        var pending: [ScrcpyControlMessage] = []
        for message in messages {
            guard case .setClipboard(_, paste: true, let text) = message else {
                pending.append(message)
                continue
            }
            control.send(pending)
            pending.removeAll()
            _ = await control.setClipboard(
                text,
                paste: true,
                timeout: pasteAcknowledgementTimeout
            )
            // A `stop()` cancels the wait; nothing may follow it to a device
            // the session no longer owns.
            guard control.isUsable, !Task.isCancelled else { return }
            try? await Task.sleep(for: pasteSettleDelay)
            guard !Task.isCancelled else { return }
        }
        control.send(pending)
    }

    /// The live control channel of `generation`, when it is still usable.
    private func currentControl(generation: UInt64) -> ScrcpyControlChannel? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard _running, _generation == generation,
              let control = _connection?.control, control.isUsable
        else { return nil }
        return control
    }

    /// Scales a fallback gesture from video-frame to display pixels (the
    /// server may stream a smaller picture than the display). The display
    /// size is looked up once per attempt; without it the gesture is sent
    /// unscaled.
    private func scaledToDisplay(
        _ gesture: PhysicalGesture,
        displaySize: (@Sendable () async -> (width: Int, height: Int)?)?,
        state: inout InputState
    ) async -> PhysicalGesture {
        guard let video = frames.currentSize else { return gesture }
        if !state.displaySizeLooked {
            state.displaySizeLooked = true
            state.naturalDisplaySize = await displaySize?()
        }
        guard let natural = state.naturalDisplaySize else { return gesture }
        let display = PhysicalInput.displaySize(
            natural: natural,
            orientedLikeVideoWidth: video.width,
            videoHeight: video.height
        )
        return PhysicalInput.scaled(
            gesture,
            videoWidth: video.width,
            videoHeight: video.height,
            displayWidth: display.width,
            displayHeight: display.height
        )
    }

    /// The injected runner wins over `adb`; without either, fallback input is
    /// dropped (the stream-only lifecycle tests).
    private func resolvedInputRunner() -> (@Sendable ([String]) async throws -> Void)? {
        if let inputRunner { return inputRunner }
        guard let adb else { return nil }
        let timeout = inputCommandTimeout
        return { arguments in _ = try await adb.run(arguments, within: timeout) }
    }

    private func resolvedDisplaySizeProvider() -> (@Sendable () async -> (width: Int, height: Int)?)? {
        if let displaySizeProvider { return displaySizeProvider }
        guard let adb else { return nil }
        let serial = self.serial
        return { await adb.naturalDisplaySize(serial: serial, within: .seconds(3)) }
    }

    /// Input views produce frame coordinates; scrcpy frames arrive already in
    /// the display's current orientation (the server re-frames on rotation),
    /// so `rotation == 0` makes this the identity plus a clamp into the
    /// frame. It is the same `TouchMapping` step the emulator session uses,
    /// so a rotated physical frame needs no new seam.
    private func translated(_ commands: [TouchCommand]) -> [TouchCommand] {
        guard let frame = frames.current else { return commands }
        return commands.map { command in
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
    }

    /// Records an input failure without stopping the stream: the protocol
    /// contract keeps sessions running after input errors, and the app surfaces
    /// `lastError` through its existing error path. A stale generation (already
    /// stopped or restarted) is ignored.
    private func reportInputError(_ message: String, generation: UInt64) {
        stateLock.lock()
        if _running, _generation == generation {
            _lastError = message
        }
        stateLock.unlock()
    }

    // MARK: - Video

    /// Publishes `connection` as the session's and hands it to a read loop,
    /// which the caller dispatches next (`readLoops` is entered under the
    /// same lock, so `stopAndWait` never sees a claimed connection without
    /// its loop).
    private func claim(_ connection: ScrcpyServerConnection, generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard _running, _generation == generation else { return false }
        _connection = connection
        readLoops.enter()
        return true
    }

    /// Starts a new start attempt and returns its generation. Incrementing and
    /// capturing under one lock keeps two concurrent `start()` calls from
    /// sharing a generation (the caller's earlier `stop()` no longer has to
    /// be the same critical section).
    private func beginAttempt() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        _generation &+= 1
        _running = true
        return _generation
    }

    /// Reads the claimed connection until the session lets go of it, then
    /// tears it down: this loop is the only code that closes its sockets.
    private func readLoop(_ connection: ScrcpyServerConnection, generation: UInt64) {
        let readLoops = self.readLoops
        defer {
            Task { await connection.stop() }
            readLoops.leave()
        }
        // A `stop()` may have landed between the claim and this block; the
        // descriptor is still open (stop only shuts it down), but the
        // session no longer wants it.
        guard isCurrent(generation) else { return }

        let startedAt = ContinuousClock.now
        var reader = ScrcpyStreamReader(
            expectsDummyByte: false,
            stallTimeout: stallTimeout,
            handshakeTimeout: headerTimeout,
            startedAt: startedAt
        )
        let decoder = ScrcpyVideoDecoder()
        defer { decoder.invalidate() }
        decoder.onFrame = { [weak self] frame in
            self?.didDecode(frame, generation: generation)
        }
        decoder.onError = { [weak self] error in
            // This runs on VideoToolbox's output handler: never tear down
            // from there. Not on `readQueue` either, which this loop holds
            // until the session stops; `fail` only signals, so any other
            // queue will do.
            guard let self else { return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.fail("scrcpy decode: \(error)", generation: generation)
            }
        }

        stateLock.lock()
        guard _running, _generation == generation else {
            stateLock.unlock()
            return
        }
        _decoder = decoder
        stateLock.unlock()

        connection.control?.startReading { [weak self] message in
            self?.handle(message, generation: generation)
        }

        // Read with `read(2)`, not `FileHandle.read(upToCount:)`: the
        // FileHandle API blocks until it has filled the requested length,
        // which buffered whole seconds of the stream and destroyed latency.
        // `read(2)` returns as soon as any bytes are available; `shutdown`
        // (in `stop`) makes it return 0.
        //
        // `poll(2)` in front of it bounds each wait so a peer that declares a
        // large packet and then trickles, or never sends the header or a
        // first frame, cannot hold the serial reader forever: the deadlines
        // are checked whenever a poll times out.
        let descriptor = connection.videoDescriptor
        var buffer = [UInt8](repeating: 0, count: 1 << 16)

        while isCurrent(generation) {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&pollDescriptor, 1, Self.readPollMilliseconds)
            if pollResult == 0 {
                do {
                    try reader.checkStall()
                    try checkFirstFrame(since: startedAt, generation: generation)
                } catch {
                    failStream("scrcpy stream: \(error)", connection: connection, generation: generation)
                    return
                }
                continue
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                fail("scrcpy read: errno \(errno)", generation: generation)
                break
            }

            let chunk: Data
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if count > 0 {
                chunk = Data(buffer[0..<count])
            } else if count == 0 {
                // EOF while the session is running means the server (or the
                // adb tunnel) went away; a deliberate `stop()` clears the
                // generation before `shutdown`, so it stays silent.
                failStream(
                    "The mirror stream ended unexpectedly",
                    connection: connection,
                    generation: generation
                )
                break
            } else if errno == EINTR {
                continue
            } else {
                fail("scrcpy read: errno \(errno)", generation: generation)
                break
            }

            reader.append(chunk)
            if !headerValidated, let header = reader.header {
                validate(header, generation: generation)
                if !isCurrent(generation) { break }
            }

            do {
                while let packet = try reader.nextPacket() {
                    guard process(packet, decoder: decoder, generation: generation) else {
                        return
                    }
                }
                try checkFirstFrame(since: startedAt, generation: generation)
            } catch {
                // `.emptyPacket` / `.oversizedPacket` / stream-disabled are
                // protocol corruption, not transient: tear the session down.
                failStream("scrcpy stream: \(error)", connection: connection, generation: generation)
                return
            }
        }
    }

    /// Throws once the first-frame deadline has passed without a decoded
    /// frame: a server that sends its header and then nothing (a capture or
    /// encoder that never starts) must not leave the stage connecting forever.
    private func checkFirstFrame(since start: ContinuousClock.Instant, generation: UInt64) throws {
        guard ContinuousClock.now - start >= .seconds(firstFrameTimeout) else { return }
        stateLock.lock()
        let decoded = _firstFrameDecoded || _generation != generation
        stateLock.unlock()
        guard !decoded else { return }
        throw PhysicalMirrorError.noVideoFrame(seconds: firstFrameTimeout)
    }

    /// Fails with `message` plus what the device server last printed. The
    /// server usually dies a moment after its socket, so its console gets a
    /// brief chance to catch up first.
    private func failStream(
        _ message: String,
        connection: ScrcpyServerConnection,
        generation: UInt64
    ) {
        guard isCurrent(generation) else { return }
        guard let log = connection.serverLog else {
            fail(message, generation: generation)
            return
        }
        log.waitForOutputEnd(timeout: 0.3)
        fail(log.annotate(message), generation: generation)
    }

    private func handle(_ message: ScrcpyDeviceMessage, generation: UInt64) {
        guard case .clipboard(let text) = message else { return }
        stateLock.lock()
        let current = _running && _generation == generation
        let observer = _onDeviceClipboard
        stateLock.unlock()
        guard current else { return }
        observer?(text)
    }

    private func validate(_ header: ScrcpyStreamHeader, generation: UInt64) {
        stateLock.lock()
        if _running, _generation == generation {
            _headerValidated = true
        }
        stateLock.unlock()

        guard header.codecID == ScrcpyH264.codecID else {
            fail(
                "scrcpy: \(ScrcpyVideoDecoderError.unsupportedCodec(header.codecID))",
                generation: generation
            )
            return
        }
    }

    /// Returns false when the stream was torn down by a decode failure.
    private func process(
        _ packet: FramePacket,
        decoder: ScrcpyVideoDecoder,
        generation: UInt64
    ) -> Bool {
        stateLock.lock()
        if packet.pts > 0 {
            _pendingArrivals[packet.pts] = Date()
        }
        stateLock.unlock()

        do {
            try decoder.decode(packet)
            return true
        } catch {
            fail("scrcpy decode: \(error)", generation: generation)
            return false
        }
    }

    private func didDecode(_ decoded: ScrcpyDecodedFrame, generation: UInt64) {
        // A callback from a stopped generation must not repopulate a newer
        // session's FrameStore.
        guard isCurrent(generation) else { return }

        let now = Date()
        let arrival = takeArrival(decoded.pts)

        let pixelBuffer = decoded.pixelBuffer
        guard CVPixelBufferGetWidth(pixelBuffer) > 0, CVPixelBufferGetHeight(pixelBuffer) > 0 else {
            Task { await statsCounter.recordDroppedFrame() }
            return
        }

        stateLock.lock()
        guard _running, _generation == generation else {
            stateLock.unlock()
            return
        }
        _seq &+= 1
        let seq = _seq
        _firstFrameDecoded = true
        stateLock.unlock()

        // The decoded buffer itself goes into the store: the renderer samples
        // it in place, and the RGBA bytes are made only for a consumer that
        // reads `Frame.data` (replay, capture), from the recycled pool.
        let pool = framePool
        frames.put(Frame(pixelBuffer: pixelBuffer, seq: seq) { buffer in
            PhysicalMirrorSession.rgbaFrame(from: buffer, pool: pool)?.data
        })
        Task { await statsCounter.recordDecodedFrame(arrival: arrival ?? now) }

        let observer = onDecodedFrame
        observer?(decoded.pts, now)
    }

    private func takeArrival(_ pts: Int64) -> Date? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if _pendingArrivals.count > 600 {
            // Bound the map when VideoToolbox drops a frame: arrivals older
            // than ten seconds cannot belong to a callback still in flight.
            let cutoff = pts - 10_000_000
            _pendingArrivals = _pendingArrivals.filter { $0.key >= cutoff }
        }
        return _pendingArrivals.removeValue(forKey: pts)
    }

    /// Converts a decoded BGRA pixel buffer into the RGBA bytes the stage's
    /// `FrameStore` contract carries (`vImagePermuteChannels_ARGB8888` swaps
    /// the red and blue channels in one pass). With a `pool`, the bytes live
    /// in a recycled buffer instead of a fresh zero-filled allocation.
    static func rgbaFrame(
        from pixelBuffer: CVPixelBuffer,
        pool: RGBAFramePool? = nil
    ) -> (data: Data, width: Int, height: Int)? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer)
        else { return nil }

        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let permute: (UnsafeMutableRawPointer) -> Bool = { destination in
            var source = vImage_Buffer(
                data: base,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: rowBytes
            )
            var target = vImage_Buffer(
                data: destination,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: width * 4
            )
            let map: [UInt8] = [2, 1, 0, 3]
            return vImagePermuteChannels_ARGB8888(
                &source,
                &target,
                map,
                vImage_Flags(kvImageNoFlags)
            ) == kvImageNoError
        }

        let byteCount = width * height * 4
        if let pool {
            guard let data = pool.makeData(byteCount: byteCount, filling: permute) else {
                return nil
            }
            return (data, width, height)
        }

        var data = Data(count: byteCount)
        let converted = data.withUnsafeMutableBytes { raw in
            raw.baseAddress.map(permute) ?? false
        }
        guard converted else { return nil }
        return (data, width, height)
    }

    // MARK: - State

    /// True when `generation` still owns the session (running and not stopped
    /// or restarted since).
    private func isCurrent(_ generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _running && _generation == generation
    }

    private var headerValidated: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _headerValidated
    }

    private func setError(_ value: String?) {
        stateLock.lock()
        _lastError = value
        stateLock.unlock()
    }

    /// Records a fatal stream error and tears the session down. A stale
    /// generation (already stopped or restarted) is ignored so an old read
    /// loop cannot fail a newer stream.
    private func fail(_ message: String, generation: UInt64) {
        guard isCurrent(generation) else { return }
        setError(message)
        stop()
    }
}

/// Recycles the RGBA frame buffers of one session.
///
/// A mirrored phone produces a new 8–15 MB frame up to 60 times a second,
/// and the previous one is released a frame later (the `FrameStore` keeps
/// only the latest; replay and recording copy what they keep). Allocating
/// each one fresh, zero-filled and page-faulted in, is pure overhead: the
/// pool hands out a released buffer of the same size instead. A buffer
/// returns to the pool when the last `Data` referencing it is released.
final class RGBAFramePool: @unchecked Sendable {
    /// Buffers kept for reuse; more are allocated (and freed) on demand.
    static let maximumPooled = 4

    private let lock = NSLock()
    private var byteCount = 0
    private var available: [UnsafeMutableRawPointer] = []

    deinit {
        available.forEach { $0.deallocate() }
    }

    /// A `Data` of `byteCount` bytes written by `fill`, or nil (and the
    /// buffer kept) when `fill` fails. A new frame size (a rotation) drops
    /// the buffers of the old one.
    func makeData(
        byteCount: Int,
        filling fill: (UnsafeMutableRawPointer) -> Bool
    ) -> Data? {
        let buffer = take(byteCount: byteCount)
        guard fill(buffer) else {
            recycle(buffer, byteCount: byteCount)
            return nil
        }
        return Data(
            bytesNoCopy: buffer,
            count: byteCount,
            deallocator: .custom { [self] pointer, count in
                recycle(pointer, byteCount: count)
            }
        )
    }

    /// How many released buffers are waiting for reuse.
    var pooledCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return available.count
    }

    private func take(byteCount: Int) -> UnsafeMutableRawPointer {
        lock.lock()
        defer { lock.unlock() }
        if byteCount != self.byteCount {
            available.forEach { $0.deallocate() }
            available.removeAll()
            self.byteCount = byteCount
        }
        return available.popLast()
            ?? UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
    }

    private func recycle(_ buffer: UnsafeMutableRawPointer, byteCount: Int) {
        lock.lock()
        if byteCount == self.byteCount, available.count < Self.maximumPooled {
            available.append(buffer)
            lock.unlock()
            return
        }
        lock.unlock()
        buffer.deallocate()
    }
}

public enum PhysicalMirrorError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The stream header arrived but no frame was decoded within the deadline.
    case noVideoFrame(seconds: TimeInterval)

    public var description: String {
        switch self {
        case .noVideoFrame(let seconds):
            return "no video frame was decoded within \(String(format: "%.1f", seconds))s"
        }
    }
}

/// Frame statistics for the scrcpy transport. The latency it reports is the
/// host-side decode latency (packet arrival → decoded pixel buffer), which is
/// measurable without a device clock; capture/encode time on the device is not
/// included (the integration measurement accounts for it via the PTS clock).
actor ScrcpyStreamStats {
    private var totalFrames = 0
    private var droppedFrames = 0
    private var windowStart = Date()
    private var windowFrames = 0
    private var currentFPS = 0.0
    private var latencySum = 0.0
    private var latencyCount = 0

    func recordDecodedFrame(arrival: Date, now: Date = Date()) {
        totalFrames += 1
        windowFrames += 1

        let latency = now.timeIntervalSince(arrival)
        if latency >= 0, latency < 5 {
            latencySum += latency
            latencyCount += 1
        }

        let window = now.timeIntervalSince(windowStart)
        if window >= 1 {
            currentFPS = Double(windowFrames) / window
            windowStart = now
            windowFrames = 0
        }
    }

    func recordDroppedFrame() {
        droppedFrames += 1
    }

    func snapshot() -> MirrorStats {
        MirrorStats(
            fps: currentFPS,
            totalFrames: totalFrames,
            dropped: droppedFrames,
            averageLatencyMs: latencyCount > 0 ? latencySum / Double(latencyCount) * 1000 : 0
        )
    }
}
