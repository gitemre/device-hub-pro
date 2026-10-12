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
///
/// `hvf-not-enabled-target-zero-vm.log` is the head of emulator 37.2.12's
/// output (2026-10-11, the same virtual machine) starting an Android 17 AVD
/// whose target an old avdmanager wrote as `android-0`: up to the line where
/// it gives up the hypervisor. `mprotect-denied-report.log` is from a
/// user's report of 1.0.0 on an Apple silicon Mac, such an AVD crashing
/// there (its last two lines, a process number and a path with the user's
/// name, left out).
final class EmulatorStartFailureTests: XCTestCase {
    private func fixture(_ name: String = "hvf-unsupported-vm.log") throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/emulator-start/\(name)")
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

    /// An emulator that gives up the hypervisor runs Android in software,
    /// which macOS refused on the reporting Mac: both logs say so plainly.
    func testSoftwareEmulationIsNamed() throws {
        for name in ["hvf-not-enabled-target-zero-vm.log", "mprotect-denied-report.log"] {
            let failure = EmulatorStartFailure.exited("during startup", logTail: try fixture(name))
            XCTAssertTrue(failure.message.contains("hypervisor"), "\(name) -> \(failure.message)")
            XCTAssertTrue(failure.message.contains("Command-line Tools"), name)
        }
        let report = EmulatorStartFailure.exited("during startup", logTail: try fixture("mprotect-denied-report.log"))
        XCTAssertTrue(try XCTUnwrap(report.details).contains("mprotect failed: Permission denied"))
    }

    func testUnknownCauseKeepsThePlainSentence() {
        let failure = EmulatorStartFailure.exited("while booting", logTail: "something odd happened")
        XCTAssertEqual(failure.message, "The emulator exited while booting.")
        XCTAssertEqual(failure.details, "something odd happened")
    }

    // MARK: The causes, as the problem report's analyzer reads them

    func testEveryFixtureNamesItsCause() throws {
        XCTAssertEqual(EmulatorStartFailure.cause(in: try fixture("hvf-unsupported-vm.log")), .noHypervisor)
        XCTAssertEqual(EmulatorStartFailure.cause(in: try fixture("hvf-not-enabled-target-zero-vm.log")), .hvfNotEnabled)
        XCTAssertEqual(EmulatorStartFailure.cause(in: try fixture("mprotect-denied-report.log")), .mprotectDenied)
        XCTAssertNil(EmulatorStartFailure.cause(in: "something odd happened"))
    }

    /// A log that names both says the software mode was refused: that is the
    /// more specific one.
    func testTheRefusedSoftwareModeWinsOverTheHypervisorGivenUp() {
        let both = "WARNING | hvf is not enabled on this aarch64 host.\nqemu-system-aarch64: qemu_mprotect__osdep: mprotect failed: Permission denied"
        XCTAssertEqual(EmulatorStartFailure.cause(in: both), .mprotectDenied)
        XCTAssertEqual(EmulatorStartFailure.Cause.mprotectDenied.sentence, EmulatorStartFailure.Cause.hvfNotEnabled.sentence)
    }

    func testTheOtherCausesAreMatchedOnTheEmulatorsWording() {
        let cases: [(String, EmulatorStartFailure.Cause)] = [
            ("emulator: ERROR: Running multiple emulators with the same AVD is an experimental feature.", .lockOrRunning),
            ("emulator: ERROR: Not enough space to create userdata partition.", .diskFull),
            ("PANIC: Broken AVD system path. Check your ANDROID_SDK_ROOT value", .systemImageMissing),
            ("emulator: ERROR: vkCreateInstance failed", .graphics),
        ]
        for (log, cause) in cases {
            XCTAssertEqual(EmulatorStartFailure.cause(in: log), cause, log)
            XCTAssertEqual(EmulatorStartFailure.knownCause(in: log), cause.sentence, log)
        }
    }

    /// `knownCause` and the alert's message are what they were before the
    /// causes got a type of their own.
    func testTheKnownCauseSentencesAreUnchanged() throws {
        XCTAssertEqual(
            EmulatorStartFailure.knownCause(in: try fixture("hvf-unsupported-vm.log")),
            "This Mac can\u{2019}t run Android emulators here: hardware virtualization isn\u{2019}t available (for example inside a virtual machine)."
        )
        XCTAssertEqual(
            EmulatorStartFailure.knownCause(in: "ENOSPC"),
            "There isn\u{2019}t enough free disk space to start this emulator. Free some space and try again."
        )
        XCTAssertEqual(
            EmulatorStartFailure.knownCause(in: "multiinstance.lock"),
            "This emulator is already running, or its lock file is left over from one that was not shut down cleanly. Stop it, or delete the .lock files in its AVD folder, and try again."
        )
        XCTAssertEqual(EmulatorStartFailure.knownCause(in: "cannot find avd system path"), EmulatorStartFailure.missingSystemImage)
        XCTAssertEqual(
            EmulatorStartFailure.knownCause(in: "hvf is not enabled"),
            "The emulator couldn\u{2019}t use this Mac\u{2019}s hypervisor and tried to run Android in software, which macOS refused. Recreate the emulator; if it keeps failing, update the Android SDK Command-line Tools and the emulator."
        )
        XCTAssertEqual(
            EmulatorStartFailure.knownCause(in: "eglInitialize failed"),
            "The emulator could not start its graphics. Try again; if it keeps failing, update the emulator package and macOS."
        )
        XCTAssertNil(EmulatorStartFailure.knownCause(in: "something odd happened"))
    }

    func testSignificantLinesDropTheInfoChatterButNotTheCount() throws {
        let log = try fixture("hvf-not-enabled-target-zero-vm.log")
        let lines = EmulatorStartFailure.significantLines(from: log)
        XCTAssertEqual(lines, ["WARNING      | hvf is not enabled on this aarch64 host."], "the INFO lines carry no error word")
        let many = (1...25).map { "ERROR   | problem \($0)" }.joined(separator: "\n")
        XCTAssertEqual(EmulatorStartFailure.significantLines(from: many).count, 25, "not cut to the ten of the alert")
        XCTAssertEqual(EmulatorStartFailure.detail(from: many)?.split(separator: "\n").count, 10)
        // The chatter's `vulkan_mode_selected` reads as a graphics error unless the INFO lines are filtered first.
        let chatter = "INFO         | emuglConfig_init: vulkan_mode_selected:host gles_mode_selected:host"
        XCTAssertEqual(EmulatorStartFailure.cause(in: chatter), .graphics)
        XCTAssertNil(EmulatorStartFailure.cause(in: EmulatorStartFailure.significantLines(from: chatter).joined(separator: "\n")))
        XCTAssertEqual(EmulatorStartFailure.cause(in: log), .hvfNotEnabled)
    }
}
