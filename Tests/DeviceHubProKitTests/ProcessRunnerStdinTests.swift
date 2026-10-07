import Darwin
import XCTest
@testable import DeviceHubProKit

/// Standard input of `ProcessRunner.run` children: never the app's own stdin,
/// and input writes that can neither block a bound nor SIGPIPE the app.
final class ProcessRunnerStdinTests: XCTestCase {
    /// Without input a child reads /dev/null, not the app's stdin (F14). The
    /// test swaps its own fd 0 for a pipe whose write end stays open — a
    /// terminal as far as the child can tell — so a child that inherited it
    /// would block in `cat` until the bound fired.
    func testChildWithoutInputReadsDevNullNotTheAppsStdin() async throws {
        let pipe = Pipe()
        let savedStdin = dup(STDIN_FILENO)
        XCTAssertGreaterThanOrEqual(savedStdin, 0)
        dup2(pipe.fileHandleForReading.fileDescriptor, STDIN_FILENO)
        defer {
            dup2(savedStdin, STDIN_FILENO)
            close(savedStdin)
        }

        let started = Date()
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            timeout: .seconds(5)
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutputText, "")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "cat must see EOF at once")
    }

    /// A child that exits without reading its input makes the write fail
    /// with EPIPE; that must not kill the app with SIGPIPE (F15).
    func testLargeInputToAChildThatExitsWithoutReadingIsHarmless() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 7"],
            standardInput: Data(count: 1 << 20),
            timeout: .seconds(10)
        )
        XCTAssertEqual(result.exitCode, 7)
    }

    /// Input larger than the pipe buffer to a child that never reads must not
    /// block the run past its bound: the child is launched (and therefore
    /// terminable) before the write starts (F15).
    func testTimeoutHoldsWhileAnUnreadInputIsStillBeingWritten() async throws {
        let started = Date()
        do {
            _ = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec sleep 30"],
                standardInput: Data(count: 1 << 20),
                timeout: .milliseconds(300)
            )
            XCTFail("expected the run to time out")
        } catch let error as ProcessRunnerError {
            guard case .timedOut = error else {
                return XCTFail("expected a timeout, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the bound must hold during the write")
    }

    /// Input is still delivered in full to a child that reads it.
    func testInputIsDeliveredAndClosed() async throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/wc"),
            arguments: ["-c"],
            standardInput: payload,
            timeout: .seconds(10)
        )
        XCTAssertEqual(result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines), "200000")
    }
}
