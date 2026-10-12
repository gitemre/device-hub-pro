import XCTest
@testable import DeviceHubProKit

/// One test per rule. The logs and the AVD are real captures (`emulator-start/`,
/// `problem-report/`); the report fields a rule reads that no capture can give
/// (a Mac without a hypervisor, an old Command-line Tools folder, free space)
/// are set on the model directly: they are report values, not device output.
final class ProblemReportAnalyzerTests: XCTestCase {
    /// A report of the hermetic Mac with no AVD and no log: nothing wrong.
    private func baseReport() async throws -> ProblemReport {
        let world = try HermeticReportWorld()
        var report = await world.collect(try world.inputs()).report
        report.android.avds = []
        return report
    }

    private func logTail(_ avd: String, fixture: String) throws -> ProblemReport.LogTail {
        let lines = try ProblemReportFixtures.text(fixture).components(separatedBy: "\n").filter { !$0.isEmpty }
        return ProblemReport.LogTail(avd: avd, modified: Date(timeIntervalSince1970: 1_800_000_000), bytes: 1_000, lines: lines, omittedLines: false)
    }

    private func ids(_ report: ProblemReport) -> [String] {
        ProblemReportAnalyzer.findings(for: report).map(\.id)
    }

    private func finding(_ id: String, in report: ProblemReport) -> ProblemFinding? {
        ProblemReportAnalyzer.findings(for: report).first { $0.id == id }
    }

    // MARK: Nothing wrong

    /// `emulator-app-log.log` is a real log of the app's emulator; its scrubs (the
    /// macOS user name became `aqauser001`, the adb public key a run of `A`) and
    /// the cut after "Boot completed" are listed in Fixtures/problem-report/README.md.
    func testAHealthyReportHasNoFinding() async throws {
        var report = try await baseReport()
        XCTAssertEqual(ids(report), [])
        // A healthy start's log (the app's own, from a real boot) says nothing wrong.
        report.emulatorLogs = [try logTail("Pixel_10_Pro_Fold_API_36", fixture: "problem-report/emulator-app-log.log")]
        XCTAssertEqual(ids(report), [], "the INFO line vulkan_mode_selected:host is not a graphics error")
    }

    // MARK: The logs

    func testNoHypervisorFromTheLog() async throws {
        var report = try await baseReport()
        report.emulatorLogs = [try logTail("Pixel_8_Pro", fixture: "emulator-start/hvf-unsupported-vm.log")]
        XCTAssertEqual(ids(report), ["log-no-hypervisor"])
        let finding = try XCTUnwrap(finding("log-no-hypervisor", in: report))
        XCTAssertEqual(finding.explanation, EmulatorStartFailure.Cause.noHypervisor.sentence)
        XCTAssertEqual(finding.confidence, .likely)
        XCTAssertTrue(finding.evidence[0].contains("Pixel_8_Pro"))
        XCTAssertTrue(finding.evidence[0].contains("QEMU main loop exits abnormally"), "the last line worth reading")
        XCTAssertEqual(finding.evidenceKeys, ["emulatorLogs[].lines"])
    }

    func testTheHypervisorRuleSuppressesItsLogRule() async throws {
        var report = try await baseReport()
        report.emulatorLogs = [try logTail("Pixel_8_Pro", fixture: "emulator-start/hvf-unsupported-vm.log")]
        report.mac.hypervisorSupported = false
        report.mac.insideVirtualMachine = true
        XCTAssertEqual(ids(report), ["no-hypervisor"])
        let finding = try XCTUnwrap(finding("no-hypervisor", in: report))
        XCTAssertEqual(finding.confidence, .confirmed)
        XCTAssertEqual(finding.evidence.count, 2)
    }

    func testTheHypervisorGivenUpIsNotAGraphicsProblem() async throws {
        var report = try await baseReport()
        report.emulatorLogs = [try logTail("Pixel_8_Pro", fixture: "emulator-start/hvf-not-enabled-target-zero-vm.log")]
        XCTAssertEqual(ids(report), ["log-hvf-not-enabled"], "vulkan_mode_selected:host in the INFO chatter must not read as log-graphics")
    }

    func testMprotectDeniedFromTheReportedLog() async throws {
        var report = try await baseReport()
        report.emulatorLogs = [try logTail("Pixel_8_Pro", fixture: "emulator-start/mprotect-denied-report.log")]
        XCTAssertEqual(ids(report), ["log-mprotect-denied"])
    }

