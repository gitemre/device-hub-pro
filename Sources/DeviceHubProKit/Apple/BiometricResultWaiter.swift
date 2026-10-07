import Foundation

/// What a simulator tells about its Face ID / Touch ID / Optic ID prompt.
///
/// A simulated match or non-match only reaches a prompt that is already up
/// (measured live, iOS 27.0: one sent before the app asked is ignored). The
/// signal lets a request wait for the prompt instead of being lost.
public protocol BiometricPromptSignal: Sendable {
    /// Whether a prompt is up right now: true or false, nil when it could not
    /// be told.
    func isPromptUp() async -> Bool?
    /// Returns once the simulator presents a biometric prompt. Throws
    /// `CancellationError` when cancelled; the watcher it runs is stopped then.
    func waitForPrompt() async throws
}

/// How a request for a biometric result ended.
public enum BiometricResultOutcome: Sendable, Equatable {
    /// A prompt was up (told for certain): sent at once.
    case deliveredNow
    /// Sent after the simulator presented a prompt.
    case deliveredAfterPrompt
    /// No prompt came within the time.
    case timedOut
    /// The caller cancelled.
    case cancelled
    /// The prompt watcher could not run and no prompt was up (the simulator
    /// is shut down or does not answer): nothing was sent.
    case simulatorUnavailable
}

/// "The result waits": a requested match or non-match is sent at once when a
/// prompt is up, else kept until the simulator presents one, then sent.
public enum BiometricResultWaiter {
    /// How long a request waits for a prompt.
    public static let defaultTimeout: Duration = .seconds(30)
    /// The pause between the prompt starting to match and the result being
    /// sent, so the sensor simulation is listening (a result sent before the
    /// mechanism runs is ignored; measured, iOS 27.0).
    public static let defaultSettle: Duration = .milliseconds(150)

    private enum Event: Sendable {
        case promptPresented
        case promptState(Bool?)
        case watcherFailed
        case timeout
    }

    /// Runs the request. `send` is called at most once, and not at all when
    /// the request times out or is cancelled. The watcher (`waitForPrompt`)
    /// starts before the state check, so a prompt appearing in between is not
    /// missed, and every child is stopped when this returns.
    public static func deliver(
        signal: any BiometricPromptSignal,
        timeout: Duration = defaultTimeout,
        settle: Duration = defaultSettle,
        send: @Sendable () async throws -> Void
    ) async throws -> BiometricResultOutcome {
        let event: Event? = await withTaskGroup(of: Event?.self) { group in
            group.addTask {
                do {
                    try await signal.waitForPrompt()
                    return .promptPresented
                } catch is CancellationError {
                    return nil
                } catch {
                    return .watcherFailed
                }
            }
            group.addTask { .promptState(await signal.isPromptUp()) }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .timeout
                } catch {
                    return nil
                }
            }
            var result: Event?
            var watcherFailed = false
            var stateAnswered = false
            for await next in group {
                guard let next else { continue }
                switch next {
                case .promptState(let up):
                    stateAnswered = true
                    // Send now only on a definite "up". Not up, or not told
                    // (the read timed out or failed): keep waiting for the
                    // watcher or the timer.
                    if up == true { result = next }
                case .watcherFailed:
                    watcherFailed = true
                case .promptPresented, .timeout:
                    result = next
                }
                // The watcher is the only way to learn of a prompt that
                // comes later: without it, and with no prompt up, end.
                if result == nil, watcherFailed, stateAnswered { result = .watcherFailed }
                if result != nil { break }
            }
            group.cancelAll()
            return result
        }
        if Task.isCancelled { return .cancelled }
        switch event {
        case .promptState:
            try await send()
            return .deliveredNow
        case .promptPresented:
            try await Task.sleep(for: settle)
            try await send()
            return .deliveredAfterPrompt
        case .timeout:
            return .timedOut
        case .watcherFailed:
            return .simulatorUnavailable
        case nil:
            return .cancelled
        }
    }
}

