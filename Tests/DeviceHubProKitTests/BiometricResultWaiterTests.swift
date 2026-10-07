import XCTest
@testable import DeviceHubProKit

/// A prompt signal the test drives: `up` is what `isPromptUp` answers, and
/// `waitForPrompt` returns once `present()` is called.
final class FakePromptSignal: BiometricPromptSignal, @unchecked Sendable {
    private struct State {
        var up: Bool?
        var presented = false
        var waiters: [CheckedContinuation<Void, Error>] = []
        var waitStarts = 0
        var waitEnds = 0
        var stateReads = 0
    }

    private let state: NSLock = NSLock()
    private var storage: State

    /// When set, `waitForPrompt` throws at once, as a watcher does on a
    /// simulator that is shut down.
    var watcherFails = false

    init(up: Bool?) { storage = State(up: up) }

    private func with<T>(_ body: (inout State) -> T) -> T {
        state.withLock { body(&storage) }
    }

    var waitStarts: Int { with { $0.waitStarts } }
    var waitEnds: Int { with { $0.waitEnds } }
    var stateReads: Int { with { $0.stateReads } }

    func isPromptUp() async -> Bool? {
        with { $0.stateReads += 1; return $0.up }
    }

    func waitForPrompt() async throws {
        with { $0.waitStarts += 1 }
        defer { with { $0.waitEnds += 1 } }
        if watcherFails { throw SimctlClientError.unexpectedOutput(command: "log stream", detail: "ended") }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let immediate: Result<Void, Error>? = with { state in
                    if state.presented { return .success(()) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    state.waiters.append(continuation)
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let pending = with { state -> [CheckedContinuation<Void, Error>] in
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in pending { waiter.resume(throwing: CancellationError()) }
        }
    }

    func present() {
        let pending = with { state -> [CheckedContinuation<Void, Error>] in
            state.presented = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in pending { waiter.resume() }
    }
}

/// Counts the sends.
final class SendCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func send() { lock.withLock { _count += 1 } }
}

final class BiometricResultWaiterTests: XCTestCase {
    static let settle: Duration = .milliseconds(20)

    /// A prompt that is up already: sent at once, as it always was.
    func testSentAtOnceWhenAPromptIsUp() async throws {
        let signal = FakePromptSignal(up: true)
        let counter = SendCounter()
        let outcome = try await BiometricResultWaiter.deliver(signal: signal, timeout: .seconds(5), settle: Self.settle) { counter.send() }
        XCTAssertEqual(outcome, .deliveredNow)
        XCTAssertEqual(counter.count, 1)
        // The watcher it started was stopped.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(signal.waitEnds, signal.waitStarts)
    }

    /// A state that cannot be told is not "up": the request keeps waiting for
    /// the watcher and sends only once the prompt shows.
    func testAnUnknownStateKeepsWaitingForThePrompt() async throws {
        let signal = FakePromptSignal(up: nil)
        let counter = SendCounter()
        let task = Task {
            try await BiometricResultWaiter.deliver(signal: signal, timeout: .seconds(10), settle: Self.settle) { counter.send() }
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(counter.count, 0)
        signal.present()
        let outcome = try await task.value
        XCTAssertEqual(outcome, .deliveredAfterPrompt)
        XCTAssertEqual(counter.count, 1)
    }

    func testAnUnknownStateTimesOutWithoutSending() async throws {
        let signal = FakePromptSignal(up: nil)
        let counter = SendCounter()
        let outcome = try await BiometricResultWaiter.deliver(signal: signal, timeout: .milliseconds(200), settle: Self.settle) { counter.send() }
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(counter.count, 0)
    }

    /// A watcher that cannot run (the simulator is shut down) ends the wait
    /// with its own outcome instead of sending or waiting out the timeout.
    func testAFailedWatcherEndsTheWaitWithoutSending() async throws {
        let signal = FakePromptSignal(up: nil)
        signal.watcherFails = true
        let counter = SendCounter()
        let outcome = try await BiometricResultWaiter.deliver(signal: signal, timeout: .seconds(10), settle: Self.settle) { counter.send() }
        XCTAssertEqual(outcome, .simulatorUnavailable)
        XCTAssertEqual(counter.count, 0)
    }

    /// A watcher that failed ends the wait only once the state is known and
    /// says no prompt is up; a prompt that is definitely up is still served.
    func testAFailedWatcherStillServesAPromptThatIsUpAndGivesUpOnOneThatIsNot() async throws {
        let up = FakePromptSignal(up: true)
        up.watcherFails = true
        let counter = SendCounter()
        let served = try await BiometricResultWaiter.deliver(signal: up, timeout: .seconds(10), settle: Self.settle) { counter.send() }
        XCTAssertEqual(served, .deliveredNow)
        XCTAssertEqual(counter.count, 1)

        let down = FakePromptSignal(up: false)
        down.watcherFails = true
        let none = SendCounter()
        let gaveUp = try await BiometricResultWaiter.deliver(signal: down, timeout: .seconds(10), settle: Self.settle) { none.send() }
        XCTAssertEqual(gaveUp, .simulatorUnavailable)
        XCTAssertEqual(none.count, 0)
        XCTAssertEqual(down.stateReads, 1)
    }

    /// No prompt yet: nothing is sent until the signal fires, then it is, once.
    func testWaitsForThePromptThenSends() async throws {
        let signal = FakePromptSignal(up: false)
        let counter = SendCounter()
        let task = Task {
            try await BiometricResultWaiter.deliver(signal: signal, timeout: .seconds(10), settle: Self.settle) { counter.send() }
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(counter.count, 0, "nothing goes before the prompt")
        XCTAssertEqual(signal.waitStarts, 1)
        signal.present()
        let outcome = try await task.value
        XCTAssertEqual(outcome, .deliveredAfterPrompt)
        XCTAssertEqual(counter.count, 1)
    }

    /// The result is sent only after the settle pause, not the instant the prompt shows.
    func testTheSettlePauseSeparatesThePromptFromTheSend() async throws {
        let signal = FakePromptSignal(up: false)
        let counter = SendCounter()
        let task = Task {
            try await BiometricResultWaiter.deliver(signal: signal, timeout: .seconds(10), settle: .milliseconds(400)) { counter.send() }
        }
        try await Task.sleep(for: .milliseconds(100))
        signal.present()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(counter.count, 0)
        _ = try await task.value
        XCTAssertEqual(counter.count, 1)
    }

    func testTimesOutWithoutSending() async throws {
        let signal = FakePromptSignal(up: false)
        let counter = SendCounter()
        let outcome = try await BiometricResultWaiter.deliver(signal: signal, timeout: .milliseconds(200), settle: Self.settle) { counter.send() }
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(signal.waitEnds, signal.waitStarts, "the watcher stops with the request")
    }

    func testCancelStopsTheWatcherAndSendsNothing() async throws {
        let signal = FakePromptSignal(up: false)
        let counter = SendCounter()
        let task = Task {
            try await BiometricResultWaiter.deliver(signal: signal, timeout: .seconds(30), settle: Self.settle) { counter.send() }
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let outcome = try await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(signal.waitEnds, signal.waitStarts)
        signal.present()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(counter.count, 0, "a prompt after the cancel gets nothing")
    }

    // MARK: - The simulator's own signal

    /// The log lines the signal reads are the ones measured on an iOS
    /// 27.0 simulator (Xcode 27.0, runtime 24A434).
    func testTheSignalsArguments() throws {
        let signal = SimctlBiometricPromptSignal(
            simctl: SimctlClient(simctlURL: URL(fileURLWithPath: "/nonexistent/simctl")),
            udid: SimctlFixtureTests.udid
        )
        XCTAssertEqual(Array(signal.watchArguments.prefix(6)), ["spawn", SimctlFixtureTests.udid, "log", "stream", "--style", "ndjson"])
        XCTAssertTrue(signal.watchArguments.contains("process == \"coreauthd\" AND eventMessage CONTAINS \"will start matching\""))
        XCTAssertEqual(Array(signal.stateArguments.prefix(5)), ["spawn", SimctlFixtureTests.udid, "log", "show", "--last"])
        XCTAssertTrue(signal.stateArguments.contains("process == \"coreauthd\" AND category == \"Notifications\""))
    }

    /// REAL CAPTURE: coreauthd's `Will post` entries (`log stream --style
    /// ndjson`, iOS 27.0 simulator, the verifier asking for Face ID and a
    /// match answering it), trimmed to the presented / dismissed pair.
    func testPromptStateFromTheLog() throws {
        let capture = try SimctlFixtureTests.text(".", "coreauthd-biometric-prompt-notifications.ndjson")
        let lines = capture.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(SimctlBiometricPromptSignal.promptIsUp(fromLogShow: lines[0]), "presented last: a prompt is up")
        XCTAssertFalse(SimctlBiometricPromptSignal.promptIsUp(fromLogShow: capture), "dismissed last: none")
        XCTAssertFalse(SimctlBiometricPromptSignal.promptIsUp(fromLogShow: ""), "nothing posted in the window")
        XCTAssertFalse(SimctlBiometricPromptSignal.promptIsUp(fromLogShow: "Filtering the log data using ...\n"))
    }

    func testAnInvalidUDIDIsNeverSpawned() async {
        let signal = SimctlBiometricPromptSignal(
            simctl: SimctlClient(simctlURL: URL(fileURLWithPath: "/nonexistent/simctl")),
            udid: "booted"
        )
        let up = await signal.isPromptUp()
        XCTAssertNil(up)
        do {
            try await signal.waitForPrompt()
            XCTFail("a selector is refused")
        } catch {
            XCTAssertEqual(error as? SimctlClientError, .invalidUDID("booted"))
        }
    }
}