    /// The causes without a capture are SOURCE-DERIVED like the alert's own
    /// tests (`EmulatorStartFailureTests`): the emulator's error strings.
    func testTheOtherLogCausesAndTheirRunningCondition() async throws {
        let cases: [(String, String, Bool)] = [
            ("emulator: ERROR: Running multiple emulators with the same AVD is an experimental feature.", "log-lock", true),
            ("emulator: ERROR: Not enough space to create userdata partition.", "log-disk-full", true),
            ("emulator: ERROR: vkCreateInstance failed", "log-graphics", true),
            ("PANIC: Broken AVD system path. Check your ANDROID_SDK_ROOT value", "log-system-image", false),
        ]
        for (line, id, onlyWhenStopped) in cases {
            var report = try await baseReport()
            report.emulatorLogs = [ProblemReport.LogTail(avd: "Pixel_8_Pro", modified: Date(timeIntervalSince1970: 0), bytes: 1, lines: [line], omittedLines: false)]
            XCTAssertEqual(ids(report), [id], line)
            // An AVD that runs now has not failed to start.
            report.android.runningEmulators = [ProblemReport.RunningEmulator(avd: "Pixel_8_Pro", processAlive: true)]
            XCTAssertEqual(ids(report).contains(id), !onlyWhenStopped, "\(id) while running")
        }
    }

    // MARK: The AVD an old avdmanager wrote

    func testAnAvdWithTargetZeroIsFoundAndConfirmedByItsLog() async throws {
        let world = try HermeticReportWorld()
        var report = await world.collect(try world.inputs()).report
        XCTAssertEqual(ids(report), ["avd-target-android-0", "system-image-missing"])
        var finding = try XCTUnwrap(finding("avd-target-android-0", in: report))
        XCTAssertEqual(finding.confidence, .likely)
        XCTAssertEqual(finding.evidence, ["Pixel_8_Pro_old: target=android-0, its system image is API 37.0"])

        report.emulatorLogs = [try logTail("Pixel_8_Pro_old", fixture: "emulator-start/hvf-not-enabled-target-zero-vm.log")]
        XCTAssertEqual(ids(report), ["avd-target-android-0", "system-image-missing"], "the log rule is redundant now")
        finding = try XCTUnwrap(self.finding("avd-target-android-0", in: report))
        XCTAssertEqual(finding.confidence, .confirmed)
        XCTAssertTrue(finding.evidence[0].hasSuffix("its log says the emulator ran without the hypervisor"))

        // The mprotect log of the reporting user confirms it the same way.
        report.emulatorLogs = [try logTail("Pixel_8_Pro_old", fixture: "emulator-start/mprotect-denied-report.log")]
        XCTAssertEqual(self.finding("avd-target-android-0", in: report)?.confidence, .confirmed)
        XCTAssertFalse(ids(report).contains("log-mprotect-denied"))

        // A log of another AVD does not confirm it.
        report.emulatorLogs = [try logTail("Another", fixture: "emulator-start/mprotect-denied-report.log")]
        XCTAssertEqual(self.finding("avd-target-android-0", in: report)?.confidence, .likely)
        // (The suppression is by rule, not by AVD: the log rule stays quiet while
        // an AVD with target android-0 explains this kind of log.)
        XCTAssertFalse(ids(report).contains("log-mprotect-denied"))
    }

    func testAnAvdWithNoTargetButAnImageIsTheSame() async throws {
        var report = try await baseReport()
        report.android.avds = [ProblemReport.Avd(name: "A", imageAPI: "37.0")]
        XCTAssertEqual(ids(report), ["avd-target-android-0"])
        report.android.avds = [ProblemReport.Avd(name: "A", configTarget: "android-37.0", imageAPI: "37.0")]
        XCTAssertEqual(ids(report), [], "a target in config.ini is a target")
        report.android.avds = [ProblemReport.Avd(name: "A", target: "android-36", imageAPI: "36")]
        XCTAssertEqual(ids(report), [])
    }

