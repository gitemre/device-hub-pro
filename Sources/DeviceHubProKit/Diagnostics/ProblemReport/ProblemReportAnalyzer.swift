import Foundation

/// A known cause the analyzer found in a report, with what to do about it.
public struct ProblemFinding: Codable, Sendable, Equatable {
    /// How sure the analyzer is.
    public enum Confidence: String, Codable, Sendable, Equatable {
        /// The report holds the symptom and the cause.
        case confirmed
        /// The report holds the cause, or the symptom, but not both.
        case likely
    }

    public var id: String
    public var title: String
    public var explanation: String
    public var fix: String
    /// What in the report made the rule match, one line each.
    public var evidence: [String]
    /// The JSON key paths the rule reads (`android.consoleTokenFile.state`,
    /// `android.runningEmulators[].console.outcome`).
    public var evidenceKeys: [String]
    public var confidence: Confidence

    public init(
        id: String,
        title: String,
        explanation: String,
        fix: String,
        evidence: [String],
        evidenceKeys: [String] = [],
        confidence: Confidence
    ) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.fix = fix
        self.evidence = evidence
        self.evidenceKeys = evidenceKeys
        self.confidence = confidence
    }
}

/// One known cause: its text (static) and the test that finds it in a report
/// (which builds the evidence lines).
public struct ProblemRule: Sendable {
    public let id: String
    public let title: String
    public let explanation: String
    public let fix: String
    /// The JSON key paths `evaluate` reads.
    public let evidenceKeys: [String]
    /// Lower is shown first.
    public let priority: Int
    /// Rule ids that, when they match too, make this one redundant.
    public let suppressedBy: [String]
    public let evaluate: @Sendable (ProblemReport) -> (evidence: [String], confidence: ProblemFinding.Confidence)?
}

/// Reads a (scrubbed) report for the causes the maintainers have met, so the
/// app tells the user before they file an issue and `dhp-report` tells a
/// maintainer what happened. To add a rule when an issue shows a new cause:
/// append it to `rules` with a test from a real fixture.
public enum ProblemReportAnalyzer {
    /// The findings, most important first (priority, then confirmed before
    /// likely). A finding is dropped when a rule it is suppressed by also
    /// matched.
    public static func findings(for report: ProblemReport) -> [ProblemFinding] {
        var matched: [(rule: ProblemRule, evidence: [String], confidence: ProblemFinding.Confidence)] = []
        for rule in rules {
            if let hit = rule.evaluate(report) {
                matched.append((rule, hit.evidence, hit.confidence))
            }
        }
        let ids = Set(matched.map(\.rule.id))
        return matched
            .filter { entry in !entry.rule.suppressedBy.contains(where: ids.contains) }
            .sorted { lhs, rhs in
                if lhs.rule.priority != rhs.rule.priority { return lhs.rule.priority < rhs.rule.priority }
                return lhs.confidence == .confirmed && rhs.confidence != .confirmed
            }
            .map { entry in
                ProblemFinding(
                    id: entry.rule.id,
                    title: entry.rule.title,
                    explanation: entry.rule.explanation,
                    fix: entry.rule.fix,
                    evidence: entry.evidence,
                    evidenceKeys: entry.rule.evidenceKeys,
                    confidence: entry.confidence
                )
            }
    }

    // MARK: Rules

    public static let rules: [ProblemRule] = coreRules + logRules

    private static let noHypervisorFix = "Run the emulator on a Mac directly, not inside a virtual machine, or in one that passes virtualization through."
    private static let systemImageFix = "Download it again from the OS Version menu of the New Emulator sheet, or recreate the emulator."
    private static let oldToolsFix = "Update the Android SDK Command-line Tools to 20.0 or later and recreate the emulator."

