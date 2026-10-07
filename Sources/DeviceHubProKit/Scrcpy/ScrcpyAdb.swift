import Darwin
import Foundation

/// adb helpers of the scrcpy transport: bounded invocations for the input
/// fallback and for teardown paths that must finish before they return.
extension AdbClient {
    /// ``run(_:)`` with a bound: the child is terminated and
    /// `ProcessRunnerError.timedOut` thrown when `timeout` elapses, so one
    /// stalled invocation (a wireless link that stops answering) cannot hold
    /// everything queued behind it.
    @discardableResult
    func run(_ arguments: [String], within timeout: Duration) async throws -> String {
        let result = try await ProcessRunner.run(
            executable: adbURL,
            arguments: arguments,
            timeout: timeout
        )
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: result.standardErrorText
            )
        }
        return result.standardOutputText
    }

    /// Runs adb synchronously, waiting at most `timeout` (then SIGTERM, then
    /// SIGKILL). For teardown that must be complete when the caller returns,
    /// such as quitting the app; output is discarded. Returns true when adb
    /// exited zero in time. Never call it from the main thread except on the
    /// way out, where blocking briefly is the point.
    @discardableResult
    func runBlocking(_ arguments: [String], timeout: TimeInterval) -> Bool {
        let process = Process()
        process.executableURL = adbURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return false
        }

        guard exited.wait(timeout: .now() + max(0.05, timeout)) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 0.5)
            }
            return false
        }
        return process.terminationStatus == 0
    }

    /// The display size `wm size` reports for `serial`, in the display's
    /// natural orientation (the override size when one is set), or nil.
    func naturalDisplaySize(serial: String, within timeout: Duration) async -> (width: Int, height: Int)? {
        guard let output = try? await run(
            PhysicalInput.displaySizeArguments(serial: serial),
            within: timeout
        ) else { return nil }
        return PhysicalInput.parseDisplaySize(fromWmSize: output)
    }
}