    func testOldCommandLineToolsAreNamedWithTheFolderChosen() async throws {
        var report = try await baseReport()
        report.android.avdmanager = ProblemReport.ToolInfo(path: "/sdk/cmdline-tools/19.0/bin/avdmanager", version: "19.0")
        report.android.sdkRoots = [ProblemReport.SdkRoot(
            path: "/sdk", foundBy: ["default"], exists: true,
            cmdlineTools: [ProblemReport.CmdlineTools(folder: "19.0", version: "19.0"), ProblemReport.CmdlineTools(folder: "9.0", version: "9.0")]
        )]
        XCTAssertEqual(ids(report), ["cmdline-tools-old"])
        let finding = try XCTUnwrap(finding("cmdline-tools-old", in: report))
        XCTAssertEqual(finding.confidence, .likely)
        XCTAssertEqual(finding.evidence[0], "avdmanager: /sdk/cmdline-tools/19.0/bin/avdmanager (cmdline-tools 19.0)")
        XCTAssertTrue(finding.evidence[1].contains("cmdline-tools/latest is missing"))
        XCTAssertTrue(finding.evidence[1].contains("the oldest revision, 19.0, is used"))

        report.android.avdmanager = ProblemReport.ToolInfo(path: "/sdk/cmdline-tools/latest/bin/avdmanager", version: "22.0")
        XCTAssertEqual(ids(report), [])
        report.android.avdmanager = ProblemReport.ToolInfo(path: "/sdk/cmdline-tools/latest/bin/avdmanager", version: "19.0")
        XCTAssertEqual(ids(report), ["cmdline-tools-old"], "latest at 19.0")
        report.android.avdmanager = ProblemReport.ToolInfo(path: "/sdk/cmdline-tools/13.0/bin/avdmanager", version: nil)
        XCTAssertEqual(ids(report), ["cmdline-tools-old"], "the folder says it when the revision cannot be read")
        report.android.avdmanager = ProblemReport.ToolInfo(path: "/sdk/cmdline-tools/latest/bin/avdmanager", version: nil)
        XCTAssertEqual(ids(report), [], "latest says nothing")
    }

    // MARK: Hardware and images

    func testAnIntelImageOnAppleSilicon() async throws {
        var report = try await baseReport()
        report.android.avds = [ProblemReport.Avd(name: "Old", target: "android-34", abi: "x86_64")]
        XCTAssertEqual(ids(report), ["x86-image"])
        report.mac.appleSilicon = false
        XCTAssertEqual(ids(report), [])
    }

    func testAMissingOrIncompleteSystemImage() async throws {
        var report = try await baseReport()
        report.android.avds = [
            ProblemReport.Avd(name: "A", target: "android-35", imageSysdir: "system-images/android-35/google_apis/arm64-v8a/", image: .missing),
            ProblemReport.Avd(name: "B", target: "android-35", image: .incomplete),
            ProblemReport.Avd(name: "C", target: "android-35", image: .ok),
        ]
        let finding = try XCTUnwrap(finding("system-image-missing", in: report))
        XCTAssertEqual(finding.evidence, ["A: system image missing (system-images/android-35/google_apis/arm64-v8a/)", "B: system image incomplete"])
        // Its log rule is redundant.
        report.emulatorLogs = [ProblemReport.LogTail(avd: "A", modified: Date(timeIntervalSince1970: 0), bytes: 1, lines: ["PANIC: Broken AVD system path."], omittedLines: false)]
        XCTAssertEqual(ids(report), ["system-image-missing"])
    }

    func testLowDiskSpace() async throws {
        var report = try await baseReport()
        report.mac.freeSpace = [
            ProblemReport.VolumeSpace(role: "home", freeGB: 9), ProblemReport.VolumeSpace(role: "avdHome", freeGB: 120),
            ProblemReport.VolumeSpace(role: "sdk", freeGB: 2),
        ]
        let finding = try XCTUnwrap(finding("low-disk-space", in: report))
        XCTAssertEqual(finding.evidence, ["home: 9 GB free"], "the SDK volume is not where emulators write")
        report.mac.freeSpace[0].freeGB = 10
        XCTAssertEqual(ids(report), [])
    }

    func testNoAdb() async throws {
        var report = try await baseReport()
        report.android.adb.path = nil
        XCTAssertEqual(ids(report), ["adb-not-found"])
        XCTAssertEqual(finding("adb-not-found", in: report)?.confidence, .confirmed)
    }

    // MARK: The console

