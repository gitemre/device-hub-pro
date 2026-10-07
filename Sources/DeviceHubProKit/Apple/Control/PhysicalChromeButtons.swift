import Foundation
import Synchronization

/// The Apple chrome's hardware buttons of a physical iPhone while Control is off:
/// every button goes as its real down and up edges through fast input
/// (`FastInputSending.hid`), a fast session starting on the first press and
/// the edges waiting for it in order (never the XCTest runner).
///
/// - An edge older than `staleAfter` when the session is ready is dropped with
///   its partner (a `down` dropped means its `up` is too).
/// - A button down with no up for `holdLimit` is released.
/// - `stop()` ends the session it started (which releases what is held).
///
/// With Control on, `PhysicalControlInputRouter` carries the buttons instead.
public final class PhysicalChromeButtons: Sendable {
    public struct Tuning: Sendable {
        public var staleAfter: TimeInterval = 2
        public var holdLimit: TimeInterval = 10
        /// How long `tap(button:)` holds a button (the helper's own click holds it 80 ms).
        public var clickHold: TimeInterval = 0.08
        public init() {}
    }

    private struct Edge: Sendable {
        var key: [Int]
        var down: Bool
        var at: TimeInterval
    }

    private struct State {
        var generation = 0
        var session: (any FastInputControlling)?
        var starting = false
        var pumping = false
        var queue: [Edge] = []
        /// Buttons whose `down` was dropped as stale: their `up` is dropped too.
        var skipped: Set<[Int]> = []
        var held: [[Int]: @Sendable () -> Void] = [:]
    }

    private let start: @Sendable () async throws -> any FastInputControlling
    private let schedule: PhysicalControlInputRouter.Scheduler
    private let now: @Sendable () -> TimeInterval
    private let onFailure: @Sendable (FastInputError) -> Void
    private let tuning: Tuning
    private let state = Mutex(State())

    public init(
        start: @escaping @Sendable () async throws -> any FastInputControlling,
        schedule: @escaping PhysicalControlInputRouter.Scheduler = PhysicalControlInputRouter.defaultScheduler,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        tuning: Tuning = Tuning(),
        onFailure: @escaping @Sendable (FastInputError) -> Void = { _ in }
    ) {
        self.start = start
        self.schedule = schedule
        self.now = now
        self.tuning = tuning
        self.onFailure = onFailure
    }

    /// Whether a session runs or is starting.
    public var isActive: Bool { state.withLock { $0.session != nil || $0.starting } }

    public func receive(button: SimulatorHardwareButton, isDown: Bool) {
        let key = [button.hidCode.page, button.hidCode.usage]
        let previous = state.withLock { $0.held.removeValue(forKey: key) }
        previous?()
        enqueue(Edge(key: key, down: isDown, at: now()))
        guard isDown else { return }
        let generation = state.withLock { $0.generation }
        let cancel = schedule(tuning.holdLimit) { [weak self] in
            guard let self else { return }
            let stuck = self.state.withLock { state in
                state.generation == generation && state.held.removeValue(forKey: key) != nil
            }
            if stuck { self.enqueue(Edge(key: key, down: false, at: self.now())) }
        }
        let kept = state.withLock { state -> Bool in
            guard state.generation == generation else { return false }
            state.held[key] = cancel
            return true
        }
        if !kept { cancel() }
    }

    /// A click (a menu item): down, and up after `clickHold`.
    public func tap(button: SimulatorHardwareButton) {
        receive(button: button, isDown: true)
        _ = schedule(tuning.clickHold) { [weak self] in self?.receive(button: button, isDown: false) }
    }

    private func enqueue(_ edge: Edge) {
        let action = state.withLock { state -> (startSession: Bool, pump: Bool, generation: Int) in
            state.queue.append(edge)
            if state.session != nil {
                if state.pumping { return (false, false, state.generation) }
                state.pumping = true
                return (false, true, state.generation)
            }
            if state.starting { return (false, false, state.generation) }
            state.starting = true
            return (true, false, state.generation)
        }
        if action.startSession {
            let generation = action.generation
            Task { [weak self] in await self?.startSession(generation: generation) }
        } else if action.pump {
            Task { [weak self] in await self?.pump() }
        }
    }

    private func startSession(generation: Int) async {
        do {
            let started = try await start()
            let accepted = state.withLock { state -> Bool in
                guard state.generation == generation else { return false }
                state.session = started
                state.starting = false
                state.pumping = true
                return true
            }
            if accepted { await pump() } else { await started.stop() }
        } catch {
            let current = state.withLock { state -> Bool in
                guard state.generation == generation else { return false }
                state.starting = false
                state.queue.removeAll()
                state.skipped.removeAll()
                return true
            }
            if current { onFailure((error as? FastInputError) ?? .helperExited) }
        }
    }

    private func pump() async {
        while true {
            let next = state.withLock { state -> (edge: Edge, session: any FastInputControlling, generation: Int)? in
                guard let session = state.session, !state.queue.isEmpty else {
                    state.pumping = false
                    return nil
                }
                return (state.queue.removeFirst(), session, state.generation)
            }
            guard let next else { return }
            let skip = state.withLock { state -> Bool in
                if next.edge.down {
                    if now() - next.edge.at > tuning.staleAfter {
                        state.skipped.insert(next.edge.key)
                        return true
                    }
                    return false
                }
                return state.skipped.remove(next.edge.key) != nil
            }
            if skip { continue }
            do {
                try await next.session.hid(page: next.edge.key[0], usage: next.edge.key[1], down: next.edge.down)
            } catch {
                let failed = state.withLock { state -> Bool in
                    guard state.generation == next.generation else { return false }
                    state.session = nil
                    state.pumping = false
                    state.queue.removeAll()
                    state.skipped.removeAll()
                    for cancel in state.held.values { cancel() }
                    state.held = [:]
                    return true
                }
                if failed {
                    await next.session.stop()
                    onFailure((error as? FastInputError) ?? .helperExited)
                }
                return
            }
        }
    }

    /// Releases what is held, ends the session (if one started) and forgets the queue;
    /// the next press starts a new one.
    @discardableResult
    public func stop() -> Task<Void, Never> {
        let (session, held) = takeAll()
        for cancel in held { cancel() }
        return Task { await session?.stop() }
    }

    /// Ends the session at once, from any thread (the app's quit).
    public func terminateNow() {
        let (session, held) = takeAll()
        for cancel in held { cancel() }
        session?.terminateNow()
    }

    private func takeAll() -> (session: (any FastInputControlling)?, held: [@Sendable () -> Void]) {
        state.withLock { state in
            state.generation += 1
            let taken = (state.session, Array(state.held.values))
            state.session = nil
            state.starting = false
            state.pumping = false
            state.queue.removeAll()
            state.skipped.removeAll()
            state.held = [:]
            return taken
        }
    }
}
