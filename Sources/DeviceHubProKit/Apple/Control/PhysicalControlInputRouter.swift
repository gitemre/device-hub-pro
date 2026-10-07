import Foundation
import Synchronization
import os

/// Turns the stage's mouse and keyboard into the few things the runner can do:
/// the stage's contacts and keys go in, `tap`,
/// `swipe` and `type` calls on a `PhysicalControlling` come out.
///
/// - A click (down, then up close to where it went down) is one **tap** at the
///   point where it went down.
/// - A drag is one **swipe**, sent on mouse-up, with the drag's start, end and
///   duration. There is no live tracking: the runner's drag is one atomic
///   gesture. A scroll (the stage's synthesized finger) is the same thing.
/// - Only the first finger counts: pinches, Option-drags and every other
///   contact are dropped (no multi-touch with position control).
/// - Typed keys are buffered and sent as one **type** call once the keys stop
///   (or the buffer is long), to the app that owns the keyboard: the first of
///   the session's candidates in the foreground. When none is, nothing is
///   typed and the failure says "Tap a text field first".
/// - The Apple chrome's Home and volume buttons press on the button's down
///   edge; the side, Siri and Action buttons have no public equivalent and do
///   nothing (through fast input every chrome button goes as its real down and
///   up edges, see `receive(button:isDown:)`).
///
/// **Fast input** (opt-in, `setFastInput`): with a
/// `FastInputSending` set, a portrait contact is not classified but sent live:
/// down, every move (coalesced while one is still waiting) and up, in order,
/// and the Home, volume and App Switcher buttons go the same way, and so does
/// typing (layout-independent: a run of text replaces the phone's pasteboard and
/// presses Command+V, Return, Tab and Delete are HID keys; text the pasteboard
/// would not take goes to the runner). Rotation and Siri stay with the
/// runner. The fast path's coordinates are the portrait panel's, so a touch is
/// mapped through `FastInputPanelMapping` for the stage's pose
/// (`orientation`: the native view's tracker, which is the device pose the frame
/// turns with, else the runner's reading), because the picture is the panel turned
/// with the frame: a tap lands where it appears in every pose, whatever the interface does;
/// landscape with an unknown pose, or a frame that contradicts it,
/// stays with the runner. The home indicator is at the bottom of the INTERFACE: the
/// panel's bottom edge (a side of a landscape stage, the top band of an upside-down one)
/// unless the interface itself turned to landscape (`interfaceLandscape`), where the band is the
/// stage's bottom and a contact starting in it sends nothing (no edge gesture form was
/// accepted there): a short swipe up is the Home button, a swipe up
/// that rests before release the App Switcher button. The first fast error
/// clears the fast path, reports it once through `onFastInputFailure` and
/// leaves everything to the runner for the rest of the session; a button that
/// failed is pressed again through the runner.
///
/// Every call is asynchronous and they run one at a time, in the order the
/// user made them: a click or a drag that arrives while one runs and one
/// already waits is dropped with a soft "busy" note (at most one waits). A
/// result that is not a soft message goes to `onFailure` (the app turns
/// Control off), a soft one (busy, no keyboard) to `onSoftFailure`.
public final class PhysicalControlInputRouter: @unchecked Sendable {
    public struct Tuning: Sendable {
        /// A pointer that moved less than this many points from where it
        /// went down is a click, not a drag.
        public var tapSlop: Double = 10
        /// A swipe's duration is the drag's, kept within this range.
        public var swipeDuration: ClosedRange<Double> = 0.12...1.5
        /// Keys stopped for this long: send what was typed.
        public var typingIdle: TimeInterval = 0.25
        /// A buffer this long is sent at once.
        public var typingBatch = 40
        /// A fast contact that sent nothing for this long re-sends its last
        /// point, so iOS keeps seeing a resting finger (an App Switcher swipe
        /// needs samples while the finger holds).
        public var restRepeat: TimeInterval = 0.03
        /// A chrome button held down with no up for this long is released on the phone.
        public var buttonHoldLimit: TimeInterval = 10
        /// Landscape bottom-edge contact (no edge gesture is accepted there, so it
        /// becomes a button): a rest of this long after an upward swipe of at least
        /// `landscapeSwitcherRise` (fraction of the height) is the App Switcher ...
        public var landscapeRestHold: TimeInterval = 0.4
        public var landscapeSwitcherRise: Double = 0.1
        /// ... and a swipe up of at least this much is Home.
        public var landscapeHomeRise: Double = 0.08
        /// Movement under this fraction of the height does not end a rest.
        public var landscapeRestSlop: Double = 0.02

