import Foundation

/// Renders a (scrubbed) report: the Markdown a user pastes into an issue, and
/// the plain text `dhp-report` prints.
///
/// The Markdown carries the whole report as one JSON block between
/// `<!-- dhp-report v1 -->` markers (`ProblemReportParser` finds it again,
/// whatever the user pasted it into). The summary above the JSON and the known
/// problems are derived from the report and the findings, never the other way
/// round.
public enum ProblemReportRenderer {
    /// The most UTF-8 bytes the Markdown takes, leaving room for the form's
    /// other fields under GitHub's 65,536-character body limit.
    public static let maxBytes = 40_000

    /// The Markdown for `report`, trimmed to `maxBytes` (see `fitted`).
    public static func markdown(_ report: ProblemReport, findings: [ProblemFinding]) -> String {
        fitted(report, findings: findings).markdown
    }

    /// The Markdown and the report it carries. While the Markdown is over
    /// `maxBytes` the next step below is applied, and what it cut is recorded
    /// in `collection.truncated`: the JSON is never cut mid-way.
    ///
    /// 1. log tails to 30 lines; 2. to two AVDs; 3. to 15 lines;
    /// 4. recent-problem details to 1,000 characters each; 5. recent problems
    /// to ten; 6. log tails dropped; 7. recent-problem details dropped;
    /// 8. AVDs to the running ones and those a finding names (ten at most);
    /// 9. crash reports dropped.
    public static func fitted(_ report: ProblemReport, findings: [ProblemFinding]) -> (report: ProblemReport, markdown: String) {
        var report = report
        var text = render(report, findings: findings)
        for step in trimSteps(findings: findings) {
            guard text.utf8.count > maxBytes else { break }
            guard let description = step(&report) else { continue }
            report.collection.truncated.append(description)
            text = render(report, findings: findings)
        }
        return (report, text)
    }

    private static func trimSteps(findings: [ProblemFinding]) -> [(inout ProblemReport) -> String?] {
        func cutLogLines(to count: Int) -> (inout ProblemReport) -> String? {
            return { report in
                var changed = false
                for index in report.emulatorLogs.indices where report.emulatorLogs[index].lines.count > count {
                    report.emulatorLogs[index].lines = Array(report.emulatorLogs[index].lines.suffix(count))
                    report.emulatorLogs[index].omittedLines = true
                    changed = true
                }
                return changed ? "emulator logs cut to \(count) lines" : nil
            }
        }
        return [
            cutLogLines(to: 30),
            { report in
                guard report.emulatorLogs.count > 2 else { return nil }
                report.emulatorLogs = Array(report.emulatorLogs.prefix(2))
                return "emulator logs cut to 2 emulators"
            },
            cutLogLines(to: 15),
            { report in
                var changed = false
                for index in report.recentProblems.indices {
                    guard let details = report.recentProblems[index].details else { continue }
                    var kept: [String] = []
                    var total = 0
                    for line in details {
                        if total + line.count > 1_000 {
                            kept.append(String(line.prefix(max(0, 1_000 - total))) + "\u{2026}")
                            break
                        }
                        kept.append(line)
                        total += line.count
                    }
                    if kept != details {
                        report.recentProblems[index].details = kept
                        changed = true
                    }
                }
                return changed ? "recent problem details cut to 1,000 characters" : nil
            },
            { report in
                guard report.recentProblems.count > 10 else { return nil }
                report.recentProblems = Array(report.recentProblems.prefix(10))
                return "recent problems cut to 10"
            },
            { report in
                guard !report.emulatorLogs.isEmpty else { return nil }
                report.emulatorLogs = []
                return "emulator logs left out"
            },
            { report in
                guard report.recentProblems.contains(where: { $0.details != nil }) else { return nil }
                for index in report.recentProblems.indices { report.recentProblems[index].details = nil }
                return "recent problem details left out"
            },
            { report in
                let named = findings.flatMap(\.evidence).joined(separator: "\n")
                let kept = report.android.avds.filter { $0.running || named.contains($0.name) }
                let trimmed = Array(kept.prefix(10))
                guard trimmed.count < report.android.avds.count else { return nil }
                report.android.avds = trimmed
                return "AVDs cut to the running ones and those a finding names"
            },
            { report in
                guard !report.crashReports.isEmpty else { return nil }
                report.crashReports = []
                return "crash reports left out"
            },
        ]
    }

