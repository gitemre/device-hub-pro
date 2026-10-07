import Foundation

/// Wire framing of the scrcpy (v3.1) video stream.
///
/// The video socket, in forward-tunnel mode, carries:
///
///     [dummy byte]                     1 byte   (written on accept; liveness probe)
///     [device name]                   64 bytes  (UTF-8, NUL-padded)
///     [codec id]                       4 bytes  (big-endian)
///     [width]                          4 bytes  (big-endian)
///     [height]                         4 bytes  (big-endian)
///     then, repeating:
///       [pts + flags]                  8 bytes  (big-endian)
///       [packet size]                  4 bytes  (big-endian)
///       [payload]             packet size bytes
///
/// Upstream v3.1 is the ground truth: `app/src/demuxer.c` defines the 12-byte
/// packet header, the flags (`SC_PACKET_FLAG_CONFIG = 1 << 63`,
/// `SC_PACKET_FLAG_KEY_FRAME = 1 << 62`) in the **PTS word** and
/// `SC_PACKET_PTS_MASK = SC_PACKET_FLAG_KEY_FRAME - 1`; the codec id and the
/// video size are read back-to-back. `app/src/server.h` defines the 64-byte
/// device-name field (`SC_DEVICE_NAME_FIELD_LENGTH`),
/// `server/src/main/java/com/genymobile/scrcpy/device/Streamer.java`
/// (`writeVideoHeader`, `writeFrameMeta`) emits the same bytes, and
/// `.../device/DesktopConnection.java` sends the dummy byte and the name.
public enum ScrcpyFraming {
    /// Written by the server on accept; scrcpy's client reads it to detect a
    /// working connection behind the adb tunnel.
    public static let dummyByteSize = 1
    /// `SC_DEVICE_NAME_FIELD_LENGTH` in `app/src/server.h`.
    public static let deviceNameFieldSize = 64
    /// Codec id (4 bytes) followed by the video size (width + height, 8 bytes).
    public static let codecMetadataSize = 12
    /// PTS (8 bytes) + payload size (4 bytes), `SC_PACKET_HEADER_SIZE`.
    public static let packetHeaderSize = 12
    /// Device name + codec metadata, everything after the dummy byte.
    public static let handshakeByteCount = deviceNameFieldSize + codecMetadataSize

    /// `SC_PACKET_FLAG_CONFIG`: the packet is codec configuration, not media.
    public static let packetFlagConfig: UInt64 = 1 << 63
    /// `SC_PACKET_FLAG_KEY_FRAME`: the encoded frame is a key frame.
    public static let packetFlagKeyFrame: UInt64 = 1 << 62
    /// `SC_PACKET_PTS_MASK`: presentation timestamp bits.
    public static let packetPTSMask: UInt64 = packetFlagKeyFrame - 1

    /// Sanity ceiling for a single encoded packet. AVC/HEVC level maxima for
    /// 4K are below 10 MiB; 64 MiB still rejects the up-to-4-GiB claims a
    /// corrupt size word can make without allocating for them.
    public static let defaultMaximumPacketSize = 64 << 20

    /// How long an incomplete packet may make no progress before the reader
    /// gives up. The size cap bounds the memory a trickling peer can pin; this
    /// bounds the time it can hold the socket reader. Real keyframes arrive in
    /// well under a second, so five seconds without a byte is a dead stream.
    public static let defaultStallTimeout: TimeInterval = 5

    /// The payload size declared by a complete 12-byte packet header at the
    /// start of `bytes`, or nil when the header is still incomplete.
    static func declaredPacketSize(in bytes: UnsafeRawBufferPointer) -> Int? {
        guard bytes.count >= packetHeaderSize else { return nil }
        return Int(readUInt32BE(bytes, at: 8))
    }

    /// Parses the handshake prefix that follows the dummy byte (64-byte device
    /// name + 4-byte codec id + 8-byte video size). Returns nil when `bytes`
    /// holds only a prefix of it. Codec id 0 and 1 are the server's
    /// stream-disabled and configuration-error signals (`Streamer.java`
    /// `writeDisableStream`), and carry no video size.
    public static func parseHandshake(_ bytes: Data) throws -> ScrcpyStreamHeader? {
        try bytes.withUnsafeBytes { try parseHandshake(raw: $0) }
    }