/// The simulator's own signal, read through simctl (established against
/// Xcode 27.0, iOS 27.0 simulator runtime).
///
/// The prompt is ready for a result when coreauthd logs that its biometric
/// mechanism "will start matching" (a default-level, public log line, written
/// when the prompt's UI has appeared). The Darwin notification
/// `com.apple.LocalAuthentication.ui.presented` comes earlier, when the UI is
/// only being asked for, and on a simulator's first prompt a result sent right
/// after it was lost (measured: the sheet was still drawing), so it is not
/// the signal. The watcher is one `simctl spawn ... log stream` limited to that
/// line, which exists only while a request is pending. Whether a prompt is up
/// now comes from coreauthd's log entries for the presented / dismissed posts
/// (`log show`, one call).
public struct SimctlBiometricPromptSignal: BiometricPromptSignal {
    public static let presentedNotification = "com.apple.LocalAuthentication.ui.presented"
    public static let dismissedNotification = "com.apple.LocalAuthentication.ui.dismissed"
    /// The message part that marks the mechanism starting to match.
    public static let startsMatching = "will start matching"
    /// A prompt times out after 300 s on the device; the log is read that far back.
    static let lookBack = "330s"

    public let simctl: SimctlClient
    public let udid: String

    public init(simctl: SimctlClient, udid: String) {
        self.simctl = simctl
        self.udid = udid
    }

    /// The arguments of the watcher (without the `--set` prefix).
    public var watchArguments: [String] {
        [
            "spawn", udid, "log", "stream", "--style", "ndjson",
            "--predicate", "process == \"coreauthd\" AND eventMessage CONTAINS \"\(Self.startsMatching)\"",
        ]
    }

    /// The arguments of the state read (without the `--set` prefix).
    public var stateArguments: [String] {
        [
            "spawn", udid, "log", "show", "--last", Self.lookBack, "--style", "ndjson",
            "--predicate", "process == \"coreauthd\" AND category == \"Notifications\"",
        ]
    }

    public func waitForPrompt() async throws {
        try SimctlClient.validateUDID(udid)
        let argv = try simctl.commandLine(watchArguments)
        let executable = simctl.simctlURL
        let environment = simctl.environment
        let (events, continuation) = AsyncStream<Bool>.makeStream()
        let watcher = Task {
            do {
                _ = try await ProcessRunner.stream(
                    executable: executable,
                    arguments: argv,
                    environment: environment,
                    onLine: { line in
                        if case .entry(let entry) = SimulatorLogParsing.parse(line), entry.message.contains(Self.startsMatching) {
                            continuation.yield(true)
                        }
                    }
                )
            } catch {
                // Cancelled by the caller, or the stream could not run.
            }
            continuation.finish()
        }
        defer { watcher.cancel() }
        let seen: Bool = await withTaskCancellationHandler {
            for await _ in events { return true }
            return false
        } onCancel: {
            watcher.cancel()
            continuation.finish()
        }
        try Task.checkCancellation()
        if !seen {
            throw SimctlClientError.unexpectedOutput(command: "simctl spawn log stream", detail: "the stream ended before a prompt")
        }
    }

    public func isPromptUp() async -> Bool? {
        guard (try? SimctlClient.validateUDID(udid)) != nil,
              let output = try? await simctl.run(stateArguments, timeout: .seconds(20)),
              output.exitCode == 0
        else { return nil }
        return Self.promptIsUp(fromLogShow: output.standardOutputText)
    }

    /// Whether the newest of coreauthd's presented / dismissed posts in
    /// `ndjson` is a presented one. Nothing posted in the window reads as no
    /// prompt. A `Will post` entry is the post; `Did skip` (a dismissal with
    /// no listener left) is not counted.
    public static func promptIsUp(fromLogShow ndjson: String) -> Bool {
        var up = false
        for line in ndjson.split(separator: "\n") {
            guard line.contains("Will post") || line.contains("will post") else { continue }
            guard case .entry(let entry) = SimulatorLogParsing.parse(String(line)) else { continue }
            if entry.message.contains(presentedNotification) { up = true }
            else if entry.message.contains(dismissedNotification) { up = false }
        }
        return up
    }
}
