import AppKit
import Foundation
import Observation
import DeviceHubProKit

/// The four report kinds of Device Hub's Reports pop-up. A physical device's
/// crash-log listing is classified from the one listing, by the file's
/// extension and place. Device Hub, asked about the test iPhone (Device Hub
/// 27.0, 2026-09-29), listed the `.ips` files of the listing (the top-level
/// `JetsamEvent`, `Retired/` metrics, stacks, resource reports) under Logs and
/// showed "No Crash Reports", "No Spin Reports" and "No Diagnostic Reports"
/// for the others. An app's crash report is the one `.ips` kind that is not a
/// system log: `<Process>-<date>.ips` at the top of the listing, for a
/// process that is not one of the system reporters (`isSystemLog`). `.crash`
/// files are crashes, `.spin` / `.hang` files spins and `.diag` files
/// diagnostics, the classic Console kinds; none is on the test iPhone.
enum PhysicalReportKind: String, CaseIterable, Identifiable, Sendable {
    case crashes, spins, logs, diagnostics

    var id: String { rawValue }

    /// The pop-up's item and current choice.
    var label: String {
        switch self {
        case .crashes: "Crashes"
        case .spins: "Spins"
        case .logs: "Logs"
        case .diagnostics: "Diagnostics"
        }
    }

    /// Device Hub's card text when the kind has no report.
    var emptyText: String {
        switch self {
        case .crashes: "No Crash Reports"
        case .spins: "No Spin Reports"
        case .logs: "No Log Reports"
        case .diagnostics: "No Diagnostic Reports"
        }
    }

    /// The kind of a report file at the top of the listing, by its name; nil
    /// for a file that is not a report (`.ips.synced`, `.ips.ca.synced`,
    /// plists, folders).
    static func kind(ofFileName fileName: String) -> PhysicalReportKind? {
        kind(ofRelativePath: fileName)
    }

    /// The kind of the report at `relativePath` in the crash-log domain; nil
    /// for a file that is not a report. An `.ips` is a crash only at the top
    /// level and only for a process that is not a system reporter; every
    /// other one (`Retired/`, `DiagnosticLogs/`, `JetsamEvent`, `stacks`, the
    /// resource and metrics reports) is a log.
    static func kind(ofRelativePath relativePath: String) -> PhysicalReportKind? {
        let fileName = (relativePath as NSString).lastPathComponent
        switch (fileName as NSString).pathExtension.lowercased() {
        case "ips":
            let isTopLevel = !relativePath.contains("/")
            let process = PhysicalCrashLogList.parse(fileName: fileName).process
            return isTopLevel && !isSystemLog(process: process) ? .crashes : .logs
        case "crash": return .crashes
        case "spin", "hang": return .spins
        case "diag": return .diagnostics
        default: return nil
        }
    }

    /// Whether a report of `process` is a log the system writes about itself
    /// (memory pressure, stack snapshots, radio metrics, resource and
    /// analytics reports) rather than a crash of a program. The names are
    /// those of the test iPhone's own listing (417 entries).
    static func isSystemLog(process: String) -> Bool {
        let name = process.lowercased()
        if name.hasSuffix("_resource") { return true }
        let prefixes = [
            "jetsamevent", "excresource", "stacks", "wifilqmmetrics", "analytics", "diagnosticrequest",
            "sfa-", "sirisearchfeedback", "proactive_event_tracker", "xp_amp_app_usage",
        ]
        return prefixes.contains { name.hasPrefix($0) }
    }
}

/// One report in a physical device's system crash logs (Phase
/// 9B-2b). The device names them `<process>-<yyyy-MM-dd-HHmmss>[.<n>].ips`;
/// the process and the time come from that name.
struct PhysicalCrashLog: Identifiable, Equatable, Sendable {
    /// The path inside the crash-log domain: what `device copy from` takes as
    /// `--source`.
    let relativePath: String
    /// "JetsamEvent", "MyApp", "stacks": the name before the date.
    let process: String
    /// The date in the name, read as the Mac's wall clock (the device wrote
    /// its own local time); nil for a name that carries none.
    let date: Date?
    let size: Int?
    /// The file's modification time, the fallback when the name has no date.
    let modified: Date?

    var id: String { relativePath }

    var fileName: String { (relativePath as NSString).lastPathComponent }

    /// The folder inside the domain ("Retired"), nil for a top-level file.
    var folder: String? {
        let folder = (relativePath as NSString).deletingLastPathComponent
        return folder.isEmpty ? nil : folder
    }

    /// The time the list sorts by.
    var when: Date? { date ?? modified }

    /// The time the row shows: the file's modification time (Device Hub's
    /// "Today at 18:22:32"), the name's date when the listing has none.
    var shownDate: Date? { modified ?? date }

    var kind: PhysicalReportKind? { PhysicalReportKind.kind(ofRelativePath: relativePath) }
}

