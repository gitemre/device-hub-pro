import XCTest
@testable import DeviceHubProKit

/// Byte-exact serialization of the scrcpy v3.1 control protocol. The expected
/// bytes follow `app/src/control_msg.c` (`sc_control_msg_serialize`) and the
/// fixtures of upstream's `app/tests/test_control_msg_serialize.c`; the
/// server's `ControlMessageReader.java` reads the same layouts back.
final class ScrcpyControlTests: XCTestCase {
    // MARK: - Control messages

    func testMessageTypeValuesMatchTheProtocol() {
        XCTAssertEqual(ScrcpyControl.typeInjectKeycode, 0)
        XCTAssertEqual(ScrcpyControl.typeInjectText, 1)
        XCTAssertEqual(ScrcpyControl.typeInjectTouchEvent, 2)
        XCTAssertEqual(ScrcpyControl.typeInjectScrollEvent, 3)
        XCTAssertEqual(ScrcpyControl.typeBackOrScreenOn, 4)
        XCTAssertEqual(ScrcpyControl.typeGetClipboard, 8)
        XCTAssertEqual(ScrcpyControl.typeSetClipboard, 9)
        XCTAssertEqual(ScrcpyControl.injectTextMaximumLength, 300)
        XCTAssertEqual(ScrcpyControl.clipboardTextMaximumLength, (1 << 18) - 14)
        XCTAssertEqual(ScrcpyControl.pointerIDMouse, 0xFFFF_FFFF_FFFF_FFFF)
        XCTAssertEqual(ScrcpyControl.pointerIDGenericFinger, 0xFFFF_FFFF_FFFF_FFFE)
        XCTAssertEqual(ScrcpyControl.pointerIDVirtualFinger, 0xFFFF_FFFF_FFFF_FFFD)
    }

    func testInjectKeycodeSerializesActionKeycodeRepeatAndMetaState() {
        let message = ScrcpyControlMessage.injectKeycode(
            action: .up,
            keycode: 66,          // AKEYCODE_ENTER
            repeatCount: 5,
            metaState: 0x41       // AMETA_SHIFT_ON | AMETA_SHIFT_LEFT_ON
        )

        XCTAssertEqual([UInt8](message.serialized), [
            0x00,                    // INJECT_KEYCODE
            0x01,                    // AKEY_EVENT_ACTION_UP
            0x00, 0x00, 0x00, 0x42,  // keycode
            0x00, 0x00, 0x00, 0x05,  // repeat
            0x00, 0x00, 0x00, 0x41,  // meta state
        ])
    }

    func testInjectKeycodeDefaultsToNoRepeatAndNoMetaState() {
        let message = ScrcpyControlMessage.injectKeycode(action: .down, keycode: 67)

        XCTAssertEqual([UInt8](message.serialized), [
            0x00, 0x00,
            0x00, 0x00, 0x00, 0x43,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])
    }

    func testInjectTextSerializesALengthPrefixedUTF8String() {
        let message = ScrcpyControlMessage.injectText("hello, world!")

        XCTAssertEqual([UInt8](message.serialized), [
            0x01,                    // INJECT_TEXT
            0x00, 0x00, 0x00, 0x0D,  // 13 bytes
        ] + Array("hello, world!".utf8))
    }

    func testInjectTextIsTruncatedToThreeHundredBytes() {
        let message = ScrcpyControlMessage.injectText(String(repeating: "a", count: 350))
        let bytes = [UInt8](message.serialized)

        XCTAssertEqual(bytes.count, 1 + 4 + 300)
        XCTAssertEqual(Array(bytes[0..<5]), [0x01, 0x00, 0x00, 0x01, 0x2C])
    }

    /// `sc_str_utf8_truncation_index`: the cut never splits a character.
    func testTruncationBacksUpToACharacterBoundary() {
        let text = String(repeating: "a", count: 299) + "é"   // é = C3 A9
        let bytes = [UInt8](ScrcpyControlMessage.injectText(text).serialized)

        XCTAssertEqual(Array(bytes[1..<5]), [0x00, 0x00, 0x01, 0x2B], "299 bytes")
        XCTAssertEqual(bytes.count, 1 + 4 + 299)
        XCTAssertEqual(ScrcpyControl.utf8TruncationIndex(Array(text.utf8), maximum: 300), 299)
        XCTAssertEqual(ScrcpyControl.utf8TruncationIndex(Array(text.utf8), maximum: 301), 301)
    }

