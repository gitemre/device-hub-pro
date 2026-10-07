import XCTest
@testable import DeviceHubProKit

/// `SimulatorCrashReportParsing`, `SimulatorCrashReportList` and
/// `SimulatorCrashReportScanner` fed real crash reports.
///
/// `Fixtures/ios27-simulator/crash-reports/*.trimmed.ips` are `.ips` files
/// the crash reporter of macOS 27.0 (26A428) wrote to
/// `~/Library/Logs/DiagnosticReports` (Xcode 27.0, iOS 27.0 runtime 24A434,
/// tr_TR / Europe/Istanbul, so times carry +0300):
/// - `Preferences-2026-09-27-235405`: the Settings app of an iPhone 17 Pro
///   simulator created for the capture (3A391D73-…), launched with `simctl
///   launch` and sent SIGSEGV from the Mac (`kill -SEGV <pid>`).
/// - `AQACrash-2026-09-26-204000` and `-204237`: AQACrash, a crashing test
///   app installed in a test simulator (5F734077-…), a trap and an abort.
/// - `AppIntentsLiveEntityService-…`, `SettingsSearchReindexService-…` and
///   the nine `intelligencetasksd-2026-09-25-1344…`/`-1346…` reports: runtime
///   daemons of one freshly booted test simulator (D9F3A76F-…);
///   intelligencetasksd crashed about every 10 s.
/// - `AQAHostCrash-2026-09-26-204328`: a Mac command-line tool that aborted
///   (not a simulator's process).
/// Each file is trimmed to what the parser reads, keeping each kept line
/// byte-exact and in order: the header line, the body's opening brace, the
/// body's one-line `captureTime`, `pid`, `procName`, `procPath`,
/// `bundleInfo`, `parentProc`, `coalitionName`, `exception` and
/// `termination`, and the body's last member (`trialInfo`) to the end, so
/// the body stays valid JSON. Threads, images, the crash reporter key and
/// the vendor identifier are gone. The macOS user name appears in none of
/// them (the crash reporter writes `/Users/USER/…` itself). One placeholder:
/// `AQAHostCrash`'s `coalitionName` named the app the capture session ran
/// in and reads `com.example.hostcrash.launcher` (same length) instead.
final class SimulatorCrashReportTests: XCTestCase {
    static let folder = SimctlFixtureTests.root.appendingPathComponent("crash-reports", isDirectory: true)

    static let settingsSimulator = "3A391D73-FFB5-4792-8F37-47F1638EA5FC"
    static let appSimulator = "5F734077-046C-4806-9404-846115C40E1B"
    static let daemonSimulator = "D9F3A76F-51E7-4A91-B06E-11AC95157EE5"

    static func url(_ name: String) -> URL {
        folder.appendingPathComponent(name + ".trimmed.ips")
    }

    static func report(_ name: String) throws -> SimulatorCrashReport? {
        SimulatorCrashReportParsing.parse(try Data(contentsOf: url(name)), url: url(name))
    }

