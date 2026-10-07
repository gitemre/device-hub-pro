import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The session hubs' order, pinned from outside the model. For every
/// `MirrorTeardownCause`: what the teardown has already done when it stops
/// the transport (the generations, the recording, the frame feed, the
/// per-device workers) and what it does only afterwards (the session, the
/// stream health, the device context, the Controls panel), how it stops a
/// physical session, and that keys held on the frame are released before
/// the stop. Also the stats poll's side: a stats answer that
/// lands after its session was replaced, the fatal path's order (on the
/// controller alone and through the model's lifecycle wiring), and Back
/// over a physical session's control socket.
///
/// The order among the steps before the stop, and among those after it, is
/// not observable through today's seams (the children have none); the
/// full-sequence spy comes with `DeviceSession` (S25).
///
/// No transport and no device: the sessions are fakes the model's session
/// factory hands out, the phone's adb is a stub that answers nothing (or
/// `/usr/bin/false` where the lifecycle runs), and nothing can listen on the
/// emulator port.
@MainActor
final class MirrorTeardownOrderTests: XCTestCase {
    private let phone = AndroidDevice.online("HT4CWJT01234", model: "Pixel 8")
    /// Set as the active port after the attach, so the teardown's
    /// port-bound steps (the battery write, the shared control connection)
    /// have something to stop. Nothing can serve it, so a step that got out
    /// anyway could never reach an emulator.
    private static let port = EmulatorManager.unreachableGrpcPort

    /// A transport that runs `onStop` the moment the hub stops it, on the
    /// main actor the hub runs on.
    private class SpySession: MirrorSessionProtocol, @unchecked Sendable {
        let frames = FrameStore()
        let transport: MirrorTransport = .h264

        private let lock = NSLock()
        private var _isRunning = false
        private var _stopCount = 0
        private var _onStop: (@MainActor @Sendable () -> Void)?
        private var _keyLog: [String] = []

        var lastError: String? { nil }

        var supportsHardwareKeys: Bool { true }

        /// Hardware key events ("power down") and stops, in order.
        var keyLog: [String] {
            lock.withLock { _keyLog }
        }

        var isRunning: Bool {
            lock.withLock { _isRunning }
        }

        var stopCount: Int {
            lock.withLock { _stopCount }
        }

        var onStop: (@MainActor @Sendable () -> Void)? {
            get { lock.withLock { _onStop } }
            set { lock.withLock { _onStop = newValue } }
        }

        func start() {
            lock.withLock { _isRunning = true }
        }

        func stop() {
            let hook = lock.withLock {
                _isRunning = false
                _stopCount += 1
                _keyLog.append("stop")
                return _onStop
            }
            if let hook {
                MainActor.assumeIsolated { hook() }
            }
        }

        func resync() async {}

        func stats() async -> MirrorStats {
            MirrorStats(fps: 0, totalFrames: 0, dropped: 0, averageLatencyMs: 0)
        }

        func send(_ command: TouchCommand) {}
        func send(contacts: [TouchCommand]) {}
        func send(_ command: KeyboardCommand) {}

        func send(_ event: HardwareKeyEvent) {
            lock.withLock { _keyLog.append("\(event.key) \(event.isDown ? "down" : "up")") }
        }
    }

    /// What the model showed at one moment of the teardown.
    private struct Snapshot: Equatable {
        var generation: Int
        var isRecording: Bool
        var hasReplayRing: Bool
        var hasBatteryWrite: Bool
        var isVmPaused: Bool
        var holdsTheSession: Bool
        var statsText: String
        var streamWarning: String?
        var serial: String?
        var port: Int?
        var controlsLoaded: Bool
    }

    private final class SnapshotBox {
        var value: Snapshot?
    }

