import Foundation

/// Wire format of the scrcpy (v3.1) control socket.
///
/// The client writes control messages (`app/src/control_msg.c`,
/// `sc_control_msg_serialize`; read back by the server's
/// `server/src/main/java/com/genymobile/scrcpy/control/ControlMessageReader.java`)
/// and the server writes device messages (`.../control/DeviceMessageWriter.java`,
/// parsed by the client's `app/src/device_msg.c`). Every integer is
/// big-endian; strings are UTF-8 prefixed with a 4-byte length.
public enum ScrcpyControl {
    /// `enum sc_control_msg_type` / `ControlMessage.TYPE_*`.
    static let typeInjectKeycode: UInt8 = 0
    static let typeInjectText: UInt8 = 1
    static let typeInjectTouchEvent: UInt8 = 2
    static let typeInjectScrollEvent: UInt8 = 3
    static let typeBackOrScreenOn: UInt8 = 4
    static let typeGetClipboard: UInt8 = 8
    static let typeSetClipboard: UInt8 = 9

    /// `enum sc_device_msg_type` / `DeviceMessage.TYPE_*`.
    static let deviceTypeClipboard: UInt8 = 0
    static let deviceTypeAckClipboard: UInt8 = 1
    static let deviceTypeUhidOutput: UInt8 = 2

    /// `SC_CONTROL_MSG_MAX_SIZE` / `DEVICE_MSG_MAX_SIZE` (256 KiB).
    public static let messageMaximumSize = 1 << 18
    /// `SC_CONTROL_MSG_INJECT_TEXT_MAX_LENGTH`: longer text is truncated by
    /// the serializer, so callers split it first (see ``textChunks(_:maximumBytes:)``).
    public static let injectTextMaximumLength = 300
    /// `SC_CONTROL_MSG_CLIPBOARD_TEXT_MAX_LENGTH`: the message minus its
    /// 14-byte header (type, sequence, paste flag, length).
    public static let clipboardTextMaximumLength = messageMaximumSize - 14
    /// `DEVICE_MSG_TEXT_MAX_LENGTH`: a device clipboard message minus its
    /// 5-byte header (type, length).
    public static let deviceClipboardTextMaximumLength = messageMaximumSize - 5

    /// `SC_POINTER_ID_MOUSE` (-1): the server treats it as a mouse pointer
    /// for hover and secondary buttons, and as a finger otherwise.
    public static let pointerIDMouse = UInt64(bitPattern: -1)
    /// `SC_POINTER_ID_GENERIC_FINGER` (-2).
    public static let pointerIDGenericFinger = UInt64(bitPattern: -2)
    /// `SC_POINTER_ID_VIRTUAL_FINGER` (-3).
    public static let pointerIDVirtualFinger = UInt64(bitPattern: -3)
    /// `SC_SEQUENCE_INVALID`: a clipboard request that wants no ACK.
    public static let sequenceInvalid: UInt64 = 0

    /// `sc_float_to_u16fp`: [0, 1] as 16-bit unsigned fixed point, where
    /// 1.0 saturates to 0xFFFF.
    static func unsignedFixedPoint(_ value: Float) -> UInt16 {
        let clamped = min(max(value.isNaN ? 0 : value, 0), 1)
        let scaled = UInt32(clamped * 65_536)
        return UInt16(min(scaled, 0xFFFF))
    }

    /// `sc_float_to_i16fp`: [-1, 1] as 16-bit signed fixed point, where 1.0
    /// saturates to 0x7FFF.
    static func signedFixedPoint(_ value: Float) -> Int16 {
        let clamped = min(max(value.isNaN ? 0 : value, -1), 1)
        let scaled = Int32(clamped * 32_768)
        return Int16(min(scaled, 0x7FFF))
    }

    /// `sc_str_utf8_truncation_index`: the longest prefix of `bytes` of at
    /// most `maximum` bytes that does not split a UTF-8 sequence.
    static func utf8TruncationIndex(_ bytes: [UInt8], maximum: Int) -> Int {
        guard bytes.count > maximum else { return bytes.count }
        var length = maximum
        // A continuation byte (10xxxxxx) at the cut belongs to the character
        // being cut; back up to that character's first byte.
        while length > 0, bytes[length] & 0xC0 == 0x80 {
            length -= 1
        }
        return length
    }