    // MARK: Markdown

    private static func render(_ report: ProblemReport, findings: [ProblemFinding]) -> String {
        var lines: [String] = []
        lines.append("<!-- dhp-report v\(ProblemReport.schemaVersion) -->")
        lines.append("**Device Hub Pro problem report** `\(report.id)` \u{00B7} \(dateText(report.createdAt))")
        lines.append("")
        if let subject = report.subject {
            for line in subject.message.split(whereSeparator: \.isNewline) {
                lines.append("> " + MarkdownText.text(String(line)))
            }
            lines.append("")
        }

        lines.append("- **App:** " + appSummary(report))
        lines.append("- **Mac:** " + macSummary(report))
        lines.append("- **Android:** " + androidSummary(report))
        lines.append("- **Emulators:** " + emulatorsSummary(report))
        lines.append("- **Phones:** " + phonesSummary(report))
        lines.append("- **Xcode:** " + xcodeSummary(report))
        for foldable in report.windows.compactMap(\.foldable) {
            lines.append("- **\(MarkdownText.text(foldable.model)):** " + foldableSummary(foldable))
        }
        lines.append("- **Recent problems:** " + recentProblemsSummary(report))
        lines.append("")

        lines.append("**Known problems**")
        if findings.isEmpty {
            lines.append("None of the known problems matched.")
        } else {
            for finding in findings {
                lines.append("- **\(finding.title)** (\(finding.confidence.rawValue)). \(finding.explanation) *Fix:* \(finding.fix)")
            }
        }
        lines.append("")

        if !report.collection.truncated.isEmpty {
            lines.append("_Trimmed to fit an issue: \(report.collection.truncated.joined(separator: "; "))._")
            lines.append("")
        }

        // A backtick only occurs inside a JSON string, where ``` says the
        // same, so the fence below can never close early.
        let json = ((try? report.jsonText()) ?? "{}").replacingOccurrences(of: "`", with: "\\u0060")
        lines.append("<details><summary>Full report (JSON, schema \(ProblemReport.schemaVersion))</summary>")
        lines.append("")
        lines.append("```json")
        lines.append(json)
        lines.append("```")
        lines.append("")
        lines.append("</details>")
        lines.append("<!-- /dhp-report v\(ProblemReport.schemaVersion) -->")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appSummary(_ report: ProblemReport) -> String {
        let app = report.app
        var parts: [String] = []
        switch app.kind {
        case .cli:
            parts.append("dhp-report" + (app.version.map { " " + MarkdownText.text($0) } ?? ""))
        case .packaged, .development:
            var version = app.version.map(MarkdownText.text) ?? "unknown version"
            if let build = app.build { version += " (\(MarkdownText.text(build)))" }
            parts.append(version)
            parts.append(app.kind == .packaged ? "packaged" : "development build")
        }
        switch app.location {
        case .applications: parts.append("in /Applications")
        case .userApplications: parts.append("in ~/Applications")
        case .translocated: parts.append("run from a quarantined copy (App Translocation)")
        case .diskImage: parts.append("run from a disk image")
        case .other: parts.append("in another folder")
        case nil: break
        }
        if app.quarantined == true { parts.append("quarantined") }
        if !app.environmentFlags.isEmpty {
            parts.append("variables " + app.environmentFlags.map { MarkdownText.code($0) }.joined(separator: " "))
        }
        return parts.joined(separator: ", ")
    }

    private static func macSummary(_ report: ProblemReport) -> String {
        let mac = report.mac
        var parts = ["macOS " + MarkdownText.text(mac.macOS) + (mac.build.map { " (\(MarkdownText.text($0)))" } ?? "")]
        if let model = mac.model { parts.append(MarkdownText.text(model)) }
        if let chip = mac.chip { parts.append(MarkdownText.text(chip)) }
        if let memory = mac.memoryGB { parts.append("\(memory) GB") }
        if mac.translated { parts.append("running translated (Rosetta)") }
        if mac.insideVirtualMachine == true { parts.append("virtual machine") }
        switch mac.hypervisorSupported {
        case true?: parts.append("hypervisor available")
        case false?: parts.append("no hypervisor")
        case nil: break
        }
        if let home = mac.freeSpace.first(where: { $0.role == "home" }) { parts.append("\(home.freeGB) GB free") }
        return parts.joined(separator: " \u{00B7} ")
    }

    private static func androidSummary(_ report: ProblemReport) -> String {
        let android = report.android
        var parts: [String] = []
        if android.adb.path == nil {
            parts.append("adb not found")
        } else {
            var adb = "adb " + (android.adb.version.map(MarkdownText.text) ?? "unknown version")
            if android.adb.server.running {
                switch android.adb.server.sameAsApp {
                case true?: adb += " (runs the server)"
                case false?: adb += " (another adb runs the server)"
                case nil: break
                }
            } else {
                adb += " (no server running)"
            }
            parts.append(adb)
        }
        if let emulator = android.emulator {
            parts.append("emulator " + (emulator.version.map(MarkdownText.text) ?? "unknown version"))
        } else {
            parts.append("no emulator")
        }
        // The Command-line Tools Device Hub Pro creates emulators with: the
        // avdmanager's folder, else the first the SDK folders hold.
        var tools: (folder: String?, version: String?)?
        if let tool = android.avdmanager {
            let components = tool.path.split(separator: "/").map(String.init)
            var folder: String?
            if let index = components.lastIndex(of: "cmdline-tools"), index + 1 < components.count {
                folder = components[index + 1]
            }
            tools = (folder, tool.version)
        } else if let first = android.sdkRoots.lazy.compactMap({ $0.cmdlineTools.first }).first {
            tools = (first.folder, first.version)
        }
        if let tools {
            parts.append(["cmdline-tools", tools.folder, tools.version].compactMap { $0 }.map(MarkdownText.text).joined(separator: " "))
        } else {
            parts.append("no cmdline-tools")
        }
        parts.append("console token file: " + tokenStateText(android.consoleTokenFile.state))
        return parts.joined(separator: " \u{00B7} ")
    }

    private static func emulatorsSummary(_ report: ProblemReport) -> String {
        let running = report.android.runningEmulators
        guard !running.isEmpty else {
            return "none running (\(report.android.avdHome.avdCount) AVDs)"
        }
        return running.map { emulator in
            var line = MarkdownText.code(emulator.avd)
            if let serial = emulator.serial { line += " on \(MarkdownText.code(serial))" }
            line += ": "
            var facts: [String] = []
            let listRead = !report.android.devicesSource.hasPrefix("not read")
            facts.append(emulator.adbState.map { "adb \(MarkdownText.text($0))" }
                ?? (listRead ? "adb doesn\u{2019}t list it" : "adb not asked"))
            switch emulator.console.outcome {
            case .answered: facts.append("console answered")
            case .emptyAnswer: facts.append("console gave no answer")
            case .ko: facts.append("console answered KO")
            case .failed: facts.append("console failed")
            case .timedOut: facts.append("console timed out")
            case .skipped: break
            }
            if emulator.guestAvdName.outcome == .answered, let name = emulator.guestAvdName.value {
                facts.append("Android says \(MarkdownText.code(name))")
            }
            if emulator.bootCompleted.outcome == .answered, let value = emulator.bootCompleted.value, value != "1" {
                facts.append("boot not completed")
            }
            return line + facts.joined(separator: ", ")
        }.joined(separator: "; ")
    }

    private static func phonesSummary(_ report: ProblemReport) -> String {
        let android = report.android
        if android.devicesSource.hasPrefix("not read") { return "not read" }
        guard !android.phones.isEmpty else { return "none" }
        let described = android.phones.map { phone -> String in
            let transports = phone.transports.map { transport -> String in
                switch transport {
                case "usb": return "USB"
                case "wifi": return "Wi-Fi"
                case "mdns": return "mDNS"
                default: return MarkdownText.text(transport)
                }
            }.joined(separator: "+")
            var text = "\(transports): " + MarkdownText.text(phone.model ?? phone.device ?? "unknown model")
            if let version = phone.androidVersion { text += ", Android " + MarkdownText.text(version) }
            if phone.state != "device" { text += ", " + MarkdownText.text(phone.state) }
            return text
        }
        return "\(android.phones.count) (" + described.joined(separator: "; ") + ")"
    }

    private static func xcodeSummary(_ report: ProblemReport) -> String {
        let apple = report.apple
        guard let version = apple.xcodeVersion else {
            return apple.developerDirectory == "Command Line Tools" ? "Command Line Tools only" : "not found"
        }
        var text = MarkdownText.text(version) + (apple.xcodeBuild.map { " (\(MarkdownText.text($0)))" } ?? "")
        if let tier = apple.tier { text += ", simulators " + MarkdownText.text(tier) }
        if apple.firstLaunchComplete == false { text += ", first launch pending" }
        return text
    }

    /// "105°, laptop, held landscape left, lit inner, shown inner, 3D
    /// turnable; read 3 s before: outer dark (0), inner screen (137), lit
    /// inner; screens stuck".
    static func foldableSummary(_ foldable: ProblemReport.FoldableInfo) -> String {
        var text = "\(Int(foldable.hingeAngle.rounded()))\u{00B0}, \(foldable.posture.rawValue), held \(foldable.held.rawValue)"
        text += ", lit \(foldable.litPanel.rawValue), shown " + (foldable.shownPanel?.rawValue ?? "none")
        text += ", " + foldable.view.rawValue
        if let read = foldable.lastRead {
            func panel(_ name: String, _ reading: ProblemReport.PanelReading?) -> String {
                reading.map { "\(name) \($0.content.rawValue) (\($0.grey))" } ?? "\(name) unread"
            }
            text += "; read \(read.secondsAgo) s before: " + panel("outer", read.outer) + ", " + panel("inner", read.inner)
            text += ", lit " + (read.lit?.rawValue ?? "untold")
        }
        if foldable.screensStuck { text += "; screens stuck" }
        return text
    }

    private static func recentProblemsSummary(_ report: ProblemReport) -> String {
        guard let newest = report.recentProblems.first else { return "none" }
        let seconds = max(0, Int(report.createdAt.timeIntervalSince(newest.at)))
        let age: String
        switch seconds {
        case ..<90: age = "\(seconds) s"
        case ..<5_400: age = "\(Int((Double(seconds) / 60).rounded())) min"
        case ..<172_800: age = "\(Int((Double(seconds) / 3600).rounded())) h"
        default: age = "\(seconds / 86_400) days"
        }
        return "\(report.recentProblems.count), newest \(age) before the report"
    }

    private static func tokenStateText(_ state: ProblemReport.TokenState) -> String {
        state == .notAFile ? "not a file" : state.rawValue
    }

    fileprivate static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return formatter.string(from: date)
    }

