import XCTest
@testable import DeviceHubProKit

/// `DiagnosticsBundle` fed the real answers of an API 37 emulator (see
/// `LogcatSdkApkFixtures`) through a stub `adb` that replays the captured
/// bytes. Expected values were read off the fixtures and cross-checked with
/// the device (`ps`, `getprop <key>`).
final class DiagnosticsRealOutputTests: XCTestCase {
    /// The whole bundle from real section output: the cutoff comes from the
    /// device's own `date +%s`, raw sections are archived byte for byte and
    /// `getprop.txt` keeps every property, multi-line values included.
    func testCollectArchivesRealSectionsAndEveryProperty() async throws {
        let directory = try LogcatSdkApkFixtures.temporaryDirectory(self, prefix: "diagnostics-real")
        let trace = directory.appendingPathComponent("calls.log")
        func fixture(_ name: String) -> String { LogcatSdkApkFixtures.url(name).path }
        // The logcat section replays a real threadtime dump (its non-ASCII
        // bytes must survive); the five-minute window itself is ~1 MB on a
        // busy emulator, too big to keep.
        let adb = try LogcatSdkApkFixtures.script("""
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(trace.path)"
            case "$*" in
              *"shell date +%s") cat "\(fixture("shell-date-s.txt"))" ;;
              *"logcat -d -v threadtime -t 1790280559.000") cat "\(fixture("logcat-d-v-threadtime-pid-4628.txt"))" ;;
              *"shell dumpsys battery") cat "\(fixture("shell-dumpsys-battery.txt"))" ;;
              *"shell dumpsys meminfo") cat "\(fixture("shell-dumpsys-meminfo.txt"))" ;;
              *"shell getprop") cat "\(fixture("shell-getprop.txt"))" ;;
              *) printf 'unexpected: %s\\n' "$*" >&2; exit 1 ;;
            esac
            """, named: "adb", in: directory)

        let result = try await DiagnosticsBundle.collect(
            serial: "emulator-5554",
            adb: AdbClient(adbURL: adb),
            into: directory.appendingPathComponent("out", isDirectory: true)
        )

        XCTAssertFalse(result.usedHostClockFallback)
        XCTAssertEqual(result.failedSections, [])
        XCTAssertFalse(result.usedLogcatLineFallback)
        // `date +%s` answered `1790280859\n`: the cutoff is 300 s earlier.
        XCTAssertEqual(
            try String(contentsOf: trace, encoding: .utf8).split(separator: "\n").map(String.init),
            [
                "-s emulator-5554 shell date +%s",
                "-s emulator-5554 logcat -d -v threadtime -t 1790280559.000",
                "-s emulator-5554 shell dumpsys battery",
                "-s emulator-5554 shell dumpsys meminfo",
                "-s emulator-5554 shell getprop",
            ]
        )

        let zip = result.url
        XCTAssertEqual(
            try unzip(zip, "logcat.txt"),
            try LogcatSdkApkFixtures.data("logcat-d-v-threadtime-pid-4628.txt")
        )
        XCTAssertEqual(
            try unzip(zip, "dumpsys-battery.txt"),
            try LogcatSdkApkFixtures.data("shell-dumpsys-battery.txt")
        )
        XCTAssertEqual(
            try unzip(zip, "dumpsys-meminfo.txt"),
            try LogcatSdkApkFixtures.data("shell-dumpsys-meminfo.txt")
        )

        let getprop = try XCTUnwrap(String(data: try unzip(zip, "getprop.txt"), encoding: .utf8))
        // 553 properties; the boot reason history adds three more lines.
        XCTAssertEqual(getprop.split(separator: "\n").count, 556)
        XCTAssertTrue(getprop.contains("""

            persist.sys.boot.reason.history=reboot,1790279800
            reboot,1790279318
            reboot,1790151787
            reboot,1789093744
            persist.sys.dalvik.vm.lib.2=libart.so

            """), "the multi-line value must be kept whole")
        XCTAssertTrue(getprop.contains("\nro.build.version.sdk=37\n"))
        XCTAssertTrue(getprop.contains("\npersist.sys.boot.reason=\n"), "empty values stay empty")

        let device = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try unzip(zip, "device.json")) as? [String: Any]
        )
        XCTAssertEqual(device["serial"] as? String, "emulator-5554")
        XCTAssertEqual(device["model"] as? String, "sdk_gphone16k_arm64")
        XCTAssertEqual(device["manufacturer"] as? String, "Google")
        XCTAssertEqual(device["androidVersion"] as? String, "17")
        XCTAssertEqual(device["apiLevel"] as? String, "37")
        XCTAssertEqual(device["abi"] as? String, "arm64-v8a")
        XCTAssertEqual(device["isEmulator"] as? Bool, true)
    }

    /// The real `getprop` output parsed on its own: 553 properties, the
    /// multi-line boot reason history complete.
    func testGetpropParsingKeepsMultiLineValues() throws {
        let properties = DiagnosticsBundle.properties(
            fromGetprop: try LogcatSdkApkFixtures.text("shell-getprop.txt")
        )
        XCTAssertEqual(properties.count, 553)
        XCTAssertEqual(
            properties["persist.sys.boot.reason.history"],
            "reboot,1790279800\nreboot,1790279318\nreboot,1790151787\nreboot,1789093744"
        )
        XCTAssertEqual(properties["persist.sys.dalvik.vm.lib.2"], "libart.so")
        XCTAssertEqual(properties["persist.sys.boot.reason"], "")
        XCTAssertEqual(properties["ro.serialno"], "EMULATOR37X2X8X0")
        XCTAssertEqual(properties["ro.product.model"], "sdk_gphone16k_arm64")
    }

    /// SOURCE-DERIVED: adbd before Android 7 ran `adb shell` commands on a
    /// pty, which turns every LF into CRLF (the reason `LogcatStream` strips
    /// CR as well). The same output with CRLF endings parses identically.
    func testGetpropParsingAcceptsCRLF() throws {
        let text = try LogcatSdkApkFixtures.text("shell-getprop.txt")
        let crlf = text.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(
            DiagnosticsBundle.properties(fromGetprop: crlf),
            DiagnosticsBundle.properties(fromGetprop: text)
        )
    }

    // MARK: - Helpers

    /// An archive entry's exact bytes, read with the system `unzip`.
    private func unzip(_ zip: URL, _ entry: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", zip.path, entry]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "unzip -p \(entry)")
        return data
    }
}
