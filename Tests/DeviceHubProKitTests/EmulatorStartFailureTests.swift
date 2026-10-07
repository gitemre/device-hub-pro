import XCTest
@testable import DeviceHubProKit

/// The alert text for an emulator that exits while it starts.
///
/// `Fixtures/emulator-start/hvf-unsupported-vm.log` is the log tail of the
/// "The emulator exited during startup." alert, copied from the report of a
/// fresh macOS 26.6 virtual machine (no hardware virtualization): the three
/// lines it quoted, with the middle of the first line (the kernel command
/// line, thousands of characters) elided as `[...]`. The other causes are
/// SOURCE-DERIVED from the emulator's own error strings (emulator 37.x:
/// `Running multiple emulators with the same AVD`, `Not enough space to
/// create userdata partition`, `Broken AVD system path`, the Vulkan / EGL
/// initialisation errors); no capture of those exists.
final class EmulatorStartFailureTests: XCTestCase {
    private func fixture() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/emulator-start/hvf-unsupported-vm.log")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testNoHypervisorInsideAVirtualMachine() throws {
        let failure = EmulatorStartFailure.exited("during startup", logTail: try fixture())
        XCTAssertEqual(
            failure.message,
            "This Mac can\u{2019}t run Android emulators here: hardware virtualization isn\u{2019}t available (for example inside a virtual machine)."
        )
        let details = try XCTUnwrap(failure.details)
        XCTAssertTrue(details.contains("HVF error: HV_UNSUPPORTED"))
        XCTAssertTrue(details.contains("failed to initialize HVF: Invalid argument"))
        XCTAssertTrue(details.contains("QEMU main loop exits abnormally with code 1"))
    }

    /// The alert used to show every INFO line the emulator printed before
    /// the error; only the last ten lines worth reading remain, and a
    /// thousands-of-characters kernel command line keeps its end.
    func testDetailsDropInfoNoiseAndKeepTenLines() throws {
        var lines = (1...30).map { "INFO    | boot step \($0) done" }
        lines.append("INFO    | " + String(repeating: "androidboot.x=1 ", count: 300) + "HVF error: HV_UNSUPPORTED")
        lines.append("qemu-system-aarch64: failed to initialize HVF: Invalid argument")
        let details = try XCTUnwrap(EmulatorStartFailure.detail(from: lines.joined(separator: "\n")))
        let shown = details.split(separator: "\n")
        XCTAssertEqual(shown.count, 2, "INFO lines without an error word are dropped")
        XCTAssertTrue(shown[0].hasSuffix("HVF error: HV_UNSUPPORTED"))
        XCTAssertLessThan(shown[0].count, 300)
        XCTAssertTrue(shown[0].hasPrefix("\u{2026}"))

        let many = (1...25).map { "ERROR   | problem \($0)" }.joined(separator: "\n")
        XCTAssertEqual(EmulatorStartFailure.detail(from: many)?.split(separator: "\n").count, 10)
        XCTAssertNil(EmulatorStartFailure.detail(from: "(no emulator log at /tmp/x.log)"))
    }

    func testOtherKnownCauses() {
        let cases: [(String, String)] = [
            ("emulator: ERROR: Running multiple emulators with the same AVD is an experimental feature.",
             "already running"),
            ("emulator: ERROR: Not enough space to create userdata partition. Available: 812 MB at /Users/x/.android/avd/a.avd, need 6144 MB.",
             "free disk space"),
            ("PANIC: Broken AVD system path. Check your ANDROID_SDK_ROOT value", "system image"),
            ("emulator: ERROR: vkCreateInstance failed", "graphics"),
        ]
        for (log, expected) in cases {
            let failure = EmulatorStartFailure.exited("during startup", logTail: log)
            XCTAssertTrue(failure.message.contains(expected), "\(log) -> \(failure.message)")
        }
    }

    func testUnknownCauseKeepsThePlainSentence() {
        let failure = EmulatorStartFailure.exited("while booting", logTail: "something odd happened")
        XCTAssertEqual(failure.message, "The emulator exited while booting.")
        XCTAssertEqual(failure.details, "something odd happened")
    }
}
