import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Errors thrown by ``ReplayBuffer``.
public enum ReplayBufferError: Error, Equatable, CustomStringConvertible {
    /// `saveClip` was called before any frame had been retained.
    case emptyBuffer
    /// The underlying `VTCompressionSession` could not be created or failed.
    case encoderUnavailable(String)
    /// The destination directory could not be prepared or written to.
    case directoryUnavailable(String)
    /// `AVAssetWriter` refused to mux the retained samples.
    case writerFailed(String)
    /// `saveClip` waited for in-flight encoder callbacks past its idle timeout.
    case encoderTimeout

    public var description: String {
        switch self {
        case .emptyBuffer:
            return "no replay frames have been retained"
        case .encoderUnavailable(let reason):
            return "replay encoder unavailable: \(reason)"
        case .directoryUnavailable(let reason):
            return "replay destination unavailable: \(reason)"
        case .writerFailed(let reason):
            return "could not write the replay clip: \(reason)"
        case .encoderTimeout:
            return "the replay encoder did not finish in time"
        }
    }
}

/// A bounded, in-memory rolling window of the most recent H.264-encoded frames.
///
/// `ReplayBuffer` ingests `CVPixelBuffer`s from the mirror pipeline, encodes them
/// with a real-time `VTCompressionSession` (H.264, no frame reordering) and keeps
/// the encoded samples of the last `windowSeconds` in memory, subject to the byte
/// budget below. `saveClip(to:)`
/// muxes the retained samples into an MP4 with `AVAssetWriter` without
/// re-encoding. The buffer is UI-free and safe to feed from the render path:
/// `ingest` never waits on the encoder.
///
/// ## Memory bound
///
/// ``memoryBoundBytes`` is the enforced byte budget for the encoded ring. By
/// default it is `averageBitRate × windowSeconds / 8 × 1.25` (25% headroom for
/// rate-control variance and per-sample overhead), where
/// `averageBitRate = max(1 Mbps, 0.1 bits/pixel × width × height × targetFPS)`;
/// callers may pass their own budget to `init`. After every append the ring
/// evicts the oldest keyframe-aligned segment(s) until
/// ``retainedByteCount`` fits the budget, so retention can fall below
/// `windowSeconds` on incompressible content but the retained encoded bytes
/// never exceed the bound. When the newest segment alone is over budget it is
/// dropped rather than kept over the bound.
///
/// Source pixel buffers in flight to the encoder are a separate, count-based
/// cap: `maxOutstandingFrames = max(2, min(8, 16 MB / (width × height × 4)))`,
/// so up to 8 are in flight and the floor of 2 means very large frames can put
/// roughly `2 × width × height × 4` bytes (≈ 28 MB at 2560×1440) in flight.
///
/// ## Frame flow
///
/// Frames are accepted only when they advance the presentation clock and arrive
/// at least 90% of a `1 / targetFPS` interval after the previous accepted frame.
/// Keyframes are forced at least every `keyframeIntervalSeconds` (0.5–2 s), so
/// eviction can always trim the oldest segment to a keyframe. When the encoder is
/// saturated (`maxOutstandingFrames` frames awaiting callbacks), when a frame is
/// stale or paced out, or when VideoToolbox rejects it, the *incoming* frame is
/// dropped and counted in ``droppedFrameCount`` instead of blocking the caller.
///
/// Timestamps are expected to advance monotonically across a ``reset()``.
public actor ReplayBuffer {
    private let state: ReplayState

    /// Creates a replay buffer. `memoryBoundBytes` overrides the derived encoded
    /// byte budget (see "Memory bound" above); `nil` derives it from the window
    /// and bitrate assumption.
    public init(
        windowSeconds: Double,
        targetFPS: Double,
        width: Int,
        height: Int,
        memoryBoundBytes: Int? = nil
    ) {
        self.state = ReplayState(
            windowSeconds: windowSeconds,
            targetFPS: targetFPS,
            width: width,
            height: height,
            memoryBoundBytes: memoryBoundBytes
        )
    }

    /// Test seam: injects the encoder submission (or a stall) and the idle
    /// timeout used by ``saveClip(to:)``.
    init(
        windowSeconds: Double,
        targetFPS: Double,
        width: Int,
        height: Int,
        memoryBoundBytes: Int? = nil,
        idleTimeout: Duration,
        frameEncoder: @escaping ReplayState.FrameEncoder
    ) {
        self.state = ReplayState(
            windowSeconds: windowSeconds,
            targetFPS: targetFPS,
            width: width,
            height: height,
            memoryBoundBytes: memoryBoundBytes,
            idleTimeout: idleTimeout,
            frameEncoder: frameEncoder
        )
    }

    /// Submits one frame from the mirror pipeline. Never blocks: the frame is
    /// dropped and counted when the encoder is behind.
    public nonisolated func ingest(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        state.ingest(pixelBuffer, at: time)
    }

    /// Writes the retained window to a unique `.mp4` in `directory` (creating the
    /// directory when needed) and returns the file URL. Throws
    /// ``ReplayBufferError/emptyBuffer`` when no frames are retained and
    /// ``ReplayBufferError/encoderTimeout`` when in-flight encoder callbacks do
    /// not drain within the idle timeout.
    public func saveClip(to directory: URL) async throws -> URL {
        try await state.waitUntilIdle()
        let samples = state.snapshotSamples()
        guard let firstSample = samples.first else {
            if let reason = state.encoderError {
                throw ReplayBufferError.encoderUnavailable(reason)
            }
            throw ReplayBufferError.emptyBuffer
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ReplayBufferError.directoryUnavailable("\(directory.path) is not a directory")
            }
        } else {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw ReplayBufferError.directoryUnavailable(error.localizedDescription)
            }
        }

        let temporaryURL = directory.appendingPathComponent(".replay-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try await mux(
            samples,
            from: CMSampleBufferGetPresentationTimeStamp(firstSample),
            to: temporaryURL
        )

        let clipURL = uniqueClipURL(in: directory)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: clipURL)
        } catch {
            throw ReplayBufferError.directoryUnavailable(error.localizedDescription)
        }
        return clipURL
    }

    private func mux(_ samples: [CMSampleBuffer], from startTime: CMTime, to url: URL) async throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(samples[0]) else {
            throw ReplayBufferError.writerFailed("retained samples have no format description")
        }
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw ReplayBufferError.writerFailed(error.localizedDescription)
        }

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw ReplayBufferError.writerFailed("the writer rejected the video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw ReplayBufferError.writerFailed(
                writer.error?.localizedDescription ?? "startWriting failed"
            )
        }
        writer.startSession(atSourceTime: startTime)

        for sample in samples {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else {
                    throw ReplayBufferError.writerFailed(
                        writer.error?.localizedDescription ?? "the writer stopped mid-clip"
                    )
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            let prepared = EncodedSamples.withValidDuration(sample, fallback: state.frameDuration)
            guard input.append(prepared) else {
                throw ReplayBufferError.writerFailed(
                    writer.error?.localizedDescription ?? "appending a sample failed"
                )
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ReplayBufferError.writerFailed(
                writer.error?.localizedDescription ?? "finishWriting ended with status \(writer.status.rawValue)"
            )
        }
    }

    private nonisolated func uniqueClipURL(in directory: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var candidate = directory.appendingPathComponent("Replay-\(stamp).mp4")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("Replay-\(stamp)-\(suffix).mp4")
            suffix += 1
        }
        return candidate
    }

    /// Media-time span between the oldest and newest retained samples, excluding
    /// the last sample's duration; `saveClip` output is ≈ this plus one frame.
    public nonisolated var retainedSeconds: Double { state.retainedSeconds }

    /// Number of encoded frames currently retained.
    public nonisolated var retainedFrameCount: Int { state.retainedFrameCount }

    /// Actual encoded bytes currently retained; diagnostics-only.
    public nonisolated var retainedByteCount: Int { state.retainedByteCount }

    /// Frames dropped since `init` (or `reset`): saturated encoder, stale or
    /// paced-out timestamps, and VideoToolbox rejections.
    public nonisolated var droppedFrameCount: Int { state.droppedFrameCount }

    /// Total frames appended to the ring since `init` (or `reset`); diagnostics-only.
    public nonisolated var encodedFrameCount: Int { state.encodedFrameCount }

    /// Documented upper bound for the retained encoded bytes (see ``ReplayBuffer``).
    public nonisolated var memoryBoundBytes: Int { state.memoryBoundBytes }

    /// Drops all retained frames and diagnostics. Frames submitted before the
    /// reset are ignored when their callbacks arrive; timestamps must continue to
    /// advance monotonically.
    public func reset() {
        state.reset()
    }
}

