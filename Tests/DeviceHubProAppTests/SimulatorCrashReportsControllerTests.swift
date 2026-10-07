import Foundation
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// `SimulatorCrashReportsController` on a temporary reports folder holding
/// copies of the real crash reports under `DeviceHubProKitTests/Fixtures/
/// ios27-simulator/crash-reports` (provenance in `SimulatorCrashReportTests`).
/// No stub tool runs and the user's reports folder is never read.
@MainActor
final class SimulatorCrashReportsControllerTests: XCTestCase {
    private static let daemonSimulator = "D9F3A76F-51E7-4A91-B06E-11AC95157EE5"
    private static let appSimulator = "5F734077-046C-4806-9404-846115C40E1B"
    private static let settingsSimulator = "3A391D73-FFB5-4792-8F37-47F1638EA5FC"

    private func fixture(_ name: String) -> URL {
        SimulatorFixtures.url(name + ".trimmed.ips", folder: "crash-reports")
    }

    /// A controller on a temporary reports folder holding `names`; with
    /// `folderExists` false the folder is named but not there yet.
    private func makeController(
        reports names: [String],
        readsReports: Bool = true,
        folderExists: Bool = true
    ) throws -> (SimulatorCrashReportsController, TestPasteboard, URL) {
        var reports = try makeTemporaryFolder("reports")
        if !folderExists {
            reports = reports.appendingPathComponent("DiagnosticReports", isDirectory: true)
        }
        for name in names {
            try FileManager.default.copyItem(at: fixture(name), to: reports.appendingPathComponent(name + ".ips"))
        }
        var tooling = AppleTooling.stubbed(
            simctl: nil,
            devicesDirectory: try makeTemporaryFolder("set"),
            logsDirectory: try makeTemporaryFolder("logs")
        )
        tooling.diagnosticReportsDirectory = readsReports ? reports : nil
        let inventory = SimulatorInventory(apple: tooling, preferences: AppPreferences(defaults: .scratch()))
        let pasteboard = TestPasteboard()
        let controller = SimulatorCrashReportsController(simulators: inventory, pasteboard: pasteboard)
        controller.changeDebounce = .milliseconds(50)
        controller.followUpDelay = .milliseconds(100)
        // Ends the folder watch however the test ends.
        addTeardownBlock { @MainActor in controller.hide() }
        return (controller, pasteboard, reports)
    }

    /// Waits for `condition`, failing the test (at the caller's line) when
    /// it does not hold within `timeout`.
    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting until \(what)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static let daemonReports = [
        "AppIntentsLiveEntityService-2026-09-25-134035",
        "SettingsSearchReindexService-2026-09-25-134124",
        "intelligencetasksd-2026-09-25-134451",
        "intelligencetasksd-2026-09-25-134459",
        "intelligencetasksd-2026-09-25-134509",
    ]

    func testShowListsTheSimulatorsRowsNewestFirst() async throws {
        let (controller, _, _) = try makeController(
            reports: Self.daemonReports + ["AQACrash-2026-09-26-204000", "AQAHostCrash-2026-09-26-204328"]
        )
        controller.show(udid: Self.daemonSimulator)
        await waitUntil("the folder was read") { controller.hasLoaded }

        let rows = controller.rows(followed: nil)
        XCTAssertEqual(rows.map(\.newest.process), ["intelligencetasksd", "SettingsSearchReindexService", "AppIntentsLiveEntityService"])
        XCTAssertEqual(rows.map(\.count), [3, 1, 1])
        XCTAssertEqual(controller.reports.count, 5, "only this simulator's reports")
        XCTAssertTrue(controller.isWatching)
    }

    func testMyAppOnlyNeedsAFollowedApp() async throws {
        let (controller, _, _) = try makeController(
            reports: ["AQACrash-2026-09-26-204000", "AQACrash-2026-09-26-204237"]
        )
        controller.show(udid: Self.appSimulator)
        await waitUntil("the folder was read") { controller.hasLoaded }
        let other = SimulatorCrashReportList.App(bundleIdentifier: "com.example.other", process: "Other")

        XCTAssertEqual(controller.rows(followed: other).count, 2, "off: every report")
        controller.myAppOnly = true
        XCTAssertEqual(controller.rows(followed: other).count, 0)
        XCTAssertEqual(controller.rows(followed: nil).count, 2, "no app followed: every report")
        let crash = SimulatorCrashReportList.App(bundleIdentifier: "dev.devicehubpro.fixture.crash", process: "AQACrash")
        XCTAssertEqual(controller.rows(followed: crash).count, 2)

        // Another simulator starts with the filter off.
        controller.show(udid: Self.daemonSimulator)
        XCTAssertFalse(controller.myAppOnly)
    }

    /// A report written while the list shows reads again; the folder is
    /// never changed by the controller.
    func testNewReportAppears() async throws {
        let (controller, _, reports) = try makeController(reports: ["intelligencetasksd-2026-09-25-134451"])
        controller.show(udid: Self.daemonSimulator)
        await waitUntil("the folder was read") { controller.hasLoaded }
        XCTAssertEqual(controller.rows(followed: nil).map(\.count), [1])

        try FileManager.default.copyItem(
            at: fixture("intelligencetasksd-2026-09-25-134459"),
            to: reports.appendingPathComponent("intelligencetasksd-2026-09-25-134459.ips")
        )
        await waitUntil("the new report folded in") { controller.rows(followed: nil).first?.count == 2 }
        let names = try FileManager.default.contentsOfDirectory(atPath: reports.path).sorted()
        XCTAssertEqual(names, ["intelligencetasksd-2026-09-25-134451.ips", "intelligencetasksd-2026-09-25-134459.ips"])
    }

