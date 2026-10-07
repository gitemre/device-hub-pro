import XCTest
@testable import DeviceHubProKit

final class ProcessRunnerStreamTests: XCTestCase {
    /// Collects `onLine` callbacks, which arrive on background threads.
    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            lines.append(line)
        }

        var collected: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    func testStreamEmitsStdoutAndStderrAndReturnsTheExitCode() async throws {
        let collector = LineCollector()

        let code = try await ProcessRunner.stream(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf \"a\\nb\\n\"; printf \"c\\n\" >&2; exit 7"],
            onLine: { collector.append($0) }
        )

        XCTAssertEqual(code, 7)
        // Interleaving between the two streams is unspecified; the content of
        // each stream is not.
        XCTAssertEqual(collector.collected.filter { $0 != "c" }, ["a", "b"])
        XCTAssertEqual(collector.collected.filter { $0 == "c" }, ["c"])
    }

    func testStreamEmitsCarriageReturnProgressUpdatesAsSeparateLines() async throws {
        let collector = LineCollector()

        let code = try await ProcessRunner.stream(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "printf \"[==  ] 25%% Downloading\\r[=== ] 50%% Downloading\\r[====] 100%%\"",
            ],
            onLine: { collector.append($0) }
        )

        XCTAssertEqual(code, 0)
        XCTAssertEqual(collector.collected, [
            "[==  ] 25% Downloading",
            "[=== ] 50% Downloading",
            "[====] 100%",
        ])
    }

    func testStreamTreatsCarriageReturnLineFeedAsOneLineBreak() async throws {
        let collector = LineCollector()

        _ = try await ProcessRunner.stream(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf \"a\\r\\nb\\r\\n\""],
            onLine: { collector.append($0) }
        )

        XCTAssertEqual(collector.collected, ["a", "b"])
    }

    func testStreamEmitsEmptyLinesAndFlushesTheFinalPartialLine() async throws {
        let collector = LineCollector()

        _ = try await ProcessRunner.stream(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf \"a\\n\\nb\\nno-newline\""],
            onLine: { collector.append($0) }
        )

        XCTAssertEqual(collector.collected, ["a", "", "b", "no-newline"])
    }

    func testStreamEmitsNothingForEmptyOutput() async throws {
        let collector = LineCollector()

        let code = try await ProcessRunner.stream(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["-n", ""],
            onLine: { collector.append($0) }
        )

        XCTAssertEqual(code, 0)
        XCTAssertTrue(collector.collected.isEmpty)
    }

    func testStreamFeedsStandardInputAndClosesIt() async throws {
        let collector = LineCollector()

        // `cat` echoes both lines but only exits once stdin reaches EOF, so
        // the exit code pins the write *and* the close. Without the close the
        // stream never returns and the bounded wait fails loudly instead of
        // wedging the suite.
        let code = try await withTimeout(.seconds(10)) {
            try await ProcessRunner.stream(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "cat"],
                standardInput: Data("a\nb\n".utf8),
                onLine: { collector.append($0) }
            )
        }

        XCTAssertEqual(code, 0)
        XCTAssertEqual(collector.collected, ["a", "b"])
    }

    func testStreamAppliesTheEnvironmentOverride() async throws {
        let collector = LineCollector()

        let code = try await ProcessRunner.stream(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf \"%s\\n\" \"$DHP_STREAM_TEST\""],
            environment: ["DHP_STREAM_TEST": "hello"],
            onLine: { collector.append($0) }
        )

        XCTAssertEqual(code, 0)
        XCTAssertEqual(collector.collected, ["hello"])
    }

    func testCancellingTheCallingTaskTerminatesTheProcess() async throws {
        let (lines, continuation) = AsyncStream<String>.makeStream()
        let task = Task {
            try await ProcessRunner.stream(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo started; exec sleep 30"],
                onLine: { continuation.yield($0) }
            )
        }

        let first = try await firstLine(from: lines, timeout: .seconds(10))
        XCTAssertEqual(first, "started")

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected CancellationError after cancelling the stream")
        } catch is CancellationError {
            // Expected: cancelling the caller terminates the process.
        }
    }

    func testStreamDeliversAnUnterminatedPromptAndAcceptsInteractiveInput() async throws {
        let collector = LineCollector()
        let input = StdinBox()

        // The prompt has no line terminator, so a line-oriented reader would
        // hold it back while `read` waits for an answer that never comes.
        let code = try await withTimeout(.seconds(10)) {
            try await ProcessRunner.stream(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf 'Accept? (y/N): '; read answer; printf 'got:%s\\n' \"$answer\"",
                ],
                onStdinReady: { stdin in input.attach(stdin) },
                partialLineHandler: { $0.hasSuffix("(y/N): ") },
                onLine: { line in
                    collector.append(line)
                    if line.contains("(y/N)") {
                        input.write("y\n")
                    }
                }
            )
        }

        XCTAssertEqual(code, 0)
        XCTAssertEqual(collector.collected, ["Accept? (y/N): ", "got:y"])
    }

    private final class StdinBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stdin: ProcessStdin?

        func attach(_ stdin: ProcessStdin) {
            lock.lock()
            self.stdin = stdin
            lock.unlock()
        }

        func write(_ text: String) {
            lock.lock()
            let stdin = self.stdin
            lock.unlock()
            stdin?.write(text)
        }
    }

    private struct TimedOut: Error {}

    private func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimedOut()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func firstLine(
        from lines: AsyncStream<String>,
        timeout: Duration
    ) async throws -> String? {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                var iterator = lines.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimedOut()
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }
}
