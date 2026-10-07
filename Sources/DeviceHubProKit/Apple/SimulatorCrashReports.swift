import Foundation

/// One crash report of a process that ran in a simulator, read from the
/// `.ips` file macOS's crash reporter wrote for it.
///
/// A simulator's processes are host processes, so their crash reports land
/// with the Mac's own in `~/Library/Logs/DiagnosticReports`. An `.ips` file
/// is two JSON documents: a one-line header (`bug_type` "309" for a crash,
/// `app_name`, `bundleID`, `timestamp`: when the report was written) and the
/// report body. Which simulator a report belongs to is only in the body
/// (established against Xcode 27.0 with the iOS 27.0 runtime, by crashing an
/// app in a simulator created for the purpose):
/// - `coalitionName` is `com.apple.CoreSimulator.SimDevice.<UDID>` for every
///   process the simulator's `launchd_sim` started: apps, the runtime's own
///   apps and daemons.
/// - `procPath` holds `…/CoreSimulator/Devices/<UDID>/data/Containers/Bundle/
///   Application/…` for an app installed in the simulator, and a redacted
///   runtime path (`/Volumes/VOLUME/*/Preferences.app/Preferences`) for the
///   runtime's own processes.
/// The header's `platform` (7 for an iOS simulator) names no device.
public struct SimulatorCrashReport: Sendable, Hashable, Identifiable {
    /// The file's path.
    public var id: String { url.path }
    public let url: URL
    /// The simulator the process ran in.
    public let udid: String
    /// The process name (`procName`: "Preferences", "intelligencetasksd").
    public let process: String
    /// The app's bundle identifier, when the process is an app or an app
    /// extension (the header's `bundleID`).
    public let bundleIdentifier: String?
    /// When the process crashed (`captureTime`; the header's `timestamp`,
    /// when the report was written, if the body has none).
    public let time: Date
    /// "EXC_BAD_ACCESS", "EXC_CRASH", "EXC_BREAKPOINT".
    public let exceptionType: String?
    /// "SIGSEGV", "SIGTRAP".
    public let signal: String?
    /// Whether the process is an app installed in the simulator (from its
    /// path), not one of the runtime's own processes.
    public let isInstalledApp: Bool
    /// The report's incident identifier: the same crash read from two
    /// folders is listed once.
    public let incidentID: String?

    public init(
        url: URL,
        udid: String,
        process: String,
        bundleIdentifier: String?,
        time: Date,
        exceptionType: String?,
        signal: String?,
        isInstalledApp: Bool,
        incidentID: String?
    ) {
        self.url = url
        self.udid = udid
        self.process = process
        self.bundleIdentifier = bundleIdentifier
        self.time = time
        self.exceptionType = exceptionType
        self.signal = signal
        self.isInstalledApp = isInstalledApp
        self.incidentID = incidentID
    }

    /// Whether successive crashes fold into one row: a runtime daemon or
    /// XPC service (no bundle identifier), never an app.
    public var foldsIntoLoops: Bool { bundleIdentifier == nil && !isInstalledApp }

    /// "EXC_CRASH (SIGSEGV)", "EXC_BREAKPOINT (SIGTRAP)"; "Crash" when the
    /// report names neither.
    public var exceptionSummary: String {
        switch (exceptionType, signal) {
        case let (type?, signal?): "\(type) (\(signal))"
        case let (type?, nil): type
        case let (nil, signal?): signal
        case (nil, nil): "Crash"
        }
    }
}

/// Reads `.ips` crash reports and attributes them to simulators.
public enum SimulatorCrashReportParsing {
    /// `coalitionName`'s prefix for a simulator's processes.
    public static let coalitionPrefix = "com.apple.CoreSimulator.SimDevice."
    /// A simulator device folder inside a path.
    static let devicesPathMarker = "/CoreSimulator/Devices/"
    /// Bytes that may follow a body's closing brace.
    private static let whitespace: Set<UInt8> = [0x20, 0x0A, 0x0D, 0x09]
    /// The same, as JSON escapes it in the file.
    static let escapedDevicesPathMarker = #"\/CoreSimulator\/Devices\/"#
    /// An installed app's folder inside a simulator's data folder.
    static let installedAppMarker = "/data/Containers/Bundle/Application/"

