import Foundation

// MARK: - Trim memory

/// `ComponentCallbacks2` trim levels, sent with `am send-trim-memory`
/// (API 23+, shell only). ActivityManagerService records the level on the
/// process and calls every `onTrimMemory` of the app; the system itself has
/// stopped sending 5/10/15/60/80 since API 34, but a shell-sent level is
/// still delivered.
public enum TrimMemoryLevel: Int, CaseIterable, Identifiable, Sendable {
    case runningModerate = 5
    case runningLow = 10
    case runningCritical = 15
    case uiHidden = 20
    case background = 40
    case moderate = 60
    case complete = 80

    public var id: Int { rawValue }

    public static let minimumAPI = 23

    /// The `am send-trim-memory` level name. UI_HIDDEN is `HIDDEN` there;
    /// `UI_HIDDEN` is refused ("Unknown level option").
    public var commandToken: String {
        switch self {
        case .runningModerate: return "RUNNING_MODERATE"
        case .runningLow: return "RUNNING_LOW"
        case .runningCritical: return "RUNNING_CRITICAL"
        case .uiHidden: return "HIDDEN"
        case .background: return "BACKGROUND"
        case .moderate: return "MODERATE"
        case .complete: return "COMPLETE"
        }
    }

    public var label: String {
        switch self {
        case .runningModerate: return "RUNNING_MODERATE (5)"
        case .runningLow: return "RUNNING_LOW (10)"
        case .runningCritical: return "RUNNING_CRITICAL (15)"
        case .uiHidden: return "UI_HIDDEN (20)"
        case .background: return "BACKGROUND (40)"
        case .moderate: return "MODERATE (60)"
        case .complete: return "COMPLETE (80)"
        }
    }

    /// Levels ActivityManagerService refuses for a foreground process
    /// ("Unable to set a background trim level on a foreground process").
    public var isBackgroundLevel: Bool { rawValue >= Self.uiHidden.rawValue }

    /// The level Simulate low memory sends: RUNNING_CRITICAL (15) while the
    /// process is in the foreground (a background level is refused there),
    /// COMPLETE (80) otherwise: what the system sends a cached process
    /// before it kills it, so every `onTrimMemory` branch (>= 15 and >= 80)
    /// of the app runs.
    public static func forLowMemory(process: AppProcessState?, apiLevel: Int?) -> TrimMemoryLevel {
        guard let apiLevel, apiLevel >= AppProcessState.procStateNumberingMinimumAPI,
              let state = process?.procState
        else { return .runningCritical }
        return state <= AppProcessState.importantForegroundProcState ? .runningCritical : .complete
    }

    public static func named(_ value: Int) -> TrimMemoryLevel? {
        TrimMemoryLevel(rawValue: value)
    }
}

// MARK: - Process state

/// The target app's main process as `dumpsys activity processes <package>`
/// describes it (filtered on the device to the `*APP*` header, the `pid=`,
/// `trimMemoryLevel=` and `curProcState=` lines, and the freezer line with
/// `isFrozen=`: `AppConditionsSnapshot.processLinesPattern`).
public struct AppProcessState: Sendable, Equatable {
    public var processName: String
    public var pid: Int?
    /// What AMS last recorded (`ProcessProfileRecord`); the app reads the
    /// same field as `RunningAppProcessInfo.lastTrimLevel`.
    public var trimMemoryLevel: Int?
    /// `ActivityManager.PROCESS_STATE_*` (`curProcState=`).
    public var procState: Int?
    /// The cached-app freezer's state (`isFrozen=`, dumped from API 31);
    /// nil where the dump has none.
    public var isFrozen: Bool?

    public init(processName: String, pid: Int? = nil, trimMemoryLevel: Int? = nil, procState: Int? = nil, isFrozen: Bool? = nil) {
        self.processName = processName
        self.pid = pid
        self.trimMemoryLevel = trimMemoryLevel
        self.procState = procState
        self.isFrozen = isFrozen
    }

