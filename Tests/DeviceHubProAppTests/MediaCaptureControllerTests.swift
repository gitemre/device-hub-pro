import Foundation
import Observation
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The media controller on its own, without an `AppModel`: the frame feed
/// across attach and detach, the recorder's cut-off, the replay switch
/// during a recording, and where saved clips go through the picker.
///
/// Real encoders over `FakeMirrorSession` frames; nothing reaches a device,
/// a save panel or the Desktop.
@MainActor
final class MediaCaptureControllerTests: XCTestCase {
    private struct Rig {
        let media: MediaCaptureController
        let finalizer: RecordingFinalizer
        let picker: TestPicker
        let status: StatusCenter
        let session: FakeMirrorSession
    }

    /// Whatever a test's closures collect.
    @MainActor
    private final class Box<Value> {
        var value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    /// A controller on scratch settings (replay on) for a mirrored
    /// "Pixel A", with a picker that cancels until the test says otherwise
    /// and auto-saves into a scratch directory, never the Desktop.
    private func makeRig() throws -> Rig {
        let status = StatusCenter()
        let picker = TestPicker()
        let context = ActiveDeviceContext()
        context.serial = "HT4CWJT0000A"
        let finalizer = RecordingFinalizer(status: status, picker: picker)
        finalizer.recordingAutoSaveDirectory = try scratchDirectory()
        let media = MediaCaptureController(
            preferences: AppPreferences(defaults: .scratch()),
            status: status,
            context: context,
            finalizer: finalizer,
            picker: picker
        )
        media.displayName = { _ in "Pixel A" }
        addTeardownBlock { @MainActor in
            media.endRecording(.user)
            media.detach()
            await finalizer.waitForRecordingsToFinish()
        }
        return Rig(media: media, finalizer: finalizer, picker: picker, status: status, session: FakeMirrorSession())
    }

