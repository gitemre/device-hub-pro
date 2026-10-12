import Darwin
import Foundation

/// A collection's result: the report as read, not yet scrubbed, and the values
/// the scrubber must take out of every string.
public struct CollectedProblemReport: Sendable {
    public var report: ProblemReport
    /// A raw identifier to its alias: phone serials as `phone-N`, simulator
    /// UDIDs as `sim-N`.
    public var privateIdentifiers: [String: String]
    /// Values that must never appear (the team id, enabled devices' names).
    public var secrets: [String]
}

/// Reads what a problem report holds, read-only and bounded.
///
/// The collection makes no network call, writes no file, never starts, kills
/// or restarts the adb server (`ProblemReportAdbCall` lists the four argv
/// shapes it ever runs, and only while an adb server of the same adb is
/// already running) and never runs simctl or devicectl. It never throws: a
/// section that fails becomes a line of `collection.notes`. It stops starting
/// new probes once `ProblemReportInputs.budget` has elapsed and when its task
/// is cancelled.
public enum ProblemReportCollector {
    /// `recentIdentifiers` are the serials and names of devices that were
    /// connected when an earlier error was recorded, which may not be now:
    /// the errors still name them.
    public static func collect(
        inputs: ProblemReportInputs,
        appState: ProblemReportAppState?,
        subject: ProblemReport.Subject?,
        recentProblems: [ProblemReport.RecentProblem],
        recentIdentifiers: RecentProblemIdentifiers = RecentProblemIdentifiers(),
        now: Date,
        reportID: String
    ) async -> CollectedProblemReport {
        var run = CollectionRun(inputs: inputs, appState: appState)
        let facts = inputs.macFacts()

        // The SDK, its tools and the token files: files only.
        let roots = run.sdkRoots()
        let adb = run.adbInfo()
        let emulator = run.emulatorInfo()
        let avdmanager = run.avdmanagerInfo(roots: roots)
        let tokenFile = run.tokenFile(
            at: inputs.homeDirectory.appendingPathComponent(".emulator_console_auth_token")
        )
        var emulatorHomeTokenFile: ProblemReport.TokenFileInfo?
        if let emulatorHome = run.environment["ANDROID_EMULATOR_HOME"], !emulatorHome.isEmpty {
            emulatorHomeTokenFile = run.tokenFile(
                at: URL(fileURLWithPath: emulatorHome, isDirectory: true)
                    .appendingPathComponent(".emulator_console_auth_token")
            )
        }

        // The processes (and the adb server guard), then what adb says.
        let processes = await run.processes(adbVersion: adb.version)
        var emulators = run.runningEmulators(processes: processes)
        let adbServer = processes.server
        let devices = await run.devices(server: adbServer)
        await run.probe(emulators: &emulators, devices: devices, server: adbServer)

        // The AVDs need to know which ones run.
        let avdHome = run.avdHome()
        let avds = run.avds(
            home: avdHome.url,
            roots: roots,
            running: Set(emulators.map(\.avd)),
            hostIsAppleSilicon: facts.appleSilicon
        )
        let phones = run.phones(devices: devices)

        var adbInfo = adb
        adbInfo.server = adbServer.info

        let cancelled = Task.isCancelled
        if cancelled { run.note("Cancelled before the logs were read.") }
        let logs = cancelled ? [] : run.emulatorLogs()
        let crashes = cancelled ? [] : run.crashReports(now: now)
        let apple = cancelled ? ProblemReport.AppleInfo() : await run.appleInfo()

        let android = ProblemReport.AndroidInfo(
            variables: run.variables(),
            sdkFolderSetByApp: inputs.producer == .app && AndroidSDKLocation.isAppliedByApp,
            mdnsDisabledByApp: inputs.producer == .app && AdbMdnsPolicy.isDisabledByApp,
            sdkRoots: roots.reports,
            adb: adbInfo,
            emulator: emulator,
            avdmanager: avdmanager,
            consoleTokenFile: tokenFile,
            emulatorHomeTokenFile: emulatorHomeTokenFile,
            avdHome: avdHome.report(avdCount: avds.total),
            avds: avds.avds,
            emulatorListsAvds: appState?.emulatorListAvds,
            runningEmulators: emulators,
            phones: phones.phones,
            devicesSource: devices.source,
            appAdb: run.appAdbState()
        )

        var report = ProblemReport(
            id: reportID,
            createdAt: wholeSeconds(now),
            producer: inputs.producer,
            subject: subject.map {
                ProblemReport.Subject(message: $0.message, details: $0.details, occurredAt: wholeSeconds($0.occurredAt))
            },
            app: run.appInfo(),
            mac: run.macInfo(facts: facts, avdHome: avdHome.url, roots: roots),
            android: android,
            apple: apple,
            windows: appState?.windows ?? [],
            recentProblems: recentProblems.map {
                ProblemReport.RecentProblem(at: wholeSeconds($0.at), message: $0.message, details: $0.details, count: $0.count)
            },
            emulatorLogs: logs,
            crashReports: crashes
        )

        var identifiers = run.privateIdentifiers
        phones.identifiers.forEach { identifiers[$0.key] = $0.value }
        for (index, udid) in (appState?.simulatorUDIDs ?? []).enumerated() where !udid.isEmpty {
            identifiers[udid] = "sim-\(index + 1)"
        }
        Self.addRecentPhones(recentIdentifiers.phones, to: &identifiers)
        var secrets = appState?.secrets ?? []
        for secret in recentIdentifiers.secrets where !secrets.contains(secret) { secrets.append(secret) }

        report.collection = ProblemReport.CollectionInfo(
            milliseconds: run.elapsedMilliseconds,
            notes: run.notes
        )
        return CollectedProblemReport(
            report: report,
            privateIdentifiers: identifiers,
            secrets: secrets
        )
    }

