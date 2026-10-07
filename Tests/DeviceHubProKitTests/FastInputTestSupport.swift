import CoreGraphics
import Foundation
@testable import DeviceHubProKit

// Fakes for fast input: a helper process that speaks the line protocol from a
// script, a launcher, a lease and a sender. No test starts a real process,
// opens a socket or reaches a device.

/// A fake child: records what is written, answers from `respond`, and can emit
/// lines by hand.
final class FakeFastChild: FastInputChild, @unchecked Sendable {
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var _written: [String] = []
    private var _running = true
    private var _terminated = 0
    private var _killed = 0
    /// The lines to print in answer to a written line (none: it stays quiet).
    var respond: (@Sendable (String) -> [String])?

    init(startup: [String] = [], respond: (@Sendable (String) -> [String])? = { _ in ["ok"] }) {
        (lines, continuation) = AsyncStream<String>.makeStream()
        self.respond = respond
        for line in startup { continuation.yield(line) }
    }

    var written: [String] { lock.withLock { _written } }
    var isRunning: Bool { lock.withLock { _running } }
    var terminated: Int { lock.withLock { _terminated } }
    var killed: Int { lock.withLock { _killed } }

    func write(_ line: String) throws {
        guard isRunning else { throw FastInputError.helperExited }
        lock.withLock { _written.append(line) }
        if line == "quit" {
            continuation.yield("ok")
            end()
            return
        }
        for answer in respond?(line) ?? [] { continuation.yield(answer) }
    }

    func emit(_ line: String) { continuation.yield(line) }

    /// The process ends (its output closes).
    func end() {
        lock.withLock { _running = false }
        continuation.finish()
    }

    func terminate() {
        lock.withLock { _terminated += 1 }
        end()
    }

    func kill() { lock.withLock { _killed += 1 }; end() }
}

/// Hands out children from a queue and records each launch.
final class FakeFastLauncher: FastInputChildLauncher, @unchecked Sendable {
    struct Launch: Equatable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]?
        let wantsLines: Bool
    }

    private let lock = NSLock()
    private var queue: [FakeFastChild]
    private var _launches: [Launch] = []
    private var _children: [FakeFastChild] = []
    /// Launch numbers (1-based) that throw.
    var failing: Set<Int> = []

    init(children: [FakeFastChild] = []) { queue = children }

    var launches: [Launch] { lock.withLock { _launches } }
    var children: [FakeFastChild] { lock.withLock { _children } }

    func launch(executable: URL, arguments: [String], environment: [String: String]?, wantsLines: Bool) throws -> any FastInputChild {
        let (number, child) = lock.withLock { () -> (Int, FakeFastChild) in
            _launches.append(Launch(executable: executable, arguments: arguments, environment: environment, wantsLines: wantsLines))
            let child = queue.isEmpty ? FakeFastChild(respond: nil) : queue.removeFirst()
            _children.append(child)
            return (_launches.count, child)
        }
        if failing.contains(number) { throw FastInputError.launchFailed("scripted") }
        return child
    }
}

final class FakeLease: FastInputLease, @unchecked Sendable {
    private let lock = NSLock()
    private var _starts = 0
    private var _stops = 0
    private var _terminations = 0
    var startError: FastInputError?
    var starts: Int { lock.withLock { _starts } }
    var stops: Int { lock.withLock { _stops } }
    var terminations: Int { lock.withLock { _terminations } }

    func start() async throws {
        lock.withLock { _starts += 1 }
        if let startError { throw startError }
    }
    func stop() async { lock.withLock { _stops += 1 } }
    func terminateNow() { lock.withLock { _terminations += 1 } }
}

/// A sender that records its calls, can be held at the first call and can fail.
final class FakeFastSender: FastInputControlling, @unchecked Sendable {
    enum Call: Equatable {
        case down(CGPoint), move(CGPoint), up(CGPoint), edge(FastInputEdgePhase, CGPoint), button(PhysicalControlButton), hid(Int, Int, Bool), appSwitcher, key(Int, FastInputKeyAction), keys([Int])
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _stops = 0
    private var _terminations = 0
    /// Awaited by every call before it is recorded as done.
    var gate: (@Sendable () async -> Void)?
    /// Calls (matching) that throw.
    var failWhen: (@Sendable (Call) -> Bool)?
    /// What a failing call throws.
    var failure: FastInputError = .commandFailed(code: 1, message: "scripted")

    var calls: [Call] { lock.withLock { _calls } }
    var stops: Int { lock.withLock { _stops } }
    var terminations: Int { lock.withLock { _terminations } }

    private func record(_ call: Call) async throws {
        lock.withLock { _calls.append(call) }
        await gate?()
        if failWhen?(call) == true { throw failure }
    }

    func down(_ point: CGPoint) async throws { try await record(.down(point)) }
    func move(_ point: CGPoint) async throws { try await record(.move(point)) }
    func up(_ point: CGPoint) async throws { try await record(.up(point)) }
    func edge(_ phase: FastInputEdgePhase, _ point: CGPoint) async throws { try await record(.edge(phase, point)) }
    func button(_ button: PhysicalControlButton) async throws { try await record(.button(button)) }
    func hid(page: Int, usage: Int, down: Bool) async throws { try await record(.hid(page, usage, down)) }
    func appSwitcher() async throws { try await record(.appSwitcher) }
    func key(usage: Int, action: FastInputKeyAction) async throws { try await record(.key(usage, action)) }
    func keys(_ usages: [Int]) async throws { try await record(.keys(usages)) }
    func stop() async { lock.withLock { _stops += 1 } }
    func terminateNow() { lock.withLock { _terminations += 1 } }
}

/// A one-shot gate a test opens by hand.
actor FastInputGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
