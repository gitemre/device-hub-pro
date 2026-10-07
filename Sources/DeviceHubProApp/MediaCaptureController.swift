import Accelerate
import CoreMedia
import CoreVideo
import Foundation
import Observation
import DeviceHubProKit

/// The mirror's media: the frame feed that hands the session's frames to
/// the replay ring and the recorder, the ring and Save Replay, and the
/// host-side recording with its timer.
///
/// One long-lived instance per `DeviceWorkspace` (`media`), which the views
/// and menus read directly. The session hubs
/// drive it: `attach(frames:)` when a session starts, `endRecording(_:)`
/// and `detach()` when it is torn down. An ended recording goes to the
/// app-scoped `RecordingFinalizer`, which outlives the session.
@MainActor
@Observable
final class MediaCaptureController {
    private let preferences: AppPreferences
    private let status: StatusCenter
    private let context: ActiveDeviceContext
    private let finalizer: RecordingFinalizer
    /// Asks where a saved replay goes (the save panel in the app).
    private let picker: any FileDestinationPicker
    /// Told where a finished recording was saved (the stage's thumbnail
    /// banner, `CaptureController.showSavedRecording`). Wired by the workspace.
    @ObservationIgnored var onRecordingSaved: @MainActor (URL) -> Void = { _ in }
    /// The display name of this device, for a recording's file name and
    /// alerts; `AppModel` answers from its device list.
    @ObservationIgnored var displayName: @MainActor (_ device: DeviceRef) -> String = { $0.id }
    /// Starts a recording of a simulator on the view-only canvas through
    /// `simctl io recordVideo` into the file given
    /// (`SimulatorCanvasController.startViewOnlyRecording`); nil for every
    /// other session, which records its own frames. Wired by its owner.
    @ObservationIgnored var simulatorVideoRecording: @MainActor (_ url: URL) -> SimulatorVideoRecording? = { _ in nil }
    /// The mirrored session's frames; nil while nothing is mirrored.
    private var frames: FrameStore?

    init(
        preferences: AppPreferences,
        status: StatusCenter,
        context: ActiveDeviceContext,
        finalizer: RecordingFinalizer,
        picker: any FileDestinationPicker
    ) {
        self.preferences = preferences
        self.status = status
        self.context = context
        self.finalizer = finalizer
        self.picker = picker
    }

    /// A session started: its frames feed the replay ring and a recording.
    func attach(frames: FrameStore) {
        self.frames = frames
        updateFrameFeed()
    }

    /// The session is going away: the feed stops and the ring is dropped.
    /// The hub ends a running recording first (`endRecording(_:)`); the
    /// pending conversions keep counting.
    func detach() {
        stopFrameFeed()
        frames = nil
    }

    // MARK: - Replay buffer

    /// The kit buffer's frame rate: below the mirror's rate on purpose — the
    /// ring is a recap, not a recording.
    private static let replayTargetFPS: Double = 15

    /// A recording's frame rate (the `ScreenRecorder` default).
    private static let recordingTargetFPS: Double = 30

    /// Backpressure for the feed queue: one more frame may be staged while at
    /// most ``FeedAdmission/stagingLimit`` conversions are pending.
    static func replayStagingAccepts(pending: Int) -> Bool {
        FeedAdmission.stagingAccepts(pending: pending)
    }

    /// The frame poll's cadence: the replay ring keeps 15 fps, a recording
    /// 30 fps, so the poll runs twice as often while one records.
    static func frameFeedInterval(isRecording: Bool) -> Duration {
        isRecording ? .milliseconds(33) : .milliseconds(66)
    }

    /// The live ring. Nil while replay is off or before the first frame of a
    /// mirror arrives; dropped (and its encoder freed) when replay is
    /// disabled or the mirror stops.
    private(set) var replayBuffer: ReplayBuffer?
    /// The poll that hands the mirror's newest frame to its consumers — the
    /// replay ring and the recorder, which share one BGRA conversion per
    /// frame. Runs while a mirror runs and either consumes frames.
    private var frameFeedTask: Task<Void, Never>?
    /// Reused BGRA buffers for the conversion, one pool per frame size, so
    /// the feed no longer allocates an IOSurface-backed buffer per frame.
    private var frameFeedPool: BGRAPixelBufferPool?
    /// The pool of the ring's smaller frames (a simulator's, scaled to fit
    /// 1080 x 1920); nil while frames reach the ring at full size.
    private var replayScalePool: BGRAPixelBufferPool?
    /// Serializes the RGBA→BGRA pixel-buffer staging off the main actor; a
    /// serial queue keeps the frames' order (the encoders drop stale times).
    private let frameFeedQueue = DispatchQueue(
        label: "com.devicehubpro.frame-feed",
        qos: .utility
    )
    /// Which frames the feed stages: the last fed generation, the ring's
    /// size, and the conversions queued or executing on ``frameFeedQueue``
    /// (deliberately never reset when the feed restarts: conversions from
    /// the previous run still decrement it, so a reset would transiently
    /// over-admit). Readable for the tests.
    private(set) var admission = FeedAdmission()