    /// The silent console of the real capture (zero bytes, exit 0) with an
    /// empty token file: confirmed, with the evidence a maintainer reads.
    func testAnEmptyTokenFileAndASilentConsoleAreConfirmed() async throws {
        var report = try await baseReport()
        report.android.consoleTokenFile = ProblemReport.TokenFileInfo(path: "~/.emulator_console_auth_token", state: .empty, bytes: 0, mode: "600", ownedByUser: true)
        report.android.runningEmulators[0].console = ProblemReportCollector.classifyConsole(
            exitCode: 0, stdout: try ProblemReportFixtures.data("problem-report/emulator-emu-avd-name-silent.txt"), stderr: ""
        )
        report.android.runningEmulators[0].avd = "Pixel_8_Pro"
        XCTAssertEqual(ids(report), ["console-token-empty"], "console-silent is the same fact")
        let finding = try XCTUnwrap(finding("console-token-empty", in: report))
        XCTAssertEqual(finding.confidence, .confirmed)
        XCTAssertEqual(finding.evidence[0], "~/.emulator_console_auth_token: empty (0 bytes)")
        XCTAssertEqual(
            finding.evidence[1],
            "emulator-5554 (Pixel_8_Pro): `adb emu avd name` printed nothing; Android names its AVD DHP_ConsoleCapture; discovery file present (gRPC token: no)"
        )
        XCTAssertEqual(finding.title, "The emulator console\u{2019}s token file is empty")
        XCTAssertTrue(finding.fix.contains("delete ~/.emulator_console_auth_token"))
        XCTAssertTrue(finding.evidenceKeys.contains("android.consoleTokenFile.state"))
    }

    /// From 1.1.2 the app reads the console itself, so the empty file is no
    /// cause for a release from then on or for a development build; it still
    /// is for an older release, a release whose version cannot be read, and
    /// the CLI (which says nothing about the user's app).
    func testAnEmptyTokenFileIsACauseOnlyBeforeTheAppReadsTheConsoleItself() async throws {
        var report = try await baseReport()
        report.android.consoleTokenFile.state = .empty
        report.android.runningEmulators[0].console = ProblemReport.ConsoleProbe(outcome: .emptyAnswer, exitCode: 0)
        let cases: [(ProblemReport.AppInfo.Kind, String?, Bool)] = [
            (.packaged, "1.1.1", true),
            (.packaged, "1.0.0", true),
            (.packaged, nil, true),
            (.packaged, "unknown", true),
            (.packaged, "1.1.2", false),
            (.packaged, "1.2.0", false),
            (.packaged, "2.0", false),
            (.development, nil, false),
            (.cli, nil, true),
        ]
        for (kind, version, fires) in cases {
            report.app.kind = kind
            report.app.version = version
            XCTAssertEqual(finding("console-token-empty", in: report) != nil, fires, "\(kind) \(version ?? "nil")")
        }
        report.app.kind = .packaged
        report.app.version = "1.1.1"
        XCTAssertTrue(try XCTUnwrap(finding("console-token-empty", in: report)).fix.hasPrefix("Update Device Hub Pro to 1.1.2 or later"))
    }

    /// With no console asked (every probe skipped) the empty file is only a
    /// likely cause.
    func testAnEmptyTokenFileAloneIsLikely() async throws {
        var report = try await baseReport()
        report.android.consoleTokenFile.state = .blank
        report.android.runningEmulators[0].console = ProblemReport.ConsoleProbe(outcome: .skipped, note: "adb not queried")
        let finding = try XCTUnwrap(finding("console-token-empty", in: report))
        XCTAssertEqual(finding.confidence, .likely)
        XCTAssertEqual(finding.evidence.count, 1)

        report.android.runningEmulators = []
        XCTAssertEqual(try XCTUnwrap(self.finding("console-token-empty", in: report)).confidence, .likely, "no emulator runs")
    }

    /// An emulator whose console answered refutes the cause: an empty token
    /// file is also how console authentication is turned off on purpose.
    func testAnEmptyTokenFileWithAnAnsweringConsoleIsNoProblem() async throws {
        var report = try await baseReport()
        XCTAssertEqual(report.android.runningEmulators[0].console.outcome, .answered)
        for state in [ProblemReport.TokenState.empty, .blank] {
            report.android.consoleTokenFile.state = state
            XCTAssertNil(finding("console-token-empty", in: report), "\(state)")
        }
        // One silent emulator among answering ones still counts as no proof.
        var silent = report.android.runningEmulators[0]
        silent.console = ProblemReport.ConsoleProbe(outcome: .emptyAnswer, exitCode: 0)
        report.android.runningEmulators.append(silent)
        XCTAssertNil(finding("console-token-empty", in: report))
    }