    private static func snapshot(_ model: AppModel, _ session: SpySession) -> Snapshot {
        Snapshot(
            generation: model.mirrorSessionGeneration,
            isRecording: model.workspace.media.isRecording,
            hasReplayRing: model.workspace.media.replayBuffer != nil,
            hasBatteryWrite: model.workspace.hardware.batteryApplyTask != nil,
            isVmPaused: model.workspace.extras.isVmPaused,
            holdsTheSession: model.workspace.mirror.session === session,
            statsText: model.workspace.mirror.statsText,
            streamWarning: model.workspace.mirror.mirrorStreamWarning,
            serial: model.activeDeviceSerial,
            port: model.workspace.context.port,
            controlsLoaded: model.workspace.controlsPanel.controlsLoaded
        )
    }

    /// New frames, one every 40 ms (the recorder paces at 30 fps).
    private func feed(_ frames: FrameStore, count: Int) async throws {
        let width = 128
        let height = 256
        for index in 0..<count {
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                bytes[offset] = UInt8((index * 40) % 256)
            }
            frames.put(Frame(data: Data(bytes), width: width, height: height, seq: 0))
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    /// A model mirroring `phone` over `session` on `port`, with everything
    /// the teardown undoes in a non-default state: a recording with frames,
    /// a filled replay ring, a pending battery write, a paused VM, a stats
    /// line, a stream warning and a loaded Controls panel. Clips go to a
    /// scratch directory or are deleted, never to the Desktop.
    private func loadedModel(session: SpySession) async throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirrorTeardownOrder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let adb = try makeStubAdb(arms: "")
        let model = AppModel.testing(adb: adb.client)
        model.workspace.mirror.sessionFactoryOverride = { _, _ in session }
        model.recordingFinalizer.recordingAutoSaveDirectory = directory
        model.recordingFinalizer.recordingSaveOverride = { url, _ in
            // Each clip has a temporary directory of its own.
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        model.inventory.devices = [phone]

        await model.mirror(device: phone)
        XCTAssertTrue(model.workspace.mirror.session === session)
        model.workspace.context.port = Self.port
        await model.workspace.media.toggleRecording()
        XCTAssertTrue(model.workspace.media.isRecording)
        try await feed(session.frames, count: 6)
        await waitUntil("the replay ring never filled") { model.workspace.media.canSaveReplay }
        await waitUntil("the stats poll never ran") { !model.workspace.mirror.statsText.isEmpty }
        model.workspace.mirror.noteEmulatorStream(isStreaming: false, lastError: "stream ended")
        model.workspace.extras.isVmPaused = true
        model.workspace.controlsPanel.controlsLoaded = true
        // Started without a suspension before the teardown, so it is still
        // pending when the hub cancels it.
        model.workspace.hardware.setBatteryLevel(42)
        XCTAssertNotNil(model.workspace.hardware.batteryApplyTask)
        return model
    }

    /// Tears the mirror down for `cause` and checks the model at the
    /// transport stop and after the hub returned.
    private func assertTeardownOrder(
        _ cause: MirrorController.MirrorTeardownCause,
        session: SpySession = SpySession(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let model = try await loadedModel(session: session)
        let generation = model.mirrorSessionGeneration
        let statsText = model.workspace.mirror.statsText
        let atStop = SnapshotBox()
        session.onStop = { atStop.value = Self.snapshot(model, session) }

        model.tearDownMirror(cause: cause)

        XCTAssertEqual(session.stopCount, 1, "the transport is stopped once", file: file, line: line)
        XCTAssertEqual(
            atStop.value,
            Snapshot(
                generation: generation + 1,
                isRecording: false,
                hasReplayRing: false,
                hasBatteryWrite: false,
                isVmPaused: false,
                holdsTheSession: true,
                statsText: statsText,
                streamWarning: "stream ended",
                serial: phone.serial,
                port: Self.port,
                controlsLoaded: true
            ),
            "before the stop: generations, recording, feed and device work; after it: session, health, context, Controls",
            file: file,
            line: line
        )
        XCTAssertEqual(
            Self.snapshot(model, session),
            Snapshot(
                generation: generation + 1,
                isRecording: false,
                hasReplayRing: false,
                hasBatteryWrite: false,
                isVmPaused: false,
                holdsTheSession: false,
                statsText: "",
                streamWarning: nil,
                serial: nil,
                port: nil,
                controlsLoaded: false
            ),
            file: file,
            line: line
        )
        await model.recordingFinalizer.waitForRecordingsToFinish()
    }

    // MARK: Teardown order per cause

    func testUserStopStopsTheTransportBetweenTheWorkersAndTheResets() async throws {
        try await assertTeardownOrder(.userStop)
    }

    func testReplacedStopsTheTransportBetweenTheWorkersAndTheResets() async throws {
        try await assertTeardownOrder(.replaced)
    }

    func testDisconnectedStopsTheTransportBetweenTheWorkersAndTheResets() async throws {
        try await assertTeardownOrder(.disconnected)
    }

    func testTransportFatalStopsTheTransportBetweenTheWorkersAndTheResets() async throws {
        try await assertTeardownOrder(.transportFatal)
    }

    func testQuitStopsTheTransportBetweenTheWorkersAndTheResets() async throws {
        try await assertTeardownOrder(.quit)
    }

    // MARK: Physical transport stop

    /// A physical session that logs the hub's calls on it, in order.
    private final class PhysicalSpySession: SpySession, PhysicalSessionControlling, @unchecked Sendable {
        let serial: String

        private let log = NSLock()
        private var _calls: [String] = []
        private var _onDeviceClipboard: (@Sendable (String) -> Void)?

        init(serial: String) {
            self.serial = serial
        }

        var calls: [String] {
            log.withLock { _calls }
        }

        var usesControlSocket: Bool { true }

        var onDeviceClipboard: (@Sendable (String) -> Void)? {
            get { log.withLock { _onDeviceClipboard } }
            set {
                log.withLock {
                    _onDeviceClipboard = newValue
                    _calls.append(newValue == nil ? "clipboard hook cleared" : "clipboard hook set")
                }
            }
        }

        override func stop() {
            log.withLock { _calls.append("stop") }
            super.stop()
        }

        func stopAndWait(timeout: TimeInterval) {
            log.withLock { _calls.append("stopAndWait(\(timeout))") }
            super.stop()
        }

        func setDeviceClipboard(_ text: String, paste: Bool) {}
        func sendBackOrScreenOn() {}
    }

    /// The same order on a physical session, whose clipboard hook is dropped
    /// before its transport stops: synchronously (bounded) at quit,
    /// asynchronously for every other cause.
    private func assertPhysicalTeardownOrder(
        _ cause: MirrorController.MirrorTeardownCause,
        stops expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let session = PhysicalSpySession(serial: phone.serial)
        session.onDeviceClipboard = { _ in }
        try await assertTeardownOrder(cause, session: session, file: file, line: line)
        XCTAssertEqual(
            session.calls,
            ["clipboard hook set", "clipboard hook cleared", expected],
            file: file,
            line: line
        )
    }

    func testUserStopDropsTheClipboardHookThenStopsThePhysicalSession() async throws {
        try await assertPhysicalTeardownOrder(.userStop, stops: "stop")
    }

    func testReplacedDropsTheClipboardHookThenStopsThePhysicalSession() async throws {
        try await assertPhysicalTeardownOrder(.replaced, stops: "stop")
    }

    func testDisconnectedDropsTheClipboardHookThenStopsThePhysicalSession() async throws {
        try await assertPhysicalTeardownOrder(.disconnected, stops: "stop")
    }

    func testTransportFatalDropsTheClipboardHookThenStopsThePhysicalSession() async throws {
        try await assertPhysicalTeardownOrder(.transportFatal, stops: "stop")
    }

    func testQuitDropsTheClipboardHookThenWaitsForThePhysicalSessionToStop() async throws {
        try await assertPhysicalTeardownOrder(.quit, stops: "stopAndWait(2.0)")
    }

    // MARK: Held hardware keys

    /// For every cause, keys still held on the frame are released through
    /// the session before its transport stops (power first, then volume,
    /// whatever the press order), and the next session starts with none
    /// held.
    func testEveryTeardownReleasesHeldHardwareKeysBeforeItStopsTheTransport() async throws {
        let causes: [MirrorController.MirrorTeardownCause] = [.userStop, .replaced, .disconnected, .transportFatal, .quit]
        for cause in causes {
            let adb = try makeStubAdb(arms: "")
            let model = AppModel.testing(adb: adb.client)
            let session = SpySession()
            let next = FakeMirrorSession()
            var built: [any MirrorSessionProtocol] = [session, next]
            model.workspace.mirror.sessionFactoryOverride = { _, _ in built.removeFirst() }
            model.inventory.devices = [phone]
            await model.mirror(device: phone)
            XCTAssertTrue(model.workspace.mirror.session === session)

            model.mirror.pressHardwareKey(.volumeUp)
            model.mirror.pressHardwareKey(.power)
            model.tearDownMirror(cause: cause)

            XCTAssertEqual(
                session.keyLog,
                ["volumeUp down", "power down", "power up", "volumeUp up", "stop"],
                "\(cause)"
            )

            await model.mirror(device: phone)
            XCTAssertTrue(model.workspace.mirror.session === next)
            model.mirror.releaseAllHardwareKeys()
            XCTAssertEqual(next.hardwareKeyEvents, [], "\(cause): nothing is held on the next session")
            model.stopMirror()
        }
    }

    // MARK: Stale stats

    /// A physical-looking session whose `stats()` waits until the test
    /// releases it, then answers with frames it never had and a fatal
    /// error: applied to the model, either would show on (or tear down) the
    /// session that replaced it.
    private final class GatedStatsSession: MirrorSessionProtocol, PhysicalSessionControlling, @unchecked Sendable {
        let serial: String
        let frames = FrameStore()
        let transport: MirrorTransport = .h264
        let answer = MirrorStats(fps: 11, totalFrames: 111, dropped: 0, averageLatencyMs: 0)

        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var _asked = 0
        private var _isRunning = false
        private var _onDeviceClipboard: (@Sendable (String) -> Void)?

        init(serial: String) {
            self.serial = serial
        }

        /// How many `stats()` calls began.
        var asked: Int {
            lock.withLock { _asked }
        }

        var usesControlSocket: Bool { false }

        var onDeviceClipboard: (@Sendable (String) -> Void)? {
            get { lock.withLock { _onDeviceClipboard } }
            set { lock.withLock { _onDeviceClipboard = newValue } }
        }

        var lastError: String? { "The replaced session failed." }

        var isRunning: Bool {
            lock.withLock { _isRunning }
        }

        func start() {
            lock.withLock { _isRunning = true }
        }

        func stop() {
            lock.withLock { _isRunning = false }
        }

        func stopAndWait(timeout: TimeInterval) {
            stop()
        }

        func stats() async -> MirrorStats {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let answerNow = lock.withLock {
                    _asked += 1
                    if released { return true }
                    waiting.append(continuation)
                    return false
                }
                if answerNow { continuation.resume() }
            }
            return answer
        }

        /// Answers every pending and later `stats()` call.
        func release() {
            let pending = lock.withLock {
                released = true
                defer { waiting = [] }
                return waiting
            }
            for continuation in pending {
                continuation.resume()
            }
        }

        func setDeviceClipboard(_ text: String, paste: Bool) {}
        func sendBackOrScreenOn() {}
        func resync() async {}
        func send(_ command: TouchCommand) {}
        func send(contacts: [TouchCommand]) {}
        func send(_ command: KeyboardCommand) {}
    }

    /// The replaced session's `stats()` answers after the replacement: its
    /// result is dropped, so it neither writes the stats line nor stops the
    /// session that replaced it.
    func testAStaleStatsAnswerAfterAReplacementIsIgnored() async throws {
        let adb = try makeStubAdb(arms: "")
        let model = AppModel.testing(adb: adb.client)
        let stale = GatedStatsSession(serial: phone.serial)
        addTeardownBlock { stale.release() }
        let fresh = FakeMirrorSession()
        var built: [any MirrorSessionProtocol] = [stale, fresh]
        model.workspace.mirror.sessionFactoryOverride = { _, _ in built.removeFirst() }
        model.inventory.devices = [phone]

        await model.mirror(device: phone)
        XCTAssertTrue(model.workspace.mirror.session === stale)
        await waitUntil("the stats poll never asked the first session") { stale.asked == 1 }

        await model.mirror(device: phone)
        XCTAssertTrue(model.workspace.mirror.session === fresh)
        await waitUntil("the new session's poll never ran") { !model.workspace.mirror.statsText.isEmpty }
        let freshText = model.workspace.mirror.statsText

        stale.release()
        // The stale poll resumes on the main actor; give it the chance.
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(model.workspace.mirror.statsText, freshText)
        XCTAssertFalse(model.workspace.mirror.statsText.contains("111"), model.workspace.mirror.statsText)
        XCTAssertTrue(model.workspace.mirror.session === fresh, "the stale error does not tear the new session down")
        XCTAssertEqual(model.activeDeviceSerial, phone.serial)
        XCTAssertEqual(fresh.stopCount, 0)
        XCTAssertNil(model.workspace.status.errorMessage)
        XCTAssertNil(model.workspace.mirror.lastTransportError)
        XCTAssertEqual(stale.asked, 1, "the replaced session is not polled again")
        model.stopMirror()
    }

    // MARK: Fatal path

    /// A physical transport that fails for good, through the model: the
    /// stats poll tears the mirror down, then records the failure for the
    /// waiting panel's Details and, with no reconnect cycle armed, raises it.
    func testAFatalPhysicalErrorTearsTheMirrorDownThenIsRecordedAndRaised() async throws {
        let adb = try makeStubAdb(arms: "")
        let model = AppModel.testing(adb: adb.client)
        let session = FakePhysicalSession(serial: phone.serial)
        model.workspace.mirror.sessionFactoryOverride = { _, _ in session }
        model.inventory.devices = [phone]
        await model.mirror(device: phone)
        XCTAssertTrue(model.workspace.mirror.session === session)

        session.fail("The device went away.")

        await waitUntil("the stats poll never tore the mirror down") { model.workspace.mirror.session == nil }
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertNil(model.activeDeviceSerial)
        XCTAssertEqual(model.workspace.mirror.statsText, "")
        XCTAssertEqual(model.workspace.mirror.lastTransportError, "The device went away.", "recorded after the teardown's reset")
        XCTAssertEqual(model.workspace.status.errorMessage, "The device went away.", "no cycle is armed: the alert shows it")
        XCTAssertEqual(model.deviceSelection, .device(phone.serial), "the teardown leaves the selection")
    }

    /// What the fatal path did, in order.
    private final class EventLog {
        var entries: [String] = []
    }

    /// A controller alone, polling a fake physical session for `phone`. Its
    /// closures log the armed read and the teardown, which does to the
    /// mirror what the model's hub does, in the hub's order.
    private func fatalHarness(
        armed: Bool
    ) -> (mirror: MirrorController, session: FakePhysicalSession, status: StatusCenter, log: EventLog) {
        let context = ActiveDeviceContext()
        let status = StatusCenter()
        let mirror = MirrorController(adbClient: nil, context: context, status: status, perfLog: nil)
        let session = FakePhysicalSession(serial: phone.serial)
        let log = EventLog()
        mirror.isAutoReconnectArmed = { serial in
            log.entries.append("armed? \(serial)")
            return armed
        }
        mirror.onTransportFatal = { [weak mirror] serial in
            log.entries.append("teardown \(serial ?? "nil"), stash \(mirror?.lastTransportError ?? "empty")")
            mirror?.stopStatsPolling()
            mirror?.stopSession(cause: .transportFatal)
            mirror?.session = nil
            mirror?.resetMirrorHealth()
            context.clear()
        }
        context.serial = phone.serial
        mirror.session = session
        session.start()
        mirror.startStatsPolling()
        addTeardownBlock { @MainActor in mirror.stopStatsPolling() }
        return (mirror, session, status, log)
    }

    /// The armed marker is read before the teardown (which clears the stash
    /// an earlier input error left), the failure is recorded after it and,
    /// being new with no cycle armed, raised; the path runs once.
    func testTheFatalPathReadsArmedThenTearsDownThenRecordsAndRaises() async throws {
        let (mirror, session, status, log) = fatalHarness(armed: false)
        session.lastError = "Input failed."
        await waitUntil("the input error was never raised") { status.errorMessage == "Input failed." }
        XCTAssertEqual(mirror.lastTransportError, "Input failed.")
        XCTAssertTrue(mirror.session === session, "an input error leaves the mirror up")
        log.entries = []

        session.fail("The device went away.")
        await waitUntil("the fatal error never tore the mirror down") { mirror.session == nil }

        XCTAssertEqual(log.entries, ["armed? \(phone.serial)", "teardown \(phone.serial), stash Input failed."])
        XCTAssertEqual(mirror.lastTransportError, "The device went away.")
        XCTAssertEqual(status.errorMessage, "The device went away.")
        XCTAssertEqual(session.stopCount, 1)
        // One more poll interval: nothing runs the fatal path again.
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(log.entries.count, 2, "\(log.entries)")
        XCTAssertEqual(session.stopCount, 1)
    }

    /// While the machine drives a reconnect cycle the failure is recorded
    /// for the waiting panel but stays off the alert.
    func testAnArmedFatalErrorIsRecordedButNotRaised() async {
        let (mirror, session, status, log) = fatalHarness(armed: true)

        session.fail("The device went away.")
        await waitUntil("the fatal error never tore the mirror down") { mirror.session == nil }

        XCTAssertEqual(log.entries, ["armed? \(phone.serial)", "teardown \(phone.serial), stash empty"])
        XCTAssertEqual(mirror.lastTransportError, "The device went away.")
        XCTAssertNil(status.errorMessage)
    }

    /// Item 12, 2026-09-28: a disconnect — `PhysicalMirrorSession`'s EOF
    /// message — is recorded for the waiting panel like any other fatal
    /// error, but never raised as an alert, even with no reconnect cycle
    /// armed. DH shows its own "Currently Unavailable" panel for this and
    /// never alerts; a device going away is not an
    /// error.
    func testADisconnectFatalErrorIsRecordedButNeverRaised() async {
        let (mirror, session, status, log) = fatalHarness(armed: false)

        session.fail("The mirror stream ended unexpectedly (scrcpy server: [server] INFO: Device: [Xiaomi] Redmi 2209116AG (Android 13))")
        await waitUntil("the disconnect never tore the mirror down") { mirror.session == nil }

        XCTAssertEqual(log.entries, ["armed? \(phone.serial)", "teardown \(phone.serial), stash empty"])
        XCTAssertEqual(
            mirror.lastTransportError,
            "The mirror stream ended unexpectedly (scrcpy server: [server] INFO: Device: [Xiaomi] Redmi 2209116AG (Android 13))"
        )
        XCTAssertNil(status.errorMessage, "a device going away is not an error")
    }

    /// A fatal error the poll already raised (as an input error, then
    /// dismissed) is recorded again but not raised a second time.
    func testAFatalErrorAlreadyRaisedIsNotRaisedAgain() async {
        let (mirror, session, status, _) = fatalHarness(armed: false)
        session.lastError = "Link lost."
        await waitUntil("the input error was never raised") { status.errorMessage == "Link lost." }
        status.errorMessage = nil

        session.fail("Link lost.")
        await waitUntil("the fatal error never tore the mirror down") { mirror.session == nil }

        XCTAssertEqual(mirror.lastTransportError, "Link lost.")
        XCTAssertNil(status.errorMessage)
    }

    /// The model's wiring of the fatal path, with the lifecycle running (its
    /// watcher's adb is `/usr/bin/false`, so it reports nothing on its own):
    /// the armed read asks the lifecycle, and a fatal error reaches it after
    /// the teardown. Unarmed, the failure opens a reconnect episode, is
    /// recorded after the lifecycle's own teardown and is raised; during the
    /// episode's resumed attempt the next failure is recorded but stays off
    /// the alert, and the episode goes on to its next attempt.
    func testAFatalErrorReachesTheLifecycleWhichSilencesItsResumedAttempt() async throws {
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        addTeardownBlock { @MainActor in model.inventory.stopDeviceLifecycle() }
        var built: [FakePhysicalSession] = []
        model.workspace.mirror.sessionFactoryOverride = { serial, _ in
            let session = FakePhysicalSession(serial: serial)
            built.append(session)
            return session
        }
        model.inventory.startDeviceLifecycle()
        model.inventory.applyWatcherSnapshot([phone], degraded: false)
        await model.mirror(device: phone)
        let first = try XCTUnwrap(built.first)
        XCTAssertTrue(model.workspace.mirror.session === first)
        XCTAssertNil(model.workspace.reconnect, "a manual start is no reconnect episode")

        // Unarmed: the user's own session fails.
        first.fail("The device went away.")

        await waitUntil("the stats poll never tore the mirror down") { model.workspace.mirror.session == nil }
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(
            model.workspace.reconnect,
            ReconnectStatus(serial: phone.serial, isArmed: true, attempt: 1),
            "noteTransportFatal reached the lifecycle, which armed its first attempt"
        )
        XCTAssertEqual(model.inventory.ghostSerial(for: model.workspace.id), phone.serial)
        XCTAssertEqual(model.workspace.mirror.lastTransportError, "The device went away.", "recorded after the lifecycle's teardown")
        XCTAssertEqual(model.workspace.status.errorMessage, "The device went away.", "no cycle was armed: the alert shows it")
        model.workspace.status.errorMessage = nil

        // Armed: the lifecycle's resume attaches the next session, which
        // fails before it proves healthy (its second clean poll).
        await waitUntil("the lifecycle never resumed the mirror") {
            built.count == 2 && model.workspace.mirror.session === built[1]
                && model.workspace.lifecycleIfRunning?.isAutoReconnectArmed(serial: phone.serial) == true
        }
        let resumed = try XCTUnwrap(built.dropFirst().first)
        resumed.fail("The device went away again.")

        await waitUntil("the stats poll never tore the resumed mirror down") { model.workspace.mirror.session == nil }
        XCTAssertEqual(resumed.stopCount, 1)
        XCTAssertNil(model.workspace.status.errorMessage, "the armed attempt's failure stays off the alert")
        XCTAssertEqual(model.workspace.mirror.lastTransportError, "The device went away again.", "but is recorded for Details")
        XCTAssertEqual(
            model.workspace.reconnect,
            ReconnectStatus(serial: phone.serial, isArmed: true, attempt: 2),
            "the episode goes on to its next attempt"
        )
        XCTAssertEqual(model.inventory.ghostSerial(for: model.workspace.id), phone.serial)
        XCTAssertEqual(model.deviceSelection, .device(phone.serial))
    }

    // MARK: Physical Back

    /// Back goes over the active physical session's control socket, never
    /// through an adb key event; a session that is not the active device's
    /// is not used.
    func testPhysicalBackGoesOverTheControlSocket() async throws {
        let adb = try makeStubAdb(arms: "")
        let context = ActiveDeviceContext()
        let mirror = MirrorController(adbClient: adb.client, context: context, status: StatusCenter(), perfLog: nil)
        let session = FakePhysicalSession(serial: phone.serial)
        mirror.session = session
        context.serial = phone.serial

        await mirror.goBack()

        XCTAssertEqual(session.backPresses, 1)
        XCTAssertTrue(adb.calls(containing: "keyevent").isEmpty, "\(adb.calls)")

        context.serial = "emulator-5554"
        await mirror.goBack()

        XCTAssertEqual(session.backPresses, 1, "another device's session is not the active one")
        XCTAssertEqual(adb.calls(containing: "keyevent 4").count, 1, "\(adb.calls)")
    }
}