    static func parseHandshake(raw bytes: UnsafeRawBufferPointer) throws -> ScrcpyStreamHeader? {
        guard bytes.count >= deviceNameFieldSize + 4 else { return nil }

        let codecID = readUInt32BE(bytes, at: deviceNameFieldSize)
        switch codecID {
        case 0:
            throw ScrcpyFramingError.streamDisabledByDevice
        case 1:
            throw ScrcpyFramingError.streamConfigurationError
        default:
            break
        }

        guard bytes.count >= handshakeByteCount else { return nil }

        let nameField = UnsafeRawBufferPointer(rebasing: bytes[0..<deviceNameFieldSize])
        let nameEnd = nameField.firstIndex(of: 0) ?? nameField.endIndex
        let deviceName = String(decoding: nameField[0..<nameEnd], as: UTF8.self)

        return ScrcpyStreamHeader(
            deviceName: deviceName,
            codecID: codecID,
            width: readUInt32BE(bytes, at: deviceNameFieldSize + 4),
            height: readUInt32BE(bytes, at: deviceNameFieldSize + 8)
        )
    }

    /// Parses one complete packet (12-byte header + payload). Returns nil when
    /// `bytes` holds only a prefix of it. Throws before buffering anything when
    /// the size word is zero or above `maximumPacketSize`.
    public static func parsePacket(
        _ bytes: Data,
        maximumPacketSize: Int = defaultMaximumPacketSize
    ) throws -> FramePacket? {
        try bytes.withUnsafeBytes {
            try parsePacket(raw: $0, maximumPacketSize: maximumPacketSize)
        }
    }

    /// The payload is copied out, so the returned packet never keeps the
    /// caller's buffer alive.
    static func parsePacket(
        raw bytes: UnsafeRawBufferPointer,
        maximumPacketSize: Int = defaultMaximumPacketSize
    ) throws -> FramePacket? {
        guard bytes.count >= packetHeaderSize else { return nil }

        let ptsFlags = readUInt64BE(bytes, at: 0)
        let size = readUInt32BE(bytes, at: 8)

        guard size > 0 else { throw ScrcpyFramingError.emptyPacket }
        guard Int(size) <= maximumPacketSize else {
            throw ScrcpyFramingError.oversizedPacket(size: size, maximum: maximumPacketSize)
        }
        guard bytes.count >= packetHeaderSize + Int(size) else { return nil }

        let payload = Data(
            UnsafeRawBufferPointer(
                rebasing: bytes[packetHeaderSize..<(packetHeaderSize + Int(size))]
            )
        )

        return FramePacket(
            pts: Int64(ptsFlags & packetPTSMask),
            isConfig: ptsFlags & packetFlagConfig != 0,
            isKeyFrame: ptsFlags & packetFlagKeyFrame != 0,
            payload: payload
        )
    }

    private static func readUInt32BE(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func readUInt64BE(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(bytes[offset + index])
        }
        return value
    }
}

/// The video stream prefix: the device the server runs on and the shape of the
/// encoded stream it will send.
public struct ScrcpyStreamHeader: Equatable, Sendable {
    public let deviceName: String
    public let codecID: UInt32
    public let width: UInt32
    public let height: UInt32

    public init(deviceName: String, codecID: UInt32, width: UInt32, height: UInt32) {
        self.deviceName = deviceName
        self.codecID = codecID
        self.width = width
        self.height = height
    }
}

/// One encoded video packet from the server.
public struct FramePacket: Equatable, Sendable {
    /// Presentation timestamp in microseconds, masked to 62 bits. The top two
    /// bits of the wire word are flags, not timestamp. Config packets carry 0.
    public let pts: Int64
    public let isConfig: Bool
    public let isKeyFrame: Bool
    public let payload: Data

    public init(pts: Int64, isConfig: Bool, isKeyFrame: Bool, payload: Data) {
        self.pts = pts
        self.isConfig = isConfig
        self.isKeyFrame = isKeyFrame
        self.payload = payload
    }
}

