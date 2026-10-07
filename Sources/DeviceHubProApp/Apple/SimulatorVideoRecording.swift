import Foundation
import DeviceHubProKit

/// A recording of a simulator on the view-only canvas: `simctl io <UDID>
/// recordVideo` into a temporary file ("Capture": the live
/// canvas records its own frames through `ScreenRecorder`; the view-only
/// canvas's once-a-second pictures would make a slide show).
///
/// simctl writes the movie's index only when it is interrupted, so `finish`
/// stops it with SIGINT (`SimctlClient.recordVideo`, the task's cancel) and
/// returns once the movie is complete. H.264, for players without HEVC;
/// simctl records at the screen's own variable rate (28–30 fps measured).
/// A shutdown does not end simctl (it recorded on until interrupted, then
/// exited 0 with the movie playable up to the shutdown, measured
/// 2026-09-26), so the canvas's teardown ends the recording and the clip is
/// kept. A recording that ends on its own (a simctl failure) shows in
/// `hasEnded`, and `finish` then throws why.
@MainActor
final class SimulatorVideoRecording {
    /// Where the movie is written.
    let url: URL
    /// Whether simctl has ended, on its own or after `finish`.
    private(set) var hasEnded = false
    private let task: Task<Void, any Error>

    /// Starts recording `udid` into `url` (a new file).
    init(udid: String, simctl: SimctlClient, url: URL) {
        self.url = url
        let recording = Task.detached(priority: .userInitiated) {
            try await simctl.recordVideo(udid: udid, to: url, codec: .h264)
        }
        task = recording
        Task { [weak self] in
            _ = await recording.result
            self?.hasEnded = true
        }
    }

    /// Stops the recording with SIGINT and returns the complete movie; throws
    /// simctl's failure when it ended on its own, or
    /// `SimctlClientError.incompleteRecording` when the movie is not usable
    /// (stopped before its first frame, for one).
    func finish() async throws -> URL {
        task.cancel()
        try await task.value
        return url
    }
}
