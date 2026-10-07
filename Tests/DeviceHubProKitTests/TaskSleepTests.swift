import XCTest
@testable import DeviceHubProKit

/// Every `Task.sleep(for:)` in this package goes through the non-generic shim
/// in `TaskSleep.swift`. The shim works around a toolchain bug that crashed
/// native-build release builds (see `docs/native-build-async-odr.md`). These
/// tests pin that it still behaves like the standard library's sleep: it
/// waits at least the duration and throws `CancellationError` when cancelled.
/// The link-level bug itself shows only in a native-build release link, so
/// `Scripts/async-odr-repro/repro.sh` and `Scripts/check-async-odr.sh` cover
/// it rather than a unit test.
final class TaskSleepTests: XCTestCase {
    func testSleepWaitsAtLeastTheDuration() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertGreaterThanOrEqual(clock.now - start, .milliseconds(80))
    }

    func testCancellingASleepThrowsCancellationErrorPromptly() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let sleeper = Task {
            try await Task.sleep(for: .seconds(60))
        }
        try await Task.sleep(for: .milliseconds(50))
        sleeper.cancel()

        do {
            try await sleeper.value
            XCTFail("expected the sleep to be cancelled")
        } catch is CancellationError {
            // expected
        }
        XCTAssertLessThan(clock.now - start, .seconds(5), "cancellation must end the 60 s sleep")
    }

    func testSleepInAnAlreadyCancelledTaskThrowsWithoutWaiting() async throws {
        let clock = ContinuousClock()
        let sleeper = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            let start = clock.now
            do {
                try await Task.sleep(for: .seconds(60))
                return (threw: false, elapsed: clock.now - start)
            } catch is CancellationError {
                return (threw: true, elapsed: clock.now - start)
            }
        }
        sleeper.cancel()
        let outcome = try await sleeper.value
        XCTAssertTrue(outcome.threw, "a cancelled task must not sleep")
        XCTAssertLessThan(outcome.elapsed, .seconds(5))
    }

    /// The pattern that crashed at launch: `ProcessRunner.run` races the child
    /// against a sleeping child task and cancels the sleeper when the child
    /// wins. It must return the child's result and leave no sleeper behind.
    func testTimeoutRaceReturnsTheFastChildsResult() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            timeout: .seconds(30)
        )
        XCTAssertEqual(result.exitCode, 1)
    }
}
