import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// The encoder plumbing shared by `ReplayBuffer` (an in-memory ring) and
// `ScreenRecorder` (a file on disk): one real-time H.264 compression session,
// the in-flight bookkeeping that lets a caller wait for its callbacks without
// ever blocking the render path, and the sample helpers both muxers need.

/// Encoder parameters derived from the stream: the bitrate assumption is
/// `max(1 Mbps, 0.1 bits/pixel × width × height × fps)`.
struct H264EncoderSettings: Sendable, Equatable {
    let width: Int
    let height: Int
    let targetFPS: Double
    let keyframeIntervalSeconds: Double
    let averageBitRate: Int

    init(
        width: Int,
        height: Int,
        targetFPS: Double,
        keyframeIntervalSeconds: Double,
        averageBitRate: Int? = nil
    ) {
        self.width = width
        self.height = height
        self.targetFPS = targetFPS
        self.keyframeIntervalSeconds = keyframeIntervalSeconds
        self.averageBitRate = averageBitRate
            ?? Self.defaultBitRate(width: width, height: height, targetFPS: targetFPS)
    }

    static func defaultBitRate(width: Int, height: Int, targetFPS: Double) -> Int {
        max(1_000_000, Int((Double(width * height) * targetFPS * 0.1).rounded()))
    }

    /// `1 / targetFPS`, the duration handed to the encoder per frame.
    var frameDuration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(targetFPS.rounded()))
    }

    /// Source pixel buffers in flight to the encoder are capped by count:
    /// `max(2, min(8, 16 MB / (width × height × 4)))`.
    var maxOutstandingFrames: Int {
        max(2, min(8, 16_000_000 / max(1, width * height * 4)))
    }
}

/// One real-time H.264 `VTCompressionSession` for 32BGRA frames (Main
/// profile, no frame reordering, forced keyframes on request). Encoded
/// samples arrive on VideoToolbox's thread through `output`. Submissions are
/// serialized; the output callback never runs under the submission lock, so
/// a slow consumer can never block `encode`.
final class H264EncoderSession: @unchecked Sendable {
    typealias Output = @Sendable (
        _ sampleBuffer: CMSampleBuffer?,
        _ status: OSStatus,
        _ flags: VTEncodeInfoFlags
    ) -> Void

    /// A replacement for `encode`'s VideoToolbox submission, injectable by
    /// tests. A hook that returns `noErr` without ever invoking the output
    /// callback models a stalled encoder.
    typealias SubmissionHook = @Sendable (
        _ session: VTCompressionSession,
        _ pixelBuffer: CVPixelBuffer,
        _ presentationTimeStamp: CMTime,
        _ frameProperties: CFDictionary?
    ) -> OSStatus

    let settings: H264EncoderSettings
    let session: VTCompressionSession
    private let contextRetainer: Unmanaged<OutputContext>
    private let submissionLock = NSLock()

    /// Throws a readable reason when VideoToolbox refuses the session.
    init(settings: H264EncoderSettings, output: @escaping Output) throws {
        self.settings = settings
        let retainer = Unmanaged.passRetained(OutputContext(output: output))
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(settings.width),
            height: Int32(settings.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: h264EncoderOutputCallback,
            refcon: retainer.toOpaque(),
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            retainer.release()
            throw H264EncoderSessionError(reason: "VTCompressionSessionCreate failed with status \(status)")
        }
        self.session = created
        self.contextRetainer = retainer
        Self.configure(created, settings: settings)
        VTCompressionSessionPrepareToEncodeFrames(created)
    }

    deinit {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        contextRetainer.release()
    }

    /// The frame properties for one submission: a forced keyframe or none.
    static func frameProperties(forceKeyframe: Bool) -> CFDictionary? {
        forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
    }

    /// Submits one frame. The result arrives through `output` (exactly once
    /// per `noErr` submission, possibly with `.frameDropped`).
    func encode(
        _ pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime,
        frameProperties: CFDictionary?
    ) -> OSStatus {
        submissionLock.lock()
        defer { submissionLock.unlock() }
        return VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: settings.frameDuration,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    /// Emits every pending frame (blocking until VideoToolbox has called back
    /// for each). Call it off the render path, before a final drain.
    func completeFrames() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    private static func configure(_ session: VTCompressionSession, settings: H264EncoderSettings) {
        let keyframeFrameCount = max(
            1,
            Int((settings.targetFPS * settings.keyframeIntervalSeconds).rounded())
        )
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_Main_AutoLevel
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanFalse
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: keyframeFrameCount as CFNumber
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: settings.keyframeIntervalSeconds as CFNumber
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: settings.targetFPS as CFNumber
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: settings.averageBitRate as CFNumber
        )
    }
}

