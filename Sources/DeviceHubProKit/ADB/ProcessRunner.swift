import Darwin
import Foundation

/// Errors thrown by `ProcessRunner` itself rather than by the child process.
public enum ProcessRunnerError: Error, Equatable, CustomStringConvertible {
    /// The child did not exit within the caller's bound and was terminated.
    case timedOut(command: String, seconds: Duration)

    public var description: String {
        switch self {
        case .timedOut(let command, let seconds):
            return "\(command) did not finish within \(Self.secondsText(seconds))s and was terminated"
        }
    }

    private static func secondsText(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1e18
        return String(format: "%.1f", seconds)
    }
}

struct ProcessResult: Sendable {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data

    var standardErrorText: String {
        String(data: standardError, encoding: .utf8) ?? ""
    }

    var standardOutputText: String {
        String(data: standardOutput, encoding: .utf8) ?? ""
    }

    /// adb writes `* daemon not running; starting now at tcp:5037` and
    /// `* daemon started successfully` to stderr when a call starts its
    /// server. They are progress notes, not errors, and every caller reads
    /// stderr as the failure text, so they are removed. Other lines stay.
    static func droppingAdbDaemonNotices(from data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8), text.contains("* daemon") else {
            return data
        }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !(trimmed.hasPrefix("* daemon not running; starting now at")
                || trimmed == "* daemon started successfully")
        }
        return Data(kept.joined(separator: "\n").utf8)
    }
}

/// The signal that asks a child to stop when its run is cancelled or times
/// out. Either way the child is SIGKILLed if it is still running after
/// `ProcessRunner.terminationGracePeriod`.
enum ProcessStopSignal: Sendable, Equatable {
    /// SIGTERM, the default.
    case terminate
    /// SIGINT, for tools that finish their output only on an interrupt, the
    /// way Ctrl-C stops them in a terminal: `simctl io recordVideo` writes the
    /// movie's index on SIGINT, and a SIGTERM leaves an unplayable file.
    case interrupt
}

/// How a streamed child ended. `ProcessRunner.stream` reports it through
/// `onExit` even when the run was cancelled and throws `CancellationError`.
struct ProcessExit: Sendable, Equatable {
    /// The exit status, or the signal number when `signaled`.
    let status: Int32
    /// The child died of a signal (a SIGKILL after the grace period, say).
    let signaled: Bool
}

/// Runs short-lived command-line tools (adb, emulator) and captures their output.
///
/// Pipe reads happen on background threads while the process runs, so large outputs
/// (e.g. `screencap`) cannot deadlock on a full pipe buffer.
enum ProcessRunner {
    /// How long a terminated child gets to exit before it is SIGKILLed. Long
    /// enough that a loaded machine still lets a well-behaved child run its
    /// SIGTERM cleanup; short enough that a child ignoring SIGTERM cannot make
    /// a bounded run meaningfully unbounded (the run's structured group waits
    /// for the child before it can throw).
    static let terminationGracePeriod: Duration = .seconds(2)

