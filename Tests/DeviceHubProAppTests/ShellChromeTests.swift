import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// The window shell's toolbar and banner state: the inspector capsule's
/// routing and active circles, what assistive tech hears about toolbar
/// buttons, the status banner's progress glyph, and where the leading
/// titlebar cluster sits.
@MainActor
final class ShellChromeTests: XCTestCase {
    private func model(tab: WindowState.InspectorTab, showing: Bool) -> AppModel {
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        model.workspace.window.inspectorTab = tab
        model.workspace.window.showInspector = showing
        return model
    }

    // MARK: - (i) Device Info

    func testInfoFromControlsSwitchesToInfoInsteadOfClosing() {
        // The old (i) only toggled visibility: from Controls it closed the
        // inspector, and the next click reopened Controls, with no segmented
        // control to get back to Info.
        let model = model(tab: .controls, showing: true)
        model.workspace.window.toggleDeviceInfoInspector()
        XCTAssertTrue(model.workspace.window.showInspector)
        XCTAssertEqual(model.workspace.window.inspectorTab, .info)
    }

    func testInfoFromDiagnosticsSwitchesToInfo() {
        let model = model(tab: .diagnostics, showing: true)
        model.workspace.window.toggleDeviceInfoInspector()
        XCTAssertTrue(model.workspace.window.showInspector)
        XCTAssertEqual(model.workspace.window.inspectorTab, .info)
    }

    func testInfoClosesTheInfoAppsInspector() {
        for tab in [WindowState.InspectorTab.info, .apps] {
            let model = model(tab: tab, showing: true)
            model.workspace.window.toggleDeviceInfoInspector()
            XCTAssertFalse(model.workspace.window.showInspector, "\(tab)")
            XCTAssertEqual(model.workspace.window.inspectorTab, tab, "closing keeps the tab")
        }
    }

    func testInfoReopensOnTheLastInfoAppsTab() {
        let apps = model(tab: .apps, showing: false)
        apps.workspace.window.toggleDeviceInfoInspector()
        XCTAssertTrue(apps.workspace.window.showInspector)
        XCTAssertEqual(apps.workspace.window.inspectorTab, .apps)

        let controls = model(tab: .controls, showing: false)
        controls.workspace.window.toggleDeviceInfoInspector()
        XCTAssertTrue(controls.workspace.window.showInspector)
        XCTAssertEqual(controls.workspace.window.inspectorTab, .info)
    }

    // MARK: - Active circles

    func testOnlyTheShownSurfacesButtonIsActive() {
        let cases: [(WindowState.InspectorTab, InspectorToolbarButton)] = [
            (.controls, .controls),
            (.diagnostics, .diagnostics),
            (.info, .deviceInfo),
            (.apps, .deviceInfo),
        ]
        for (tab, lit) in cases {
            let model = model(tab: tab, showing: true)
            for button in InspectorToolbarButton.allCases {
                XCTAssertEqual(
                    model.workspace.window.isInspectorToolbarButtonActive(button),
                    button == lit,
                    "\(tab): \(button)"
                )
            }
        }
    }

    func testNoButtonIsActiveWhileTheInspectorIsHidden() {
        let model = model(tab: .controls, showing: false)
        for button in InspectorToolbarButton.allCases {
            XCTAssertFalse(model.workspace.window.isInspectorToolbarButtonActive(button))
        }
    }

    // MARK: - Toolbar accessibility

    func testActiveModesAreSelected() {
        let fit = ToolbarButtonAccessibility(active: true, toggleState: nil)
        XCTAssertTrue(fit.isSelected)
        XCTAssertFalse(fit.isToggle)
        XCTAssertNil(fit.value)
        XCTAssertFalse(ToolbarButtonAccessibility(active: false, toggleState: nil).isSelected)
    }

    func testSettingButtonsAreTogglesWithAnOnOffValue() {
        let on = ToolbarButtonAccessibility(active: false, toggleState: true)
        let off = ToolbarButtonAccessibility(active: false, toggleState: false)
        XCTAssertTrue(on.isToggle)
        XCTAssertEqual(on.value, "on")
        XCTAssertEqual(off.value, "off")
    }

    // MARK: - Status banner