    private static let coreRules: [ProblemRule] = [
        ProblemRule(
            id: "no-hypervisor",
            title: "Hardware virtualization isn\u{2019}t available",
            explanation: EmulatorStartFailure.Cause.noHypervisor.sentence,
            fix: noHypervisorFix,
            evidenceKeys: ["mac.hypervisorSupported", "mac.insideVirtualMachine"],
            priority: 1,
            suppressedBy: []
        ) { report in
            guard report.mac.hypervisorSupported == false else { return nil }
            var evidence = ["kern.hv_support: 0 (the hypervisor isn\u{2019}t available)"]
            if report.mac.insideVirtualMachine == true {
                evidence.append("kern.hv_vmm_present: 1 (this Mac is a virtual machine)")
            }
            return (evidence, .confirmed)
        },

        ProblemRule(
            id: "adb-not-found",
            title: "Device Hub Pro can\u{2019}t find adb",
            explanation: "No adb was found in the Android SDK folders, on the PATH Device Hub Pro sees, or in Homebrew.",
            fix: "Choose Set Up Android Tools in the sidebar, or Locate SDK\u{2026} if the SDK is somewhere else.",
            evidenceKeys: ["android.adb.path", "android.sdkRoots[].exists"],
            priority: 5,
            suppressedBy: []
        ) { report in
            guard report.android.adb.path == nil else { return nil }
            let looked = report.android.sdkRoots.map { "\($0.path)\($0.exists ? "" : " (missing)")" }
            return (["No adb path; looked in: " + (looked.isEmpty ? "no SDK folder" : looked.joined(separator: ", "))], .confirmed)
        },

        ProblemRule(
            id: "console-token-empty",
            title: "The emulator console\u{2019}s token file is empty",
            explanation: "~/.emulator_console_auth_token is empty, which turns the emulator console\u{2019}s authentication off, and then adb drops every answer of the console (`adb emu` prints nothing). Device Hub Pro then can\u{2019}t tell which emulator is which: a started emulator never \u{201C}comes online\u{201D}, and its controls and screen stop answering.",
            fix: "Update Device Hub Pro to \(consoleTokenHandledFrom) or later, which talks to the console itself. Or quit the emulators, delete ~/.emulator_console_auth_token (the emulator writes a new one when it starts), then start the emulator again.",
            evidenceKeys: [
                "app.version", "app.kind",
                "android.consoleTokenFile.state",
                "android.runningEmulators[].console.outcome",
                "android.runningEmulators[].guestAvdName.value",
                "android.runningEmulators[].discovery",
            ],
            priority: 10,
            suppressedBy: []
        ) { report in
            let file = report.android.consoleTokenFile
            guard file.state == .empty || file.state == .blank else { return nil }
            // From \(consoleTokenHandledFrom) the app reads the console
            // itself, so an empty file only breaks `adb emu` (which the report
            // still asks, and which then prints nothing). A development build
            // is built from sources that have the fix.
            guard !handlesEmptyConsoleToken(report.app) else { return nil }
            // A console that answered refutes the cause: an empty token file is
            // also how the emulator\u{2019}s console authentication is turned
            // off on purpose, and then nothing is wrong.
            guard !report.android.runningEmulators.contains(where: { $0.console.outcome == .answered }) else { return nil }
            var evidence = ["\(file.path): \(file.state.rawValue) (\(file.bytes ?? 0) bytes)"]
            var confirmed = false
            for emulator in report.android.runningEmulators where emulator.console.outcome == .emptyAnswer {
                confirmed = true
                var line = "\(label(of: emulator)): `adb emu avd name` printed nothing"
                if emulator.guestAvdName.outcome == .answered, let name = emulator.guestAvdName.value {
                    line += "; Android names its AVD \(name)"
                }
                if let discovery = emulator.discovery, discovery.found {
                    line += "; discovery file present (gRPC token: \(discovery.hasGrpcToken ? "yes" : "no"))"
                }
                evidence.append(line)
            }
            return (evidence, confirmed ? .confirmed : .likely)
        },

        ProblemRule(
            id: "avd-target-android-0",
            title: "An emulator was created by old Android tools",
            explanation: "Its target says Android version 0 (target=android-0), which Android SDK Command-line Tools 19.0 and older write for Android 17 images. The emulator then runs Android without the Mac\u{2019}s hypervisor, which is slow or fails with \u{201C}mprotect failed\u{201D}.",
            fix: "Update the Android SDK Command-line Tools to 20.0 or later, then recreate the emulator. Device Hub Pro also corrects the target when it starts the emulator.",
            evidenceKeys: [
                "android.avds[].target", "android.avds[].configTarget", "android.avds[].imageAPI",
                "emulatorLogs[].lines",
            ],
            priority: 12,
            suppressedBy: []
        ) { report in
            let causes = logCauses(of: report)
            var evidence: [String] = []
            var confirmed = false
            for avd in report.android.avds {
                let target = nonEmpty(avd.target) ?? nonEmpty(avd.configTarget)
                guard target == EmulatorPreflight.brokenTarget || (target == nil && avd.imageAPI != nil) else { continue }
                var line = "\(avd.name): target=\(target ?? "none")"
                if let api = avd.imageAPI { line += ", its system image is API \(api)" }
                if causes.contains(where: { $0.avd == avd.name && ($0.cause == .hvfNotEnabled || $0.cause == .mprotectDenied) }) {
                    confirmed = true
                    line += "; its log says the emulator ran without the hypervisor"
                }
                evidence.append(line)
            }
            return evidence.isEmpty ? nil : (evidence, confirmed ? .confirmed : .likely)
        },

        ProblemRule(
            id: "cmdline-tools-old",
            title: "The Android SDK Command-line Tools are old",
            explanation: "Device Hub Pro creates emulators with this avdmanager. Versions 19.0 and older write Android 17 emulators with target android-0.",
            fix: "Install Command-line Tools 20.0 or later as cmdline-tools/latest (Android Studio \u{25B8} SDK Manager \u{25B8} SDK Tools, or sdkmanager \u{201C}cmdline-tools;latest\u{201D}).",
            evidenceKeys: ["android.avdmanager.path", "android.avdmanager.version", "android.sdkRoots[].cmdlineTools"],
            priority: 13,
            suppressedBy: []
        ) { report in
            guard let tool = report.android.avdmanager, let major = cmdlineToolsMajor(of: tool), major <= 19 else { return nil }
            let folder = cmdlineToolsFolder(of: tool)
            var line = "avdmanager: \(tool.path)"
            if let version = tool.version { line += " (cmdline-tools \(version))" }
            var evidence = [line]
            if let folder, folder != "latest",
               let root = report.android.sdkRoots.first(where: { tool.path.hasPrefix($0.path + "/") }),
               !root.cmdlineTools.contains(where: { $0.folder == "latest" }) {
                let installed = root.cmdlineTools.map(\.folder).joined(separator: ", ")
                evidence.append("cmdline-tools/latest is missing in \(root.path) (installed: \(installed)), so the oldest revision, \(folder), is used")
            }
            return (evidence, .likely)
        },

        ProblemRule(
            id: "x86-image",
            title: "An emulator uses an Intel system image",
            explanation: "Intel (x86) system images can\u{2019}t run on a Mac with Apple silicon.",
            fix: "Create the emulator again with an ARM 64 (arm64-v8a) system image.",
            evidenceKeys: ["mac.appleSilicon", "android.avds[].abi"],
            priority: 14,
            suppressedBy: []
        ) { report in
            guard report.mac.appleSilicon else { return nil }
            let evidence = report.android.avds.compactMap { avd -> String? in
                guard let abi = avd.abi, abi.hasPrefix("x86") else { return nil }
                return "\(avd.name): abi \(abi) on a Mac with Apple silicon"
            }
            return evidence.isEmpty ? nil : (evidence, .confirmed)
        },

        ProblemRule(
            id: "system-image-missing",
            title: "An emulator\u{2019}s system image is missing or incomplete",
            explanation: "The system image it needs isn\u{2019}t fully on this Mac: a download that didn\u{2019}t finish, or an SDK folder that moved.",
            fix: systemImageFix,
            evidenceKeys: ["android.avds[].image", "android.avds[].imageSysdir", "android.avds[].preflightProblem"],
            priority: 15,
            suppressedBy: []
        ) { report in
            let evidence = report.android.avds.compactMap { avd -> String? in
                guard avd.image == .missing || avd.image == .incomplete else { return nil }
                return "\(avd.name): system image \(avd.image.rawValue)" + (avd.imageSysdir.map { " (\($0))" } ?? "")
            }
            return evidence.isEmpty ? nil : (evidence, .confirmed)
        },

        ProblemRule(
            id: "low-disk-space",
            title: "Little free disk space",
            explanation: "An emulator needs several GB for its data and snapshots.",
            fix: "Free some space on the disk that holds your emulators (~/.android/avd), for example by deleting emulators you no longer use.",
            evidenceKeys: ["mac.freeSpace"],
            priority: 16,
            suppressedBy: []
        ) { report in
            let evidence = report.mac.freeSpace.compactMap { space -> String? in
                guard space.role == "home" || space.role == "avdHome", space.freeGB < 10 else { return nil }
                return "\(space.role): \(space.freeGB) GB free"
            }
            return evidence.isEmpty ? nil : (evidence, .likely)
        },

        ProblemRule(
            id: "console-silent",
            title: "An emulator\u{2019}s console doesn\u{2019}t answer",
            explanation: "adb lists the emulator, but its console (adb emu) didn\u{2019}t answer. Device Hub Pro reads the emulator\u{2019}s name and controls through it, so the emulator looks stuck.",
            fix: "Restart the emulator. If it keeps happening, quit other tools that use adb and check that ~/.emulator_console_auth_token belongs to you.",
            evidenceKeys: [
                "android.runningEmulators[].adbState", "android.runningEmulators[].console",
                "android.consoleTokenFile.state",
            ],
            priority: 20,
            suppressedBy: ["console-token-empty"]
        ) { report in
            let token = report.android.consoleTokenFile.state
            guard token != .empty, token != .blank else { return nil }
            let silent: Set<ProblemReport.ConsoleOutcome> = [.emptyAnswer, .ko, .failed, .timedOut]
            let evidence = report.android.runningEmulators.compactMap { emulator -> String? in
                guard emulator.adbState == "device", silent.contains(emulator.console.outcome) else { return nil }
                return "\(label(of: emulator)): adb lists it as device; `adb emu avd name` \(describe(emulator.console))"
            }
            return evidence.isEmpty ? nil : (evidence, .likely)
        },

        ProblemRule(
            id: "adb-server-other-copy",
            title: "Another adb runs the adb server",
            explanation: "The adb server was started by a different adb than the one Device Hub Pro uses. When their versions differ, each restarts the server the other started, and devices drop off.",
            fix: "Use one Android SDK for all tools, or update platform-tools so every copy is the same version.",
            evidenceKeys: ["android.adb.path", "android.adb.version", "android.adb.server"],
            priority: 25,
            suppressedBy: []
        ) { report in
            let adb = report.android.adb
            let server = adb.server
            guard server.running, server.sameAsApp == false else { return nil }
            if let serverVersion = server.version, let appVersion = adb.version, serverVersion == appVersion { return nil }
            return ([
                "adb server: \(server.path ?? "unknown path") (\(server.version ?? "unknown version"))",
                "Device Hub Pro\u{2019}s adb: \(adb.path ?? "unknown path") (\(adb.version ?? "unknown version"))",
            ], .likely)
        },

        ProblemRule(
            id: "emulator-not-in-adb",
            title: "adb doesn\u{2019}t list a running emulator",
            explanation: "The emulator process runs, but the adb server doesn\u{2019}t list it, so Device Hub Pro can\u{2019}t reach it. This happens when the server was started by another adb, or restarted while the emulator ran.",
            fix: "Restart the adb server with the adb shown below (`adb kill-server`, then `adb start-server`). If the emulator still doesn\u{2019}t appear, restart it.",
            evidenceKeys: [
                "android.runningEmulators[].adbState", "android.runningEmulators[].processAlive",
                "android.adb.server.queried", "android.devicesSource",
            ],
            priority: 30,
            suppressedBy: []
        ) { report in
            let android = report.android
            // The device list must have been read, or every emulator would look missing.
            guard android.adb.server.queried,
                  android.devicesSource == "adb devices -l" || android.devicesSource == "app inventory"
            else { return nil }
            let missing = android.runningEmulators.filter { $0.processAlive && $0.serial != nil && $0.adbState == nil }
            guard !missing.isEmpty else { return nil }
            var evidence = missing.map { "\(label(of: $0)): the process runs, adb doesn\u{2019}t list it" }
            evidence.append("Device Hub Pro\u{2019}s adb: \(android.adb.path ?? "unknown path")")
            return (evidence, .likely)
        },
    ]

