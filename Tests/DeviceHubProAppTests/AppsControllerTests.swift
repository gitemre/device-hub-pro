import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// `AppsController` on its own, without `AppModel`: the serials it targets,
/// the package-set change it reports, the list load's newest-wins rule, what
/// a successful install reloads and records, and the busy window an install
/// holds through its result line.
///
/// A stub adb answers for `emulator-5554` (the listed device) and
/// `emulator-5556`; any other serial fails. Nothing reaches a real device.
@MainActor
final class AppsControllerTests: XCTestCase {
    private let listed = "emulator-5554"
    private let other = "emulator-5556"
    /// No such file: the install is the stub's.
    private let apk = URL(fileURLWithPath: "/nonexistent/app-debug.apk")

    /// Its owner side of the controller's hooks: the serials it reads and
    /// the package-set changes it was told about.
    @MainActor
    private final class Owner {
        var inspectorSerial: String?
        var activeSerial: String?
        var changedPackages: [String] = []
    }

    private struct Harness {
        let controller: AppsController
        let adb: StubAdb
        let status: StatusCenter
        let owner: Owner
        let pasteboard: TestPasteboard
    }

    /// A controller wired to an `Owner`, on a stub adb whose `extraArms` are
    /// matched first. The listings are lines of the API 37 emulator's
    /// captures (`Fixtures/api37-emulator/adb-core`).
    private func makeHarness(extraArms: String = "", defaults: UserDefaults = .scratch()) throws -> Harness {
        let adb = try makeStubAdb(arms: """
        \(extraArms)
          "-s emulator-5554 shell pm list packages --show-versioncode")
            printf 'package:com.android.settings versionCode:37\\npackage:com.devicehubpro.verifier versionCode:1\\n' ;;
          "-s emulator-5554 shell pm list packages --show-versioncode -3")
            printf 'package:com.devicehubpro.verifier versionCode:1\\n' ;;
          "-s emulator-5554 install "*|"-s emulator-5556 install "*|"-s emulator-5554 uninstall "*|"-s emulator-5556 uninstall "*)
            printf 'Success\\n' ;;
          "-s emulator-5554 shell monkey "*|"-s emulator-5556 shell monkey "*)
            printf 'Events injected: 1\\n' ;;
        """)
        let status = StatusCenter()
        let pasteboard = TestPasteboard()
        let controller = AppsController(
            adbClient: adb.client,
            status: status,
            recentAPKs: RecentAPKStore(defaults: defaults),
            pasteboard: pasteboard
        )
        let owner = Owner()
        controller.inspectorSerialSource = { [owner] in owner.inspectorSerial }
        controller.activeSerialSource = { [owner] in owner.activeSerial }
        controller.packagesChanged = { [owner] serial in owner.changedPackages.append(serial) }
        return Harness(controller: controller, adb: adb, status: status, owner: owner, pasteboard: pasteboard)
    }