    /// New frames, one every 40 ms (the recorder paces at 30 fps).
    private func feed(_ session: FakeMirrorSession, count: Int) async throws {
        for index in 0..<count {
            session.putFrame(width: 128, height: 256, shade: UInt8((index * 20) % 256))
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    /// A scratch directory, removed after the test.
    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaCaptureControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    // MARK: - Finishing

    /// Quit waits for every clip still being finalized, including one whose
    /// recording the user ended before the quit's own teardown ran.
    func testWaitingForRecordingsIncludesOneEndedBeforeTheTeardown() async throws {
        let rig = try makeRig()
        let saved = Box<[URL]>([])
        rig.finalizer.recordingSaveOverride = { url, _ in saved.value.append(url) }
        addTeardownBlock { @MainActor in
            for clip in saved.value {
                try? FileManager.default.removeItem(at: clip.deletingLastPathComponent())
            }
        }
        rig.media.attach(frames: rig.session.frames)
        await rig.media.toggleRecording()
        try await feed(rig.session, count: 10)

        await rig.media.toggleRecording()
        XCTAssertEqual(rig.finalizer.recordingFinishTasks.count, 1)
        XCTAssertTrue(saved.value.isEmpty, "the clip is still being finalized")
        // The quit's teardown: nothing records any more.
        rig.media.endRecording(.quit)
        rig.media.detach()
        await rig.finalizer.waitForRecordingsToFinish()

        XCTAssertEqual(saved.value.count, 1, "the wait returned before the earlier clip was handed on")
        XCTAssertTrue(rig.finalizer.recordingFinishTasks.isEmpty)
        XCTAssertNil(rig.status.errorMessage)
    }

    /// An interrupted clip with no auto-save directory — none of the
    /// app's own, none from the picker (a test's) — is moved nowhere: it
    /// stays in its temporary directory and the alert says so. The move is
    /// the finalizer's seam, which only records and refuses here, so a
    /// fallback that came back (the Desktop, once) fails this test without
    /// a clip ever landing there.
    func testAnInterruptedClipWithNoAutoSaveDirectoryStaysWhereItIs() async throws {
        let rig = try makeRig()
        rig.finalizer.recordingAutoSaveDirectory = nil
        XCTAssertNil(rig.picker.autoSaveDirectory)
        let attempted = Box<[URL]>([])
        rig.finalizer.moveAutoSavedClip = { _, destination in
            attempted.value.append(destination)
            throw CocoaError(.fileWriteNoPermission)
        }
        rig.media.attach(frames: rig.session.frames)
        await rig.media.toggleRecording()
        try await feed(rig.session, count: 10)

        rig.media.endRecording(.interrupted("the device disconnected"))
        await rig.finalizer.waitForRecordingsToFinish()

        XCTAssertEqual(attempted.value, [], "an interrupted clip was sent to a directory nobody named")
        let message = try XCTUnwrap(rig.status.errorMessage)
        let marker = "The clip is kept at "
        let keptAt = try XCTUnwrap(message.range(of: marker).map { String(message[$0.upperBound...].dropLast()) }, message)
        let clip = URL(fileURLWithPath: keptAt)
        addTeardownBlock { try? FileManager.default.removeItem(at: clip.deletingLastPathComponent()) }
        XCTAssertTrue(message.hasSuffix("\(marker)\(clip.path)."), message)
        XCTAssertTrue(clip.path.hasPrefix(FileManager.default.temporaryDirectory.path), clip.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clip.path), "the clip must stay where it was recorded")
    }

    // MARK: - Frame feed

    /// Once `endRecording` returns, the recorder is out of the feed's reach:
    /// with replay off it was the only consumer, so the feed stages nothing
    /// more, however many new frames arrive.
    func testTheRecorderIsHandedNoFrameAfterEndRecordingReturns() async throws {
        let rig = try makeRig()
        rig.finalizer.recordingSaveOverride = { url, _ in
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        rig.media.setReplayEnabled(false)
        rig.media.attach(frames: rig.session.frames)
        await rig.media.toggleRecording()
        let recorder = try XCTUnwrap(rig.media.screenRecorder)
        try await feed(rig.session, count: 6)
        await waitUntil("the recorder never received a frame") { recorder.encodedFrameCount > 0 }

        rig.media.endRecording(.user)

        XCTAssertNil(rig.media.screenRecorder)
        XCTAssertFalse(rig.media.isRecording)
        XCTAssertNil(rig.media.recordingTimerTask)
        let lastFed = rig.media.admission.lastGeneration
        XCTAssertNotNil(lastFed)
        try await feed(rig.session, count: 6)
        XCTAssertEqual(rig.media.admission.lastGeneration, lastFed, "a frame was staged after the recording ended")
        await waitUntil("a staged conversion never finished") { rig.media.admission.pending == 0 }
        await rig.finalizer.waitForRecordingsToFinish()
    }

    /// The pending-conversion count spans feed runs: a conversion staged
    /// before a detach still counts after the next attach, and its
    /// completion takes it back down.
    func testAttachAndDetachNeverResetThePendingCount() async throws {
        let rig = try makeRig()
        rig.session.putFrame(shade: 10)
        let next = FakeMirrorSession()
        let seen = Box<(before: Int, after: Int)?>(nil)
        // The first change to `admission` is the first tick's frame being
        // admitted. The block queued from there runs right after that tick,
        // ahead of the conversion's completion, which is queued on the main
        // actor only once the conversion ran.
        withObservationTracking {
            _ = rig.media.admission
        } onChange: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let before = rig.media.admission.pending
                    rig.media.detach()
                    rig.media.attach(frames: next.frames)
                    seen.value = (before, rig.media.admission.pending)
                }
            }
        }

        rig.media.attach(frames: rig.session.frames)
        await waitUntil("the first frame was never staged") { seen.value != nil }

        XCTAssertEqual(seen.value?.before, 1, "the first frame's conversion is pending")
        XCTAssertEqual(seen.value?.after, 1, "detach and attach keep counting it")
        await waitUntil("the earlier run's conversion never finished") { rig.media.admission.pending == 0 }
    }