    /// Starts a long-running process (e.g. the emulator) without waiting for it.
    /// Output is appended to `logURL` when provided, otherwise discarded. The process
    /// keeps running independently of this app.
    @discardableResult
    static func launchDetached(executable: URL, arguments: [String], logURL: URL? = nil) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        var logHandle: FileHandle?
        if let logURL {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: logURL)
            logHandle?.seekToEndOfFile()
        }
        process.standardOutput = logHandle ?? FileHandle.nullDevice
        process.standardError = logHandle ?? FileHandle.nullDevice

        try process.run()
        return process
    }

    /// Runs a short-lived command and captures its output.
    ///
    /// `timeout` bounds the run: when it elapses the child is terminated and
    /// `ProcessRunnerError.timedOut` is thrown. Cancelling the calling task
    /// likewise terminates the child and throws `CancellationError`.
    /// `stopSignal` is what "terminated" sends first.
    static func run(
        executable: URL,
        arguments: [String],
        standardInput: Data? = nil,
        environment: [String: String]? = nil,
        timeout: Duration? = nil,
        stopSignal: ProcessStopSignal = .terminate
    ) async throws -> ProcessResult {
        guard let timeout else {
            return try await runProcess(
                executable: executable,
                arguments: arguments,
                standardInput: standardInput,
                environment: environment,
                stopSignal: stopSignal
            )
        }

        return try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            group.addTask {
                try await runProcess(
                    executable: executable,
                    arguments: arguments,
                    standardInput: standardInput,
                    environment: environment,
                    stopSignal: stopSignal
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProcessRunnerError.timedOut(
                    command: executable.lastPathComponent,
                    seconds: timeout
                )
            }
            // The loser of the race is cancelled on both paths: the sleeping
            // bound when the child wins, and the child itself when the bound
            // fires (its cancellation handler terminates the process).
            defer { group.cancelAll() }

            guard let result = try await group.next() else {
                throw ProcessRunnerError.timedOut(
                    command: executable.lastPathComponent,
                    seconds: timeout
                )
            }
            return result
        }
    }

    private static func runProcess(
        executable: URL,
        arguments: [String],
        standardInput: Data?,
        environment: [String: String]?,
        stopSignal: ProcessStopSignal,
        terminationGrace: Duration = ProcessRunner.terminationGracePeriod
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, override in override }
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Without input the child reads /dev/null, never the app's own stdin:
        // run from a terminal, `adb shell` would otherwise forward (and eat)
        // whatever is typed there.
        let inputPipe = Pipe()
        process.standardInput = standardInput == nil ? FileHandle.nullDevice : inputPipe

        let capture = ProcessCapture()
        capture.group.enter()
        capture.group.enter()

        let state = StreamingProcess(
            process: process,
            stdin: nil,
            stopSignal: stopSignal,
            terminationGrace: terminationGrace
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    state.recordTermination(finished.terminationStatus)
                    capture.group.wait()
                    if state.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: ProcessResult(
                            exitCode: finished.terminationStatus,
                            standardOutput: capture.output,
                            standardError: executable.lastPathComponent == "adb"
                                ? ProcessResult.droppingAdbDaemonNotices(from: capture.error)
                                : capture.error
                        ))
                    }
                }

                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                // Launched first, so a timeout or cancel can terminate the
                // child even while its input is still being written.
                state.didLaunch()
                if let standardInput {
                    ProcessRunner.feed(standardInput, to: inputPipe.fileHandleForWriting)
                }

                let outputHandle = SendableFileHandle(handle: outputPipe.fileHandleForReading)
                let errorHandle = SendableFileHandle(handle: errorPipe.fileHandleForReading)

                DispatchQueue.global(qos: .userInitiated).async {
                    let data = outputHandle.handle.readDataToEndOfFile()
                    capture.setOutput(data)
                    capture.group.leave()
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = errorHandle.handle.readDataToEndOfFile()
                    capture.setError(data)
                    capture.group.leave()
                }
            }
        } onCancel: {
            state.cancel()
        }
    }
}

