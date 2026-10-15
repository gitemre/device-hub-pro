import XCTest
@testable import DeviceHubProKit

/// A window's foldable simulator in the report (iPhone Duo): the fold the app
/// holds, the panel it shows, its last read of the two panels and whether the
/// stage offers to lock and wake it. The values are the app's own state, set
/// on the model directly (no device output).
final class ProblemReportFoldableTests: XCTestCase {
    /// The 2026-10-14 case: laptop, the inner panel taken as lit and shown,
    /// the last read finding both panels dark, the stage offering Lock and Wake.
    private let stuck = ProblemReport.FoldableInfo(
        model: "iPhone Duo",
        hingeAngle: 105,
        posture: .laptop,
        held: .landscapeLeft,
        litPanel: .inner,
        shownPanel: .inner,
        lastRead: ProblemReport.PanelRead(
            secondsAgo: 3,
            outer: ProblemReport.PanelReading(content: .dark, grey: 0),
            inner: ProblemReport.PanelReading(content: .dark, grey: 0),
            lit: nil
        ),
        screensStuck: true,
        view: .turnable3D
    )

    private func report(windows: [ProblemReport.WindowInfo]) async throws -> ProblemReport {
        let world = try HermeticReportWorld()
        var report = await world.collect(try world.inputs()).report
        report.android.avds = []
        report.windows = windows
        return report
    }

    func testTheFoldableGoesThroughTheJsonAndBack() async throws {
        let report = try await report(windows: [ProblemReport.WindowInfo(selection: "simulator", foldable: stuck)])
        let decoded = try ProblemReport.decode(jsonText: try report.jsonText())
        XCTAssertEqual(decoded.windows.first?.foldable, stuck)
        let json = try report.jsonText()
        XCTAssertTrue(json.contains("\"posture\" : \"laptop\""), json)
        XCTAssertTrue(json.contains("\"held\" : \"landscape left\""))
        XCTAssertTrue(json.contains("\"view\" : \"3D turnable\""))
    }

    /// A report made before the field (every window without it) still reads.
    func testAWindowWithoutAFoldableStillDecodes() throws {
        let json = #"{"selection": "simulator", "screenStalled": false, "unresponsivePolls": 0}"#
        let window = try ProblemReport.decoder().decode(ProblemReport.WindowInfo.self, from: Data(json.utf8))
        XCTAssertNil(window.foldable)
    }

    func testTheSummaryHasALineForTheFoldable() async throws {
        let report = try await report(windows: [
            ProblemReport.WindowInfo(selection: "simulator", foldable: stuck),
            ProblemReport.WindowInfo(selection: "emulator"),
        ])
        let line = "105\u{00B0}, laptop, held landscape left, lit inner, shown inner, 3D turnable; "
            + "read 3 s before: outer dark (0), inner dark (0), lit untold; screens stuck"
        let markdown = ProblemReportRenderer.markdown(report, findings: [])
        XCTAssertTrue(markdown.contains("- **iPhone Duo:** " + line), markdown)
        let terminal = ProblemReportRenderer.terminal(report, findings: [])
        XCTAssertTrue(terminal.contains("Foldable: iPhone Duo: " + line), terminal)
    }

    func testAFoldableWithoutAReadOrAViewSaysSo() {
        let quiet = ProblemReport.FoldableInfo(
            model: "iPhone Duo", hingeAngle: 0, posture: .closed, held: .portrait,
            litPanel: .outer, shownPanel: nil, lastRead: nil, screensStuck: false, view: .flat2D
        )
        XCTAssertEqual(
            ProblemReportRenderer.foldableSummary(quiet),
            "0\u{00B0}, closed, held portrait, lit outer, shown none, 2D"
        )
    }

    func testStuckScreensAreAFinding() async throws {
        let report = try await report(windows: [ProblemReport.WindowInfo(selection: "simulator", foldable: stuck)])
        let finding = try XCTUnwrap(ProblemReportAnalyzer.findings(for: report).first { $0.id == "foldable-screens-stuck" })
        XCTAssertEqual(finding.confidence, .likely)
        XCTAssertEqual(finding.evidence.count, 1)
        XCTAssertTrue(finding.evidence[0].hasPrefix("iPhone Duo: 105\u{00B0}, laptop"), finding.evidence[0])

        var calm = stuck
        calm.screensStuck = false
        let calmReport = try await self.report(windows: [ProblemReport.WindowInfo(selection: "simulator", foldable: calm)])
        XCTAssertFalse(ProblemReportAnalyzer.findings(for: calmReport).contains { $0.id == "foldable-screens-stuck" })
    }
}