struct H264EncoderSessionError: Error, CustomStringConvertible {
    let reason: String
    var description: String { reason }
}

private final class OutputContext: @unchecked Sendable {
    let output: H264EncoderSession.Output

    init(output: @escaping H264EncoderSession.Output) {
        self.output = output
    }
}

private func h264EncoderOutputCallback(
    refcon: UnsafeMutableRawPointer?,
    sourceFrameRefcon: UnsafeMutableRawPointer?,
    status: OSStatus,
    flags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let refcon else { return }
    Unmanaged<OutputContext>.fromOpaque(refcon).takeUnretainedValue()
        .output(sampleBuffer, status, flags)
}

// MARK: - In-flight tracking

/// Counts encoder submissions awaiting their callback, capped at `limit`,
/// and lets a caller wait (bounded by a timeout, or cancelled) until none
/// remain. `tryAcquire` never blocks: a saturated encoder drops the incoming
/// frame instead of stalling the caller.
final class EncoderInFlightTracker: @unchecked Sendable {
    let limit: Int
    private let lock = NSLock()
    private var inFlight = 0
    private var waiters: [IdleWaiter] = []

    init(limit: Int) {
        self.limit = limit
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlight
    }

    /// Reserves one slot; false when `limit` submissions are outstanding.
    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight < limit else { return false }
        inFlight += 1
        return true
    }

    /// Frees one slot (a callback arrived, or the submission failed) and
    /// wakes the waiters once nothing is outstanding.
    func release() {
        lock.lock()
        inFlight = max(0, inFlight - 1)
        let ready: [IdleWaiter]
        if inFlight == 0 {
            ready = waiters
            waiters.removeAll()
        } else {
            ready = []
        }
        lock.unlock()
        for waiter in ready {
            waiter.finish(with: .success(()))
        }
    }

    /// Waits until no submission is outstanding. Throws `timeoutError` when
    /// the callbacks do not drain within `timeout` (a stalled encoder must
    /// not hang its caller) and `CancellationError` when the task is
    /// cancelled.
    func waitUntilIdle(timeout: Duration, timeoutError: any Error & Sendable) async throws {
        let waiter = IdleWaiter()
        let alreadyIdle: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if inFlight == 0 { return true }
            waiters.append(waiter)
            return false
        }()
        if alreadyIdle { return }

        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            waiter.finish(with: .failure(timeoutError))
            self.discard(waiter)
        }
        defer { timeoutTask.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.attach(continuation)
            }
        } onCancel: {
            waiter.finish(with: .failure(CancellationError()))
            self.discard(waiter)
        }
    }

    private func discard(_ waiter: IdleWaiter) {
        lock.lock()
        waiters.removeAll { $0 === waiter }
        lock.unlock()
    }
}

/// A one-shot continuation that can be finished by either the encoder going
/// idle, a timeout, or task cancellation — whichever comes first.
private final class IdleWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(with result: Result<Void, Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else if self.result == nil {
            self.result = result
            lock.unlock()
        } else {
            lock.unlock()
        }
    }
}

// MARK: - Sample helpers

enum EncodedSamples {
    /// Whether an encoded sample is a sync sample (keyframe); samples without
    /// attachments are.
    static func isSyncSample(_ sample: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample,
                createIfNecessary: false
            ) as? [[CFString: Any]],
            let first = attachments.first
        else { return true }
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        return true
    }

    /// `sample` with a positive duration: `AVAssetWriter` needs one, and
    /// encoder output can carry an invalid or zero duration.
    static func withValidDuration(_ sample: CMSampleBuffer, fallback: CMTime) -> CMSampleBuffer {
        let duration = CMSampleBufferGetDuration(sample)
        guard !duration.isValid || CMTimeCompare(duration, .zero) <= 0 else { return sample }
        let timing = CMSampleTimingInfo(
            duration: fallback,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
            decodeTimeStamp: .invalid
        )
        var output: CMSampleBuffer?
        let status = withUnsafePointer(to: timing) { pointer in
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sample,
                sampleTimingEntryCount: 1,
                sampleTimingArray: pointer,
                sampleBufferOut: &output
            )
        }
        guard status == noErr, let output else { return sample }
        return output
    }
}