        public init() {}
    }

    /// What the stage can show of a touch while it is being handled (local
    /// feedback: it does not wait for the runner). Points are normalized
    /// (0...1 of the stage's frame), `id` counts the touch actions.
    public enum ActionEvent: Sendable, Equatable {
        /// The pointer went down.
        case pressed(CGPoint)
        /// The pointer moved while down.
        case moved(CGPoint)
        /// The gesture ended without an action (a second finger, a stop).
        case cancelled
        /// The release was queued as action `id`.
        case accepted(id: UInt64, point: CGPoint)
        /// Action `id` ran (its answer is in, or it failed).
        case finished(id: UInt64)
        /// The release was dropped: the queue was full (soft "busy").
        case dropped(point: CGPoint)
    }

    /// Runs `work` after `delay` seconds; the returned closure cancels it.
    public typealias Scheduler = @Sendable (_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> @Sendable () -> Void

    public static let defaultScheduler: Scheduler = { delay, work in
        let task = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            work()
        }
        return { task.cancel() }
    }

    private let control: any PhysicalControlling
    private let frameSize: @Sendable () -> CGSize?
    private let tuning: Tuning
    private let schedule: Scheduler
    private let now: @Sendable () -> TimeInterval
    private let onFailure: @Sendable (PhysicalControlError) -> Void
    private let onSoftFailure: @Sendable (PhysicalControlError) -> Void
    private let onActionEvent: (@Sendable (ActionEvent) -> Void)?
    private let onFastInputFailure: (@Sendable (FastInputError) -> Void)?
    private let orientation: @Sendable () -> PhysicalControlOrientation?
    private let interfaceLandscape: (@Sendable () -> Bool)?
    private let state = Mutex(State())

    private struct Contact {
        var down: CGPoint
        var last: CGPoint
        var frame: CGSize
        var startedAt: TimeInterval
        /// The contact is sent live through fast input.
        var viaFast = false
        /// The fast contact began in the bottom edge band: it goes as edge events.
        var viaEdge = false
        /// Landscape bottom-edge contact: nothing is sent, the release picks Home or the App Switcher.
        var viaButtons = false
        /// Where and when the pointer last moved by more than the rest slop.
        var anchor = CGPoint.zero
        var anchorAt: TimeInterval = 0
        /// The last point sent (panel coordinates): what the rest repeats.
        var lastPanel: CGPoint?
        /// How the stage's points map to the panel (fast contacts only).
        var panel = FastInputPanelMapping.Rotation.identity
    }

    private enum FastEvent: Sendable {
        case down(CGPoint)
        case move(CGPoint)
        case up(CGPoint, id: UInt64)
        /// A bottom-edge gesture event (`id` on the last one, like `up`).
        case edge(FastInputEdgePhase, CGPoint, id: UInt64?)
        case button(PhysicalControlButton)
        case appSwitcher
        /// One edge of a chrome button, by its HID page and usage.
        case hid(page: Int, usage: Int, down: Bool)
        /// One keyboard report: exactly these usages held.
        case keys([Int])
    }