    /// What a `.ips` file holds, for the scanner.
    public enum Outcome: Sendable, Equatable {
        /// A crash report of a simulator's process.
        case report(SimulatorCrashReport)
        /// A whole report of something else: another bug type (hangs,
        /// resource reports), a Mac process.
        case notSimulatorCrash
        /// Not two JSON documents (yet): a file the crash reporter is still
        /// writing, or a damaged one.
        case unreadable
    }

    /// The report in `data` (a whole `.ips` file), or nil when it is not a
    /// crash report of a simulator's process (`outcome` says why).
    public static func parse(_ data: Data, url: URL) -> SimulatorCrashReport? {
        if case .report(let report) = outcome(data, url: url) { return report }
        return nil
    }

    /// What `data` (a whole `.ips` file) holds.
    public static func outcome(_ data: Data, url: URL) -> Outcome {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let header = (try? JSONSerialization.jsonObject(with: data[data.startIndex..<newline])) as? [String: Any]
        else { return .unreadable }
        // A body the crash reporter is still writing has not closed yet
        // (checked before the simulator markers, which may come later).
        guard let last = data.last(where: { !Self.whitespace.contains($0) }), last == UInt8(ascii: "}")
        else { return .unreadable }
        // Most reports are the Mac's own: skip them without decoding the body.
        guard header["bug_type"] as? String == "309",
              data.range(of: Data(coalitionPrefix.utf8)) != nil
                || data.range(of: Data(devicesPathMarker.utf8)) != nil
                || data.range(of: Data(escapedDevicesPathMarker.utf8)) != nil
        else { return .notSimulatorCrash }
        guard let body = (try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...])) as? [String: Any]
        else { return .unreadable }

        let procPath = body["procPath"] as? String
        guard let udid = udid(coalitionName: body["coalitionName"] as? String, procPath: procPath),
              let time = (body["captureTime"] as? String).flatMap(date) ?? (header["timestamp"] as? String).flatMap(date)
        else { return .notSimulatorCrash }

        let exception = body["exception"] as? [String: Any]
        let bundleInfo = body["bundleInfo"] as? [String: Any]
        let process = nonEmpty(body["procName"] as? String)
            ?? nonEmpty(header["app_name"] as? String)
            ?? nonEmpty(header["name"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return .report(SimulatorCrashReport(
            url: url,
            udid: udid,
            process: process,
            bundleIdentifier: nonEmpty(header["bundleID"] as? String)
                ?? nonEmpty(bundleInfo?["CFBundleIdentifier"] as? String),
            time: time,
            exceptionType: nonEmpty(exception?["type"] as? String),
            signal: nonEmpty(exception?["signal"] as? String),
            isInstalledApp: isInstalledApp(procPath: procPath, udid: udid),
            incidentID: nonEmpty(body["incident"] as? String) ?? nonEmpty(header["incident_id"] as? String)
        ))
    }

    /// Whether `procPath` is inside an app installed in `udid`: its data
    /// folder's `Containers/Bundle/Application`, whichever device set holds
    /// it (the default set's `…/CoreSimulator/Devices/<UDID>/` or a private
    /// set's `<set>/<UDID>/`).
    static func isInstalledApp(procPath: String?, udid: String) -> Bool {
        guard let procPath else { return false }
        return procPath.range(of: "/\(udid)" + installedAppMarker, options: .caseInsensitive) != nil
    }

    /// The simulator's UDID: from `coalitionName`, else from a path inside
    /// a simulator's device folder.
    static func udid(coalitionName: String?, procPath: String?) -> String? {
        if let coalitionName, coalitionName.hasPrefix(coalitionPrefix) {
            let rest = String(coalitionName.dropFirst(coalitionPrefix.count))
            if let udid = canonicalUDID(rest) { return udid }
        }
        if let procPath, let marker = procPath.range(of: devicesPathMarker) {
            let rest = procPath[marker.upperBound...]
            if let udid = canonicalUDID(String(rest.prefix(36))) { return udid }
        }
        return nil
    }

    /// `text` as an upper-case UUID string, or nil when it is not one.
    private static func canonicalUDID(_ text: String) -> String? {
        guard text.count == 36, let uuid = UUID(uuidString: text) else { return nil }
        return uuid.uuidString
    }

    /// "2026-09-27 23:53:26.6915 +0300" (the body's times) or
    /// "2026-09-27 23:54:05.00 +0300" (the header's): read field by field,
    /// with no shared formatter.
    static func date(_ text: String) -> Date? {
        let parts = text.split(separator: " ")
        guard parts.count == 3 else { return nil }
        let day = parts[0].split(separator: "-").compactMap { Int($0) }
        var clock = parts[1]
        var fraction = 0.0
        if let dot = clock.firstIndex(of: ".") {
            guard let value = Double("0" + clock[dot...]) else { return nil }
            fraction = value
            clock = clock[..<dot]
        }
        let time = clock.split(separator: ":").compactMap { Int($0) }
        let zone = parts[2]
        guard day.count == 3, time.count == 3, zone.count == 5,
              let sign = zone.first, sign == "+" || sign == "-",
              let hours = Int(zone.dropFirst().prefix(2)), let minutes = Int(zone.suffix(2)),
              let timeZone = TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(
            year: day[0], month: day[1], day: day[2],
            hour: time[0], minute: time[1], second: time[2]
        )
        guard components.isValidDate(in: calendar), let whole = calendar.date(from: components) else { return nil }
        return whole.addingTimeInterval(fraction)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

/// A row of a simulator's crash report list: one report, or a crash loop
/// of a runtime process folded into one row.
public struct SimulatorCrashReportRow: Sendable, Hashable, Identifiable {
    /// Newest first; never empty.
    public let reports: [SimulatorCrashReport]

    public init(reports: [SimulatorCrashReport]) {
        precondition(!reports.isEmpty)
        self.reports = reports
    }

    public var id: String { newest.id }
    public var newest: SimulatorCrashReport { reports[0] }
    public var oldest: SimulatorCrashReport { reports[reports.count - 1] }
    public var count: Int { reports.count }
    public var isLoop: Bool { reports.count > 1 }
}

/// Builds a simulator's crash report list.
public enum SimulatorCrashReportList {
    /// The app "My app only" keeps: its bundle identifier and process name.
    public struct App: Sendable, Hashable {
        public let bundleIdentifier: String
        public let process: String?

        public init(bundleIdentifier: String, process: String?) {
            self.bundleIdentifier = bundleIdentifier
            self.process = process
        }

        func matches(_ report: SimulatorCrashReport) -> Bool {
            if let identifier = report.bundleIdentifier { return identifier == bundleIdentifier }
            return process != nil && report.process == process
        }
    }

    /// The longest gap inside a crash loop. launchd starts a crashing
    /// daemon again with a growing delay: iOS 27.0's intelligencetasksd
    /// crashed every 10 s, then after 20, 40, 80 and 160 s.
    public static let loopGap: TimeInterval = 600

    /// `udid`'s rows, newest first: its reports (only `app`'s when given),
    /// each runtime daemon's or XPC service's successive crashes with the
    /// same exception no more than `loopGap` apart folded into one row. A
    /// report with a bundle identifier is an app's (installed or built in,
    /// like Settings) and stays one row: each crash is somebody's launch.
    public static func rows(
        _ reports: [SimulatorCrashReport],
        udid: String,
        app: App? = nil
    ) -> [SimulatorCrashReportRow] {
        var seen = Set<String>()
        let mine = reports
            .filter { $0.udid == udid && (app?.matches($0) ?? true) }
            .sorted { ($0.time, $0.id) < ($1.time, $1.id) }
            .filter { report in
                guard let incident = report.incidentID else { return true }
                return seen.insert(incident).inserted
            }

        struct LoopKey: Hashable {
            let process: String
            let exceptionType: String?
            let signal: String?
        }
        var rows: [[SimulatorCrashReport]] = []
        var openLoops: [LoopKey: Int] = [:]
        for report in mine {
            guard report.foldsIntoLoops else {
                rows.append([report])
                continue
            }
            let key = LoopKey(process: report.process, exceptionType: report.exceptionType, signal: report.signal)
            if let index = openLoops[key], let last = rows[index].last,
               report.time.timeIntervalSince(last.time) <= loopGap {
                rows[index].append(report)
            } else {
                openLoops[key] = rows.count
                rows.append([report])
            }
        }
        return rows
            .map { SimulatorCrashReportRow(reports: $0.reversed()) }
            .sorted { ($0.newest.time, $0.newest.id) > ($1.newest.time, $1.newest.id) }
    }
}

/// What one scan found.
public struct SimulatorCrashReportScan: Sendable, Equatable {
    /// Every simulator's crash reports in the folders.
    public let reports: [SimulatorCrashReport]
    /// Whether a report written in the last `recentWindow` did not read as
    /// a whole report: the crash reporter may still be writing it, and a
    /// file that grows in place changes no folder entry, so the caller
    /// reads once more a little later.
    public let hasRecentUnreadable: Bool

    public init(reports: [SimulatorCrashReport], hasRecentUnreadable: Bool) {
        self.reports = reports
        self.hasRecentUnreadable = hasRecentUnreadable
    }
}

/// Finds the crash reports of simulators' processes in folders, reading a
/// file again only when its size or modification date changed.
public actor SimulatorCrashReportScanner {
    private struct Stamp: Equatable {
        let size: Int
        let modified: Date
    }

    private var cache: [String: (stamp: Stamp, outcome: SimulatorCrashReportParsing.Outcome)] = [:]
    /// How many files the scans have read from disk (tests).
    public private(set) var readCount = 0
    /// How recent an unreadable report must be for `hasRecentUnreadable`.
    public static let recentWindow: TimeInterval = 60

    public init() {}

    /// `~/Library/Logs/DiagnosticReports`, where the crash reporter writes
    /// the reports of a simulator's processes with the Mac's own.
    public static var userDiagnosticReportsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// The reports among the `.ips` files directly in `folders` (not their
    /// subfolders). Missing folders are skipped; nothing is ever changed or
    /// removed.
    public func scan(folders: [URL], now: Date = Date()) -> SimulatorCrashReportScan {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var files: [URL] = []
        for folder in folders {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            )) ?? []
            files.append(contentsOf: entries.filter { $0.pathExtension == "ips" })
        }

        var reports: [SimulatorCrashReport] = []
        var recentUnreadable = false
        var live = Set<String>()
        for file in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            let stamp = Stamp(size: values.fileSize ?? -1, modified: values.contentModificationDate ?? .distantPast)
            live.insert(file.path)
            let outcome: SimulatorCrashReportParsing.Outcome
            if let cached = cache[file.path], cached.stamp == stamp {
                outcome = cached.outcome
            } else {
                // Mapped: a Mac report can run to megabytes, and most are
                // rejected after the header line.
                readCount += 1
                outcome = (try? Data(contentsOf: file, options: .mappedIfSafe))
                    .map { SimulatorCrashReportParsing.outcome($0, url: file) } ?? .unreadable
                cache[file.path] = (stamp, outcome)
            }
            switch outcome {
            case .report(let report):
                reports.append(report)
            case .unreadable:
                if now.timeIntervalSince(stamp.modified) <= Self.recentWindow { recentUnreadable = true }
            case .notSimulatorCrash:
                break
            }
        }
        cache = cache.filter { live.contains($0.key) }
        return SimulatorCrashReportScan(reports: reports, hasRecentUnreadable: recentUnreadable)
    }
}
