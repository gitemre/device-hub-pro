import CoreVideo
import Foundation
import IOSurface
import Synchronization

/// A live mirror of one iOS simulator through the private simulator bridge:
/// frames from its screen IOSurface, touch and keyboard through dtuhidd.
///
/// **Frames** are published upright, the way scrcpy's are
/// (`PhysicalMirrorSession`): `Frame.rotation` is always 0 and the pixel
/// buffer is already turned for the interface orientation, so the stage,
/// capture, replay and recording need nothing new. The simulator's own
/// framebuffer stays in the panel's native portrait with the content drawn
/// turned; its screen reports the interface orientation (`uiOrientation`),
/// and the session turns the picture while it copies it
/// (`SimulatorFrameCopier`, a plain row copy upright, vImage otherwise) into
/// a pooled IOSurface-backed 32BGRA buffer. The live surface is never
/// published: CoreSimulator rewrites it in place.
///
/// **Pacing.** A frame callback marks the screen dirty; copies run on the
/// session queue at most once per `minimumPublishInterval` (1/60 s). A
/// callback that arrives while a copy is already scheduled is coalesced
/// (`MirrorStats.dropped`); the scheduled copy reads the surface when it
/// runs, so the last frame of a burst is always published. An idle screen
/// sends no callbacks and costs nothing.
///
/// **Input** maps displayed-frame pixels back to the native portrait ratios
/// dtuhidd takes, through the rotation of the frame the user was looking at
/// (`SimulatorFrameRotation`), follows up to two fingers
/// (`SimulatorTouchTracker`) and tags a contact that starts at a displayed
/// edge with the matching native edge. Text is typed as HID key presses with
/// the table of the simulator's hardware keyboard layout
/// (`SimulatorKeyboard`); a character the layout has no key for is put on the
/// simulator pasteboard with `simctl pbcopy` and followed by ⌘V. That path is
/// experimental: on iOS 27.0 the ⌘V did not insert the `pbcopy` text in any
/// field tried (see the spec, §3.4). Hardware buttons (the frame's side
/// buttons, Home and Lock) go through the same channel, in order with the
/// touches and keys; a button still down when the session stops goes up
/// before its channel closes. The dtuhidd connection opens lazily, on the
/// first input event of each start: connecting marks dtuhidd active for the
/// rest of that simulator's boot.
///
/// **Lifecycle.** `start()` returns at once; failures land in `lastError`.
/// When the simulator shuts down (the screen reports a nil surface) the
/// session stops itself with "The simulator shut down." in `lastError`, like
/// a physical session whose stream died. `stop()` is idempotent. Every bridge
/// call runs on the session's own queues, never the main queue, and the
/// screen is never unregistered from its callback queue.
///
/// The caller decides whether the bridge may load at all
/// (`BridgeCompatibility`, `SimulatorBridging.loadIfCompatible`).
public final class SimulatorMirrorSession: MirrorSessionProtocol, SimulatorButtonSending, @unchecked Sendable {
    public let udid: String
    /// The device set holding the simulator, or nil for the default set.
    public let deviceSet: URL?
    public let frames = FrameStore()
    public var transport: MirrorTransport { .simulatorSurface }

    /// The shortest gap between two publishes: 60 frames per second.
    public static let defaultMinimumPublishInterval: Duration = .nanoseconds(16_666_667)
    /// Between two pastes, so the app reads one paste's text before the next
    /// `pbcopy` replaces it.
    static let pasteSettle: Duration = .milliseconds(100)
    /// How long U.S. stands in for a layout the simulator's preferences do
    /// not name before they are read again.
    static let layoutRetryInterval: Duration = .milliseconds(500)
    /// The message a session that stopped because its simulator shut down leaves.
    public static let shutDownMessage = "The simulator shut down."

    private let bridge: any SimulatorBridging
    private let simctl: SimctlClient?
    private let address: SimulatorAddress
    private let minimumPublishInterval: UInt64
    private let keyboardLayoutOverride: SimulatorKeyboardLayout?
    private let pasteboardWriter: (@Sendable (String) async throws -> Void)?

    /// Lifecycle, copies and publishes. Serial.
    private let sessionQueue = DispatchQueue(label: "com.devicehubpro.simulator-mirror.session", qos: .userInteractive)
    /// Every input send, in order. Serial; the first send can wait for dtuhidd.
    private let inputQueue = DispatchQueue(label: "com.devicehubpro.simulator-mirror.input", qos: .userInitiated)
    /// Confined to `sessionQueue`.
    let copier = SimulatorFrameCopier()
    private let rgbaPool = RGBAFramePool()

    private let state = Mutex(State())
    /// Confined to `inputQueue`.
    private var inputSide = InputSide()