    private struct State {
        var contact: Contact?
        var buffer = ""
        var cancelTimer: (@Sendable () -> Void)?
        var isStopped = false
        /// The last queued action: the next one starts after it.
        var tail: Task<Void, Never>?
        /// Actions running or waiting.
        var queued = 0
        var nextID: UInt64 = 0
        var fast: (any FastInputSending)?
        var fastQueue: [FastEvent] = []
        var fastPumping = false
        /// The helper has no digitizer connection: bottom-edge gestures go as touches.
        var edgeUnavailable = false
        /// The resting-finger repeater: a new number invalidates a pending tick.
        var repeatGen = 0
        var repeatCancel: (@Sendable () -> Void)?
        var keyboard = PhysicalKeyboardState()
        /// Chrome buttons that went down through fast input, each with its stuck-button timer.
        var heldButtons: [[Int]: @Sendable () -> Void] = [:]
    }

    /// The most touch actions in the queue: one runs, one waits.
    static let queueLimit = 2

    /// Runs `work` after every earlier action. A touch (`dropIfFull`) that
    /// would be a third in the queue is dropped with a soft note; typing and
    /// buttons always queue.
    private func enqueue(
        dropIfFull: Bool,
        touch: (id: UInt64, point: CGPoint)? = nil,
        _ work: @escaping @Sendable () async -> Void
    ) {
        let previous = state.withLock { state -> (accepted: Bool, tail: Task<Void, Never>?) in
            guard !state.isStopped else { return (false, nil) }
            if dropIfFull, state.queued >= Self.queueLimit { return (false, nil) }
            state.queued += 1
            return (true, state.tail)
        }
        guard previous.accepted else {
            if dropIfFull, !state.withLock({ $0.isStopped }) {
                if let touch { onActionEvent?(.dropped(point: touch.point)) }
                onSoftFailure(.busy)
            }
            return
        }
        // Before the task exists, so `finished` can never overtake it.
        if let touch { onActionEvent?(.accepted(id: touch.id, point: touch.point)) }
        let task = Task { [weak self] in
            await previous.tail?.value
            if let self, !self.state.withLock({ $0.isStopped }) { await work() }
            self?.state.withLock { $0.queued = max(0, $0.queued - 1) }
            if let touch { self?.onActionEvent?(.finished(id: touch.id)) }
        }
        state.withLock { $0.tail = task }
    }

    public init(
        control: any PhysicalControlling,
        frameSize: @escaping @Sendable () -> CGSize?,
        tuning: Tuning = Tuning(),
        schedule: @escaping Scheduler = PhysicalControlInputRouter.defaultScheduler,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onFailure: @escaping @Sendable (PhysicalControlError) -> Void,
        onSoftFailure: @escaping @Sendable (PhysicalControlError) -> Void,
        onActionEvent: (@Sendable (ActionEvent) -> Void)? = nil,
        onFastInputFailure: (@Sendable (FastInputError) -> Void)? = nil,
        orientation: @escaping @Sendable () -> PhysicalControlOrientation? = { nil },
        interfaceLandscape: (@Sendable () -> Bool)? = nil
    ) {
        self.orientation = orientation
        self.interfaceLandscape = interfaceLandscape
        self.control = control
        self.frameSize = frameSize
        self.tuning = tuning
        self.schedule = schedule
        self.now = now
        self.onFailure = onFailure
        self.onSoftFailure = onSoftFailure
        self.onActionEvent = onActionEvent
        self.onFastInputFailure = onFastInputFailure
    }

    // MARK: Fast input

    /// Sets (or, with nil, clears) the fast path. A gesture that began
    /// through the runner path finishes there; the next one uses this.
    public func setFastInput(_ sending: (any FastInputSending)?) {
        state.withLock { state in
            guard !state.isStopped else { return }
            state.fast = sending
            if sending == nil { state.fastQueue.removeAll(); state.keyboard = PhysicalKeyboardState() }
        }
        if sending == nil {
            cancelRepeat()
            _ = takeHeldButtons()
        }
    }

    /// Whether touches and buttons go through fast input now.
    public var isFastActive: Bool { state.withLock { $0.fast != nil && !$0.isStopped } }