    func testInjectTouchEventSerializesThe32ByteLayout() {
        let message = ScrcpyControlMessage.injectTouch(
            action: .down,
            pointerID: 0x1234_5678_8765_4321,
            position: ScrcpyPosition(x: 100, y: 200, screenWidth: 1080, screenHeight: 1920),
            pressure: 1,
            actionButton: 1,   // AMOTION_EVENT_BUTTON_PRIMARY
            buttons: 1
        )

        XCTAssertEqual([UInt8](message.serialized), [
            0x02,                                            // INJECT_TOUCH_EVENT
            0x00,                                            // AMOTION_EVENT_ACTION_DOWN
            0x12, 0x34, 0x56, 0x78, 0x87, 0x65, 0x43, 0x21,  // pointer id
            0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0xC8,  // 100, 200
            0x04, 0x38, 0x07, 0x80,                          // 1080 x 1920
            0xFF, 0xFF,                                      // pressure 1.0
            0x00, 0x00, 0x00, 0x01,                          // action button
            0x00, 0x00, 0x00, 0x01,                          // buttons
        ])
    }

    func testInjectTouchEventEncodesAFingerReleaseAtZeroPressure() {
        let message = ScrcpyControlMessage.injectTouch(
            action: .up,
            pointerID: 2,
            position: ScrcpyPosition(x: 1079, y: 2399, screenWidth: 1080, screenHeight: 2400),
            pressure: 0
        )

        XCTAssertEqual([UInt8](message.serialized), [
            0x02,
            0x01,                                            // ACTION_UP
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
            0x00, 0x00, 0x04, 0x37, 0x00, 0x00, 0x09, 0x5F,  // 1079, 2399
            0x04, 0x38, 0x09, 0x60,                          // 1080 x 2400
            0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])
    }

    func testInjectScrollEventSerializesThe21ByteLayout() {
        let message = ScrcpyControlMessage.injectScroll(
            position: ScrcpyPosition(x: 260, y: 1026, screenWidth: 1080, screenHeight: 1920),
            horizontal: 1,
            vertical: -1,
            buttons: 1
        )

        XCTAssertEqual([UInt8](message.serialized), [
            0x03,                                            // INJECT_SCROLL_EVENT
            0x00, 0x00, 0x01, 0x04, 0x00, 0x00, 0x04, 0x02,  // 260, 1026
            0x04, 0x38, 0x07, 0x80,                          // 1080 x 1920
            0x7F, 0xFF,                                      // +1.0 saturates
            0x80, 0x00,                                      // -1.0
            0x00, 0x00, 0x00, 0x01,                          // buttons
        ])
    }

    func testBackOrScreenOnSerializesItsAction() {
        XCTAssertEqual([UInt8](ScrcpyControlMessage.backOrScreenOn(action: .down).serialized), [0x04, 0x00])
        XCTAssertEqual([UInt8](ScrcpyControlMessage.backOrScreenOn(action: .up).serialized), [0x04, 0x01])
    }

    func testGetClipboardSerializesTheCopyKey() {
        XCTAssertEqual([UInt8](ScrcpyControlMessage.getClipboard(copyKey: .copy).serialized), [0x08, 0x01])
        XCTAssertEqual([UInt8](ScrcpyControlMessage.getClipboard(copyKey: .cut).serialized), [0x08, 0x02])
    }

    func testSetClipboardSerializesSequencePasteFlagAndText() {
        let message = ScrcpyControlMessage.setClipboard(
            sequence: 0x0102_0304_0506_0708,
            paste: true,
            text: "hello, world!"
        )

        XCTAssertEqual([UInt8](message.serialized), [
            0x09,                                            // SET_CLIPBOARD
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,  // sequence
            0x01,                                            // paste
            0x00, 0x00, 0x00, 0x0D,                          // 13 bytes
        ] + Array("hello, world!".utf8))
    }

    func testSetClipboardCarriesNonASCIITextVerbatim() {
        let message = ScrcpyControlMessage.setClipboard(sequence: 0, paste: false, text: "çşğı")
        let bytes = [UInt8](message.serialized)

        XCTAssertEqual(bytes[9], 0x00, "paste flag")
        XCTAssertEqual(Array(bytes[10..<14]), [0x00, 0x00, 0x00, 0x08])
        XCTAssertEqual(Array(bytes[14...]), Array("çşğı".utf8))
    }