// MARK: - Ring storage

private struct EncodedSample {
    let sample: CMSampleBuffer
    let isKeyframe: Bool
    let presentationTimeStamp: CMTime
    let byteCount: Int
}

private struct ReplaySegment {
    var startTime: CMTime
    var samples: [EncodedSample] = []
}

// MARK: - State

final class ReplayState: @unchecked Sendable {
    /// Submission of one frame to VideoToolbox; injectable for tests. A hook
    /// that returns `noErr` without ever invoking the output callback models a
    /// stalled encoder.
    typealias FrameEncoder = H264EncoderSession.SubmissionHook

    static let defaultIdleTimeout: Duration = .seconds(5)

    let windowSeconds: Double
    let targetFPS: Double
    let frameDuration: CMTime
    let keyframeIntervalSeconds: Double
    let segmentDurationSeconds: Double
    let averageBitRate: Int
    let memoryBoundBytes: Int
    let maxOutstandingFrames: Int
    let idleTimeout: Duration
    private let frameEncoder: FrameEncoder?

    private let minFrameInterval: CMTime
    private let stateLock = NSLock()
    /// Serializes the injected `frameEncoder` like the real session's own
    /// submission lock does.
    private let hookLock = NSLock()
    private var encoder: H264EncoderSession?
    private let inFlight: EncoderInFlightTracker
    private var segments: [ReplaySegment] = []
    private var encodedFrameCountValue = 0
    private var droppedFrameCountValue = 0
    private var retainedByteCountValue = 0
    private var lastAcceptedTime: CMTime = .invalid
    private var lastKeyframeTime: CMTime = .invalid
    private var resetFloor: CMTime = .invalid
    private var lastError: String?

