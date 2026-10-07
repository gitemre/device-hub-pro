import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// Apply to Selected and Screenshot All Selected over stand-in device work:
/// what runs where, what is reported, one batch at a time, and Cancel.
@MainActor
final class MultiDeviceControllerTests: XCTestCase {
    /// What the stand-in device work was asked to do.
    @MainActor
    private final class Journal {
        var runs: [String] = []
        var operations: [String: BatchOperation] = [:]
        var contexts: [String: BatchRunContext] = [:]
    }

    private struct Boom: Error, CustomStringConvertible {
        var description: String { "adb: device offline" }
    }

    private func target(
        _ id: String,
        name: String? = nil,
        platform: DevicePlatform = .android,
        readiness: BatchReadiness = .ready
    ) -> BatchTarget {
        BatchTarget(
            id: id,
            platform: platform,
            kind: platform == .android ? .emulator : .simulator,
            ref: platform == .android ? .android("emulator-5554") : .apple("95D9676B-3317-4BA5-8CF6-3CDD0488CACA"),
            name: name ?? id,
            osName: platform == .android ? "Android" : "iOS",
            osVersion: nil,
            readiness: readiness
        )
    }

    private func controller(
        status: StatusCenter = StatusCenter(),
        picker: TestPicker = TestPicker(),
        journal: Journal,
        failing: Set<String> = [],
        skipping: Set<String> = []
    ) -> MultiDeviceController {
        MultiDeviceController(status: status, picker: picker) { target, operation, context in
            journal.runs.append(target.id)
            journal.operations[target.id] = operation
            journal.contexts[target.id] = context
            if failing.contains(target.id) { throw Boom() }
            if skipping.contains(target.id) { throw BatchSkip("Needs an iOS simulator") }
        }
    }

    /// Waits (at most 5 s) until `condition` holds.
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testEveryReadyDeviceRunsItsOwnOperationAndTheOthersAreSkipped() async throws {
        let status = StatusCenter()
        let journal = Journal()
        let multi = controller(status: status, journal: journal)
        let report = await multi.run(
            .textSize(.large),
            on: [target("A", name: "Pixel 9"), target("S", name: "iPhone 17", platform: .apple), target("B", name: "Pixel 8", readiness: .stopped)]
        )
        XCTAssertEqual(Set(journal.runs), ["A", "S"])
        XCTAssertEqual(journal.operations["A"], .androidTextSize(.large))
        XCTAssertEqual(journal.operations["S"], .simulatorTextSize(.extraLarge))
        let unwrapped = try XCTUnwrap(report)
        XCTAssertEqual(unwrapped.succeeded, ["Pixel 9", "iPhone 17"])
        XCTAssertEqual(unwrapped.skipped, [BatchReport.Entry(name: "Pixel 8", message: "Not running")])
        XCTAssertEqual(status.errorMessage, "Text Size Large: Done on 2 of 3 devices · 1 skipped\n\nSkipped 1 device:\nPixel 8: Not running")
        XCTAssertEqual(multi.lastReport, unwrapped)
        XCTAssertNotNil(multi.lastElapsed)
        XCTAssertFalse(multi.isRunning)
        XCTAssertEqual(multi.rowStates, [:])
    }

    func testFailuresAreReportedTogetherInOneAlert() async {
        let status = StatusCenter()
        let journal = Journal()
        let multi = controller(status: status, journal: journal, failing: ["A"], skipping: ["S"])
        await multi.run(.appearance(dark: true), on: [target("A", name: "Pixel 9"), target("B", name: "Pixel 8"), target("S", name: "Apple TV", platform: .apple)])
        XCTAssertEqual(
            status.errorMessage,
            "Dark Appearance: Done on 1 of 3 devices · 1 failed · 1 skipped\n\nFailed on 1 device:\nPixel 9: adb: device offline\n\nSkipped 1 device:\nApple TV: Needs an iOS simulator"
        )
        XCTAssertEqual(multi.lastReport?.skipped, [BatchReport.Entry(name: "Apple TV", message: "Needs an iOS simulator")])
    }

    func testSkippedDevicesGetAnAlertNamingEachWithItsReason() async {
        let status = StatusCenter()
        let multi = controller(status: status, journal: Journal())
        await multi.run(.appearance(dark: true), on: [target("A", name: "Pixel 9"), target("B", name: "Pixel 8", readiness: .stopped)])
        let text = status.errorMessage ?? ""
        XCTAssertTrue(text.contains("Skipped 1 device:\nPixel 8: Not running"), text)
    }