    private struct State {
        var generation: UInt64 = 0
        var running = false
        var lastError: String?
        var screen: (any SimulatorScreenBridging)?
        var input: (any SimulatorInputBridging)?
        var surface: SimulatorSurface?
        var uiOrientation: UInt32 = 1
        /// Bumped by every `surfaceChanged` / `propertiesChanged` callback.
        /// A synchronous read of the screen takes these before it asks and
        /// keeps its value only when they have not moved: a callback that
        /// overtook the read reported something newer.
        var surfaceUpdates: UInt64 = 0
        var propertiesUpdates: UInt64 = 0

        var publishScheduled = false
        var lastPublishStart: UInt64 = 0
        /// When the oldest frame callback not yet published arrived.
        var pendingSince: UInt64?
        var published: DisplayGeometry?
        var seq: UInt32 = 0
        var statistics = StatisticsRecorder()

        var pendingInput: [(generation: UInt64, event: InputEvent)] = []
        var inputDrainScheduled = false
        /// The buttons whose down this generation delivered and whose up it
        /// has not, in the order they went down. A stop takes them and
        /// releases them on the input channel before it disconnects.
        var heldButtons: [SimulatorHardwareButton] = []
    }

    private struct InputSide {
        var tracker = SimulatorTouchTracker()
        var trackerGeneration: UInt64 = 0
        var layout: SimulatorKeyboardLayout?
        /// When the preferences, which named no layout with a table, are read again.
        var layoutRetryAt: UInt64 = 0
        var lastPaste: UInt64?
    }

    private enum InputEvent {
        case contacts([SimulatorContact])
        case keyboard(KeyboardCommand)
        /// One edge of a hardware button (the frame's side buttons).
        case button(SimulatorHardwareButton, isDown: Bool)
        /// A button pressed and released after `hold` (Home, Lock).
        case press(SimulatorHardwareButton, hold: Duration)
    }

    /// The frame the user sees: what input maps back through.
    private struct DisplayGeometry {
        let rotation: SimulatorFrameRotation
        let width: Int
        let height: Int

        func contact(for command: TouchCommand) -> SimulatorContact {
            let x = Double(command.x)
            let y = Double(command.y)
            let point = rotation.nativeRatio(displayX: x, displayY: y, displayWidth: width, displayHeight: height)
            var edge = SimulatorTouchEdge.none
            if command.phase == .down {
                let zone = max(8, 0.02 * Double(min(width, height)))
                let displayEdge = SimulatorFrameRotation.displayEdge(x: x, y: y, width: width, height: height, zone: zone)
                edge = rotation.nativeEdge(forDisplayEdge: displayEdge)
            }
            return SimulatorContact(id: command.id, phase: command.phase, point: point, edge: edge)
        }
    }

    /// - Parameters:
    ///   - udid: the simulator; it must be booted when `start()` runs.
    ///   - deviceSet: its device set folder, nil for the default set.
    ///   - bridge: the private bridge (`LiveSimulatorBridge`, or a fake).
    ///   - simctl: a client for the same device set, used to put text the
    ///     keyboard layout cannot type on the pasteboard. Without it such text
    ///     is dropped with an error.
    public convenience init(udid: String, deviceSet: URL? = nil, bridge: any SimulatorBridging, simctl: SimctlClient? = nil) {
        self.init(udid: udid, deviceSet: deviceSet, bridge: bridge, simctl: simctl, minimumPublishInterval: Self.defaultMinimumPublishInterval)
    }

