import XCTest
@testable import DeviceHubProKit

/// `ProcessStopSignal`: a stream or run that is cancelled or times out stops
/// its child with SIGTERM by default and with SIGINT on request — what
/// `simctl io recordVideo` needs to write a playable movie. The stub traps
/// both signals and reports which one arrived (`finalized` for INT, which
/// also creates the file named by its last argument, `terminated` for TERM).
final class ProcessRunnerStopSignalTests: XCTestCase {
    private static let udid = "95D9676B-3317-4BA5-8CF6-3CDD0488CACA"

    private struct Stub {
        let directory: URL
        let command: URL
        let marker: URL
        let arguments: URL
    }

    /// A recorder stand-in: announces itself on stderr like simctl
    /// (`Recording started`, unless `announces` is false), then idles until a
    /// signal. The short sleeps let the shell run its trap promptly. With
    /// `ignoresInterrupt` it ignores SIGINT, so only the SIGKILL after the
    /// grace period ends it.
    private func makeRecorderStub(announces: Bool = true, ignoresInterrupt: Bool = false) throws -> Stub {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessRunnerStopSignalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Best effort: a leftover temporary folder must not fail the test.
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let marker = directory.appendingPathComponent("marker")
        let arguments = directory.appendingPathComponent("arguments")
        let command = directory.appendingPathComponent("simctl")
        let interrupt = ignoresInterrupt
            ? "trap '' INT"
            : #"trap 'if [ -n "$last" ]; then : > "$last"; fi; printf finalized > "\#(marker.path)"; echo finalized; exit 0' INT"#
        // The traps are set before the arguments are written, so a test that
        // waits for the arguments file knows they are in place.
        let script = """
        #!/bin/sh
        for last; do :; done
        \(interrupt)
        trap 'printf terminated > "\(marker.path)"; exit 1' TERM
        printf '%s\\n' "$@" > '\(arguments.path)'
        \(announces ? #"echo "Recording started" >&2"# : "")
        while :; do sleep 0.05; done
        """
        try Data(script.utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        return Stub(directory: directory, command: command, marker: marker, arguments: arguments)
    }

    private func marker(_ stub: Stub) throws -> String {
        try String(contentsOf: stub.marker, encoding: .utf8)
    }

    /// Cancelling an `.interrupt` stream sends SIGINT; the call throws
    /// `CancellationError` only after the child ran its handler and exited,
    /// and the handler's output was still delivered.
    func testCancellingAnInterruptStreamSendsSIGINTAndWaitsForTheChild() async throws {
        let stub = try makeRecorderStub()
        let lines = LineBox()
        let task = Task {
            try await ProcessRunner.stream(
                executable: stub.command,
                arguments: [],
                stopSignal: .interrupt,
                onLine: { lines.append($0) }
            )
        }
        try await waitUntil { lines.values.contains("Recording started") }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        XCTAssertEqual(try marker(stub), "finalized", "the child must get SIGINT, not SIGTERM")
        XCTAssertTrue(lines.values.contains("finalized"), "output written while stopping is delivered")
    }

    /// The default stays SIGTERM.
    func testTheDefaultStopSignalIsSIGTERM() async throws {
        let stub = try makeRecorderStub()
        let lines = LineBox()
        let task = Task {
            try await ProcessRunner.stream(executable: stub.command, arguments: [], onLine: { lines.append($0) })
        }
        try await waitUntil { lines.values.contains("Recording started") }
        task.cancel()
        _ = try? await task.value
        XCTAssertEqual(try marker(stub), "terminated")
    }

    /// A bounded run's timeout sends the stop signal too.
    func testATimedOutInterruptRunSendsSIGINT() async throws {
        let stub = try makeRecorderStub()
        do {
            _ = try await ProcessRunner.run(
                executable: stub.command,
                arguments: [],
                timeout: .milliseconds(500),
                stopSignal: .interrupt
            )
            XCTFail("expected a timeout")
        } catch ProcessRunnerError.timedOut {
            // expected
        }
        try await waitUntil { FileManager.default.fileExists(atPath: stub.marker.path) }
        XCTAssertEqual(try marker(stub), "finalized")
    }

    /// `SimctlClient.recordVideo` runs `io <udid> recordVideo --codec=… <file>`,
    /// reports the start, and returns normally once cancelling interrupted
    /// the recorder and it exited.
    func testRecordVideoStopsWithSIGINT() async throws {
        let stub = try makeRecorderStub()
        let simctl = SimctlClient(simctlURL: stub.command)
        let destination = stub.directory.appendingPathComponent("recording.mov")
        let started = LineBox()
        let task = Task {
            try await simctl.recordVideo(
                udid: Self.udid,
                to: destination,
                codec: .h264,
                onStarted: { started.append("started") }
            )
        }
        try await waitUntil { !started.values.isEmpty }
        task.cancel()
        try await task.value
        XCTAssertEqual(started.values, ["started"])
        XCTAssertEqual(try marker(stub), "finalized")
        let arguments = try String(contentsOf: stub.arguments, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(arguments, ["io", Self.udid, "recordVideo", "--codec=h264", destination.path])
    }

    /// A recorder that ignores the interrupt is SIGKILLed after the grace
    /// period, and its movie is reported incomplete, not returned as done.
    func testAKilledRecorderIsAnIncompleteRecording() async throws {
        let stub = try makeRecorderStub(ignoresInterrupt: true)
        let simctl = SimctlClient(simctlURL: stub.command)
        let started = LineBox()
        let task = Task {
            try await simctl.recordVideo(
                udid: Self.udid,
                to: stub.directory.appendingPathComponent("recording.mov"),
                onStarted: { started.append("started") }
            )
        }
        try await waitUntil { !started.values.isEmpty }
        task.cancel()
        do {
            try await task.value
            XCTFail("a killed recorder must not count as a finished movie")
        } catch let error as SimctlClientError {
            XCTAssertEqual(error, .incompleteRecording("simctl ignored the interrupt and was killed"))
        }
    }

    /// Stopped before `Recording started`, there is no movie to return.
    func testARecordingStoppedBeforeItStartedIsIncomplete() async throws {
        let stub = try makeRecorderStub(announces: false)
        let simctl = SimctlClient(simctlURL: stub.command)
        let task = Task {
            try await simctl.recordVideo(udid: Self.udid, to: stub.directory.appendingPathComponent("recording.mov"))
        }
        try await waitUntil { FileManager.default.fileExists(atPath: stub.arguments.path) }
        task.cancel()
        do {
            try await task.value
            XCTFail("a recording that never started must not count as a finished movie")
        } catch let error as SimctlClientError {
            XCTAssertEqual(error, .incompleteRecording("stopped before simctl reported Recording started"))
        }
        XCTAssertEqual(try marker(stub), "finalized")
    }

    // MARK: Helpers

    private func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not met within \(timeout) s") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private final class LineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []

        func append(_ line: String) {
            lock.lock()
            stored.append(line)
            lock.unlock()
        }

        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}
