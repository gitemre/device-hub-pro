import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The Diagnostics section of an enabled physical device: the
/// reports of the 417-entry `systemCrashLogs` capture, newest first, split by
/// the Reports pop-up's kind (Crashes / Spins / Logs / Diagnostics) and the
/// Filter field, and Open / Show in Finder / Save to… through `device copy
/// from`. Nothing is ever deleted on the device.
@MainActor
final class PhysicalCrashLogsControllerTests: XCTestCase {
    private static let udid = PhysicalFixtures.udid

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private func captureFiles() throws -> [DevicectlDeviceFile] {
        try DevicectlJSON.decode(
            DevicectlFileList.self, from: try PhysicalFixtures.data("devicectl-info-files-crashlogs.json")
        ).value.files
    }

    private struct Harness {
        let stub: StubTool
        let controller: PhysicalCrashLogsController
        let status: StatusCenter
        let picker: TestPicker
        let temporary: URL
    }

    private func harness(enabled: Bool = true) async throws -> Harness {
        let stub = try makePhysicalStub(extra: """
          *"device info files"*"systemCrashLogs"*) \(PhysicalFixtures.json("devicectl-info-files-crashlogs.json")) ;;
          *"device copy from"*) \(PhysicalFixtures.capture("devicectl-copy-from-readings.json")) ;;
        """)
        let inventory = try await makeListedPhysicalInventory(stub: stub, enabled: enabled)
        let status = StatusCenter()
        let picker = TestPicker()
        let temporary = try makeTemporaryFolder("crash")
        let controller = PhysicalCrashLogsController(
            inventory: inventory,
            status: status,
            picker: picker,
            temporaryDirectory: temporary
        )
        return Harness(stub: stub, controller: controller, status: status, picker: picker, temporary: temporary)
    }

    // MARK: - The listing

