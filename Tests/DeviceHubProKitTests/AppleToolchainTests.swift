import XCTest
@testable import DeviceHubProKit

/// `AppleToolchain`: the real-binary resolution, the wrappers' first-launch
/// rule, and the tier.
///
/// The layout tests build a stand-in system in a temporary folder: framework
/// `Info.plist`s with a `CFBundleVersion`, tool binaries, and wrapper
/// scripts. The wrappers hold only the two lines the probe reads from Xcode
/// 27.0's `usr/bin/simctl` / `usr/bin/devicectl` (`EXPECTED_VERSION="…"` and
/// the `exec "<real binary>" "${@}"` line, spelled as there); Apple's scripts
/// themselves are not copied into the repository. `testThisMacResolvesTheRealBinaries`
/// reads the installed Xcode instead, read-only.
final class AppleToolchainTests: XCTestCase {
    // MARK: Stand-in layout

    private struct StandIn {
        let root: URL
        let developer: URL
        var layout: AppleToolchain.Layout

        var simctlBinary: URL { layout.simctlBinary }
        var devicectlBinary: URL { layout.devicectlBinary }
    }

    private func makeStandIn(
        coreSimulatorVersion: String? = "1171.7",
        coreDeviceVersion: String? = "642.16",
        simctlExpected: String = "1171.7",
        devicectlExpected: String = "642.16",
        neverLaunched: Bool = false
    ) throws -> StandIn {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleToolchainTests-\(UUID().uuidString)", isDirectory: true)
        // Best effort: a leftover temporary folder must not fail the test.
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let layout = AppleToolchain.Layout(
            coreSimulatorFramework: root.appendingPathComponent("PrivateFrameworks/CoreSimulator.framework"),
            coreDeviceFramework: root.appendingPathComponent("PrivateFrameworks/CoreDevice.framework"),
            xcodeSelect: root.appendingPathComponent("usr/bin/xcode-select")
        )
        let developer = root.appendingPathComponent("Xcode.app/Contents/Developer", isDirectory: true)

        // A never-launched Xcode: the system components are not installed.
        if !neverLaunched {
            try writeExecutable(layout.simctlBinary, "#!/bin/sh\nexit 0\n")
            try writeExecutable(layout.devicectlBinary, "#!/bin/sh\nexit 0\n")
        }
        if let coreSimulatorVersion, !neverLaunched {
            try writePlist(["CFBundleVersion": coreSimulatorVersion], to: layout.coreSimulatorInfoPlist)
        }
        if let coreDeviceVersion, !neverLaunched {
            try writePlist(["CFBundleVersion": coreDeviceVersion], to: layout.coreDeviceInfoPlist)
        }
        try writeExecutable(
            developer.appendingPathComponent("usr/bin/simctl"),
            "#!/bin/bash\nEXPECTED_VERSION=\"\(simctlExpected)\"\nexec \"\(layout.simctlBinary.path)\" \"${@}\"\n"
        )
        try writeExecutable(
            developer.appendingPathComponent("usr/bin/devicectl"),
            "#!/bin/zsh\nEXPECTED_VERSION=\"\(devicectlExpected)\"\nexec \"\(layout.devicectlBinary.path)\" \"${@}\"\n"
        )
        try writeExecutable(
            developer.appendingPathComponent("usr/bin/xcodebuild"),
            "#!/bin/sh\ntouch \"\(root.path)/xcodebuild-ran\"\nexit 99\n"
        )
        try writePlist(
            ["CFBundleShortVersionString": "27.0", "ProductBuildVersion": "27A266a"],
            to: developer.deletingLastPathComponent().appendingPathComponent("version.plist")
        )
        try writeExecutable(layout.xcodeSelect, "#!/bin/sh\nprintf '%s\\n' '\(developer.path)'\n")
        return StandIn(root: root, developer: developer, layout: layout)
    }

    /// The marker the stand-in xcodebuild leaves when something runs it.
    private func xcodebuildRan(_ standIn: StandIn) -> Bool {
        FileManager.default.fileExists(atPath: standIn.root.appendingPathComponent("xcodebuild-ran").path)
    }

