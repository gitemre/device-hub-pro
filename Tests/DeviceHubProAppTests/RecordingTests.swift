import AVFoundation
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// Recording runs on the host (`ScreenRecorder`) from the mirror's frames:
/// no device-side `screenrecord`, no 3-minute cap, and a clip is never
/// discarded when the mirror goes away (F8, F12).
@MainActor
final class RecordingTests: XCTestCase {
    private let phoneA = AndroidDevice.online("HT4CWJT0000A", model: "Pixel A")
    private let phoneB = AndroidDevice.online("HT4CWJT0000B", model: "Pixel B")

    /// The fake sessions by serial, and the clips handed to the save flow.
    private final class Harness {
        var sessions: [String: FakeMirrorSession] = [:]
        var saved: [(url: URL, name: String)] = []
    }

    private func makeModel() -> (AppModel, Harness) {
        let harness = Harness()
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        model.workspace.mirror.sessionFactoryOverride = { serial, _ in
            let session = FakeMirrorSession()
            harness.sessions[serial] = session
            return session
        }
        model.recordingFinalizer.recordingSaveOverride = { url, name in
            harness.saved.append((url, name))
        }
        addTeardownBlock { @MainActor in
            for clip in harness.saved {
                try? FileManager.default.removeItem(at: clip.url.deletingLastPathComponent())
            }
        }
        model.inventory.applyWatcherSnapshot([phoneA, phoneB], degraded: false)
        return (model, harness)
    }

    /// New frames over `duration`, one every 40 ms (the recorder paces at
    /// 30 fps).
    private func feed(_ session: FakeMirrorSession?, count: Int = 12) async throws {
        let session = try XCTUnwrap(session)
        for index in 0..<count {
            session.putFrame(width: 128, height: 256, shade: UInt8((index * 20) % 256))
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    private func assertPlayableClip(_ url: URL?, file: StaticString = #filePath, line: UInt = #line) async throws {
        let url = try XCTUnwrap(url, "no clip was handed on", file: file, line: line)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        XCTAssertGreaterThan(size?.intValue ?? 0, 0, file: file, line: line)
        let duration = try await AVURLAsset(url: url).load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.2, "the clip holds the recorded frames", file: file, line: line)
    }

    func testStopRecordingHandsTheClipToTheSaveFlow() async throws {
        let (model, harness) = makeModel()
        await model.mirror(device: phoneA)

        await model.workspace.media.toggleRecording()
        XCTAssertTrue(model.workspace.media.isRecording)
        try await feed(harness.sessions[phoneA.serial])
        await model.workspace.media.toggleRecording()

        XCTAssertFalse(model.workspace.media.isRecording, "the REC indicator ends with the recorder")
        XCTAssertEqual(model.workspace.media.recordingElapsedText, "")
        await waitUntil("the clip never reached the save flow") { !harness.saved.isEmpty }
        XCTAssertTrue(harness.saved[0].name.hasPrefix("Pixel-A-"), harness.saved[0].name)
        try await assertPlayableClip(harness.saved.first?.url)
        XCTAssertNil(model.status.errorMessage)
    }

    /// Switching devices mid-recording used to delete the clip on the device
    /// without a word; now it is finalized and handed to the save flow.
    func testDeviceSwitchSavesTheRecording() async throws {
        let (model, harness) = makeModel()
        await model.mirror(device: phoneA)
        await model.workspace.media.toggleRecording()
        try await feed(harness.sessions[phoneA.serial])

        await model.mirror(device: phoneB)

        XCTAssertEqual(model.activeDeviceSerial, phoneB.serial)
        XCTAssertFalse(model.workspace.media.isRecording, "device B is not being recorded")
        await waitUntil("the switch discarded the clip") { !harness.saved.isEmpty }
        XCTAssertTrue(harness.saved[0].name.hasPrefix("Pixel-A-"), harness.saved[0].name)
        try await assertPlayableClip(harness.saved.first?.url)
    }

    /// A disconnect ends the recording without the user: what was recorded
    /// is saved next to the save panel's default and the alert says where.
    func testDisconnectSavesWhatWasRecordedAndSaysSo() async throws {
        let (model, harness) = makeModel()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingAutoSave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        model.recordingFinalizer.recordingAutoSaveDirectory = directory
        await model.mirror(device: phoneA)
        await model.workspace.media.toggleRecording()
        try await feed(harness.sessions[phoneA.serial])

        model.tearDownMirror(cause: .disconnected)

        await waitUntil("the interrupted clip was not reported") {
            model.status.errorMessage?.contains("disconnected") == true
        }
        let clips = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(clips.count, 1)
        XCTAssertTrue(model.status.errorMessage?.contains(directory.path) == true, model.status.errorMessage ?? "")
        XCTAssertTrue(harness.saved.isEmpty, "no save panel for a recording the user did not stop")
        try await assertPlayableClip(clips.first)
    }

    /// Without a directory of the model's own, an interrupted clip goes to
    /// the environment picker's auto-save directory (the Desktop only for
    /// the app's save panel): a test model never writes the user's Desktop.
    func testAnInterruptedClipGoesToThePickersAutoSaveDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PickerAutoSave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let environment = AppEnvironment.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        let picker = try XCTUnwrap(environment.picker as? TestPicker)
        XCTAssertNil(picker.autoSaveDirectory, "a test picker saves nowhere unless told")
        picker.autoSaveDirectory = directory
        let model = AppModel(environment: environment)
        let session = FakeMirrorSession()
        model.workspace.mirror.sessionFactoryOverride = { _, _ in session }
        model.inventory.applyWatcherSnapshot([phoneA], degraded: false)
        XCTAssertNil(model.recordingFinalizer.recordingAutoSaveDirectory)
        await model.mirror(device: phoneA)
        await model.workspace.media.toggleRecording()
        try await feed(session)

        model.tearDownMirror(cause: .disconnected)

        await waitUntil("the interrupted clip was not reported") {
            model.status.errorMessage?.contains("disconnected") == true
        }
        let clips = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(clips.count, 1)
        try await assertPlayableClip(clips.first)
    }

