import Foundation

/// A report ready to show: scrubbed, analyzed and rendered.
public struct PreparedProblemReport: Sendable, Equatable {
    /// The scrubbed report, as trimmed to fit an issue.
    public let report: ProblemReport
    public let findings: [ProblemFinding]
    public let markdown: String
}

/// One report read back from text, with what this build's analyzer finds in it.
public struct AnalyzedProblemReport: Sendable, Equatable {
    public let report: ProblemReport
    public let findings: [ProblemFinding]
    /// Findings this build reports that the producing build did not.
    public let newFindingIDs: [String]
}

/// The pipeline both producers share: collect, scrub, cut, analyze, render. The
/// analyzer only ever sees scrubbed data, so the app and the CLI reach the same
/// verdict.
public enum ProblemReportBuilder {
    public static func prepare(
        inputs: ProblemReportInputs,
        appState: ProblemReportAppState?,
        subject: ProblemReport.Subject?,
        recentProblems: [ProblemReport.RecentProblem],
        recentIdentifiers: RecentProblemIdentifiers = RecentProblemIdentifiers(),
        now: Date = Date(),
        reportID: String = randomID()
    ) async -> PreparedProblemReport {
        let collected = await ProblemReportCollector.collect(
            inputs: inputs,
            appState: appState,
            subject: subject,
            recentProblems: recentProblems,
            recentIdentifiers: recentIdentifiers,
            now: now,
            reportID: reportID
        )
        var scrubber = ProblemReportScrubber(
            identity: inputs.identity,
            secrets: collected.secrets,
            identifiers: collected.privateIdentifiers
        )
        var report = scrubber.scrub(collected.report)
        // Long log lines are cut only now: cut before, a key would have been
        // left in pieces the scrubber no longer takes for one.
        report.emulatorLogs = report.emulatorLogs.map { tail in
            var cut = tail
            cut.lines = CollectionRun.cutLongLines(tail.lines)
            return cut
        }
        let findings = ProblemReportAnalyzer.findings(for: report)
        report.findingsShown = findings.map(\.id)
        let fitted = ProblemReportRenderer.fitted(report, findings: findings)
        return PreparedProblemReport(report: fitted.report, findings: findings, markdown: fitted.markdown)
    }

    /// Eight lowercase hex characters.
    public static func randomID() -> String {
        String(format: "%08x", UInt32.random(in: .min ... .max))
    }

    /// Reads the reports in `text` (an issue, a comment, a file, or JSON) and
    /// analyzes each with this build. A report that appears twice (the same
    /// id: pasted into two fields of the form) is analyzed once.
    public static func analyze(markdownOrJSON text: String) -> [Result<AnalyzedProblemReport, ProblemReportParseError>] {
        var seen = Set<String>()
        return ProblemReportParser.reports(in: text).compactMap { result in
            if case .success(let report) = result, !seen.insert(report.id).inserted { return nil }
            return result.map { report in
                let findings = ProblemReportAnalyzer.findings(for: report)
                let shown = Set(report.findingsShown)
                return AnalyzedProblemReport(
                    report: report,
                    findings: findings,
                    newFindingIDs: report.producer == .app ? findings.map(\.id).filter { !shown.contains($0) } : []
                )
            }
        }
    }

    /// `[{"reportID": …, "findings": […]}]` for the CLI's `--json`.
    public static func findingsJSON(_ analyzed: [AnalyzedProblemReport]) -> String {
        struct Entry: Encodable {
            let reportID: String
            let findings: [ProblemFinding]
        }
        let encoder = ProblemReport.encoder()
        let entries = analyzed.map { Entry(reportID: $0.report.id, findings: $0.findings) }
        return (try? encoder.encode(entries)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}