    /// Whether the mirrored simulator is on the live canvas (the view-only
    /// canvas keeps no ring). Wired by the workspace; true by default.
    @ObservationIgnored var simulatorIsLiveCanvas: @MainActor () -> Bool = { true }
    /// Whether the stage can be seen (window shown and not occluded). A
    /// hidden stage pauses the ring's feed. Wired by the workspace.
    @ObservationIgnored var isStageVisible: @MainActor () -> Bool = { true }
    /// Told when the replay clip was saved, for the stage's banner
    /// (`CaptureController.showSavedReplay`). Wired by the workspace.
    @ObservationIgnored var onReplaySaved: @MainActor (URL) -> Void = { _ in }

    /// The kind of the mirrored device, for what replay it keeps.
    var replayDeviceKind: ReplaySupport.DeviceKind {
        guard let device = context.device else { return .none }
        if device.platform != .apple { return .android }
        if context.isPhysicalView { return .physicalApple }
        return simulatorIsLiveCanvas() ? .simulatorLive : .simulatorViewOnly
    }

    /// Whether Save Replay is listed at all: the Settings switch is on and
    /// the device keeps a ring (an Android device, a simulator on the live
    /// canvas). Otherwise there is nothing to save, so the button and the
    /// menu items are hidden, not dimmed.
    var offersReplay: Bool {
        ReplaySupport.isOffered(kind: replayDeviceKind, enabled: preferences.replayEnabled)
    }

    /// Whether the pill's Save Replay button is enabled: a ring with frames,
    /// and no save running.
    var canSaveReplayNow: Bool { canSaveReplay && !isSavingReplay && replayHasFrames }
    private(set) var isSavingReplay = false
    /// Whether the ring holds an encoded frame; refreshed by the feed's poll
    /// and changed only on an edge, so the button redraws once.
    private(set) var replayHasFrames = false

    /// Whether the one-time tip is showing on the Save Replay button.
    var replayHintVisible = false

    /// A screenshot or recording was just taken: the first time on a device
    /// with a replay ring shows the tip (persisted at once, never again).
    func noteCaptureTaken() {
        guard offersReplay, !preferences.replayHintShown else { return }
        preferences.markReplayHintShown()
        replayHintVisible = true
    }

    /// The tip's text (the window is the Settings one).
    var replayHintText: String { ReplaySupport.hintText(windowSeconds: preferences.replayWindowSeconds) }

    /// The pill button's tooltip.
    var replayTooltip: String { ReplaySupport.tooltip(windowSeconds: preferences.replayWindowSeconds) }

    /// Whether ``saveReplay()`` has a ring to write.
    var canSaveReplay: Bool { replayBuffer != nil && context.device != nil }

    /// The Device menu / popover title's window suffix.
    var replayWindowLabel: String { "last \(Int(preferences.replayWindowSeconds)) s" }

    /// Turning replay off frees the ring (the poll keeps running while a
    /// recording needs it); turning it on mid-mirror starts filling from
    /// that point.
    func setReplayEnabled(_ enabled: Bool) {
        preferences.setReplayEnabled(enabled)
        resetReplayRing()
        updateFrameFeed()
    }

    /// Changing the window restarts the fill with a fresh ring (the encoded
    /// segments are window-sized; nothing is re-encoded retroactively).
    func setReplayWindowSeconds(_ seconds: Double) {
        guard AppPreferences.replayWindowOptions.contains(seconds) else { return }
        preferences.setReplayWindowSeconds(seconds)
        resetReplayRing()
    }

    /// Drops the ring; the feed builds a fresh one (at the current window)
    /// from its next frame.
    private func resetReplayRing() {
        replayBuffer = nil
        replayHasFrames = false
        admission.resetRing()
    }

