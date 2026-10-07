import Accelerate
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Errors thrown by ``ScreenRecorder``.
public enum ScreenRecorderError: Error, Equatable, CustomStringConvertible {
    /// A file already exists at the output URL; the recorder never overwrites.
    case outputExists(String)
    /// `finalize` ran before any frame was encoded. No file is left behind.
    case noFrames
    /// The `VTCompressionSession` could not be created.
    case encoderUnavailable(String)
    /// `AVAssetWriter` failed (disk full, destination gone). The partial
    /// file is removed when `finalize` reports it.
    case writerFailed(String)
    /// `finalize` waited for in-flight encoder callbacks past its timeout.
    case encoderTimeout
    /// `finalize` or `cancel` already ran.
    case alreadyFinished

    public var description: String {
        switch self {
        case .outputExists(let path):
            return "a file already exists at \(path)"
        case .noFrames:
            return "no frames were recorded"
        case .encoderUnavailable(let reason):
            return "recording encoder unavailable: \(reason)"
        case .writerFailed(let reason):
            return "could not write the recording: \(reason)"
        case .encoderTimeout:
            return "the recording encoder did not finish in time"
        case .alreadyFinished:
            return "the recording has already been finished or cancelled"
        }
    }
}

/// Records the mirror on the host: the same `CVPixelBuffer`s ``ReplayBuffer``
/// receives are H.264-encoded with a real-time `VTCompressionSession` (shared
/// with the replay ring) and muxed continuously into an `.mp4` on disk.
///
/// Unlike the device-side `screenrecord`, there is no length limit (it stops
/// at 180 s) and no dependency on the system image (ATD images have no
/// `screenrecord`). Memory stays bounded however long the recording runs:
/// encoded samples go to the file as they arrive, at most
/// ``maxPendingSamples`` wait for the writer and at most
/// `max(2, min(8, 16 MB / (width × height × 4)))` source frames wait for the
/// encoder. Movie fragments are flushed every 10 s of media, so a crash
/// mid-recording still leaves a readable file up to the last fragment.
///
/// ## Frames
///
/// `ingest` never blocks: a frame is dropped (and counted in
/// ``droppedFrameCount``) when it does not advance the clock, arrives sooner
/// than 90% of `1 / targetFPS` after the previous one, or when the encoder or
/// the writer is behind. Timestamps are the caller's clock (the mirror feed
/// uses `systemUptime`); the file starts at the first encoded frame. Frames
/// may be sparse — a static screen produces none — and each one is shown
/// until the next, so the file is variable-frame-rate with correct timing.
/// Keyframes are forced every 2 s so the file seeks well.
///
/// ## Resolution and rotation changes
///
/// An H.264 track has one size, fixed by the first frame (rounded down to
/// even dimensions) unless `canvasSize` is given. A later frame of another
/// size — the device rotated, a foldable unfolded — is scaled to fit inside
/// that canvas preserving its aspect ratio, centered on black bars
/// (letterbox/pillarbox). A portrait recording that turns landscape
/// therefore shows the landscape picture smaller, with bars above and below,
/// rather than being cut into a second file or distorted.
public actor ScreenRecorder {
    /// Where the recording is written.
    public nonisolated let outputURL: URL
    private let state: RecorderState

    /// Encoded samples allowed to wait for the writer before frames are
    /// dropped: four seconds of frames at the target rate.
    public nonisolated var maxPendingSamples: Int { state.maxPendingSamples }

    /// Starts a recording that will be written to `outputURL` (its directory
    /// must exist). `canvasSize` fixes the video size up front; nil takes it
    /// from the first frame. `averageBitRate` overrides the
    /// `max(1 Mbps, 0.1 bits/pixel × fps)` default. Throws
    /// ``ScreenRecorderError/outputExists(_:)`` when the file already exists.
    public init(
        outputURL: URL,
        targetFPS: Double = 30,
        canvasSize: CGSize? = nil,
        averageBitRate: Int? = nil
    ) throws {
        try self.init(
            outputURL: outputURL,
            targetFPS: targetFPS,
            canvasSize: canvasSize,
            averageBitRate: averageBitRate,
            idleTimeout: RecorderState.defaultIdleTimeout,
            frameEncoder: nil
        )
    }

    /// Test seam: injects the encoder submission (or a stall) and the idle
    /// timeout used by ``finalize(endingAt:)``.
    init(
        outputURL: URL,
        targetFPS: Double,
        canvasSize: CGSize? = nil,
        averageBitRate: Int? = nil,
        idleTimeout: Duration,
        frameEncoder: H264EncoderSession.SubmissionHook?
    ) throws {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ScreenRecorderError.outputExists(outputURL.path)
        }
        self.outputURL = outputURL
        self.state = RecorderState(
            outputURL: outputURL,
            targetFPS: targetFPS,
            canvasSize: canvasSize,
            averageBitRate: averageBitRate,
            idleTimeout: idleTimeout,
            frameEncoder: frameEncoder
        )
    }

    /// Submits one mirror frame (32BGRA). Never blocks; see "Frames" above.
    public nonisolated func ingest(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        state.ingest(pixelBuffer, at: time)
    }

    /// Stops accepting frames, waits for the encoder to drain, writes the
    /// remaining samples and closes the file; returns ``outputURL``. The last
    /// frame is held until `endTime` when given (a static screen at the end
    /// still counts), otherwise for one frame interval. Throws
    /// ``ScreenRecorderError/noFrames`` when nothing was recorded, and
    /// removes the file whenever it throws.
    public func finalize(endingAt endTime: CMTime? = nil) async throws -> URL {
        try await state.finalize(endingAt: endTime)
        return outputURL
    }

    /// Stops the recording and deletes its file. Safe to call at any time,
    /// including after ``finalize(endingAt:)`` failed; a no-op after a
    /// successful finalize (the file then belongs to the caller). A cancel
    /// that arrives while a finalize is closing the file makes that finalize
    /// delete it and throw `CancellationError`.
    public func cancel() async {
        await state.cancel()
    }

    /// Media time from the first to the newest encoded frame.
    public nonisolated var recordedSeconds: Double { state.recordedSeconds }

    /// Frames encoded (and handed to the writer) so far.
    public nonisolated var encodedFrameCount: Int { state.encodedFrameCount }

    /// Frames dropped so far: stale or paced-out timestamps, a saturated
    /// encoder or writer, and VideoToolbox rejections.
    public nonisolated var droppedFrameCount: Int { state.droppedFrameCount }

    /// The video size, fixed by the first frame (nil before it).
    public nonisolated var canvasSize: CGSize? { state.canvasSize }

    /// A failure that ended the recording early (the writer failed, the
    /// encoder could not start); frames are no longer accepted once set.
    public nonisolated var failure: ScreenRecorderError? { state.failure }

    /// Encoded samples currently waiting for the writer; diagnostics-only.
    public nonisolated var pendingSampleCount: Int { state.pendingSampleCount }
}