    static func allReports() throws -> [SimulatorCrashReport] {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "ips" }.compactMap {
            SimulatorCrashReportParsing.parse(try Data(contentsOf: $0), url: $0)
        }
    }

    // MARK: - Parsing

    /// The crash triggered for this test: a runtime app, attributed by
    /// `coalitionName` alone (its path is the runtime's, redacted).
    func testRuntimeAppCrash() throws {
        let report = try XCTUnwrap(Self.report("Preferences-2026-09-27-235405"))
        XCTAssertEqual(report.udid, Self.settingsSimulator)
        XCTAssertEqual(report.process, "Preferences")
        XCTAssertEqual(report.bundleIdentifier, "com.apple.Preferences")
        XCTAssertEqual(report.exceptionType, "EXC_CRASH")
        XCTAssertEqual(report.signal, "SIGSEGV")
        XCTAssertEqual(report.exceptionSummary, "EXC_CRASH (SIGSEGV)")
        XCTAssertFalse(report.isInstalledApp)
        XCTAssertEqual(report.incidentID, "7C2AAB0C-945A-4751-88C6-CE7A8DB54598")
        // captureTime, not the header's later timestamp (23:54:05).
        XCTAssertEqual(
            report.time.timeIntervalSince1970,
            try XCTUnwrap(Self.utc("2026-09-27T20:53:26Z")).timeIntervalSince1970 + 0.6915,
            accuracy: 0.0001
        )
    }

    func testInstalledAppCrash() throws {
        let report = try XCTUnwrap(Self.report("AQACrash-2026-09-26-204000"))
        XCTAssertEqual(report.udid, Self.appSimulator)
        XCTAssertEqual(report.process, "AQACrash")
        XCTAssertEqual(report.bundleIdentifier, "dev.devicehubpro.fixture.crash")
        XCTAssertEqual(report.exceptionSummary, "EXC_BREAKPOINT (SIGTRAP)")
        XCTAssertTrue(report.isInstalledApp)
    }

    func testDaemonCrashHasNoBundleIdentifier() throws {
        let report = try XCTUnwrap(Self.report("intelligencetasksd-2026-09-25-134451"))
        XCTAssertEqual(report.udid, Self.daemonSimulator)
        XCTAssertEqual(report.process, "intelligencetasksd")
        XCTAssertNil(report.bundleIdentifier)
        XCTAssertFalse(report.isInstalledApp)
    }

    func testMacProcessIsNotListed() throws {
        let url = Self.url("AQAHostCrash-2026-09-26-204328")
        XCTAssertEqual(SimulatorCrashReportParsing.outcome(try Data(contentsOf: url), url: url), .notSimulatorCrash)
    }

    /// A Mac process's report that mentions a simulator's folder without
    /// naming one (derived from the Settings capture: `coalitionName` and
    /// `procPath` replaced with a Mac app's and a path under
    /// `CoreSimulator/Devices/` that holds no UDID) passes the byte check and
    /// is still left out.
    func testMacReportMentioningSimulatorsIsNotListed() throws {
        let url = Self.url("Preferences-2026-09-27-235405")
        let lines = try XCTUnwrap(String(data: try Data(contentsOf: url), encoding: .utf8))
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                if line.hasPrefix("  \"coalitionName\"") { return #"  "coalitionName" : "com.apple.Terminal","# }
                if line.hasPrefix("  \"procPath\"") {
                    return #"  "procPath" : "\/Users\/USER\/Library\/Developer\/CoreSimulator\/Devices\/.cache\/tool","#
                }
                return String(line)
            }
        let data = Data(lines.joined(separator: "\n").utf8)
        XCTAssertNotNil(data.range(of: Data(SimulatorCrashReportParsing.escapedDevicesPathMarker.utf8)))
        XCTAssertEqual(SimulatorCrashReportParsing.outcome(data, url: url), .notSimulatorCrash)
    }

    /// An installed app's path names its simulator too: without
    /// `coalitionName` (derived from the AQACrash capture, the member
    /// removed here), the path attributes it.
    func testPathAttributesWithoutCoalition() throws {
        let text = try XCTUnwrap(String(data: try Data(contentsOf: Self.url("AQACrash-2026-09-26-204000")), encoding: .utf8))
        let stripped = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("  \"coalitionName\"") }
            .joined(separator: "\n")
        XCTAssertNotEqual(stripped, text)
        let report = try XCTUnwrap(SimulatorCrashReportParsing.parse(Data(stripped.utf8), url: Self.url("AQACrash-2026-09-26-204000")))
        XCTAssertEqual(report.udid, Self.appSimulator)
    }

    /// An app installed in a simulator of a private device set
    /// (`<set>/<UDID>/data/…`, no `CoreSimulator/Devices`) is an installed
    /// app too.
    func testInstalledAppInPrivateSet() {
        let udid = Self.appSimulator
        XCTAssertTrue(SimulatorCrashReportParsing.isInstalledApp(
            procPath: "/private/var/folders/x/T/devicehubpro-live-sims/\(udid)/data/Containers/Bundle/Application/16C095EA-14B6-4DCB-B448-2A99F7A7EC28/AQACrash.app/AQACrash",
            udid: udid
        ))
        XCTAssertFalse(SimulatorCrashReportParsing.isInstalledApp(procPath: "/Volumes/VOLUME/*/Preferences.app/Preferences", udid: udid))
        XCTAssertFalse(SimulatorCrashReportParsing.isInstalledApp(
            procPath: "/Users/USER/Library/Developer/CoreSimulator/Devices/\(Self.daemonSimulator)/data/Containers/Bundle/Application/X/A.app/A",
            udid: udid
        ), "another simulator's app")
    }

    func testUDIDSources() {
        XCTAssertEqual(
            SimulatorCrashReportParsing.udid(coalitionName: "com.apple.CoreSimulator.SimDevice.3a391d73-ffb5-4792-8f37-47f1638ea5fc", procPath: nil),
            Self.settingsSimulator
        )
        XCTAssertNil(SimulatorCrashReportParsing.udid(coalitionName: "com.apple.CoreSimulator.SimDevice.nope", procPath: nil))
        XCTAssertNil(SimulatorCrashReportParsing.udid(coalitionName: "com.apple.Terminal", procPath: "/usr/bin/true"))
    }

    func testHeaderTimestampFormat() throws {
        let date = try XCTUnwrap(SimulatorCrashReportParsing.date("2026-09-27 23:54:05.00 +0300"))
        XCTAssertEqual(date, Self.utc("2026-09-27T20:54:05Z"))
        XCTAssertNil(SimulatorCrashReportParsing.date("yesterday"))
        XCTAssertEqual(SimulatorCrashReportParsing.date("2026-01-02 03:04:05 -0130"), Self.utc("2026-01-02T04:34:05Z"))
        XCTAssertNil(SimulatorCrashReportParsing.date("2026-02-30 03:04:05 +0000"), "no such day")
        XCTAssertNil(SimulatorCrashReportParsing.date("2026-01-02 03:04:05 0300"))
    }

    /// A report cut short (the crash reporter still writing it) is skipped
    /// as unreadable, so the caller reads it again.
    func testTruncatedReportIsUnreadable() throws {
        let data = try Data(contentsOf: Self.url("Preferences-2026-09-27-235405"))
        XCTAssertNil(SimulatorCrashReportParsing.parse(data.prefix(data.count / 2), url: Self.url("x")))
        XCTAssertEqual(SimulatorCrashReportParsing.outcome(data.prefix(data.count / 2), url: Self.url("x")), .unreadable)
        XCTAssertEqual(SimulatorCrashReportParsing.outcome(data.prefix(40), url: Self.url("x")), .unreadable)
    }

    // MARK: - Rows

    func testDaemonLoopFoldsIntoOneRow() throws {
        let rows = SimulatorCrashReportList.rows(try Self.allReports(), udid: Self.daemonSimulator)
        XCTAssertEqual(rows.map(\.newest.process), [
            "intelligencetasksd", "SettingsSearchReindexService", "AppIntentsLiveEntityService",
        ])
        let loop = rows[0]
        XCTAssertEqual(loop.count, 9)
        XCTAssertTrue(loop.isLoop)
        XCTAssertEqual(loop.newest.url.lastPathComponent, "intelligencetasksd-2026-09-25-134612.trimmed.ips")
        XCTAssertEqual(loop.oldest.url.lastPathComponent, "intelligencetasksd-2026-09-25-134451.trimmed.ips")
        XCTAssertEqual(loop.reports.map(\.time), loop.reports.map(\.time).sorted(by: >))
        XCTAssertFalse(rows[1].isLoop)
    }

    /// A gap longer than `loopGap` starts a new row.
    func testLoopBreaksAfterLongGap() throws {
        let reports = try Self.allReports().filter { $0.process == "intelligencetasksd" }
        let late = reports.map { report in
            report.url.lastPathComponent.hasPrefix("intelligencetasksd-2026-09-25-134612")
                ? Self.copy(report, time: report.time.addingTimeInterval(SimulatorCrashReportList.loopGap + 1))
                : report
        }
        let rows = SimulatorCrashReportList.rows(late, udid: Self.daemonSimulator)
        XCTAssertEqual(rows.map(\.count), [1, 8])
    }

    /// A built-in app's crashes (Settings: a bundle identifier, the
    /// runtime's path) stay one row each, however close together.
    func testBuiltInAppCrashesStaySeparate() throws {
        let report = try XCTUnwrap(Self.report("Preferences-2026-09-27-235405"))
        XCTAssertFalse(report.foldsIntoLoops)
        let later = Self.copy(report, time: report.time.addingTimeInterval(10), url: URL(fileURLWithPath: "/r/Preferences-2.ips"), incidentID: "second")
        XCTAssertEqual(SimulatorCrashReportList.rows([report, later], udid: Self.settingsSimulator).map(\.count), [1, 1])
    }

    /// An installed app's crashes stay one row each, newest first.
    func testAppCrashesStaySeparate() throws {
        let rows = SimulatorCrashReportList.rows(try Self.allReports(), udid: Self.appSimulator)
        XCTAssertEqual(rows.map(\.count), [1, 1])
        XCTAssertEqual(rows.map(\.newest.exceptionType), ["EXC_CRASH", "EXC_BREAKPOINT"])
    }

    func testOtherSimulatorsAreLeftOut() throws {
        let rows = SimulatorCrashReportList.rows(try Self.allReports(), udid: Self.settingsSimulator)
        XCTAssertEqual(rows.map(\.newest.process), ["Preferences"])
        XCTAssertTrue(SimulatorCrashReportList.rows(try Self.allReports(), udid: UUID().uuidString).isEmpty)
    }

    func testMyAppOnly() throws {
        let reports = try Self.allReports()
        let crash = SimulatorCrashReportList.App(bundleIdentifier: "dev.devicehubpro.fixture.crash", process: "AQACrash")
        XCTAssertEqual(SimulatorCrashReportList.rows(reports, udid: Self.appSimulator, app: crash).count, 2)
        let settings = SimulatorCrashReportList.App(bundleIdentifier: "com.apple.Preferences", process: "Preferences")
        XCTAssertTrue(SimulatorCrashReportList.rows(reports, udid: Self.appSimulator, app: settings).isEmpty)
        // A report without a bundle identifier matches by process name.
        let daemon = SimulatorCrashReportList.App(bundleIdentifier: "x.y", process: "intelligencetasksd")
        XCTAssertEqual(SimulatorCrashReportList.rows(reports, udid: Self.daemonSimulator, app: daemon).map(\.count), [9])
    }

    /// The same incident read from two folders is listed once.
    func testDuplicateIncidentListedOnce() throws {
        let report = try XCTUnwrap(Self.report("Preferences-2026-09-27-235405"))
        let copy = Self.copy(report, url: URL(fileURLWithPath: "/elsewhere/Preferences.ips"))
        XCTAssertEqual(SimulatorCrashReportList.rows([report, copy], udid: Self.settingsSimulator).count, 1)
    }

    // MARK: - Scanner

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorCrashReportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testScannerReadsOnlyTheFolderItself() async throws {
        let top = try makeFolder()
        let nested = top.appendingPathComponent("Retired", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for name in ["Preferences-2026-09-27-235405", "AQAHostCrash-2026-09-26-204328"] {
            try FileManager.default.copyItem(at: Self.url(name), to: top.appendingPathComponent(name + ".ips"))
        }
        try FileManager.default.copyItem(at: Self.url("AQACrash-2026-09-26-204000"), to: nested.appendingPathComponent("AQACrash.ips"))
        try Data("not a report".utf8).write(to: top.appendingPathComponent("notes.txt"))

        let scanner = SimulatorCrashReportScanner()
        let first = await scanner.scan(folders: [top, top.appendingPathComponent("missing")])
        XCTAssertEqual(first.reports.map(\.process), ["Preferences"], "not the subfolder, not the Mac's report")
        XCTAssertFalse(first.hasRecentUnreadable)

        // A removed file drops out; the scan never removes or changes one.
        try FileManager.default.removeItem(at: top.appendingPathComponent("Preferences-2026-09-27-235405.ips"))
        let second = await scanner.scan(folders: [top])
        XCTAssertTrue(second.reports.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: top.appendingPathComponent("AQAHostCrash-2026-09-26-204328.ips").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.appendingPathComponent("AQACrash.ips").path))
    }

    /// A file is read again only when its size or modification date
    /// changed: new bytes of the same size under the old date keep the
    /// cached report; a new date reads them.
    func testScannerCacheFollowsSizeAndDate() async throws {
        let top = try makeFolder()
        let file = top.appendingPathComponent("Preferences.ips")
        let original = try Data(contentsOf: Self.url("Preferences-2026-09-27-235405"))
        try original.write(to: file)
        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)

        let scanner = SimulatorCrashReportScanner()
        let now = stamp.addingTimeInterval(3600)
        var scan = await scanner.scan(folders: [top], now: now)
        XCTAssertEqual(scan.reports.map(\.process), ["Preferences"])
        var reads = await scanner.readCount
        XCTAssertEqual(reads, 1)

        scan = await scanner.scan(folders: [top], now: now)
        reads = await scanner.readCount
        XCTAssertEqual(reads, 1, "unchanged: from the cache")

        // Same size, same date, other bytes: still the cached report.
        try Data(repeating: UInt8(ascii: "x"), count: original.count).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        scan = await scanner.scan(folders: [top], now: now)
        reads = await scanner.readCount
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(scan.reports.map(\.process), ["Preferences"])

        // A new date: read again, now unreadable (and old, so no follow-up).
        try FileManager.default.setAttributes([.modificationDate: stamp.addingTimeInterval(1)], ofItemAtPath: file.path)
        scan = await scanner.scan(folders: [top], now: now)
        reads = await scanner.readCount
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(scan.reports.isEmpty)
        XCTAssertFalse(scan.hasRecentUnreadable)

        // A new size: read again.
        try original.prefix(original.count - 1).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: stamp.addingTimeInterval(1)], ofItemAtPath: file.path)
        scan = await scanner.scan(folders: [top], now: now)
        reads = await scanner.readCount
        XCTAssertEqual(reads, 3)
    }

    /// A report written moments ago that does not read yet asks for a
    /// follow-up read; an old one does not.
    func testRecentUnreadableReport() async throws {
        let top = try makeFolder()
        let file = top.appendingPathComponent("Preferences.ips")
        let original = try Data(contentsOf: Self.url("Preferences-2026-09-27-235405"))
        try original.prefix(original.count / 2).write(to: file)
        let written = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: file.path)

        let scanner = SimulatorCrashReportScanner()
        let fresh = await scanner.scan(folders: [top], now: written.addingTimeInterval(5))
        XCTAssertTrue(fresh.hasRecentUnreadable)
        let stale = await scanner.scan(folders: [top], now: written.addingTimeInterval(SimulatorCrashReportScanner.recentWindow + 1))
        XCTAssertFalse(stale.hasRecentUnreadable)
    }

    // MARK: - Helpers

    static func utc(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    static func copy(_ report: SimulatorCrashReport, time: Date? = nil, url: URL? = nil, incidentID: String? = nil) -> SimulatorCrashReport {
        SimulatorCrashReport(
            url: url ?? report.url,
            udid: report.udid,
            process: report.process,
            bundleIdentifier: report.bundleIdentifier,
            time: time ?? report.time,
            exceptionType: report.exceptionType,
            signal: report.signal,
            isInstalledApp: report.isInstalledApp,
            incidentID: incidentID ?? report.incidentID
        )
    }
}