    // MARK: Plain text

    /// The report as plain text for a terminal: the header, the subject, the
    /// Mac and Android facts, each running emulator on a line (outcomes in
    /// capitals), the findings with their evidence, the key paths they read and
    /// the fix, what the app showed, the recent problems and the log tails.
    /// Findings the app did not show are marked new.
    public static func terminal(_ report: ProblemReport, findings: [ProblemFinding]) -> String {
        var lines: [String] = []
        lines.append("Device Hub Pro problem report \(report.id) (\(report.producer.rawValue), \(dateText(report.createdAt)))")
        if let subject = report.subject {
            lines.append("Subject: \(subject.message)")
            for line in subject.details ?? [] { lines.append("    \(line)") }
        }
        lines.append("App:      " + plain(appSummary(report)))
        lines.append("Mac:      " + plain(macSummary(report)))
        lines.append("Android:  " + plain(androidSummary(report)))
        lines.append("Apple:    " + plain(xcodeSummary(report)))
        for foldable in report.windows.compactMap(\.foldable) {
            lines.append("Foldable: \(foldable.model): " + foldableSummary(foldable))
        }
        let listRead = !report.android.devicesSource.hasPrefix("not read")
        lines.append("Devices:  " + (listRead ? "read from \(report.android.devicesSource)" : report.android.devicesSource))
        let adb = report.android.adb
        if adb.server.running {
            lines.append("adb server: \(adb.server.path ?? "unknown path") (\(adb.server.version ?? "unknown version")), "
                + (adb.server.queried ? "asked" : "not asked: \(adb.server.notQueriedBecause ?? "no reason given")"))
        } else {
            lines.append("adb server: not running" + (adb.server.notQueriedBecause.map { " (\($0))" } ?? ""))
        }

        lines.append("Emulators running: \(report.android.runningEmulators.count)")
        for emulator in report.android.runningEmulators {
            var parts = [emulator.serial ?? "(no serial)", emulator.avd]
            parts.append("adb=" + (emulator.adbState ?? (listRead ? "NOT LISTED" : "NOT ASKED")))
            parts.append("console=" + consoleText(emulator.console))
            parts.append("guest=" + propertyText(emulator.guestAvdName))
            parts.append("boot=" + propertyText(emulator.bootCompleted))
            if let discovery = emulator.discovery {
                parts.append(discovery.found ? "discovery=found(grpcToken=\(discovery.hasGrpcToken))" : "discovery=none")
            }
            lines.append("  " + parts.joined(separator: " "))
        }

        lines.append("")
        if findings.isEmpty {
            lines.append("No known problem matched.")
        } else {
            lines.append("Known problems (\(findings.count)):")
            let shown = Set(report.findingsShown)
            for finding in findings {
                let isNew = report.producer == .app && !shown.contains(finding.id)
                lines.append("  [\(finding.confidence.rawValue)] \(finding.title) (\(finding.id))" + (isNew ? " [new since the app\u{2019}s check]" : ""))
                lines.append("      \(finding.explanation)")
                for item in finding.evidence { lines.append("      evidence: \(item)") }
                if !finding.evidenceKeys.isEmpty { lines.append("      keys: " + finding.evidenceKeys.joined(separator: ", ")) }
                lines.append("      fix: \(finding.fix)")
            }
        }
        if report.producer == .app {
            lines.append("The app showed: " + (report.findingsShown.isEmpty ? "no known problem" : report.findingsShown.joined(separator: ", ")))
        }

        if !report.recentProblems.isEmpty {
            lines.append("")
            lines.append("Recent problems (newest first):")
            for problem in report.recentProblems {
                let time = timeText(problem.at)
                lines.append("  \(time) \(problem.message)" + (problem.count > 1 ? " (x\(problem.count))" : ""))
                for line in problem.details ?? [] { lines.append("      \(line)") }
            }
        }
        for log in report.emulatorLogs {
            lines.append("")
            lines.append("Emulator log of \(log.avd) (\(dateText(log.modified)), \(log.bytes) bytes\(log.omittedLines ? ", cut" : "")):")
            for line in log.lines { lines.append("  | \(line)") }
        }
        if !report.collection.notes.isEmpty {
            lines.append("")
            lines.append("Notes:")
            for note in report.collection.notes { lines.append("  \(note)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func consoleText(_ probe: ProblemReport.ConsoleProbe) -> String {
        switch probe.outcome {
        case .answered: return "ANSWERED" + (probe.name.map { "(\($0))" } ?? "")
        case .emptyAnswer: return "EMPTY ANSWER"
        case .ko: return "KO"
        case .failed: return "FAILED" + (probe.exitCode.map { "(exit \($0))" } ?? "")
        case .timedOut: return "TIMED OUT"
        case .skipped: return "SKIPPED" + (probe.note.map { "(\($0))" } ?? "")
        }
    }

    private static func propertyText(_ probe: ProblemReport.PropertyProbe) -> String {
        switch probe.outcome {
        case .answered: return probe.value ?? "ANSWERED"
        case .empty: return "EMPTY"
        case .failed: return "FAILED"
        case .timedOut: return "TIMED OUT"
        case .skipped: return "SKIPPED" + (probe.note.map { "(\($0))" } ?? "")
        }
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// A Markdown summary line without the escapes and code spans.
    private static func plain(_ markdown: String) -> String {
        var text = ""
        var escaped = false
        for character in markdown {
            if escaped {
                text.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character != "`" {
                text.append(character)
            }
        }
        return text
    }
}

/// The two ways user-derived text goes into Markdown.
enum MarkdownText {
    /// Escapes `\ * _ [ ] < > & `` ` `` so the text renders as typed and
    /// cannot open a tag or a link.
    static func text(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if "\\*_[]<>&`".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// The text in a code span: a backtick inside becomes an apostrophe, so
    /// the span cannot end early.
    static func code(_ text: String) -> String {
        "`" + text.replacingOccurrences(of: "`", with: "'")
            .replacingOccurrences(of: "\n", with: " ") + "`"
    }
}
