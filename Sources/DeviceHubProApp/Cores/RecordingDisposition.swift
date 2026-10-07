import Foundation
import DeviceHubProKit

/// What happens to a finished recording's clip, decided from why the
/// recording ended and what `ScreenRecorder.finalize` returned. Nothing is
/// ever deleted silently: a clip that cannot be written says why, except
/// while the app quits.
///
/// `RecordingFinalizer` performs the disposition (the save panel or its test
/// override, the auto-save move through `AutoSaveNamer`, the alert).
enum RecordingDisposition: Equatable, Sendable {
    /// Nothing was written. `alert`, when non-nil, tells the user why; a
    /// quit stays silent.
    case nothingSaved(alert: String?)
    /// The user stopped it, switched devices or stopped the mirror: ask
    /// where the clip goes, suggesting its file name.
    case askWhereToSave(clip: URL, suggestedName: String)
    /// Move the clip to the auto-save directory without asking. `report`,
    /// when non-nil, is the alert raised once the move's outcome is known; a
    /// quit stays silent.
    case autoSave(clip: URL, report: AutoSaveReport?)

    /// The alert after an interrupted or failed recording was auto-saved.
    enum AutoSaveReport: Equatable, Sendable {
        /// The device disconnected or its stream failed.
        case interrupted(deviceName: String, reason: String)
        /// The recorder itself failed (disk full, encoder gone).
        case failed(deviceName: String, failure: ScreenRecorderError)

        /// The alert text: where the clip was saved, or where it is kept
        /// (`clip`) when it could not be moved.
        func message(savedTo saved: URL?, clip url: URL) -> String {
            switch self {
            case .interrupted(let deviceName, let reason):
                return "Recording of \(deviceName) stopped: \(reason). "
                    + (saved.map { "The clip was saved to \($0.path)." } ?? "The clip is kept at \(url.path).")
            case .failed(let deviceName, let failure):
                return "Recording of \(deviceName) stopped: \(failure). "
                    + (saved.map { "What was recorded was saved to \($0.path)." } ?? "What was recorded is kept at \(url.path).")
            }
        }
    }

    /// The disposition of a recording of `deviceName` that ended for `end`
    /// and finalized to `finalized`.
    static func decide(
        end: MediaCaptureController.RecordingEnd,
        deviceName: String,
        finalized: Result<URL, any Error>
    ) -> RecordingDisposition {
        let url: URL
        switch finalized {
        case .success(let finished):
            url = finished
        case .failure(let error):
            guard end != .quit else { return .nothingSaved(alert: nil) }
            // A recording thrown away on purpose: nothing to tell.
            if error is CancellationError { return .nothingSaved(alert: nil) }
            if case ScreenRecorderError.noFrames? = error as? ScreenRecorderError {
                return .nothingSaved(alert: "Nothing was recorded: the mirror showed no frames.")
            }
            return .nothingSaved(alert: "Could not save the recording: \(error)")
        }
        switch end {
        case .user:
            return .askWhereToSave(clip: url, suggestedName: url.lastPathComponent)
        case .interrupted(let reason):
            return .autoSave(clip: url, report: .interrupted(deviceName: deviceName, reason: reason))
        case .failed(let failure):
            return .autoSave(clip: url, report: .failed(deviceName: deviceName, failure: failure))
        case .quit:
            return .autoSave(clip: url, report: nil)
        }
    }
}
