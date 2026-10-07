import CoreMedia
import Foundation
import Observation
import DeviceHubProKit

/// Finishes the recordings that ended: finalizes each clip in the
/// background and hands it on according to why its recording ended (see
/// `MediaCaptureController.RecordingEnd`).
///
/// App-scoped, owned by `AppModel` as `recordingFinalizer`: a clip outlives
/// the session it recorded, and quit waits for every recording still being
/// finalized (`waitForRecordingsToFinish()`).
@MainActor
@Observable
final class RecordingFinalizer {
    typealias RecordingEnd = MediaCaptureController.RecordingEnd

    private let status: StatusCenter
    /// Asks where a clip the user stopped goes (the save panel in the app).
    private let picker: any FileDestinationPicker

    /// Recordings still being finalized after they stopped, by id; quit
    /// waits for them so no clip is cut off mid-write.
    @ObservationIgnored private(set) var recordingFinishTasks: [UUID: Task<Void, Never>] = [:]
    /// Test seam: receives a finished clip (temporary file, suggested name)
    /// instead of the save panel (`picker`).
    @ObservationIgnored var recordingSaveOverride: ((URL, String) -> Void)?
    /// Where a clip whose recording ended without the user (disconnect,
    /// fatal stream error, quit) is saved; nil = the picker's
    /// `autoSaveDirectory` (the Desktop in the app, the save panel's
    /// default; none for a test's picker, so the clip stays put).
    @ObservationIgnored var recordingAutoSaveDirectory: URL?
    /// Moves an auto-saved clip to its destination. Test seam: a test sees
    /// where a clip would go without letting it go anywhere.
    @ObservationIgnored var moveAutoSavedClip: @MainActor (_ clip: URL, _ destination: URL) throws -> Void = {
        try FileManager.default.moveItem(at: $0, to: $1)
    }

    /// The folder the user chose in Settings for captures; nil = the default
    /// (the picker's `autoSaveDirectory`, the Desktop in the app).
    @ObservationIgnored var preferredDirectory: @MainActor () -> URL? = { nil }

    init(status: StatusCenter, picker: any FileDestinationPicker) {
        self.status = status
        self.picker = picker
    }

    /// Finalizes `recorder`'s clip in the background, ending it at
    /// `endTime`, and hands it on according to `end`.
    func finish(
        _ recorder: ScreenRecorder,
        endingAt endTime: CMTime,
        deviceName: String,
        end: RecordingEnd,
        saved: (@MainActor (URL) -> Void)? = nil
    ) {
        schedule(deviceName: deviceName, end: end, saved: saved) {
            try await recorder.finalize(endingAt: endTime)
        }
    }

    /// Stops a view-only simulator's `simctl io recordVideo` (SIGINT) in
    /// the background and hands its movie on according to `end`, as a
    /// recorder's clip.
    func finish(
        _ recording: SimulatorVideoRecording,
        deviceName: String,
        end: RecordingEnd,
        saved: (@MainActor (URL) -> Void)? = nil
    ) {
        schedule(deviceName: deviceName, end: end, saved: saved) {
            try await recording.finish()
        }
    }

    private func schedule(
        deviceName: String,
        end: RecordingEnd,
        saved: (@MainActor (URL) -> Void)?,
        finalize: @escaping @MainActor () async throws -> URL
    ) {
        let id = UUID()
        recordingFinishTasks[id] = Task { [weak self] in
            await self?.finishRecording(deviceName: deviceName, end: end, saved: saved, finalize: finalize)
            self?.recordingFinishTasks[id] = nil
        }
    }

