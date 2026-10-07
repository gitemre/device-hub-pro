import CoreGraphics
import Foundation
import Synchronization
import os

/// Fast input on one physical iPhone (AGENTS.md):
/// a resident `fastinput-helper` (private CoreDevice HID path, vendored from
/// ipb, see `fastinput/PROVENANCE.md`) fed through a line protocol, and a
/// `devicectl` child that holds the phone's tunnel lease.
///
/// Opt-in and default off; `DHP_DISABLE_FAST_INPUT` (any non-empty
/// value) makes it unavailable. It is only ever pointed at a phone the app
/// already enabled. One command is outstanding at a time; moves are paced to
/// at most 120 a second. Any error ends the session: the caller falls back to
/// the public-XCTest runner.
public actor FastInputSession: FastInputControlling {
    public struct Configuration: Sendable, Equatable {
        /// How long the helper may take to print `ready` or `fatal`.
        public var startTimeout: Duration = .seconds(25)
        /// How often a start is retried while the tunnel is not up yet (the
        /// lease needs a moment to bring it up).
        public var tunnelAttempts = 6
        public var tunnelRetryDelay: Duration = .milliseconds(1500)
        /// Moves are at least this far apart.
        public var minMoveInterval: TimeInterval = 1.0 / 120.0
        /// How long `stop()` waits for the helper to quit before killing it.
        public var quitGrace: Duration = .seconds(1)

        public init() {}
    }

    private enum State: Equatable {
        case idle, starting, ready, stopped
        case failed(FastInputError)
    }

    public static let disableVariable = "DHP_DISABLE_FAST_INPUT"

    /// The kill switch: any non-empty value.
    public static func isDisabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !(environment[disableVariable] ?? "").isEmpty
    }

    private let coreDeviceIdentifier: String
    private let helperURL: URL
    private let launcher: any FastInputChildLauncher
    private let lease: any FastInputLease
    private let configuration: Configuration
    private let environment: [String: String]
    private let now: @Sendable () -> TimeInterval
    private let sleep: @Sendable (Duration) async throws -> Void

    private var state = State.idle
    private var child: (any FastInputChild)?
    private let liveChild = Mutex<(any FastInputChild)?>(nil)
    private var consumer: Task<Void, Never>?
    private var buffered: [FastInputReply] = []
    private var waiter: (id: UInt64, continuation: CheckedContinuation<FastInputReply, Error>)?
    private var waiterCounter: UInt64 = 0
    private var endedWith: FastInputError?
    private var busy = false
    private var gate: [CheckedContinuation<Void, Never>] = []
    private var lastMoveAt: TimeInterval = -1
    /// HID buttons (page, usage) that went down and have not come up.
    private var heldHID: Set<[Int]> = []
    /// The helper's touchscreen service id, once ready (not an identifier of
    /// the phone; kept for diagnostics only).
    public private(set) var serviceID: String?

    public init(
        coreDeviceIdentifier: String,
        helperURL: URL,
        launcher: any FastInputChildLauncher,
        lease: any FastInputLease,
        configuration: Configuration = Configuration(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (Duration) async throws -> Void = FastInputClock.sleep
    ) {
        self.coreDeviceIdentifier = coreDeviceIdentifier
        self.helperURL = helperURL
        self.launcher = launcher
        self.lease = lease
        self.configuration = configuration
        self.environment = environment
        self.now = now
        self.sleep = sleep
    }

    // MARK: Starting

    /// Holds the tunnel, starts the helper and waits until it is ready.
    public func start() async throws {
        guard !Self.isDisabled(environment: environment) else { throw FastInputError.disabled }
        guard state == .idle else { throw state == .stopped ? FastInputError.stopped : FastInputError.notReady }
        state = .starting
        do {
            try await lease.start()
            try await launchUntilReady()
        } catch {
            let failure = (error as? FastInputError) ?? .launchFailed((error as NSError).domain)
            await abort(with: failure)
            throw failure
        }
        guard state == .starting else { throw FastInputError.stopped }
        state = .ready
    }

    private func launchUntilReady() async throws {
        var attempt = 0
        while true {
            attempt += 1
            let started = try launcher.launch(
                executable: helperURL,
                arguments: [coreDeviceIdentifier],
                environment: nil,
                wantsLines: true
            )
            child = started
            liveChild.withLock { $0 = started }
            buffered = []
            endedWith = nil
            consume(started)
            switch try await nextReply(timeout: configuration.startTimeout, onTimeout: .startTimedOut) {
            case .ready(let id):
                serviceID = id
                return
            case .fatal(let code, let message):
                started.terminate()
                consumer?.cancel()
                if code == 4 {
                    if attempt < configuration.tunnelAttempts {
                        try await sleep(configuration.tunnelRetryDelay)
                        guard state == .starting else { throw FastInputError.stopped }
                        continue
                    }
                    throw FastInputError.tunnelNotConnected
                }
                throw code == 3 ? FastInputError.socketRefused(message) : FastInputError.helperFatal(code: code, message: message)
            default:
                throw FastInputError.helperFatal(code: 0, message: "unexpected first line")
            }
        }
    }

    // MARK: Replies

    private func consume(_ started: any FastInputChild) {
        consumer?.cancel()
        consumer = Task { [weak self] in
            for await line in started.lines {
                guard let reply = FastInputReply.parse(line) else { continue }
                await self?.deliver(reply)
            }
            await self?.childEnded(started)
        }
    }

    private func deliver(_ reply: FastInputReply) {
        if let waiting = waiter {
            waiter = nil
            waiting.continuation.resume(returning: reply)
        } else {
            buffered.append(reply)
        }
    }

    private func childEnded(_ ended: any FastInputChild) {
        guard child === ended else { return }
        endedWith = .helperExited
        if let waiting = waiter {
            waiter = nil
            waiting.continuation.resume(throwing: FastInputError.helperExited)
        }
    }

    private func timeoutWaiter(_ id: UInt64, error: FastInputError) {
        guard let waiting = waiter, waiting.id == id else { return }
        waiter = nil
        waiting.continuation.resume(throwing: error)
    }

    private func nextReply(timeout: Duration, onTimeout: FastInputError) async throws -> FastInputReply {
        if !buffered.isEmpty { return buffered.removeFirst() }
        if let endedWith { throw endedWith }
        waiterCounter += 1
        let id = waiterCounter
        let sleep = self.sleep
        let timer = Task { [weak self] in
            do { try await sleep(timeout) } catch { return }
            await self?.timeoutWaiter(id, error: onTimeout)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = (id, continuation)
        }
    }

    // MARK: Commands

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { gate.append($0) }
    }

    private func release() {
        if gate.isEmpty {
            busy = false
        } else {
            gate.removeFirst().resume()
        }
    }

    /// One line per command and its answer (verb and result only: no
    /// identifier), for `log stream --predicate 'category == "FastInput"'`.
    private static let log = Logger(subsystem: "com.devicehubpro", category: "FastInput")

    private func send(_ command: FastInputCommand) async throws {
        let verb = command.line.split(separator: " ").first.map(String.init) ?? "?"
        do {
            try await sendUnlogged(command)
            Self.log.debug("\(verb, privacy: .public) ok")
        } catch {
            Self.log.error("\(verb, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private func sendUnlogged(_ command: FastInputCommand) async throws {
        try checkReady()
        await acquire()
        defer { release() }
        try checkReady()
        guard let child else { throw FastInputError.notReady }
        do {
            try child.write(command.line)
            switch try await nextReply(timeout: command.answerTimeout, onTimeout: .commandTimedOut) {
            case .ok:
                return
            case .err(let code, let message):
                throw FastInputError.commandFailed(code: code, message: message)
            default:
                throw FastInputError.commandFailed(code: 0, message: "unexpected answer")
            }
        } catch {
            let failure = (error as? FastInputError) ?? .helperExited
            // No digitizer connection is not a broken session: the caller falls back to touches.
            if case .edge = command, case .commandFailed(7, _) = failure { throw failure }
            await abort(with: failure)
            throw failure
        }
    }

    private func checkReady() throws {
        switch state {
        case .ready: return
        case .stopped: throw FastInputError.stopped
        case .failed(let error): throw error
        case .idle, .starting: throw FastInputError.notReady
        }
    }

    public func down(_ point: CGPoint) async throws {
        try await send(.down(x: point.x, y: point.y))
    }

    public func move(_ point: CGPoint) async throws {
        let wait = lastMoveAt + configuration.minMoveInterval - now()
        if wait > 0 { try await sleep(.seconds(wait)) }
        lastMoveAt = now()
        try await send(.move(x: point.x, y: point.y))
    }

    public func up(_ point: CGPoint) async throws {
        try await send(.up(x: point.x, y: point.y))
    }

    /// A tap the helper does whole: down, `holdMs`, up.
    public func tap(_ point: CGPoint, holdMs: Int = 10) async throws {
        try await send(.tap(x: point.x, y: point.y, holdMs: holdMs))
    }

    public func edge(_ phase: FastInputEdgePhase, _ point: CGPoint) async throws {
        if phase == .move {
            let wait = lastMoveAt + configuration.minMoveInterval - now()
            if wait > 0 { try await sleep(.seconds(wait)) }
            lastMoveAt = now()
        }
        try await send(.edge(phase, x: point.x, y: point.y))
    }

    public func button(_ button: PhysicalControlButton) async throws {
        try await send(.button(button))
    }

    /// One edge of a HID button. The session remembers what is held so `stop()` can release it.
    public func hid(page: Int, usage: Int, down: Bool) async throws {
        let key = [page, usage]
        if down { heldHID.insert(key) } else { heldHID.remove(key) }
        try await send(.hid(page: page, usage: usage, down: down))
    }

    public func appSwitcher() async throws {
        try await send(.appSwitcher)
    }

    public func key(usage: Int, action: FastInputKeyAction = .tap) async throws {
        try await send(.key(usage: usage, action: action))
    }

    /// One keyboard report with exactly `usages` held (empty: all up).
    public func keys(_ usages: [Int]) async throws {
        try await send(.keys(usages))
    }

    public func ping() async throws {
        try await send(.ping)
    }

    // MARK: Ending

    /// The session failed: the helper and the lease end; later calls throw
    /// `error`.
    private func abort(with error: FastInputError) async {
        if case .stopped = state {} else if case .failed = state {} else { state = .failed(error) }
        endedWith = error
        if let waiting = waiter {
            waiter = nil
            waiting.continuation.resume(throwing: error)
        }
        consumer?.cancel()
        child?.terminate()
        await lease.stop()
    }

    /// Sends `quit`, ends the helper and the lease. Safe to call again.
    public func stop() async {
        if state == .stopped { return }
        let wasReady = state == .ready
        // A button still down would stay held on the phone.
        if wasReady {
            for key in heldHID.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                try? await send(.hid(page: key[0], usage: key[1], down: false))
            }
        }
        heldHID.removeAll()
        state = .stopped
        endedWith = .stopped
        if let waiting = waiter {
            waiter = nil
            waiting.continuation.resume(throwing: FastInputError.stopped)
        }
        if let child, wasReady, child.isRunning {
            try? child.write(FastInputCommand.quit.line)
            let deadline = ContinuousClock.now + configuration.quitGrace
            while child.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        consumer?.cancel()
        if let child, child.isRunning {
            child.terminate()
            try? await Task.sleep(for: .milliseconds(50))
            child.kill()
        }
        await lease.stop()
        for waiting in gate { waiting.resume() }
        gate.removeAll()
    }

    /// Ends the helper and the lease at once, from any thread (the app's quit).
    public nonisolated func terminateNow() {
        liveChild.withLock { $0 }?.terminate()
        lease.terminateNow()
    }
}

extension FastInputSession {
    /// The real session for `client`'s phone: the helper is built from
    /// `fastinput/` into the cache (or found there), the lease keeper runs the
    /// client's `devicectl` against the same CoreDevice identifier.
    ///
    /// Throws `.disabled` under the kill switch, `.sourcesMissing` when
    /// `fastinput/` is not part of this build, `.launchFailed` without Xcode.
    public static func live(
        client: DevicectlPhysicalClient,
        toolchain: AppleToolchain,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> FastInputSession {
        guard !isDisabled(environment: environment) else { throw FastInputError.disabled }
        guard let sources = FastInputBuilder.locateSources(environment: environment) else {
            throw FastInputError.sourcesMissing
        }
        guard let developerDirectory = toolchain.developerDirectory else {
            throw FastInputError.launchFailed("Xcode was not found")
        }
        let build = try await FastInputBuilder(
            sourcesDirectory: sources,
            developerDirectory: developerDirectory,
            xcodeBuild: toolchain.xcodeBuild
        ).ensureHelper(progress: progress)
        let launcher = ProcessFastInputChildLauncher()
        // One tunnel lease per phone, shared with the native live view.
        let devicectlURL = client.devicectlURL
        let identifier = client.device.coreDeviceIdentifier
        let lease = SharedTunnelLeases.shared.lease(for: identifier) {
            TunnelLeaseKeeper(
                devicectlURL: devicectlURL,
                coreDeviceIdentifier: identifier,
                developerDirectory: developerDirectory,
                launcher: launcher
            )
        }
        return FastInputSession(
            coreDeviceIdentifier: client.device.coreDeviceIdentifier,
            helperURL: build.helperURL,
            launcher: launcher,
            lease: lease,
            environment: environment
        )
    }
}