    init(
        windowSeconds: Double,
        targetFPS: Double,
        width: Int,
        height: Int,
        memoryBoundBytes: Int? = nil,
        idleTimeout: Duration = ReplayState.defaultIdleTimeout,
        frameEncoder: FrameEncoder? = nil
    ) {
        precondition(windowSeconds > 0, "windowSeconds must be positive")
        precondition(targetFPS > 0, "targetFPS must be positive")
        precondition(width > 0 && height > 0, "dimensions must be positive")
        if let memoryBoundBytes {
            precondition(memoryBoundBytes > 0, "memoryBoundBytes must be positive")
        }
        let settings = H264EncoderSettings(
            width: width,
            height: height,
            targetFPS: targetFPS,
            keyframeIntervalSeconds: min(2.0, max(0.5, windowSeconds / 30))
        )
        self.windowSeconds = windowSeconds
        self.targetFPS = targetFPS
        self.frameDuration = settings.frameDuration
        self.minFrameInterval = CMTimeMultiplyByFloat64(frameDuration, multiplier: 0.9)
        self.keyframeIntervalSeconds = settings.keyframeIntervalSeconds
        self.segmentDurationSeconds = 2.0
        self.averageBitRate = settings.averageBitRate
        self.memoryBoundBytes =
            memoryBoundBytes ?? Int(Double(settings.averageBitRate) * windowSeconds / 8.0 * 1.25)
        self.maxOutstandingFrames = settings.maxOutstandingFrames
        self.inFlight = EncoderInFlightTracker(limit: settings.maxOutstandingFrames)
        self.idleTimeout = idleTimeout
        self.frameEncoder = frameEncoder

        do {
            encoder = try H264EncoderSession(settings: settings) { [weak self] sample, status, flags in
                self?.didEncode(sample, status: status, flags: flags)
            }
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: Ingest

    func ingest(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        stateLock.lock()
        guard let encoder, time.isValid, time.isNumeric else {
            droppedFrameCountValue += 1
            stateLock.unlock()
            return
        }
        if lastAcceptedTime.isValid {
            guard CMTimeCompare(time, lastAcceptedTime) > 0 else {
                droppedFrameCountValue += 1
                stateLock.unlock()
                return
            }
            guard CMTimeCompare(CMTimeSubtract(time, lastAcceptedTime), minFrameInterval) >= 0 else {
                droppedFrameCountValue += 1
                stateLock.unlock()
                return
            }
        }
        // Saturated: the incoming frame is dropped, the caller never waits.
        guard inFlight.tryAcquire() else {
            droppedFrameCountValue += 1
            stateLock.unlock()
            return
        }

        lastAcceptedTime = time
        let forceKeyframe = !lastKeyframeTime.isValid
            || CMTimeGetSeconds(CMTimeSubtract(time, lastKeyframeTime)) >= keyframeIntervalSeconds
        if forceKeyframe {
            lastKeyframeTime = time
        }
        stateLock.unlock()

        let frameProperties = H264EncoderSession.frameProperties(forceKeyframe: forceKeyframe)
        let status: OSStatus
        if let frameEncoder {
            hookLock.lock()
            status = frameEncoder(encoder.session, pixelBuffer, time, frameProperties)
            hookLock.unlock()
        } else {
            status = encoder.encode(pixelBuffer, presentationTimeStamp: time, frameProperties: frameProperties)
        }

        if status != noErr {
            stateLock.lock()
            droppedFrameCountValue += 1
            lastError = "VTCompressionSessionEncodeFrame failed with status \(status)"
            stateLock.unlock()
            inFlight.release()
        }
    }

    func didEncode(_ sampleBuffer: CMSampleBuffer?, status: OSStatus, flags: VTEncodeInfoFlags) {
        stateLock.lock()
        if status == noErr, !flags.contains(.frameDropped), let sampleBuffer {
            if resetFloor.isValid,
                CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), resetFloor) <= 0
            {
                // A frame submitted before `reset()`; the ring has moved on.
            } else {
                append(sampleBuffer)
                encodedFrameCountValue += 1
            }
        } else {
            droppedFrameCountValue += 1
            if status != noErr {
                lastError = "encoder callback failed with status \(status)"
            }
        }
        stateLock.unlock()
        // After the append, so an idle waiter always sees the sample.
        inFlight.release()
    }


