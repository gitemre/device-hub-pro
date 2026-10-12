import XCTest
@testable import DeviceHubProKit

/// The link that opens the bug report form. Values come from the scrubbed report.
final class ProblemReportIssueLinkTests: XCTestCase {
    private func prepared(
        subject: ProblemReport.Subject? = nil,
        markdown: String? = nil,
        adjust: (inout ProblemReport) -> Void = { _ in }
    ) async throws -> PreparedProblemReport {
        let world = try HermeticReportWorld()
        var inputs = try world.inputs(producer: .app)
        inputs.bundle = BundleFacts(version: "1.1.1", build: "412", bundlePath: "/Applications/Device Hub Pro.app")
        let made = await ProblemReportBuilder.prepare(
            inputs: inputs, appState: nil, subject: subject, recentProblems: [],
            now: Date(timeIntervalSince1970: 1_800_000_000), reportID: "3fa9c2d1"
        )
        var report = made.report
        adjust(&report)
        return PreparedProblemReport(report: report, findings: made.findings, markdown: markdown ?? made.markdown)
    }

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    func testTheLinkOpensTheBugReportFormOfTheRepository() async throws {
        let link = ProblemReportIssueLink.link(for: try await prepared(markdown: "short report"))
        XCTAssertEqual(link.url.host, "github.com")
        XCTAssertEqual(link.url.path, "/gitemre/device-hub-pro/issues/new")
        let fields = query(link.url)
        XCTAssertEqual(fields["template"], "bug_report.yml")
        XCTAssertEqual(fields["app-version"], "1.1.1 (412)")
        XCTAssertEqual(fields["macos"], "macOS 27.0 (27A123), no Xcode")
        XCTAssertEqual(fields["device-details"], "Pixel_9_Pro_Fold emulator, 2209116AG")
        XCTAssertNil(fields["title"], "no subject, no title")
        XCTAssertNil(fields["what"])
        XCTAssertNil(fields["device"])
        XCTAssertTrue(link.includesReport)
        XCTAssertEqual(fields[ProblemReportIssueLink.reportFieldID], "short report")
        XCTAssertLessThanOrEqual(link.url.absoluteString.count, ProblemReportIssueLink.maxURLLength)
    }

    func testAPlusIsEscapedBecauseGitHubReadsItAsASpace() async throws {
        let link = ProblemReportIssueLink.link(for: try await prepared(markdown: "a+b c&d=e\n#f"))
        XCTAssertTrue(link.url.absoluteString.contains("report=a%2Bb%20c%26d%3De%0A%23f"), link.url.absoluteString)
        XCTAssertEqual(query(link.url)["report"], "a+b c&d=e\n#f")
        XCTAssertEqual(ProblemReportIssueLink.percentEncoded("AZaz09-._~ +/"), "AZaz09-._~%20%2B%2F")
    }

    func testTheSubjectFillsTheTitleAndTheDescription() async throws {
        let message = "Pixel_9_Pro_Fold did not come online in time.\nSecond line."
        let link = ProblemReportIssueLink.link(for: try await prepared(
            subject: ProblemReport.Subject(message: message, occurredAt: Date(timeIntervalSince1970: 1_800_000_000)),
            markdown: "r"
        ))
        let fields = query(link.url)
        XCTAssertEqual(fields["title"], "Pixel_9_Pro_Fold did not come online in time.")
        XCTAssertEqual(fields["what"], "Device Hub Pro showed: \u{201C}\(message)\u{201D}\n\n")
        XCTAssertEqual(fields["device"], "Android emulator", "the subject names one of the report's AVDs")

        let long = String(repeating: "word ", count: 40)
        let longLink = ProblemReportIssueLink.link(for: try await prepared(
            subject: ProblemReport.Subject(message: long, occurredAt: Date(timeIntervalSince1970: 0)), markdown: "r"
        ))
        XCTAssertEqual(query(longLink.url)["title"]?.count, 80)
        XCTAssertNil(query(longLink.url)["device"], "no AVD is named")
    }

    func testALargeReportStaysOnTheClipboard() async throws {
        let prepared = try await prepared(markdown: String(repeating: "a long report line\n", count: 600))
        let link = ProblemReportIssueLink.link(for: prepared)
        XCTAssertFalse(link.includesReport)
        XCTAssertEqual(query(link.url)[ProblemReportIssueLink.reportFieldID], ProblemReportIssueLink.clipboardNote)
        XCTAssertLessThanOrEqual(link.url.absoluteString.count, ProblemReportIssueLink.maxURLLength)
        XCTAssertEqual(query(link.url)["template"], "bug_report.yml")
    }

    func testTheDetailsAndTheVersionsHaveFallbacks() async throws {
        let link = ProblemReportIssueLink.link(for: try await prepared(markdown: "r") { report in
            report.app.kind = .development
            report.apple.xcodeVersion = "27.0"
            report.apple.xcodeBuild = "27A266a"
            report.android.runningEmulators = (0..<30).map { ProblemReport.RunningEmulator(avd: "A_very_long_emulator_name_\($0)", processAlive: true) }
        })
        let fields = query(link.url)
        XCTAssertEqual(fields["app-version"], "development build")
        XCTAssertEqual(fields["macos"], "macOS 27.0 (27A123), Xcode 27.0 (27A266a)")
        XCTAssertEqual(fields["device-details"]?.count, 200)
    }
}