    /// Test seam: the publish interval, a fixed keyboard layout, and the
    /// pasteboard write.
    init(
        udid: String,
        deviceSet: URL? = nil,
        bridge: any SimulatorBridging,
        simctl: SimctlClient? = nil,
        minimumPublishInterval: Duration,
        keyboardLayout: SimulatorKeyboardLayout? = nil,
        pasteboardWriter: (@Sendable (String) async throws -> Void)? = nil
    ) {
        self.udid = udid
        self.deviceSet = deviceSet
        self.bridge = bridge
        self.simctl = simctl
        self.address = SimulatorAddress(udid: udid, deviceSetPath: deviceSet?.path)
        self.minimumPublishInterval = Self.nanoseconds(minimumPublishInterval)
        self.keyboardLayoutOverride = keyboardLayout
        self.pasteboardWriter = pasteboardWriter
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

    /// The interface orientation the last published frame was turned for.
    public var publishedRotation: SimulatorFrameRotation? {
        state.withLock { $0.published?.rotation }
    }

    // MARK: - Lifecycle

    public func start() {
        stop()
        let generation = state.withLock { state -> UInt64 in
            state.generation &+= 1
            state.running = true
            state.lastError = nil
            state.uiOrientation = 1
            state.published = nil
            state.statistics = StatisticsRecorder()
            return state.generation
        }
        sessionQueue.async { [weak self] in
            self?.open(generation: generation)
        }
    }

    /// Ends the session. A button still held down (a chrome or frame
    /// button the mouse holds, `send(button:isDown:)`) goes up on the
    /// simulator first: the input queued behind it is dropped, its up
    /// included, so the session sends the ups itself.
    public func stop() {
        let taken = state.withLock { Self.tearDown(&$0) }
        guard taken.screen != nil || taken.input != nil else { return }
        // Off the caller's queue (the main queue, typically), and never the
        // screen's callback queue. The next start opens a channel of its
        // own, so no disconnect here reaches it.
        let (screen, input, held) = taken
        sessionQueue.async {
            screen?.stop()
            // Cancels a dtuhidd connect in progress on the input queue. A
            // channel with a button held is connected (the down went through
            // it): it closes on the input queue, after the ups.
            if held.isEmpty { input?.disconnect() }
        }
        if let input {
            // Behind the send in flight: releases what is held, then closes
            // a connection that send reopened.
            inputQueue.async {
                Self.release(held, on: input)
                input.disconnect()
            }
        }
    }

    /// Stops the session and waits, at most `timeout`, until the screen is
    /// unregistered and the buttons held down are released. For app
    /// termination and tests; not from the session's own callbacks.
    public func stopAndWait(timeout: TimeInterval = 2) {
        stop()
        let deadline = DispatchTime.now() + max(0, timeout)
        let screenDone = DispatchSemaphore(value: 0)
        let inputDone = DispatchSemaphore(value: 0)
        sessionQueue.async { screenDone.signal() }
        inputQueue.async { inputDone.signal() }
        _ = screenDone.wait(timeout: deadline)
        _ = inputDone.wait(timeout: deadline)
    }

    /// How long a stop waits for the ups it sends to leave the process
    /// before it disconnects.
    static let releaseFlushTimeout: Duration = .seconds(1)

    /// Sends the up of every button in `held`, in the order they went down,
    /// and waits until they have left the process before the disconnect
    /// that follows (a send only queues the message), as the Device menu's
    /// press does (`SimulatorHardwareActions.press`). Stops at the first
    /// failed send. On the input queue.
    private static func release(_ held: [SimulatorHardwareButton], on input: any SimulatorInputBridging) {
        guard !held.isEmpty else { return }
        for button in held {
            do {
                try input.send(.button(button, isDown: false))
            } catch {
                return
            }
        }
        // Best effort: past the timeout the disconnect goes ahead anyway.
        try? input.flush(timeout: releaseFlushTimeout)
    }

    /// Resolves the screen and registers the callbacks. On the session queue.
    private func open(generation: UInt64) {
        do {
            _ = try bridge.load()
            let screen = try bridge.makeScreen(for: address)
            let initial = screen.initialProperties
            let adopted = state.withLock { state -> Bool in
                guard state.running, state.generation == generation else { return false }
                state.screen = screen
                state.uiOrientation = initial.uiOrientation
                return true
            }
            // Stopped while resolving: nothing is registered yet.
            guard adopted else { return }
            try screen.start { [weak self] event in
                self?.handle(event, generation: generation)
            }
            // A rotation between resolving the screen and registering sends
            // no callback; read the orientation once more.
            let updates = state.withLock { $0.propertiesUpdates }
            if let current = try? screen.currentProperties() {
                let changed = state.withLock { state -> Bool in
                    guard state.running, state.generation == generation, state.propertiesUpdates == updates,
                          state.uiOrientation != current.uiOrientation
                    else {
                        return false
                    }
                    state.uiOrientation = current.uiOrientation
                    return true
                }
                if changed { screenChanged(generation: generation, isFrameCallback: false) }
            }
        } catch {
            fail(Self.message(for: error), generation: generation)
        }
    }

    /// Runs on the bridge's callback queue, where CoreSimulator waits for it:
    /// bookkeeping only; the work hops to the session queue.
    private func handle(_ event: SimulatorScreenEvent, generation: UInt64) {
        switch event {
        case .frame:
            screenChanged(generation: generation, isFrameCallback: true)
        case .surfaceChanged(let surface?):
            let current = state.withLock { state -> Bool in
                guard state.running, state.generation == generation else { return false }
                state.surface = surface
                state.surfaceUpdates &+= 1
                return true
            }
            // The first surface arrives right after registering: publish it,
            // since an idle screen sends no frame callback.
            if current { screenChanged(generation: generation, isFrameCallback: false) }
        case .surfaceChanged(nil):
            sessionQueue.async { [weak self] in
                self?.simulatorWentAway(generation: generation)
            }
        case .propertiesChanged(let properties):
            let current = state.withLock { state -> Bool in
                guard state.running, state.generation == generation else { return false }
                state.uiOrientation = properties.uiOrientation
                state.propertiesUpdates &+= 1
                return true
            }
            if current { screenChanged(generation: generation, isFrameCallback: false) }
        }
    }

    /// The device went away. On the session queue, so the unregister never
    /// runs on the callback queue.
    private func simulatorWentAway(generation: UInt64) {
        let taken = state.withLock { state -> TornDown? in
            guard state.running, state.generation == generation else { return nil }
            state.lastError = Self.shutDownMessage
            return Self.tearDown(&state)
        }
        // The held buttons went with the device: nothing to release.
        guard let (screen, input, _) = taken else { return }
        screen?.stop()
        input?.disconnect()
    }

    /// Records a fatal error and stops. On the session queue.
    private func fail(_ message: String, generation: UInt64) {
        let taken = state.withLock { state -> TornDown? in
            guard state.running, state.generation == generation else { return nil }
            state.lastError = message
            return Self.tearDown(&state)
        }
        guard let (screen, input, held) = taken else { return }
        screen?.stop()
        if held.isEmpty {
            input?.disconnect()
        } else if let input {
            // A button went down while the screen was resolving: its up
            // first, on the input queue, as `stop()` does.
            inputQueue.async {
                Self.release(held, on: input)
                input.disconnect()
            }
        }
    }

    /// What a stop takes from the state: the screen, the input channel and
    /// the buttons still held down on it.
    private typealias TornDown = (
        screen: (any SimulatorScreenBridging)?,
        input: (any SimulatorInputBridging)?,
        held: [SimulatorHardwareButton]
    )

    private static func tearDown(_ state: inout State) -> TornDown {
        state.running = false
        state.generation &+= 1
        state.publishScheduled = false
        state.pendingSince = nil
        state.pendingInput.removeAll()
        state.surface = nil
        let screen = state.screen
        state.screen = nil
        let input = state.input
        state.input = nil
        let held = state.heldButtons
        state.heldButtons = []
        return (screen, input, held)
    }

    // MARK: - Frames

    /// The screen has something new: schedule a publish unless one is
    /// already scheduled, no sooner than the interval after the last one.
    private func screenChanged(generation: UInt64, isFrameCallback: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        let interval = minimumPublishInterval
        let delay = state.withLock { state -> UInt64? in
            guard state.running, state.generation == generation else { return nil }
            if isFrameCallback { state.statistics.callbacks += 1 }
            if state.pendingSince == nil { state.pendingSince = now }
            if state.publishScheduled {
                if isFrameCallback { state.statistics.coalesced += 1 }
                return nil
            }
            state.publishScheduled = true
            let due = state.lastPublishStart &+ interval
            return due > now ? due - now : 0
        }
        guard let delay else { return }
        schedulePublish(generation: generation, after: delay)
    }

    private func schedulePublish(generation: UInt64, after delay: UInt64) {
        if delay == 0 {
            sessionQueue.async { [weak self] in self?.publish(generation: generation, scheduled: true) }
        } else {
            sessionQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { [weak self] in
                self?.publish(generation: generation, scheduled: true)
            }
        }
    }

    private enum PublishStep {
        case copy(SimulatorSurface, uiOrientation: UInt32, pendingSince: UInt64?)
        case wait(UInt64)
        case none
    }

    /// Copies the surface, upright, and stores it. On the session queue.
    ///
    /// `scheduled` is the paced publish `screenChanged` set up; only it
    /// clears `publishScheduled`. An unscheduled one (`resync`) can run while
    /// a paced one waits: that one then has nothing left to copy, or keeps
    /// to the interval after the unscheduled copy.
    private func publish(generation: UInt64, scheduled: Bool) {
        let started = DispatchTime.now().uptimeNanoseconds
        let interval = minimumPublishInterval
        let step = state.withLock { state -> PublishStep in
            guard state.running, state.generation == generation else { return .none }
            if scheduled {
                guard state.pendingSince != nil else {
                    state.publishScheduled = false
                    return .none
                }
                let due = state.lastPublishStart &+ interval
                if due > started { return .wait(due - started) }
                state.publishScheduled = false
            }
            state.lastPublishStart = started
            let since = state.pendingSince
            state.pendingSince = nil
            guard let surface = state.surface else { return .none }
            return .copy(surface, uiOrientation: state.uiOrientation, pendingSince: since)
        }
        guard case .copy(let surface, let uiOrientation, let since) = step else {
            if case .wait(let delay) = step { schedulePublish(generation: generation, after: delay) }
            return
        }
        let rotation = SimulatorFrameRotation(uiOrientation: uiOrientation)

        let outcome: SimulatorFrameCopier.Outcome
        do {
            outcome = try copier.copy(surface.surface, rotation: rotation)
        } catch {
            state.withLock { state in
                guard state.running, state.generation == generation else { return }
                state.statistics.copyFailures += 1
                state.lastError = "Copying a simulator frame failed: \(error)"
            }
            return
        }

        let finished = DispatchTime.now().uptimeNanoseconds
        let seq = state.withLock { state -> UInt32? in
            guard state.running, state.generation == generation else { return nil }
            state.seq &+= 1
            state.statistics.record(outcome, publishedAt: finished, pendingSince: since ?? started)
            state.published = DisplayGeometry(
                rotation: rotation,
                width: CVPixelBufferGetWidth(outcome.buffer),
                height: CVPixelBufferGetHeight(outcome.buffer)
            )
            return state.seq
        }
        guard let seq else { return }
        let pool = rgbaPool
        frames.put(Frame(pixelBuffer: outcome.buffer, seq: seq) { buffer in
            PhysicalMirrorSession.rgbaFrame(from: buffer, pool: pool)?.data
        })
        // A copy the simulator wrote over twice: the write that tore it is a
        // new frame, so copy again rather than leave the torn one standing.
        if outcome.torn {
            screenChanged(generation: generation, isFrameCallback: false)
        }
    }

    public func resync() async {
        let generation = state.withLock { $0.running ? $0.generation : nil }
        guard let generation else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                self?.refreshSurface(generation: generation)
                self?.publish(generation: generation, scheduled: false)
                continuation.resume()
            }
        }
    }

    /// Reads the surface and orientation from the screen again, keeping
    /// what a callback reported while the reads were on their way. On the
    /// session queue.
    private func refreshSurface(generation: UInt64) {
        let taken = state.withLock { state -> (screen: any SimulatorScreenBridging, surfaceUpdates: UInt64, propertiesUpdates: UInt64)? in
            guard state.running, state.generation == generation, let screen = state.screen else { return nil }
            return (screen, state.surfaceUpdates, state.propertiesUpdates)
        }
        guard let taken else { return }
        let surface = try? taken.screen.currentSurface()
        let properties = try? taken.screen.currentProperties()
        state.withLock { state in
            guard state.running, state.generation == generation else { return }
            if let surface, state.surfaceUpdates == taken.surfaceUpdates { state.surface = surface }
            if let properties, state.propertiesUpdates == taken.propertiesUpdates {
                state.uiOrientation = properties.uiOrientation
            }
        }
    }

    public func stats() async -> MirrorStats {
        let statistics = surfaceStatistics()
        return MirrorStats(
            fps: statistics.publishFPS,
            totalFrames: statistics.publishedFrames,
            dropped: statistics.coalescedCallbacks,
            averageLatencyMs: statistics.averageLatencyMilliseconds
        )
    }

    /// The surface transport's own counters, for diagnostics and tests.
    public func surfaceStatistics() -> SimulatorSurfaceStatistics {
        let now = DispatchTime.now().uptimeNanoseconds
        return state.withLock { $0.statistics.snapshot(now: now) }
    }

    // MARK: - Input

    public func send(_ command: TouchCommand) {
        send(contacts: [command])
    }

    public func send(contacts: [TouchCommand]) {
        guard !contacts.isEmpty else { return }
        enqueue { state in
            // Without a frame there is nothing to position against.
            guard let geometry = state.published else { return nil }
            return .contacts(contacts.map(geometry.contact(for:)))
        }
    }

    public func send(_ command: KeyboardCommand) {
        enqueue { _ in .keyboard(command) }
    }

    // MARK: - Hardware buttons

    /// The frame's side buttons reach the simulator as dtuhidd buttons, on
    /// the session's own input channel.
    public var supportsHardwareKeys: Bool { true }

    /// One edge of a side button: power is the side (lock) button, the
    /// volume keys are the volume buttons. The simulator sees the button
    /// held for as long as the mouse holds it.
    public func send(_ event: HardwareKeyEvent) {
        let button = Self.button(for: event.key)
        enqueue { _ in .button(button, isDown: event.isDown) }
    }

    /// One edge of any hardware button, by its HID usage: an Apple chrome
    /// button held for as long as the mouse holds it (Action, Home, the side
    /// and volume buttons), in order with the touches and keys already
    /// queued. Dropped while the session is not running; a button still
    /// down when the session stops is released by `stop()`.
    public func send(button: SimulatorHardwareButton, isDown: Bool) {
        enqueue { _ in .button(button, isDown: isDown) }
    }

    /// Presses `button` for `hold` on the session's input channel, in order
    /// with the touches and keys already queued: Home and Lock from the
    /// Device menu (`SimulatorHardwareActions` documents what each does on
    /// iOS 27.0). Dropped while the session is not running.
    public func press(_ button: SimulatorHardwareButton, hold: Duration = SimulatorHardwareActions.defaultPress) {
        enqueue { _ in .press(button, hold: hold) }
    }

    /// The dtuhidd button a side button of the frame presses.
    public static func button(for key: HardwareKey) -> SimulatorHardwareButton {
        switch key {
        case .power: return .side
        case .volumeUp: return .volumeUp
        case .volumeDown: return .volumeDown
        }
    }

    private func enqueue(_ make: (inout State) -> InputEvent?) {
        let generation = state.withLock { state -> UInt64? in
            guard state.running, let event = make(&state) else { return nil }
            state.pendingInput.append((state.generation, event))
            guard !state.inputDrainScheduled else { return nil }
            state.inputDrainScheduled = true
            return state.generation
        }
        guard generation != nil else { return }
        inputQueue.async { [weak self] in
            self?.drainInput()
        }
    }

    /// Sends everything queued, in order. On the input queue.
    private func drainInput() {
        while true {
            let batch = state.withLock { state -> [(generation: UInt64, event: InputEvent)]? in
                guard !state.pendingInput.isEmpty else {
                    state.inputDrainScheduled = false
                    return nil
                }
                let batch = state.pendingInput
                state.pendingInput.removeAll()
                return batch
            }
            guard let batch else { return }
            deliver(Self.coalescingText(batch))
        }
    }

    /// Merges runs of typed text, so a burst of keystrokes that queued up
    /// behind a slow send pastes (when it must paste) once.
    private static func coalescingText(_ batch: [(generation: UInt64, event: InputEvent)]) -> [(generation: UInt64, event: InputEvent)] {
        var merged: [(generation: UInt64, event: InputEvent)] = []
        for item in batch {
            if case .keyboard(.text(let text)) = item.event,
               let last = merged.last, last.generation == item.generation,
               case .keyboard(.text(let previous)) = last.event {
                merged[merged.count - 1] = (item.generation, .keyboard(.text(previous + text)))
            } else {
                merged.append(item)
            }
        }
        return merged
    }

    private func currentGeneration() -> UInt64? {
        state.withLock { $0.running ? $0.generation : nil }
    }

    private func deliver(_ batch: [(generation: UInt64, event: InputEvent)]) {
        for (generation, event) in batch {
            guard currentGeneration() == generation else { continue }
            if inputSide.trackerGeneration != generation {
                // A new start: fingers and the keyboard layout start over.
                inputSide.tracker.reset()
                inputSide.layout = nil
                inputSide.layoutRetryAt = 0
                inputSide.trackerGeneration = generation
            }
            guard let input = inputChannel(generation: generation) else { continue }
            do {
                switch event {
                case .contacts(let contacts):
                    for hid in inputSide.tracker.accept(contacts) {
                        try input.send(hid)
                    }
                case .keyboard(let command):
                    try type(command, input: input, generation: generation)
                case .button(let button, isDown: true):
                    try input.send(.button(button, isDown: true))
                    if !noteHeld(button, generation: generation) {
                        // A stop took the held buttons before this down
                        // landed: its up is owed here.
                        Self.release([button], on: input)
                    }
                case .button(let button, isDown: false):
                    // Once a stop took the held buttons, it sends this up.
                    guard noteReleased(button, generation: generation) else { continue }
                    try input.send(.button(button, isDown: false))
                case .press(let button, let hold):
                    try input.send(.button(button, isDown: true))
                    Thread.sleep(forTimeInterval: Double(Self.nanoseconds(hold)) / 1e9)
                    try input.send(.button(button, isDown: false))
                }
            } catch {
                // A send failed (pasteboard failures stay in `paste`): most
                // likely dtuhidd never answered (the connect retries for up to
                // about 40 s). Drop what queued up meanwhile rather than wait
                // that long again for each event. The next input retries.
                inputSide.tracker.reset()
                state.withLock { state in
                    state.pendingInput.removeAll { $0.generation == generation }
                    guard state.running, state.generation == generation else { return }
                    state.lastError = "Simulator input: \(Self.message(for: error))"
                }
                return
            }
        }
    }

    /// Records a delivered down; false once the generation is over.
    private func noteHeld(_ button: SimulatorHardwareButton, generation: UInt64) -> Bool {
        state.withLock { state in
            guard state.running, state.generation == generation else { return false }
            if !state.heldButtons.contains(button) { state.heldButtons.append(button) }
            return true
        }
    }

    /// Records an up about to be sent; false once the generation is over
    /// (the stop that ended it sends the up of a button it held).
    private func noteReleased(_ button: SimulatorHardwareButton, generation: UInt64) -> Bool {
        state.withLock { state in
            guard state.running, state.generation == generation else { return false }
            state.heldButtons.removeAll { $0 == button }
            return true
        }
    }

    /// The generation's input channel, made on its first use; nil once the
    /// generation is over. Each start gets its own: the disconnects `stop()`
    /// queues for the previous one must not reach the next one's connect.
    /// On the input queue.
    private func inputChannel(generation: UInt64) -> (any SimulatorInputBridging)? {
        let current = state.withLock { state -> (live: Bool, input: (any SimulatorInputBridging)?) in
            (state.running && state.generation == generation, state.input)
        }
        guard current.live else { return nil }
        if let input = current.input { return input }
        // Nothing connects until the first send, so a channel made for a
        // generation that ended meanwhile is simply dropped.
        let made = bridge.makeInput(for: address)
        return state.withLock { state in
            guard state.running, state.generation == generation else { return nil }
            if let existing = state.input { return existing }
            state.input = made
            return made
        }
    }

    private func type(_ command: KeyboardCommand, input: any SimulatorInputBridging, generation: UInt64) throws {
        switch command {
        case .specialKey(let keyCode):
            guard let usage = SimulatorKeyboard.usage(forMacKeyCode: keyCode) else { return }
            for event in SimulatorKeyStroke(usage: usage).events {
                try input.send(event)
            }
        case .text(let text):
            let layout = keyboardLayout()
            for step in SimulatorKeyboard.steps(for: text, layout: layout) {
                guard currentGeneration() == generation else { return }
                switch step {
                case .stroke(let stroke):
                    for event in stroke.events {
                        try input.send(event)
                    }
                case .paste(let pasted):
                    try paste(pasted, input: input, generation: generation)
                }
            }
        }
    }

    /// The simulator's hardware keyboard layout, read from its preferences
    /// and kept for the rest of the start once they name one with a table.
    /// Until then (a fresh simulator has not written them yet, or they name
    /// a layout without a table) U.S., and they are read again at most every
    /// `layoutRetryInterval`.
    private func keyboardLayout() -> SimulatorKeyboardLayout {
        if let keyboardLayoutOverride { return keyboardLayoutOverride }
        if let layout = inputSide.layout { return layout }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= inputSide.layoutRetryAt else { return .usQWERTY }
        if let read = SimulatorKeyboard.layout(udid: udid, deviceSet: deviceSet) {
            inputSide.layout = read
            return read
        }
        inputSide.layoutRetryAt = now + Self.nanoseconds(Self.layoutRetryInterval)
        return .usQWERTY
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        return UInt64(max(0, components.seconds)) * 1_000_000_000 + UInt64(max(0, components.attoseconds) / 1_000_000_000)
    }

    /// `pbcopy` then ⌘V, at least `pasteSettle` after the previous paste.
    /// A pasteboard that cannot be written (no simctl, or `pbcopy` failed)
    /// drops only this run of text, with an error; the rest of the input goes
    /// on. Only a failed ⌘V send throws.
    private func paste(_ text: String, input: any SimulatorInputBridging, generation: UInt64) throws {
        do {
            try writePasteboard(text)
        } catch {
            state.withLock { state in
                guard state.running, state.generation == generation else { return }
                state.lastError = "Simulator input: \(Self.message(for: error))"
            }
            return
        }
        for event in SimulatorKeyboard.pasteStroke.events {
            try input.send(event)
        }
        inputSide.lastPaste = DispatchTime.now().uptimeNanoseconds
    }

    /// Puts `text` on the simulator pasteboard, at least `pasteSettle` after
    /// the previous paste.
    private func writePasteboard(_ text: String) throws {
        let writer: @Sendable (String) async throws -> Void
        if let pasteboardWriter {
            writer = pasteboardWriter
        } else if let simctl {
            let udid = self.udid
            writer = { text in try await simctl.setPasteboard(udid: udid, text: text) }
        } else {
            throw SimulatorMirrorError.noPasteboard(text)
        }
        let settle = Self.nanoseconds(Self.pasteSettle)
        if let last = inputSide.lastPaste {
            let now = DispatchTime.now().uptimeNanoseconds
            if now < last + settle {
                Thread.sleep(forTimeInterval: Double(last + settle - now) / 1e9)
            }
        }
        try Self.waitFor { try await writer(text) }
    }

    /// Runs `operation` and blocks this (input) queue until it finishes.
    static func waitFor(_ operation: @escaping @Sendable () async throws -> Void) throws {
        let outcome = BlockingOutcome()
        Task.detached {
            do {
                try await operation()
                outcome.finish(.success(()))
            } catch {
                outcome.finish(.failure(error))
            }
        }
        try outcome.wait()
    }

    private static func message(for error: any Error) -> String {
        if let bridgeError = error as? SimulatorBridgeError { return bridgeError.message }
        return "\(error)"
    }
}