    /// `PROCESS_STATE_IMPORTANT_FOREGROUND` from Android 11 (API 30): AMS
    /// refuses background trim levels at or below it. The numbering moved
    /// before API 30, so older images are not gated here; AMS's own refusal
    /// is shown instead.
    public static let importantForegroundProcState = 6
    public static let procStateNumberingMinimumAPI = 30

    /// A short name for the common states (API 30+ numbering).
    public static func procStateName(_ state: Int, apiLevel: Int?) -> String? {
        guard let apiLevel, apiLevel >= procStateNumberingMinimumAPI else { return nil }
        switch state {
        case 0, 1: return "persistent"
        case 2: return "top"
        case 3: return "bound top"
        case 4, 5: return "foreground service"
        case 6: return "important foreground"
        case 7, 8: return "background"
        case 9: return "backup"
        case 10: return "service"
        case 11: return "receiver"
        case 12: return "top, sleeping"
        case 13: return "heavy weight"
        case 14: return "home"
        case 15: return "last activity"
        case 16, 17, 18, 19: return "cached"
        default: return nil
        }
    }

    /// The package's main process (the one named like the package) from
    /// the filtered dump; nil when it is not running.
    public static func parse(_ dump: String, package: String) -> AppProcessState? {
        var blocks: [AppProcessState] = []
        for rawLine in dump.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("*APP*") {
                // `*APP* UID 10183 ProcessRecord{91994fb 3310:com.example/u0a183}`
                guard let record = ConditionsText.braced(after: "ProcessRecord{", in: line[...]),
                      let colon = record.firstIndex(of: ":")
                else { continue }
                let head = record[..<colon].split(separator: " ")
                let pid = head.last.flatMap { Int($0) }
                let name = record[record.index(after: colon)...].split(separator: "/").first.map(String.init) ?? ""
                blocks.append(AppProcessState(processName: name, pid: pid))
                continue
            }
            guard !blocks.isEmpty else { continue }
            let index = blocks.count - 1
            if line.hasPrefix("pid="), let pid = ConditionsText.integer(after: "pid", in: line[...]) {
                blocks[index].pid = pid
            } else if line.hasPrefix("trimMemoryLevel=") {
                blocks[index].trimMemoryLevel = ConditionsText.integer(after: "trimMemoryLevel", in: line[...])
            } else if line.hasPrefix("curProcState=") {
                blocks[index].procState = ConditionsText.integer(after: "curProcState", in: line[...])
            } else if let frozen = ConditionsText.word(after: "isFrozen=", in: line[...]) {
                blocks[index].isFrozen = Bool(frozen)
            }
        }
        return blocks.first { $0.processName == package }
    }
}

/// Whether a trim level can be sent now, decided the way
/// `ActivityManagerService.setProcessMemoryTrimLevel` decides.
public enum TrimMemoryGate: Sendable, Equatable {
    case allowed
    case unsupported
    case notRunning
    /// Background levels (≥ 20) are refused while `curProcState` is at or
    /// below IMPORTANT_FOREGROUND (API 30+ numbering).
    case foreground(procState: Int)
    /// The level must be strictly higher than the recorded one; it only
    /// drops when the process restarts (API 35+).
    case notHigher(current: Int)

    public static func evaluate(
        _ level: TrimMemoryLevel,
        process: AppProcessState?,
        apiLevel: Int?
    ) -> TrimMemoryGate {
        if let apiLevel, apiLevel < TrimMemoryLevel.minimumAPI { return .unsupported }
        guard let process, process.pid != nil else { return .notRunning }
        if level.isBackgroundLevel,
           let apiLevel, apiLevel >= AppProcessState.procStateNumberingMinimumAPI,
           let state = process.procState, state <= AppProcessState.importantForegroundProcState {
            return .foreground(procState: state)
        }
        if let current = process.trimMemoryLevel, level.rawValue <= current {
            return .notHigher(current: current)
        }
        return .allowed
    }