    private func finishRecording(
        deviceName: String,
        end: RecordingEnd,
        saved: (@MainActor (URL) -> Void)?,
        finalize: @MainActor () async throws -> URL
    ) async {
        let finalized: Result<URL, any Error>
        do {
            finalized = .success(try await finalize())
        } catch {
            finalized = .failure(error)
        }
        switch RecordingDisposition.decide(end: end, deviceName: deviceName, finalized: finalized) {
        case .nothingSaved(let alert):
            if let alert {
                status.errorMessage = alert
            }
        case .askWhereToSave(let url, let suggestedName):
            if let recordingSaveOverride {
                recordingSaveOverride(url, suggestedName)
            } else {
                // The clip under its suggested name; every fallback below
                // uses that path, since the rename moved the file.
                let clip = renamedClip(url, suggestedName: suggestedName)
                if let destination = saveStoppedRecording(clip) {
                    // Like a screenshot or a replay: saved without asking, into
                    // the capture folder; the banner reveals it with one click.
                    status.flash("Recording saved to \(destination.deletingLastPathComponent().lastPathComponent)")
                    saved?(destination)
                } else if let destination = saveRecordingWithPanel(tempURL: clip, suggestedName: suggestedName) {
                    // No capture folder could take it: ask instead.
                    saved?(destination)
                }
            }
        case .autoSave(let url, let report):
            let destination = autoSaveRecording(url)
            if let report {
                status.errorMessage = report.message(savedTo: destination, clip: url)
            } else if let destination {
                saved?(destination)
            } else {
                // Nowhere to save it, or the move failed: say where it is.
                status.errorMessage = "The recording could not be saved to a folder. It is kept at \(url.path)"
            }
        }
    }

    /// Moves a clip to the auto-save directory (the app's own, else the
    /// picker's: the Desktop in the app) under a free name; nil when there
    /// is no such directory or the clip could not be moved (it stays where
    /// it is).
    private func autoSaveRecording(_ url: URL) -> URL? {
        let manager = FileManager.default
        guard let directory = recordingAutoSaveDirectory ?? preferredDirectory() ?? picker.autoSaveDirectory else {
            return nil
        }
        let destination = AutoSaveNamer.destination(for: url, in: directory) { path in
            manager.fileExists(atPath: path)
        }
        do {
            try moveAutoSavedClip(url, destination)
        } catch {
            return nil
        }
        // Best effort: the per-recording temporary directory is empty now.
        try? manager.removeItem(at: url.deletingLastPathComponent())
        return destination
    }

    /// The clip under its suggested name, in its own temporary folder; the
    /// clip as it is when it cannot be renamed.
    private func renamedClip(_ url: URL, suggestedName: String) -> URL {
        let named = url.deletingLastPathComponent().appendingPathComponent(suggestedName)
        guard named != url else { return url }
        do {
            try FileManager.default.moveItem(at: url, to: named)
            return named
        } catch {
            return url
        }
    }

    /// A clip the user stopped, moved into the capture folder (Settings ▸
    /// Screenshots ▸ Save in; the Desktop by default). Nil when there is no
    /// such folder or the move failed; the clip is then still at `clip`.
    private func saveStoppedRecording(_ clip: URL) -> URL? {
        guard recordingAutoSaveDirectory ?? preferredDirectory() ?? picker.autoSaveDirectory != nil else { return nil }
        return autoSaveRecording(clip)
    }

    /// Ask where the clip goes, Desktop by default.
    /// Returns where the clip went; nil when it was not saved.
    @discardableResult
    private func saveRecordingWithPanel(tempURL: URL, suggestedName: String) -> URL? {
        let desktop = preferredDirectory() ?? FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask)
            .first

        guard let url = picker.chooseDestination(suggestedName: suggestedName, directory: desktop) else {
            try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
            return nil
        }
        do {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tempURL, to: url)
            // Best effort: the per-recording temporary directory is empty now.
            try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
            status.flash("Recording saved")
            return url
        } catch {
            status.errorMessage = "Could not save recording: \(error) — clip kept at \(tempURL.path)"
            return nil
        }
    }

    /// Waits for every recording that is still being finalized.
    func waitForRecordingsToFinish() async {
        for task in recordingFinishTasks.values {
            await task.value
        }
    }
}