// MARK: - State

final class RecorderState: @unchecked Sendable {
    static let defaultIdleTimeout: Duration = .seconds(5)
    /// Keyframe spacing: seekable, and a lost P-frame heals within 2 s.
    static let keyframeIntervalSeconds = 2.0
    /// Movie fragments are flushed at this media interval.
    static let fragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

    private enum Phase {
        case recording
        case finishing
        case finished
    }

    let outputURL: URL
    let targetFPS: Double
    let maxPendingSamples: Int
    private let requestedCanvas: (width: Int, height: Int)?
    private let averageBitRateOverride: Int?
    private let idleTimeout: Duration
    private let frameEncoder: H264EncoderSession.SubmissionHook?
    private let frameDuration: CMTime
    private let minFrameInterval: CMTime

    private let lock = NSLock()
    private var phase = Phase.recording
    /// `finalize` succeeded: the file belongs to the caller.
    private var isFinalized = false
    /// `cancel` arrived while `finalize` was closing the file (the actor is
    /// reentrant); `finalize` discards the file once the writer is done.
    private var cancelRequested = false
    private var encoder: H264EncoderSession?
    private var inFlight: EncoderInFlightTracker?
    private var fitter: CanvasFitter?
    private var canvas: (width: Int, height: Int)?
    private var lastAcceptedTime: CMTime = .invalid
    private var lastKeyframeTime: CMTime = .invalid
    private var firstEncodedTime: CMTime = .invalid
    private var lastEncodedTime: CMTime = .invalid
    private var encodedCount = 0
    private var droppedCount = 0
    private var failureValue: ScreenRecorderError?
    /// Encoded samples waiting for the writer, in encode order.
    private var pending: [CMSampleBuffer] = []