    func testRowsBatchActionsDoNotReachAreCountedAndNamed() async throws {
        let status = StatusCenter()
        let multi = controller(status: status, journal: Journal())
        let ran = await multi.run(.appearance(dark: true), on: [target("A", name: "Pixel 9")], excluded: ["Pixel 10 Pro"])
        let report = try XCTUnwrap(ran)
        XCTAssertEqual(report.skipped.map(\.name), ["Pixel 10 Pro"])
        XCTAssertEqual(report.total, 2)
        XCTAssertTrue(status.errorMessage?.contains("Pixel 10 Pro: \(MultiDeviceController.excludedReason)") == true)
        // Nothing usable at all: a message, no batch.
        let none = StatusCenter()
        let other = controller(status: none, journal: Journal())
        let result = await other.run(.appearance(dark: true), on: [], excluded: ["X", "Y"])
        XCTAssertNil(result)
        XCTAssertEqual(none.errorMessage, "None of the 2 selected rows can take batch actions: X, Y")
    }

    func testTheExcludedLineCountsAndNamesTheRows() {
        XCTAssertEqual(MultiDeviceController.excludedLine(["A", "B"]), "2 of the selected rows can\u{2019}t take batch actions: A, B")
        XCTAssertEqual(MultiDeviceController.excludedLine(["A"], all: true), "The selected row can\u{2019}t take batch actions: A")
        XCTAssertEqual(MultiDeviceController.excludedLine(["A", "B", "C"], all: true), "None of the 3 selected rows can take batch actions: A, B, C")
    }

    func testScreenshotAllCountsExcludedRowsAsSkipped() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiDeviceControllerTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let status = StatusCenter()
        let multi = controller(status: status, journal: Journal())
        multi.captureFolder = { parent }

        let ran = await multi.screenshotAll([target("A", name: "Pixel 9")], excluded: ["Pixel 10 Pro", "iPhone"])
        let report = try XCTUnwrap(ran)

        XCTAssertEqual(report.skipped.map(\.name), ["Pixel 10 Pro", "iPhone"])
        XCTAssertEqual(report.skipped.map(\.message), Array(repeating: MultiDeviceController.excludedReason, count: 2))
        XCTAssertEqual(report.succeeded.count, 1)
        XCTAssertEqual(report.total, 3)