public enum ScrcpyFramingError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Codec id 0: the server disabled the stream (e.g. it could not capture).
    case streamDisabledByDevice
    /// Codec id 1: the server hit a configuration error.
    case streamConfigurationError
    /// A zero-length packet violates the protocol; scrcpy's client asserts on
    /// it (`demuxer.c`: `assert(len)`).
    case emptyPacket
    /// The size word claims more than the parser's sanity ceiling.
    case oversizedPacket(size: UInt32, maximum: Int)
    /// An incomplete packet made no progress within the reader's deadline:
    /// the peer is trickling (or stopped) mid-packet.
    case stalledPacket(receivedBytes: Int, declaredBytes: Int, seconds: TimeInterval)
    /// The stream header (device name + codec metadata) did not arrive within
    /// the reader's deadline: the server accepted the socket and then hung
    /// (capture or encoder setup, or a socket it is still waiting to accept).
    case handshakeTimedOut(receivedBytes: Int, seconds: TimeInterval)

    public var description: String {
        switch self {
        case .streamDisabledByDevice:
            return "the device disabled the scrcpy video stream"
        case .streamConfigurationError:
            return "the device reported a scrcpy stream configuration error"
        case .emptyPacket:
            return "the scrcpy stream contains a zero-size packet"
        case .oversizedPacket(let size, let maximum):
            return "the scrcpy stream declares a \(size)-byte packet (maximum \(maximum))"
        case .stalledPacket(let received, let declared, let seconds):
            return "the scrcpy stream stalled mid-packet: \(received) of \(declared) bytes received, no progress for \(String(format: "%.1f", seconds))s"
        case .handshakeTimedOut(let received, let seconds):
            return "the scrcpy server sent no stream header within \(String(format: "%.1f", seconds))s (\(received) of \(ScrcpyFraming.handshakeByteCount) bytes received)"
        }
    }
}

/// Incremental reader for a scrcpy video socket. Feed it every chunk of bytes
/// in arrival order; it parses the handshake once and then emits packets,
/// tolerating arbitrary chunk boundaries.
///
/// Memory stays bounded by what is buffered, not by what has streamed:
/// consumed bytes are only skipped with `readOffset` and physically dropped
/// when the next chunk is appended. The buffer is never re-sliced: a
/// `Data`/`Array` slice keeps its whole backing store alive, and appending to
/// it grows that store in place, so `buffer = buffer.dropFirst(n)` retained
/// every byte ever received (about 1 MB per second of mirroring).
public struct ScrcpyStreamReader: Sendable {
    /// Buffers above this capacity are reallocated to fit once they drain, so
    /// one large keyframe does not pin its peak for the rest of the session.
    static let retainedCapacity = 4 << 20

    private var buffer: [UInt8] = []
    /// How many leading bytes of `buffer` are already consumed.
    private var readOffset = 0
    private let expectsDummyByte: Bool
    private let maximumPacketSize: Int
    /// The no-progress deadline for an incomplete packet; nil disables it.
    private let stallTimeout: TimeInterval?
    /// The deadline for the stream header, measured from `startedAt`; nil
    /// disables it.
    private let handshakeTimeout: TimeInterval?
    private let startedAt: ContinuousClock.Instant
    /// When `buffer` last grew, for the stall deadline. A monotonic instant:
    /// a wall-clock step must never look like a stream that stopped sending
    /// (or hide one that did).
    private var lastProgress: ContinuousClock.Instant?

    /// The handshake, as soon as it has been parsed.
    public private(set) var header: ScrcpyStreamHeader?

    /// - Parameters:
    ///   - expectsDummyByte: true for a raw socket, whose first byte is the
    ///     server's dummy byte; false when the caller already consumed it (as
    ///     `ScrcpyServerLauncher` does).
    ///   - stallTimeout: how long an incomplete packet may stop growing before
    ///     `nextPacket`/`checkStall` throw `stalledPacket`; nil never expires.
    ///   - handshakeTimeout: how long after `startedAt` the stream header may
    ///     take before `nextPacket`/`checkStall` throw `handshakeTimedOut`;
    ///     nil never expires.
    public init(
        expectsDummyByte: Bool = false,
        maximumPacketSize: Int = ScrcpyFraming.defaultMaximumPacketSize,
        stallTimeout: TimeInterval? = nil,
        handshakeTimeout: TimeInterval? = nil,
        startedAt: ContinuousClock.Instant = ContinuousClock.now
    ) {
        self.expectsDummyByte = expectsDummyByte
        self.maximumPacketSize = maximumPacketSize
        self.stallTimeout = stallTimeout
        self.handshakeTimeout = handshakeTimeout
        self.startedAt = startedAt
    }