    /// Turning replay off during a recording frees the ring at once, but
    /// the feed keeps running for the recorder and builds no new ring.
    func testTurningReplayOffFreesTheRingWhileARecordingKeepsTheFeedAlive() async throws {
        let rig = try makeRig()
        rig.finalizer.recordingSaveOverride = { url, _ in
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        rig.media.attach(frames: rig.session.frames)
        await rig.media.toggleRecording()
        let recorder = try XCTUnwrap(rig.media.screenRecorder)
        try await feed(rig.session, count: 6)
        await waitUntil("the replay ring never filled") { rig.media.canSaveReplay }
        let encoded = recorder.encodedFrameCount

        rig.media.setReplayEnabled(false)

        XCTAssertNil(rig.media.replayBuffer, "turning replay off frees the ring")
        XCTAssertFalse(rig.media.canSaveReplay)
        try await feed(rig.session, count: 8)
        await waitUntil("the feed stopped with the ring") {
            rig.media.admission.lastGeneration == rig.session.frames.current?.generation
        }
        // At most the frame staged before the switch can still be encoding.
        await waitUntil("the recorder stopped receiving frames") { recorder.encodedFrameCount >= encoded + 5 }
        XCTAssertNil(rig.media.replayBuffer, "no ring is rebuilt while replay is off")

        rig.media.endRecording(.user)
        await rig.finalizer.waitForRecordingsToFinish()
    }

    // MARK: - Where clips go

    /// A saved replay goes straight to the capture folder (here the picker's
    /// auto-save directory), without asking, and leaves no temporary clip.
    func testTheReplayClipIsSavedWithoutAskingIntoTheCaptureFolder() async throws {
        let rig = try makeRig()
        let folder = try scratchDirectory()
        rig.picker.autoSaveDirectory = folder
        rig.media.attach(frames: rig.session.frames)
        try await feed(rig.session, count: 12)
        await waitUntil("the ring never retained a clip") { (rig.media.replayBuffer?.retainedSeconds ?? 0) > 0 }

        await rig.media.saveReplay()

        XCTAssertTrue(rig.picker.suggestedNames.isEmpty, "the save panel is not shown")
        let saved = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".mp4") }
        XCTAssertEqual(saved.count, 1, "one clip in the capture folder")
        XCTAssertNil(rig.status.errorMessage)
    }

    /// A second clip with the same name does not overwrite the first.
    func testAReplayNameThatIsTakenGetsANumber() throws {
        let folder = try scratchDirectory()
        let first = folder.appendingPathComponent("Replay.mp4")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        XCTAssertEqual(MediaCaptureController.uniqueURL(in: folder, name: "Replay.mp4").lastPathComponent, "Replay 2.mp4")
    }

    /// A stopped recording is saved without asking, like a screenshot or a
    /// replay, under its suggested name in the capture folder; the save
    /// panel is shown only when no folder can take it.
    func testAStoppedRecordingIsSavedWithoutAsking() async throws {
        let rig = try makeRig()
        let folder = try XCTUnwrap(rig.finalizer.recordingAutoSaveDirectory)
        rig.media.attach(frames: rig.session.frames)

        await rig.media.toggleRecording()
        let clip = try XCTUnwrap(rig.media.screenRecorder?.outputURL)
        try await feed(rig.session, count: 10)
        await rig.media.toggleRecording()
        await rig.finalizer.waitForRecordingsToFinish()

        XCTAssertTrue(rig.picker.suggestedNames.isEmpty, "the save panel is not shown")
        XCTAssertTrue(clip.lastPathComponent.hasPrefix("Pixel-A-"), clip.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(clip.lastPathComponent).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.deletingLastPathComponent().path))
        XCTAssertEqual(rig.status.statusMessage, "Recording saved to \(folder.lastPathComponent)")
        XCTAssertNil(rig.status.errorMessage)
    }

    /// With no folder to save into, the stopped recording asks the picker: a
    /// cancel deletes the clip with its temporary directory.
    func testWithoutAFolderAStoppedRecordingAsks() async throws {
        let rig = try makeRig()
        rig.finalizer.recordingAutoSaveDirectory = nil
        rig.media.attach(frames: rig.session.frames)

        await rig.media.toggleRecording()
        let cancelled = try XCTUnwrap(rig.media.screenRecorder?.outputURL)
        try await feed(rig.session, count: 10)
        await rig.media.toggleRecording()
        await rig.finalizer.waitForRecordingsToFinish()

        XCTAssertEqual(rig.picker.suggestedNames, [cancelled.lastPathComponent])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cancelled.deletingLastPathComponent().path),
            "a cancelled clip is deleted with its directory"
        )
    }

    /// Records a short clip and ends it for `end`, waiting for the finalizer.
    private func recordAndEnd(_ rig: Rig, _ end: MediaCaptureController.RecordingEnd) async throws -> URL {
        rig.media.attach(frames: rig.session.frames)
        await rig.media.toggleRecording()
        let clip = try XCTUnwrap(rig.media.screenRecorder?.outputURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: clip.deletingLastPathComponent()) }
        try await feed(rig.session, count: 10)
        if case .user = end {
            await rig.media.toggleRecording()
        } else {
            rig.media.endRecording(end)
        }
        await rig.finalizer.waitForRecordingsToFinish()
        return clip
    }

    /// The auto-save move throws for a stopped recording: the save panel is
    /// asked next and the clip goes where the picker says.
    func testAStoppedRecordingWhoseAutoSaveMoveFailsFallsBackToThePicker() async throws {
        let rig = try makeRig()
        rig.finalizer.moveAutoSavedClip = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        let target = try scratchDirectory().appendingPathComponent("chosen.mp4")
        rig.picker.destination = target
        let saved = Box<[URL]>([])
        rig.media.onRecordingSaved = { saved.value.append($0) }

        let clip = try await recordAndEnd(rig, .user)

        XCTAssertEqual(rig.picker.suggestedNames, [clip.lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "the clip went to the picker's choice")
        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.path))
        XCTAssertEqual(saved.value, [target])
    }

    /// With no auto-save directory the picker is asked, and its answer gets the clip.
    func testAStoppedRecordingWithNoFolderGoesWhereThePickerSays() async throws {
        let rig = try makeRig()
        rig.finalizer.recordingAutoSaveDirectory = nil
        let target = try scratchDirectory().appendingPathComponent("picked.mp4")
        rig.picker.destination = target

        let clip = try await recordAndEnd(rig, .user)

        XCTAssertEqual(rig.picker.suggestedNames, [clip.lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertNil(rig.status.errorMessage)
    }

    /// The panel's own save fails (a destination folder that does not exist):
    /// the alert says where the clip is kept.
    func testAFailedPanelSaveSaysWhereTheClipIsKept() async throws {
        let rig = try makeRig()
        rig.finalizer.recordingAutoSaveDirectory = nil
        let missing = try scratchDirectory().appendingPathComponent("no-such-folder/clip.mp4")
        rig.picker.destination = missing
        let saved = Box<[URL]>([])
        rig.media.onRecordingSaved = { saved.value.append($0) }

        let clip = try await recordAndEnd(rig, .user)

        let message = try XCTUnwrap(rig.status.errorMessage)
        XCTAssertTrue(message.contains("kept at \(clip.path)"), message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clip.path))
        XCTAssertTrue(saved.value.isEmpty)
    }

    /// An interrupted recording whose auto-save move fails: the alert says
    /// the clip is kept at its path and `saved` is never called.
    func testAnInterruptedClipWhoseMoveFailsIsKeptAndNeverReportedSaved() async throws {
        let rig = try makeRig()
        let attempted = Box<Int>(0)
        rig.finalizer.moveAutoSavedClip = { _, _ in
            attempted.value += 1
            throw CocoaError(.fileWriteNoPermission)
        }
        let saved = Box<[URL]>([])
        rig.media.onRecordingSaved = { saved.value.append($0) }

        let clip = try await recordAndEnd(rig, .interrupted("the device disconnected"))

        XCTAssertEqual(attempted.value, 1)
        let message = try XCTUnwrap(rig.status.errorMessage)
        XCTAssertTrue(message.contains("The clip is kept at \(clip.path)."), message)
        XCTAssertTrue(saved.value.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clip.path))
    }

    // MARK: - Recording guards

    func testALowDiskWarnsBelowAboutOneGigabyte() {
        XCTAssertNil(MediaCaptureController.lowDiskWarning(availableBytes: nil))
        XCTAssertNil(MediaCaptureController.lowDiskWarning(availableBytes: 5_000_000_000))
        XCTAssertNil(MediaCaptureController.lowDiskWarning(availableBytes: MediaCaptureController.lowDiskBytes))
        XCTAssertEqual(
            MediaCaptureController.lowDiskWarning(availableBytes: 400_000_000),
            "Only 0.4 GB is free on this Mac. The recording stops if the disk fills up."
        )
    }

    func testAFrameSizeChangeIsDetected() {
        XCTAssertFalse(MediaCaptureController.recordingSizeChanged(from: (1080, 2400), to: (1080, 2400)))
        XCTAssertTrue(MediaCaptureController.recordingSizeChanged(from: (1080, 2400), to: (2400, 1080)))
    }
}
