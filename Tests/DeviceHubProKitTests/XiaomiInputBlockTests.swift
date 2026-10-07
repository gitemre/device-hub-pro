import XCTest
@testable import DeviceHubProKit

/// Detection of a Xiaomi phone that refuses the Mac's input, as pure
/// functions of the property values and the scrcpy server's console line.
/// Fixtures: `Fixtures/physical-xiaomi/` (real captures, see its README).
final class XiaomiInputBlockTests: XCTestCase {
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/physical-xiaomi", isDirectory: true)

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: Self.directory.appendingPathComponent(name), encoding: .utf8)
    }

    func testARealPhonesOutputIsBlocked() throws {
        let output = try fixture("shell-getprop-miui-adbinput-off.txt")
        XCTAssertEqual(XiaomiInputBlock.isBlocked(probeOutput: output), true)
    }

    func testMiuiOrHyperOSWithTheSwitchOffIsBlocked() {
        XCTAssertTrue(XiaomiInputBlock.isBlocked(miuiVersion: "V14", hyperOSVersion: "", adbInput: "0"))
        XCTAssertTrue(XiaomiInputBlock.isBlocked(miuiVersion: nil, hyperOSVersion: "OS1.0", adbInput: "0\n"))
    }

    func testTheSwitchOnIsNotBlocked() {
        XCTAssertFalse(XiaomiInputBlock.isBlocked(miuiVersion: "V816", hyperOSVersion: "OS1.0", adbInput: "1"))
        XCTAssertEqual(XiaomiInputBlock.isBlocked(probeOutput: "V816\nOS1.0\n1\n"), false)
    }

    func testAnUnreadableSwitchIsNotBlocked() {
        XCTAssertFalse(XiaomiInputBlock.isBlocked(miuiVersion: "V14", hyperOSVersion: "", adbInput: ""))
        XCTAssertFalse(XiaomiInputBlock.isBlocked(miuiVersion: "V14", hyperOSVersion: "", adbInput: nil))
    }

    func testAnotherMakersPhoneIsNeverBlockedByTheProperty() {
        XCTAssertFalse(XiaomiInputBlock.isBlocked(miuiVersion: "", hyperOSVersion: "", adbInput: "0"))
        XCTAssertEqual(XiaomiInputBlock.isBlocked(probeOutput: "\n\n0\n"), false)
    }

    /// A Xiaomi phone whose switch could not be read is unknown, not allowed.
    func testAnEmptySwitchOnAXiaomiPhoneIsUnknown() {
        XCTAssertNil(XiaomiInputBlock.isBlocked(probeOutput: "V816\nOS1.0\n\n"))
        XCTAssertEqual(XiaomiInputBlock.isBlocked(probeOutput: "\n\n\n"), false, "another maker's phone is not blocked")
    }

    func testShortProbeOutputIsUndecided() {
        XCTAssertNil(XiaomiInputBlock.isBlocked(probeOutput: ""))
        XCTAssertNil(XiaomiInputBlock.isBlocked(probeOutput: "V816\n"))
    }

    func testTheServerConsoleLineIsRecognised() throws {
        let line = try fixture("logcat-scrcpy-inject-denied.txt")
        XCTAssertTrue(XiaomiInputBlock.isInjectionDenied(logLine: line))
        XCTAssertFalse(XiaomiInputBlock.isInjectionDenied(logLine: "[server] INFO: Device: Xiaomi 2209116AG"))
        XCTAssertFalse(XiaomiInputBlock.isInjectionDenied(logLine: "java.lang.SecurityException: other"))
    }

    func testTheServerLogRemembersTheRefusalUntilCleared() throws {
        let log = ScrcpyServerLog()
        log.append("[server] INFO: ok\n")
        XCTAssertFalse(log.injectionDenied)
        log.append(try fixture("logcat-scrcpy-inject-denied.txt"))
        XCTAssertTrue(log.injectionDenied)
        log.clearInjectionDenied()
        XCTAssertFalse(log.injectionDenied)
    }
}
