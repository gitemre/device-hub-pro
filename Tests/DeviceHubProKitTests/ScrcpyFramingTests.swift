import XCTest
@testable import DeviceHubProKit

final class ScrcpyFramingTests: XCTestCase {
    private static let h264CodecID: UInt32 = 0x6832_3634 // "h264"

    // MARK: - Fixtures

    private func beBytes(_ value: UInt64) -> Data {
        var data = Data()
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
        return data
    }

    private func beBytes(_ value: UInt32) -> Data {
        var data = Data()
        for shift in stride(from: 24, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
        return data
    }

    /// The stream prefix after the dummy byte: a NUL-padded 64-byte device
    /// name, the 4-byte codec id and (unless the stream is disabled) the
    /// 8-byte captured size.
    private func handshake(
        deviceName: String = "sdk_gphone16k_arm64",
        codecID: UInt32 = ScrcpyFramingTests.h264CodecID,
        width: UInt32 = 1080,
        height: UInt32 = 1920,
        dummyByte: Bool = false
    ) -> Data {
        var data = Data()
        if dummyByte {
            data.append(0)
        }
        var nameField = Data(deviceName.utf8)
        nameField.append(Data(count: max(0, 64 - nameField.count)))
        data.append(contentsOf: nameField.prefix(64))
        data.append(beBytes(codecID))
        if codecID > 1 {
            data.append(beBytes(width))
            data.append(beBytes(height))
        }
        return data
    }

    /// One 12-byte packet header followed by its payload, exactly as
    /// `Streamer.writeFrameMeta` emits it. `ptsWord` is the raw 64-bit word:
    /// flags in the top two bits, PTS below.
    private func packet(ptsWord: UInt64, payload: [UInt8]) -> Data {
        var data = beBytes(ptsWord)
        data.append(beBytes(UInt32(payload.count)))
        data.append(contentsOf: payload)
        return data
    }

    private func drain(_ reader: inout ScrcpyStreamReader) throws -> [FramePacket] {
        var packets: [FramePacket] = []
        while let packet = try reader.nextPacket() {
            packets.append(packet)
        }
        return packets
    }

    // MARK: - Layout

    func testWireLayoutConstantsMatchTheScrcpyV31Protocol() {
        XCTAssertEqual(ScrcpyFraming.dummyByteSize, 1)
        XCTAssertEqual(ScrcpyFraming.deviceNameFieldSize, 64)
        XCTAssertEqual(ScrcpyFraming.codecMetadataSize, 12)
        XCTAssertEqual(ScrcpyFraming.packetHeaderSize, 12)
        XCTAssertEqual(ScrcpyFraming.handshakeByteCount, 76)
        XCTAssertEqual(ScrcpyFraming.packetFlagConfig, 1 << 63)
        XCTAssertEqual(ScrcpyFraming.packetFlagKeyFrame, 1 << 62)
        XCTAssertEqual(ScrcpyFraming.packetPTSMask, (1 << 62) - 1)
    }

    // MARK: - Handshake parsing

    func testParsesTheVideoHandshake() throws {
        let header = try XCTUnwrap(ScrcpyFraming.parseHandshake(handshake()))

        XCTAssertEqual(header.deviceName, "sdk_gphone16k_arm64")
        XCTAssertEqual(header.codecID, Self.h264CodecID)
        XCTAssertEqual(header.width, 1080)
        XCTAssertEqual(header.height, 1920)
    }

    func testHandshakeWaitsForTheCompleteDeviceNameAndMetadata() throws {
        let stream = handshake()

        XCTAssertNil(try ScrcpyFraming.parseHandshake(Data()))
        XCTAssertNil(try ScrcpyFraming.parseHandshake(stream.prefix(63)))
        XCTAssertNil(try ScrcpyFraming.parseHandshake(stream.prefix(67)))
        XCTAssertNil(try ScrcpyFraming.parseHandshake(stream.prefix(75)))
        XCTAssertNotNil(try ScrcpyFraming.parseHandshake(stream))
    }

    func testHandshakeTrimsTheDeviceNameAtTheFirstNUL() throws {
        let header = try XCTUnwrap(ScrcpyFraming.parseHandshake(handshake(deviceName: "Pixel 9")))

        XCTAssertEqual(header.deviceName, "Pixel 9")
    }

    func testHandshakeDecodesAMultiByteDeviceName() throws {
        let header = try XCTUnwrap(ScrcpyFraming.parseHandshake(handshake(deviceName: "café-telefoon")))

        XCTAssertEqual(header.deviceName, "café-telefoon")
    }

    func testHandshakeReportsAStreamDisabledByTheDevice() {
        XCTAssertThrowsError(try ScrcpyFraming.parseHandshake(handshake(codecID: 0))) { error in
            XCTAssertEqual(error as? ScrcpyFramingError, .streamDisabledByDevice)
        }
    }

    func testHandshakeReportsAStreamConfigurationError() {
        XCTAssertThrowsError(try ScrcpyFraming.parseHandshake(handshake(codecID: 1))) { error in
            XCTAssertEqual(error as? ScrcpyFramingError, .streamConfigurationError)
        }
    }

    func testHandshakeParsesFromANonZeroIndexedSlice() throws {
        let padded = Data([0xAA]) + handshake()

        let header = try XCTUnwrap(ScrcpyFraming.parseHandshake(padded.dropFirst()))

        XCTAssertEqual(header.deviceName, "sdk_gphone16k_arm64")
    }

    // MARK: - Streaming reader: handshake

    func testReaderReturnsNilBeforeAnyBytesArrive() throws {
        var reader = ScrcpyStreamReader(expectsDummyByte: true)

        XCTAssertNil(try reader.nextPacket())
        XCTAssertNil(reader.header)
    }

    func testReaderSkipsTheDummyByteWhenExpected() throws {
        var reader = ScrcpyStreamReader(expectsDummyByte: true)
        reader.append(handshake(dummyByte: true))

        XCTAssertNil(try reader.nextPacket())

        XCTAssertEqual(reader.header?.deviceName, "sdk_gphone16k_arm64")
        XCTAssertEqual(reader.header?.codecID, Self.h264CodecID)
    }

    func testReaderDoesNotSkipAByteWhenNoDummyByteIsExpected() throws {
        var reader = ScrcpyStreamReader()
        reader.append(handshake(dummyByte: true))

        XCTAssertNil(try reader.nextPacket())

        // The leading 0x00 was treated as the first name byte, not skipped.
        XCTAssertEqual(reader.header?.deviceName, "")
    }

    func testReaderAcceptsTheHandshakeOneByteAtATime() throws {
        var reader = ScrcpyStreamReader(expectsDummyByte: true)

        for byte in handshake(dummyByte: true) {
            reader.append(Data([byte]))
            XCTAssertNil(try reader.nextPacket())
        }

        XCTAssertEqual(reader.header?.deviceName, "sdk_gphone16k_arm64")
        XCTAssertEqual(reader.header?.width, 1080)
        XCTAssertEqual(reader.header?.height, 1920)
    }

    func testReaderSurfacesADisabledStreamWhileHandlingChunks() {
        var reader = ScrcpyStreamReader()
        reader.append(handshake(codecID: 0).prefix(40))

        XCTAssertNil(try reader.nextPacket())

        reader.append(handshake(codecID: 0).dropFirst(40))
        XCTAssertThrowsError(try reader.nextPacket()) { error in
            XCTAssertEqual(error as? ScrcpyFramingError, .streamDisabledByDevice)
        }
    }

    // MARK: - Packet parsing

    func testParsesAConfigPacketKeyFrameAndDeltaFrame() throws {
        let configPayload: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x67, 0x42]
        let keyPayload: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84]
        let deltaPayload: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x41, 0x9A]

        var stream = handshake(dummyByte: true)
        stream.append(packet(ptsWord: ScrcpyFraming.packetFlagConfig, payload: configPayload))
        stream.append(packet(ptsWord: 1_000_000 | ScrcpyFraming.packetFlagKeyFrame, payload: keyPayload))
        stream.append(packet(ptsWord: 1_016_666, payload: deltaPayload))

        var reader = ScrcpyStreamReader(expectsDummyByte: true)
        reader.append(stream)

        XCTAssertEqual(reader.header?.width, 1080)
        XCTAssertEqual(reader.header?.height, 1920)

        let packets = try drain(&reader)
        XCTAssertEqual(packets.count, 3)
        XCTAssertEqual(
            packets[0],
            FramePacket(pts: 0, isConfig: true, isKeyFrame: false, payload: Data(configPayload))
        )
        XCTAssertEqual(
            packets[1],
            FramePacket(pts: 1_000_000, isConfig: false, isKeyFrame: true, payload: Data(keyPayload))
        )
        XCTAssertEqual(
            packets[2],
            FramePacket(pts: 1_016_666, isConfig: false, isKeyFrame: false, payload: Data(deltaPayload))
        )
    }

    func testParsesPTSWiderThan32Bits() throws {
        let pts: UInt64 = 0x1_2345_6789_AB

        let parsed = try XCTUnwrap(
            try ScrcpyFraming.parsePacket(
                packet(ptsWord: pts | ScrcpyFraming.packetFlagKeyFrame, payload: [0xAA])
            )
        )

        XCTAssertEqual(parsed.pts, Int64(pts))
        XCTAssertTrue(parsed.isKeyFrame)
        XCTAssertFalse(parsed.isConfig)
    }

    func testMasksTheFlagBitsAtTheTopOfThePTSWord() throws {
        let rawPTSWord =
            ScrcpyFraming.packetFlagConfig | ScrcpyFraming.packetFlagKeyFrame | 0xABCD

        let parsed = try XCTUnwrap(
            try ScrcpyFraming.parsePacket(packet(ptsWord: rawPTSWord, payload: [0x01]))
        )

        XCTAssertEqual(parsed.pts, 0xABCD)
        XCTAssertTrue(parsed.isConfig)
        XCTAssertTrue(parsed.isKeyFrame)
    }

    func testConfigPacketsCarryNoPTS() throws {
        let parsed = try XCTUnwrap(
            try ScrcpyFraming.parsePacket(
                packet(ptsWord: ScrcpyFraming.packetFlagConfig, payload: [0x67])
            )
        )

        XCTAssertEqual(parsed.pts, 0)
        XCTAssertTrue(parsed.isConfig)
        XCTAssertFalse(parsed.isKeyFrame)
    }

    func testPacketParsingWaitsForTheWholePayload() throws {
        let full = packet(ptsWord: 42, payload: [1, 2, 3, 4])

        XCTAssertNil(try ScrcpyFraming.parsePacket(full.prefix(11)))
        XCTAssertNil(try ScrcpyFraming.parsePacket(full.prefix(15)))

        let parsed = try XCTUnwrap(try ScrcpyFraming.parsePacket(full))
        XCTAssertEqual(parsed.pts, 42)
        XCTAssertEqual(parsed.payload, Data([1, 2, 3, 4]))
    }

    func testRejectsAZeroSizePacket() {
        let empty = packet(ptsWord: ScrcpyFraming.packetFlagKeyFrame, payload: [])

        XCTAssertThrowsError(try ScrcpyFraming.parsePacket(empty)) { error in
            XCTAssertEqual(error as? ScrcpyFramingError, .emptyPacket)
        }
    }

    func testRejectsAnOversizedPacketWithoutBufferingThePayload() throws {
        var header = beBytes(ScrcpyFraming.packetFlagConfig)
        header.append(beBytes(UInt32.max))

        XCTAssertThrowsError(try ScrcpyFraming.parsePacket(header)) { error in
            XCTAssertEqual(
                error as? ScrcpyFramingError,
                .oversizedPacket(size: .max, maximum: ScrcpyFraming.defaultMaximumPacketSize)
            )
        }

        var reader = ScrcpyStreamReader()
        reader.append(handshake())
        reader.append(header)
        XCTAssertThrowsError(try reader.nextPacket()) { error in
            XCTAssertEqual(
                error as? ScrcpyFramingError,
                .oversizedPacket(size: .max, maximum: ScrcpyFraming.defaultMaximumPacketSize)
            )
        }
    }

    func testReaderHonorsACustomMaximumPacketSize() throws {
        var reader = ScrcpyStreamReader(maximumPacketSize: 8)
        reader.append(handshake())
        reader.append(packet(ptsWord: 0, payload: [UInt8](repeating: 0, count: 9)))

        XCTAssertThrowsError(try reader.nextPacket()) { error in
            XCTAssertEqual(error as? ScrcpyFramingError, .oversizedPacket(size: 9, maximum: 8))
        }
    }

    func testReadsAPacketSplitAcrossThreeReads() throws {
        let payload = Data([0x00, 0x00, 0x00, 0x01, 0x65]) + Data(repeating: 0x5A, count: 300)
        let bytes = packet(
            ptsWord: 0x2A | ScrcpyFraming.packetFlagKeyFrame,
            payload: [UInt8](payload)
        )

        var reader = ScrcpyStreamReader(expectsDummyByte: true)
        reader.append(handshake(dummyByte: true))

        reader.append(bytes.prefix(5))
        XCTAssertNil(try reader.nextPacket())

        reader.append(bytes.dropFirst(5).prefix(4))
        XCTAssertNil(try reader.nextPacket())

        reader.append(bytes.dropFirst(9))
        let parsed = try XCTUnwrap(try reader.nextPacket())

        XCTAssertEqual(parsed.pts, 0x2A)
        XCTAssertTrue(parsed.isKeyFrame)
        XCTAssertEqual(parsed.payload, payload)
        XCTAssertNil(try reader.nextPacket())
    }

    func testReadsAWholeStreamOneByteAtATime() throws {
        var stream = handshake(dummyByte: true)
        stream.append(packet(ptsWord: ScrcpyFraming.packetFlagConfig, payload: [0x67, 0x42]))
        stream.append(packet(ptsWord: 7 | ScrcpyFraming.packetFlagKeyFrame, payload: [0x65, 0x88]))
        stream.append(packet(ptsWord: 8, payload: [0x41, 0x9A]))

        var reader = ScrcpyStreamReader(expectsDummyByte: true)
        var packets: [FramePacket] = []
        for byte in stream {
            reader.append(Data([byte]))
            while let parsed = try reader.nextPacket() {
                packets.append(parsed)
            }
        }

        XCTAssertEqual(packets.count, 3)
        XCTAssertTrue(packets[0].isConfig)
        XCTAssertTrue(packets[1].isKeyFrame)
        XCTAssertEqual(packets[2].payload, Data([0x41, 0x9A]))
    }

    func testParsesPacketsFromANonZeroIndexedSlice() throws {
        let padded = Data([0xAA, 0xBB]) + packet(ptsWord: 99, payload: [1, 2])

        let parsed = try XCTUnwrap(try ScrcpyFraming.parsePacket(padded.dropFirst(2)))

        XCTAssertEqual(parsed.pts, 99)
        XCTAssertEqual(parsed.payload, Data([1, 2]))
    }

    // MARK: - Stall bound

    /// An incomplete packet header followed by a declared payload larger than
    /// the bytes received: the 64 MiB cap bounds memory, this deadline bounds
    /// wait. The reader must throw a typed error instead of waiting forever.
    func testReaderThrowsWhenAnIncompletePacketStopsMakingProgress() throws {
        var reader = ScrcpyStreamReader(stallTimeout: 2)
        reader.append(handshake())
        let start = ContinuousClock.now

        let declaredSize = 1 << 20
        var incomplete = beBytes(UInt64(1))
        incomplete.append(beBytes(UInt32(declaredSize)))
        incomplete.append(Data(repeating: 0x5A, count: 100))
        reader.append(incomplete, at: start)

        // Before the deadline the reader keeps waiting for the rest.
        XCTAssertNil(try reader.nextPacket(at: start.advanced(by: .seconds(1))))
        try reader.checkStall(at: start.advanced(by: .seconds(1)))

        let expected = ScrcpyFramingError.stalledPacket(
            receivedBytes: 100,
            declaredBytes: declaredSize,
            seconds: 2
        )
        XCTAssertThrowsError(try reader.nextPacket(at: start.advanced(by: .seconds(3)))) { error in
            XCTAssertEqual(error as? ScrcpyFramingError, expected)
        }

        var fresh = ScrcpyStreamReader(stallTimeout: 2)
        fresh.append(handshake())
        fresh.append(incomplete, at: start)
        XCTAssertThrowsError(try fresh.checkStall(at: start.advanced(by: .seconds(3)))) { error in
            XCTAssertEqual(error as? ScrcpyFramingError, expected)
        }
    }

    func testReaderStallDeadlineResetsWhileBytesKeepArriving() throws {
        var reader = ScrcpyStreamReader(stallTimeout: 2)
        reader.append(handshake())
        let start = ContinuousClock.now

        var incomplete = beBytes(UInt64(1))
        incomplete.append(beBytes(UInt32(1 << 20)))
        incomplete.append(Data(repeating: 0x5A, count: 100))
        reader.append(incomplete, at: start)

        // A trickle 1.5 s after the first chunk is progress; the deadline
        // runs from the newest bytes, not from the packet's first byte.
        reader.append(
            Data(repeating: 0x5A, count: 50),
            at: start.advanced(by: .milliseconds(1_500))
        )

        XCTAssertNil(try reader.nextPacket(at: start.advanced(by: .milliseconds(2_500))))
        try reader.checkStall(at: start.advanced(by: .seconds(3)))
    }

    func testReaderWithoutAStallTimeoutNeverThrowsForAnIncompletePacket() throws {
        var reader = ScrcpyStreamReader()
        reader.append(handshake())
        let start = ContinuousClock.now

        var incomplete = beBytes(UInt64(1))
        incomplete.append(beBytes(UInt32(1 << 20)))
        incomplete.append(Data(repeating: 0x5A, count: 100))
        reader.append(incomplete, at: start)

        XCTAssertNil(try reader.nextPacket(at: start.advanced(by: .seconds(3_600))))
        try reader.checkStall(at: start.advanced(by: .seconds(3_600)))
    }

    func testReaderDoesNotStallWhileIdleBetweenPackets() throws {
        var reader = ScrcpyStreamReader(stallTimeout: 1)
        reader.append(handshake())
        reader.append(packet(ptsWord: 7, payload: [0x65, 0x88]))

        let parsed = try XCTUnwrap(try reader.nextPacket())
        XCTAssertEqual(parsed.pts, 7)

        // The idle socket (no partial packet buffered) is not a stall: the
        // server may legitimately send nothing on a static screen.
        let later = ContinuousClock.now.advanced(by: .seconds(600))
        XCTAssertNil(try reader.nextPacket(at: later))
        try reader.checkStall(at: later)
    }

    // MARK: - Handshake deadline

    /// A server that accepts the socket and then hangs (capture or encoder
    /// setup, or waiting on a socket nobody connects) never sends the header;
    /// without a deadline the session sat "connecting" forever with no error.
    func testReaderThrowsWhenTheHeaderMissesItsDeadline() throws {
        let start = ContinuousClock.now
        var reader = ScrcpyStreamReader(handshakeTimeout: 5, startedAt: start)
        reader.append(handshake().prefix(10), at: start.advanced(by: .seconds(1)))

        XCTAssertNil(try reader.nextPacket(at: start.advanced(by: .milliseconds(4_900))))
        try reader.checkStall(at: start.advanced(by: .milliseconds(4_900)))

        let expected = ScrcpyFramingError.handshakeTimedOut(receivedBytes: 10, seconds: 5)
        XCTAssertThrowsError(try reader.checkStall(at: start.advanced(by: .seconds(5)))) { error in
            XCTAssertEqual(error as? ScrcpyFramingError, expected)
        }
        XCTAssertThrowsError(try reader.nextPacket(at: start.advanced(by: .seconds(6)))) { error in
            XCTAssertEqual(error as? ScrcpyFramingError, expected)
        }
    }

    func testHandshakeDeadlineNoLongerAppliesOnceTheHeaderArrived() throws {
        let start = ContinuousClock.now
        var reader = ScrcpyStreamReader(handshakeTimeout: 5, startedAt: start)
        reader.append(handshake(), at: start.advanced(by: .seconds(1)))

        let later = start.advanced(by: .seconds(600))
        XCTAssertNil(try reader.nextPacket(at: later))
        try reader.checkStall(at: later)
        XCTAssertNotNil(reader.header)
    }

    // MARK: - Memory bound

    /// Streams 256 MiB through the reader in 64 KiB socket-sized chunks whose
    /// boundaries split packets (the production read size), and asserts the
    /// reader's own buffer stays bounded by what is in flight. Consuming with
    /// `buffer = buffer.dropFirst(n)` kept every received byte alive: the
    /// slice pinned the backing store and each append grew it in place, so a
    /// mirror leaked about 1 MB per second of video.
    func testReaderMemoryStaysBoundedWhileStreamingHundredsOfMegabytes() throws {
        let chunkSize = 64 << 10
        // One cycle is exactly three chunks, so every cycle splits packets at
        // the same non-aligned offsets and the stream can repeat it.
        var cycle = Data()
        for index in 0..<6 {
            cycle.append(packet(
                ptsWord: UInt64(index + 1),
                payload: [UInt8](repeating: UInt8(index), count: 30_000)
            ))
        }
        let fillerPayload = 3 * chunkSize - cycle.count - ScrcpyFraming.packetHeaderSize
        cycle.append(packet(
            ptsWord: 7,
            payload: [UInt8](repeating: 0xAB, count: fillerPayload)
        ))
        XCTAssertEqual(cycle.count, 3 * chunkSize)
        let chunks = stride(from: 0, to: cycle.count, by: chunkSize).map {
            cycle.subdata(in: $0..<($0 + chunkSize))
        }

        var reader = ScrcpyStreamReader(stallTimeout: 5)
        reader.append(handshake())
        _ = try reader.nextPacket()

        let target = 256 << 20
        var streamed = 0
        var packets = 0
        var peakCapacity = 0
        var peakBuffered = 0
        while streamed < target {
            for chunk in chunks {
                reader.append(chunk)
                streamed += chunk.count
                while try reader.nextPacket() != nil {
                    packets += 1
                }
                peakCapacity = max(peakCapacity, reader.bufferCapacity)
                peakBuffered = max(peakBuffered, reader.bufferedByteCount)
            }
        }

        XCTAssertGreaterThanOrEqual(streamed, target)
        XCTAssertEqual(packets, streamed / cycle.count * 7, "every packet must be delivered")
        XCTAssertLessThan(peakBuffered, 2 * chunkSize)
        XCTAssertLessThanOrEqual(
            peakCapacity,
            1 << 20,
            "the reader must not retain consumed bytes: \(peakCapacity) bytes allocated after \(streamed) streamed"
        )
    }

    /// A single large keyframe may grow the buffer, but its peak allocation is
    /// given back once the stream moves on to ordinary packets.
    func testReaderReleasesALargeKeyframesCapacityOnceItDrains() throws {
        var reader = ScrcpyStreamReader()
        reader.append(handshake())

        let large = packet(ptsWord: 1, payload: [UInt8](repeating: 0x11, count: 8 << 20))
        reader.append(large)
        XCTAssertEqual(try reader.nextPacket()?.payload.count, 8 << 20)
        XCTAssertGreaterThan(reader.bufferCapacity, ScrcpyStreamReader.retainedCapacity)

        reader.append(packet(ptsWord: 2, payload: [1, 2, 3]))
        XCTAssertEqual(try reader.nextPacket()?.payload, Data([1, 2, 3]))
        XCTAssertLessThanOrEqual(reader.bufferCapacity, ScrcpyStreamReader.retainedCapacity)
    }
}
