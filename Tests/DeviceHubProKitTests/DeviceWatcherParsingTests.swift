import XCTest
@testable import DeviceHubProKit

/// `adb track-devices` framing and payload parsing. The byte streams are the
/// wire format platform-tools 37.0.0 writes: a 4-hex-digit length, then the
/// payload, with no header and no terminator (`0000` = no devices).
final class DeviceWatcherParsingTests: XCTestCase {
    // MARK: Payloads

    func testParsesPlainStateOnlyPayload() {
        let payload = "emulator-5554\tdevice\nHT4CWJT01234\tunauthorized\n"
        let devices = AdbParsing.trackDevicesSnapshot(from: payload)
        XCTAssertEqual(devices.map(\.serial), ["emulator-5554", "HT4CWJT01234"])
        XCTAssertEqual(devices.map(\.state), ["device", "unauthorized"])
        XCTAssertNil(devices[0].model)
    }

    /// The `-l` payload is the `devices -l` row format, details included.
    func testParsesLongPayloadWithDetails() {
        let payload = """
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
        R58M12345AB            offline transport_id:4

        """
        let devices = AdbParsing.trackDevicesSnapshot(from: payload)
        XCTAssertEqual(devices.map(\.serial), ["emulator-5554", "R58M12345AB"])
        XCTAssertEqual(devices.map(\.state), ["device", "offline"])
        XCTAssertEqual(devices[0].model, "sdk_gphone64_arm64")
        XCTAssertEqual(devices[0].product, "sdk_gphone64_arm64")
        XCTAssertEqual(devices[0].device, "emu64a")
        XCTAssertEqual(devices[0].transportID, "1")
        XCTAssertEqual(devices[1].transportID, "4")
    }

    func testPlainPayloadKeepsASerialWithSpaces() {
        let devices = AdbParsing.trackDevicesSnapshot(from: "(no serial number)\tdevice\n")
        XCTAssertEqual(devices.map(\.serial), ["(no serial number)"])
    }

    func testEmptyPayloadYieldsNoDevices() {
        XCTAssertTrue(AdbParsing.trackDevicesSnapshot(from: "").isEmpty)
    }

    // MARK: Framing

    func testDecodesTheEmptyListFrame() throws {
        var decoder = AdbHostFrameDecoder()
        XCTAssertEqual(try decoder.append(Data("0000".utf8)), [""])
    }

    func testDecodesBackToBackFramesFromOneRead() throws {
        var decoder = AdbHostFrameDecoder()
        let bytes = Data("0015emulator-5554\tdevice\n0000".utf8)
        XCTAssertEqual(try decoder.append(bytes), ["emulator-5554\tdevice\n", ""])
    }

    /// Reads split frames anywhere — inside the length and inside the
    /// payload — and a frame completes only once all of its bytes are in.
    func testReassemblesFramesSplitAcrossReads() throws {
        var decoder = AdbHostFrameDecoder()
        XCTAssertEqual(try decoder.append(Data("00".utf8)), [])
        XCTAssertEqual(try decoder.append(Data("15emulator".utf8)), [])
        XCTAssertEqual(try decoder.append(Data("-5554\tdevice\n00".utf8)), ["emulator-5554\tdevice\n"])
        XCTAssertEqual(try decoder.append(Data("0".utf8)), [])
        XCTAssertEqual(try decoder.append(Data("0".utf8)), [""])
    }

    /// Lengths are hex and count bytes, not characters.
    func testLengthIsHexadecimalByteCount() throws {
        var decoder = AdbHostFrameDecoder()
        let payload = String(repeating: "a", count: 26) + "é\n"
        let length = String(format: "%04x", payload.utf8.count)
        XCTAssertEqual(length, "001d")
        XCTAssertEqual(try decoder.append(Data((length + payload).utf8)), [payload])
    }

    /// The header-and-blank-line format the watcher once assumed is not adb
    /// framing: decoding refuses it rather than misreading `List` as a length.
    func testRejectsUnframedOutput() {
        var decoder = AdbHostFrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data("List of devices attached\n".utf8))) { error in
            XCTAssertEqual(error as? AdbHostFrameDecoder.DecodingError, .invalidLengthPrefix("List"))
        }
    }
}