    private func append(_ sample: CMSampleBuffer) {
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        let byteCount = CMSampleBufferGetTotalSampleSize(sample)
        let isKeyframe = EncodedSamples.isSyncSample(sample)

        if segments.isEmpty
            || (isKeyframe
                && CMTimeGetSeconds(CMTimeSubtract(time, segments[segments.count - 1].startTime))
                    >= segmentDurationSeconds)
        {
            segments.append(ReplaySegment(startTime: time))
        }
        segments[segments.count - 1].samples.append(
            EncodedSample(
                sample: sample,
                isKeyframe: isKeyframe,
                presentationTimeStamp: time,
                byteCount: byteCount
            )
        )
        retainedByteCountValue += byteCount
        evict(before: CMTimeSubtract(time, CMTime(seconds: windowSeconds, preferredTimescale: 600)))
        evictForMemoryBound()
    }

    /// Drops everything older than `cutoff`, keeping whole segments when possible
    /// and trimming the leading samples of the oldest segment to the first
    /// keyframe at or after the cutoff so the clip can always start decoding.
    private func evict(before cutoff: CMTime) {
        while let first = segments.first {
            guard let firstSample = first.samples.first, let lastSample = first.samples.last else {
                removeFirstSegment()
                continue
            }
            if segments.count > 1, CMTimeCompare(lastSample.presentationTimeStamp, cutoff) <= 0 {
                removeFirstSegment()
                continue
            }
            if CMTimeCompare(firstSample.presentationTimeStamp, cutoff) < 0 {
                if let index = first.samples.firstIndex(where: {
                    $0.isKeyframe && CMTimeCompare($0.presentationTimeStamp, cutoff) >= 0
                }) {
                    trimFirstSegment(to: index)
                    return
                } else if segments.count > 1 {
                    removeFirstSegment()
                    continue
                }
            }
            return
        }
    }