    // MARK: - Fixed point

    func testUnsignedFixedPointMatchesScrcpy() {
        XCTAssertEqual(ScrcpyControl.unsignedFixedPoint(0), 0x0000)
        XCTAssertEqual(ScrcpyControl.unsignedFixedPoint(0.5), 0x8000)
        XCTAssertEqual(ScrcpyControl.unsignedFixedPoint(1), 0xFFFF)
        XCTAssertEqual(ScrcpyControl.unsignedFixedPoint(2), 0xFFFF, "out of range clamps")
        XCTAssertEqual(ScrcpyControl.unsignedFixedPoint(-1), 0x0000)
    }

    func testSignedFixedPointMatchesScrcpy() {
        XCTAssertEqual(ScrcpyControl.signedFixedPoint(0), 0)
        XCTAssertEqual(ScrcpyControl.signedFixedPoint(0.5), 0x4000)
        XCTAssertEqual(ScrcpyControl.signedFixedPoint(-0.5), -0x4000)
        XCTAssertEqual(ScrcpyControl.signedFixedPoint(1), 0x7FFF)
        XCTAssertEqual(ScrcpyControl.signedFixedPoint(-1), -0x8000)
        XCTAssertEqual(ScrcpyControl.signedFixedPoint(-3), -0x8000)
    }

    func testTextChunksNeverSplitACharacter() {
        XCTAssertEqual(ScrcpyControl.textChunks("abcde", maximumBytes: 2), ["ab", "cd", "e"])
        XCTAssertEqual(ScrcpyControl.textChunks("aé", maximumBytes: 2), ["a", "é"])
        XCTAssertEqual(ScrcpyControl.textChunks("", maximumBytes: 2), [])
        let long = String(repeating: "x", count: 650)
        XCTAssertEqual(ScrcpyControl.textChunks(long).map(\.utf8.count), [300, 300, 50])
    }

    // MARK: - Device messages

    func testParsesAClipboardDeviceMessage() throws {
        var reader = ScrcpyDeviceMessageReader()
        reader.append(Data([0x00, 0x00, 0x00, 0x00, 0x03]) + Data("ABC".utf8))

        XCTAssertEqual(try reader.nextMessage(), .clipboard("ABC"))
        XCTAssertNil(try reader.nextMessage())
    }

    func testParsesAClipboardAckAndUhidOutput() throws {
        var reader = ScrcpyDeviceMessageReader()
        reader.append(Data([0x01, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))
        reader.append(Data([0x02, 0x00, 0x2A, 0x00, 0x02, 0xAB, 0xCD]))

        XCTAssertEqual(try reader.nextMessage(), .ackClipboard(sequence: 0x0102_0304_0506_0708))
        XCTAssertEqual(try reader.nextMessage(), .uhidOutput(id: 42, data: Data([0xAB, 0xCD])))
        XCTAssertNil(try reader.nextMessage())
    }

    func testDeviceMessagesSurviveArbitraryChunkBoundaries() throws {
        var stream = Data([0x00, 0x00, 0x00, 0x00, 0x05]) + Data("çağ".utf8)   // 5 UTF-8 bytes
        stream.append(contentsOf: [0x01, 0, 0, 0, 0, 0, 0, 0, 0x07])
        var reader = ScrcpyDeviceMessageReader()
        var messages: [ScrcpyDeviceMessage] = []

        for byte in stream {
            reader.append(Data([byte]))
            while let message = try reader.nextMessage() {
                messages.append(message)
            }
        }

        XCTAssertEqual(messages, [.clipboard("çağ"), .ackClipboard(sequence: 7)])
    }

    func testUnknownDeviceMessageTypesAndOversizedClipboardsThrow() {
        var unknown = ScrcpyDeviceMessageReader()
        unknown.append(Data([0x7F]))
        XCTAssertThrowsError(try unknown.nextMessage()) { error in
            XCTAssertEqual(error as? ScrcpyDeviceMessageError, .unknownType(0x7F))
        }

        var oversized = ScrcpyDeviceMessageReader()
        oversized.append(Data([0x00, 0x00, 0x04, 0x00, 0x00]))   // 256 KiB
        XCTAssertThrowsError(try oversized.nextMessage()) { error in
            XCTAssertEqual(error as? ScrcpyDeviceMessageError, .oversizedClipboard(length: 1 << 18))
        }
    }
}