    /// Serializes the injected hook like the real session's own lock does.
    private let hookLock = NSLock()
    private let fitterLock = NSLock()

    // writerQueue only.
    private let writerQueue = DispatchQueue(label: "io.github.gitemre.devicehubpro.screen-recorder.writer", qos: .userInitiated)
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?

    init(
        outputURL: URL,
        targetFPS: Double,
        canvasSize: CGSize?,
        averageBitRate: Int?,
        idleTimeout: Duration,
        frameEncoder: H264EncoderSession.SubmissionHook?
    ) {
        precondition(targetFPS > 0, "targetFPS must be positive")
        self.outputURL = outputURL
        self.targetFPS = targetFPS
        self.maxPendingSamples = max(8, Int((targetFPS * 4).rounded()))
        self.requestedCanvas = canvasSize.map {
            (Self.evenDimension(Int($0.width.rounded())), Self.evenDimension(Int($0.height.rounded())))
        }
        self.averageBitRateOverride = averageBitRate
        self.idleTimeout = idleTimeout
        self.frameEncoder = frameEncoder
        self.frameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS.rounded()))
        self.minFrameInterval = CMTimeMultiplyByFloat64(frameDuration, multiplier: 0.9)
    }

    /// H.264 (4:2:0) needs even dimensions; at least 2.
    private static func evenDimension(_ value: Int) -> Int {
        max(2, value & ~1)
    }

    // MARK: Ingest

    func ingest(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        lock.lock()
        guard phase == .recording, failureValue == nil else {
            lock.unlock()
            return
        }
        guard time.isValid, time.isNumeric else {
            droppedCount += 1
            lock.unlock()
            return
        }
        if lastAcceptedTime.isValid {
            guard CMTimeCompare(time, lastAcceptedTime) > 0,
                  CMTimeCompare(CMTimeSubtract(time, lastAcceptedTime), minFrameInterval) >= 0
            else {
                droppedCount += 1
                lock.unlock()
                return
            }
        }
        if encoder == nil {
            startEncoder(firstFrame: pixelBuffer)
        }
        guard let encoder, let inFlight, let canvas else {
            droppedCount += 1
            lock.unlock()
            return
        }
        // Backpressure: the writer is behind, or the encoder is saturated.
        guard pending.count < maxPendingSamples, inFlight.tryAcquire() else {
            droppedCount += 1
            lock.unlock()
            return
        }
        lastAcceptedTime = time
        let forceKeyframe = !lastKeyframeTime.isValid
            || CMTimeGetSeconds(CMTimeSubtract(time, lastKeyframeTime)) >= Self.keyframeIntervalSeconds
        if forceKeyframe {
            lastKeyframeTime = time
        }
        lock.unlock()

        guard let frame = fitted(pixelBuffer, canvas: canvas) else {
            dropSubmission(inFlight)
            return
        }
        let frameProperties = H264EncoderSession.frameProperties(forceKeyframe: forceKeyframe)
        let status: OSStatus
        if let frameEncoder {
            hookLock.lock()
            status = frameEncoder(encoder.session, frame, time, frameProperties)
            hookLock.unlock()
        } else {
            status = encoder.encode(frame, presentationTimeStamp: time, frameProperties: frameProperties)
        }
        if status != noErr {
            dropSubmission(inFlight)
        }
    }

    /// Creates the encoder for the canvas the first frame defines. Called
    /// under `lock`.
    private func startEncoder(firstFrame: CVPixelBuffer) {
        let size = requestedCanvas ?? (
            Self.evenDimension(CVPixelBufferGetWidth(firstFrame)),
            Self.evenDimension(CVPixelBufferGetHeight(firstFrame))
        )
        let settings = H264EncoderSettings(
            width: size.width,
            height: size.height,
            targetFPS: targetFPS,
            keyframeIntervalSeconds: Self.keyframeIntervalSeconds,
            averageBitRate: averageBitRateOverride
        )
        do {
            encoder = try H264EncoderSession(settings: settings) { [weak self] sample, status, flags in
                self?.didEncode(sample, status: status, flags: flags)
            }
            inFlight = EncoderInFlightTracker(limit: settings.maxOutstandingFrames)
            canvas = size
        } catch {
            failureValue = .encoderUnavailable("\(error)")
        }
    }

    /// The frame as the canvas takes it: unchanged at the canvas size,
    /// otherwise letterboxed into a pooled canvas-sized buffer.
    private func fitted(_ pixelBuffer: CVPixelBuffer, canvas: (width: Int, height: Int)) -> CVPixelBuffer? {
        if CVPixelBufferGetWidth(pixelBuffer) == canvas.width,
           CVPixelBufferGetHeight(pixelBuffer) == canvas.height {
            return pixelBuffer
        }
        fitterLock.lock()
        defer { fitterLock.unlock() }
        if fitter == nil {
            fitter = CanvasFitter(width: canvas.width, height: canvas.height)
        }
        return fitter?.fit(pixelBuffer)
    }

    private func dropSubmission(_ inFlight: EncoderInFlightTracker) {
        lock.lock()
        droppedCount += 1
        lock.unlock()
        inFlight.release()
    }

    // MARK: Encoder output

    func didEncode(_ sampleBuffer: CMSampleBuffer?, status: OSStatus, flags: VTEncodeInfoFlags) {
        lock.lock()
        let tracker = inFlight
        var shouldDrain = false
        if phase != .finished, status == noErr, !flags.contains(.frameDropped), let sampleBuffer {
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if !firstEncodedTime.isValid {
                firstEncodedTime = time
            }
            lastEncodedTime = time
            encodedCount += 1
            pending.append(sampleBuffer)
            shouldDrain = true
        } else if phase != .finished {
            droppedCount += 1
        }
        lock.unlock()
        if shouldDrain {
            writerQueue.async { [weak self] in
                self?.drainOnWriterQueue()
            }
        }
        // After the sample is queued, so an idle waiter always sees it.
        tracker?.release()
    }

    // MARK: Writer (writerQueue only)

    /// Appends every queued sample, creating the writer on the first one
    /// (its format description is the track's).
    private func drainOnWriterQueue() {
        while true {
            lock.lock()
            guard phase != .finished, failureValue == nil, let sample = pending.first else {
                lock.unlock()
                return
            }
            lock.unlock()

            if writer == nil, let failure = startWriter(firstSample: sample) {
                fail(failure)
                return
            }
            guard let writer, let input else { return }
            // `expectsMediaDataInRealTime` keeps the input ready almost
            // always; a slow disk makes the queue (and then ingest) wait.
            let deadline = ContinuousClock.now + .seconds(10)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else {
                    fail(.writerFailed(writer.error?.localizedDescription ?? "the writer stopped"))
                    return
                }
                guard ContinuousClock.now < deadline else {
                    fail(.writerFailed("the writer stopped accepting samples"))
                    return
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
            guard input.append(EncodedSamples.withValidDuration(sample, fallback: frameDuration)) else {
                fail(.writerFailed(writer.error?.localizedDescription ?? "appending a sample failed"))
                return
            }
            lock.lock()
            if !pending.isEmpty {
                pending.removeFirst()
            }
            lock.unlock()
        }
    }

    private func startWriter(firstSample: CMSampleBuffer) -> ScreenRecorderError? {
        guard let format = CMSampleBufferGetFormatDescription(firstSample) else {
            return .writerFailed("the encoded samples have no format description")
        }
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            return .writerFailed(error.localizedDescription)
        }
        // Fragments keep a crashed recording readable up to the last flush;
        // no network optimization, which would rewrite the whole file at
        // the end.
        writer.movieFragmentInterval = Self.fragmentInterval
        writer.shouldOptimizeForNetworkUse = false
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            return .writerFailed("the writer rejected the video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            return .writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(firstSample))
        self.writer = writer
        self.input = input
        return nil
    }

    /// Records the first failure; frames stop being accepted.
    private func fail(_ failure: ScreenRecorderError) {
        lock.lock()
        if failureValue == nil {
            failureValue = failure
        }
        pending.removeAll()
        lock.unlock()
    }

    // MARK: Finish

    func finalize(endingAt endTime: CMTime?) async throws {
        let started: (encoder: H264EncoderSession?, tracker: EncoderInFlightTracker?)? = lock.withLock {
            guard phase == .recording else { return nil }
            phase = .finishing
            return (encoder, inFlight)
        }
        guard let (encoder, tracker) = started else {
            throw ScreenRecorderError.alreadyFinished
        }

        do {
            if let encoder {
                // Blocks until VideoToolbox has called back for every
                // submitted frame; keep it off the caller's executor.
                await Task.detached(priority: .userInitiated) { encoder.completeFrames() }.value
            }
            try await tracker?.waitUntilIdle(
                timeout: idleTimeout,
                timeoutError: ScreenRecorderError.encoderTimeout
            )
            let endTime = endTime.flatMap { $0.isNumeric ? CMTimeGetSeconds($0) : nil }
            try await finishWriting(endingAtSeconds: endTime)
        } catch {
            await discard()
            // A cancel that arrived while finishing wins: the caller asked to
            // throw the recording away, so its own failure (under load, "no
            // frames were recorded") is not what they hear.
            if lock.withLock({ cancelRequested }) { throw CancellationError() }
            throw error
        }
        let outcome: (released: H264EncoderSession?, cancelled: Bool) = lock.withLock {
            phase = .finished
            isFinalized = !cancelRequested
            defer { self.encoder = nil }
            return (self.encoder, cancelRequested)
        }
        // Released outside the lock: the session's teardown flushes frames,
        // and their callbacks take the lock.
        _ = outcome.released
        if outcome.cancelled {
            await discard()
            throw CancellationError()
        }
    }

    /// Drains the queue and closes the file on the writer queue. The end
    /// time crosses as seconds (plain `Sendable` data).
    private func finishWriting(endingAtSeconds endSeconds: Double?) async throws {
        let outcome: Result<Void, ScreenRecorderError> = await withCheckedContinuation { continuation in
            writerQueue.async { [self] in
                drainOnWriterQueue()
                lock.lock()
                let failure = failureValue
                let first = firstEncodedTime
                let last = lastEncodedTime
                lock.unlock()
                if let failure {
                    continuation.resume(returning: .failure(failure))
                    return
                }
                guard let writer, let input, first.isValid, last.isValid else {
                    continuation.resume(returning: .failure(.noFrames))
                    return
                }
                var end = CMTimeAdd(last, frameDuration)
                if let endSeconds {
                    let requested = CMTime(seconds: endSeconds, preferredTimescale: 600)
                    if CMTimeCompare(requested, end) > 0 {
                        end = requested
                    }
                }
                input.markAsFinished()
                writer.endSession(atSourceTime: end)
                let box = WriterBox(writer)
                writer.finishWriting {
                    let writer = box.writer
                    if writer.status == .completed {
                        continuation.resume(returning: .success(()))
                    } else {
                        continuation.resume(returning: .failure(.writerFailed(
                            writer.error?.localizedDescription
                                ?? "finishWriting ended with status \(writer.status.rawValue)"
                        )))
                    }
                }
            }
        }
        try outcome.get()
    }

    func cancel() async {
        let discardNow: Bool = lock.withLock {
            // After a successful finalize the file is the caller's.
            if isFinalized { return false }
            // `cancelWriting` must not race `finishWriting`: the finalize in
            // progress discards the file when it is done.
            if phase == .finishing {
                cancelRequested = true
                return false
            }
            return true
        }
        if discardNow {
            await discard()
        }
    }

    /// Stops everything and removes the file.
    private func discard() async {
        let released: H264EncoderSession? = lock.withLock {
            phase = .finished
            pending.removeAll()
            defer { encoder = nil }
            return encoder
        }
        // Released outside the lock: the session's teardown flushes frames,
        // and their callbacks take the lock.
        _ = released
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerQueue.async { [self] in
                if let writer, writer.status == .writing {
                    writer.cancelWriting()
                }
                writer = nil
                input = nil
                try? FileManager.default.removeItem(at: outputURL)
                continuation.resume()
            }
        }
    }

    // MARK: Diagnostics

    var recordedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        guard firstEncodedTime.isValid, lastEncodedTime.isValid else { return 0 }
        return CMTimeGetSeconds(CMTimeSubtract(lastEncodedTime, firstEncodedTime))
    }

    var encodedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return encodedCount
    }

    var droppedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedCount
    }

    var canvasSize: CGSize? {
        lock.lock()
        defer { lock.unlock() }
        return canvas.map { CGSize(width: $0.width, height: $0.height) }
    }

    var failure: ScreenRecorderError? {
        lock.lock()
        defer { lock.unlock() }
        return failureValue
    }

    var pendingSampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }
}

