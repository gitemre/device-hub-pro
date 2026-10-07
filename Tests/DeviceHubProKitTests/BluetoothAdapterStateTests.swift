import XCTest
@testable import DeviceHubProKit

/// The adapter reading behind a `bluetooth_on` of 2: BluetoothManagerService's
/// status lines, not the persisted setting.
final class BluetoothAdapterStateTests: XCTestCase {
    /// SOURCE-DERIVED (API 26-36 BluetoothManagerService.dump, where
    /// `enabled:` is `state == ON`): the state line decides.
    func testTheStateLineDecidesTheOlderStatusBlock() {
        XCTAssertEqual(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: "  enabled: true\n  state: ON\n"), true)
        XCTAssertEqual(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: "  enabled: false\n  state: OFF\n"), false)
        XCTAssertEqual(
            AdbClient.bluetoothAdapterEnabled(fromManagerStatus: "  enabled: false\n  state: BLE_ON\n"),
            false,
            "BLE-only scanning is not Bluetooth on"
        )
    }

    /// SOURCE-DERIVED: `nameForState` (API 26+) and AdapterService's
    /// `STATE_*` names (API 24-25, android-7.1.1_r1 AdapterService.dump).
    func testNamedStates() {
        XCTAssertEqual(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: "  state: ON\r\n"), true)
        XCTAssertEqual(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: "  state: STATE_ON\n"), true)
        XCTAssertEqual(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: "  state: TURNING_OFF\n"), false)
        XCTAssertEqual(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: "  state: STATE_OFF\n"), false)
        XCTAssertEqual(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: "  state: STATE_BLE_ON\n"), false)
        XCTAssertEqual(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: "  state: TURNING_ON\n"), false)
    }

    /// SOURCE-DERIVED: API 23 and older (android-6.0.1_r1 and
    /// android-5.1.1_r1 BluetoothManagerService.dump) print the raw
    /// BluetoothAdapter constant, `"  state: " + mState` (12 is STATE_ON,
    /// 10 STATE_OFF), and `enabled:` is `mEnable`, the requested state.
    func testNumericStatesOfApi23AndOlder() {
        XCTAssertEqual(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: "  state: 12\n"), true)
        XCTAssertEqual(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: "  state: 10\n"), false)
        for turningOrBLE in [11, 13, 14, 15, 16] {
            XCTAssertEqual(
                AdbClient.bluetoothAdapterEnabled(fromManagerStatus: "  state: \(turningOrBLE)\n"),
                false,
                "state \(turningOrBLE)"
            )
        }
        XCTAssertEqual(
            AdbClient.bluetoothAdapterEnabled(fromManagerStatus: "  enabled: true\n  state: 11\n"),
            false,
            "mEnable is only the request; the radio is still turning on"
        )
    }

    /// States no version names (`nameForState`'s `?!?!? (n)`, AdapterService's
    /// `UNKNOWN STATE: n`) leave the answer to the airplane-mode rule.
    func testAnUnknownStateIsUnknown() {
        XCTAssertNil(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: "  state: ?!?!? (99)\n"))
        XCTAssertNil(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: "  state: UNKNOWN STATE: 99\n"))
        XCTAssertNil(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: "  state: 99\n"))
        XCTAssertNil(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: "  state: \n"))
    }

    /// The API 37 Bluetooth module's status block (the byte-exact state line
    /// is `Fixtures/api37-emulator/controls/dumpsys-bluetooth_manager-state.txt`):
    /// capitalized, padded, no `enabled:` line.
    func testTheCapitalizedPaddedStateLineIsRead() {
        XCTAssertEqual(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: "  State:         ON\n"), true)
        XCTAssertEqual(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: "  State:         OFF\n"), false)
        XCTAssertEqual(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: "  State:         BLE_ON\n"), false)
        XCTAssertEqual(
            AdbClient.bluetoothAdapterEnabled(
                fromManagerStatus: "Bluetooth Status:\n  State:         ON\n  Address:       XX:XX:XX:XX:BB:BB\n"
            ),
            true
        )
    }

    func testNoStatusIsUnknown() {
        XCTAssertNil(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: ""))
        XCTAssertNil(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: "Can't find service: bluetooth_manager\n"))
    }

    /// One shell round trip that stops after the state line; on an older
    /// dump grep prints `  state: OFF` (SOURCE-DERIVED: BluetoothManagerService.dump).
    func testReadsTheManagerStatus() async throws {
        let adb = try FakeAdb([
            .init("dumpsys bluetooth_manager", output: "  state: OFF\n")
        ])

        let enabled = try await adb.client.bluetoothAdapterEnabled(serial: "emulator-5554")

        XCTAssertEqual(enabled, false)
        XCTAssertEqual(adb.calls, ["-s emulator-5554 shell \(AdbClient.bluetoothStatusCommand)"])
    }

    // MARK: - Real API 37 emulator output

    /// `adb shell dumpsys bluetooth_manager`: the API 37 Bluetooth module
    /// prints `Bluetooth Status:` / `  State:         ON`, with no
    /// `enabled:` line. `settings get global bluetooth_on` was `1` and the
    /// dump's own `mEnable:true` agrees.
    func testTheAdapterStateIsReadFromTheRealDump() throws {
        let dump = try ControlsAPI37Fixture.text("dumpsys-bluetooth_manager.txt")
        XCTAssertTrue(dump.hasPrefix("Bluetooth Status:\n  State:         ON\n"))
        XCTAssertTrue(dump.contains("\n  mEnable:true\n"))
        XCTAssertEqual(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: dump), true)
    }

    /// The status command's grep, run over the real dump, yields the state
    /// line — the output `adb shell "<bluetoothStatusCommand>"` returned.
    /// The previous case-sensitive `^ *(enabled|state): ` matched no line
    /// at all, so grep exited 1 and the reading was lost.
    func testTheStatusCommandFindsTheStateLineInTheRealDump() throws {
        let dump = try ControlsAPI37Fixture.text("dumpsys-bluetooth_manager.txt")
        let captured = try ControlsAPI37Fixture.text("dumpsys-bluetooth_manager-state.txt")
        XCTAssertEqual(captured, "  State:         ON\n")
        XCTAssertEqual(
            AdbClient.bluetoothStatusCommand,
            "dumpsys bluetooth_manager | grep -m 1 -iE '^ *state: '"
        )

        let matches = try grepLines(AdbClient.bluetoothStatePattern, caseInsensitive: true, in: dump)
        XCTAssertEqual(matches.first.map { $0 + "\n" }, captured)
        XCTAssertEqual(try grepLines("^ *(enabled|state): ", caseInsensitive: false, in: dump), [])

        XCTAssertEqual(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: captured), true)
    }

    /// SOURCE-DERIVED: from API 26 through Android 16
    /// (BluetoothManagerService.dump in packages/modules/Bluetooth,
    /// frameworks/base before that) the dump opens with `Bluetooth Status` /
    /// `  enabled: …` / `  state: …`, the state named by
    /// BluetoothAdapter.nameForState. The same grep takes the state line there.
    func testTheStatusCommandStillFindsTheOlderStateLine() throws {
        let older = """
        Bluetooth Status
          enabled: false
          state: BLE_ON
          address: 00:11:22:33:44:55
          name: Pixel 7
        """
        let matches = try grepLines(AdbClient.bluetoothStatePattern, caseInsensitive: true, in: older)
        let first = try XCTUnwrap(matches.first)
        XCTAssertEqual(first, "  state: BLE_ON")
        XCTAssertEqual(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: first), false)
        XCTAssertEqual(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: older), false)
    }

    /// SOURCE-DERIVED: the API 23 block (android-6.0.1_r1
    /// BluetoothManagerService.dump: `"  enabled: " + mEnable`,
    /// `"  state: " + mState`) with the radio on. The grep keeps
    /// `  state: 12`, which reads on.
    func testTheStatusCommandFindsTheNumericStateOfApi23() throws {
        let api23 = """
        Bluetooth Status
          enabled: true
          state: 12
          address: 00:11:22:33:44:55
          name: Nexus 5

        """
        let matches = try grepLines(AdbClient.bluetoothStatePattern, caseInsensitive: true, in: api23)
        let first = try XCTUnwrap(matches.first)
        XCTAssertEqual(first, "  state: 12")
        XCTAssertEqual(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: first + "\n"), true)
        XCTAssertEqual(AdbClient.bluetoothAdapterEnabled(fromManagerStatus: api23), true)
    }

    func testTheRealStateLineIsReadThroughTheClient() async throws {
        let adb = try FakeAdb([
            .init(
                "dumpsys bluetooth_manager",
                output: try ControlsAPI37Fixture.text("dumpsys-bluetooth_manager-state.txt")
            ),
        ])
        let enabled = try await adb.client.bluetoothAdapterEnabled(serial: "emulator-5554")
        XCTAssertEqual(enabled, true)
        XCTAssertEqual(adb.calls, ["-s emulator-5554 shell \(AdbClient.bluetoothStatusCommand)"])
    }

    /// The lines of `text` a `grep -E` of `pattern` prints (ICU and POSIX
    /// ERE agree on these patterns).
    private func grepLines(_ pattern: String, caseInsensitive: Bool, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(
            pattern: pattern,
            options: caseInsensitive ? [.caseInsensitive] : []
        )
        return text.components(separatedBy: "\n").filter { line in
            regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
    }
}