    /// The recorder is fed even with the replay ring switched off.
    func testRecordingWorksWithReplayOff() async throws {
        let (model, harness) = makeModel()
        model.workspace.media.setReplayEnabled(false)
        await model.mirror(device: phoneA)

        await model.workspace.media.toggleRecording()
        try await feed(harness.sessions[phoneA.serial])
        await model.workspace.media.toggleRecording()

        await waitUntil("no clip without the replay ring") { !harness.saved.isEmpty }
        try await assertPlayableClip(harness.saved.first?.url)
    }

    /// Turning replay off mid-recording frees the ring at once, but the
    /// feed keeps running for the recorder: its frames still reach the
    /// clip, and no ring is rebuilt from them.
    func testTurningReplayOffMidRecordingFreesTheRingAndKeepsRecording() async throws {
        let (model, harness) = makeModel()
        await model.mirror(device: phoneA)
        let session = try XCTUnwrap(harness.sessions[phoneA.serial])
        await model.workspace.media.toggleRecording()
        try await feed(session, count: 6)
        await waitUntil("the replay ring never filled") { model.workspace.media.canSaveReplay }
        let recorder = try XCTUnwrap(model.workspace.media.screenRecorder)
        let encoded = recorder.encodedFrameCount

        model.workspace.media.setReplayEnabled(false)

        XCTAssertNil(model.workspace.media.replayBuffer, "turning replay off frees the ring")
        XCTAssertFalse(model.workspace.media.canSaveReplay)
        XCTAssertTrue(model.workspace.media.isRecording)
        try await feed(session, count: 8)
        // At most the frame staged before the switch can still be encoding;
        // the rest come from the feed that kept running.
        await waitUntil("the recorder stopped receiving frames") {
            recorder.encodedFrameCount >= encoded + 5
        }
        XCTAssertNil(model.workspace.media.replayBuffer, "no ring is rebuilt while replay is off")

        await model.workspace.media.toggleRecording()
        await waitUntil("the clip never reached the save flow") { !harness.saved.isEmpty }
        try await assertPlayableClip(harness.saved.first?.url)
    }

    /// A recording the user stopped just before quitting is still being
    /// finalized when quit tears the mirror down: quit waits for that clip
    /// too, not only for one its own teardown ends.
    func testQuitWaitsForARecordingStoppedBeforeIt() async throws {
        let (model, harness) = makeModel()
        await model.mirror(device: phoneA)
        await model.workspace.media.toggleRecording()
        try await feed(harness.sessions[phoneA.serial])
        await model.workspace.media.toggleRecording()
        XCTAssertFalse(model.workspace.media.isRecording)
        XCTAssertEqual(model.recordingFinalizer.recordingFinishTasks.count, 1, "the stopped clip is being finalized")
        XCTAssertTrue(harness.saved.isEmpty)

        await model.prepareForTermination(timeout: .seconds(5))

        XCTAssertEqual(harness.saved.count, 1, "quit returned before the stopped clip was handed on")
        XCTAssertTrue(model.recordingFinalizer.recordingFinishTasks.isEmpty)
        try await assertPlayableClip(harness.saved.first?.url)
    }

    /// A recording that never saw a frame says so instead of failing
    /// silently.
    func testRecordingWithoutFramesSaysSo() async {
        let (model, harness) = makeModel()
        await model.mirror(device: phoneA)

        await model.workspace.media.toggleRecording()
        await model.workspace.media.toggleRecording()

        await waitUntil("the empty recording was not reported") { model.status.errorMessage != nil }
        XCTAssertEqual(model.status.errorMessage, "Nothing was recorded: the mirror showed no frames.")
        XCTAssertTrue(harness.saved.isEmpty)
    }
}
