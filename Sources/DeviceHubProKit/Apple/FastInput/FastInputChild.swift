import Foundation
import Synchronization

/// The real launcher: a `Process` with a pipe on each side.
public struct ProcessFastInputChildLauncher: FastInputChildLauncher {
    public init() {}

    public func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        wantsLines: Bool
    ) throws -> any FastInputChild {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new } }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = wantsLines ? output : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // A closed pipe must fail the write, not kill the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let child = ProcessFastInputChild(process: process, input: input.fileHandleForWriting)
        if wantsLines {
            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    child.finishLines()
                } else {
                    child.append(data)
                }
            }
        } else {
            child.finishLines()
        }
        process.terminationHandler = { _ in child.didExit() }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw FastInputError.launchFailed((error as NSError).localizedDescription)
        }
        return child
    }
}

final class ProcessFastInputChild: FastInputChild, @unchecked Sendable {
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let process: Process
    private let input: FileHandle
    private let state = Mutex(State())

    private struct State {
        var pending = Data()
        var exited = false
    }

    init(process: Process, input: FileHandle) {
        self.process = process
        self.input = input
        (lines, continuation) = AsyncStream<String>.makeStream()
    }

    var isRunning: Bool { !state.withLock { $0.exited } && process.isRunning }

    func append(_ data: Data) {
        let complete = state.withLock { state -> [String] in
            state.pending.append(data)
            var result: [String] = []
            while let newline = state.pending.firstIndex(of: 0x0A) {
                result.append(String(decoding: state.pending[state.pending.startIndex..<newline], as: UTF8.self))
                state.pending = Data(state.pending[(newline + 1)...])
            }
            return result
        }
        for line in complete { continuation.yield(line) }
    }

    func finishLines() { continuation.finish() }

    func didExit() { state.withLock { $0.exited = true } }

    func write(_ line: String) throws {
        guard isRunning else { throw FastInputError.helperExited }
        do {
            try input.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            throw FastInputError.helperExited
        }
    }

    func terminate() {
        guard isRunning else { return }
        process.terminate()
    }

    func kill() {
        guard isRunning else { return }
        Foundation.kill(process.processIdentifier, SIGKILL)
    }
}
