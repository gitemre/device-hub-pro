import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// H.264 helpers for the scrcpy video stream.
///
/// scrcpy frames its packets in Annex-B form: parameter sets and encoded
/// pictures are preceded by 3- or 4-byte start codes. VideoToolbox's
/// `CMVideoFormatDescriptionCreateFromH264ParameterSets` and its
/// `AVCC`-style sample buffers instead want parameter sets as raw NAL units
/// and pictures as length-prefixed NAL units, so both directions are pure
/// transforms (unit-tested in `ScrcpyVideoDecoderTests`).
public enum ScrcpyH264 {
    /// The four-character codec id the server announces for AVC ("h264").
    public static let codecID: UInt32 = 0x6832_3634
    static let parameterSetSPS: UInt8 = 7
    static let parameterSetPPS: UInt8 = 8

    /// Splits an Annex-B payload into NAL units (start codes removed, trailing
    /// zero padding trimmed). A payload without any start code is returned as
    /// a single NAL unit, so a mis-framed packet fails in VideoToolbox instead
    /// of silently decoding nothing.
    public static func nalUnits(in data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }

        var units: [Data] = []
        var unitStart = data.startIndex
        var hasStartCode = false
        var index = data.startIndex

        while index < data.endIndex {
            guard index + 2 < data.endIndex,
                  data[index] == 0,
                  data[index + 1] == 0,
                  data[index + 2] == 1
            else {
                index += 1
                continue
            }
            if hasStartCode {
                let unit = trimmedTrailingZeros(data[unitStart..<index])
                if !unit.isEmpty { units.append(unit) }
            }
            hasStartCode = true
            index += 3
            unitStart = index
        }

        guard hasStartCode else { return [data] }
        let unit = trimmedTrailingZeros(data[unitStart..<data.endIndex])
        if !unit.isEmpty { units.append(unit) }
        return units
    }

    /// One encoded picture as an AVCC sample: each NAL unit prefixed with its
    /// 4-byte big-endian length, which is the form a `CMSampleBuffer` built
    /// against an H.264 format description expects.
    public static func avccSample(fromAnnexB data: Data) -> Data {
        var sample = Data(capacity: data.count + 16)
        for unit in nalUnits(in: data) {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { sample.append(contentsOf: $0) }
            sample.append(unit)
        }
        return sample
    }

    /// The SPS/PPS NAL units carried by a config packet, in wire order. Other
    /// NAL units (SEI, in-band parameter sets on old servers) are dropped.
    public static func parameterSets(fromConfigPacket data: Data) -> [Data] {
        nalUnits(in: data).filter { unit in
            guard let header = unit.first else { return false }
            let type = header & 0x1F
            return type == parameterSetSPS || type == parameterSetPPS
        }
    }

    private static func trimmedTrailingZeros(_ slice: Data) -> Data {
        var end = slice.endIndex
        while end > slice.startIndex, slice[end - 1] == 0 {
            end -= 1
        }
        return Data(slice[slice.startIndex..<end])
    }
}

/// One decoded video frame: the VideoToolbox pixel buffer (BGRA) and the
/// device presentation timestamp (microseconds, as received on the wire).
public struct ScrcpyDecodedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let pts: Int64
    public let isKeyFrame: Bool

    public init(pixelBuffer: CVPixelBuffer, pts: Int64, isKeyFrame: Bool) {
        self.pixelBuffer = pixelBuffer
        self.pts = pts
        self.isKeyFrame = isKeyFrame
    }
}

public enum ScrcpyVideoDecoderError: Error, Equatable, CustomStringConvertible {
    /// The config packet carried no SPS/PPS pair.
    case missingParameterSets
    case formatDescriptionCreationFailed(OSStatus)
    case decompressionSessionCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    /// `VTDecompressionSessionDecodeFrame` refused the frame synchronously.
    case decodeFrameSubmissionFailed(OSStatus)
    /// VideoToolbox reported a failure from its asynchronous decode callback.
    case asynchronousDecodeFailed(OSStatus)
    case unsupportedCodec(UInt32)

