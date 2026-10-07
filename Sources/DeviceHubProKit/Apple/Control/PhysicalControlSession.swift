import Foundation
import Synchronization
import os

/// What one tap or swipe cost, as the Mac and the runner measured it.
public struct PhysicalControlActionTiming: Sendable, Equatable {
    public enum Kind: String, Sendable { case tap, swipe }
    public var kind: Kind
    /// Mac time from the operation starting to run until the answer (the queue wait excluded).
    public var roundTripMs: Double
    /// The runner's time choosing and resolving the reference; nil when it sent none.
    public var runnerResolveMs: Double?
    /// The runner's time inside the XCUICoordinate call; nil when it sent none.
    public var runnerActionMs: Double?
    /// The bundle identifier the runner used as the coordinate reference.
    public var reference: String?
    /// The phone's clock (seconds since 1970) just before the runner's tap
    /// call; nil for a swipe or an older runner.
    public var runnerTapStart: Double?

    public init(
        kind: Kind, roundTripMs: Double, runnerResolveMs: Double? = nil, runnerActionMs: Double? = nil,
        reference: String? = nil, runnerTapStart: Double? = nil
    ) {
        self.kind = kind
        self.roundTripMs = roundTripMs
        self.runnerResolveMs = runnerResolveMs
        self.runnerActionMs = runnerActionMs
        self.reference = reference
        self.runnerTapStart = runnerTapStart
    }
}

/// Where a control session is.
public enum PhysicalControlState: Sendable, Equatable {
    /// Not started, or stopped.
    case stopped
    /// Building or finding the signed runner.
    case preparing(String)
    /// The runner is being started on the phone (or started again).
    case starting(String)
    /// The runner answers; actions run.
    case ready
    /// The session ended with this error; the runner is stopped.
    case failed(PhysicalControlError)

    public var isReady: Bool { self == .ready }
}

/// What the app watches: the state, whether an action is in flight or
/// waiting, and the phone's last known orientation.
public struct PhysicalControlSnapshot: Sendable, Equatable {
    public var state: PhysicalControlState
    public var isBusy: Bool
    public var orientation: PhysicalControlOrientation?
    /// Grows with every change the session reports, so a receiver that gets
    /// them out of order keeps the newest.
    public var revision: UInt64

    public init(
        state: PhysicalControlState,
        isBusy: Bool = false,
        orientation: PhysicalControlOrientation? = nil,
        revision: UInt64 = 0
    ) {
        self.state = state
        self.isBusy = isBusy
        self.orientation = orientation
        self.revision = revision
    }
}

/// What the app's input side asks of a control session. `PhysicalControlSession`
/// is the real one; tests hand in a fake.
public protocol PhysicalControlling: Sendable {
    /// Builds the runner if needed, starts it and waits until it answers; on
    /// return the state is `.ready` or `.failed` (also thrown).
    func start() async throws
    /// Ends the runner: `POST /stop`, then SIGINT, then SIGTERM.
    func stop() async
    /// Ends the runner at once, without waiting (the app's quit): SIGINT to
    /// the child. Safe from any thread.
    func terminateNow()

    func snapshot() async -> PhysicalControlSnapshot
    /// The phone's portrait size in points, once the runner answered
    /// `/screen`.
    func portraitSize() async -> CGSize?

    func tap(_ point: CGPoint) async throws
    func swipe(from: CGPoint, to: CGPoint, duration: TimeInterval) async throws
    func type(_ text: String, bundleID: String) async throws
    func press(_ button: PhysicalControlButton) async throws
    func setOrientation(_ orientation: PhysicalControlOrientation) async throws -> PhysicalControlOrientation
    func orientation() async throws -> PhysicalControlOrientation
    /// Presents Siri (`text`, when given, is processed as recognised speech).
    /// Throws `PhysicalControlError.unsupported` when the phone has no Siri
    /// route.
    func activateSiri(text: String?) async throws
    /// Shows the App Switcher (a held swipe up from the bottom edge).
    func showAppSwitcher() async throws
    /// Which of `ids` is in the foreground, in the order given.
    func foreground(ids: [String]) async throws -> [String]
    /// The app that owns the keyboard: the first of the session's candidate
    /// bundle identifiers that is in the foreground; nil when none is.
    func foregroundApp() async throws -> String?
}