/// Carries the writer into `finishWriting`'s completion handler; the writer
/// is only touched there after every other use of it has finished.
private final class WriterBox: @unchecked Sendable {
    let writer: AVAssetWriter

    init(_ writer: AVAssetWriter) {
        self.writer = writer
    }
}

// MARK: - Letterboxing

/// Scales frames of another size into the recording canvas: aspect ratio
/// kept, centered, black bars around. Buffers come from a pool, so a rotated
/// recording does not allocate per frame.
private final class CanvasFitter {
    let width: Int
    let height: Int
    private let pool: CVPixelBufferPool

    init?(width: Int, height: Int) {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            attributes as CFDictionary,
            &pool
        ) == kCVReturnSuccess, let pool else {
            return nil
        }
        self.width = width
        self.height = height
        self.pool = pool
    }

    /// The source letterboxed into a canvas-sized buffer, or nil when the
    /// source is not 32BGRA or a buffer could not be had.
    func fit(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess,
              let output
        else {
            return nil
        }

        let scale = min(Double(width) / Double(sourceWidth), Double(height) / Double(sourceHeight))
        let fittedWidth = min(width, max(1, Int((Double(sourceWidth) * scale).rounded())))
        let fittedHeight = min(height, max(1, Int((Double(sourceHeight) * scale).rounded())))
        let originX = (width - fittedWidth) / 2
        let originY = (height - fittedHeight) / 2

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(output, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let outputBase = CVPixelBufferGetBaseAddress(output)
        else {
            return nil
        }
        let outputRowBytes = CVPixelBufferGetBytesPerRow(output)

        // Opaque black (BGRA 0,0,0,255) everywhere, then the picture.
        let black: [UInt8] = [0, 0, 0, 255]
        black.withUnsafeBytes { pattern in
            memset_pattern4(outputBase, pattern.baseAddress!, outputRowBytes * height)
        }
        var sourceBuffer = vImage_Buffer(
            data: sourceBase,
            height: vImagePixelCount(sourceHeight),
            width: vImagePixelCount(sourceWidth),
            rowBytes: CVPixelBufferGetBytesPerRow(source)
        )
        var destination = vImage_Buffer(
            data: outputBase + originY * outputRowBytes + originX * 4,
            height: vImagePixelCount(fittedHeight),
            width: vImagePixelCount(fittedWidth),
            rowBytes: outputRowBytes
        )
        // Channel order does not matter to a scale: BGRA passes as ARGB.
        let status = vImageScale_ARGB8888(
            &sourceBuffer,
            &destination,
            nil,
            vImage_Flags(kvImageHighQualityResampling)
        )
        return status == kvImageNoError ? output : nil
    }
}