    /// Bytes received but not yet consumed.
    var bufferedByteCount: Int {
        buffer.count - readOffset
    }

    /// The allocated size of the internal buffer (the memory the reader pins).
    var bufferCapacity: Int {
        buffer.capacity
    }

    public mutating func append(
        _ data: Data,
        at now: ContinuousClock.Instant = ContinuousClock.now
    ) {
        if !data.isEmpty {
            lastProgress = now
        }
        compact()
        buffer.append(contentsOf: data)
        if header == nil {
            // Parse eagerly so the header is readable as soon as it arrives;
            // codec-disabled errors stay latched in the buffer and are thrown
            // by nextPacket().
            header = try? parseHandshake()
        }
    }

    /// Returns the next complete packet, or nil when more bytes are needed.
    /// Never consumes bytes when it throws. When a deadline is set and has
    /// passed (the header never arrived, or an incomplete packet made no
    /// progress), throws instead of waiting forever.
    public mutating func nextPacket(
        at now: ContinuousClock.Instant = ContinuousClock.now
    ) throws -> FramePacket? {
        if header == nil {
            guard let parsedHeader = try parseHandshake() else {
                if let stall = stallError(at: now) { throw stall }
                return nil
            }
            header = parsedHeader
        }

        let offset = readOffset
        let maximumPacketSize = self.maximumPacketSize
        guard let packet = try buffer.withUnsafeBytes({ raw in
            try ScrcpyFraming.parsePacket(
                raw: UnsafeRawBufferPointer(rebasing: raw[offset...]),
                maximumPacketSize: maximumPacketSize
            )
        }) else {
            if let stall = stallError(at: now) { throw stall }
            return nil
        }
        readOffset += ScrcpyFraming.packetHeaderSize + packet.payload.count
        return packet
    }

    /// Throws when a deadline has passed: the header has not arrived within
    /// the handshake deadline, or an incomplete packet has made no progress
    /// within the stall deadline. The idle case (header parsed, no partial
    /// packet buffered) never stalls: a static screen may legitimately
    /// produce no packets for a long time.
    public mutating func checkStall(
        at now: ContinuousClock.Instant = ContinuousClock.now
    ) throws {
        if let stall = stallError(at: now) { throw stall }
    }

    private func stallError(at now: ContinuousClock.Instant) -> ScrcpyFramingError? {
        guard header != nil else {
            guard let handshakeTimeout,
                  now - startedAt >= .seconds(handshakeTimeout)
            else { return nil }
            return .handshakeTimedOut(
                receivedBytes: bufferedByteCount,
                seconds: handshakeTimeout
            )
        }

        guard let stallTimeout, let lastProgress else { return nil }
        let offset = readOffset
        guard let declared = buffer.withUnsafeBytes({ raw in
            ScrcpyFraming.declaredPacketSize(in: UnsafeRawBufferPointer(rebasing: raw[offset...]))
        }) else { return nil }

        let received = bufferedByteCount - ScrcpyFraming.packetHeaderSize
        guard received < declared else { return nil }
        guard now - lastProgress >= .seconds(stallTimeout) else { return nil }
        return .stalledPacket(
            receivedBytes: received,
            declaredBytes: declared,
            seconds: stallTimeout
        )
    }

    /// Drops the consumed prefix. Runs before each append, so the memmove
    /// covers at most the partial packet left over from the previous chunk.
    private mutating func compact() {
        guard readOffset > 0 else { return }
        let remaining = buffer.count - readOffset
        if buffer.capacity > Self.retainedCapacity, remaining <= Self.retainedCapacity / 2 {
            buffer = Array(buffer[readOffset...])
        } else {
            buffer.removeSubrange(0..<readOffset)
        }
        readOffset = 0
    }

    /// Consumes and returns the handshake once enough bytes are buffered.
    private mutating func parseHandshake() throws -> ScrcpyStreamHeader? {
        let skipped = expectsDummyByte ? ScrcpyFraming.dummyByteSize : 0
        let start = readOffset + skipped
        guard buffer.count > start else { return nil }

        guard let parsed = try buffer.withUnsafeBytes({ raw in
            try ScrcpyFraming.parseHandshake(raw: UnsafeRawBufferPointer(rebasing: raw[start...]))
        }) else {
            return nil
        }
        readOffset = start + ScrcpyFraming.handshakeByteCount
        return parsed
    }
}