    /// A report still being written (half of it on disk) is read once more
    /// shortly after, without any folder change: completing the file in
    /// place changes no folder entry.
    func testReportStillBeingWrittenIsReadAgain() async throws {
        let (controller, _, reports) = try makeController(reports: [])
        let file = reports.appendingPathComponent("Preferences.ips")
        let whole = try Data(contentsOf: fixture("Preferences-2026-09-27-235405"))
        try whole.prefix(whole.count / 2).write(to: file)
        controller.followUpDelay = .milliseconds(500)
        controller.show(udid: Self.settingsSimulator)
        await waitUntil("the folder was read") { controller.hasLoaded }
        XCTAssertTrue(controller.reports.isEmpty)

        // Rewrite the same file in place (no new folder entry).
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: whole)
        try handle.close()
        await waitUntil("the completed report was read") { controller.reports.count == 1 }
    }

    /// A missing reports folder is waited for through its parent: when it
    /// appears the list follows it with no manual reload.
    func testAMissingFolderIsAwaitedThroughItsParent() async throws {
        let (controller, _, reports) = try makeController(reports: [], folderExists: false)
        controller.show(udid: Self.daemonSimulator)
        await waitUntil("the folder was read") { controller.hasLoaded }
        XCTAssertTrue(controller.isWatchingParent)

        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        await waitUntil("the folder is followed") { controller.isWatching }
        XCTAssertFalse(controller.isWatchingParent)
    }

    /// A reports folder that appears after the list opened is followed from
    /// the next read on.
    func testFolderCreatedLaterIsWatched() async throws {
        let (controller, _, reports) = try makeController(reports: [], folderExists: false)
        controller.show(udid: Self.daemonSimulator)
        await waitUntil("the folder was read") { controller.hasLoaded }
        XCTAssertFalse(controller.isWatching)

        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        await controller.reload()
        XCTAssertTrue(controller.isWatching)
        try FileManager.default.copyItem(
            at: fixture("intelligencetasksd-2026-09-25-134451"),
            to: reports.appendingPathComponent("intelligencetasksd.ips")
        )
        await waitUntil("the report was read through the watch") { controller.reports.count == 1 }
    }

    func testActions() async throws {
        let (controller, pasteboard, reports) = try makeController(reports: Self.daemonReports)
        var opened: [URL] = []
        var revealed: [URL] = []
        controller.openInConsole = { opened = $0 }
        controller.revealInFinder = { revealed = $0 }
        controller.show(udid: Self.daemonSimulator)
        await waitUntil("the folder was read") { controller.hasLoaded }
        let loop = try XCTUnwrap(controller.rows(followed: nil).first)

        controller.open(loop)
        XCTAssertEqual(opened.map(\.lastPathComponent), ["intelligencetasksd-2026-09-25-134509.ips"], "the newest")
        controller.reveal(loop)
        XCTAssertEqual(revealed.map(\.lastPathComponent), [
            "intelligencetasksd-2026-09-25-134509.ips",
            "intelligencetasksd-2026-09-25-134459.ips",
            "intelligencetasksd-2026-09-25-134451.ips",
        ])
        let copied = await controller.copy(loop)
        XCTAssertTrue(copied)
        XCTAssertEqual(
            pasteboard.text,
            try String(contentsOf: reports.appendingPathComponent("intelligencetasksd-2026-09-25-134509.ips"), encoding: .utf8)
        )
    }

    /// Only the last `show`'s token ends the list: a section that
    /// disappears after its successor appeared leaves the successor's list
    /// and watch alone.
    func testHideTokenOwnership() async throws {
        let (controller, _, _) = try makeController(reports: Self.daemonReports)
        let first = controller.show(udid: Self.daemonSimulator)
        await waitUntil("the folder was read") { controller.hasLoaded }
        let second = controller.show(udid: Self.daemonSimulator)
        controller.hide(token: first)
        XCTAssertEqual(controller.udid, Self.daemonSimulator)
        XCTAssertTrue(controller.hasLoaded)
        XCTAssertTrue(controller.isWatching)

        controller.hide(token: second)
        XCTAssertNil(controller.udid)
        XCTAssertFalse(controller.isWatching)
    }

    func testHideClearsAndWithoutFolderNothingIsRead() async throws {
        let (controller, _, _) = try makeController(reports: Self.daemonReports, readsReports: false)
        XCTAssertNil(controller.folder)
        controller.show(udid: Self.daemonSimulator)
        await waitUntil("the empty read finished") { controller.hasLoaded }
        XCTAssertTrue(controller.reports.isEmpty)

        controller.hide()
        XCTAssertNil(controller.udid)
        XCTAssertFalse(controller.hasLoaded)
        XCTAssertTrue(controller.rows(followed: nil).isEmpty)
        // A read that finishes after the hide leaves the list empty.
        await controller.reload()
        XCTAssertFalse(controller.hasLoaded)
    }

    /// The testing environment reads no reports folder.
    func testTestingModelReadsNoReports() {
        let model = AppModel(environment: .testing())
        XCTAssertNil(model.simulators.diagnosticReportsDirectory)
    }
}
