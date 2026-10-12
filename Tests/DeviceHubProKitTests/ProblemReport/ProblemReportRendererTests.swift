import XCTest
@testable import DeviceHubProKit

/// The Markdown a user pastes into an issue, the plain text of the CLI, and the
/// parser that reads the Markdown back. The reports are made by the whole
/// pipeline (`ProblemReportBuilder`) over the hermetic Mac, so what is rendered
/// is what the app would show, scrubbed.
final class ProblemReportRendererTests: XCTestCase {
    private func prepared(
        subject: ProblemReport.Subject? = nil,
        recentProblems: [ProblemReport.RecentProblem] = [],
        adjust: (inout ProblemReportInputs) -> Void = { _ in }
    ) async throws -> PreparedProblemReport {
        let world = try HermeticReportWorld()
        var inputs = try world.inputs()
        adjust(&inputs)
        return await ProblemReportBuilder.prepare(
            inputs: inputs,
            appState: nil,
            subject: subject,
            recentProblems: recentProblems,
            now: Date(timeIntervalSince1970: 1_800_000_000),
            reportID: "3fa9c2d1"
        )
    }

    // MARK: Markdown

    func testTheMarkdownHasTheMarkersTheSummaryAndTheJson() async throws {
        let prepared = try await prepared(
            subject: ProblemReport.Subject(message: "Pixel_8_Pro did not come online in time.", occurredAt: Date(timeIntervalSince1970: 1_799_999_880)),
            recentProblems: [ProblemReport.RecentProblem(at: Date(timeIntervalSince1970: 1_799_999_880), message: "Emulator not responding")]
        )
        let markdown = prepared.markdown
        XCTAssertTrue(markdown.hasPrefix("<!-- dhp-report v1 -->\n**Device Hub Pro problem report** `3fa9c2d1` \u{00B7} 2027-01-15 08:00 UTC\n"))
        XCTAssertTrue(markdown.hasSuffix("</details>\n<!-- /dhp-report v1 -->\n"))
        XCTAssertTrue(markdown.contains("> Pixel\\_8\\_Pro did not come online in time."))
        XCTAssertTrue(markdown.contains("- **Mac:** macOS 27.0 (27A123) \u{00B7} Mac16,10 \u{00B7} Apple M4 Pro \u{00B7} 24 GB \u{00B7} hypervisor available \u{00B7} 182 GB free"))
        XCTAssertTrue(markdown.contains("- **Android:** adb 37.0.0 (runs the server) \u{00B7} emulator 36.6.11 \u{00B7} cmdline-tools latest 22.0 \u{00B7} console token file: missing"), markdown)
        XCTAssertTrue(markdown.contains("- **Emulators:** `Pixel_9_Pro_Fold` on `emulator-5554`: adb device, console answered, Android says `DHP_ConsoleCapture`"))
        XCTAssertTrue(markdown.contains("- **Phones:** 1 (USB: 2209116AG)"))
        XCTAssertTrue(markdown.contains("- **Xcode:** not found"))
        XCTAssertTrue(markdown.contains("- **Recent problems:** 1, newest 2 min before the report"))
        XCTAssertTrue(markdown.contains("**Known problems**\n- **An emulator was created by old Android tools** (likely)."))
        XCTAssertTrue(markdown.contains("<details><summary>Full report (JSON, schema 1)</summary>\n\n```json\n{"))
        XCTAssertEqual(prepared.report.findingsShown, prepared.findings.map(\.id))
        XCTAssertFalse(markdown.contains("testeruser"))
        XCTAssertFalse(markdown.contains("0a1b2c3d4e5f"))
    }

    func testNoFindingsSaysSo() async throws {
        let prepared = try await prepared { inputs in
            inputs.homeDirectory = inputs.homeDirectory.appendingPathComponent("elsewhere")
        }
        XCTAssertTrue(prepared.markdown.contains("**Known problems**\nNone of the known problems matched."), prepared.markdown)
    }