    /// Why the Send button is off; nil when it is on.
    public var reason: String? {
        switch self {
        case .allowed:
            return nil
        case .unsupported:
            return "Needs Android 6 (API 23) or newer."
        case .notRunning:
            return "The app is not running. Open it first."
        case .foreground:
            return "Android refuses background levels (UI_HIDDEN and up) while the app is in the foreground or runs a foreground service. Send it to the background first."
        case .notHigher(let current):
            return "Android only accepts a level above the app's current one (\(current)). Restart the app to send lower levels."
        }
    }
}

// MARK: - Process exit records

/// The newest `ApplicationExitInfo` of the package (`dumpsys activity
/// exit-info <package>`, API 30+).
public struct ProcessExitRecord: Sendable, Equatable {
    public var timestamp: String?
    public var pid: Int?
    public var processName: String?
    public var reason: Int?
    public var reasonName: String?
    public var subreason: Int?
    public var subreasonName: String?
    public var description: String?

    public init(
        timestamp: String? = nil,
        pid: Int? = nil,
        processName: String? = nil,
        reason: Int? = nil,
        reasonName: String? = nil,
        subreason: Int? = nil,
        subreasonName: String? = nil,
        description: String? = nil
    ) {
        self.timestamp = timestamp
        self.pid = pid
        self.processName = processName
        self.reason = reason
        self.reasonName = reasonName
        self.subreason = subreason
        self.subreasonName = subreasonName
        self.description = description
    }

    public static let minimumAPI = 30
    /// `ApplicationExitInfo.REASON_CRASH`.
    public static let crashReason = 4
    /// `ApplicationExitInfo.REASON_USER_REQUESTED`.
    public static let userRequestedReason = 10

    /// `USER REQUESTED · KILL BACKGROUND`, or the reason alone.
    public var summary: String {
        var parts: [String] = []
        if let reasonName { parts.append(reasonName) } else if let reason { parts.append("reason \(reason)") }
        if let subreasonName, subreasonName != "UNKNOWN" { parts.append(subreasonName) }
        return parts.joined(separator: " · ")
    }

    /// Every record in the dump, newest first (the dump's order).
    ///
    ///     ApplicationExitInfo #0:
    ///       timestamp=2026-09-23 06:43:37.352 pid=23633 realUid=10183 …
    ///       process=com.example reason=10 (USER REQUESTED) subreason=24 (KILL BACKGROUND) status=0
    ///       description=kill background
    public static func parse(_ dump: String) -> [ProcessExitRecord] {
        var records: [ProcessExitRecord] = []
        for rawLine in dump.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("ApplicationExitInfo #") {
                records.append(ProcessExitRecord())
                continue
            }
            guard !records.isEmpty else { continue }
            let index = records.count - 1
            if line.hasPrefix("timestamp=") {
                let value = line.dropFirst("timestamp=".count)
                records[index].timestamp = value.range(of: " pid=").map { String(value[..<$0.lowerBound]) }
                    ?? String(value)
                records[index].pid = ConditionsText.integer(after: "pid", in: line[...])
            } else if line.hasPrefix("process=") {
                records[index].processName = ConditionsText.word(after: "process=", in: line[...])
                if let reason = ConditionsText.registration(after: "reason=", in: line[...]) {
                    records[index].reason = reason.code
                    records[index].reasonName = reason.name
                }
                if let subreason = ConditionsText.registration(after: "subreason=", in: line[...]) {
                    records[index].subreason = subreason.code
                    records[index].subreasonName = subreason.name
                }
            } else if line.hasPrefix("description=") {
                let value = String(line.dropFirst("description=".count))
                records[index].description = value == "null" ? nil : value
            }
        }
        return records
    }
}

// MARK: - System memory pressure

/// `am memory-factor set` (API 31+): overrides the memory level
/// ActivityManagerService computes. The device cannot say whether an
/// override is active — `show` prints the override or the computed level
/// alike — so Device Hub Pro tracks what it set and resets on connect and
/// disconnect. It changes service-restart backoff, process stats and the
/// oom-adj "memory normal" flag everywhere; whether apps also get
/// `onTrimMemory` depends on the release (`trimsAppsMaximumAPI`).
public enum MemoryFactor: String, CaseIterable, Identifiable, Sendable {
    case normal = "NORMAL"
    case moderate = "MODERATE"
    case low = "LOW"
    case critical = "CRITICAL"