    /// Of the 417 entries only the `.ips` files are reports: directories,
    /// `.ips.synced`, `.ips.ca.synced` and the plist are hidden. Newest
    /// first.
    func testTheCaptureListsOnlyIPSReportsNewestFirst() throws {
        let files = try captureFiles()
        XCTAssertEqual(files.count, 417)

        let logs = PhysicalCrashLogList.logs(from: files, calendar: utc)

        XCTAssertEqual(logs.count, 309)
        XCTAssertEqual(logs.count, files.filter { !$0.isDirectory && $0.relativePath.hasSuffix(".ips") }.count)
        XCTAssertTrue(logs.allSatisfy { $0.relativePath.hasSuffix(".ips") })
        XCTAssertFalse(logs.contains { $0.relativePath.hasSuffix(".synced") || $0.relativePath.hasSuffix(".plist") })
        let times = logs.compactMap(\.when)
        XCTAssertEqual(times.count, logs.count, "every name of the capture carries its date")
        XCTAssertEqual(times, times.sorted(by: >), "newest first")
        let first = try XCTUnwrap(logs.first)
        XCTAssertEqual(first.relativePath, "JetsamEvent-2026-09-29-004706.ips")
        XCTAssertEqual(first.process, "JetsamEvent")
        XCTAssertEqual(first.date, utc.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 0, minute: 47, second: 6)))
        XCTAssertNil(first.folder)
        XCTAssertEqual(first.size, 275010)
        XCTAssertEqual(logs.filter { $0.process == "JetsamEvent" }.count, 20)
        XCTAssertEqual(logs.filter { $0.process == "WiFiLQMMetrics" }.count, 177)
        XCTAssertEqual(logs.first { $0.relativePath.hasPrefix("Retired/") }?.folder, "Retired")
    }

    func testParsingFileNames() {
        let jetsam = PhysicalCrashLogList.parse(fileName: "JetsamEvent-2026-09-29-004706.ips", calendar: utc)
        XCTAssertEqual(jetsam.process, "JetsamEvent")
        XCTAssertNotNil(jetsam.date)
        // A report split in parts: ".0002" is not part of the time.
        let part = PhysicalCrashLogList.parse(fileName: "SFA-local.json-2026-09-23-203515.0002.ips", calendar: utc)
        XCTAssertEqual(part.process, "SFA-local.json")
        XCTAssertEqual(part.date, utc.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 20, minute: 35, second: 15)))
        let dotted = PhysicalCrashLogList.parse(fileName: "DiagnosticRequest_com.apple.autobugcapture_Performance-2026-09-24-150022.ips", calendar: utc)
        XCTAssertEqual(dotted.process, "DiagnosticRequest_com.apple.autobugcapture_Performance")
        // No date, or one that is not a date: the whole stem is the process.
        XCTAssertEqual(PhysicalCrashLogList.parse(fileName: "plain.ips", calendar: utc).process, "plain")
        XCTAssertNil(PhysicalCrashLogList.parse(fileName: "plain.ips", calendar: utc).date)
        let bad = PhysicalCrashLogList.parse(fileName: "MyApp-2026-13-45-999999.ips", calendar: utc)
        XCTAssertEqual(bad.process, "MyApp-2026-13-45-999999")
        XCTAssertNil(bad.date)
        XCTAssertEqual(PhysicalCrashLogList.parse(fileName: "MyApp.2-2026-09-29-004706.ips", calendar: utc).process, "MyApp.2")
    }

    /// The pop-up's four kinds, by extension and place: Device Hub listed every
    /// system `.ips` of the test iPhone under Logs and nothing under the others. The
    /// `.synced` copies and other files are not reports.
    func testKindsFollowTheExtension() {
        XCTAssertEqual(PhysicalReportKind.allCases.map(\.label), ["Crashes", "Spins", "Logs", "Diagnostics"])
        XCTAssertEqual(PhysicalReportKind.kind(ofFileName: "JetsamEvent-2026-09-29-004706.ips"), .logs)
        XCTAssertEqual(PhysicalReportKind.kind(ofFileName: "MyApp-2026-09-29-004706.crash"), .crashes)
        XCTAssertEqual(PhysicalReportKind.kind(ofFileName: "MyApp_2026-09-29-004706.spin"), .spins)
        XCTAssertEqual(PhysicalReportKind.kind(ofFileName: "MyApp_2026-09-29-004706.hang"), .spins)
        XCTAssertEqual(PhysicalReportKind.kind(ofFileName: "MyApp_2026-09-29-004706.diag"), .diagnostics)
        XCTAssertNil(PhysicalReportKind.kind(ofFileName: "JetsamEvent-2026-09-23-012104.ips.synced"))
        XCTAssertNil(PhysicalReportKind.kind(ofFileName: "Analytics-2026-09-22-030805.ips.ca.synced"))
        XCTAssertNil(PhysicalReportKind.kind(ofFileName: "spotlight_heartbeat_last.plist"))
        XCTAssertEqual(
            PhysicalReportKind.allCases.map(\.emptyText),
            ["No Crash Reports", "No Spin Reports", "No Log Reports", "No Diagnostic Reports"]
        )
    }

    /// The Crashes / Logs split of the one listing: an app's `<Process>-<date>.ips` at the
    /// top is a crash; the system's own reports (`JetsamEvent`, stacks, radio metrics,
    /// resource reports, everything under `Retired/` or `DiagnosticLogs/`) are logs. The
    /// 417-entry capture has no app crash (Device Hub showed "No Crash Reports" for it), so
    /// it splits as 0 crashes / 309 logs; the crash names below are SOURCE-DERIVED from the
    /// listing's own `<Process>-<yyyy-MM-dd-HHmmss>.ips` naming, not a capture.
    func testCrashesAreTheTopLevelAppReportsAndTheRestIsLogs() throws {
        let logs = PhysicalCrashLogList.logs(from: try captureFiles(), calendar: utc)
        XCTAssertEqual(logs.filter { $0.kind == .crashes }.count, 0)
        XCTAssertEqual(logs.filter { $0.kind == .logs }.count, 309)
        XCTAssertEqual(logs.first { $0.relativePath == "JetsamEvent-2026-09-29-004706.ips" }?.kind, .logs)

        let kind = PhysicalReportKind.kind(ofRelativePath:)
        XCTAssertEqual(kind("MyApp-2026-09-29-101010.ips"), .crashes)
        XCTAssertEqual(kind("My.App.2-2026-09-29-101010.0002.ips"), .crashes)
        XCTAssertEqual(kind("Retired/MyApp-2026-09-29-101010.ips"), .logs)
        XCTAssertEqual(kind("DiagnosticLogs/MyApp-2026-09-29-101010.ips"), .logs)
        for process in ["JetsamEvent", "ExcResource", "stacks", "WiFiLQMMetrics", "SFA-local.json", "Analytics",
                        "DiagnosticRequest_com.apple.autobugcapture_Performance", "cfprefsd.diskwrites_resource",
                        "contactsd.cpu_resource", "SiriSearchFeedback"] {
            XCTAssertEqual(kind("\(process)-2026-09-29-101010.ips"), .logs, process)
        }
        XCTAssertNil(kind("MyApp-2026-09-29-101010.ips.synced"))
        XCTAssertNil(kind("Retired"))
    }

    /// A real crash added to the capture's listing lands under Crashes and the controller's
    /// kind filter shows it there only.
    func testACrashInTheListingShowsUnderCrashesOnly() throws {
        var files = try captureFiles()
        let extra = try JSONDecoder().decode([DevicectlDeviceFile].self, from: Data(#"""
        [{"name":"MyApp-2026-09-29-101010.ips","relativePath":"MyApp-2026-09-29-101010.ips","metadata":{"size":9},"resources":{"isDirectory":false}}]
        """#.utf8))
        files.append(contentsOf: extra)
        let logs = PhysicalCrashLogList.logs(from: files, calendar: utc)
        XCTAssertEqual(logs.filter { $0.kind == .crashes }.map(\.process), ["MyApp"])
        XCTAssertEqual(logs.filter { $0.kind == .logs }.count, 309)
    }

    /// Other report extensions parse like `.ips`: the extension is not part
    /// of the process name.
    func testOtherExtensionsParse() throws {
        let json = #"""
        [{"name":"MyApp-2026-09-29-004706.crash","relativePath":"MyApp-2026-09-29-004706.crash","metadata":{"size":5},"resources":{"isDirectory":false}},
         {"name":"MyApp_x.hang","relativePath":"MyApp_x.hang","resources":{"isDirectory":false}},
         {"name":"a.txt","relativePath":"a.txt","resources":{"isDirectory":false}}]
        """#
        let files = try JSONDecoder().decode([DevicectlDeviceFile].self, from: Data(json.utf8))
        let logs = PhysicalCrashLogList.logs(from: files, calendar: utc)
        XCTAssertEqual(logs.map(\.kind), [.crashes, .spins])
        XCTAssertEqual(logs.first?.process, "MyApp")
        XCTAssertEqual(logs.last?.process, "MyApp_x")
    }

    /// The row shows the file's modification time, else the name's date.
    func testTheShownDatePrefersTheModificationTime() {
        let named = utc.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 0, minute: 47, second: 6))
        let modified = utc.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 0, minute: 47, second: 7))
        XCTAssertEqual(PhysicalCrashLog(relativePath: "a.ips", process: "a", date: named, size: nil, modified: modified).shownDate, modified)
        XCTAssertEqual(PhysicalCrashLog(relativePath: "a.ips", process: "a", date: named, size: nil, modified: nil).shownDate, named)
    }

    /// A name without a date falls back to the file's modification time.
    func testAnUndatedNameSortsByItsModificationTime() throws {
        let json = #"""
        [{"name":"a.ips","relativePath":"a.ips","metadata":{"lastModDate":"2026-09-01T10:00:00.000Z","size":1},"resources":{"isDirectory":false}},
         {"name":"b.ips","relativePath":"b.ips","metadata":{"lastModDate":"2026-09-02T10:00:00.000Z","size":2},"resources":{"isDirectory":false}},
         {"name":"c-2026-09-01-120000.ips","relativePath":"c-2026-09-01-120000.ips","metadata":{"size":3},"resources":{"isDirectory":false}},
         {"name":"d.ips","relativePath":"d.ips","resources":{"isDirectory":false}}]
        """#
        let files = try JSONDecoder().decode([DevicectlDeviceFile].self, from: Data(json.utf8))
        let logs = PhysicalCrashLogList.logs(from: files, calendar: utc)
        XCTAssertEqual(logs.map(\.relativePath), ["b.ips", "c-2026-09-01-120000.ips", "a.ips", "d.ips"])
    }

    // MARK: - The controller

    private func loaded() async throws -> Harness {
        let h = try await harness()
        h.controller.show(udid: Self.udid)
        let done = await physicalWait { h.controller.hasLoaded && !h.controller.isLoading }
        XCTAssertTrue(done)
        return h
    }

    /// Showing the section lists `systemCrashLogs` on the enabled device
    /// (one call); the pop-up's kind and the Filter field narrow the rows.
    func testTheControllerListsAndFilters() async throws {
        let h = try await loaded()

        XCTAssertEqual(h.controller.logs.count, 309)
        XCTAssertNil(h.controller.problem)
        let calls = h.stub.deviceCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(
            calls[0].contains("device info files --device \(PhysicalFixtures.coreDeviceIdentifier)"),
            calls[0]
        )
        XCTAssertTrue(calls[0].contains("--domain-type systemCrashLogs"), calls[0])

        // Device Hub opens on Crashes; every report of the capture is a `.ips`,
        // so it is a Log.
        XCTAssertEqual(h.controller.kind, .crashes)
        XCTAssertEqual(h.controller.rows, [])
        XCTAssertFalse(h.controller.hasReportsOfKind)
        for kind in [PhysicalReportKind.spins, .diagnostics] {
            h.controller.kind = kind
            XCTAssertEqual(h.controller.rows, [], kind.label)
        }
        h.controller.kind = .logs
        XCTAssertEqual(h.controller.rows.count, 309)
        XCTAssertTrue(h.controller.hasReportsOfKind)

        h.controller.filter = "jetsam"
        XCTAssertEqual(h.controller.rows.count, 20, "the filter matches the file name, case-insensitively")
        h.controller.filter = "no such report"
        XCTAssertEqual(h.controller.rows, [])
        XCTAssertTrue(h.controller.hasReportsOfKind, "a filter that hides everything is not an empty kind")

        h.controller.hide()
        XCTAssertEqual(h.controller.logs, [])
        XCTAssertEqual(h.controller.filter, "")
    }

    /// "Open" and "Show in Finder" copy the report through `device copy from`
    /// into a folder of temporary files, asking nothing, then hand the copy on.
    func testOpenAndShowInFinderCopyWithoutAsking() async throws {
        let h = try await loaded()
        let log = try XCTUnwrap(h.controller.logs.first)
        var opened: [URL] = []
        var revealed: [URL] = []
        h.controller.openFile = { opened.append($0) }
        h.controller.revealInFinder = { revealed.append($0) }

        await h.controller.open(log)
        await h.controller.reveal(log)

        let expected = h.temporary.appendingPathComponent("Device Hub Pro Physical Reports").appendingPathComponent(log.fileName)
        XCTAssertEqual(opened, [expected])
        XCTAssertEqual(revealed, [expected])
        XCTAssertEqual(h.picker.suggestedNames, [], "the user is not asked where")
        XCTAssertNil(h.controller.savingPath)
        let copies = h.stub.deviceCalls.filter { $0.contains("device copy from") }
        XCTAssertEqual(copies.count, 2)
        for call in copies {
            XCTAssertTrue(call.contains("--domain-type systemCrashLogs"), call)
            XCTAssertTrue(call.contains("--source \(log.relativePath)"), call)
            XCTAssertTrue(call.contains("--destination \(expected.path)"), call)
        }
    }

    /// "Save to…" copies the report through `device copy from` with the
    /// domain and the path inside it, to a temporary file that is then moved
    /// where the user chose; "and Show in Finder" reveals it. Cancelling
    /// copies nothing.
    func testSavingAReport() async throws {
        let h = try await loaded()
        let log = try XCTUnwrap(h.controller.logs.first { $0.relativePath.hasPrefix("Retired/JetsamEvent-") })
        var revealed: [URL] = []
        h.controller.revealInFinder = { revealed.append($0) }

        let cancelled = await h.controller.save(log)
        XCTAssertNil(cancelled)
        XCTAssertEqual(h.picker.suggestedNames, [log.fileName])
        XCTAssertFalse(h.stub.deviceCalls.contains { $0.contains("device copy from") })

        let destination = try makeTemporaryFolder("saved").appendingPathComponent(log.fileName)
        h.picker.destination = destination
        let saved = await h.controller.save(log, revealAfter: true)

        XCTAssertEqual(saved, destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("captured".utf8))
        XCTAssertEqual(revealed, [destination])
        XCTAssertEqual(h.status.statusMessage, "Saved \(log.fileName)")
        XCTAssertNil(h.controller.savingPath)
        let call = try XCTUnwrap(h.stub.deviceCalls.first { $0.contains("device copy from") })
        XCTAssertTrue(call.contains("device copy from --device \(PhysicalFixtures.coreDeviceIdentifier)"), call)
        XCTAssertTrue(call.contains("--domain-type systemCrashLogs"), call)
        XCTAssertFalse(call.contains("--domain-identifier"), call)
        XCTAssertTrue(call.contains("--source \(log.relativePath)"), call)
        XCTAssertTrue(call.contains("--destination \(h.temporary.path)/devicehubpro-physical-copy-"), call)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: h.temporary.path), [])

        // Save without the Finder.
        let plain = await h.controller.save(log)
        XCTAssertEqual(plain, destination)
        XCTAssertEqual(revealed.count, 1)
    }

    /// Nothing on the device is ever deleted, moved or changed: a whole
    /// session (list, copy) runs only `device info files` and `device copy
    /// from`.
    func testNothingIsEverDeleted() async throws {
        let h = try await loaded()
        let log = try XCTUnwrap(h.controller.logs.first)
        h.picker.destination = try makeTemporaryFolder("saved").appendingPathComponent("x.ips")
        _ = await h.controller.save(log)
        await h.controller.reload()

        XCTAssertFalse(h.stub.deviceCalls.isEmpty)
        for call in h.stub.deviceCalls {
            XCTAssertTrue(call.hasPrefix("device info files") || call.hasPrefix("device copy from"), call)
            for word in ["uninstall", "copy to", "delete", "remove", "reset", "sysdiagnose", "settings"] {
                XCTAssertFalse(call.contains(word), "\(word) in \(call)")
            }
        }
    }

    /// A failed listing says why and leaves no list.
    func testFailures() async throws {
        let stub = try makePhysicalStub(extra: """
          *"device info files"*) exit 1 ;;
        """)
        let inventory = try await makeListedPhysicalInventory(stub: stub)
        let status = StatusCenter()
        let controller = PhysicalCrashLogsController(inventory: inventory, status: status, picker: TestPicker())
        controller.show(udid: Self.udid)
        let done = await physicalWait { controller.hasLoaded && !controller.isLoading }
        XCTAssertTrue(done)
        XCTAssertEqual(controller.logs, [])
        XCTAssertTrue(controller.problem?.hasPrefix("Could not list the crash logs:") == true, controller.problem ?? "")
    }

    /// A device that is not enabled shows its state's hint and no command
    /// reaches it.
    func testANonEnabledDeviceGetsNoCall() async throws {
        let h = try await harness(enabled: false)

        h.controller.show(udid: Self.udid)
        let done = await physicalWait { h.controller.hasLoaded }
        XCTAssertTrue(done)
        let log = PhysicalCrashLog(relativePath: "a-2026-09-29-004706.ips", process: "a", date: nil, size: nil, modified: nil)
        h.picker.destination = try makeTemporaryFolder("saved").appendingPathComponent("a.ips")
        let saved = await h.controller.save(log)

        XCTAssertNil(saved)
        XCTAssertEqual(h.stub.deviceCalls, [])
        XCTAssertEqual(h.controller.problem, "Choose Use This Device to let Device Hub Pro read and manage it.")
        XCTAssertEqual(h.controller.logs, [])
        XCTAssertEqual(h.picker.suggestedNames, [], "the user is not even asked")
    }

    /// Only the last `show`'s token ends the list, so a section that
    /// disappears after its successor appeared does not end the successor's.
    func testOnlyTheLastSectionEndsTheList() async throws {
        let h = try await loaded()
        let first = h.controller.show(udid: Self.udid)
        let second = h.controller.show(udid: Self.udid)
        h.controller.hide(token: first)
        XCTAssertNotNil(h.controller.udid)
        h.controller.hide(token: second)
        XCTAssertNil(h.controller.udid)
    }
}