    /// The phones earlier errors named that the inventory does not list now:
    /// each group of serials is one phone, which keeps the alias of any of its
    /// serials that the table has, else takes the next `phone-N`.
    static func addRecentPhones(_ groups: [[String]], to identifiers: inout [String: String]) {
        var known: [String: String] = [:]
        var highest = 0
        for (raw, alias) in identifiers {
            known[raw.lowercased()] = alias
            if alias.hasPrefix("phone-"), let number = Int(alias.dropFirst("phone-".count)) { highest = max(highest, number) }
        }
        for group in groups {
            let members = group.filter { !$0.isEmpty }
            guard !members.isEmpty else { continue }
            var alias = members.compactMap { known[$0.lowercased()] }.first
            if alias == nil {
                highest += 1
                alias = "phone-\(highest)"
            }
            guard let alias else { continue }
            for member in members where known[member.lowercased()] == nil {
                identifiers[member] = alias
                known[member.lowercased()] = alias
            }
        }
    }

    /// A date with its fraction cut: a report keeps whole seconds, so what is
    /// rendered decodes to an equal report.
    static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}

/// The state one collection carries from section to section: its inputs, the
/// clock and what could not be read.
struct CollectionRun {
    let inputs: ProblemReportInputs
    let appState: ProblemReportAppState?
    let environment: [String: String]
    let started: ContinuousClock.Instant
    let deadline: ContinuousClock.Instant
    var notes: [String] = []
    var privateIdentifiers: [String: String] = [:]

    init(inputs: ProblemReportInputs, appState: ProblemReportAppState?) {
        self.inputs = inputs
        self.appState = appState
        self.environment = inputs.environment()
        self.started = ContinuousClock.now
        self.deadline = started.advanced(by: inputs.budget)
    }

    var home: URL { inputs.homeDirectory }

    var overBudget: Bool { ContinuousClock.now >= deadline }

    var elapsedMilliseconds: Int {
        let components = (ContinuousClock.now - started).components
        return Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }

    mutating func note(_ text: String) {
        if !notes.contains(text) { notes.append(text) }
    }
}

// MARK: - The app and the Mac