        // Only excluded rows: a message, no folder.
        let none = StatusCenter()
        let other = controller(status: none, journal: Journal())
        let result = await other.screenshotAll([], excluded: ["X"])
        XCTAssertNil(result)
        XCTAssertEqual(none.errorMessage, "The selected row can\u{2019}t take batch actions: X")
    }

    func testDuplicateNamesAreToldApartInTheReport() {
        var a = target("device:emulator-5554", name: "Pixel 9")
        var b = target("device:emulator-5556", name: "Pixel 9")
        let plain = MultiDeviceController.displayNames(for: [a, b])
        XCTAssertEqual(plain["device:emulator-5554"], "Pixel 9 (5554)")
        XCTAssertEqual(plain["device:emulator-5556"], "Pixel 9 (5556)")
        a = BatchTarget(id: a.id, platform: .android, kind: .emulator, ref: a.ref, name: "Pixel 9", osName: "Android", osVersion: "15", readiness: .ready)
        b = BatchTarget(id: b.id, platform: .android, kind: .emulator, ref: b.ref, name: "Pixel 9", osName: "Android", osVersion: "14", readiness: .ready)
        let versions = MultiDeviceController.displayNames(for: [a, b])
        XCTAssertEqual(versions[a.id], "Pixel 9 (Android 15)")
        XCTAssertEqual(versions[b.id], "Pixel 9 (Android 14)")
        let unique = MultiDeviceController.displayNames(for: [target("x", name: "One"), target("y", name: "Two")])
        XCTAssertEqual(unique["x"], "One")
    }

    func testAlertTextIsNilWhenEveryDeviceTookIt() {
        XCTAssertNil(MultiDeviceController.alertText(title: "T", report: BatchReport(succeeded: ["A"])))
        let cancelled = MultiDeviceController.alertText(title: "T", report: BatchReport(succeeded: ["A"], cancelled: ["B"]))
        XCTAssertEqual(cancelled, "T: Done on 1 of 2 devices · 1 cancelled\n\nCancelled before it finished:\nB")
    }

    func testARowSelectedTwiceRunsOnce() async {
        let journal = Journal()
        let multi = controller(journal: journal)
        let report = await multi.run(.screenshot, on: [target("A"), target("A"), target("B")])
        XCTAssertEqual(journal.runs.sorted(), ["A", "B"])
        XCTAssertEqual(report?.total, 2)
    }

    func testNothingSelectedRunsNothing() async {
        let journal = Journal()
        let multi = controller(journal: journal)
        let report = await multi.run(.screenshot, on: [])
        XCTAssertNil(report)
        XCTAssertEqual(journal.runs, [])
    }

    func testOneBatchAtATimeAndCancelEndsIt() async {
        let status = StatusCenter()
        let multi = MultiDeviceController(status: status, picker: TestPicker()) { _, _, _ in
            try await Task.sleep(for: .seconds(30))
        }
        let targets = [target("A"), target("B"), target("C", readiness: .offline)]
        let batch = Task { await multi.run(.appearance(dark: false), on: targets) }
        await waitUntil { multi.rowStates["A"] == .running && multi.rowStates["B"] == .running }
        XCTAssertTrue(multi.isRunning)
        XCTAssertEqual(multi.runningAction, .appearance(dark: false))
        // A skipped row is never shown working.
        XCTAssertNil(multi.rowStates["C"])
        XCTAssertEqual(status.statusMessage, "Light Appearance on 3 devices…")

        let second = await multi.run(.screenshot, on: [target("D")])
        XCTAssertNil(second, "a second batch waits for the first to end")

        multi.cancel()
        let report = await batch.value
        XCTAssertEqual(report?.cancelled, ["A", "B"])
        XCTAssertEqual(report?.skipped, [BatchReport.Entry(name: "C", message: "Offline")])
        XCTAssertEqual(report?.headline, "Done on 0 of 3 devices · 1 skipped · 2 cancelled")
        XCTAssertFalse(multi.isRunning)
        XCTAssertEqual(multi.rowStates, [:])
    }

    func testScreenshotAllSavesOneFileNamedAfterEachDeviceInANewFolder() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiDeviceControllerTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let picker = TestPicker()
        let journal = Journal()
        let multi = controller(picker: picker, journal: journal)
        multi.captureFolder = { parent }
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let folder = parent.appendingPathComponent(BatchScreenshotNaming.folderName(at: date), isDirectory: true)

        let report = await multi.screenshotAll(
            [target("S1", name: "iPhone 17 Pro", platform: .apple), target("S2", name: "iPhone 17 Pro", platform: .apple), target("A", name: "Pixel 9")],
            at: date
        )

        XCTAssertEqual(picker.suggestedNames, [], "saved without asking, like a single screenshot")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(journal.operations["A"], .screenshot)
        XCTAssertEqual(journal.contexts["S1"]?.screenshotDestinations["S1"]?.lastPathComponent, "iPhone 17 Pro.png")
        XCTAssertEqual(journal.contexts["S2"]?.screenshotDestinations["S2"]?.lastPathComponent, "iPhone 17 Pro 2.png")
        XCTAssertEqual(journal.contexts["A"]?.screenshotDestinations["A"], folder.appendingPathComponent("Pixel 9.png"))
        XCTAssertEqual(try XCTUnwrap(report).succeeded.count, 3)
    }

    /// With no capture folder and no default, it asks; a cancel does nothing.
    func testScreenshotAllDoesNothingWhenTheSavePanelIsCancelled() async {
        let journal = Journal()
        let multi = controller(journal: journal)
        let report = await multi.screenshotAll([target("A")])
        XCTAssertNil(report)
        XCTAssertEqual(journal.runs, [])
    }
}

/// Screenshot All Selected's folder and file names.
final class BatchScreenshotNamingTests: XCTestCase {
    private func target(_ id: String, _ name: String) -> BatchTarget {
        BatchTarget(id: id, platform: .apple, kind: .simulator, ref: nil, name: name, osName: "iOS", osVersion: nil, readiness: .ready)
    }

    func testTheFolderIsNamedLikeASingleScreenshot() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        // 2026-09-21 14:13:20 UTC.
        XCTAssertEqual(
            BatchScreenshotNaming.folderName(at: Date(timeIntervalSince1970: 1_790_000_000), timeZone: utc),
            "devicehubpro-screenshots-20260921-141320"
        )
    }

    func testFileNamesAreTheDevicesNamesMadeUnique() {
        let names = BatchScreenshotNaming.fileNames(for: [
            target("a", "iPhone 17 Pro"),
            target("b", "iPhone 17 Pro"),
            target("c", "IPHONE 17 PRO"),
            target("d", "Pixel 9/Fold: test"),
            target("e", ".hidden"),
            target("f", "   "),
        ])
        XCTAssertEqual(names["a"], "iPhone 17 Pro.png")
        XCTAssertEqual(names["b"], "iPhone 17 Pro 2.png")
        // Case-insensitive, as the Mac's disk is.
        XCTAssertEqual(names["c"], "IPHONE 17 PRO 3.png")
        XCTAssertEqual(names["d"], "Pixel 9-Fold- test.png")
        XCTAssertEqual(names["e"], "-hidden.png")
        XCTAssertEqual(names["f"], "Device.png")
    }
}