    /// Splits `text` into pieces of at most `maximumBytes` UTF-8 bytes each,
    /// never inside a character, so long text survives the per-message cap.
    public static func textChunks(
        _ text: String,
        maximumBytes: Int = injectTextMaximumLength
    ) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentBytes = 0
        for character in text {
            let size = character.utf8.count
            if currentBytes + size > maximumBytes, !current.isEmpty {
                chunks.append(current)
                current = ""
                currentBytes = 0
            }
            current.append(character)
            currentBytes += size
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}

/// A point in the video frame together with the frame size it refers to
/// (`struct sc_position`). The server maps it to display coordinates itself
/// and drops the event when the size is not its current video size (the
/// device rotated after the event was generated).
public struct ScrcpyPosition: Equatable, Sendable {
    public var x: Int32
    public var y: Int32
    public var screenWidth: UInt16
    public var screenHeight: UInt16

    public init(x: Int32, y: Int32, screenWidth: UInt16, screenHeight: UInt16) {
        self.x = x
        self.y = y
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }
}

/// One client → server control message.
public enum ScrcpyControlMessage: Equatable, Sendable {
    /// Android `KeyEvent.ACTION_*`.
    public enum KeyAction: UInt8, Sendable {
        case down = 0
        case up = 1
    }

    /// Android `MotionEvent.ACTION_*` (the server turns a second pointer's
    /// down/up into `ACTION_POINTER_DOWN/UP` itself).
    public enum TouchAction: UInt8, Sendable {
        case down = 0
        case up = 1
        case move = 2
    }

    /// `enum sc_copy_key`.
    public enum CopyKey: UInt8, Sendable {
        case none = 0
        case copy = 1
        case cut = 2
    }

    case injectKeycode(action: KeyAction, keycode: Int32, repeatCount: Int32 = 0, metaState: Int32 = 0)
    /// Typed through the device's virtual key map: characters it cannot map
    /// (most non-ASCII) are dropped by the server.
    case injectText(String)
    /// `pressure` is in [0, 1]; `actionButton`/`buttons` are
    /// `MotionEvent.BUTTON_*` masks (0 for a finger).
    case injectTouch(
        action: TouchAction,
        pointerID: UInt64,
        position: ScrcpyPosition,
        pressure: Float,
        actionButton: UInt32 = 0,
        buttons: UInt32 = 0
    )
    /// `horizontal`/`vertical` are wheel steps in [-1, 1], applied as
    /// `AXIS_HSCROLL`/`AXIS_VSCROLL`.
    case injectScroll(position: ScrcpyPosition, horizontal: Float, vertical: Float, buttons: UInt32 = 0)
    /// BACK, or POWER when the screen is off (scrcpy's right click).
    case backOrScreenOn(action: KeyAction)
    case getClipboard(copyKey: CopyKey)
    /// Sets the device clipboard; `paste` also injects `KEYCODE_PASTE`
    /// (Android 7+). A non-zero `sequence` asks for an ACK device message.
    case setClipboard(sequence: UInt64, paste: Bool, text: String)

    /// The exact bytes `sc_control_msg_serialize` writes for this message.
    public var serialized: Data {
        var writer = BigEndianWriter()
        switch self {
        case .injectKeycode(let action, let keycode, let repeatCount, let metaState):
            writer.u8(ScrcpyControl.typeInjectKeycode)
            writer.u8(action.rawValue)
            writer.u32(UInt32(bitPattern: keycode))
            writer.u32(UInt32(bitPattern: repeatCount))
            writer.u32(UInt32(bitPattern: metaState))

        case .injectText(let text):
            writer.u8(ScrcpyControl.typeInjectText)
            writer.string(text, maximum: ScrcpyControl.injectTextMaximumLength)

        case .injectTouch(let action, let pointerID, let position, let pressure, let actionButton, let buttons):
            writer.u8(ScrcpyControl.typeInjectTouchEvent)
            writer.u8(action.rawValue)
            writer.u64(pointerID)
            writer.position(position)
            writer.u16(ScrcpyControl.unsignedFixedPoint(pressure))
            writer.u32(actionButton)
            writer.u32(buttons)

        case .injectScroll(let position, let horizontal, let vertical, let buttons):
            writer.u8(ScrcpyControl.typeInjectScrollEvent)
            writer.position(position)
            writer.u16(UInt16(bitPattern: ScrcpyControl.signedFixedPoint(horizontal)))
            writer.u16(UInt16(bitPattern: ScrcpyControl.signedFixedPoint(vertical)))
            writer.u32(buttons)

        case .backOrScreenOn(let action):
            writer.u8(ScrcpyControl.typeBackOrScreenOn)
            writer.u8(action.rawValue)

        case .getClipboard(let copyKey):
            writer.u8(ScrcpyControl.typeGetClipboard)
            writer.u8(copyKey.rawValue)

        case .setClipboard(let sequence, let paste, let text):
            writer.u8(ScrcpyControl.typeSetClipboard)
            writer.u64(sequence)
            writer.u8(paste ? 1 : 0)
            writer.string(text, maximum: ScrcpyControl.clipboardTextMaximumLength)
        }
        return writer.data
    }
}

/// One server → client device message.
public enum ScrcpyDeviceMessage: Equatable, Sendable {
    /// The device clipboard changed (clipboard autosync) or was requested.
    case clipboard(String)
    /// The server applied the `setClipboard` with this sequence number.
    case ackClipboard(sequence: UInt64)
    case uhidOutput(id: UInt16, data: Data)
}

public enum ScrcpyDeviceMessageError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A type this client does not know; the stream cannot be re-synchronised.
    case unknownType(UInt8)
    /// A clipboard message longer than the protocol allows.
    case oversizedClipboard(length: Int)