    // MARK: Rules from the emulator's log

    /// One rule per `EmulatorStartFailure.Cause`, from the log tails. The
    /// sentence is the one the start-failure alert shows.
    private static let logRules: [ProblemRule] = {
        let table: [(cause: EmulatorStartFailure.Cause, id: String, priority: Int, title: String, fix: String, suppressedBy: [String], onlyWhenStopped: Bool)] = [
            (.noHypervisor, "log-no-hypervisor", 40, "Hardware virtualization isn\u{2019}t available", noHypervisorFix, ["no-hypervisor"], false),
            (.diskFull, "log-disk-full", 41, "Not enough free disk space",
             "Free some space on the disk that holds ~/.android/avd and start it again.", [], true),
            (.lockOrRunning, "log-lock", 42, "The emulator is already running or left a lock behind",
             "Stop it; if none is running, delete the .lock files in its AVD folder.", [], true),
            (.systemImageMissing, "log-system-image", 43, "The system image is missing or incomplete",
             systemImageFix, ["system-image-missing"], false),
            (.hvfNotEnabled, "log-hvf-not-enabled", 44, "The emulator ran without the hypervisor",
             oldToolsFix, ["avd-target-android-0"], false),
            (.mprotectDenied, "log-mprotect-denied", 45, "macOS refused the emulator\u{2019}s software mode",
             oldToolsFix, ["avd-target-android-0"], false),
            (.graphics, "log-graphics", 46, "The emulator couldn\u{2019}t start its graphics",
             "Try again; if it keeps failing, update the emulator package and macOS.", [], true),
        ]
        return table.map { entry in
            ProblemRule(
                id: entry.id,
                title: entry.title,
                explanation: entry.cause.sentence,
                fix: entry.fix,
                evidenceKeys: ["emulatorLogs[].lines"],
                priority: entry.priority,
                suppressedBy: entry.suppressedBy
            ) { report in
                let running = Set(report.android.runningEmulators.map(\.avd))
                let evidence = logCauses(of: report).compactMap { found -> String? in
                    guard found.cause == entry.cause else { return nil }
                    if entry.onlyWhenStopped, running.contains(found.avd) { return nil }
                    return "emulator log of \(found.avd) (\(dateText(found.tail.modified))): \(found.line)"
                }
                return evidence.isEmpty ? nil : (evidence, .likely)
            }
        }
    }()