    private func removeFirstSegment() {
        guard !segments.isEmpty else { return }
        retainedByteCountValue -= segments[0].samples.reduce(0) { $0 + $1.byteCount }
        segments.removeFirst()
    }

    private func trimFirstSegment(to index: Int) {
        guard !segments.isEmpty, index > 0 else { return }
        let removed = segments[0].samples.prefix(index)
        retainedByteCountValue -= removed.reduce(0) { $0 + $1.byteCount }
        segments[0].samples.removeFirst(index)
        if let first = segments[0].samples.first {
            segments[0].startTime = first.presentationTimeStamp
        }
    }

    /// Enforces the encoded-byte budget: drops whole oldest segments while
    /// `segments.count > 1`, then trims the surviving segment to its next
    /// keyframe. If even the newest keyframe-aligned GOP is over budget it is
    /// dropped too, so `retainedByteCountValue` never exceeds the bound.
    private func evictForMemoryBound() {
        while retainedByteCountValue > memoryBoundBytes {
            guard !segments.isEmpty else { return }
            if segments.count > 1 {
                removeFirstSegment()
                continue
            }
            if let nextKeyframe = segments[0].samples.dropFirst().firstIndex(where: {
                $0.isKeyframe
            }) {
                trimFirstSegment(to: nextKeyframe)
                continue
            }
            removeFirstSegment()
        }
    }

    // MARK: Diagnostics

    var retainedSeconds: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let first = segments.first, let last = segments.last?.samples.last else { return 0 }
        return CMTimeGetSeconds(CMTimeSubtract(last.presentationTimeStamp, first.startTime))
    }

    var retainedFrameCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return segments.reduce(0) { $0 + $1.samples.count }
    }

    var retainedByteCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return retainedByteCountValue
    }

    var droppedFrameCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return droppedFrameCountValue
    }

    var encodedFrameCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return encodedFrameCountValue
    }

    var encoderError: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastError
    }

    func snapshotSamples() -> [CMSampleBuffer] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return segments.flatMap { $0.samples.map(\.sample) }
    }

    // MARK: Reset

    func reset() {
        stateLock.lock()
        if lastAcceptedTime.isValid {
            resetFloor = lastAcceptedTime
        }
        segments.removeAll()
        retainedByteCountValue = 0
        encodedFrameCountValue = 0
        droppedFrameCountValue = 0
        lastKeyframeTime = .invalid
        stateLock.unlock()
    }

    // MARK: Idle

    /// Waits until no encodes are in flight. Bounded by ``idleTimeout`` so a
    /// VideoToolbox callback that never fires fails `saveClip` with
    /// ``ReplayBufferError/encoderTimeout`` instead of hanging it. Task
    /// cancellation also resumes the wait (with `CancellationError`).
    func waitUntilIdle() async throws {
        try await inFlight.waitUntilIdle(
            timeout: idleTimeout,
            timeoutError: ReplayBufferError.encoderTimeout
        )
    }
}