    public var description: String {
        switch self {
        case .missingParameterSets:
            return "the scrcpy config packet carries no SPS/PPS"
        case .formatDescriptionCreationFailed(let status):
            return "CMVideoFormatDescriptionCreateFromH264ParameterSets failed (\(status))"
        case .decompressionSessionCreationFailed(let status):
            return "VTDecompressionSessionCreate failed (\(status))"
        case .sampleBufferCreationFailed(let status):
            return "CMSampleBufferCreateReady failed (\(status))"
        case .decodeFrameSubmissionFailed(let status):
            return "VTDecompressionSessionDecodeFrame failed (\(status))"
        case .asynchronousDecodeFailed(let status):
            return "an asynchronous VideoToolbox decode failed (\(status))"
        case .unsupportedCodec(let codecID):
            let fourCC = String(
                bytes: [
                    UInt8(truncatingIfNeeded: codecID >> 24),
                    UInt8(truncatingIfNeeded: codecID >> 16),
                    UInt8(truncatingIfNeeded: codecID >> 8),
                    UInt8(truncatingIfNeeded: codecID),
                ],
                encoding: .ascii
            ) ?? "?"
            return "unsupported scrcpy video codec '\(fourCC)' (only h264 is supported)"
        }
    }
}

/// Decodes the scrcpy H.264 stream with VideoToolbox.
///
/// Feed packets in arrival order. The first config packet builds the format
/// description and the decompression session; later config packets (a device
/// rotation or resolution change) rebuild both. Frames are delivered through
/// ``onFrame`` on a VideoToolbox callback thread; async decode failures are
/// delivered through ``onError``. ``decode(_:)`` throws only for local
/// failures (missing parameter sets, session creation, submission).
///
/// All entry points are lock-protected; the intended use is one producing
/// queue, as ``PhysicalMirrorSession`` does with its serial reader queue.
///
/// No VideoToolbox teardown ever runs on the caller's thread or under
/// `lock`. `VTDecompressionSessionInvalidate` waits for the session's
/// in-flight output callbacks, so invalidating a session from inside its own
/// output handler never returns, and invalidating it while holding a lock
/// that handler takes deadlocks. ``invalidate()`` may therefore be called
/// from anywhere, including ``onFrame``/``onError``: retired sessions are
/// invalidated on a private queue.
public final class ScrcpyVideoDecoder: @unchecked Sendable {
    /// Called for every decoded frame, in decode order.
    public var onFrame: (@Sendable (ScrcpyDecodedFrame) -> Void)?
    /// Called when VideoToolbox reports an asynchronous decode failure. Runs
    /// on a VideoToolbox callback thread; nothing is delivered after
    /// ``invalidate()``.
    public var onError: (@Sendable (Error) -> Void)?

    /// Where retired sessions are invalidated (see the type comment).
    private static let teardownQueue = DispatchQueue(
        label: "com.devicehubpro.scrcpy.decoder-teardown"
    )

    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private var parameterSets: [Data] = []
    private var width = 0
    private var height = 0
    private var invalidated = false

    public init() {}

    deinit {
        invalidate()
    }

    /// The decoded picture size, once a config packet has been processed.
    public var dimensions: (width: Int, height: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// Decodes one scrcpy packet. Config packets update the decoder's
    /// parameter sets; picture packets are submitted for async decode.
    public func decode(_ packet: FramePacket) throws {
        if packet.isConfig {
            try configure(withConfigPacket: packet.payload)
        } else {
            try submit(packet)
        }
    }

    /// Tears the decompression session down. Safe to call repeatedly and
    /// from any thread, including a decode callback: it never waits for
    /// VideoToolbox (the session is invalidated on a private queue), and no
    /// callback is forwarded once it returns.
    public func invalidate() {
        lock.lock()
        let session = self.session
        self.session = nil
        formatDescription = nil
        parameterSets = []
        width = 0
        height = 0
        invalidated = true
        lock.unlock()

        if let session {
            Self.retire(session, flushingFrames: false)
        }
    }

    /// Invalidates `session` on the teardown queue. `flushingFrames` first
    /// lets its pending pictures reach ``onFrame`` (a reconfiguration keeps
    /// them; a teardown drops them).
    private static func retire(_ session: VTDecompressionSession, flushingFrames: Bool) {
        let retired = RetiredSession(session)
        teardownQueue.async {
            if flushingFrames {
                VTDecompressionSessionWaitForAsynchronousFrames(retired.session)
            }
            VTDecompressionSessionInvalidate(retired.session)
        }
    }

    // MARK: - Configuration

    private func configure(withConfigPacket payload: Data) throws {
        let sets = ScrcpyH264.parameterSets(fromConfigPacket: payload)
        let hasSPS = sets.contains { ($0.first ?? 0) & 0x1F == ScrcpyH264.parameterSetSPS }
        let hasPPS = sets.contains { ($0.first ?? 0) & 0x1F == ScrcpyH264.parameterSetPPS }
        guard hasSPS, hasPPS else {
            throw ScrcpyVideoDecoderError.missingParameterSets
        }

        lock.lock()
        let unchanged = invalidated || (sets == parameterSets && session != nil)
        lock.unlock()
        guard !unchanged else { return }

        let format = try Self.makeFormatDescription(parameterSets: sets)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let newSession = try Self.makeDecompressionSession(format: format)

        lock.lock()
        guard !invalidated else {
            lock.unlock()
            Self.retire(newSession, flushingFrames: false)
            return
        }
        let oldSession = session
        session = newSession
        formatDescription = format
        parameterSets = sets
        width = Int(dimensions.width)
        height = Int(dimensions.height)
        lock.unlock()

        // Outside the lock: the old session's pending callbacks take it. The
        // pictures it still owes (the last frames before a rotation) reach
        // `onFrame` before it is invalidated.
        if let oldSession {
            Self.retire(oldSession, flushingFrames: true)
        }
    }

    private static func makeFormatDescription(
        parameterSets: [Data]
    ) throws -> CMFormatDescription {
        var pointers: [UnsafeMutablePointer<UInt8>] = []
        for set in parameterSets {
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            set.copyBytes(to: pointer, count: set.count)
            pointers.append(pointer)
        }
        defer { pointers.forEach { $0.deallocate() } }

        let sizes = parameterSets.map(\.count)
        var format: CMFormatDescription?
        let status = pointers.withUnsafeBufferPointer { pointerBuffer -> OSStatus in
            pointerBuffer.baseAddress!.withMemoryRebound(
                to: UnsafePointer<UInt8>.self,
                capacity: pointerBuffer.count
            ) { rebound in
                sizes.withUnsafeBufferPointer { sizeBuffer -> OSStatus in
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: parameterSets.count,
                        parameterSetPointers: rebound,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &format
                    )
                }
            }
        }
        guard status == noErr, let format else {
            throw ScrcpyVideoDecoderError.formatDescriptionCreationFailed(status)
        }
        return format
    }