extension ProcessRunner {
    /// Runs a process and delivers its output line by line as it arrives.
    ///
    /// A line ends at `\n`, `\r` or `\r\n`, so the carriage-return updates
    /// sdkmanager writes for progress arrive as individual lines. Empty lines
    /// are delivered as empty strings, and a final line without a terminator
    /// is delivered when the stream ends. `onLine` runs on a background
    /// thread, serially per stream; the two streams may interleave.
    ///
    /// `standardInput` is written to the child's stdin and the pipe is closed
    /// (like `run`); without it stdin is `/dev/null`. For interactive input
    /// (answering a prompt while the child runs) pass `onStdinReady` instead:
    /// it receives the write end, stdin stays open, and the runner closes it
    /// when the process ends.
    ///
    /// `partialLineHandler` is offered the bytes read since the last line
    /// break after every read; returning true delivers them to `onLine`
    /// immediately and clears them, so a later line break cannot deliver
    /// them twice. This covers prompts written without a terminator (like
    /// sdkmanager's `Accept? (y/N):`), which a line-oriented reader would
    /// otherwise hold back until the process ends.
    ///
    /// Cancelling the calling task stops the process with `stopSignal` and
    /// throws `CancellationError` once the process has exited and its output
    /// was delivered, so a caller that interrupts a recorder can rely on the
    /// recorder having finished when the call returns. `onExit` learns how
    /// the child ended, before the call returns or throws, on either path.
    static func stream(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        standardInput: Data? = nil,
        stopSignal: ProcessStopSignal = .terminate,
        onStdinReady: (@Sendable (ProcessStdin) -> Void)? = nil,
        partialLineHandler: (@Sendable (String) -> Bool)? = nil,
        onExit: (@Sendable (ProcessExit) -> Void)? = nil,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, override in override }
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let inputPipe = Pipe()
        if standardInput != nil || onStdinReady != nil {
            process.standardInput = inputPipe
        }
        let stdin = onStdinReady == nil
            ? nil
            : ProcessStdin(handle: inputPipe.fileHandleForWriting)

        let state = StreamingProcess(process: process, stdin: stdin, stopSignal: stopSignal)
        process.terminationHandler = { finished in
            // Reported before the termination is recorded, which the
            // continuation waits for, so it lands before the call ends.
            onExit?(ProcessExit(
                status: finished.terminationStatus,
                signaled: finished.terminationReason == .uncaughtSignal
            ))
            state.recordTermination(finished.terminationStatus)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try process.run()
                } catch {
                    state.closeStdin()
                    continuation.resume(throwing: error)
                    return
                }
                // Launched first, so a cancel can terminate the child even
                // while its input is still being written.
                state.didLaunch()
                if let standardInput {
                    ProcessRunner.feed(standardInput, to: inputPipe.fileHandleForWriting)
                }
                if let stdin, let onStdinReady {
                    onStdinReady(stdin)
                }

                let outputHandle = SendableFileHandle(handle: outputPipe.fileHandleForReading)
                let errorHandle = SendableFileHandle(handle: errorPipe.fileHandleForReading)