    // MARK: Helpers

    private struct LogCause {
        let avd: String
        let cause: EmulatorStartFailure.Cause
        let tail: ProblemReport.LogTail
        /// The last line worth reading, cut for the evidence.
        let line: String
    }

    /// The cause each log tail names, matched on the lines worth reading
    /// (`EmulatorStartFailure.significantLines`: a healthy log's INFO line
    /// `vulkan_mode_selected:host` is not a graphics error).
    private static func logCauses(of report: ProblemReport) -> [LogCause] {
        report.emulatorLogs.compactMap { tail in
            let lines = EmulatorStartFailure.significantLines(from: tail.lines.joined(separator: "\n"))
            guard let cause = EmulatorStartFailure.cause(in: lines.joined(separator: "\n")) else { return nil }
            let last = (lines.last ?? "").trimmingCharacters(in: .whitespaces)
            return LogCause(avd: tail.avd, cause: cause, tail: tail, line: String(last.prefix(160)))
        }
    }

    /// The first release that talks to the emulator console itself rather
    /// than through `adb emu`, so an empty console token file no longer
    /// stops it.
    static let consoleTokenHandledFrom = "1.1.2"

    /// Whether the app that made the report reads the console itself: a
    /// release from `consoleTokenHandledFrom` on, or a development build.
    /// False for the CLI, which says nothing about the user's app.
    static func handlesEmptyConsoleToken(_ app: ProblemReport.AppInfo) -> Bool {
        switch app.kind {
        case .development: return true
        case .cli: return false
        case .packaged:
            guard let version = app.version, EmulatorVersion.components(version) != nil else { return false }
            return !EmulatorVersion.isOlder(version, than: consoleTokenHandledFrom)
        }
    }

