import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// Where a finished recording goes, and what its alert says.
final class RecordingDispositionTests: XCTestCase {
    private struct DiskFull: Error, CustomStringConvertible {
        var description: String { "disk full" }
    }

    private let clip = URL(fileURLWithPath: "/tmp/devicehubpro-recordings/ABC/Pixel_9-20260925-101500.mp4")
    private let saved = URL(fileURLWithPath: "/Users/me/Desktop/Pixel_9-20260925-101500.mp4")

    private func decide(_ end: MediaCaptureController.RecordingEnd, _ finalized: Result<URL, any Error>) -> RecordingDisposition {
        RecordingDisposition.decide(end: end, deviceName: "Pixel 9", finalized: finalized)
    }

    // MARK: - The table

    func testAFinishedClipGoesWhereTheEndSays() {
        XCTAssertEqual(
            decide(.user, .success(clip)),
            .askWhereToSave(clip: clip, suggestedName: "Pixel_9-20260925-101500.mp4")
        )
        XCTAssertEqual(
            decide(.interrupted("Pixel 9 disconnected"), .success(clip)),
            .autoSave(clip: clip, report: .interrupted(deviceName: "Pixel 9", reason: "Pixel 9 disconnected"))
        )
        XCTAssertEqual(
            decide(.failed(.writerFailed("no space")), .success(clip)),
            .autoSave(clip: clip, report: .failed(deviceName: "Pixel 9", failure: .writerFailed("no space")))
        )
        XCTAssertEqual(decide(.quit, .success(clip)), .autoSave(clip: clip, report: nil), "a quit saves silently")
    }

    /// A recording cancelled while it finished was thrown away on purpose:
    /// no "Could not save the recording: CancellationError()" alert.
    func testACancelledRecordingSavesNothingSilently() {
        XCTAssertEqual(decide(.user, .failure(CancellationError())), .nothingSaved(alert: nil))
    }

    func testAnEmptyRecordingSaysNothingWasRecorded() {
        let alert = RecordingDisposition.nothingSaved(alert: "Nothing was recorded: the mirror showed no frames.")
        XCTAssertEqual(decide(.user, .failure(ScreenRecorderError.noFrames)), alert)
        XCTAssertEqual(decide(.interrupted("gone"), .failure(ScreenRecorderError.noFrames)), alert)
        XCTAssertEqual(decide(.failed(.encoderTimeout), .failure(ScreenRecorderError.noFrames)), alert)
        XCTAssertEqual(decide(.quit, .failure(ScreenRecorderError.noFrames)), .nothingSaved(alert: nil))
    }

    func testAFinalizeErrorIsReportedExceptOnQuit() {
        XCTAssertEqual(
            decide(.user, .failure(DiskFull())),
            .nothingSaved(alert: "Could not save the recording: disk full")
        )
        XCTAssertEqual(
            decide(.interrupted("gone"), .failure(DiskFull())),
            .nothingSaved(alert: "Could not save the recording: disk full")
        )
        XCTAssertEqual(
            decide(.failed(.encoderTimeout), .failure(ScreenRecorderError.alreadyFinished)),
            .nothingSaved(alert: "Could not save the recording: \(ScreenRecorderError.alreadyFinished)")
        )
        XCTAssertEqual(decide(.quit, .failure(DiskFull())), .nothingSaved(alert: nil))
    }

    // MARK: - Auto-save alerts

    func testAnInterruptedRecordingSaysWhereTheClipWent() {
        let report = RecordingDisposition.AutoSaveReport.interrupted(deviceName: "Pixel 9", reason: "Pixel 9 disconnected")
        XCTAssertEqual(
            report.message(savedTo: saved, clip: clip),
            "Recording of Pixel 9 stopped: Pixel 9 disconnected. The clip was saved to \(saved.path)."
        )
        XCTAssertEqual(
            report.message(savedTo: nil, clip: clip),
            "Recording of Pixel 9 stopped: Pixel 9 disconnected. The clip is kept at \(clip.path)."
        )
    }

    func testAFailedRecordingSaysWhereWhatWasRecordedWent() {
        let failure = ScreenRecorderError.writerFailed("no space")
        let report = RecordingDisposition.AutoSaveReport.failed(deviceName: "Pixel 9", failure: failure)
        XCTAssertEqual(
            report.message(savedTo: saved, clip: clip),
            "Recording of Pixel 9 stopped: \(failure). What was recorded was saved to \(saved.path)."
        )
        XCTAssertEqual(
            report.message(savedTo: nil, clip: clip),
            "Recording of Pixel 9 stopped: \(failure). What was recorded is kept at \(clip.path)."
        )
    }
}
