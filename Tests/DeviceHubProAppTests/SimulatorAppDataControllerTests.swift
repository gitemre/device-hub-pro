import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The app data inspector's controller (`SimulatorAppDataController`) and the
/// App State and sample data actions of `SimulatorAppsController`, on a stub
/// simctl and temporary folders standing in for a data container. The stub
/// answers `get_app_container … data` with the folder; the running-app check
/// reads the real `launchctl list` capture (`simctl-spawn-launchctl-list.ready`,
/// where `com.apple.family` runs). The group listing's line format
/// (`<group id><TAB><path>`) is the capture's
/// (`simctl-get_app_container-groups.stdout.txt`), with a path of the test's own.
@MainActor
final class SimulatorAppDataControllerTests: XCTestCase {
    private static let udid = "95D9676B-3317-4BA5-8CF6-3CDD0488CACA"

    private func makeApp(bundle: String) -> SimulatorApp {
        SimulatorApp(
            bundleIdentifier: bundle, displayName: "Fixture", bundleName: "Fixture", executable: "Fixture",
            shortVersion: "1", version: "1", applicationType: "User", path: nil, dataContainer: nil,
            groupContainers: [:], isAppClip: false, isDeveloperApp: true, isFirstParty: false,
            isHidden: false, isRemovable: true, tags: []
        )
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private struct Rig {
        let controller: SimulatorAppDataController
        let stub: StubTool
        let container: URL
        let group: URL
        let status: StatusCenter
    }

    /// `launchctl` answers with the ready capture, where `bundle` may run.
    private func rig(bundle: String = "dev.example.inspector") throws -> Rig {
        let container = try makeTemporaryFolder("container")
        let group = try makeTemporaryFolder("group")
        let u = Self.udid
        let stub = try makeStubTool("simctl", arms: """
          *"get_app_container \(u) \(bundle) data")
            printf '%s\\n' \(SimulatorFixtures.quoted(container.path)) ;;
          *"get_app_container \(u) \(bundle) groups")
            printf 'group.dev.example.shared\\t%s\\n' \(SimulatorFixtures.quoted(group.path)) ;;
          *"spawn \(u) launchctl list")
            \(SimulatorFixtures.cat("simctl-spawn-launchctl-list.ready.stdout.txt")) ;;
          *"terminate \(u) "*)
            exit 0 ;;
        """)
        let status = StatusCenter()
        let controller = SimulatorAppDataController(
            app: makeApp(bundle: bundle), udid: u,
            simctl: SimctlClient(simctlURL: stub.url),
            status: status, temporaryDirectory: try makeTemporaryFolder("tmp")
        )
        addTeardownBlock { @MainActor in controller.close() }
        return Rig(controller: controller, stub: stub, container: container, group: group, status: status)
    }

    func testStartFindsTheDataContainerAndTheGroupsAndListsTheTop() async throws {
        let rig = try rig()
        try write("a", to: rig.container.appendingPathComponent("Documents/a.txt"))
        try write("b", to: rig.group.appendingPathComponent("shared.txt"))

        await rig.controller.start()

        XCTAssertEqual(rig.controller.roots.map(\.title), ["Data Container", "group.dev.example.shared"])
        XCTAssertEqual(rig.controller.entries.map(\.name), ["Documents"])
        let group = try XCTUnwrap(rig.controller.roots.last)
        await rig.controller.select(root: group)
        XCTAssertEqual(rig.controller.entries.map(\.name), ["shared.txt"])
        XCTAssertFalse(rig.controller.canGoUp)
    }

    func testNavigationStaysInsideTheContainer() async throws {
        let rig = try rig()
        try write("a", to: rig.container.appendingPathComponent("Documents/deep/a.txt"))
        await rig.controller.start()
        let documents = try XCTUnwrap(rig.controller.entries.first)
        await rig.controller.open(documents)
        XCTAssertTrue(rig.controller.canGoUp)
        XCTAssertEqual(rig.controller.breadcrumb.count, 2)
        await rig.controller.goUp()
        XCTAssertFalse(rig.controller.canGoUp)
        await rig.controller.goUp()
        XCTAssertEqual(rig.controller.entries.map(\.name), ["Documents"], "going up from the root does nothing")
    }

    func testDeleteRemovesTheFileAndListsAgain() async throws {
        let rig = try rig()
        try write("a", to: rig.container.appendingPathComponent("a.txt"))
        try write("b", to: rig.container.appendingPathComponent("b.txt"))
        await rig.controller.start()
        let first = try XCTUnwrap(rig.controller.entries.first)
        await rig.controller.delete(first)
        XCTAssertEqual(rig.controller.entries.map(\.name), ["b.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.container.appendingPathComponent("a.txt").path))
    }

    func testPreferencesAreEditedAndWrittenWhileTheAppIsNotRunning() async throws {
        let rig = try rig()
        let plist = rig.container.appendingPathComponent("Library/Preferences/dev.example.inspector.plist")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["launches": 1, "name": "x"], format: .binary, options: 0
        ).write(to: plist)
        await rig.controller.start()
        XCTAssertEqual(rig.controller.preferenceEntries.map(\.key), ["launches", "name"])

        XCTAssertTrue(rig.controller.setPreference(key: "launches", kind: .integer, text: "9"))
        XCTAssertTrue(rig.controller.preferencesDirty)
        // Nothing reaches the file before the save.
        XCTAssertEqual(try PreferencesDocument(contentsOf: plist).entries.first { $0.key == "launches" }?.text, "1")

        let outcome = await rig.controller.savePreferences(terminatingIfRunning: false)
        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(try PreferencesDocument(contentsOf: plist).entries.first { $0.key == "launches" }?.text, "9")
        XCTAssertFalse(rig.controller.preferencesDirty)
        XCTAssertFalse(rig.stub.calls.contains { $0.hasPrefix("terminate") })
    }

    func testPreferencesAreNotWrittenWhileTheAppRunsUnlessItIsTerminated() async throws {
        // `com.apple.family` runs in the capture.
        let rig = try rig(bundle: "com.apple.family")
        let plist = rig.container.appendingPathComponent("Library/Preferences/com.apple.family.plist")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["k": "old"], format: .xml, options: 0).write(to: plist)
        await rig.controller.start()
        XCTAssertTrue(rig.controller.setPreference(key: "k", kind: .string, text: "new"))

        let refused = await rig.controller.savePreferences(terminatingIfRunning: false)
        XCTAssertEqual(refused, .appRunning)
        XCTAssertEqual(try PreferencesDocument(contentsOf: plist).entries.first?.text, "old", "the file is untouched")
        XCTAssertTrue(rig.controller.preferencesDirty, "the edit is kept for the next try")
        XCTAssertFalse(rig.stub.calls.contains { $0.hasPrefix("terminate") })

        let saved = await rig.controller.savePreferences(terminatingIfRunning: true)
        XCTAssertEqual(saved, .saved)
        XCTAssertEqual(try PreferencesDocument(contentsOf: plist).entries.first?.text, "new")
        XCTAssertTrue(rig.stub.calls.contains { $0.hasSuffix("terminate \(Self.udid) com.apple.family") })
    }

    func testAMissingPreferencesFileSaysSo() async throws {
        let rig = try rig()
        await rig.controller.start()
        XCTAssertNil(rig.controller.preferences)
        XCTAssertNotNil(rig.controller.preferencesProblem)
    }

    func testDatabasesAreFoundByTheirHeaderAndOpenedReadOnly() async throws {
        let rig = try rig()
        let database = rig.container.appendingPathComponent("Library/Application Support/app.sqlite")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        let made = try await ProcessRunner.run(
            executable: SQLiteBrowser.defaultExecutable,
            arguments: [database.path, "CREATE TABLE t (a, b); INSERT INTO t VALUES (1, 'two');"],
            timeout: .seconds(20)
        )
        XCTAssertEqual(made.exitCode, 0)
        try write("not a database", to: rig.container.appendingPathComponent("Documents/fake.sqlite"))
        let before = try Data(contentsOf: database)

        await rig.controller.start()
        XCTAssertEqual(rig.controller.databases.map(\.lastPathComponent), ["app.sqlite"])
        await rig.controller.openDatabase(try XCTUnwrap(rig.controller.databases.first))
        XCTAssertEqual(rig.controller.tables.map(\.name), ["t"])
        XCTAssertEqual(rig.controller.rows?.rows, [["1", "two"]])
        XCTAssertEqual(try Data(contentsOf: database), before)
    }

    // MARK: - App state and sample data (SimulatorAppsController)

    private func appsHarness() async throws -> (SimulatorAppsController, StatusCenter, StubTool, URL) {
        let container = try makeTemporaryFolder("state-container")
        let u = Self.udid
        let stub = try makeStubTool("simctl", arms: """
          *"list -j devices")
            \(SimulatorFixtures.cat("simctl-list-j-devices.booted.json")) ;;
          *"list -j runtimes")
            \(SimulatorFixtures.cat("simctl-list-j-runtimes.json")) ;;
          *"list -j devicetypes")
            \(SimulatorFixtures.cat("simctl-list-j-devicetypes.json")) ;;
          *" get_app_container \(u) dev.example.inspector data")
            printf '%s\\n' \(SimulatorFixtures.quoted(container.path)) ;;
          *" terminate \(u) "*|*" addmedia \(u) "*)
            exit 0 ;;
        """)
        let inventory = SimulatorInventory(
            apple: .stubbed(
                simctl: stub,
                devicesDirectory: try makeTemporaryFolder("set"),
                logsDirectory: try makeTemporaryFolder("logs")
            ),
            preferences: AppPreferences(defaults: .scratch())
        )
        addTeardownBlock { @MainActor in inventory.stop() }
        await inventory.refresh()
        let status = StatusCenter()
        let controller = SimulatorAppsController(simulators: inventory, status: status, defaults: .scratch())
        controller.temporaryDirectory = try makeTemporaryFolder("unzip")
        controller.revealInFinder = { _ in }
        return (controller, status, stub, container)
    }

    func testSaveAndRestoreAppStateStopTheAppAndRoundTrip() async throws {
        let (controller, status, stub, container) = try await appsHarness()
        let app = makeApp(bundle: "dev.example.inspector")
        try write("one", to: container.appendingPathComponent("Documents/n.txt"))
        let archive = try makeTemporaryFolder("zips").appendingPathComponent("state.zip")

        await controller.saveAppState(app, udid: Self.udid, to: archive)
        XCTAssertNil(status.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertTrue(stub.calls.contains { $0.hasSuffix("terminate \(Self.udid) dev.example.inspector") })

        try write("two", to: container.appendingPathComponent("Documents/n.txt"))
        await controller.restoreAppState(app, udid: Self.udid, from: archive)
        XCTAssertNil(status.errorMessage)
        XCTAssertEqual(try String(contentsOf: container.appendingPathComponent("Documents/n.txt"), encoding: .utf8), "one")
        XCTAssertEqual(stub.calls.filter { $0.contains("terminate") }.count, 2)
        XCTAssertNil(controller.activity)
    }

    func testRestoringABadArchiveReportsAndKeepsTheData() async throws {
        let (controller, status, _, container) = try await appsHarness()
        let app = makeApp(bundle: "dev.example.inspector")
        try write("one", to: container.appendingPathComponent("Documents/n.txt"))
        let bad = try makeTemporaryFolder("zips").appendingPathComponent("bad.zip")
        try write("nope", to: bad)
        await controller.restoreAppState(app, udid: Self.udid, from: bad)
        XCTAssertNotNil(status.errorMessage)
        XCTAssertEqual(try String(contentsOf: container.appendingPathComponent("Documents/n.txt"), encoding: .utf8), "one")
        XCTAssertNil(controller.activity)
    }

    func testSampleContactsAndPhotosGoThroughAddmediaAndLeaveNoTemporaryFiles() async throws {
        let (controller, status, stub, _) = try await appsHarness()
        let scratch = controller.temporaryDirectory

        await controller.addSampleContacts(count: 10, udid: Self.udid)
        let contactsCall = try XCTUnwrap(stub.calls.first { $0.contains("addmedia") })
        XCTAssertTrue(contactsCall.contains("Sample Contacts 10.vcf"), contactsCall)

        await controller.addSamplePhotos(count: 3, udid: Self.udid)
        let photosCall = try XCTUnwrap(stub.calls.last { $0.contains("addmedia") })
        XCTAssertTrue(photosCall.contains("Sample Photo 01.png"), photosCall)
        XCTAssertTrue(photosCall.contains("Sample Photo 03.png"), photosCall)

        XCTAssertNil(status.errorMessage)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [], "the generated files are removed")
    }
}
