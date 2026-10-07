import SwiftUI
import DeviceHubProKit

/// The Reports panel of a simulator: its crash reports newest first in a Device
/// Hub card, a runtime daemon's crash loop as one row with a count, "My app
/// only" while the log follows an app. A double click opens a report in
/// Console; the row's menu also shows it in Finder or copies it. Where there
/// are none the panel is Device Hub's placeholder (a slashed page and one
/// sentence), which fills the column.
struct SimulatorCrashReportsSection: View {
    let udid: String
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    /// This section's `show` token: its disappearance ends only its own
    /// list, not one a newer section opened meanwhile.
    @State private var token: Int?

    private var controller: SimulatorCrashReportsController { workspace.simulatorCrashReports }

    private var followedApp: SimulatorCrashReportList.App? {
        workspace.logcat.followedSimulatorApp(udid: udid)
    }

    var body: some View {
        @Bindable var controller = controller
        let rows = controller.rows(followed: followedApp)

        Group {
            if rows.isEmpty {
                DHControlsEmptyState(
                    glyph: "text.page.slash.fill",
                    caption: emptyText
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            InspectorHeading("Crash Reports")
                            Spacer(minLength: 4)
                            if let app = followedApp {
                                Toggle("My app only", isOn: $controller.myAppOnly)
                                    .toggleStyle(.checkbox)
                                    .controlSize(.small)
                                    .help("Only \(app.bundleIdentifier), the app the log follows")
                            }
                        }
                        DHCard {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                SimulatorCrashReportRowView(row: row, controller: controller)
                                if index != rows.count - 1 {
                                    DHHairline()
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: ParityMetrics.inspectorCardRadius, style: .continuous))
                    }
                    .padding(.horizontal, ParityMetrics.inspectorCardInset)
                    .padding(.top, ParityMetrics.controlsPanelTopSpacing)
                    .padding(.bottom, ParityMetrics.inspectorCardInset)
                }
                .scrollIndicators(.never)
            }
        }
        .onChange(of: udid, initial: true) {
            token = controller.show(udid: udid)
        }
        .onDisappear {
            if let token { controller.hide(token: token) }
            token = nil
        }
    }

    /// Device Hub's own sentence while there is nothing to show; a read that
    /// is not possible or that filters everything out says so.
    private var emptyText: String {
        if model.simulators.diagnosticReportsDirectory == nil { return "Crash reports are not read here." }
        if controller.myAppOnly, let app = followedApp { return "No crash reports of \(app.process ?? app.bundleIdentifier)." }
        return "Crash, log, spin, and diagnostic reports are unavailable for simulators."
    }
}

private struct SimulatorCrashReportRowView: View {
    let row: SimulatorCrashReportRow
    let controller: SimulatorCrashReportsController

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                // Process, loop count and newest time; the exception below.
                HStack(spacing: 6) {
                    Text(row.newest.process)
                        .font(.system(size: ParityMetrics.crashReportsTitleFontSize, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.isLoop {
                        Text("×\(row.count)")
                            .font(.system(size: ParityMetrics.crashReportsDetailFontSize, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    Spacer(minLength: 4)
                    Text(Self.format(row.newest.time))
                        .font(.system(size: ParityMetrics.crashReportsDetailFontSize).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(detail)
                    .font(.system(size: ParityMetrics.crashReportsDetailFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, ParityMetrics.crashReportsRowVerticalPadding)
        .padding(.horizontal, ParityMetrics.inspectorRowTextInset)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { controller.open(row) }
        .contextMenu { actions }
        .help(row.newest.url.lastPathComponent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Open in Console")) { controller.open(row) }
        .accessibilityAction(named: Text("Show in Finder")) { controller.reveal(row) }
        .accessibilityAction(named: Text("Copy Report")) { Task { await controller.copy(row) } }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Open in Console") { controller.open(row) }
        Button(row.isLoop ? "Show \(row.count) Reports in Finder" : "Show in Finder") { controller.reveal(row) }
        Button("Copy Report") { Task { await controller.copy(row) } }
    }

    /// "EXC_CRASH (SIGSEGV)"; a loop adds its first crash ("… · since
    /// 13:44:40").
    private var detail: String {
        guard row.isLoop else { return row.newest.exceptionSummary }
        return "\(row.newest.exceptionSummary) · since \(Self.format(row.oldest.time))"
    }

    private var accessibilityText: String {
        let count = row.isLoop ? ", \(row.count) crashes" : ""
        return "\(row.newest.process)\(count), \(detail), \(Self.format(row.newest.time))"
    }

    /// A time today ("13:45:02"), a date and time otherwise ("27 Sep
    /// 23:53").
    static func format(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute().second())
        }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}