    func testASilentConsoleWithATokenIsLikelyStuck() async throws {
        var report = try await baseReport()
        for outcome in [ProblemReport.ConsoleOutcome.emptyAnswer, .ko, .failed, .timedOut] {
            report.android.runningEmulators[0].console = ProblemReport.ConsoleProbe(outcome: outcome, exitCode: 0)
            XCTAssertEqual(ids(report), ["console-silent"], "\(outcome)")
        }
        let finding = try XCTUnwrap(finding("console-silent", in: report))
        XCTAssertEqual(finding.evidence, ["emulator-5554 (Pixel_9_Pro_Fold): adb lists it as device; `adb emu avd name` didn\u{2019}t answer in time"])
        report.android.runningEmulators[0].adbState = "offline"
        XCTAssertEqual(ids(report), [], "an offline emulator is the boot's business")
        report.android.runningEmulators[0].adbState = "device"
        report.android.runningEmulators[0].console = ProblemReport.ConsoleProbe(outcome: .skipped)
        XCTAssertEqual(ids(report), [])
    }

    // MARK: The adb server

    func testAnotherAdbRunsTheServer() async throws {
        var report = try await baseReport()
        report.android.adb.server.sameAsApp = false
        report.android.adb.server.path = "/opt/homebrew/bin/adb"
        report.android.adb.server.version = "35.0.1"
        let finding = try XCTUnwrap(finding("adb-server-other-copy", in: report))
        XCTAssertEqual(finding.evidence, [
            "adb server: /opt/homebrew/bin/adb (35.0.1)",
            "Device Hub Pro\u{2019}s adb: \(report.android.adb.path ?? "") (37.0.0)",
        ])
        report.android.adb.server.version = "37.0.0"
        XCTAssertEqual(ids(report), [], "the same version does not restart the other's server")
        report.android.adb.server.version = nil
        XCTAssertEqual(ids(report), ["adb-server-other-copy"], "an unknown version counts as different")
        report.android.adb.server.sameAsApp = true
        XCTAssertEqual(ids(report), [])
    }

    func testARunningEmulatorThatAdbDoesNotList() async throws {
        var report = try await baseReport()
        report.android.runningEmulators[0].adbState = nil
        let finding = try XCTUnwrap(finding("emulator-not-in-adb", in: report))
        XCTAssertEqual(finding.evidence[0], "emulator-5554 (Pixel_9_Pro_Fold): the process runs, adb doesn\u{2019}t list it")
        XCTAssertTrue(finding.evidence[1].hasPrefix("Device Hub Pro\u{2019}s adb: "))
        XCTAssertTrue(finding.fix.contains("adb kill-server"))

        report.android.devicesSource = "not read: adb devices -l failed."
        XCTAssertEqual(ids(report), [], "an unread list says nothing about the emulator")
        report.android.devicesSource = "app inventory"
        report.android.adb.server.queried = false
        XCTAssertEqual(ids(report), [])
        report.android.adb.server.queried = true
        report.android.runningEmulators[0].processAlive = false
        XCTAssertEqual(ids(report), [])
    }

    // MARK: Order and text

    func testFindingsComeInPriorityOrderWithConfirmedFirst() async throws {
        var report = try await baseReport()
        report.mac.hypervisorSupported = false
        report.android.adb.path = nil
        report.android.consoleTokenFile.state = .empty
        report.android.runningEmulators[0].console = ProblemReport.ConsoleProbe(outcome: .skipped, note: "adb not queried")
        report.mac.freeSpace = [ProblemReport.VolumeSpace(role: "home", freeGB: 1)]
        XCTAssertEqual(ids(report), ["no-hypervisor", "adb-not-found", "console-token-empty", "low-disk-space"])
        XCTAssertEqual(ProblemReportAnalyzer.rules.map(\.priority), ProblemReportAnalyzer.rules.map(\.priority).sorted(), "the table is kept in order")
        XCTAssertEqual(Set(ProblemReportAnalyzer.rules.map(\.id)).count, ProblemReportAnalyzer.rules.count, "ids are unique")
    }

    func testEveryCauseHasALogRule() {
        for cause in EmulatorStartFailure.Cause.allCases {
            let rule = ProblemReportAnalyzer.rules.first { $0.explanation == cause.sentence && $0.id.hasPrefix("log-") }
            XCTAssertNotNil(rule, "\(cause)")
        }
        XCTAssertEqual(ProblemReportAnalyzer.rules.filter { $0.id.hasPrefix("log-") }.count, EmulatorStartFailure.Cause.allCases.count)
    }
}