    private static func label(of emulator: ProblemReport.RunningEmulator) -> String {
        emulator.serial.map { "\($0) (\(emulator.avd))" } ?? emulator.avd
    }

    private static func describe(_ probe: ProblemReport.ConsoleProbe) -> String {
        switch probe.outcome {
        case .answered: return "answered"
        case .emptyAnswer: return "printed nothing"
        case .ko: return "answered KO"
        case .failed: return "failed" + (probe.exitCode.map { " (exit \($0))" } ?? "")
        case .timedOut: return "didn\u{2019}t answer in time"
        case .skipped: return "was not asked"
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }

    /// "cmdline-tools/<folder>/bin/avdmanager" → the folder.
    private static func cmdlineToolsFolder(of tool: ProblemReport.ToolInfo) -> String? {
        let components = tool.path.split(separator: "/").map(String.init)
        guard let index = components.lastIndex(of: "cmdline-tools"), index + 1 < components.count else { return nil }
        return components[index + 1]
    }

    /// The major version of the tool's package: its revision, else its folder
    /// name when that is a number (`latest` says nothing).
    private static func cmdlineToolsMajor(of tool: ProblemReport.ToolInfo) -> Int? {
        let text = tool.version ?? cmdlineToolsFolder(of: tool) ?? ""
        return Int(text.split(separator: ".").first ?? "")
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return formatter.string(from: date)
    }
}