    func testTheRenderedReportParsesBackToTheSameReport() async throws {
        let prepared = try await prepared(subject: ProblemReport.Subject(message: "It failed", details: ["a", "b"], occurredAt: Date(timeIntervalSince1970: 1_799_999_000)))
        let results = ProblemReportParser.reports(in: prepared.markdown)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try results[0].get(), prepared.report)
    }

    func testBackticksInTheJsonCannotCloseTheFence() async throws {
        let prepared = try await prepared(subject: ProblemReport.Subject(
            message: "Failed in ```swift\nlet x = `y`\n``` and more", details: ["```", "~~~"], occurredAt: Date(timeIntervalSince1970: 0)
        ))
        let lines = prepared.markdown.components(separatedBy: "\n")
        let open = try XCTUnwrap(lines.firstIndex(of: "```json"))
        let close = try XCTUnwrap(lines[(open + 1)...].firstIndex { $0.hasPrefix("```") })
        let json = lines[(open + 1)..<close].joined(separator: "\n")
        XCTAssertFalse(json.contains("`"))
        XCTAssertTrue(json.contains("\\u0060\\u0060\\u0060swift"))
        XCTAssertEqual(try ProblemReportParser.reports(in: prepared.markdown)[0].get(), prepared.report, "the escapes decode back")
        // After the closing fence only the details tail and the marker remain.
        XCTAssertEqual(Array(lines[(close + 1)...]).filter { !$0.isEmpty }, ["</details>", "<!-- /dhp-report v1 -->"])
    }

    func testUserTextInTheSummaryIsEscaped() async throws {
        let prepared = try await prepared(subject: ProblemReport.Subject(
            message: "<img src=x onerror=alert(1)> *bold* [link](http://x) `code` & more_text", occurredAt: Date(timeIntervalSince1970: 0)
        )) { inputs in
            // An AVD name is user text too.
            let environment = ["PATH": "/nonexistent"]
            inputs.environment = { environment }
        }
        XCTAssertTrue(prepared.markdown.contains("> \\<img src=x onerror=alert(1)\\> \\*bold\\* \\[link\\](http://x) \\`code\\` \\& more\\_text"), prepared.markdown)
        XCTAssertEqual(MarkdownText.text("a_b*c[d]<e>&f`g\\h"), "a\\_b\\*c\\[d\\]\\<e\\>\\&f\\`g\\\\h")
        XCTAssertEqual(MarkdownText.code("a`b\nc"), "`a'b c`")
    }

    func testAMarkdownInjectionInAnAvdNameIsEscaped() async throws {
        let world = try HermeticReportWorld()
        let process = "71988 /x/qemu/darwin-aarch64/qemu-system-aarch64 -avd <img/src=x>`*_ -port 5554"
        let inputs = try world.inputs(processList: process)
        let prepared = await ProblemReportBuilder.prepare(inputs: inputs, appState: nil, subject: nil, recentProblems: [], now: Date(timeIntervalSince1970: 0), reportID: "00000000")
        let line = try XCTUnwrap(prepared.markdown.components(separatedBy: "\n").first { $0.hasPrefix("- **Emulators:**") })
        XCTAssertTrue(line.contains("`<img/src=x>'*_`"), line)
        XCTAssertFalse(line.contains("`<img/src=x>`*_`"))
    }

    // MARK: Fitting an issue

    func testAHugeReportIsTrimmedToFit() async throws {
        let base = try await prepared()
        var report = base.report
        let long = String(repeating: "x", count: 500)
        report.emulatorLogs = ["A", "B", "C"].map { name in
            ProblemReport.LogTail(avd: name, modified: Date(timeIntervalSince1970: 1_800_000_000), bytes: 100_000,
                                  lines: Array(repeating: long, count: 60), omittedLines: true)
        }
        report.recentProblems = (0..<20).map { index in
            ProblemReport.RecentProblem(at: Date(timeIntervalSince1970: 1_800_000_000 - Double(index)), message: "Problem \(index)",
                                        details: [String(repeating: "d", count: 4_000)])
        }
        let fitted = ProblemReportRenderer.fitted(report, findings: [])
        XCTAssertLessThanOrEqual(fitted.markdown.utf8.count, ProblemReportRenderer.maxBytes)
        XCTAssertFalse(fitted.report.collection.truncated.isEmpty)
        XCTAssertTrue(fitted.markdown.contains("_Trimmed to fit an issue: emulator logs cut to 30 lines"), fitted.markdown.prefix(2_000).description)
        // What was cut is what the JSON says was cut.
        let parsed = try ProblemReportParser.reports(in: fitted.markdown)[0].get()
        XCTAssertEqual(parsed, fitted.report)
        XCTAssertEqual(ProblemReportRenderer.markdown(report, findings: []), fitted.markdown)
    }

    func testASmallReportIsNotTrimmed() async throws {
        let prepared = try await prepared()
        XCTAssertEqual(prepared.report.collection.truncated, [])
        XCTAssertFalse(prepared.markdown.contains("_Trimmed"))
    }

    func testTheTrimStepsRunInOrderAndStopWhenItFits() {
        var report = ProblemReport(
            id: "abcd1234", createdAt: Date(timeIntervalSince1970: 0), producer: .app,
            app: ProblemReport.AppInfo(kind: .packaged), mac: ProblemReport.MacInfo(macOS: "27.0", appleSilicon: true),
            android: ProblemReport.AndroidInfo(
                consoleTokenFile: ProblemReport.TokenFileInfo(path: "", state: .missing),
                avdHome: ProblemReport.AvdHomeInfo(path: "", exists: false)
            ),
            apple: ProblemReport.AppleInfo()
        )
        let long = String(repeating: "y", count: 400)
        report.emulatorLogs = [ProblemReport.LogTail(avd: "A", modified: Date(timeIntervalSince1970: 0), bytes: 1, lines: Array(repeating: long, count: 60), omittedLines: false)]
        report.crashReports = [ProblemReport.CrashReportRef(process: "adb", date: Date(timeIntervalSince1970: 0))]
        let fitted = ProblemReportRenderer.fitted(report, findings: [])
        // 60 x 400 characters is 24 KB: it fits as it is.
        XCTAssertEqual(fitted.report.collection.truncated, [])
        let wide = String(repeating: "y", count: 700)
        report.emulatorLogs = (0..<3).map { index in ProblemReport.LogTail(avd: "A\(index)", modified: Date(timeIntervalSince1970: 0), bytes: 1, lines: Array(repeating: wide, count: 60), omittedLines: false) }
        let cut = ProblemReportRenderer.fitted(report, findings: [])
        XCTAssertEqual(
            cut.report.collection.truncated,
            ["emulator logs cut to 30 lines", "emulator logs cut to 2 emulators", "emulator logs cut to 15 lines"]
        )
        XCTAssertEqual(cut.report.emulatorLogs.count, 2)
        XCTAssertEqual(cut.report.crashReports.count, 1, "later steps are not needed")
    }

    // MARK: Plain text

    func testTheTerminalTextShowsOutcomesFindingsAndWhatTheAppShowed() async throws {
        var prepared = try await prepared()
        var report = prepared.report
        report.producer = .app
        report.findingsShown = ["x86-image"]
        report.android.runningEmulators[0].console = ProblemReport.ConsoleProbe(outcome: .emptyAnswer, exitCode: 0, stdoutBytes: 0)
        report.android.consoleTokenFile.state = .empty
        let findings = ProblemReportAnalyzer.findings(for: report)
        let text = ProblemReportRenderer.terminal(report, findings: findings)
        XCTAssertTrue(text.contains("emulator-5554 Pixel_9_Pro_Fold adb=device console=EMPTY ANSWER guest=DHP_ConsoleCapture boot=1 discovery=found(grpcToken=false)"), text)
        XCTAssertTrue(text.contains("[confirmed] The emulator console\u{2019}s token file is empty (console-token-empty) [new since the app\u{2019}s check]"))
        XCTAssertTrue(text.contains("evidence: emulator-5554 (Pixel_9_Pro_Fold): `adb emu avd name` printed nothing"))
        XCTAssertTrue(text.contains("keys: app.version, app.kind, android.consoleTokenFile.state, android.runningEmulators[].console.outcome"))
        XCTAssertTrue(text.contains("fix: Update Device Hub Pro to 1.1.2 or later, which talks to the console itself. Or quit the emulators, delete ~/.emulator_console_auth_token"))
        XCTAssertTrue(text.contains("The app showed: x86-image"))
        prepared = PreparedProblemReport(report: report, findings: findings, markdown: "")
        XCTAssertFalse(text.contains("<img"))
    }

    func testTheTerminalTextSaysWhenAdbWasNotAsked() async throws {
        let prepared = try await prepared { $0.runsAdb = false }
        let text = ProblemReportRenderer.terminal(prepared.report, findings: prepared.findings)
        XCTAssertTrue(text.contains("Devices:  not read: adb calls are turned off."), text)
        XCTAssertTrue(text.contains("adb server: $TMPDIR/FakeTool-adb-<uuid-1>/adb (37.0.0), not asked: adb calls are turned off."), text)
        XCTAssertTrue(text.contains("adb=NOT ASKED console=SKIPPED(adb not queried)"), text)
        XCTAssertFalse(text.contains("NOT LISTED"))
        XCTAssertTrue(prepared.markdown.contains("`Pixel_9_Pro_Fold` on `emulator-5554`: adb not asked"), "not \u{201C}adb doesn\u{2019}t list it\u{201D}")
        XCTAssertTrue(prepared.markdown.contains("- **Phones:** not read"))
    }

    func testTheTerminalTextListsRecentProblemsAndLogs() async throws {
        let prepared = try await prepared(recentProblems: [
            ProblemReport.RecentProblem(at: Date(timeIntervalSince1970: 1_799_999_000), message: "Emulator not responding", details: ["a detail"], count: 3),
        ])
        var report = prepared.report
        report.emulatorLogs = [ProblemReport.LogTail(avd: "Pixel_8_Pro", modified: Date(timeIntervalSince1970: 1_799_999_000), bytes: 90, lines: ["WARNING | hvf is not enabled"], omittedLines: true)]
        let text = ProblemReportRenderer.terminal(report, findings: [])
        XCTAssertTrue(text.contains("Recent problems (newest first):\n  07:43:20 Emulator not responding (x3)\n      a detail"), text)
        XCTAssertTrue(text.contains("Emulator log of Pixel_8_Pro (2027-01-15 07:43 UTC, 90 bytes, cut):\n  | WARNING | hvf is not enabled"))
        XCTAssertTrue(text.contains("No known problem matched."))
    }

    // MARK: The parser

    func testTheParserReadsACrLfBody() async throws {
        let prepared = try await prepared()
        let crlf = prepared.markdown.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(try ProblemReportParser.reports(in: crlf)[0].get(), prepared.report)
    }

    func testTheParserReadsAReportInsideAnotherCodeBlock() async throws {
        // The old `logs` field of the issue form renders as text: a pasted report arrives in a block.
        let prepared = try await prepared()
        let wrapped = "### What happened?\n\nIt broke.\n\n### Logs or screenshots\n\n```text\n\(prepared.markdown)```\n\n### More\n"
        let results = ProblemReportParser.reports(in: wrapped)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try results[0].get(), prepared.report)
    }

    func testTheParserFindsTwoReportsInOneText() async throws {
        let first = try await prepared()
        let second = await ProblemReportBuilder.prepare(
            inputs: .inert, appState: nil, subject: nil, recentProblems: [], now: Date(timeIntervalSince1970: 5), reportID: "22222222"
        )
        let text = "Issue body\n\(first.markdown)\n\nA comment\n\n\(second.markdown)"
        let results = ProblemReportParser.reports(in: text)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(try results[0].get().id, "3fa9c2d1")
        XCTAssertEqual(try results[1].get().id, "22222222")
    }

    func testTheParserReadsRawJson() async throws {
        let prepared = try await prepared()
        let json = try prepared.report.jsonText()
        XCTAssertEqual(try ProblemReportParser.reports(in: "\n\n" + json + "\n")[0].get(), prepared.report)
    }

    func testTheParserSaysWhyItCouldNotRead() async throws {
        XCTAssertEqual(ProblemReportParser.reports(in: "just some words"), [.failure(.noReport)])
        XCTAssertEqual(ProblemReportParser.reports(in: ""), [.failure(.noReport)])

        let prepared = try await prepared()
        let newer = try prepared.report.jsonText().replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 2")
        XCTAssertEqual(ProblemReportParser.reports(in: newer), [.failure(.newerSchema(2))])
        let wrapped = "<!-- dhp-report v2 -->\n```json\n\(newer)\n```\n<!-- /dhp-report v2 -->"
        XCTAssertEqual(ProblemReportParser.reports(in: wrapped), [.failure(.newerSchema(2))])

        let damaged = "<!-- dhp-report v1 -->\n```json\n{ \"schemaVersion\": 1, \"id\": \n```\n"
        guard case .failure(.invalid) = ProblemReportParser.reports(in: damaged)[0] else { return XCTFail("damaged JSON") }
        let incomplete = "<!-- dhp-report v1 -->\n```json\n{ \"schemaVersion\": 1 }\n```\n"
        guard case .failure(.invalid(let reason)) = ProblemReportParser.reports(in: incomplete)[0] else { return XCTFail("a report without fields") }
        XCTAssertTrue(reason.hasPrefix("The report has no "), reason)
        let noBlock = "<!-- dhp-report v1 -->\nsummary only\n<!-- /dhp-report v1 -->"
        guard case .failure(.invalid) = ProblemReportParser.reports(in: noBlock)[0] else { return XCTFail("no JSON block") }
    }

    /// Copied from the rendered issue page, the report has lost its HTML comments and its fence, and has the summary
    /// above the JSON: the JSON is still found, as the document that starts at a line of its own.
    func testTheParserReadsTheJsonOfAReportCopiedFromTheRenderedPage() async throws {
        let prepared = try await prepared()
        let json = try prepared.report.jsonText()
        let summary = "Device Hub Pro problem report 3fa9c2d1\n\nMac\nmacOS 27.0 {Apple M4 Pro}\n{\nnot a report\n}\n\nKnown problems\n- x\n\n"
        for text in [summary + json, summary + json + "\n\nA comment follows\n", (summary + json).replacingOccurrences(of: "\n", with: "\r\n")] {
            let results = ProblemReportParser.reports(in: text)
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(try results[0].get(), prepared.report)
        }
        // Indented as a list item of the page would have it.
        let indented = (summary + json).components(separatedBy: "\n").map { $0.isEmpty ? $0 : "  " + $0 }.joined(separator: "\n")
        XCTAssertEqual(try ProblemReportParser.reports(in: indented)[0].get(), prepared.report)

        let newer = json.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 2")
        XCTAssertEqual(ProblemReportParser.reports(in: summary + newer), [.failure(.newerSchema(2))])
        XCTAssertEqual(ProblemReportParser.reports(in: summary + "{\n  \"schemaVersion\" : 1,\n  \"id\" : 3\n}\n").count, 1)
        guard case .failure(.invalid) = ProblemReportParser.reports(in: summary + "{\n  \"schemaVersion\" : 1,\n  \"id\" : 3\n}\n")[0] else {
            return XCTFail("a damaged document that says it is a report")
        }
        XCTAssertEqual(ProblemReportParser.reports(in: summary), [.failure(.noReport)], "braces of a summary are not a report")
    }

    // MARK: The builder

    /// A report pasted into the form's Problem report field and again into the Logs field is one report.
    func testAReportThatAppearsTwiceInAnIssueIsAnalyzedOnce() async throws {
        let prepared = try await prepared()
        let twice = "### Problem report\n\n\(prepared.markdown)\n### Logs\n\n```text\n\(prepared.markdown)```\n"
        XCTAssertEqual(ProblemReportParser.reports(in: twice).count, 2, "the parser finds both")
        let results = ProblemReportBuilder.analyze(markdownOrJSON: twice)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try results[0].get().report.id, "3fa9c2d1")

        let other = await ProblemReportBuilder.prepare(
            inputs: .inert, appState: nil, subject: nil, recentProblems: [], now: Date(timeIntervalSince1970: 5), reportID: "22222222"
        )
        XCTAssertEqual(ProblemReportBuilder.analyze(markdownOrJSON: twice + other.markdown).count, 2, "another report is another report")
    }

    func testAnalyzeMarksWhatTheAppDidNotShow() async throws {
        var prepared = try await prepared()
        var report = prepared.report
        report.producer = .app
        report.findingsShown = []
        prepared = PreparedProblemReport(report: report, findings: [], markdown: ProblemReportRenderer.markdown(report, findings: []))
        let results = ProblemReportBuilder.analyze(markdownOrJSON: prepared.markdown)
        let analyzed = try results[0].get()
        XCTAssertEqual(analyzed.findings.map(\.id), ["avd-target-android-0", "system-image-missing"])
        XCTAssertEqual(analyzed.newFindingIDs, ["avd-target-android-0", "system-image-missing"])
        XCTAssertTrue(ProblemReportBuilder.findingsJSON([analyzed]).contains("\"reportID\" : \"3fa9c2d1\""))
        XCTAssertEqual(ProblemReportBuilder.randomID().count, 8)
        XCTAssertNotNil(ProblemReportBuilder.randomID().range(of: "^[0-9a-f]{8}$", options: .regularExpression))
    }
}
