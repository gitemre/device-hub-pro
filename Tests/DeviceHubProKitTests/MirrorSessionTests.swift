import XCTest
@testable import DeviceHubProKit

/// Session lifecycle, input and MMAP rules that need no emulator. The
/// session's port is `EmulatorManager.unreachableGrpcPort` (0): nothing can
/// listen on it, so the video stream fails at once and keeps reconnecting,
/// and no process on the Mac receives its requests (any user may listen on
/// port 1, which these tests used to dial).
final class MirrorSessionTests: XCTestCase {
    private static let port = EmulatorManager.unreachableGrpcPort

    private actor Recorder {
        private(set) var frames: [[TouchCommand]] = []
        func record(_ contacts: [TouchCommand]) { frames.append(contacts) }
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    // MARK: - Lifecycle

    func testInputStillWorksAfterARestart() async {
        let recorder = Recorder()
        let session = MirrorSession(port: Self.port, touchSender: { contacts, _, _ in
            await recorder.record(contacts)
        })
        session.start()
        session.stop()
        session.start()
        defer { session.stop() }

        session.send(TouchCommand(phase: .down, x: 10, y: 20, id: 3))
        let delivered = await waitUntil { await recorder.frames.count == 1 }
        XCTAssertTrue(delivered, "a restarted session must still forward touches")
    }

    func testDroppingASessionEndsItsTasks() async {
        weak var weakSession: MirrorSession?
        do {
            let session = MirrorSession(port: Self.port, touchSender: { _, _, _ in })
            session.start()
            weakSession = session
        }
        let released = await waitUntil { weakSession == nil }
        XCTAssertTrue(released, "the session's tasks must not keep it alive")
    }

    func testRunningStateFollowsStartAndStop() {
        let session = MirrorSession(port: Self.port, touchSender: { _, _, _ in })
        XCTAssertFalse(session.isRunning)
        session.start()
        XCTAssertTrue(session.isRunning)
        session.stop()
        XCTAssertFalse(session.isRunning)
        session.stop()
        XCTAssertFalse(session.isRunning, "stop is idempotent")
    }

    // MARK: - Video reconnect

    func testTheVideoStreamReconnectsAndReportsItsFailure() async {
        let session = MirrorSession(port: Self.port, touchSender: { _, _, _ in })
        session.start()
        defer { session.stop() }

        let retried = await waitUntil { session.videoAttempts >= 3 }
        XCTAssertTrue(retried, "a failed stream must be retried, not abandoned")
        XCTAssertNotNil(session.lastError, "the failure must be visible while reconnecting")
        XCTAssertFalse(session.isStreaming)
        XCTAssertTrue(session.isRunning, "an emulator session keeps running while it reconnects")
    }

    func testStopEndsTheReconnectLoop() async throws {
        let session = MirrorSession(port: Self.port, touchSender: { _, _, _ in })
        session.start()
        _ = await waitUntil { session.videoAttempts >= 1 }
        session.stop()
        try await Task.sleep(for: .milliseconds(100))
        let attempts = session.videoAttempts
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(session.videoAttempts, attempts)
    }

    // MARK: - Touch input

    func testContactsAreSentWithRealisticPressure() {
        let down = MirrorInput.touch(for: TouchCommand(phase: .down, x: 1, y: 2, id: 4))
        XCTAssertEqual(down.pressure, 0x400)
        XCTAssertEqual(down.identifier, 4)
        XCTAssertEqual(MirrorInput.touch(for: TouchCommand(phase: .move, x: 1, y: 2)).pressure, 0x400)
        XCTAssertEqual(MirrorInput.touch(for: TouchCommand(phase: .up, x: 1, y: 2)).pressure, 0)
        XCTAssertEqual(down.expiration, .unspecified, "a lost release must not pin the slot forever")
    }

    func testStoppingLiftsContactsThatAreStillDown() async {
        let recorder = Recorder()
        let (stream, continuation) = AsyncStream<[TouchCommand]>.makeStream()
        let input = Task {
            await MirrorInput.run(
                port: Self.port,
                display: 0,
                contacts: stream,
                send: { contacts, _, _ in await recorder.record(contacts) },
                reportError: { _ in }
            )
        }
        continuation.yield([TouchCommand(phase: .down, x: 5, y: 5, id: 1)])
        continuation.yield([TouchCommand(phase: .down, x: 9, y: 9, id: 2)])
        continuation.yield([TouchCommand(phase: .move, x: 7, y: 8, id: 2)])
        continuation.yield([TouchCommand(phase: .up, x: 5, y: 5, id: 1)])
        continuation.finish()
        await input.value

        let frames = await recorder.frames
        XCTAssertEqual(frames.count, 5)
        let release = frames.last ?? []
        XCTAssertEqual(release.map(\.id), [2], "only the contact still down is lifted")
        XCTAssertEqual(release.first?.phase, .up)
        XCTAssertEqual(release.first?.x, 7)
        XCTAssertEqual(release.first?.y, 8)
    }

    func testNothingIsLiftedWhenEveryContactEnded() async {
        let recorder = Recorder()
        let (stream, continuation) = AsyncStream<[TouchCommand]>.makeStream()
        let input = Task {
            await MirrorInput.run(
                port: Self.port,
                display: 0,
                contacts: stream,
                send: { contacts, _, _ in await recorder.record(contacts) },
                reportError: { _ in }
            )
        }
        continuation.yield([TouchCommand(phase: .down, x: 5, y: 5)])
        continuation.yield([TouchCommand(phase: .up, x: 5, y: 5)])
        continuation.finish()
        await input.value
        let count = await recorder.frames.count
        XCTAssertEqual(count, 2)
    }

    // MARK: - MMAP policy

    func testStartRequestsMMAPByDefault() {
        let session = MirrorSession(port: Self.port, touchSender: { _, _, _ in })
        session.start()
        defer { session.stop() }
        let disabled = ProcessInfo.processInfo.environment[MMAPPolicy.disableVariable] == "1"
        XCTAssertEqual(session.mmapAllowed, !disabled, "MMAP is the default fast path")

        session.start(forceRaw: true)
        XCTAssertEqual(session.mmapAllowed, false)
    }

    func testMMAPIsAllowedWhenRequestedAndNothingOverridesIt() {
        XCTAssertTrue(MMAPPolicy.isAllowed(requested: true, forceRaw: false, environment: [:]))
        XCTAssertFalse(MMAPPolicy.isAllowed(requested: false, forceRaw: false, environment: [:]))
        XCTAssertFalse(MMAPPolicy.isAllowed(requested: true, forceRaw: true, environment: [:]))
    }

    func testTheDisableSwitchWinsOverEverything() {
        let disabled = ["DHP_DISABLE_MMAP": "1"]
        XCTAssertFalse(MMAPPolicy.isAllowed(requested: true, forceRaw: false, environment: disabled))
        XCTAssertFalse(MMAPPolicy.isAllowed(
            requested: true,
            forceRaw: false,
            environment: disabled.merging(["DHP_FORCE_MMAP": "1"]) { $1 }
        ))
    }

    func testTheForceSwitchAllowsMMAPForARawRequest() {
        XCTAssertTrue(MMAPPolicy.isAllowed(
            requested: false,
            forceRaw: false,
            environment: ["DHP_FORCE_MMAP": "1"]
        ))
    }

    func testTheVersionGateStillGuardsOldEngines() {
        XCTAssertFalse(EmulatorVersion.supportsMMAP("36.6.11.0"))
        XCTAssertFalse(EmulatorVersion.supportsMMAP("37.2.1.0"))
        XCTAssertTrue(EmulatorVersion.supportsMMAP("37.2.3.0"))
        XCTAssertTrue(EmulatorVersion.supportsMMAP("37.2.8.0 (build_id 1)"))
        XCTAssertFalse(EmulatorVersion.supportsMMAP(""))
    }

    // MARK: - Reconnect decisions

    private typealias RetryState = MirrorVideo.RetryState

    /// How one attempt went: its opening snapshot, then `mapped` written
    /// mapped frames (or `raw` raw frames).
    private func progress(snapshot: Bool = true, mapped: Int = 0, raw: Int = 0) -> MirrorVideo.Progress {
        let progress = MirrorVideo.Progress()
        if snapshot { progress.snapshotDelivered() }
        if mapped > 0 { progress.verifyMMAP() }
        for _ in 0..<(mapped + raw) { progress.frameDelivered() }
        return progress
    }

    func testASnapshotAloneIsNoEvidenceForMMAPOrTheStream() {
        // An MMAP attempt that fails right after its opening snapshot used
        // to keep MMAP and reset the backoff: a 250 ms loop of getStatus, a
        // 14 MB screenshot and a new 64 MB frame file, forever.
        var state = RetryState(allowMMAP: true)
        for attempt in 1..<RetryState.unprovenMMAPAttemptLimit {
            state.streamStopped(usedMMAP: true, progress: progress())
            XCTAssertTrue(state.mmapCandidate, "attempt \(attempt) may still be a stream ending on a static screen")
            XCTAssertEqual(state.failures, attempt, "a snapshot alone must not reset the backoff")
        }
        state.streamStopped(usedMMAP: true, progress: progress())
        XCTAssertFalse(state.mmapCandidate, "attempts that never read a written mapped frame settle on raw")
        XCTAssertEqual(state.failures, RetryState.unprovenMMAPAttemptLimit)
    }

    func testAWrittenMappedFrameKeepsMMAPAndResetsTheCount() {
        var state = RetryState(allowMMAP: true)
        state.streamStopped(usedMMAP: true, progress: progress())
        state.streamStopped(usedMMAP: true, progress: progress())
        state.streamStopped(usedMMAP: true, progress: progress(mapped: 5))
        XCTAssertTrue(state.mmapProven)
        XCTAssertEqual(state.failures, 1, "streamed frames reset the backoff")
        for _ in 1..<RetryState.unprovenMMAPAttemptLimit {
            state.streamStopped(usedMMAP: true, progress: progress())
        }
        XCTAssertTrue(state.mmapCandidate, "the unproven count starts over after a verified attempt")
    }

    func testAnEngineThatNeverDeliveredFallsBackToRawAtOnce() {
        var state = RetryState(allowMMAP: true)
        state.streamStopped(usedMMAP: true, progress: progress(snapshot: false))
        XCTAssertFalse(state.mmapCandidate, "a refused handle or a broken engine")
    }

    func testAnEmulatorRestartKeepsAProvenMMAP() {
        var state = RetryState(allowMMAP: true)
        state.streamStopped(usedMMAP: true, progress: progress(mapped: 3))
        for _ in 0..<(RetryState.unprovenMMAPAttemptLimit + 2) {
            state.streamStopped(usedMMAP: true, progress: progress(snapshot: false))
        }
        XCTAssertTrue(state.mmapCandidate, "an unreachable emulator says nothing about MMAP")
    }

    func testRawAttemptsNeverTouchMMAPAndResetOnFrames() {
        var state = RetryState(allowMMAP: false)
        state.streamStopped(usedMMAP: false, progress: progress(snapshot: false))
        state.streamStopped(usedMMAP: false, progress: progress(snapshot: false))
        XCTAssertEqual(state.failures, 2)
        state.streamStopped(usedMMAP: false, progress: progress(snapshot: false, raw: 10))
        XCTAssertEqual(state.failures, 1)
        XCTAssertFalse(state.mmapCandidate)

        var mmap = RetryState(allowMMAP: true)
        mmap.engineChecked(supportsMMAP: false)
        XCTAssertFalse(mmap.mmapCandidate, "a known-old engine is never asked again")
    }

    func testASnapshotIsCountedApartFromStreamedFrames() {
        let progress = MirrorVideo.Progress()
        progress.snapshotDelivered()
        XCTAssertEqual(progress.delivered, 1)
        XCTAssertEqual(progress.streamed, 0)
        progress.frameDelivered()
        XCTAssertEqual(progress.delivered, 2)
        XCTAssertEqual(progress.streamed, 1)
    }

    // MARK: - MMAP buffer

    func testAnUnwrittenBufferIsNotAFrame() {
        XCTAssertFalse(MappedFrameCheck.isWritten(Data(count: 64)))
        var frame = Data(count: 64)
        frame[3] = 0xFF
        XCTAssertTrue(MappedFrameCheck.isWritten(frame))
    }

    func testTheFrameFileIsPrivateUnpredictableAndRemoved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MappedFileTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var first: MappedFile? = try MappedFile.makePrivate(port: 5554, display: 0, size: 4096, directory: directory)
        let second = try MappedFile.makePrivate(port: 5554, display: 0, size: 4096, directory: directory)
        let path = try XCTUnwrap(first?.path)

        XCTAssertNotEqual(path, second.path, "the name must not be predictable")
        XCTAssertTrue(path.hasPrefix(directory.path))
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        )
        XCTAssertEqual(fileMode & 0o777, 0o600)
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        )
        XCTAssertEqual(directoryMode & 0o777, 0o700)

        first = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the file is removed with the mapping")
    }

    func testFrameFilesNoMappingHoldsAreSwept() throws {
        // A crash or force-quit leaves its frame file behind; a live mapping
        // (here or in another running copy) keeps its lock and its file.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MappedFileTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = try MappedFile.makePrivate(port: 5554, display: 0, size: 4096, directory: directory)
        let abandoned = directory.appendingPathComponent("mirror-5556-0-\(UUID().uuidString).raw").path
        let unrelated = directory.appendingPathComponent("notes.txt").path
        XCTAssertTrue(FileManager.default.createFile(atPath: abandoned, contents: Data(count: 4096)))
        XCTAssertTrue(FileManager.default.createFile(atPath: unrelated, contents: Data("x".utf8)))

        let next = try MappedFile.makePrivate(port: 5554, display: 0, size: 4096, directory: directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned), "nobody holds it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path), "a live mapping keeps its file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: next.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated))
    }

    func testOldWorldReadableFrameFilesAreRemoved() throws {
        // Earlier builds left /tmp/devicehubpro-mirror-<port>-<display>.raw.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MappedFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

        for name in ["devicehubpro-mirror-5554-0.raw", "devicehubpro-mirror-5556-1.raw", "devicehubpro-mirror-notes.raw", "other.raw"] {
            XCTAssertTrue(FileManager.default.createFile(atPath: path(name), contents: Data("x".utf8)))
        }
        let target = path("target.raw")
        XCTAssertTrue(FileManager.default.createFile(atPath: target, contents: Data("x".utf8)))
        try FileManager.default.createSymbolicLink(atPath: path("devicehubpro-mirror-5558-0.raw"), withDestinationPath: target)

        MappedFile.sweepLegacyFiles(in: directory)

        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(left, ["devicehubpro-mirror-5558-0.raw", "devicehubpro-mirror-notes.raw", "other.raw", "target.raw"])
    }

    func testTheFrameFileNeverFollowsOrReusesAnExistingPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MappedFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let existing = directory.appendingPathComponent("existing.raw").path
        XCTAssertTrue(FileManager.default.createFile(atPath: existing, contents: Data("x".utf8)))
        XCTAssertThrowsError(try MappedFile(path: existing, size: 4096))

        let target = directory.appendingPathComponent("target").path
        let link = directory.appendingPathComponent("link.raw").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        XCTAssertThrowsError(try MappedFile(path: link, size: 4096))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target), "a planted symlink must not be followed")
    }

    func testASharedFrameDirectoryIsRefused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MappedFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o777]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try MappedFile.makePrivate(port: 1, display: 0, size: 4096, directory: directory))
    }
}