    public var description: String {
        switch self {
        case .unknownType(let type):
            return "unknown scrcpy device message type \(type)"
        case .oversizedClipboard(let length):
            return "scrcpy device clipboard message of \(length) bytes exceeds the protocol maximum"
        }
    }
}

/// Incremental parser for the device-message side of the control socket.
/// Like ``ScrcpyStreamReader`` it keeps a read offset and compacts before
/// each append, so memory is bounded by one message.
struct ScrcpyDeviceMessageReader: Sendable {
    private var buffer: [UInt8] = []
    private var readOffset = 0

    mutating func append(_ bytes: UnsafeRawBufferPointer) {
        if readOffset > 0 {
            buffer.removeSubrange(0..<readOffset)
            readOffset = 0
        }
        buffer.append(contentsOf: bytes)
    }

    mutating func append(_ data: Data) {
        data.withUnsafeBytes { append($0) }
    }

    /// The next complete message, or nil when more bytes are needed.
    mutating func nextMessage() throws -> ScrcpyDeviceMessage? {
        let available = buffer.count - readOffset
        guard available >= 1 else { return nil }
        let base = readOffset

        switch buffer[base] {
        case ScrcpyControl.deviceTypeClipboard:
            guard available >= 5 else { return nil }
            let length = Int(readUInt32(at: base + 1))
            guard length <= ScrcpyControl.deviceClipboardTextMaximumLength else {
                throw ScrcpyDeviceMessageError.oversizedClipboard(length: length)
            }
            guard available >= 5 + length else { return nil }
            let text = String(decoding: buffer[(base + 5)..<(base + 5 + length)], as: UTF8.self)
            readOffset += 5 + length
            return .clipboard(text)

        case ScrcpyControl.deviceTypeAckClipboard:
            guard available >= 9 else { return nil }
            let sequence = UInt64(readUInt32(at: base + 1)) << 32 | UInt64(readUInt32(at: base + 5))
            readOffset += 9
            return .ackClipboard(sequence: sequence)

        case ScrcpyControl.deviceTypeUhidOutput:
            guard available >= 5 else { return nil }
            let id = readUInt16(at: base + 1)
            let size = Int(readUInt16(at: base + 3))
            guard available >= 5 + size else { return nil }
            let data = Data(buffer[(base + 5)..<(base + 5 + size)])
            readOffset += 5 + size
            return .uhidOutput(id: id, data: data)

        default:
            throw ScrcpyDeviceMessageError.unknownType(buffer[base])
        }
    }

    private func readUInt16(at index: Int) -> UInt16 {
        UInt16(buffer[index]) << 8 | UInt16(buffer[index + 1])
    }

    private func readUInt32(at index: Int) -> UInt32 {
        UInt32(buffer[index]) << 24
            | UInt32(buffer[index + 1]) << 16
            | UInt32(buffer[index + 2]) << 8
            | UInt32(buffer[index + 3])
    }
}

/// Big-endian serialization helpers (`sc_write16be`/`32be`/`64be`).
private struct BigEndianWriter {
    var data = Data()

    mutating func u8(_ value: UInt8) {
        data.append(value)
    }

    mutating func u16(_ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func u32(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func u64(_ value: UInt64) {
        u32(UInt32(truncatingIfNeeded: value >> 32))
        u32(UInt32(truncatingIfNeeded: value))
    }

    /// `write_position`: x, y (32-bit) then the frame size (16-bit).
    mutating func position(_ position: ScrcpyPosition) {
        u32(UInt32(bitPattern: position.x))
        u32(UInt32(bitPattern: position.y))
        u16(position.screenWidth)
        u16(position.screenHeight)
    }

    /// `write_string`: a 4-byte length, then the UTF-8 bytes truncated to
    /// `maximum` on a character boundary.
    mutating func string(_ text: String, maximum: Int) {
        let bytes = Array(text.utf8)
        let length = ScrcpyControl.utf8TruncationIndex(bytes, maximum: maximum)
        u32(UInt32(length))
        data.append(contentsOf: bytes[0..<length])
    }
}