    // The banner's spinner follows the kind each writer states, never the
    // text: an outcome may quote a file name or an error with an ellipsis in
    // it, and a progress line need not end in one.

    /// An adb for `emulator-5554` whose every command waits while `hold`
    /// exists and then succeeds, so an operation's progress line stays up
    /// until the test lets it finish.
    private func parkingAdb() throws -> (client: AdbClient, hold: URL) {
        let hold = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellChromeTests-hold-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: hold) }
        let adb = try makeStubAdb(arms: """
          "-s emulator-5554 "*)
            i=0
            while [ -f "\(hold.path)" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
            printf 'Success\\n' ;;
        """)
        return (adb.client, hold)
    }

    private func holdAdb(_ hold: URL) {
        FileManager.default.createFile(atPath: hold.path, contents: nil)
    }

    func testAFlashIsAnOutcomeWhateverItsText() {
        let model = model(tab: .apps, showing: true)
        model.status.flash("Device frame unavailable — continuing without it: no skin in …/skins/pixel_9")
        XCTAssertEqual(model.status.statusKind, .outcome)
    }

    func testTheElapsedLineIsProgressWithOrWithoutAnEllipsis() async {
        let model = model(tab: .apps, showing: true)
        await model.status.withElapsedStatus("Stopping Pixel_9…") {
            XCTAssertEqual(model.status.statusKind, .progress)
        }
        await model.status.withElapsedStatus("Stopping Pixel_9") {
            XCTAssertEqual(model.status.statusMessage, "Stopping Pixel_9")
            XCTAssertEqual(model.status.statusKind, .progress)
        }
    }

    /// The install line is progress while adb runs; the result line held
    /// after it is an outcome, also for an APK whose name has an ellipsis.
    /// `apps` is per-device: its lines land on
    /// `model.workspace.status`, not the app-global `model.status`.
    func testInstallShowsProgressThenAnOutcome() async throws {
        let (adb, hold) = try parkingAdb()
        let model = AppModel.testing(adb: adb)
        // No such file: the install is the stub's, and the recents entry it
        // records is pruned again below.
        let apk = URL(fileURLWithPath: "/nonexistent/Nightly…build.apk")

        holdAdb(hold)
        let install = Task { await model.workspace.apps.installAPK(at: apk, serial: "emulator-5554") }
        await waitUntil("the install line never showed") {
            model.workspace.status.statusMessage == "Installing Nightly…build.apk…"
        }
        XCTAssertEqual(model.workspace.status.statusKind, .progress)

        try FileManager.default.removeItem(at: hold)
        await waitUntil("the result line never showed") {
            model.workspace.status.statusMessage == "Nightly…build.apk installed"
        }
        XCTAssertEqual(model.workspace.status.statusKind, .outcome, "a finished install shows no spinner")

        // Ends the result line's two-second hold.
        install.cancel()
        await install.value
        XCTAssertNil(model.workspace.status.statusMessage)
        model.workspace.apps.recentAPKs.pruneMissingFiles()
    }

    /// Launch, uninstall, force stop and clear data: each line is progress
    /// while adb runs, and each result flash is an outcome. `apps` is
    /// per-device: its lines land on
    /// `model.workspace.status`.
    func testAppActionsShowProgressThenAnOutcome() async throws {
        let (adb, hold) = try parkingAdb()
        let model = AppModel.testing(adb: adb)
        model.deviceSelection = .device("emulator-5554")
        let actions: [(run: @MainActor (AppModel) async -> Void, progress: String, outcome: String)] = [
            ({ await $0.workspace.apps.launchApp(package: "com.example") }, "Launching com.example…", "Launched com.example"),
            ({ await $0.workspace.apps.uninstallApp(package: "com.example") }, "Uninstalling com.example…", "Uninstalled com.example"),
            ({ await $0.workspace.apps.forceStopApp(package: "com.example") }, "Force stopping com.example…", "Stopped com.example"),
            ({ await $0.workspace.apps.clearAppData(package: "com.example") }, "Clearing data for com.example…", "Cleared data for com.example"),
        ]

        for action in actions {
            holdAdb(hold)
            let run = Task { await action.run(model) }
            await waitUntil("\(action.progress) never showed") { model.workspace.status.statusMessage == action.progress }
            XCTAssertEqual(model.workspace.status.statusKind, .progress, action.progress)

            try FileManager.default.removeItem(at: hold)
            await run.value
            XCTAssertEqual(model.workspace.status.statusMessage, action.outcome)
            XCTAssertEqual(model.workspace.status.statusKind, .outcome, action.outcome)
        }
    }

    /// Start's lines (here the first, shown while the VM starts up) are
    /// progress. Power On shows its lines through the same kind of writer.
    /// `startAndMirror` is per-device ("mirror/attach"): it
    /// writes through `deviceStatus()` (the focused workspace's own center
    /// with one workspace), not the app-global `model.status`.
    func testStartShowsProgress() async {
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        let bootTiming = EmulatorBootController.BootTiming(
            startupGrace: .milliseconds(500),
            poll: .milliseconds(100),
            onlineTimeout: .seconds(1),
            bootTimeout: .seconds(1)
        )
        model.boot.bootTiming = bootTiming
        model.apps.bootTiming = bootTiming
        let avd = "Status_\(UUID().uuidString.prefix(6))"
        addTeardownBlock { try? FileManager.default.removeItem(at: EmulatorManager.inert.logFileURL(forAvd: avd)) }

        // The emulator is `/usr/bin/false`: it exits at once and the start
        // fails once the startup grace is over.
        let start = Task { await model.startAndMirror(avd: avd) }
        await waitUntil("the start line never showed") { model.workspace.status.statusMessage == "Starting \(avd)…" }
        XCTAssertEqual(model.workspace.status.statusKind, .progress)
        await start.value
        XCTAssertNil(model.workspace.status.statusMessage, "the start clears its own line")
    }

    /// A line written without a stated kind (the `statusMessage` setter the
    /// tests use) claims no work under way, so it shows no spinner.
    func testALineWrittenWithoutAKindIsAnOutcome() {
        let model = model(tab: .apps, showing: true)
        model.status.showOutcome("Working…")
        XCTAssertEqual(model.status.statusKind, .outcome)
        model.status.clear()
        XCTAssertNil(model.status.statusMessage)
    }

    // MARK: - Leading cluster

    func testTheClusterHugsAnExpandedSidebarsDivider() {
        // The stock 300 pt sidebar: the audited toggle edge at x≈289 + inset.
        let x = LeadingToolbarAccessoryController.clusterTrailingX(sidebarMaxX: 296, windowButtonsMaxX: 72)
        XCTAssertEqual(x, 296 - ParityMetrics.toolbarLeadingAccessoryTrailingInset)
    }

    func testACollapsedSidebarParksTheToggleBesideTheWindowButtons() {
        // The old code found no sidebar once it collapsed and left the
        // cluster at its expanded position, floating over the detail. DH's
        // collapsed toolbar keeps only the sidebar toggle, 17 pt after a zoom
        // button ending at 80 pt (its centre reads 114 pt, DH's).
        let x = LeadingToolbarAccessoryController.clusterTrailingX(sidebarMaxX: nil, windowButtonsMaxX: 80)
        XCTAssertEqual(x - ParityMetrics.toolbarLeadingCollapsedClusterWidth, 80 + 17)
        XCTAssertEqual(ParityMetrics.toolbarLeadingCollapsedClusterWidth, ParityMetrics.toolbarSidebarToggleDiameter)
    }

    func testACollapsingSidebarNeverPushesTheClusterUnderTheWindowButtons() {
        let floor = LeadingToolbarAccessoryController.clusterTrailingX(sidebarMaxX: nil, windowButtonsMaxX: 72)
        let midCollapse = LeadingToolbarAccessoryController.clusterTrailingX(sidebarMaxX: 90, windowButtonsMaxX: 72)
        XCTAssertEqual(midCollapse, floor)
    }

    func testTheClusterWidthIsTheAuditedCapsulesAndToggle() {
        // DH 27.0, re-measured 2026-09-28: a 74 pt capsule (173.5–248 pt
        // rendered) + 8 pt gap + 36 pt toggle (255.5–292.5 pt).
        XCTAssertEqual(ParityMetrics.toolbarLeadingClusterWidth, 118)
    }
}