    public var id: String { rawValue }
    public static let minimumAPI = 31

    /// The last release on which a factor above NORMAL also trims apps.
    /// Through Android 13, `AppProfiler.updateLowMemStateLSP` takes the
    /// override as its memory factor and sends `onTrimMemory`: RUNNING_
    /// MODERATE/LOW/CRITICAL to processes in use, BACKGROUND to COMPLETE to
    /// cached ones (android-12.0.0_r1, android-13.0.0_r1). Android 14 keeps
    /// that code behind `use_modern_trim`, which defaults to true
    /// (`ActivityManagerConstants.DEFAULT_USE_MODERN_TRIM`, android-14.0.0_r1)
    /// and returns before it; Android 15 removed it (android-15.0.0_r1).
    public static let trimsAppsMaximumAPI = 33

    public var label: String { rawValue.capitalized }

    /// `am memory-factor show`'s answer (`NORMAL`).
    public static func parse(_ text: String) -> MemoryFactor? {
        MemoryFactor(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    }
}

// MARK: - Probe

/// The App conditions rows' reads in one `adb shell` round trip: the API
/// level, the target's pids, its main process record, its newest exit
/// record (API 30+) and the memory level (API 31+). Without a target only
/// the API level and the memory level are read.
public struct AppConditionsSnapshot: Sendable, Equatable {
    public var apiLevel: Int?
    public var pids: [Int]
    public var process: AppProcessState?
    public var lastExit: ProcessExitRecord?
    public var memoryFactor: MemoryFactor?

    public init(
        apiLevel: Int? = nil,
        pids: [Int] = [],
        process: AppProcessState? = nil,
        lastExit: ProcessExitRecord? = nil,
        memoryFactor: MemoryFactor? = nil
    ) {
        self.apiLevel = apiLevel
        self.pids = pids
        self.process = process
        self.lastExit = lastExit
        self.memoryFactor = memoryFactor
    }

    /// The main process while it runs: its dump record, trusted only while
    /// `pidof` still lists its pid. AMS keeps a crashed process's record
    /// for a moment after the kernel reaped it.
    public var runningProcess: AppProcessState? {
        guard let process, let pid = process.pid, pids.contains(pid) else { return nil }
        return process
    }

    /// Whether any process of the package runs (`pidof`).
    public var isRunning: Bool { !pids.isEmpty }

    /// The main process's pid, else the first `pidof` pid.
    public var mainPid: Int? { runningProcess?.pid ?? pids.first }

    enum Section: String, CaseIterable {
        case api
        case pids
        case process
        case exit
        case memoryFactor = "memory-factor"

        var marker: String { "@@devicehubpro:app:\(rawValue)" }
    }

    /// The probe for `package` (nil: device-wide reads only). The package
    /// is shell-quoted; every marker starts with `@@devicehubpro:app:`.
    public static func probeScript(package: String?) -> String {
        func mark(_ section: Section) -> String { "echo \(section.marker)" }
        var lines = [mark(.api), "api=$(getprop ro.build.version.sdk)", "echo $api"]
        if let package {
            let quoted = AdbClient.shellQuoted(package)
            lines += [
                mark(.pids), "pidof \(quoted)",
                mark(.process),
                "dumpsys activity processes \(quoted) 2>/dev/null | grep -E '\(processLinesPattern)'",
                mark(.exit),
                "if [ \"$api\" -ge \(ProcessExitRecord.minimumAPI) ]; then dumpsys activity exit-info \(quoted) 2>/dev/null"
                    + " | grep -E '^ +(ApplicationExitInfo #|timestamp=|process=|description=)' | head -n 4; fi",
            ]
        }
        lines += [
            mark(.memoryFactor),
            "if [ \"$api\" -ge \(MemoryFactor.minimumAPI) ]; then am memory-factor show 2>&1; fi",
            "true",
        ]
        return lines.joined(separator: "; ")
    }