    /// Queues `event` for the fast pump (a move replaces a waiting move).
    /// False when there is no fast path.
    @discardableResult
    private func enqueueFast(_ event: FastEvent) -> Bool {
        let outcome = state.withLock { state -> (accepted: Bool, start: Bool) in
            guard !state.isStopped, state.fast != nil else { return (false, false) }
            if Self.isMove(event), let last = state.fastQueue.last, Self.isMove(last), Self.isEdge(event) == Self.isEdge(last) {
                state.fastQueue[state.fastQueue.count - 1] = event
            } else {
                state.fastQueue.append(event)
            }
            if state.fastPumping { return (true, false) }
            state.fastPumping = true
            return (true, true)
        }
        if outcome.start { Task { [weak self] in await self?.pumpFast() } }
        return outcome.accepted
    }

    private static func isMove(_ event: FastEvent) -> Bool {
        switch event {
        case .move, .edge(.move, _, _): true
        default: false
        }
    }

    private static func isEdge(_ event: FastEvent) -> Bool {
        if case .edge = event { return true }
        return false
    }

    /// The touch an edge event becomes when the helper has no digitizer connection.
    private static func asTouch(_ phase: FastInputEdgePhase, _ point: CGPoint, id: UInt64?) -> FastEvent {
        switch phase {
        case .down: .down(point)
        case .move: .move(point)
        case .up: .up(point, id: id ?? 0)
        }
    }

    private func pumpFast() async {
        while true {
            let next = state.withLock { state -> (event: FastEvent, fast: any FastInputSending)? in
                guard !state.isStopped, let fast = state.fast, !state.fastQueue.isEmpty else {
                    state.fastPumping = false
                    return nil
                }
                return (state.fastQueue.removeFirst(), fast)
            }
            guard let next else { return }
            do {
                var event = next.event
                if case .edge(let phase, let point, let id) = event, state.withLock({ $0.edgeUnavailable }) {
                    event = Self.asTouch(phase, point, id: id)
                }
                if case .edge(let phase, let point, let id) = event {
                    do {
                        try await next.fast.edge(phase, point)
                        if phase == .up, let id { onActionEvent?(.finished(id: id)) }
                    } catch FastInputError.commandFailed(7, _) {
                        state.withLock { $0.edgeUnavailable = true }
                        event = Self.asTouch(phase, point, id: id)
                    }
                }
                switch event {
                case .edge: break
                case .down(let point): try await next.fast.down(point)
                case .move(let point): try await next.fast.move(point)
                case .up(let point, let id):
                    try await next.fast.up(point)
                    onActionEvent?(.finished(id: id))
                case .button(let button): try await next.fast.button(button)
                case .appSwitcher: try await next.fast.appSwitcher()
                case .hid(let page, let usage, let down): try await next.fast.hid(page: page, usage: usage, down: down)
                case .keys(let usages): try await next.fast.keys(usages)
                }
            } catch {
                fastFailed(error, at: next.event)
                return
            }
        }
    }

    /// The fast path failed: it is cleared, the touches waiting on it end,
    /// the failure is reported once and the buttons that had not run are
    /// pressed through the runner.
    private func fastFailed(_ error: Error, at failed: FastEvent) {
        let dropped = state.withLock { state -> [FastEvent]? in
            guard state.fast != nil else { state.fastPumping = false; return nil }
            state.fast = nil
            state.fastPumping = false
            state.keyboard = PhysicalKeyboardState()
            defer { state.fastQueue.removeAll() }
            return [failed] + state.fastQueue
        }
        guard let dropped else { return }
        cancelRepeat()
        _ = takeHeldButtons()
        for event in dropped {
            switch event {
            case .up(_, let id): onActionEvent?(.finished(id: id))
            case .edge(.up, _, let id?): onActionEvent?(.finished(id: id))
            case .button(let button): press(button)
            case .appSwitcher: showAppSwitcherViaRunner()
            default: break
            }
        }
        if !state.withLock({ $0.isStopped }) {
            onFastInputFailure?((error as? FastInputError) ?? .helperExited)
        }
    }