                state.readers.enter()
                state.readers.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    StreamingLineReader(
                        partialLineHandler: partialLineHandler,
                        onLine: onLine
                    ).read(outputHandle.handle)
                    state.readers.leave()
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    StreamingLineReader(
                        partialLineHandler: partialLineHandler,
                        onLine: onLine
                    ).read(errorHandle.handle)
                    state.readers.leave()
                }

                state.readers.notify(queue: .global(qos: .userInitiated)) {
                    state.closeStdin()
                    state.waitForTermination()
                    if state.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: state.terminationStatus)
                    }
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    /// Runs a process and delivers its standard output as raw byte chunks,
    /// exactly as `read(2)` returns them — for length-framed protocols such as
    /// `adb track-devices`, whose frames a line reader would split and
    /// corrupt. Chunk boundaries carry no meaning; the caller reassembles.
    /// Standard error is drained and discarded, stdin is `/dev/null`.
    ///
    /// `onChunk` runs on a background thread, serially. Returning false ends
    /// the run: the child is terminated (SIGTERM, then SIGKILL after the
    /// grace period) and the call returns its exit status, so a caller can
    /// drop a stream it can no longer decode without cancelling itself.
    /// Cancelling the calling task terminates the process and throws
    /// `CancellationError`.
    static func streamChunks(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        onChunk: @Sendable @escaping (Data) -> Bool
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, override in override }
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let state = StreamingProcess(process: process, stdin: nil)
        process.terminationHandler = { finished in
            state.recordTermination(finished.terminationStatus)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                state.didLaunch()

                let outputHandle = SendableFileHandle(handle: outputPipe.fileHandleForReading)
                let errorHandle = SendableFileHandle(handle: errorPipe.fileHandleForReading)

                state.readers.enter()
                state.readers.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    var stopped = false
                    readChunks(outputHandle.handle.fileDescriptor) { chunk in
                        // After a stop request the pipe is still drained to
                        // EOF (the child is on its way out), but nothing more
                        // is delivered.
                        guard !stopped else { return }
                        if !onChunk(chunk) {
                            stopped = true
                            state.requestTermination()
                        }
                    }
                    state.readers.leave()
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    readChunks(errorHandle.handle.fileDescriptor) { _ in }
                    state.readers.leave()
                }

                state.readers.notify(queue: .global(qos: .userInitiated)) {
                    state.waitForTermination()
                    if state.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: state.terminationStatus)
                    }
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    /// Writes `data` to a child's stdin and closes it, off the calling thread:
    /// a child that does not read would otherwise block the write — and with
    /// it the run's timeout — once the pipe buffer is full. A child that
    /// exits before reading everything makes the write fail with EPIPE,
    /// which is ignored instead of raising SIGPIPE (fatal to the app).
    static func feed(_ data: Data, to handle: FileHandle) {
        disableSIGPIPE(on: handle)
        let writer = SendableFileHandle(handle: handle)
        DispatchQueue.global(qos: .userInitiated).async {
            // Best effort: EPIPE means the child no longer wants the input.
            try? writer.handle.write(contentsOf: data)
            try? writer.handle.close()
        }
    }

    /// Makes writes to `handle` fail with EPIPE instead of raising SIGPIPE
    /// when the reading child has gone.
    static func disableSIGPIPE(on handle: FileHandle) {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    /// Reads `descriptor` to EOF with `read(2)`, handing every non-empty read
    /// to `body` as it arrives (see `StreamingLineReader.read` for why not
    /// `FileHandle`).
    private static func readChunks(_ descriptor: Int32, _ body: (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                body(Data(buffer[0..<count]))
            } else if count == 0 || errno != EINTR {
                break
            }
        }
    }
}

/// The write end of a running process's standard input, usable from any
/// thread. Writes after the runner closed it are ignored.
final class ProcessStdin: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    init(handle: FileHandle) {
        self.handle = handle
        // An answer written as the child exits must not SIGPIPE the app.
        ProcessRunner.disableSIGPIPE(on: handle)
    }

    func write(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        try? handle.write(contentsOf: Data(text.utf8))
    }

    func close() {
        lock.lock()
        let handle = self.handle
        self.handle = nil
        lock.unlock()
        try? handle?.close()
    }
}

/// Reader-thread shared state of a streaming run: the process, the rendezvous
/// of its two output readers, the stdin writer and the cancellation flag.
private final class StreamingProcess: @unchecked Sendable {
    let process: Process
    let readers = DispatchGroup()
    private let stdin: ProcessStdin?
    private let termination = DispatchGroup()
    private let stopSignal: ProcessStopSignal
    private let terminationGrace: Duration
    private let lock = NSLock()
    private var exitCode: Int32 = 0
    private var cancelled = false
    private var launched = false
    private var escalationScheduled = false

    init(
        process: Process,
        stdin: ProcessStdin?,
        stopSignal: ProcessStopSignal = .terminate,
        terminationGrace: Duration = ProcessRunner.terminationGracePeriod
    ) {
        self.process = process
        self.stdin = stdin
        self.stopSignal = stopSignal
        self.terminationGrace = terminationGrace
        termination.enter()
    }

    func closeStdin() {
        stdin?.close()
    }

    /// Called from the process's termination handler.
    func recordTermination(_ status: Int32) {
        ChildProcessRegistry.unregister(process)
        lock.lock()
        exitCode = status
        lock.unlock()
        termination.leave()
    }

    func waitForTermination() {
        termination.wait()
    }