    /// Starts the frame poll while a mirror runs and something consumes its
    /// frames (the replay ring, a recording), stops it otherwise. Every tick
    /// takes the mirror's latest frame.
    private func updateFrameFeed() {
        guard frames != nil, offersReplay || screenRecorder != nil else {
            if !offersReplay, replayBuffer != nil { resetReplayRing() }
            frameFeedTask?.cancel()
            frameFeedTask = nil
            return
        }
        guard frameFeedTask == nil else { return }
        frameFeedTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let frames = self.frames else { return }
                let hasFrames = (self.replayBuffer?.retainedFrameCount ?? 0) > 0
                if hasFrames != self.replayHasFrames { self.replayHasFrames = hasFrames }
                if let frame = frames.current,
                   ReplaySupport.feedsRing(isStageVisible: self.isStageVisible(), isRecording: self.screenRecorder != nil) {
                    self.submitFeedFrame(frame)
                }
                let interval = Self.frameFeedInterval(isRecording: self.screenRecorder != nil)
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// The mirror is going away: the poll stops and the ring is dropped.
    private func stopFrameFeed() {
        frameFeedTask?.cancel()
        frameFeedTask = nil
        resetReplayRing()
    }

    /// One poll tick's frame: skips a repeat of the last fed frame,
    /// (re)builds the ring when the pixel size changes, then stages one
    /// conversion on the feed queue for both consumers, so the render path
    /// never waits. The recorder is not rebuilt on a size change: it
    /// letterboxes a rotated or unfolded frame into its first canvas.
    private func submitFeedFrame(_ frame: Frame) {
        guard admission.isNew(width: frame.width, height: frame.height, generation: frame.generation)
        else { return }
        noteRecordingFrameSize(width: frame.width, height: frame.height)

        let kind = replayDeviceKind
        let ringSize = ReplaySupport.encodedSize(width: frame.width, height: frame.height, kind: kind)
        if admission.ringNeedsRebuild(
            replayEnabled: offersReplay,
            hasRing: replayBuffer != nil,
            width: frame.width,
            height: frame.height
        ) {
            replayBuffer = ReplayBuffer(
                windowSeconds: preferences.replayWindowSeconds,
                targetFPS: Self.replayTargetFPS,
                width: ringSize.width,
                height: ringSize.height
            )
        }
        let replay = offersReplay ? replayBuffer : nil
        let needsScale = replay != nil && (ringSize.width != frame.width || ringSize.height != frame.height)
        if needsScale, replayScalePool?.width != ringSize.width || replayScalePool?.height != ringSize.height {
            replayScalePool = BGRAPixelBufferPool(width: ringSize.width, height: ringSize.height)
        }
        let scalePool = replayScalePool
        let recorder = screenRecorder
        // A frame dropped here stays un-fed, so a static screen's only frame
        // is offered again on the next tick.
        guard admission.stage(generation: frame.generation, hasConsumer: replay != nil || recorder != nil)
        else { return }

        if frameFeedPool?.width != frame.width || frameFeedPool?.height != frame.height {
            frameFeedPool = BGRAPixelBufferPool(width: frame.width, height: frame.height)
        }
        let pool = frameFeedPool
        let time = CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 600)
        frameFeedQueue.async { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.admission.conversionFinished()
                }
            }
            if needsScale, recorder == nil, let source = frame.pixelBuffer,
               CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA {
                // Ring only: scale straight from the session's buffer, no
                // full-size copy first.
                guard let small = Self.scaledBGRA(source, width: ringSize.width, height: ringSize.height, pool: scalePool)
                else { return }
                replay?.ingest(small, at: time)
                return
            }
            guard let pixelBuffer = Self.feedPixelBuffer(from: frame, pool: pool) else { return }
            if needsScale {
                if let small = Self.scaledBGRA(pixelBuffer, width: ringSize.width, height: ringSize.height, pool: scalePool) {
                    replay?.ingest(small, at: time)
                }
            } else {
                replay?.ingest(pixelBuffer, at: time)
            }
            recorder?.ingest(pixelBuffer, at: time)
        }
    }

    /// Copies a mirror frame into a BGRA `CVPixelBuffer` for the encoders,
    /// drawn from `pool` when it has one; it runs on the feed queue. A frame
    /// that is a 32BGRA pixel buffer already (the simulator's canvas, a
    /// phone's decoded scrcpy video) is copied as it is, row by row
    /// (`copyBGRA`), without making its RGBA bytes; a byte frame (RGBA8888,
    /// as the renderer consumes it) is swapped R↔B in one pass
    /// (`vImagePermuteChannels_ARGB8888`).
    nonisolated static func feedPixelBuffer(
        from frame: Frame,
        pool: BGRAPixelBufferPool?
    ) -> CVPixelBuffer? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        if let source = frame.pixelBuffer,
           CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA {
            return copyBGRA(source, width: frame.width, height: frame.height, pool: pool)
        }
        guard frame.data.count >= frame.width * frame.height * 4 else { return nil }

        guard let pixelBuffer = pool?.makeBuffer() ?? BGRAPixelBufferPool.makeUnpooledBuffer(
            width: frame.width,
            height: frame.height
        ) else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        var output = vImage_Buffer(
            data: destination,
            height: vImagePixelCount(frame.height),
            width: vImagePixelCount(frame.width),
            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer)
        )
        let permute: [UInt8] = [2, 1, 0, 3]
        let status = frame.data.withUnsafeBytes { raw -> vImage_Error in
            guard let base = raw.baseAddress else { return kvImageNullPointerArgument }
            var input = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: base),
                height: vImagePixelCount(frame.height),
                width: vImagePixelCount(frame.width),
                rowBytes: frame.width * 4
            )
            return vImagePermuteChannels_ARGB8888(
                &input,
                &output,
                permute,
                vImage_Flags(kvImageNoFlags)
            )
        }
        guard status == kvImageNoError else { return nil }
        return pixelBuffer
    }

    /// A 32BGRA buffer scaled into a buffer of `width` x `height` from
    /// `pool` (`vImageScale_ARGB8888`, four 8-bit channels in any order);
    /// runs on the feed queue.
    nonisolated static func scaledBGRA(
        _ source: CVPixelBuffer,
        width: Int,
        height: Int,
        pool: BGRAPixelBufferPool?
    ) -> CVPixelBuffer? {
        guard let target = pool?.makeBuffer()
            ?? BGRAPixelBufferPool.makeUnpooledBuffer(width: width, height: height),
            CVPixelBufferGetWidth(target) == width, CVPixelBufferGetHeight(target) == height
        else { return nil }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        CVPixelBufferLockBaseAddress(target, [])
        defer { CVPixelBufferUnlockBaseAddress(target, []) }
        guard let from = CVPixelBufferGetBaseAddress(source),
              let to = CVPixelBufferGetBaseAddress(target)
        else { return nil }
        var input = vImage_Buffer(
            data: from,
            height: vImagePixelCount(CVPixelBufferGetHeight(source)),
            width: vImagePixelCount(CVPixelBufferGetWidth(source)),
            rowBytes: CVPixelBufferGetBytesPerRow(source)
        )
        var output = vImage_Buffer(
            data: to,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(target)
        )
        guard vImageScale_ARGB8888(&input, &output, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            return nil
        }
        return target
    }

    /// A 32BGRA buffer's pixels copied into a buffer of its own (the source
    /// is the session's, reused for a later frame), rows re-strided by
    /// `vImageCopyBuffer`.
    private nonisolated static func copyBGRA(
        _ source: CVPixelBuffer,
        width: Int,
        height: Int,
        pool: BGRAPixelBufferPool?
    ) -> CVPixelBuffer? {
        guard CVPixelBufferGetWidth(source) == width, CVPixelBufferGetHeight(source) == height,
              let pixelBuffer = pool?.makeBuffer()
                ?? BGRAPixelBufferPool.makeUnpooledBuffer(width: width, height: height)
        else { return nil }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let from = CVPixelBufferGetBaseAddress(source),
              let to = CVPixelBufferGetBaseAddress(pixelBuffer)
        else { return nil }
        var input = vImage_Buffer(
            data: from,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(source)
        )
        var output = vImage_Buffer(
            data: to,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer)
        )
        guard vImageCopyBuffer(&input, &output, 4, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            return nil
        }
        return pixelBuffer
    }

    // MARK: - Recording

    /// The host-side recorder fed with the mirror's frames (see the
    /// Recording section); nil while nothing is recorded.
    private(set) var screenRecorder: ScreenRecorder?
    /// A view-only simulator's `simctl io recordVideo`; nil otherwise.
    private(set) var simulatorRecording: SimulatorVideoRecording?
    /// Whether a recording runs: the REC indicator and the Record items
    /// follow the recorder itself, so they end the moment it ends.
    var isRecording: Bool { screenRecorder != nil || simulatorRecording != nil }
    /// Whether Start/Stop Recording can act: a recording runs (to stop it),
    /// or a session does, whatever the device.
    var canRecord: Bool { isRecording || (frames != nil && context.device != nil) }
    /// When the current recording started; drives the stage's elapsed readout.
    private(set) var recordingStartedAt: Date?
    /// The stage indicator's elapsed time, ticked once a second.
    private(set) var recordingElapsedText = ""
    /// The recorded device's display name, for the clip's file name.
    private(set) var recordingDeviceName: String?
    @ObservationIgnored private(set) var recordingTimerTask: Task<Void, Never>?

    /// Why a recording ended; decides where its clip goes.
    enum RecordingEnd: Equatable {
        /// The user stopped it, switched devices or stopped the mirror: the
        /// clip goes to the save panel.
        case user
        /// The device disconnected or its stream failed: the clip is saved
        /// next to where the panel would have put it, and an alert says so.
        case interrupted(String)
        /// The recorder itself failed (disk full, encoder gone).
        case failed(ScreenRecorderError)
        /// The app quits: the clip is saved without asking.
        case quit
    }

    func toggleRecording() async {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    /// Records the mirror on the host: the recorder takes the same frames as
    /// the replay ring (fed even with replay off), so it works for emulators,
    /// physical devices and a simulator's live canvas alike, has no length
    /// limit and needs no `screenrecord` on the device. A simulator on the
    /// view-only canvas, whose frames come once a second, is recorded by
    /// `simctl io recordVideo` instead (`simulatorVideoRecording`).
    private func startRecording() {
        guard !isRecording, frames != nil, let device = context.device else { return }
        let deviceName = displayName(device)
        // A directory of its own: two clips of one device within a second
        // must not collide, and the recorder never overwrites.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-recordings", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outputURL = directory.appendingPathComponent(AdbClient.recordingFileName(device: deviceName))
        let recorder: ScreenRecorder
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            warnIfDiskIsLow(at: directory)
            if let recording = simulatorVideoRecording(outputURL) {
                simulatorRecording = recording
                noteCaptureTaken()
                recordingDeviceName = deviceName
                recordingStartedAt = Date()
                startRecordingTimer()
                return
            }
            recorder = try ScreenRecorder(outputURL: outputURL, targetFPS: Self.recordingTargetFPS)
        } catch {
            status.errorMessage = "Could not start recording: \(error)"
            return
        }
        screenRecorder = recorder
        recordingFrameSize = nil
        warnedRecordingSizeChange = false
        noteCaptureTaken()
        recordingDeviceName = deviceName
        recordingStartedAt = Date()
        // Offer the current frame again: on a static screen it is the only
        // one the recorder would get, and the ring already has it.
        admission.offerCurrentFrameAgain()
        updateFrameFeed()
        startRecordingTimer()
    }

    /// The first frame size of the recording in flight; nil outside one.
    @ObservationIgnored private var recordingFrameSize: (width: Int, height: Int)?
    @ObservationIgnored private var warnedRecordingSizeChange = false

    /// A recording keeps the size it started with (a rotated frame is
    /// letterboxed into it): said once, the first time the device's frame
    /// size differs.
    private func noteRecordingFrameSize(width: Int, height: Int) {
        guard screenRecorder != nil else {
            recordingFrameSize = nil
            warnedRecordingSizeChange = false
            return
        }
        guard let start = recordingFrameSize else {
            recordingFrameSize = (width, height)
            return
        }
        if !warnedRecordingSizeChange, Self.recordingSizeChanged(from: start, to: (width, height)) {
            warnedRecordingSizeChange = true
            status.flash("Recording keeps the starting orientation", seconds: 4)
        }
    }

    nonisolated static func recordingSizeChanged(from start: (width: Int, height: Int), to now: (width: Int, height: Int)) -> Bool {
        start.width != now.width || start.height != now.height
    }

    /// Below this much free space a recording is likely to fill the disk.
    nonisolated static let lowDiskBytes: Int64 = 1_000_000_000

    /// The warning for a recording started with `available` bytes free; nil
    /// when there is room (or the figure is unknown).
    nonisolated static func lowDiskWarning(availableBytes available: Int64?) -> String? {
        guard let available, available < lowDiskBytes else { return nil }
        let gigabytes = Double(max(0, available)) / 1_000_000_000
        return String(format: "Only %.1f GB is free on this Mac. The recording stops if the disk fills up.", gigabytes)
    }

    private func warnIfDiskIsLow(at directory: URL) {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let warning = Self.lowDiskWarning(availableBytes: values?.volumeAvailableCapacityForImportantUsage) {
            status.flash(warning, seconds: 6)
        }
    }

    /// Stop Recording: the clip goes to the save panel.
    private func stopRecording() {
        endRecording(.user)
    }

    /// Ends the running recording: it stops taking frames at once (so a new
    /// session's frames never reach it), then finalizes in the background
    /// and hands the clip on according to `end`. Nothing is ever deleted
    /// silently: a clip that cannot be written says why.
    func endRecording(_ end: RecordingEnd) {
        if let recording = simulatorRecording {
            let deviceName = recordingDeviceName ?? "device"
            simulatorRecording = nil
            recordingDeviceName = nil
            recordingStartedAt = nil
            clearRecordingTimer()
            finalizer.finish(recording, deviceName: deviceName, end: end, saved: onRecordingSaved)
            return
        }
        guard let recorder = screenRecorder else { return }
        let deviceName = recordingDeviceName ?? "device"
        screenRecorder = nil
        recordingDeviceName = nil
        recordingStartedAt = nil
        clearRecordingTimer()
        updateFrameFeed()
        // The clip ends now, even though the last frame may be older (a
        // static screen): the recorder holds it until this time.
        let endTime = CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 600)
        finalizer.finish(recorder, endingAt: endTime, deviceName: deviceName, end: end, saved: onRecordingSaved)
    }

    /// Ticks the stage's elapsed readout and watches the recorder: a
    /// recorder that failed (disk full, encoder gone) ends the recording at
    /// once instead of counting on over a dead file, and so does a simctl
    /// recording that ended on its own (a simctl failure; a shutdown ends
    /// it through the canvas's teardown instead).
    private func startRecordingTimer() {
        recordingTimerTask?.cancel()
        recordingElapsedText = "0s"
        recordingTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRecording, let started = self.recordingStartedAt else { return }
                if let failure = self.screenRecorder?.failure {
                    self.endRecording(.failed(failure))
                    return
                }
                if self.simulatorRecording?.hasEnded == true {
                    self.endRecording(.interrupted("The simulator stopped recording"))
                    return
                }
                self.recordingElapsedText = Self.formatDuration(
                    Date().timeIntervalSince(started)
                )
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func clearRecordingTimer() {
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        recordingElapsedText = ""
    }

    /// Short elapsed-time label for the recording indicator ("1m 05s").
    static func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, seconds)
        }
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, seconds)
        }
        return String(format: "%ds", seconds)
    }

    // MARK: - Replay saving

    /// Saves the replay ring's retained window as a clip; a save panel asks
    /// where it goes (Desktop default).
    func saveReplay() async {
        guard !isSavingReplay else { return }
        isSavingReplay = true
        defer { isSavingReplay = false }
        guard let buffer = replayBuffer else {
            status.errorMessage = "No replay to save — start a mirror and give it a few seconds."
            return
        }
        let seconds = buffer.retainedSeconds
        guard seconds > 0 else {
            status.flash("The replay buffer is still filling")
            return
        }

        let tempURL: URL
        do {
            tempURL = try await buffer.saveClip(to: FileManager.default.temporaryDirectory)
        } catch {
            status.errorMessage = "Could not save replay: \(error)"
            return
        }

        saveReplayToCaptureFolder(tempURL: tempURL)
    }

    /// Saves the clip without asking, like a screenshot: into Settings ▸
    /// Screenshots ▸ Save in (the default screenshot folder when none is
    /// set). The "Replay Saved" banner that follows reveals it in Finder with
    /// one click.
    private func saveReplayToCaptureFolder(tempURL: URL) {
        let directory = preferences.captureFolder ?? picker.screenshotDirectory
        let url = Self.uniqueURL(in: directory, name: tempURL.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: tempURL, to: url)
            status.flash("Replay saved to \(directory.lastPathComponent)")
            onReplaySaved(url)
        } catch {
            status.errorMessage = "Could not save replay: \(error) — clip kept at \(tempURL.path)"
        }
    }

    /// `name` in `directory`, or "name 2", "name 3"… when it is taken.
    static func uniqueURL(in directory: URL, name: String) -> URL {
        let manager = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
            index += 1
        }
        return candidate
    }
}