extension CollectionRun {
    func appInfo() -> ProblemReport.AppInfo {
        let bundle = inputs.bundle
        let kind: ProblemReport.AppInfo.Kind
        if inputs.producer == .cli {
            kind = .cli
        } else {
            kind = bundle.bundlePath?.hasSuffix(".app") == true ? .packaged : .development
        }
        var location: ProblemReport.AppInfo.Location?
        if let path = bundle.bundlePath {
            if path.hasPrefix("/Applications/") {
                location = .applications
            } else if path.hasPrefix(home.path + "/Applications/") {
                location = .userApplications
            } else if path.contains("/AppTranslocation/") {
                location = .translocated
            } else if path.hasPrefix("/Volumes/") {
                location = .diskImage
            } else {
                location = .other
            }
        }
        let flags = environment
            .filter { $0.key.hasPrefix("DHP_") && !$0.value.isEmpty }
            .map(\.key)
            .sorted()
        return ProblemReport.AppInfo(
            version: bundle.version,
            build: bundle.build,
            kind: kind,
            location: location,
            quarantined: bundle.quarantined,
            environmentFlags: flags,
            preferences: appState?.preferences
        )
    }

    func macInfo(facts: MacFacts, avdHome: URL, roots: SdkRoots) -> ProblemReport.MacInfo {
        var space: [ProblemReport.VolumeSpace] = []
        func add(_ role: String, _ url: URL?) {
            guard let url, let bytes = inputs.freeBytes(url) else { return }
            space.append(ProblemReport.VolumeSpace(role: role, freeGB: Int(bytes / 1_000_000_000)))
        }
        add("home", home)
        add("avdHome", avdHome)
        add("sdk", roots.reports.first { $0.exists }.map { URL(fileURLWithPath: $0.path, isDirectory: true) })
        return ProblemReport.MacInfo(
            macOS: facts.macOS,
            build: facts.build,
            model: facts.model,
            chip: facts.chip,
            memoryGB: facts.memoryBytes.map { Int((Double($0) / 1_073_741_824).rounded()) },
            appleSilicon: facts.appleSilicon,
            translated: facts.translated,
            hypervisorSupported: facts.hypervisorSupported,
            insideVirtualMachine: facts.insideVirtualMachine,
            freeSpace: space
        )
    }
}

// MARK: - Apple

extension CollectionRun {
    /// The Xcode facts from the toolchain the app probed, else the one the
    /// producer probes (the CLI); the tier, simulators and bridge only from
    /// the app's snapshot. Nothing here runs simctl or devicectl.
    func appleInfo() async -> ProblemReport.AppleInfo {
        var info = ProblemReport.AppleInfo()
        let toolchain: AppleToolchain?
        if let probed = appState?.apple.toolchain {
            toolchain = probed
        } else {
            toolchain = await inputs.appleToolchain()
        }
        if let toolchain {
            info.xcodeVersion = toolchain.xcodeVersion
            info.xcodeBuild = toolchain.xcodeBuild
            if let developerDirectory = toolchain.developerDirectory {
                let path = developerDirectory.path
                if path.contains("CommandLineTools") {
                    info.developerDirectory = "Command Line Tools"
                } else if path.hasSuffix("/Contents/Developer") {
                    info.developerDirectory = "Xcode app"
                    info.xcodeAppName = developerDirectory.pathComponents.last { $0.hasSuffix(".app") }
                } else {
                    info.developerDirectory = "other"
                }
            }
            info.installedXcodes = toolchain.installedXcodes.count
            info.firstLaunchComplete = toolchain.firstLaunchComplete
            info.simctl = Self.appleTool(toolchain.simctl)
            info.devicectl = Self.appleTool(toolchain.devicectl)
        } else if let state = appState?.apple {
            info.xcodeVersion = state.xcodeVersion
            info.xcodeBuild = state.xcodeBuild
        }
        if let state = appState?.apple {
            info.tier = state.isProbed ? state.tier : nil
            info.setupAdvice = state.setupAdvice
            info.simulators = ProblemReport.SimulatorCounts(
                listed: state.simulatorsListed,
                total: state.simulatorCount,
                booted: state.bootedCount,
                runtimes: state.runtimeCount,
                watcher: state.watcherHealth,
                canvasReady: state.canvasReadyCount
            )
            info.bridge = state.bridge
        }
        return info
    }

    private static func appleTool(_ tool: AppleToolchain.BundledTool) -> ProblemReport.AppleTool {
        ProblemReport.AppleTool(
            found: tool.binary != nil,
            version: tool.installedVersion,
            expectedVersion: tool.expectedVersion,
            needsFirstLaunch: tool.needsFirstLaunch,
            overridden: tool.isOverride
        )
    }
}