/// The extensions of the report kinds (`PhysicalReportKind`).
private enum ReportExtension {
    static func isReport(_ ext: String) -> Bool {
        ["ips", "crash", "spin", "hang", "diag"].contains(ext.lowercased())
    }
}

/// The crash-log listing of a device, read into the reports the Diagnostics
/// section shows.
enum PhysicalCrashLogList {
    /// The report files of `files` (`PhysicalReportKind`), newest first.
    /// Folders and every other file are hidden (`.ips.synced`,
    /// `.ips.ca.synced` and plists are not reports).
    static func logs(from files: [DevicectlDeviceFile], calendar: Calendar = .current) -> [PhysicalCrashLog] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var logs: [PhysicalCrashLog] = []
        for file in files where !file.isDirectory {
            let fileName = (file.relativePath as NSString).lastPathComponent
            guard PhysicalReportKind.kind(ofRelativePath: file.relativePath) != nil else { continue }
            let parsed = parse(fileName: fileName, calendar: calendar)
            logs.append(PhysicalCrashLog(
                relativePath: file.relativePath,
                process: parsed.process,
                date: parsed.date,
                size: file.metadata?.size,
                modified: file.metadata?.lastModDate.flatMap(formatter.date(from:))
            ))
        }
        return logs.sorted { lhs, rhs in
            switch (lhs.when, rhs.when) {
            case (let left?, let right?) where left != right: return left > right
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.relativePath < rhs.relativePath
            }
        }
    }

    /// The process and time of `<process>-yyyy-MM-dd-HHmmss[.<n>].ips`; a
    /// name in another shape keeps its whole stem as the process.
    static func parse(fileName: String, calendar: Calendar = .current) -> (process: String, date: Date?) {
        var stem = fileName
        let ext = (fileName as NSString).pathExtension
        if ReportExtension.isReport(ext) { stem.removeLast(ext.count + 1) }
        // The trailing ".000" / ".0002" of a report split in parts.
        if let dot = stem.lastIndex(of: "."), stem[stem.index(after: dot)...].allSatisfy(\.isNumber),
           stem.index(after: dot) < stem.endIndex {
            stem = String(stem[..<dot])
        }
        // "-yyyy-MM-dd-HHmmss" is 18 characters.
        guard stem.count > 18 else { return (stem, nil) }
        let tail = stem.suffix(18)
        let parts = tail.split(separator: "-", omittingEmptySubsequences: false)
        guard tail.first == "-", parts.count == 5,
              let year = Int(parts[1]), let month = Int(parts[2]), let day = Int(parts[3]),
              parts[4].count == 6, let clock = Int(parts[4]),
              (1...12).contains(month), (1...31).contains(day)
        else { return (stem, nil) }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = clock / 10000
        components.minute = clock / 100 % 100
        components.second = clock % 100
        return (String(stem.dropLast(18)), calendar.date(from: components))
    }
}

/// The reports of the physical device the Reports tab shows (Phase
/// 9B-2b): `device info files` for the `systemCrashLogs` domain, the report
/// files newest first, narrowed by the pop-up's kind and the Filter field,
/// and Open / Show in Finder / Save to… through `device copy from`. Nothing
/// is ever deleted, moved or changed on the device. The listing is one call (several hundred entries on a phone that
/// has been in use), read when the section shows and on Refresh; it does not
/// poll.
///
/// Every call goes through `ApplePhysicalInventory.client(for:)`: a device
/// that cannot be asked shows its state hint and nothing is sent.
@MainActor
@Observable
final class PhysicalCrashLogsController {
    /// The device whose logs are listed; nil while none is shown.
    private(set) var udid: String?
    /// `udid`'s reports, newest first.
    private(set) var logs: [PhysicalCrashLog] = []
    /// Whether `udid`'s listing was read at least once.
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    /// Why there is no list (the device cannot be asked, or the read failed).
    private(set) var problem: String?
    /// The pop-up's kind (Device Hub opens on Crashes).
    var kind: PhysicalReportKind = .crashes
    /// The Filter field: a report shows when its file name contains this.
    var filter = ""
    /// The report being copied now.
    private(set) var savingPath: String?