    /// The process section's `grep -E` pattern: the `*APP*` headers, the
    /// `pid=`, `trimMemoryLevel=` and `curProcState=` lines, and the
    /// freezer's `isFrozen=` wherever its line starts. The freezer line
    /// (`ProcessCachedOptimizerRecord.dump`) starts with `isFreezeExempt=`
    /// on API 31–32, with `hasPendingCompaction=` on API 33–36 (a missing
    /// newline joins the two), and with `isPendingFreeze=` on API 37.
    static let processLinesPattern = #"^  \*APP\*|^    (pid|trimMemoryLevel|curProcState)=|isFrozen="#

    public static func parse(_ output: String, package: String?) -> AppConditionsSnapshot {
        let sections = ConditionsText.sections(from: output, markers: Section.allCases.map { ($0, $0.marker) })
        var snapshot = AppConditionsSnapshot()
        snapshot.apiLevel = sections[.api].flatMap { Int($0) }
        snapshot.pids = (sections[.pids] ?? "")
            .split(whereSeparator: { $0 == " " || $0.isNewline })
            .compactMap { Int($0) }
        if let package, let dump = sections[.process] {
            snapshot.process = AppProcessState.parse(dump, package: package)
        }
        snapshot.lastExit = sections[.exit].flatMap { ProcessExitRecord.parse($0).first }
        snapshot.memoryFactor = sections[.memoryFactor].flatMap(MemoryFactor.parse)
        return snapshot
    }

    /// The package of the resumed activity: the `topResumedActivity=` line
    /// (API 29+) or `mResumedActivity:` (older) of `dumpsys activity
    /// activities`, `ActivityRecord{45739545 u0 com.android.settings/.Home t315}`.
    public static func foregroundPackage(fromActivities text: String) -> String? {
        for rawLine in text.components(separatedBy: .newlines)
        where rawLine.contains("topResumedActivity=") || rawLine.contains("mResumedActivity") {
            guard let record = ConditionsText.braced(after: "ActivityRecord{", in: rawLine[...]) else { continue }
            if let component = record.split(separator: " ").first(where: { $0.contains("/") }) {
                return component.split(separator: "/").first.map(String.init)
            }
        }
        return nil
    }

    /// The package's last exit records (up to ten, newest first): a kill or
    /// crash is confirmed by the record of the pid it ended, since one
    /// command can end several processes of a package (`:remote`, …) and
    /// the probe keeps only the newest record.
    public static func exitRecordsScript(package: String) -> String {
        "dumpsys activity exit-info \(AdbClient.shellQuoted(package)) 2>/dev/null"
            + " | grep -E '^ +(ApplicationExitInfo #|timestamp=|process=|description=)' | head -n 40; true"
    }

    /// The foreground probe: the resumed-activity lines only.
    public static let foregroundScript =
        "dumpsys activity activities 2>/dev/null | grep -E 'topResumedActivity=|mResumedActivity' | head -n 2; true"
}

/// Why an App conditions command was refused, from the activity manager's
/// own message (`java.lang.IllegalArgumentException: Unable to set a higher
/// trim level than current level` → "Unable to set a higher trim level than
/// current level").
public enum AppConditionsError: Error, Equatable, CustomStringConvertible {
    case refused(command: String, reason: String)

    public var description: String {
        switch self {
        case .refused(let command, let reason):
            return "\(command) was refused: \(reason)"
        }
    }

    /// The activity manager's reason in a failed `am` command's stderr: the
    /// exception message, or an `Error:` line.
    public static func reason(fromOutput output: String) -> String? {
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Error:") {
                return line.dropFirst("Error:".count).trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("java."), let colon = line.range(of: "Exception: ") {
                return String(line[colon.upperBound...])
            }
        }
        return nil
    }
}