    private static let log = Logger(subsystem: "com.devicehubpro", category: "FastInput")

    /// The bottom edge band of the upright interface (ipb's `BottomEdgeFraction`, 2 %).
    private static func isBottomEdge(_ interface: CGPoint) -> Bool { interface.y >= 0.98 }

    /// Whether the interface's bottom edge is the stage's bottom: the stage is landscape and
    /// so is the interface (an app that rotates). Without an interface reading the
    /// interface follows the stage's pose.
    private func isLandscape() -> Bool {
        switch orientation() {
        case .landscapeLeft?, .landscapeRight?: interfaceLandscape?() ?? true
        default: false
        }
    }

    private func normalized(_ point: CGPoint, in frame: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x / frame.width, 0), 1), y: min(max(point.y / frame.height, 0), 1))
    }

    /// The rotation to the panel for a contact on `frame`, nil when the touch
    /// goes to the runner: the known orientation decides (and must agree with
    /// the frame's aspect); with none, a portrait frame is the panel itself.
    private func fastRotation(for frame: CGSize) -> FastInputPanelMapping.Rotation? {
        if let pose = orientation(), FastInputPanelMapping.rotation(for: pose) != nil {
            return FastInputPanelMapping.frame(frame, fits: pose) ? FastInputPanelMapping.rotation(for: pose) : nil
        }
        return frame.width <= frame.height ? .identity : nil
    }

    // MARK: Touches

    /// One input frame of the stage's contacts.
    public func receive(contacts: [TouchCommand]) {
        // A second finger (a pinch, an Option-drag) ends the gesture without
        // sending anything: the runner has no positional multi-touch.
        if contacts.contains(where: { $0.id != 0 }) {
            let had = state.withLock { state -> Bool in
                defer { state.contact = nil }
                return state.contact != nil
            }
            cancelRepeat()
            if had { onActionEvent?(.cancelled) }
            return
        }
        for command in contacts { receive(command) }
    }

    public func receive(_ command: TouchCommand) {
        guard command.id == 0 else { return }
        let point = CGPoint(x: Int(command.x), y: Int(command.y))
        switch command.phase {
        case .down:
            guard let frame = frameSize(), frame.width > 0, frame.height > 0 else { return }
            let time = now()
            let rotation = fastRotation(for: frame)
            let landscape = isLandscape()
            let began = state.withLock { state -> (began: Bool, fast: Bool) in
                guard !state.isStopped else { return (false, false) }
                let buttons = state.fast != nil && landscape && Self.isBottomEdge(normalized(point, in: frame))
                let fast = state.fast != nil && rotation != nil && !buttons
                // The home indicator is the panel's bottom edge: on an upside-down frame
                // that is the stage's top band, so the band follows the rotation.
                let panelPoint = (rotation ?? .identity).apply(normalized(point, in: frame))
                let edge = fast && !state.edgeUnavailable && Self.isBottomEdge(panelPoint)
                state.contact = Contact(down: point, last: point, frame: frame, startedAt: time, viaFast: fast,
                                        viaEdge: edge, viaButtons: buttons, anchor: point, anchorAt: time,
                                        panel: rotation ?? .identity)
                return (true, fast)
            }
            // Nothing is sent to the runner on mouse-down (no warm-up or
            // prefetch): it handles one request at a time, so a prefetch
            // would only delay the tap that follows.
            if began.began {
                Self.log.debug("down: \(began.fast ? "fast" : "runner", privacy: .public) path, frame \(Int(frame.width), privacy: .public)x\(Int(frame.height), privacy: .public)")
                onActionEvent?(.pressed(normalized(point, in: frame)))
                let first = rotation.map { $0.apply(normalized(point, in: frame)) }
                let edge = state.withLock { state -> Bool in
                    state.contact?.lastPanel = first
                    return state.contact?.viaEdge ?? false
                }
                if began.fast, let first {
                    if enqueueFast(edge ? .edge(.down, first, id: nil) : .down(first)) {
                        armRepeat()
                    } else {
                        state.withLock { $0.contact?.viaFast = false }
                    }
                }
            }
        case .move:
            let time = now()
            let moved = state.withLock { state -> (frame: CGSize, fast: Bool, edge: Bool, panel: FastInputPanelMapping.Rotation)? in
                state.contact?.last = point
                guard let contact = state.contact else { return nil }
                if contact.viaButtons {
                    let slop = tuning.landscapeRestSlop * Double(contact.frame.height)
                    if hypot(Double(point.x - contact.anchor.x), Double(point.y - contact.anchor.y)) > slop {
                        state.contact?.anchor = point
                        state.contact?.anchorAt = time
                    }
                }
                if contact.viaFast { state.contact?.lastPanel = contact.panel.apply(normalized(point, in: contact.frame)) }
                return (contact.frame, contact.viaFast, contact.viaEdge, contact.panel)
            }
            if let moved {
                let normal = normalized(point, in: moved.frame)
                onActionEvent?(.moved(normal))
                if moved.fast {
                    let panel = moved.panel.apply(normal)
                    enqueueFast(moved.edge ? .edge(.move, panel, id: nil) : .move(panel))
                    armRepeat()
                }
            }
        case .up:
            let time = now()
            let finished = state.withLock { state -> Contact? in
                defer { state.contact = nil }
                guard !state.isStopped else { return nil }
                return state.contact
            }
            cancelRepeat()
            guard var open = finished else { return }
            open.last = point
            let contact = open
            let touchID = state.withLock { state -> UInt64 in
                state.nextID += 1
                return state.nextID
            }
            let touch = (id: touchID, point: normalized(point, in: contact.frame))
            if contact.viaButtons {
                onActionEvent?(.accepted(id: touch.id, point: touch.point))
                let height = Double(contact.frame.height)
                let rise = Double(contact.down.y - point.y) / height
                let rested = hypot(Double(point.x - contact.anchor.x), Double(point.y - contact.anchor.y)) <= tuning.landscapeRestSlop * height
                    && time - contact.anchorAt >= tuning.landscapeRestHold
                if rested, rise >= tuning.landscapeSwitcherRise {
                    enqueueFast(.appSwitcher)
                } else if rise >= tuning.landscapeHomeRise {
                    enqueueFast(.button(.home))
                }
                onActionEvent?(.finished(id: touch.id))
                return
            }
            if contact.viaFast {
                onActionEvent?(.accepted(id: touch.id, point: touch.point))
                let panel = contact.panel.apply(touch.point)
                if !enqueueFast(contact.viaEdge ? .edge(.up, panel, id: touch.id) : .up(panel, id: touch.id)) {
                    // The fast path went away mid-gesture: nothing more to send.
                    onActionEvent?(.finished(id: touch.id))
                }
                return
            }
            let duration = max(0, time - contact.startedAt)
            let control = self.control
            let tuning = self.tuning
            enqueue(dropIfFull: true, touch: touch) { [weak self] in
                await self?.perform(contact: contact, duration: duration, control: control, tuning: tuning)
            }
        }
    }

    /// (Re)starts the rest timer: `restRepeat` after the last point was sent.
    private func armRepeat() {
        let gen = state.withLock { state -> Int in
            state.repeatGen += 1
            return state.repeatGen
        }
        let cancel = schedule(tuning.restRepeat) { [weak self] in self?.repeatTick(gen) }
        let previous = state.withLock { state -> (@Sendable () -> Void)? in
            guard state.repeatGen == gen else { return cancel }
            let previous = state.repeatCancel
            state.repeatCancel = cancel
            return previous
        }
        previous?()
    }

    private func cancelRepeat() {
        let cancel = state.withLock { state -> (@Sendable () -> Void)? in
            state.repeatGen += 1
            defer { state.repeatCancel = nil }
            return state.repeatCancel
        }
        cancel?()
    }

    /// The finger has rested: re-send its last point unless a send is still
    /// queued or running, then wait again.
    private func repeatTick(_ gen: Int) {
        let resend = state.withLock { state -> (point: CGPoint, edge: Bool, busy: Bool)? in
            guard state.repeatGen == gen, !state.isStopped, state.fast != nil,
                  let contact = state.contact, contact.viaFast, let point = contact.lastPanel else { return nil }
            return (point, contact.viaEdge, !state.fastQueue.isEmpty || state.fastPumping)
        }
        guard let resend else { return }
        if !resend.busy { enqueueFast(resend.edge ? .edge(.move, resend.point, id: nil) : .move(resend.point)) }
        armRepeat()
    }

    private func perform(contact: Contact, duration: TimeInterval, control: any PhysicalControlling, tuning: Tuning) async {
        guard let portrait = await control.portraitSize(),
              let from = PhysicalControlGeometry.point(forFramePoint: contact.down, frame: contact.frame, portrait: portrait),
              let to = PhysicalControlGeometry.point(forFramePoint: contact.last, frame: contact.frame, portrait: portrait)
        else { return }
        do {
            let distance = hypot(to.x - from.x, to.y - from.y)
            if distance < tuning.tapSlop {
                try await control.tap(from)
            } else {
                let clamped = min(max(duration, tuning.swipeDuration.lowerBound), tuning.swipeDuration.upperBound)
                try await control.swipe(from: from, to: to, duration: clamped)
            }
        } catch {
            report(error)
        }
    }

    // MARK: Keys

    /// One Mac key: text is typed, Delete, Return and Tab are typed as their
    /// control characters, every other key is left alone.
    public func receive(_ command: KeyboardCommand) {
        let piece: String
        switch command {
        case .text(let text): piece = text
        case .specialKey(let code):
            guard let mapped = Self.specialKeyText[code] else { return }
            piece = mapped
        }
        guard !piece.isEmpty else { return }
        let batchIsFull = state.withLock { state -> Bool in
            guard !state.isStopped else { return false }
            state.buffer += piece
            return state.buffer.count >= tuning.typingBatch
        }
        if batchIsFull {
            flush()
        } else {
            armTimer()
        }
    }

    /// One Mac key event as the same physical key on the phone (fast input
    /// only: nothing is sent without it). Each change of the held set is one
    /// report, in order.
    public func receive(physical event: PhysicalKeyEvent) {
        let reports = state.withLock { state -> [[Int]] in
            guard !state.isStopped, state.fast != nil else { return [] }
            return state.keyboard.apply(event)
        }
        for usages in reports { enqueueFast(.keys(usages)) }
    }

    /// macOS virtual key codes typed as their control character.
    static let specialKeyText: [UInt16: String] = [
        51: "\u{8}",  // delete
        36: "\n",     // return
        76: "\n",     // keypad enter
        48: "\t",     // tab
    ]

    private func armTimer() {
        let idle = tuning.typingIdle
        let cancel = schedule(idle) { [weak self] in self?.flush() }
        let previous = state.withLock { state -> (@Sendable () -> Void)? in
            let previous = state.cancelTimer
            state.cancelTimer = cancel
            return previous
        }
        previous?()
    }

    /// Queues what was typed so far; keys typed while it runs go in the next
    /// send, after it.
    func flush() {
        let text = state.withLock { state -> String? in
            state.cancelTimer = nil
            guard !state.isStopped, !state.buffer.isEmpty else { return nil }
            let text = state.buffer
            state.buffer = ""
            return text
        }
        guard let text else { return }
        typeViaRunner(text)
    }

    private func typeViaRunner(_ text: String) {
        let control = self.control
        enqueue(dropIfFull: false) { [weak self] in
            await self?.type(text, control: control)
        }
    }

    private func type(_ text: String, control: any PhysicalControlling) async {
        do {
            guard let app = try await control.foregroundApp() else {
                throw PhysicalControlError.noForegroundApp
            }
            try await control.type(text, bundleID: app)
        } catch {
            report(error)
        }
    }

    // MARK: Buttons

    /// The Apple chrome's button, every one of them, as its real down and up edges through
    /// fast input (so a hold, a combination or a repeating volume key is the Mac's own): in
    /// the same queue as touches and keys. A button still down after `buttonHoldLimit` is
    /// released. Without fast input only Home and volume act, on the down edge, through the
    /// runner.
    public func receive(button: SimulatorHardwareButton, isDown: Bool) {
        let (page, usage) = button.hidCode
        if enqueueFast(.hid(page: page, usage: usage, down: isDown)) {
            holdWatch(key: [page, usage], isDown: isDown)
            return
        }
        guard isDown else { return }
        switch button {
        case .home: press(.home)
        case .volumeUp: press(.volumeUp)
        case .volumeDown: press(.volumeDown)
        default: return
        }
    }

    private func holdWatch(key: [Int], isDown: Bool) {
        let previous = state.withLock { $0.heldButtons.removeValue(forKey: key) }
        previous?()
        guard isDown else { return }
        let limit = tuning.buttonHoldLimit
        let cancel = schedule(limit) { [weak self] in
            guard let self else { return }
            let stuck = self.state.withLock { $0.heldButtons.removeValue(forKey: key) != nil }
            if stuck { self.enqueueFast(.hid(page: key[0], usage: key[1], down: false)) }
        }
        let accepted = state.withLock { state -> Bool in
            guard !state.isStopped, state.fast != nil else { return false }
            state.heldButtons[key] = cancel
            return true
        }
        if !accepted { cancel() }
    }

    /// Cancels every stuck-button timer and returns the buttons still held.
    private func takeHeldButtons() -> [[Int]] {
        let held = state.withLock { state -> [[Int]: @Sendable () -> Void] in
            defer { state.heldButtons = [:] }
            return state.heldButtons
        }
        for cancel in held.values { cancel() }
        return held.keys.sorted { $0.lexicographicallyPrecedes($1) }
    }

    /// Presses a phone button (the Device and Controls menus).
    public func press(_ button: PhysicalControlButton) {
        if enqueueFast(.button(button)) { return }
        let control = self.control
        enqueue(dropIfFull: false) { [weak self] in
            do {
                try await control.press(button)
            } catch {
                self?.report(error)
            }
        }
    }

    /// The App Switcher: fast input's key when active, else the runner's held swipe.
    public func showAppSwitcher() {
        if enqueueFast(.appSwitcher) { return }
        showAppSwitcherViaRunner()
    }

    private func showAppSwitcherViaRunner() {
        let control = self.control
        enqueue(dropIfFull: false) { [weak self] in
            do { try await control.showAppSwitcher() } catch { self?.report(error) }
        }
    }

    // MARK: Ending

    /// Drops the gesture and the typed text and ignores everything after:
    /// Control ended.
    public func stop() {
        let held = takeHeldButtons()
        let fast = state.withLock { $0.fast }
        let cancel = state.withLock { state -> (@Sendable () -> Void)? in
            state.isStopped = true
            state.fast = nil
            state.fastQueue.removeAll()
            state.contact = nil
            state.buffer = ""
            defer { state.cancelTimer = nil }
            return state.cancelTimer
        }
        cancel?()
        cancelRepeat()
        // A button still down would stay held on the phone.
        if let fast, !held.isEmpty {
            Task { for key in held { try? await fast.hid(page: key[0], usage: key[1], down: false) } }
        }
    }

    private func report(_ error: Error) {
        let failure: PhysicalControlError
        if let error = error as? PhysicalControlError {
            failure = error
        } else if error is CancellationError {
            return
        } else {
            failure = .transportFailed((error as NSError).domain)
        }
        if state.withLock({ $0.isStopped }) { return }
        if failure.isSoft {
            onSoftFailure(failure)
        } else {
            onFailure(failure)
        }
    }
}