    private func writeExecutable(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writePlist(_ dictionary: [String: String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try data.write(to: url)
    }

    // MARK: Probe

    func testCurrentComponentsResolveTheRealBinariesWithoutFirstLaunch() async throws {
        let standIn = try makeStandIn()
        let toolchain = await AppleToolchain.probe(environment: [:], layout: standIn.layout)

        XCTAssertEqual(toolchain.developerDirectory?.standardizedFileURL, standIn.developer.standardizedFileURL)
        XCTAssertEqual(toolchain.xcodeVersion, "27.0")
        XCTAssertEqual(toolchain.xcodeBuild, "27A266a")
        XCTAssertEqual(toolchain.firstLaunchComplete, true)
        XCTAssertEqual(toolchain.simctl.binary?.path, standIn.simctlBinary.path)
        XCTAssertEqual(toolchain.simctl.installedVersion, "1171.7")
        XCTAssertEqual(toolchain.simctl.expectedVersion, "1171.7")
        XCTAssertFalse(toolchain.simctl.needsFirstLaunch)
        XCTAssertEqual(toolchain.devicectl.binary?.path, standIn.devicectlBinary.path)
        XCTAssertFalse(toolchain.devicectl.needsFirstLaunch)
        XCTAssertTrue(toolchain.simctlUsable)
        XCTAssertNil(toolchain.setupAdvice)
        XCTAssertEqual(toolchain.tier(), .t1)

        let client = try XCTUnwrap(toolchain.makeSimctlClient())
        XCTAssertEqual(client.simctlURL.path, standIn.simctlBinary.path)
        XCTAssertEqual(client.environment["DEVELOPER_DIR"], toolchain.developerDirectory?.path)
    }

    /// `DEVELOPER_DIR` wins over `xcode-select`, as it does for `xcrun`.
    func testDeveloperDirEnvironmentWins() async throws {
        let standIn = try makeStandIn()
        try FileManager.default.removeItem(at: standIn.layout.xcodeSelect)
        let toolchain = await AppleToolchain.probe(
            environment: ["DEVELOPER_DIR": standIn.developer.path],
            layout: standIn.layout
        )
        XCTAssertEqual(toolchain.developerDirectory?.path, standIn.developer.path)
        XCTAssertTrue(toolchain.simctlUsable)
    }

    /// An older CoreSimulator is what makes the simctl wrapper run
    /// `xcodebuild -runFirstLaunch`; the probe reports it instead, and the
    /// stand-in xcodebuild would fail (exit 99) on anything but the status check.
    func testOlderCoreSimulatorNeedsFirstLaunchAndIsNotUsed() async throws {
        let standIn = try makeStandIn(coreSimulatorVersion: "1171.6")
        let toolchain = await AppleToolchain.probe(environment: [:], layout: standIn.layout)
        XCTAssertTrue(toolchain.simctl.needsFirstLaunch)
        XCTAssertFalse(toolchain.simctlUsable)
        XCTAssertEqual(toolchain.setupAdvice, "Open Xcode, accept the license and let it install its components (a few minutes), then come back.")
        XCTAssertEqual(toolchain.tier(), .t0)
        XCTAssertNil(toolchain.makeSimctlClient())
    }

    /// A newer CoreSimulator than the wrapper expects is fine for simctl (the
    /// wrapper only checks "older"); devicectl's wrapper insists on equality.
    func testWrapperVersionRules() async throws {
        let newer = try makeStandIn(coreSimulatorVersion: "1172.1", coreDeviceVersion: "642.17")
        let toolchain = await AppleToolchain.probe(environment: [:], layout: newer.layout)
        XCTAssertFalse(toolchain.simctl.needsFirstLaunch)
        XCTAssertTrue(toolchain.devicectl.needsFirstLaunch)
        XCTAssertTrue(toolchain.simctlUsable)
        XCTAssertFalse(toolchain.devicectlUsable)

        let missing = try makeStandIn(coreSimulatorVersion: nil)
        let unversioned = await AppleToolchain.probe(environment: [:], layout: missing.layout)
        XCTAssertTrue(unversioned.simctl.needsFirstLaunch, "a missing version runs first launch in the wrapper too")
    }

    /// A Mac whose Xcode was never launched (no CoreSimulator or CoreDevice
    /// framework installed) is read as "first launch not done" from files:
    /// nothing inside Xcode.app runs, and the guidance is "Open Xcode...".
    func testNeverLaunchedXcodeIsReadFromFilesAndRunsNothing() async throws {
        let standIn = try makeStandIn(neverLaunched: true)
        let toolchain = await AppleToolchain.probe(environment: [:], layout: standIn.layout)
        XCTAssertFalse(xcodebuildRan(standIn), "the probe must not run any tool inside Xcode.app")
        XCTAssertEqual(toolchain.firstLaunchComplete, false)
        XCTAssertNil(toolchain.simctl.binary)
        XCTAssertFalse(toolchain.simctlUsable)
        XCTAssertFalse(toolchain.devicectlUsable)
        XCTAssertNil(toolchain.makeSimctlClient())
        XCTAssertNil(toolchain.makePhysicalDeviceLister())
        XCTAssertEqual(toolchain.tier(), .t0)
        XCTAssertEqual(toolchain.setupAdvice, "Open Xcode, accept the license and let it install its components (a few minutes), then come back.")
        XCTAssertEqual(toolchain.guidance?.actionTitle, "Open Xcode\u{2026}")
    }

    /// Once the components are installed the same Xcode reads as complete,
    /// again without running anything.
    func testSetUpXcodeIsCompleteAndRunsNothing() async throws {
        let standIn = try makeStandIn()
        let toolchain = await AppleToolchain.probe(environment: [:], layout: standIn.layout)
        XCTAssertFalse(xcodebuildRan(standIn))
        XCTAssertEqual(toolchain.firstLaunchComplete, true)
        XCTAssertTrue(toolchain.simctlUsable)
    }

    /// The selection symlink answers without spawning `xcode-select`.
    func testSelectionSymlinkIsReadWithoutRunningXcodeSelect() async throws {
        let standIn = try makeStandIn()
        try FileManager.default.removeItem(at: standIn.layout.xcodeSelect)
        var layout = standIn.layout
        let link = standIn.root.appendingPathComponent("xcode_select_link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: standIn.developer.path)
        layout.xcodeSelectLink = link
        let toolchain = await AppleToolchain.probe(environment: [:], layout: layout)
        XCTAssertEqual(toolchain.developerDirectory?.standardizedFileURL, standIn.developer.standardizedFileURL)
    }

    func testNoXcodeIsTierZero() async throws {
        let standIn = try makeStandIn()
        try writeExecutable(standIn.layout.xcodeSelect, "#!/bin/sh\nexit 2\n")
        let toolchain = await AppleToolchain.probe(environment: [:], layout: standIn.layout)
        XCTAssertNil(toolchain.developerDirectory)
        XCTAssertEqual(toolchain.tier(), .t0)
        XCTAssertEqual(toolchain.setupAdvice, "iOS simulators and iPhones need Xcode.")
        XCTAssertEqual(toolchain.guidance, .notInstalled)
        XCTAssertEqual(toolchain.guidance?.actionTitle, "Get Xcode\u{2026}")
        XCTAssertEqual(toolchain.guidance?.actionURL?.absoluteString, "macappstore://apps.apple.com/app/id497799835")
    }

    /// `xcode-select` pointing at the Command Line Tools (no Xcode selected)
    /// leaves iOS unusable even when an earlier Xcode left CoreSimulator
    /// behind; an Xcode in the application folder is offered ("Open Xcode…"),
    /// none means "Get Xcode…". Stand-in folders only: no real Xcode is touched.
    func testCommandLineToolsSelectedIsNotUsableAndPointsAtAnInstalledXcode() async throws {
        var standIn = try makeStandIn()
        let tools = standIn.root.appendingPathComponent("Library/Developer/CommandLineTools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try writeExecutable(standIn.layout.xcodeSelect, "#!/bin/sh\nprintf '%s\\n' '\(tools.path)'\n")

        let none = await AppleToolchain.probe(environment: [:], layout: standIn.layout)
        XCTAssertTrue(none.commandLineToolsSelected)
        XCTAssertFalse(none.simctlUsable)
        XCTAssertFalse(none.devicectlUsable)
        XCTAssertEqual(none.tier(), .t0)
        XCTAssertEqual(none.guidance, .notInstalled)

        // An Xcode in an application folder that is not the selected one.
        let apps = standIn.root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(
            at: apps.appendingPathComponent("Xcode.app/Contents/Developer"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: apps.appendingPathComponent("Other.app/Contents/Developer"), withIntermediateDirectories: true
        )
        standIn.layout.applicationFolders = [apps]
        let installed = await AppleToolchain.probe(environment: [:], layout: standIn.layout)
        XCTAssertEqual(installed.installedXcodes.map(\.lastPathComponent), ["Xcode.app"])
        guard case let .notSelected(name, app)? = installed.guidance else {
            return XCTFail("expected notSelected, got \(String(describing: installed.guidance))")
        }
        XCTAssertEqual(name, "Xcode")
        XCTAssertEqual(app.lastPathComponent, "Xcode.app")
        XCTAssertEqual(installed.guidance?.actionTitle, "Open Xcode\u{2026}")
        XCTAssertEqual(installed.guidance?.actionURL?.lastPathComponent, "Xcode.app")
        XCTAssertTrue(installed.setupAdvice?.contains("not the selected one") ?? false)
    }

    /// A selected Xcode with components left to install: "Open Xcode…" on it.
    func testASelectedXcodeThatNeedsFirstLaunchPointsAtItself() async throws {
        let standIn = try makeStandIn(coreSimulatorVersion: "1171.6")
        let toolchain = await AppleToolchain.probe(environment: [:], layout: standIn.layout)
        XCTAssertEqual(toolchain.setupAdvice, "Open Xcode, accept the license and let it install its components (a few minutes), then come back.")
        XCTAssertEqual(toolchain.guidance?.actionTitle, "Open Xcode\u{2026}")
        XCTAssertEqual(toolchain.guidance?.actionURL?.standardizedFileURL.lastPathComponent, "Xcode.app")
    }

    /// A usable toolchain has nothing to say.
    func testAUsableToolchainHasNoGuidance() async throws {
        let standIn = try makeStandIn()
        let toolchain = await AppleToolchain.probe(environment: [:], layout: standIn.layout)
        XCTAssertNil(toolchain.guidance)
    }

    /// A wrapper whose `exec` line is missing still never resolves to the
    /// wrapper itself: the framework path is the fallback.
    func testTheWrapperIsNeverTheResolvedBinary() async throws {
        let standIn = try makeStandIn()
        let wrapper = standIn.developer.appendingPathComponent("usr/bin/simctl")
        try writeExecutable(wrapper, "#!/bin/bash\nEXPECTED_VERSION=\"1171.7\"\nexec \"\(wrapper.path)\" \"${@}\"\n")
        let toolchain = await AppleToolchain.probe(environment: [:], layout: standIn.layout)
        XCTAssertEqual(toolchain.simctl.binary?.path, standIn.simctlBinary.path)
        XCTAssertNotEqual(toolchain.simctl.binary?.path, wrapper.path)
    }

    /// `DHP_SIMCTL` / `DHP_DEVICECTL` replace the binaries (for
    /// fakes) without version checks.
    func testOverrides() async throws {
        let standIn = try makeStandIn(coreSimulatorVersion: "1.0")
        let fake = try FakeTool(name: "simctl", rules: [])
        let toolchain = await AppleToolchain.probe(
            environment: ["DHP_SIMCTL": fake.executableURL.path, "DHP_DEVICECTL": "/nonexistent/devicectl"],
            layout: standIn.layout
        )
        XCTAssertTrue(toolchain.simctl.isOverride)
        XCTAssertEqual(toolchain.simctl.binary?.path, fake.executableURL.path)
        XCTAssertTrue(toolchain.simctlUsable)
        XCTAssertNil(toolchain.devicectl.binary, "a missing override binary is not usable")
        XCTAssertFalse(toolchain.devicectlUsable)
    }

    // MARK: Pure parts

    func testWrapperParsing() {
        let script = "#!/bin/bash\nexport DEVELOPER_DIR=x\nEXPECTED_VERSION=\"1171.7\"\nexec \"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl\" \"${@}\"\n"
        XCTAssertEqual(AppleToolchain.expectedVersion(inWrapper: script), "1171.7")
        XCTAssertEqual(
            AppleToolchain.execTarget(inWrapper: script)?.path,
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl"
        )
        XCTAssertNil(AppleToolchain.execTarget(inWrapper: "exec \"${DEVELOPER_DIR}/usr/bin/x\" \"$@\"\n"))
        XCTAssertNil(AppleToolchain.expectedVersion(inWrapper: "#!/bin/sh\n"))
    }

    /// The simctl wrapper canonicalises trailing `.0` components and compares
    /// numerically (`sort --version-sort`).
    func testVersionComparison() {
        XCTAssertEqual(AppleToolchain.compareVersions("1107.0", "1107"), .orderedSame)
        XCTAssertEqual(AppleToolchain.compareVersions("1171.7", "1171.10"), .orderedAscending)
        XCTAssertEqual(AppleToolchain.compareVersions("1172", "1171.7"), .orderedDescending)
        XCTAssertEqual(AppleToolchain.compareVersions("1155.4", "1171.7"), .orderedAscending)
    }

    func testTierTable() {
        XCTAssertEqual(AppleToolchain.tier(simctlUsable: false, devicectlReady: true, canvasReady: true), .t0)
        XCTAssertEqual(AppleToolchain.tier(simctlUsable: true, devicectlReady: false, canvasReady: false), .t1)
        XCTAssertEqual(AppleToolchain.tier(simctlUsable: true, devicectlReady: true, canvasReady: false), .t2)
        XCTAssertEqual(AppleToolchain.tier(simctlUsable: true, devicectlReady: false, canvasReady: true), .t3)
        XCTAssertTrue(AppleToolchain.Tier.t1 < .t2)
    }

    /// T2 needs a devicectl answer for a simulator with a JSON version the
    /// decoders know (the real `info details` capture's `info` block).
    func testDevicectlProbeRaisesTheTier() async throws {
        let standIn = try makeStandIn()
        let toolchain = await AppleToolchain.probe(environment: [:], layout: standIn.layout)
        let info = try DevicectlJSON.info(from: try Data(contentsOf: SimctlFixtureTests.url(
            "devicectl",
            "devicectl-device-info-details.json"
        )))
        XCTAssertEqual(toolchain.tier(devicectlProbe: info), .t2)
        let notFound = try DevicectlJSON.info(from: try Data(contentsOf: SimctlFixtureTests.url(
            "devicectl",
            "devicectl-device-info-details.private-set.json"
        )))
        XCTAssertEqual(toolchain.tier(devicectlProbe: notFound), .t1, "a failed probe does not count")
    }

    // MARK: This Mac (read-only)

    /// On a Mac with Xcode, the probe must resolve the framework binaries,
    /// never the `usr/bin` wrappers, and read the wrappers' expectations.
    /// Reads files and runs `xcode-select -p` (unless `DEVELOPER_DIR` names
    /// the Xcode); nothing is installed or changed. `DHP_SIMCTL` and
    /// `DHP_DEVICECTL` are left out, since they replace exactly the
    /// resolution checked here and no
    /// Xcode tool is ever run.
    func testThisMacResolvesTheRealBinaries() async throws {
        var environment = ProcessInfo.processInfo.environment
        environment["DHP_SIMCTL"] = nil
        environment["DHP_DEVICECTL"] = nil
        let toolchain = await AppleToolchain.probe(environment: environment)
        guard let developer = toolchain.developerDirectory,
              FileManager.default.fileExists(atPath: developer.appendingPathComponent("usr/bin/simctl").path)
        else {
            throw XCTSkip("no Xcode with simctl on this Mac")
        }
        let binary = try XCTUnwrap(toolchain.simctl.binary)
        XCTAssertFalse(binary.path.hasPrefix(developer.path), "resolved the wrapper: \(binary.path)")
        XCTAssertTrue(binary.path.hasSuffix("/Resources/bin/simctl"), binary.path)
        XCTAssertNotNil(toolchain.simctl.expectedVersion)
        XCTAssertNotNil(toolchain.simctl.installedVersion)
        if let devicectl = toolchain.devicectl.binary {
            XCTAssertFalse(devicectl.path.hasPrefix(developer.path), "resolved the wrapper: \(devicectl.path)")
        }
    }
}