/// The control of one physical iPhone through the public-XCTest runner of
/// `ios/agent`.
///
/// **Security.** The runner binds only to the device end of the CoreDevice
/// tunnel (`fd00::/8`, read from the phone's `details`), on a fixed port,
/// and answers only requests that carry this launch's token. The Mac side
/// refuses any other address (`PhysicalControlEndpoint`), never falls back to
/// another interface and never sends a request without the token. The token
/// is fresh per launch, at least 128 bits, held in memory and in the child's
/// environment only, and never logged or shown. Nothing here names the UDID,
/// the address, the token or the team in a message it keeps.
///
/// **Lifecycle.** `start()`: the signed runner is built and cached
/// (`PhysicalControlProvisioning`), the child `xcodebuild` is started
/// (`PhysicalControlRunnerLaunching`) and `/status` is polled until it
/// answers (30 s when the build was cached, 120 s the first time, which also
/// installs the runner on the phone). One relaunch is allowed after the
/// runner dies; the second death ends the session. `stop()` posts `/stop`,
/// then interrupts and terminates the child.
///
/// **Actions.** One at a time, in order. At most one waits behind the one in
/// flight; a third gets `.busy`. A failed action never repeats itself: a
/// runner that died and came back gives `.runnerRestarted`.
public actor PhysicalControlSession: PhysicalControlling {
    public struct Timing: Sendable {
        /// How long `/status` gets when the build was cached.
        public var warmStart: Duration = .seconds(30)
        /// How long it gets after a build (the first run installs the apps).
        public var firstRunStart: Duration = .seconds(120)
        public var pollInterval: Duration = .milliseconds(400)
        /// How often an idle session checks that the runner is still there;
        /// nil for never (tests drive `checkHealth()`).
        public var healthInterval: Duration? = .seconds(5)
        public var actionTimeout: Duration = .seconds(20)
        public var typeTimeoutPerCharacter: Duration = .milliseconds(150)
        public var stopGrace: Duration = .seconds(3)
        /// How long the candidate list of the foreground lookup is kept.
        public var candidateRefresh: Duration = .seconds(120)
        /// The least time between two background refreshes after a Springboard answer
        /// although candidates were sent (a miss: the app is not in the list).
        public var missRefresh: Duration = .seconds(10)
        /// The runner's own watchdog: it ends itself after this long.
        public var runnerMaximumSeconds = 28_800

        public init() {}
    }

    /// Bundle identifiers no candidate list may reach the runner with: the
    /// runner's own (a lookup of it hangs the runner).
    static let excludedBundlePrefixes = ["com.devicehubpro.agent.uitests"]
    /// System overlay services the runner reports as always in the
    /// foreground: taken as the coordinate reference, the tap waits on a
    /// snapshot that never comes (measured on an iPhone 12, iOS 27.0, with
    /// the all-apps list; its devicectl flags match an ordinary default app).
    static let excludedBundleIDs: Set<String> = ["com.apple.HangHUD"]
    static let springboard = "com.apple.springboard"
    static let maximumCandidates = 400

    private let target: PhysicalControlTarget
    private let team: @Sendable () -> String?
    private let tunnelAddress: @Sendable () async throws -> String?
    private let candidates: @Sendable () async -> [String]
    private let provisioner: any PhysicalControlProvisioning
    private let launcher: any PhysicalControlRunnerLaunching
    private let makeTransport: @Sendable (PhysicalControlEndpoint) -> any PhysicalControlTransport
    private let makeToken: @Sendable () throws -> PhysicalControlToken
    private let developerDirectory: URL?
    private let timing: Timing
    private let onChange: (@Sendable (PhysicalControlSnapshot) -> Void)?

    private var state: PhysicalControlState = .stopped
    private var screen: PhysicalControlScreen?
    private var lastOrientation: PhysicalControlOrientation?
    private var transport: (any PhysicalControlTransport)?
    private var build: PhysicalControlBuild?
    private var pending = 0
    private var lastAction: Task<Void, Never>?
    private var startTask: Task<Void, Error>?
    private var healthTask: Task<Void, Never>?
    private var relaunchesLeft = 1
    private var isRelaunching = false
    private var stopRequested = false
    private var secrets: [String] = []
    private var candidateCache: (ids: [String], at: ContinuousClock.Instant)?
    private var missRefreshTask: Task<Void, Never>?
    private var lastMissRefresh: ContinuousClock.Instant?
    private var revision: UInt64 = 0
    private var lastTiming: PhysicalControlActionTiming?
    private static let signposter = OSSignposter(subsystem: "com.devicehubpro", category: "PhysicalControl")

    /// The child, readable from any thread for the quit's synchronous stop.
    private nonisolated let processBox = Mutex<(any PhysicalControlRunnerProcess)?>(nil)

    /// - Parameters:
    ///   - team: the Development Team ID, read at each start (Settings).
    ///   - tunnelAddress: the phone's tunnel address, read from its
    ///     `details` (`connectionProperties.tunnelIPAddress`) at each start.
    ///   - candidates: bundle identifiers the foreground app is looked up
    ///     among (the phone's app list plus common Apple apps).
    public init(
        target: PhysicalControlTarget,
        team: @escaping @Sendable () -> String?,
        tunnelAddress: @escaping @Sendable () async throws -> String?,
        candidates: @escaping @Sendable () async -> [String] = { [] },
        provisioner: any PhysicalControlProvisioning,
        launcher: any PhysicalControlRunnerLaunching,
        developerDirectory: URL? = nil,
        timing: Timing = Timing(),
        makeTransport: @escaping @Sendable (PhysicalControlEndpoint) -> any PhysicalControlTransport = {
            PhysicalControlURLSessionTransport(endpoint: $0)
        },
        makeToken: @escaping @Sendable () throws -> PhysicalControlToken = { try PhysicalControlToken.generate() },
        onChange: (@Sendable (PhysicalControlSnapshot) -> Void)? = nil
    ) {
        self.target = target
        self.team = team
        self.tunnelAddress = tunnelAddress
        self.candidates = candidates
        self.provisioner = provisioner
        self.launcher = launcher
        self.developerDirectory = developerDirectory
        self.timing = timing
        self.makeTransport = makeTransport
        self.makeToken = makeToken
        self.onChange = onChange
    }

    // MARK: Reading

    public func snapshot() -> PhysicalControlSnapshot {
        PhysicalControlSnapshot(state: state, isBusy: pending > 0, orientation: lastOrientation, revision: revision)
    }

    public func portraitSize() -> CGSize? { screen?.portraitSize }

    private func publish() {
        revision &+= 1
        onChange?(snapshot())
    }

    private func set(_ next: PhysicalControlState) {
        guard state != next else { return }
        state = next
        publish()
    }

    // MARK: Starting

    public func start() async throws {
        switch state {
        case .ready: return
        case .preparing, .starting:
            // A start is running: join it.
            if let startTask { try await startTask.value }
            return
        case .stopped, .failed:
            break
        }
        stopRequested = false
        relaunchesLeft = 1
        let task = Task { try await self.runStart() }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    private func runStart() async throws {
        do {
            guard let team = team()?.trimmingCharacters(in: .whitespacesAndNewlines), !team.isEmpty else {
                throw PhysicalControlError.noTeam
            }
            secrets = [team, target.hardwareUDID]
            set(.preparing("Preparing the input runner…"))
            let build = try await provisioner.ensureRunner(for: target, team: team) { [weak self] text in
                Task { await self?.noteProgress(text) }
            }
            try throwIfStopped()
            self.build = build
            try await launchAndWait(build: build)
            try throwIfStopped()
            set(.ready)
            startHealthMonitor()
        } catch {
            let failure = classify(error)
            await abortRunner()
            if failure == .stopped {
                set(.stopped)
            } else {
                set(.failed(failure))
            }
            throw failure
        }
    }

    private func noteProgress(_ text: String) {
        if case .preparing = state { set(.preparing(text)) }
    }

    private func throwIfStopped() throws {
        if stopRequested || Task.isCancelled { throw PhysicalControlError.stopped }
    }

    private func classify(_ error: Error) -> PhysicalControlError {
        if let error = error as? PhysicalControlError { return error }
        if error is CancellationError { return .stopped }
        return .launchFailed((error as NSError).localizedDescription)
    }

    /// Starts the child and waits until it answers `/status` and `/screen`.
    private func launchAndWait(build: PhysicalControlBuild) async throws {
        let token = try makeToken()
        guard token.value.count >= PhysicalControlToken.minimumLength else { throw PhysicalControlError.tokenTooShort }
        guard let address = try await tunnelAddress() else { throw PhysicalControlError.noTunnelAddress }
        let endpoint = try PhysicalControlEndpoint(tunnelAddress: address, token: token)
        secrets = [team() ?? "", target.hardwareUDID, endpoint.address, token.value].filter { !$0.isEmpty }
        let transport = makeTransport(endpoint)
        self.transport = transport

        set(.starting(build.wasBuilt ? "Installing the input runner on the iPhone…" : "Starting the input runner…"))
        // The candidate list is read while the runner boots.
        Task { _ = await self.candidateIDs() }
        let process = try launcher.launch(PhysicalControlLaunchConfiguration(
            xctestrunURL: build.xctestrunURL,
            hardwareUDID: target.hardwareUDID,
            endpoint: endpoint,
            developerDirectory: developerDirectory,
            maximumSeconds: timing.runnerMaximumSeconds
        ))
        processBox.withLock { $0 = process }

        let limit = build.wasBuilt ? timing.firstRunStart : timing.warmStart
        let deadline = ContinuousClock.now + limit
        while true {
            try throwIfStopped()
            if !process.isRunning {
                throw PhysicalControlError.runnerExited(redacted(process.outputTail))
            }
            if let answer = try? await transport.send(.status, timeout: .seconds(2)) {
                if answer.status == 401 { throw PhysicalControlError.unauthorized }
                if answer.status == 200 { break }
            }
            if ContinuousClock.now >= deadline {
                throw PhysicalControlError.startTimedOut(seconds: Int(limit.components.seconds))
            }
            try await Task.sleep(for: timing.pollInterval)
        }

        let screenAnswer = try await transport.send(.screen, timeout: timing.actionTimeout)
        guard screenAnswer.status == 200, let object = screenAnswer.object, let info = PhysicalControlScreen(json: object) else {
            throw PhysicalControlError.badResponse("the screen size is missing")
        }
        screen = info
        if let value = try? await transport.send(.orientation, timeout: .seconds(5)), value.status == 200,
           let name = value.object?["value"] as? String {
            lastOrientation = PhysicalControlOrientation(rawValue: name) ?? .unknown
        }
    }

    private func redacted(_ text: String) -> String {
        PhysicalControlRedactor.redact(text, secrets: secrets)
    }

    // MARK: Stopping

    public func stop() async {
        stopRequested = true
        startTask?.cancel()
        healthTask?.cancel()
        healthTask = nil
        if case .stopped = state {} else if let startTask {
            _ = try? await startTask.value
        }
        await endRunner(politely: true)
        transport = nil
        screen = nil
        pending = 0
        set(.stopped)
    }

    public nonisolated func terminateNow() {
        let process = processBox.withLock { $0 }
        process?.interrupt()
    }

    /// Ends the child: `/stop` first, then SIGINT, SIGTERM and SIGKILL, each
    /// after a grace.
    private func endRunner(politely: Bool) async {
        let process = processBox.withLock { box -> (any PhysicalControlRunnerProcess)? in
            let current = box
            box = nil
            return current
        }
        guard let process else { return }
        if politely, process.isRunning, let transport {
            _ = try? await transport.send(.stop, timeout: .seconds(2))
            if await process.waitForExit(timeout: timing.stopGrace) { return }
        }
        guard process.isRunning else { return }
        process.interrupt()
        if await process.waitForExit(timeout: timing.stopGrace) { return }
        process.terminate()
        if await process.waitForExit(timeout: timing.stopGrace) { return }
        process.kill()
    }

    /// A start or a restart failed: nothing stays running.
    private func abortRunner() async {
        healthTask?.cancel()
        healthTask = nil
        await endRunner(politely: false)
        transport = nil
    }

    // MARK: Health and the one relaunch

    private func startHealthMonitor() {
        guard let interval = timing.healthInterval, healthTask == nil else { return }
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.checkHealth()
            }
        }
    }

    /// Looks at the child: when the runner died while ready, starts it again
    /// once; a second death fails the session.
    func checkHealth() async {
        guard case .ready = state, !isRelaunching else { return }
        let alive = processBox.withLock { $0?.isRunning ?? false }
        if !alive { _ = await runnerDied() }
    }

    /// The runner is gone: the one relaunch, else the session fails. True
    /// when it is running again.
    private func runnerDied() async -> Bool {
        guard !isRelaunching, !stopRequested else { return false }
        let tail = processBox.withLock { $0?.outputTail } ?? ""
        guard relaunchesLeft > 0, let build else {
            await abortRunner()
            set(.failed(.runnerExited(redacted(tail))))
            return false
        }
        relaunchesLeft -= 1
        isRelaunching = true
        defer { isRelaunching = false }
        await endRunner(politely: false)
        set(.starting("Starting the input runner again…"))
        do {
            try await launchAndWait(build: PhysicalControlBuild(xctestrunURL: build.xctestrunURL, wasBuilt: false))
            try throwIfStopped()
            set(.ready)
            return true
        } catch {
            let failure = classify(error)
            await abortRunner()
            set(failure == .stopped ? .stopped : .failed(failure))
            return false
        }
    }

    // MARK: Actions

    /// Runs `operation` after every earlier action. At most one action is in
    /// flight and one waits; a third is refused.
    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard state.isReady else { throw PhysicalControlError.notReady }
        guard pending < 2 else { throw PhysicalControlError.busy }
        pending += 1
        publish()
        let previous = lastAction
        let task = Task<Value, Error> {
            _ = await previous?.value
            return try await operation()
        }
        lastAction = Task { _ = await task.result }
        defer {
            pending = max(0, pending - 1)
            publish()
        }
        return try await task.value
    }

    /// One request; a failure of the connection while the runner's process
    /// is gone starts the one relaunch, and any other failure ends the
    /// session.
    private func call(
        _ request: PhysicalControlRequest,
        timeout: Duration? = nil
    ) async throws -> PhysicalControlResponse {
        guard let transport else { throw PhysicalControlError.notReady }
        let answer: PhysicalControlResponse
        do {
            answer = try await transport.send(request, timeout: timeout ?? timing.actionTimeout)
        } catch let error as PhysicalControlError {
            throw await connectionLost(error)
        } catch is CancellationError {
            throw PhysicalControlError.stopped
        }
        switch answer.status {
        case 200..<300:
            return answer
        case 401:
            await abortRunner()
            set(.failed(.unauthorized))
            throw PhysicalControlError.unauthorized
        case 409 where request.path == "/type":
            throw PhysicalControlError.keyboardNotShowing
        case _ where request.path == "/siri" && [404, 500, 501].contains(answer.status):
            // An older runner has no /siri, and a phone without Siri fails
            // the XCTest call: neither ends the session.
            throw PhysicalControlError.unsupported("Siri is not available through the input runner on this iPhone.")
        default:
            throw PhysicalControlError.actionFailed(status: answer.status, message: redacted(answer.errorMessage))
        }
    }

    private func connectionLost(_ error: PhysicalControlError) async -> PhysicalControlError {
        let alive = processBox.withLock { $0?.isRunning ?? false }
        if !alive {
            if await runnerDied() { return .runnerRestarted }
            if case .failed(let failure) = state { return failure }
            return error
        }
        await abortRunner()
        set(.failed(error))
        return error
    }

    /// The candidate list, asked for once a `candidateRefresh` (the real one
    /// runs `devicectl device info apps`, far too slow for every tap).
    func candidateIDs() async -> [String] {
        if let cached = candidateCache, cached.at.duration(to: .now) < timing.candidateRefresh {
            return cached.ids
        }
        return await loadCandidates()
    }

    private func loadCandidates() async -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for id in await candidates() {
            guard !id.isEmpty, id != Self.springboard, seen.insert(id).inserted else { continue }
            if Self.excludedBundlePrefixes.contains(where: { id.hasPrefix($0) }) || Self.excludedBundleIDs.contains(id) { continue }
            ids.append(id)
            if ids.count == Self.maximumCandidates { break }
        }
        candidateCache = (ids, .now)
        return ids
    }

    /// Learns from a tap's or swipe's answer: an app reference moves to the front of the
    /// list (most recently used first); Springboard although candidates were sent is a
    /// miss, and the list is reloaded in the background (never awaited by the action).
    func learn(fromReference ref: String?, sent: [String]) {
        guard let ref, !sent.isEmpty else { return }
        if ref == Self.springboard {
            guard missRefreshTask == nil,
                  lastMissRefresh.map({ $0.duration(to: .now) >= timing.missRefresh }) ?? true
            else { return }
            lastMissRefresh = .now
            candidateCache = nil
            missRefreshTask = Task { [weak self] in
                _ = await self?.loadCandidates()
                await self?.finishMissRefresh()
            }
        } else if var cached = candidateCache, let index = cached.ids.firstIndex(of: ref), index > 0 {
            cached.ids.remove(at: index)
            cached.ids.insert(ref, at: 0)
            candidateCache = cached
        }
    }

    private func finishMissRefresh() { missRefreshTask = nil }

    public func foregroundApp() async throws -> String? {
        let ids = await candidateIDs()
        guard !ids.isEmpty else { return nil }
        return try await foreground(ids: ids).first
    }

    public func foreground(ids: [String]) async throws -> [String] {
        let usable = ids.filter { id in
            !Self.excludedBundlePrefixes.contains { id.hasPrefix($0) } && !Self.excludedBundleIDs.contains(id)
        }
        guard !usable.isEmpty else { return [] }
        let answer = try await call(.foreground(ids: usable), timeout: .seconds(5))
        guard let list = answer.object?["foreground"] as? [String] else {
            throw PhysicalControlError.badResponse("the foreground list is missing")
        }
        return list
    }

    /// The last tap's or swipe's timing.
    public func lastActionTiming() -> PhysicalControlActionTiming? { lastTiming }

    private func noteTiming(_ timing: PhysicalControlActionTiming) { lastTiming = timing }

    /// Runs one tap or swipe request, timed on the Mac and traced with a
    /// signpost interval; the runner's own `timing` and `ref` are kept when
    /// it sent them.
    private func timed(
        _ kind: PhysicalControlActionTiming.Kind,
        _ makeRequest: @escaping @Sendable ([String]) -> PhysicalControlRequest
    ) async throws {
        try await perform { [self] in
            let name: StaticString = kind == .tap ? "tap" : "swipe"
            let state = Self.signposter.beginInterval(name)
            defer { Self.signposter.endInterval(name, state) }
            let clock = ContinuousClock()
            let start = clock.now
            let refs = await candidateIDs()
            let answer = try await call(makeRequest(refs))
            await learn(fromReference: answer.object?["ref"] as? String, sent: refs)
            let elapsed = start.duration(to: clock.now).components
            let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            let runner = answer.object?["timing"] as? [String: Any]
            await noteTiming(PhysicalControlActionTiming(
                kind: kind, roundTripMs: ms,
                runnerResolveMs: (runner?["resolveMs"] as? NSNumber)?.doubleValue,
                runnerActionMs: (runner?["actionMs"] as? NSNumber)?.doubleValue,
                reference: answer.object?["ref"] as? String,
                runnerTapStart: (answer.object?["t0"] as? NSNumber)?.doubleValue
            ))
        }
    }

    public func tap(_ point: CGPoint) async throws {
        try await timed(.tap) { refs in .tap(x: Double(point.x), y: Double(point.y), ref: nil, refs: refs) }
    }

    public func swipe(from: CGPoint, to: CGPoint, duration: TimeInterval) async throws {
        try await timed(.swipe) { refs in
            .swipe(x1: Double(from.x), y1: Double(from.y), x2: Double(to.x), y2: Double(to.y),
                   duration: duration, ref: nil, refs: refs)
        }
    }

    public func type(_ text: String, bundleID: String) async throws {
        let limit = timing.actionTimeout + timing.typeTimeoutPerCharacter * text.count
        try await perform { [self] in
            _ = try await call(.type(text: text, bundleID: bundleID), timeout: limit)
        }
    }

    public func press(_ button: PhysicalControlButton) async throws {
        try await perform { [self] in
            _ = try await call(.button(button))
        }
    }

    public func activateSiri(text: String?) async throws {
        try await perform { [self] in
            _ = try await call(.siri(text: text), timeout: .seconds(15))
        }
    }

    public func showAppSwitcher() async throws {
        try await perform { [self] in
            _ = try await call(.appSwitcher, timeout: .seconds(15))
        }
    }

    public func setOrientation(_ orientation: PhysicalControlOrientation) async throws -> PhysicalControlOrientation {
        let result = try await perform { [self] in
            let answer = try await call(.setOrientation(orientation))
            let name = answer.object?["value"] as? String ?? orientation.rawValue
            return PhysicalControlOrientation(rawValue: name) ?? .unknown
        }
        noteOrientation(result)
        return result
    }

    public func orientation() async throws -> PhysicalControlOrientation {
        let result = try await perform { [self] in
            let answer = try await call(.orientation, timeout: .seconds(10))
            guard let name = answer.object?["value"] as? String else {
                throw PhysicalControlError.badResponse("the orientation is missing")
            }
            return PhysicalControlOrientation(rawValue: name) ?? .unknown
        }
        noteOrientation(result)
        return result
    }

    private func noteOrientation(_ value: PhysicalControlOrientation) {
        guard lastOrientation != value else { return }
        lastOrientation = value
        publish()
    }
}