/// The result of an async operation a dispatch queue waits for.
final class BlockingOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<Void, any Error>?

    func finish(_ result: Result<Void, any Error>) {
        lock.withLock { self.result = result }
        done.signal()
    }

    func wait() throws {
        done.wait()
        try lock.withLock { result }?.get()
    }
}

/// Session failures that are not the bridge's.
public enum SimulatorMirrorError: Error, Equatable, CustomStringConvertible {
    /// Text the keyboard layout cannot type needs the pasteboard, and the
    /// session has no simctl client.
    case noPasteboard(String)

    public var description: String {
        switch self {
        case .noPasteboard(let text):
            return "cannot type \"\(text)\": the simulator keyboard has no key for it and there is no simctl for the pasteboard"
        }
    }
}

/// The simulator surface transport's counters.
public struct SimulatorSurfaceStatistics: Sendable, Equatable {
    /// Median and 95th percentile of the recent copies, in milliseconds.
    public struct CopyTimes: Sendable, Equatable {
        public var count: Int
        public var p50: Double
        public var p95: Double
    }

    /// Frame callbacks from the simulator.
    public var frameCallbacks: Int
    /// Frames copied and stored.
    public var publishedFrames: Int
    /// Callbacks folded into a publish already scheduled.
    public var coalescedCallbacks: Int
    /// Copies redone because the seed moved during the first copy.
    public var retriedCopies: Int
    /// Copies whose seed moved during the retry too (published, then replaced).
    public var tornFrames: Int
    public var copyFailures: Int
    /// Publishes in the last second.
    public var publishFPS: Double
    /// Mean time from the first unpublished callback to the frame in the store.
    public var averageLatencyMilliseconds: Double
    /// Upright copies (a plain row copy).
    public var uprightCopies: CopyTimes
    /// Turned copies (vImage).
    public var rotatedCopies: CopyTimes
}

