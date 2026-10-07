import Foundation
import Synchronization
import XCTest
@testable import DeviceHubProKit

final class ChildProcessRegistryTests: XCTestCase {
    private func sleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        return process
    }

    func testTerminateAllEndsARegisteredChild() throws {
        let process = try sleeper()
        defer { if process.isRunning { process.terminate() } }
        ChildProcessRegistry.terminateAll()
        ChildProcessRegistry.register(process)
        XCTAssertEqual(ChildProcessRegistry.registeredCount, 1)
        ChildProcessRegistry.terminateAll()
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(ChildProcessRegistry.registeredCount, 0)
    }

    func testAnUnregisteredChildIsLeftAlone() throws {
        let process = try sleeper()
        defer { process.terminate() }
        ChildProcessRegistry.register(process)
        ChildProcessRegistry.unregister(process)
        ChildProcessRegistry.terminateAll()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(process.isRunning)
    }

    func testAStreamedChildIsRegisteredWhileRunningAndEndedByTerminateAll() async throws {
        let task = Task {
            try await ProcessRunner.streamChunks(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["60"],
                onChunk: { _ in true }
            )
        }
        let deadline = Date().addingTimeInterval(5)
        while ChildProcessRegistry.registeredCount == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(ChildProcessRegistry.registeredCount, 1)
        ChildProcessRegistry.terminateAll()
        let status = try await task.value
        XCTAssertEqual(status, SIGTERM)
        XCTAssertEqual(ChildProcessRegistry.registeredCount, 0)
    }
}

final class FastInputTerminationSignalTests: XCTestCase {
    private func disposition(_ number: Int32) -> Bool {
        var action = sigaction()
        sigaction(number, nil, &action)
        return action.__sigaction_u.__sa_handler == nil || unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) == 0
    }

    func testTheSignalPathEndsRegisteredChildrenResetsTheHandlerAndSecondInstallIsANoOp() throws {
        let process = try sleeper()
        defer { if process.isRunning { process.terminate() } }
        ChildProcessRegistry.register(process)
        let raised = expectation(description: "reraised")
        let seen = Mutex<[Int32]>([])
        FastInputTermination.installSignalHandlers(signals: [SIGUSR1]) { number in
            seen.withLock { $0.append(number) }
            raised.fulfill()
        }
        // Installed: the signal is ignored by default action, handled by the source.
        XCTAssertFalse(disposition(SIGUSR1))
        kill(getpid(), SIGUSR1)
        wait(for: [raised], timeout: 5)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(seen.withLock { $0 }, [SIGUSR1])
        XCTAssertTrue(disposition(SIGUSR1), "the handler resets the signal to SIG_DFL before re-raising")

        // A second install does nothing: SIGUSR2 stays at its default.
        FastInputTermination.installSignalHandlers(signals: [SIGUSR2]) { _ in }
        XCTAssertTrue(disposition(SIGUSR2))
    }

    private func sleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        return process
    }
}

final class ErrorCancellationTests: XCTestCase {
    func testCancellationKindsAreRecognised() {
        XCTAssertTrue(CancellationError().isCancellation)
        XCTAssertTrue(URLError(.cancelled).isCancellation)
        XCTAssertTrue(CocoaError(.userCancelled).isCancellation)
        XCTAssertTrue(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError).isCancellation)
        XCTAssertFalse(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError).isCancellation)
        XCTAssertFalse(NSError(domain: NSPOSIXErrorDomain, code: NSUserCancelledError).isCancellation, "only the Cocoa domain")
        XCTAssertFalse(URLError(.timedOut).isCancellation)
        XCTAssertFalse(ProcessRunnerError.timedOut(command: "x", seconds: .seconds(1)).isCancellation)
    }
}
