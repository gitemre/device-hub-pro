import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest
@testable import DeviceHubProKit

final class ScrcpyVideoDecoderTests: XCTestCase {
    // MARK: - Annex-B / AVCC transforms

    func testSplitsAnnexBNALUnitsOnFourByteStartCodes() {
        let payload = Data([
            0, 0, 0, 1, 0x67, 0x42, 0xC0, 0x29,
            0, 0, 0, 1, 0x68, 0xCE, 0x3C, 0x80,
            0, 0, 0, 1, 0x65, 0x88, 0x84,
        ])

        let units = ScrcpyH264.nalUnits(in: payload)

        XCTAssertEqual(units.count, 3)
        XCTAssertEqual(units[0], Data([0x67, 0x42, 0xC0, 0x29]))
        XCTAssertEqual(units[1], Data([0x68, 0xCE, 0x3C, 0x80]))
        XCTAssertEqual(units[2], Data([0x65, 0x88, 0x84]))
    }

    func testSplitsMixedThreeAndFourByteStartCodesAndTrimsPadding() {
        let payload = Data([
            0, 0, 1, 0x67, 0x42, 0, 0,
            0, 0, 0, 1, 0x65, 0x88,
        ])

        let units = ScrcpyH264.nalUnits(in: payload)

        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units[0], Data([0x67, 0x42]))
        XCTAssertEqual(units[1], Data([0x65, 0x88]))
    }

    func testTreatsAPayloadWithoutAStartCodeAsASingleNALUnit() {
        let payload = Data([0x65, 0x88, 0x84])

        XCTAssertEqual(ScrcpyH264.nalUnits(in: payload), [payload])
    }

    func testBuildsAnAVCCSampleWithBigEndianLengthsAndNoStartCodes() {
        let payload = Data([
            0, 0, 0, 1, 0x67, 0x42,
            0, 0, 1, 0x68, 0xCE,
        ])

        let sample = ScrcpyH264.avccSample(fromAnnexB: payload)

        XCTAssertEqual(
            sample,
            Data([0, 0, 0, 2, 0x67, 0x42, 0, 0, 0, 2, 0x68, 0xCE])
        )
    }

    func testConfigPacketKeepsOnlySPSAndPPSInWireOrder() {
        let payload = Data([
            0, 0, 0, 1, 0x67, 0x42, 0xC0, 0x29, // SPS
            0, 0, 0, 1, 0x06, 0x05, 0x01, // SEI (dropped)
            0, 0, 0, 1, 0x68, 0xCE, 0x3C, // PPS
        ])

        let sets = ScrcpyH264.parameterSets(fromConfigPacket: payload)

        XCTAssertEqual(sets, [Data([0x67, 0x42, 0xC0, 0x29]), Data([0x68, 0xCE, 0x3C])])
    }

    func testConfigPacketUsesTheLiveServerLayout() {
        // The Task 2 live capture: `00 00 00 01 67 42 c0 29 …`.
        let payload = Data([0, 0, 0, 1, 0x67, 0x42, 0xC0, 0x29, 0x8C, 0x68])

        XCTAssertEqual(
            ScrcpyH264.parameterSets(fromConfigPacket: payload),
            [Data([0x67, 0x42, 0xC0, 0x29, 0x8C, 0x68])]
        )
    }

    // MARK: - Decoder state

    func testDecoderRejectsAConfigPacketWithoutParameterSets() {
        let decoder = ScrcpyVideoDecoder()
        let packet = FramePacket(
            pts: 0,
            isConfig: true,
            isKeyFrame: false,
            payload: Data([0, 0, 0, 1, 0x06, 0x05])
        )

        XCTAssertThrowsError(try decoder.decode(packet)) { error in
            XCTAssertEqual(error as? ScrcpyVideoDecoderError, .missingParameterSets)
        }
    }

    func testDecoderReportsUnsizedStateUntilConfigured() {
        let decoder = ScrcpyVideoDecoder()
        XCTAssertNil(decoder.dimensions)
    }

    func testUnsupportedCodecErrorNamesTheFourCC() {
        let error = ScrcpyVideoDecoderError.unsupportedCodec(0x6832_3635) // "h265"
        XCTAssertTrue(error.description.contains("h265"), error.description)
    }

    // MARK: - Full VideoToolbox round trip

    /// Encodes a handful of frames with `VTCompressionSession`, rewrites the
    /// output into the Annex-B packets scrcpy sends, and asserts the decoder
    /// hands back pixel buffers of the encoded size. This exercises the
    /// parameter-set → format description → decode path without a device.
    func testDecoderRoundTripsAVideoToolboxEncodedStream() throws {
        let width = 64
        let height = 48
        let stream = try Self.encodedStream(width: width, height: height, frameCount: 6)
        let decoder = ScrcpyVideoDecoder()
        let recorder = FrameRecorder()
        let firstFrame = DispatchSemaphore(value: 0)
        decoder.onFrame = { frame in
            recorder.record(frame: frame)
            firstFrame.signal()
        }
        decoder.onError = { error in
            recorder.record(error: error)
        }

        try decoder.decode(stream.config)
        XCTAssertEqual(decoder.dimensions?.width, width)
        XCTAssertEqual(decoder.dimensions?.height, height)

        for packet in stream.frames {
            try decoder.decode(packet)
        }
        XCTAssertGreaterThan(stream.frames.count, 0)

        XCTAssertEqual(firstFrame.wait(timeout: .now() + 10), .success)
        XCTAssertNil(recorder.error)
        XCTAssertEqual(recorder.size?.width, width)
        XCTAssertEqual(recorder.size?.height, height)
        decoder.invalidate()
    }

    /// A rotation arrives as a new config packet with swapped dimensions; the
    /// decoder rebuilds its session and must keep decoding, at the new size,
    /// without an error. The old session is retired outside the decoder lock.
    func testDecoderFollowsAMidStreamResolutionChange() throws {
        let landscape = try Self.encodedStream(width: 64, height: 48, frameCount: 4)
        let portrait = try Self.encodedStream(width: 48, height: 64, frameCount: 4)
        let decoder = ScrcpyVideoDecoder()
        defer { decoder.invalidate() }
        let sizes = SizeRecorder()
        decoder.onFrame = { frame in
            sizes.record(
                width: CVPixelBufferGetWidth(frame.pixelBuffer),
                height: CVPixelBufferGetHeight(frame.pixelBuffer)
            )
        }
        let errors = FrameRecorder()
        decoder.onError = { errors.record(error: $0) }

        try decoder.decode(landscape.config)
        for packet in landscape.frames {
            try decoder.decode(packet)
        }
        try decoder.decode(portrait.config)
        XCTAssertEqual(decoder.dimensions?.width, 48)
        XCTAssertEqual(decoder.dimensions?.height, 64)
        for packet in portrait.frames {
            try decoder.decode(packet)
        }

        let deadline = Date().addingTimeInterval(10)
        while !(sizes.contains(width: 64, height: 48) && sizes.contains(width: 48, height: 64)),
              Date() < deadline {
            usleep(20_000)
        }
        XCTAssertTrue(sizes.contains(width: 64, height: 48), "no landscape frame: \(sizes.all)")
        XCTAssertTrue(sizes.contains(width: 48, height: 64), "no portrait frame: \(sizes.all)")
        XCTAssertNil(errors.error)
    }

    /// An asynchronous decode error (corrupt picture data) is reported from
    /// VideoToolbox's output handler. Tearing the decoder down from inside
    /// that handler, as the session's fatal-error path does, must return:
    /// `VTDecompressionSessionInvalidate` called from its own output handler
    /// never does, which used to wedge the callback thread and leak the
    /// whole scrcpy connection.
    func testInvalidatingFromInsideTheErrorCallbackReturns() throws {
        let stream = try Self.encodedStream(width: 64, height: 48, frameCount: 2)
        let decoder = ScrcpyVideoDecoder()
        let returned = DispatchSemaphore(value: 0)
        let errors = FrameRecorder()
        decoder.onError = { [unowned decoder] error in
            errors.record(error: error)
            decoder.invalidate()
            returned.signal()
        }

        try decoder.decode(stream.config)
        let corrupt = Self.corrupted(try XCTUnwrap(stream.frames.first))
        // Submit off the test thread: with the old teardown the submitting
        // thread wedged along with the callback, and the test must fail, not
        // hang.
        let submission = SubmissionResult()
        DispatchQueue.global().async {
            do {
                try decoder.decode(corrupt)
            } catch {
                submission.record(error)
                returned.signal()
            }
        }

        guard returned.wait(timeout: .now() + 5) == .success else {
            if errors.error == nil {
                throw XCTSkip("VideoToolbox reported no asynchronous error for the corrupt frame")
            }
            return XCTFail("invalidate() called from the error callback never returned")
        }
        if let error = submission.error {
            throw XCTSkip("VideoToolbox rejected the corrupt frame synchronously: \(error)")
        }
        XCTAssertEqual(
            errors.error as? ScrcpyVideoDecoderError,
            .asynchronousDecodeFailed(kVTVideoDecoderBadDataErr)
        )
        XCTAssertNil(decoder.dimensions, "the decoder must be torn down")
    }

    // MARK: - BGRA → RGBA

    func testRGBAFrameSwapsBlueAndRedChannels() throws {
        let width = 2
        let height = 1
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)

        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        // BGRA: [10, 20, 30, 255], [40, 50, 60, 128]
        let source = base.assumingMemoryBound(to: UInt8.self)
        for (index, value) in [10, 20, 30, 255, 40, 50, 60, 128].enumerated() {
            source[index] = UInt8(value)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let rgba = try XCTUnwrap(PhysicalMirrorSession.rgbaFrame(from: buffer))

        XCTAssertEqual(rgba.width, width)
        XCTAssertEqual(rgba.height, height)
        XCTAssertEqual(
            [UInt8](rgba.data),
            [30, 20, 10, 255, 60, 50, 40, 128]
        )
    }

    /// A new ~10 MB zero-filled allocation per frame is pure overhead when
    /// the previous frame's memory is released a frame later: the session's
    /// pool hands the released buffer back out.
    func testRGBAFramesReuseReleasedPoolBuffers() throws {
        let pixelBuffer = try Self.makeSolidPixelBuffer(width: 64, height: 48)
        let pool = RGBAFramePool()

        var firstAddress = 0
        do {
            let first = try XCTUnwrap(PhysicalMirrorSession.rgbaFrame(from: pixelBuffer, pool: pool))
            XCTAssertEqual(first.data.count, 64 * 48 * 4)
            XCTAssertEqual([UInt8](first.data.prefix(4)), [0xC0, 0x80, 0x40, 0xFF], "BGRA → RGBA")
            firstAddress = first.data.withUnsafeBytes { Int(bitPattern: $0.baseAddress) }
            XCTAssertEqual(pool.pooledCount, 0)
        }
        XCTAssertEqual(pool.pooledCount, 1, "a released frame's buffer must return to the pool")

        let second = try XCTUnwrap(PhysicalMirrorSession.rgbaFrame(from: pixelBuffer, pool: pool))
        XCTAssertEqual(second.data.withUnsafeBytes { Int(bitPattern: $0.baseAddress) }, firstAddress)
        XCTAssertEqual([UInt8](second.data.suffix(4)), [0xC0, 0x80, 0x40, 0xFF])
        XCTAssertEqual(pool.pooledCount, 0)

        // A rotated frame has another size: the old buffers are dropped.
        let rotated = try Self.makeSolidPixelBuffer(width: 48, height: 32)
        let third = try XCTUnwrap(PhysicalMirrorSession.rgbaFrame(from: rotated, pool: pool))
        XCTAssertEqual(third.data.count, 48 * 32 * 4)
        withExtendedLifetime(second) {}
    }

    // MARK: - Session surface

    func testPhysicalSessionPublishesTheH264TransportWithoutADevice() {
        let adb = AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/true"))
        let session = PhysicalMirrorSession(serial: "serial-1", adb: adb)

        session.stop()

        XCTAssertEqual(session.transport, .h264)
        XCTAssertNil(session.lastError)
        XCTAssertNil(session.frames.current)
    }

    // MARK: - Fixtures

    /// A VideoToolbox-encoded H.264 stream rewritten into the packets scrcpy
    /// sends: one Annex-B config packet (SPS/PPS) and Annex-B pictures.
    struct EncodedStream {
        let config: FramePacket
        let frames: [FramePacket]
    }

    static func encodedStream(width: Int, height: Int, frameCount: Int) throws -> EncodedStream {
        let pixelBuffer = try makeSolidPixelBuffer(width: width, height: height)
        var session: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard createStatus == noErr, let encoder = session else {
            throw XCTSkip("VideoToolbox H.264 encoding unavailable (\(createStatus))")
        }
        defer { VTCompressionSessionInvalidate(encoder) }

        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(
            encoder,
            key: kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanFalse
        )

        let samplesBox = SampleCollector()
        for index in 0..<frameCount {
            var infoFlags = VTEncodeInfoFlags()
            let status = VTCompressionSessionEncodeFrame(
                encoder,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
                duration: CMTime(value: 1, timescale: 30),
                frameProperties: nil,
                infoFlagsOut: &infoFlags
            ) { status, _, sampleBuffer in
                if status == noErr, let sampleBuffer {
                    samplesBox.append(sampleBuffer)
                }
            }
            guard status == noErr else {
                throw XCTSkip("VTCompressionSessionEncodeFrame failed (\(status))")
            }
        }
        VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
        let deadline = Date().addingTimeInterval(5)
        while samplesBox.samples.isEmpty, Date() < deadline {
            usleep(20_000)
        }

        let samples = samplesBox.samples
        guard let first = samples.first,
              let format = CMSampleBufferGetFormatDescription(first)
        else {
            throw XCTSkip("VideoToolbox produced no samples")
        }

        let config = FramePacket(
            pts: 0,
            isConfig: true,
            isKeyFrame: false,
            payload: annexB(fromParameterSets: try parameterSets(from: format))
        )
        let frames = samples.compactMap { sample -> FramePacket? in
            guard let avcc = avccPayload(from: sample) else { return nil }
            let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            return FramePacket(
                pts: Int64(seconds * 1_000_000) + 1,
                isConfig: false,
                isKeyFrame: true,
                payload: annexB(fromAVCC: avcc)
            )
        }
        return EncodedStream(config: config, frames: frames)
    }

    /// The picture with its slice data scrambled: the NAL headers survive (so
    /// VideoToolbox accepts the sample) but the slices cannot be decoded.
    static func corrupted(_ packet: FramePacket) -> FramePacket {
        var state: UInt32 = 0x1234_5678
        var payload = Data()
        for unit in ScrcpyH264.nalUnits(in: packet.payload) {
            var bytes = [UInt8](unit)
            // Keep the NAL header; never write a zero, so no start code can
            // be emulated inside the scrambled slice.
            for index in bytes.indices.dropFirst() {
                state = state &* 1_664_525 &+ 1_013_904_223
                bytes[index] = UInt8(truncatingIfNeeded: state >> 24) | 0x01
            }
            payload.append(contentsOf: [0, 0, 0, 1])
            payload.append(contentsOf: bytes)
        }
        return FramePacket(
            pts: packet.pts,
            isConfig: false,
            isKeyFrame: packet.isKeyFrame,
            payload: payload
        )
    }

    private final class SubmissionResult: @unchecked Sendable {
        private let lock = NSLock()
        private var _error: Error?

        func record(_ error: Error) {
            lock.lock()
            _error = error
            lock.unlock()
        }

        var error: Error? {
            lock.lock()
            defer { lock.unlock() }
            return _error
        }
    }

    private final class SizeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var sizes: [String] = []

        func record(width: Int, height: Int) {
            lock.lock()
            sizes.append("\(width)x\(height)")
            lock.unlock()
        }

        func contains(width: Int, height: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return sizes.contains("\(width)x\(height)")
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return sizes
        }
    }

    private final class SampleCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [CMSampleBuffer] = []

        func append(_ sample: CMSampleBuffer) {
            lock.lock()
            storage.append(sample)
            lock.unlock()
        }

        var samples: [CMSampleBuffer] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private final class FrameRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _size: (width: Int, height: Int)?
        private var _error: Error?

        func record(frame: ScrcpyDecodedFrame) {
            lock.lock()
            _size = (
                CVPixelBufferGetWidth(frame.pixelBuffer),
                CVPixelBufferGetHeight(frame.pixelBuffer)
            )
            lock.unlock()
        }

        func record(error: Error) {
            lock.lock()
            _error = error
            lock.unlock()
        }

        var size: (width: Int, height: Int)? {
            lock.lock()
            defer { lock.unlock() }
            return _size
        }

        var error: Error? {
            lock.lock()
            defer { lock.unlock() }
            return _error
        }
    }

    private static func makeSolidPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw XCTSkip("could not allocate a pixel buffer (\(status))")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * rowBytes + x * 4
                    bytes[offset] = 0x40
                    bytes[offset + 1] = 0x80
                    bytes[offset + 2] = 0xC0
                    bytes[offset + 3] = 0xFF
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    private static func parameterSets(from format: CMFormatDescription) throws -> [Data] {
        var count = 0
        var status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: nil
        )
        guard status == noErr, count > 0 else {
            throw XCTSkip("format description has no H.264 parameter sets (\(status))")
        }
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer else {
                throw XCTSkip("could not read parameter set \(index) (\(status))")
            }
            sets.append(Data(bytes: pointer, count: size))
        }
        return sets
    }

    private static func annexB(fromParameterSets sets: [Data]) -> Data {
        var data = Data()
        for set in sets {
            data.append(contentsOf: [0, 0, 0, 1])
            data.append(set)
        }
        return data
    }

    /// Extracts the sample's length-prefixed NAL units from its block buffer.
    private static func avccPayload(from sample: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &pointer
        )
        guard status == noErr, let pointer, length > 0 else { return nil }
        return Data(bytes: pointer, count: length)
    }

    /// Rewrites an AVCC payload (4-byte lengths) as Annex-B start codes.
    private static func annexB(fromAVCC avcc: Data) -> Data {
        var data = Data()
        var index = avcc.startIndex
        while index + 4 <= avcc.endIndex {
            let length =
                Int(avcc[index]) << 24
                | Int(avcc[index + 1]) << 16
                | Int(avcc[index + 2]) << 8
                | Int(avcc[index + 3])
            index += 4
            guard length > 0, index + length <= avcc.endIndex else { break }
            data.append(contentsOf: [0, 0, 0, 1])
            data.append(avcc[index..<(index + length)])
            index += length
        }
        return data
    }
}