/// Collects `SimulatorSurfaceStatistics` under the session's lock.
struct StatisticsRecorder {
    var callbacks = 0
    var coalesced = 0
    var published = 0
    var retried = 0
    var torn = 0
    var copyFailures = 0
    private var latencySum = 0.0
    private var latencyCount = 0
    /// Publish times of the last second or so (at most 240).
    private var recentPublishes: [UInt64] = []
    private var uprightCopyTimes = RecentValues()
    private var rotatedCopyTimes = RecentValues()

    mutating func record(_ outcome: SimulatorFrameCopier.Outcome, publishedAt now: UInt64, pendingSince: UInt64) {
        published += 1
        if outcome.retried { retried += 1 }
        if outcome.torn { torn += 1 }
        if outcome.rotation == .upright {
            uprightCopyTimes.append(outcome.milliseconds)
        } else {
            rotatedCopyTimes.append(outcome.milliseconds)
        }
        if now >= pendingSince {
            latencySum += Double(now - pendingSince) / 1_000_000
            latencyCount += 1
        }
        recentPublishes.append(now)
        if recentPublishes.count > 240 { recentPublishes.removeFirst(recentPublishes.count - 240) }
    }

    func snapshot(now: UInt64) -> SimulatorSurfaceStatistics {
        let second: UInt64 = 1_000_000_000
        let lastSecond = recentPublishes.filter { now < $0 + second }.count
        return SimulatorSurfaceStatistics(
            frameCallbacks: callbacks,
            publishedFrames: published,
            coalescedCallbacks: coalesced,
            retriedCopies: retried,
            tornFrames: torn,
            copyFailures: copyFailures,
            publishFPS: Double(lastSecond),
            averageLatencyMilliseconds: latencyCount > 0 ? latencySum / Double(latencyCount) : 0,
            uprightCopies: uprightCopyTimes.summary,
            rotatedCopies: rotatedCopyTimes.summary
        )
    }

    /// The last 1024 values.
    struct RecentValues {
        private var values: [Double] = []

        mutating func append(_ value: Double) {
            values.append(value)
            if values.count > 1024 { values.removeFirst(values.count - 1024) }
        }

        var summary: SimulatorSurfaceStatistics.CopyTimes {
            guard !values.isEmpty else { return .init(count: 0, p50: 0, p95: 0) }
            let sorted = values.sorted()
            func percentile(_ p: Double) -> Double {
                sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
            }
            return .init(count: sorted.count, p50: percentile(0.5), p95: percentile(0.95))
        }
    }
}