    var terminationStatus: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return exitCode
    }

    /// A cancellation that arrives before `run()` must not terminate an
    /// unlaunched process (`terminate()` raises); it is applied on launch.
    func didLaunch() {
        lock.lock()
        launched = true
        let shouldTerminate = cancelled
        lock.unlock()
        ChildProcessRegistry.register(process)
        if shouldTerminate {
            terminateThenEscalate()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let shouldTerminate = launched
        lock.unlock()
        if shouldTerminate {
            terminateThenEscalate()
        }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Ends a launched child on the runner's own initiative (a stream the
    /// caller can no longer use) without flagging the run as cancelled, so
    /// the run still returns the exit status.
    func requestTermination() {
        lock.lock()
        let shouldTerminate = launched
        lock.unlock()
        if shouldTerminate {
            terminateThenEscalate()
        }
    }

    /// Send the stop signal (SIGTERM, or SIGINT for `.interrupt`), then
    /// SIGKILL the child after the grace period if it is still running. The
    /// run's structured group waits for the child before it can throw, so
    /// escalation is what keeps the timeout bound real against a child that
    /// traps or ignores the stop signal.
    private func terminateThenEscalate() {
        if process.isRunning {
            switch stopSignal {
            case .terminate: process.terminate()
            case .interrupt: process.interrupt()
            }
        }
        scheduleEscalation()
    }

    private func scheduleEscalation() {
        lock.lock()
        guard !escalationScheduled else {
            lock.unlock()
            return
        }
        escalationScheduled = true
        lock.unlock()

        let process = self.process
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.seconds(of: terminationGrace)
        ) {
            guard process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private static func seconds(of duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Splits a byte stream into lines on `\n`, `\r` and `\r\n`, with an optional
/// hook for unterminated prompts.
private final class StreamingLineReader: @unchecked Sendable {
    private let partialLineHandler: (@Sendable (String) -> Bool)?
    private let onLine: @Sendable (String) -> Void
    private var pending: [UInt8] = []
    private var sawCarriageReturn = false

    init(
        partialLineHandler: (@Sendable (String) -> Bool)?,
        onLine: @Sendable @escaping (String) -> Void
    ) {
        self.partialLineHandler = partialLineHandler
        self.onLine = onLine
    }

    /// Reads with `read(2)` rather than `FileHandle.read(upToCount:)`: the
    /// Foundation call only returns once the pipe reaches EOF, which would
    /// hold every line back until the process exits.
    func read(_ handle: FileHandle) {
        let descriptor = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                consume(buffer, count: count)
                offerPending()
            } else if count == 0 {
                break
            } else if errno != EINTR {
                break
            }
        }
        if !pending.isEmpty {
            emitPending()
        }
    }

    private func consume(_ bytes: [UInt8], count: Int) {
        for byte in bytes[0..<count] {
            if sawCarriageReturn {
                sawCarriageReturn = false
                if byte == 0x0A {
                    continue
                }
            }
            switch byte {
            case 0x0A, 0x0D:
                emitPending()
                sawCarriageReturn = byte == 0x0D
            default:
                pending.append(byte)
            }
        }
    }

    /// Delivers a prompt that will never get a line terminator: the handler
    /// decides whether the pending bytes are complete as written, and true
    /// clears them so a later terminator cannot deliver them twice.
    private func offerPending() {
        guard let partialLineHandler, !pending.isEmpty else { return }
        let text = String(decoding: pending, as: UTF8.self)
        guard partialLineHandler(text) else { return }
        pending.removeAll(keepingCapacity: true)
        sawCarriageReturn = false
        onLine(text)
    }

    private func emitPending() {
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        onLine(line)
    }
}

private struct SendableFileHandle: @unchecked Sendable {
    let handle: FileHandle
}

private final class ProcessCapture: @unchecked Sendable {
    let group = DispatchGroup()
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func setOutput(_ data: Data) {
        lock.lock()
        out = data
        lock.unlock()
    }

    func setError(_ data: Data) {
        lock.lock()
        err = data
        lock.unlock()
    }

    var output: Data {
        lock.lock()
        defer { lock.unlock() }
        return out
    }

    var error: Data {
        lock.lock()
        defer { lock.unlock() }
        return err
    }
}