// MARK: - Logs and crash reports

extension CollectionRun {
    /// How much of the end of a log file is read.
    static let logWindowBytes = 64 * 1024
    static let logLineCount = 60
    static let maxLogLineLength = 400

    /// The newest three of the app's emulator logs, each cut to its last 60
    /// lines. The directory is only listed (never created) and a file is read
    /// from its last 64 KiB, so a huge log costs nothing.
    mutating func emulatorLogs() -> [ProblemReport.LogTail] {
        guard let directory = inputs.appLogDirectory else { return [] }
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        let prefix = "devicehubpro-emulator-"
        let logs = urls.compactMap { url -> (url: URL, modified: Date, size: Int)? in
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(".log") else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
        }.sorted { $0.modified > $1.modified }

        var tails: [ProblemReport.LogTail] = []
        for log in logs.prefix(3) {
            let name = log.url.lastPathComponent
            let avd = String(name.dropFirst(prefix.count).dropLast(".log".count))
            guard let tail = Self.tail(of: log.url, size: log.size) else {
                note("Couldn\u{2019}t read the emulator log of \(avd).")
                continue
            }
            tails.append(ProblemReport.LogTail(
                avd: avd,
                modified: ProblemReportCollector.wholeSeconds(log.modified),
                bytes: log.size,
                lines: tail.lines,
                omittedLines: tail.omitted
            ))
        }
        return tails
    }

    static func tail(of url: URL, size: Int) -> (lines: [String], omitted: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let offset = max(0, size - logWindowBytes)
        do {
            if offset > 0 { try handle.seek(toOffset: UInt64(offset)) }
            guard let data = try handle.readToEnd() else { return ([], false) }
            return tailLines(from: data, startedMidFile: offset > 0)
        } catch {
            return nil
        }
    }

    /// The last 60 lines of `data`, whole; the first line is dropped when `data`
    /// starts in the middle of the file (it is partial). A long line is cut
    /// only after it was scrubbed (`cutLongLines`): a key cut in two before
    /// that no longer looks like one.
    static func tailLines(from data: Data, startedMidFile: Bool) -> (lines: [String], omitted: Bool) {
        var lines = String(decoding: data, as: UTF8.self)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        var omitted = false
        if startedMidFile, !lines.isEmpty {
            lines.removeFirst()
            omitted = true
        }
        // The file's final newline leaves one empty element.
        if lines.last == "" { lines.removeLast() }
        if lines.count > logLineCount {
            lines = Array(lines.suffix(logLineCount))
            omitted = true
        }
        return (lines, omitted)
    }

    /// A line over 400 characters keeps its first 150 and its last 200.
    static func cutLongLines(_ lines: [String]) -> [String] {
        lines.map { line in
            guard line.count > maxLogLineLength else { return line }
            return String(line.prefix(150)) + " \u{2026} " + String(line.suffix(200))
        }
    }

    /// Crash reports of the processes that matter, from the last 14 days,
    /// newest first, at most ten. Only their names and dates: a report is
    /// never opened.
    mutating func crashReports(now: Date) -> [ProblemReport.CrashReportRef] {
        guard let directory = inputs.diagnosticReportsDirectory else { return [] }
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        let prefixes = ["qemu-system-", "emulator", "DeviceHubPro", "adb"]
        let cutoff = now.addingTimeInterval(-14 * 24 * 3600)
        let found = urls.compactMap { url -> ProblemReport.CrashReportRef? in
            let name = url.lastPathComponent
            guard name.hasSuffix(".ips"), prefixes.contains(where: { name.hasPrefix($0) }) else { return nil }
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  date >= cutoff
            else { return nil }
            return ProblemReport.CrashReportRef(
                process: Self.crashProcessName(name),
                date: ProblemReportCollector.wholeSeconds(date)
            )
        }
        return Array(found.sorted { $0.date > $1.date }.prefix(10))
    }

    /// "qemu-system-aarch64" from "qemu-system-aarch64-2026-10-09-123456.ips".
    static func crashProcessName(_ fileName: String) -> String {
        let stem = String(fileName.dropLast(".ips".count))
        guard let range = stem.range(of: "-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$", options: .regularExpression) else {
            return stem
        }
        return String(stem[..<range.lowerBound])
    }
}