    private static func makeDecompressionSession(
        format: CMFormatDescription
    ) throws -> VTDecompressionSession {
        let decoderSpecification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true
        ]
        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: imageAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw ScrcpyVideoDecoderError.decompressionSessionCreationFailed(status)
        }
        return session
    }

    // MARK: - Decode

    private func submit(_ packet: FramePacket) throws {
        lock.lock()
        let session = self.session
        let format = self.formatDescription
        lock.unlock()

        // A frame before the first config packet cannot be decoded; the server
        // always sends config first, so this is a teardown-worthy stream
        // inconsistency rather than a normal state.
        guard let session, let format else {
            throw ScrcpyVideoDecoderError.missingParameterSets
        }

        let avcc = ScrcpyH264.avccSample(fromAnnexB: packet.payload)
        guard !avcc.isEmpty else { return }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw ScrcpyVideoDecoderError.sampleBufferCreationFailed(blockStatus)
        }

        let copyStatus = avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw ScrcpyVideoDecoderError.sampleBufferCreationFailed(copyStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: packet.pts, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw ScrcpyVideoDecoderError.sampleBufferCreationFailed(sampleStatus)
        }

        let pts = packet.pts
        let isKeyFrame = packet.isKeyFrame
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil
        ) { [weak self] status, flags, imageBuffer, _, _ in
            self?.didDecode(
                status: status,
                flags: flags,
                imageBuffer: imageBuffer,
                pts: pts,
                isKeyFrame: isKeyFrame
            )
        }
        guard status == noErr else {
            throw ScrcpyVideoDecoderError.decodeFrameSubmissionFailed(status)
        }
    }

    private func didDecode(
        status: OSStatus,
        flags: VTDecodeInfoFlags,
        imageBuffer: CVImageBuffer?,
        pts: Int64,
        isKeyFrame: Bool
    ) {
        // Callbacks can still arrive while a retired session drains on the
        // teardown queue; a torn-down decoder forwards none of them.
        lock.lock()
        let isInvalidated = invalidated
        lock.unlock()
        guard !isInvalidated else { return }

        if status != noErr {
            onError?(ScrcpyVideoDecoderError.asynchronousDecodeFailed(status))
            return
        }
        if flags.contains(.frameDropped) {
            return
        }
        guard let pixelBuffer = imageBuffer else { return }
        onFrame?(
            ScrcpyDecodedFrame(pixelBuffer: pixelBuffer, pts: pts, isKeyFrame: isKeyFrame)
        )
    }
}

/// Carries a retired session to the teardown queue. A decompression session
/// may be invalidated from any thread; the box only satisfies `Sendable`.
private struct RetiredSession: @unchecked Sendable {
    let session: VTDecompressionSession

    init(_ session: VTDecompressionSession) {
        self.session = session
    }
}
