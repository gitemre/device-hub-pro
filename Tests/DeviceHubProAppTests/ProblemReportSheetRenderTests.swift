import SwiftUI
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// Draws the Report a Problem sheet while it collects, with known problems and
/// with none, light and dark. The PNGs land in `DHP_RENDER_DIR` when it is set
/// (to look at them); without it the test only checks that every state draws
/// to a non-empty image.
@MainActor
final class ProblemReportSheetRenderTests: XCTestCase {
    private func render<V: View>(_ view: V, name: String, dark: Bool) throws {
        let framed = view.background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: framed)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.appearance = appearance
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds), name)
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        XCTAssertGreaterThan(size.width, 500, name)
        XCTAssertGreaterThan(size.height, 300, name)
        guard let dir = ProcessInfo.processInfo.environment["DHP_RENDER_DIR"], !dir.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("problem-report-\(name)-\(dark ? "dark" : "light").png"))
    }

    /// A model on inert inputs (nothing is read from this Mac) that reached its
    /// report: `noHypervisor` makes the Mac one that cannot virtualize, which
    /// the analyzer knows; `hasAdb` false is a Mac with no adb.
    private func readyModel(
        subject: ProblemReport.Subject?,
        noHypervisor: Bool,
        hasAdb: Bool
    ) async throws -> ProblemReportSheetModel {
        var inputs = ProblemReportInputs.inert
        inputs.macFacts = {
            MacFacts(
                macOS: "27.0", build: "27A123", model: "Mac16,10", chip: "Apple M4 Pro",
                memoryBytes: 24 * 1_073_741_824, appleSilicon: true,
                hypervisorSupported: !noHypervisor, insideVirtualMachine: noHypervisor
            )
        }
        inputs.adbURL = hasAdb ? URL(fileURLWithPath: "/usr/bin/true") : nil
        let state = ProblemReportAppState(
            preferences: ProblemReport.Preferences(
                customEmulatorBinary: false, customSDKFolder: false, emulatorAudio: "muted",
                autoRepairAvdDisplay: true, localNetworkInUse: false, showPhysicalAppleDevices: false,
                enabledPhysicalDeviceCount: 0, physicalFastInput: true, physicalNativeLiveView: true,
                developmentTeamSet: false
            )
        )
        let log = RecentProblemStore(fileURL: nil)
        log.record(message: "Pixel_8_Pro did not come online in time.", details: "INFO    | Storing crashdata\nWARNING | QEMU main loop exits abnormally with code 1")
        let model = ProblemReportSheetModel(
            subject: subject,
            inputs: inputs,
            state: state,
            recentProblems: log,
            pasteboard: TestPasteboard(),
            picker: TestPicker(),
            status: StatusCenter(),
            openURL: { _ in }
        )
        model.start()
        await waitUntil(timeout: 15, "the report never became ready") { model.isReady }
        return model
    }

    func testEveryStateOfTheSheetDraws() async throws {
        let subject = ProblemReport.Subject(
            message: "Pixel_8_Pro did not come online in time.",
            details: nil,
            occurredAt: Date()
        )
        let withProblems = try await readyModel(subject: subject, noHypervisor: true, hasAdb: false)
        XCTAssertGreaterThanOrEqual(withProblems.prepared?.findings.count ?? 0, 2, "no hypervisor and no adb are both known")
        let withoutProblems = try await readyModel(subject: nil, noHypervisor: false, hasAdb: true)
        XCTAssertEqual(withoutProblems.prepared?.findings.map(\.id), [], "a Mac with nothing wrong matches no known problem")

        // The footer after Open GitHub Issue: the instruction must fit whole.
        let opened = try await readyModel(subject: subject, noHypervisor: true, hasAdb: false)
        opened.openIssue()
        XCTAssertNotNil(opened.footerNote)

        for dark in [false, true] {
            try render(ProblemReportSheetView(subject: subject, model: opened), name: "opened", dark: dark)
            try render(ProblemReportSheetView(subject: nil, model: nil), name: "collecting", dark: dark)
            try render(ProblemReportSheetView(subject: subject, model: withProblems), name: "known-problems", dark: dark)
            try render(ProblemReportSheetView(subject: nil, model: withoutProblems), name: "no-known-problem", dark: dark)
        }
    }
}