    /// A file whose existence keeps the stub's `-s <serial> <command>` waiting
    /// (for up to 10 s), so a test can hold an adb call in flight.
    private func makeHold() -> URL {
        let hold = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppsControllerTests-hold-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: hold.path, contents: nil)
        addTeardownBlock { try? FileManager.default.removeItem(at: hold) }
        return hold
    }

    private func waitWhile(_ hold: URL) -> String {
        """
        i=0
            while [ -f "\(hold.path)" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
        """
    }

    /// Installs `apk` on `serial` and, once the result line shows, ends its
    /// two-second hold.
    private func install(_ harness: Harness, on serial: String?) async {
        let install = Task { await harness.controller.installAPK(at: apk, serial: serial) }
        await waitUntil("the install never showed its result") {
            harness.status.statusMessage == "app-debug.apk installed"
        }
        install.cancel()
        await install.value
    }

    // MARK: - Targets

    /// The app actions act on the device the inspector shows, and on the
    /// mirrored one only when the inspector shows none.
    func testAppActionsTargetTheInspectedDeviceBeforeTheMirroredOne() async throws {
        let harness = try makeHarness()
        harness.owner.inspectorSerial = other
        harness.owner.activeSerial = listed

        await harness.controller.launchApp(package: "com.devicehubpro.verifier")
        XCTAssertEqual(harness.adb.calls(containing: "shell monkey").count, 1)
        XCTAssertEqual(harness.adb.calls(containing: "-s \(other) shell monkey").count, 1)

        harness.owner.inspectorSerial = nil
        await harness.controller.launchApp(package: "com.devicehubpro.verifier")
        XCTAssertEqual(harness.adb.calls(containing: "-s \(listed) shell monkey").count, 1)
        XCTAssertNil(harness.status.errorMessage)
    }

    /// An install goes to the device its caller names, else to the mirrored
    /// one — never to the inspected one — and without either it asks for a
    /// device instead of running adb.
    func testAnInstallTargetsItsArgumentThenTheMirroredDevice() async throws {
        let harness = try makeHarness()
        harness.owner.inspectorSerial = other
        harness.owner.activeSerial = listed

        await install(harness, on: nil)
        XCTAssertEqual(harness.adb.calls(containing: " install ").count, 1)
        XCTAssertEqual(harness.adb.calls(containing: "-s \(listed) install ").count, 1)

        harness.owner.activeSerial = nil
        await harness.controller.installAPK(at: apk)
        XCTAssertEqual(harness.status.errorMessage, "Connect a device before installing an APK.")
        XCTAssertEqual(harness.adb.calls(containing: " install ").count, 1)
    }

    // MARK: - Package-set changes

    /// A successful install or uninstall tells its owner once, with the
    /// device it changed; a failed one tells it nothing.
    func testInstallAndUninstallEachReportTheirDevicesPackageChangeOnce() async throws {
        let harness = try makeHarness()

        await install(harness, on: listed)
        XCTAssertEqual(harness.owner.changedPackages, [listed])

        harness.owner.inspectorSerial = other
        await harness.controller.uninstallApp(package: "com.devicehubpro.verifier")
        XCTAssertEqual(harness.owner.changedPackages, [listed, other])
        XCTAssertNil(harness.status.errorMessage)

        // No arm answers emulator-5558: both commands fail.
        await harness.controller.installAPK(at: apk, serial: "emulator-5558")
        XCTAssertNotNil(harness.status.errorMessage)
        harness.status.errorMessage = nil
        harness.owner.inspectorSerial = "emulator-5558"
        await harness.controller.uninstallApp(package: "com.devicehubpro.verifier")
        XCTAssertNotNil(harness.status.errorMessage)
        XCTAssertEqual(harness.owner.changedPackages, [listed, other])
    }

    /// A successful install reloads the Apps list when the list shows the
    /// device it went to, and only then.
    func testASuccessfulInstallReloadsTheListOnlyForTheListedDevice() async throws {
        let harness = try makeHarness()
        await harness.controller.loadApps(serial: listed)
        let listings = { harness.adb.calls(containing: "pm list packages").count }
        XCTAssertEqual(listings(), 2, "one adb pair per load")

        await install(harness, on: other)
        XCTAssertEqual(listings(), 2, "another device's install leaves the list alone")

        await install(harness, on: listed)
        XCTAssertEqual(listings(), 4, "the listed device's install reloads it")
        XCTAssertEqual(harness.controller.appsSerial, listed)
    }

    // MARK: - Loads

    /// All Apps leaves out the SDK's generated resource overlays (packages,
    /// not apps); System Apps and a search still reach them.
    func testResourceOverlaysAreOnlyInSystemAppsAndSearch() {
        let ids = ["android.auto_generated_characteristics_rro", "com.android.bips.auto_generated_rro_product__", "com.android.settings"]
        XCTAssertEqual(ids.filter(AppsController.isResourceOverlay), Array(ids.prefix(2)))
        XCTAssertFalse(AppsController.isResourceOverlay("com.example.notes"))
    }

    /// The list loads the full listing and marks the `-3` packages as user
    /// apps; the scope and the filter apply over that one list.
    func testALoadListsEveryPackageAndSplitsTheScopes() async throws {
        let harness = try makeHarness()
        let controller = harness.controller

        await controller.loadApps(serial: listed)

        XCTAssertEqual(controller.appsSerial, listed)
        XCTAssertFalse(controller.isLoadingApps)
        XCTAssertEqual(controller.appsScope, .all)
        XCTAssertEqual(controller.filteredApps.map(\.id).sorted(), ["com.android.settings", "com.devicehubpro.verifier"])
        controller.appsScope = .user
        XCTAssertEqual(controller.filteredApps.map(\.id), ["com.devicehubpro.verifier"])
        controller.appsScope = .system
        XCTAssertEqual(controller.filteredApps.map(\.id), ["com.android.settings"])
        controller.appsScope = .all
        // No "I" in the query: the match is locale-aware, and a Turkish
        // locale does not fold "I" to "i".
        controller.appsFilter = " SETT "
        XCTAssertEqual(controller.filteredApps.map(\.id), ["com.android.settings"])
    }

    /// Only the newest load applies: an older one that answers after it
    /// changes nothing, neither the list nor the loading state.
    func testAStaleLoadIsIgnored() async throws {
        let hold = makeHold()
        let harness = try makeHarness(extraArms: """
          "-s emulator-5556 shell pm list packages --show-versioncode"*)
            \(waitWhile(hold))
            printf 'package:com.google.android.feedback versionCode:37\\n' ;;
        """)
        let controller = harness.controller

        let stale = Task { await controller.loadApps(serial: other) }
        await waitUntil("the first load never started") {
            !harness.adb.calls(containing: "-s \(other) shell pm list packages").isEmpty
        }
        await controller.loadApps(serial: listed)
        XCTAssertFalse(controller.isLoadingApps)

        try FileManager.default.removeItem(at: hold)
        await stale.value

        XCTAssertEqual(controller.appsSerial, listed)
        XCTAssertEqual(controller.installedAppList.map(\.id), ["com.android.settings", "com.devicehubpro.verifier"])
        XCTAssertFalse(controller.isLoadingApps)
        XCTAssertNil(harness.status.errorMessage)
    }

    /// A cancelled load leaves nothing behind: no alert, and no `appsSerial`,
    /// so the tab loads again when it returns.
    func testACancelledLoadLeavesNoSerialAndNoAlert() async throws {
        let hold = makeHold()
        let harness = try makeHarness(extraArms: """
          "-s emulator-5556 shell pm list packages"*)
            \(waitWhile(hold))
            printf 'package:com.google.android.feedback versionCode:37\\n' ;;
        """)
        let controller = harness.controller

        let load = Task { await controller.loadApps(serial: other) }
        await waitUntil("the load never started") {
            !harness.adb.calls(containing: "pm list packages").isEmpty
        }
        load.cancel()
        await load.value

        XCTAssertNil(controller.appsSerial)
        XCTAssertNil(harness.status.errorMessage)
        XCTAssertFalse(controller.isLoadingApps)
    }

    // MARK: - A device still booting

    /// A stub for `emulator-5556` that boots when `booted` appears: until
    /// then `pm` has no package manager to reach and `getprop` reports no
    /// completed boot. The refusal is the real one, captured live on
    /// 2026-09-28 (stderr bytes and exit status) from `adb -s emulator-5580
    /// shell pm list packages --show-versioncode` on an API 37.1 Pixel 9 Pro
    /// Fold emulator in the first second adb listed it: "cmd: Can't find
    /// service: package\n", exit 20, `sys.boot_completed` empty (the
    /// listing answered a second later, the boot completed later still).
    private func bootingArms(booted: URL, pmBeforeBoot: String = "printf \"cmd: Can't find service: package\\n\" >&2; exit 20") -> String {
        """
          "-s emulator-5556 shell getprop")
            if [ -f "\(booted.path)" ]; then printf '[sys.boot_completed]: [1]\\n'; else printf '[init.svc.bootanim]: [running]\\n'; fi ;;
          "-s emulator-5556 shell pm list packages --show-versioncode")
            [ -f "\(booted.path)" ] || { \(pmBeforeBoot); }
            printf 'package:com.android.settings versionCode:37\\npackage:com.devicehubpro.verifier versionCode:1\\n' ;;
          "-s emulator-5556 shell pm list packages --show-versioncode -3")
            [ -f "\(booted.path)" ] || { \(pmBeforeBoot); }
            printf 'package:com.devicehubpro.verifier versionCode:1\\n' ;;
        """
    }

    private func bootFlag() -> URL {
        let flag = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppsControllerTests-booted-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: flag) }
        return flag
    }

    /// The race the live pass found: the Apps tab lists an emulator the
    /// moment adb shows it, before Android's package manager is up. That is
    /// no error: no alert, the tab keeps loading, and the list arrives once
    /// the boot completes.
    func testAListingBeforeThePackageManagerIsUpWaitsForTheBoot() async throws {
        let booted = bootFlag()
        let harness = try makeHarness(extraArms: bootingArms(booted: booted))
        let controller = harness.controller
        controller.bootTiming.poll = .milliseconds(50)

        let load = Task { await controller.loadApps(serial: other) }
        await waitUntil("the load never waited for the boot") { controller.isWaitingForBoot }
        XCTAssertNil(harness.status.errorMessage, "a booting device raises no alert")
        XCTAssertTrue(controller.isLoadingApps)
        XCTAssertNil(controller.appsSerial)
        XCTAssertEqual(controller.installedAppList, [])

        try Data().write(to: booted)
        await load.value

        XCTAssertNil(harness.status.errorMessage)
        XCTAssertEqual(controller.appsSerial, other)
        XCTAssertEqual(controller.installedAppList.map(\.id), ["com.android.settings", "com.devicehubpro.verifier"])
        XCTAssertEqual(controller.filteredApps.map(\.id), ["com.devicehubpro.verifier", "com.android.settings"])
        XCTAssertFalse(controller.isLoadingApps)
        XCTAssertFalse(controller.isWaitingForBoot)
        XCTAssertGreaterThanOrEqual(harness.adb.calls(containing: "-s \(other) shell getprop").count, 1, "it waited on the boot property")
    }

    /// Any listing failure while `sys.boot_completed` is not 1 waits too:
    /// the package manager can answer something else mid-boot.
    func testAnyListingFailureMidBootWaitsForTheBoot() async throws {
        let booted = bootFlag()
        let harness = try makeHarness(extraArms: bootingArms(
            booted: booted,
            pmBeforeBoot: "printf 'Failure calling service package: Broken pipe (32)\\n' >&2; exit 255"
        ))
        let controller = harness.controller
        controller.bootTiming.poll = .milliseconds(50)

        let load = Task { await controller.loadApps(serial: other) }
        await waitUntil("the load never waited for the boot") { controller.isWaitingForBoot }
        try Data().write(to: booted)
        await load.value

        XCTAssertNil(harness.status.errorMessage)
        XCTAssertEqual(controller.appsSerial, other)
        XCTAssertEqual(controller.installedAppList.count, 2)
    }

    /// A booted device's failure is an error as before: one alert, no wait.
    func testABootedDevicesFailureStillAlerts() async throws {
        let harness = try makeHarness(extraArms: """
          "-s emulator-5556 shell getprop")
            printf '[sys.boot_completed]: [1]\\n' ;;
          "-s emulator-5556 shell pm list packages"*)
            printf 'cmd: Failure calling service package\\n' >&2; exit 255 ;;
        """)
        let controller = harness.controller
        controller.bootTiming.poll = .milliseconds(50)

        await controller.loadApps(serial: other)

        XCTAssertEqual(
            harness.status.errorMessage,
            "adb -s emulator-5556 shell pm list packages --show-versioncode failed (255): cmd: Failure calling service package\n"
        )
        XCTAssertEqual(controller.appsSerial, other)
        XCTAssertFalse(controller.isLoadingApps)
        XCTAssertFalse(controller.isWaitingForBoot)
    }

    /// Leaving the tab while the load waits for the boot leaves nothing
    /// behind: no alert, no `appsSerial`, no loading state, and no more
    /// boot polls.
    func testACancelledBootWaitLeavesNoSerialAndNoAlert() async throws {
        let harness = try makeHarness(extraArms: bootingArms(booted: bootFlag()))
        let controller = harness.controller
        controller.bootTiming.poll = .milliseconds(50)

        let load = Task { await controller.loadApps(serial: other) }
        await waitUntil("the load never waited for the boot") { controller.isWaitingForBoot }
        load.cancel()
        await load.value
        let polls = harness.adb.calls(containing: "shell getprop").count
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(controller.appsSerial)
        XCTAssertNil(harness.status.errorMessage)
        XCTAssertFalse(controller.isLoadingApps)
        XCTAssertFalse(controller.isWaitingForBoot)
        XCTAssertEqual(harness.adb.calls(containing: "shell getprop").count, polls, "the wait stopped polling")
    }

    /// The package manager's refusal is recognised by its message, the one
    /// the live pass's alert showed.
    func testThePackageServiceRefusalIsRecognised() {
        let refusal = AdbError.commandFailed(
            arguments: ["-s", "emulator-5580", "shell", "pm", "list", "packages", "--show-versioncode"],
            exitCode: 20,
            message: "cmd: Can't find service: package\n"
        )
        XCTAssertEqual(
            refusal.description,
            "adb -s emulator-5580 shell pm list packages --show-versioncode failed (20): cmd: Can't find service: package\n"
        )
        XCTAssertTrue(refusal.isPackageServiceMissing)
        XCTAssertFalse(AdbError.commandFailed(arguments: [], exitCode: 1, message: "error: device offline").isPackageServiceMissing)
        XCTAssertFalse(AdbError.adbNotFound.isPackageServiceMissing)
    }

    // MARK: - Copy

    /// The copy actions put their text on the pasteboard they were given,
    /// never the Mac's, and flash what they copied. A package without a
    /// version code copies nothing and says so.
    func testCopyActionsWriteTheGivenPasteboard() async throws {
        let harness = try makeHarness()
        let controller = harness.controller
        await controller.loadApps(serial: listed)

        controller.copyAppPackageName("com.devicehubpro.verifier")
        XCTAssertEqual(harness.pasteboard.text, "com.devicehubpro.verifier")
        XCTAssertEqual(harness.status.statusMessage, "Copied package name")

        controller.copyAppVersion(package: "com.android.settings")
        XCTAssertEqual(harness.pasteboard.text, "37")
        XCTAssertEqual(harness.status.statusMessage, "Copied version 37")

        controller.copyAppDataPath("com.devicehubpro.verifier")
        XCTAssertEqual(harness.pasteboard.text, "/data/data/com.devicehubpro.verifier")
        XCTAssertEqual(harness.status.statusMessage, "Copied data path")

        controller.copyAppVersion(package: "com.example.missing")
        XCTAssertEqual(harness.status.errorMessage, "No version reported for com.example.missing.")
        XCTAssertEqual(harness.pasteboard.text, "/data/data/com.devicehubpro.verifier")
    }

    // MARK: - Recents

    /// An install is recorded in the recents only once adb reports success,
    /// and the record persists in the controller's own defaults.
    func testRecentsRecordOnlySuccessfulInstalls() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppsControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let apk = directory.appendingPathComponent("app-debug.apk")
        FileManager.default.createFile(atPath: apk.path, contents: Data())
        let defaults = UserDefaults.scratch()
        let harness = try makeHarness(defaults: defaults)

        // No arm answers emulator-5558: the install fails.
        await harness.controller.installAPK(at: apk, serial: "emulator-5558")
        XCTAssertNotNil(harness.status.errorMessage)
        XCTAssertEqual(harness.controller.recentAPKs.entries, [])

        let install = Task { await harness.controller.installAPK(at: apk, serial: listed) }
        await waitUntil("the install never showed its result") {
            harness.status.statusMessage == "app-debug.apk installed"
        }
        install.cancel()
        await install.value

        XCTAssertEqual(harness.controller.recentAPKs.entries.map(\.url.lastPathComponent), ["app-debug.apk"])
        XCTAssertEqual(
            RecentAPKStore(defaults: defaults).entries.map(\.url.lastPathComponent),
            ["app-debug.apk"],
            "the record persists in the defaults the controller was given"
        )
    }

    // MARK: - Busy window

    /// Decision (split step S10): an install keeps the busy window open
    /// through its two-second result line, not just while adb runs, so the
    /// busy-gated entry points (Start, Mirror, Rescan, the Apps footer) stay
    /// disabled until the line clears. Kept as it is. The inline
    /// "Installing…" state already ends with the adb command. Releasing the
    /// busy window before the result line would be a separate `fix:` that
    /// flips this test.
    func testAnInstallStaysBusyThroughItsResultLine() async throws {
        let harness = try makeHarness()

        let install = Task { await harness.controller.installAPK(at: apk, serial: listed) }
        await waitUntil("the install never showed its result") {
            harness.status.statusMessage == "app-debug.apk installed"
        }
        let shown = ContinuousClock.now
        XCTAssertTrue(harness.status.isBusy, "the result line holds the busy window")
        XCTAssertFalse(harness.controller.isInstallingAPK, "the inline state ends with adb")

        await install.value
        XCTAssertGreaterThanOrEqual(
            ContinuousClock.now - shown,
            .milliseconds(1500),
            "the busy window lasts through the two-second result line"
        )
        XCTAssertFalse(harness.status.isBusy)
        XCTAssertNil(harness.status.statusMessage, "the install clears its own result line")
    }

    func testUserAppsListFirstThenSystemEachAlphabetical() {
        let apps = ["com.z.sys", "com.b.user", "com.a.sys", "com.a.user"].map {
            AdbClient.InstalledPackage(id: $0, versionCode: nil)
        }
        let sorted = AppsController.userAppsFirst(apps, userIDs: ["com.b.user", "com.a.user"])
        XCTAssertEqual(sorted.map(\.id), ["com.a.user", "com.b.user", "com.a.sys", "com.z.sys"])
    }
}