    /// Where "Show in Finder" goes (the Finder in the app, a recorder in tests).
    @ObservationIgnored var revealInFinder: @MainActor (_ url: URL) -> Void = { url in
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    /// What "Open" hands a copied report to (Console for an `.ips`).
    @ObservationIgnored var openFile: @MainActor (_ url: URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }
    @ObservationIgnored var temporaryDirectory: URL

    @ObservationIgnored private let inventory: ApplePhysicalInventory
    @ObservationIgnored private let status: StatusCenter
    @ObservationIgnored private let picker: any FileDestinationPicker
    @ObservationIgnored private var loadGeneration = 0
    /// The last `show` call's token: only its `hide(token:)` ends the list,
    /// so a section that disappears after its successor appeared does not
    /// end the successor's.
    @ObservationIgnored private var owner = 0

    init(
        inventory: ApplePhysicalInventory,
        status: StatusCenter,
        picker: any FileDestinationPicker,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.inventory = inventory
        self.status = status
        self.picker = picker
        self.temporaryDirectory = temporaryDirectory
    }

    /// Lists `udid`'s reports. Returns the token `hide(token:)` takes.
    @discardableResult
    func show(udid: String) -> Int {
        let key = PhysicalDeviceOptIn.normalize(udid)
        owner += 1
        if self.udid != key {
            self.udid = key
            logs = []
            hasLoaded = false
            problem = nil
            filter = ""
            Task { await reload() }
        }
        return owner
    }

    /// Ends the list when `token` is the last `show`'s.
    func hide(token: Int) {
        guard token == owner else { return }
        hide()
    }

    func hide() {
        udid = nil
        logs = []
        hasLoaded = false
        problem = nil
        filter = ""
        isLoading = false
        loadGeneration += 1
    }

    /// Reads the device's crash-log listing again.
    func reload() async {
        guard let udid else { return }
        loadGeneration += 1
        let generation = loadGeneration
        guard let client = await inventory.client(for: udid) else {
            guard generation == loadGeneration else { return }
            logs = []
            hasLoaded = true
            isLoading = false
            problem = ApplePhysicalInventory.unavailableText(entry: inventory.entry(udid: udid))
            return
        }
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        do {
            let files = try await client.listFiles(domain: .systemCrashLogs).value.files
            guard generation == loadGeneration else { return }
            logs = PhysicalCrashLogList.logs(from: files)
            hasLoaded = true
            problem = nil
        } catch {
            // A cancelled load (the view went away) is not a failure, and the
            // list still has to load: `hasLoaded` stays false.
            guard !error.isCancellation, generation == loadGeneration else { return }
            hasLoaded = true
            problem = "Could not list the crash logs: \(ApplePhysicalController.describe(error))"
        }
    }

    /// The reports to list: the pop-up's kind, narrowed by the Filter field.
    var rows: [PhysicalCrashLog] {
        let text = filter.trimmingCharacters(in: .whitespaces)
        return logs.filter { log in
            log.kind == kind && (text.isEmpty || log.fileName.localizedCaseInsensitiveContains(text))
        }
    }

    /// Whether the device has any report of the pop-up's kind, whatever the
    /// Filter field says.
    var hasReportsOfKind: Bool {
        logs.contains { $0.kind == kind }
    }

    /// Copies `log` off the device into a folder of temporary files, without
    /// asking where (`device copy from`), and returns the copy; nil when the
    /// copy failed (the reason is in the status line).
    func stage(_ log: PhysicalCrashLog) async -> URL? {
        guard let udid, savingPath == nil, let client = await inventory.client(for: udid) else { return nil }
        savingPath = log.relativePath
        defer { savingPath = nil }
        let folder = temporaryDirectory.appendingPathComponent("Device Hub Pro Physical Reports", isDirectory: true)
        let destination = folder.appendingPathComponent(log.fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            _ = try await client.copyFrom(domain: .systemCrashLogs, source: log.relativePath, to: destination)
            guard FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileNoSuchFile) }
            return destination
        } catch {
            status.errorMessage = "Could not copy \(log.fileName): \(ApplePhysicalController.describe(error))"
            return nil
        }
    }

    /// "Open": copies the report and hands it to its app.
    func open(_ log: PhysicalCrashLog) async {
        if let url = await stage(log) { openFile(url) }
    }

    /// "Show in Finder": copies the report and shows the copy.
    func reveal(_ log: PhysicalCrashLog) async {
        if let url = await stage(log) { revealInFinder(url) }
    }

    /// "Save to…": asks where, then copies the report off the device
    /// (`device copy from`, `systemCrashLogs`). Returns the saved file; nil
    /// when cancelled or failed (the reason is in the status line).
    @discardableResult
    func save(_ log: PhysicalCrashLog, revealAfter: Bool = false) async -> URL? {
        guard let udid, savingPath == nil, let client = await inventory.client(for: udid) else { return nil }
        savingPath = log.relativePath
        defer { savingPath = nil }
        let saver = PhysicalFileSaver(picker: picker, temporaryDirectory: temporaryDirectory)
        do {
            guard let saved = try await saver.save(client: client, domain: .systemCrashLogs, source: log.relativePath) else {
                return nil
            }
            status.flash("Saved \(saved.lastPathComponent)")
            if revealAfter { revealInFinder(saved) }
            return saved
        } catch {
            status.errorMessage = "Could not save \(log.fileName): \(ApplePhysicalController.describe(error))"
            return nil
        }
    }
}
