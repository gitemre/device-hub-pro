import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DeviceHubProKit

/// The Reports panel of a physical iPhone or iPad, in Device Hub's layout
/// (measured on Device Hub 27.0 against the test iPhone, 2026-09-29): a
/// bottom bar with a Filter field and the kind pop-up (Crashes, Spins, Logs,
/// Diagnostics), and above it either one "No <Kind> Reports" card, 128 pt
/// tall, or the reports newest first in a card of 48 pt rows (a document
/// icon, the file name, and "Today at 18:22:32 • 215 KB" under it). A row's
/// menu opens the report or shows it in the Finder (copied off the device
/// first) or saves it where the user chooses. A device that cannot be asked
/// shows its state hint and nothing is sent. Nothing is ever deleted on the
/// device.
struct PhysicalCrashLogsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let entry: ApplePhysicalEntry
    /// This section's `show` token: its disappearance ends only its own list.
    @State private var token: Int?

    private var controller: PhysicalCrashLogsController { workspace.physicalCrashLogs }

    private struct ShowKey: Equatable {
        let udid: String
        let canUse: Bool
    }

    var body: some View {
        @Bindable var controller = controller
        Group {
            if !entry.canUseClient {
                DHControlsEmptyState(
                    glyph: "text.page.slash",
                    caption: ApplePhysicalInventory.unavailableText(entry: entry)
                )
            } else if let problem = controller.problem {
                DHControlsEmptyState(glyph: "text.page.slash", caption: problem)
            } else {
                VStack(spacing: 0) {
                    reports(controller: controller)
                    InspectorFilterBar(text: $controller.filter, popupLabel: controller.kind.label) {
                        Picker("", selection: $controller.kind) {
                            ForEach(PhysicalReportKind.allCases) { kind in
                                Text(kind.label).tag(kind)
                            }
                        }
                    }
                }
            }
        }
        .task(id: ShowKey(udid: entry.udid, canUse: entry.canUseClient)) {
            if entry.canUseClient {
                token = controller.show(udid: entry.udid)
            } else if let token {
                controller.hide(token: token)
                self.token = nil
            }
        }
        .onDisappear {
            if let token { controller.hide(token: token) }
            token = nil
        }
    }

    @ViewBuilder
    private func reports(controller: PhysicalCrashLogsController) -> some View {
        let rows = controller.rows
        let shape = RoundedRectangle(cornerRadius: ParityMetrics.inspectorCardRadius, style: .continuous)
        if rows.isEmpty {
            // One card at the top, as Device Hub's: the kind's own sentence,
            // "No Results" for a filter that hides everything.
            Text(emptyText(controller: controller))
                .font(.system(size: ParityMetrics.inspectorRowFontSize))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: ParityMetrics.physicalReportsEmptyCardHeight)
                .background(Color.primary.opacity(ParityMetrics.inspectorCardFillOpacity), in: shape)
                .padding(.horizontal, ParityMetrics.inspectorCardInset)
                .padding(.top, ParityMetrics.controlsPanelTopSpacing)
            Spacer(minLength: 0)
        } else {
            // Rounded at the top only: the list runs down to the bar's hairline.
            let radius = ParityMetrics.inspectorCardRadius
            let listShape = UnevenRoundedRectangle(
                topLeadingRadius: radius, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: radius, style: .continuous
            )
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, log in
                        PhysicalCrashLogRowView(log: log, controller: controller)
                        if index != rows.count - 1 {
                            InspectorDivider(
                                leadingInset: ParityMetrics.physicalReportsTextInset,
                                trailingInset: ParityMetrics.inspectorAppsDividerTrailingInset
                            )
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .background(Color.primary.opacity(ParityMetrics.inspectorCardFillOpacity), in: listShape)
            .clipShape(listShape)
            .padding(.horizontal, ParityMetrics.inspectorCardInset)
            // Runs down to the bar's hairline, as in Device Hub.
            .padding(.top, ParityMetrics.controlsPanelTopSpacing)
        }
    }

    private func emptyText(controller: PhysicalCrashLogsController) -> String {
        if !controller.hasLoaded { return "Reading Reports…" }
        if controller.hasReportsOfKind { return "No Results" }
        return controller.kind.emptyText
    }
}

private struct PhysicalCrashLogRowView: View {
    let log: PhysicalCrashLog
    let controller: PhysicalCrashLogsController

    /// The document icon Device Hub draws for a report, from the system's
    /// icon for the file's type.
    private static let icon: NSImage = {
        let type = UTType(filenameExtension: "ips") ?? .plainText
        return NSWorkspace.shared.icon(for: type)
    }()

    var body: some View {
        HStack(alignment: .center, spacing: ParityMetrics.physicalReportsIconSpacing) {
            Image(nsImage: Self.icon)
                .resizable()
                .frame(width: ParityMetrics.physicalReportsIconSize, height: ParityMetrics.physicalReportsIconSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(log.fileName)
                    .font(.system(size: ParityMetrics.physicalReportsNameFontSize))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(.system(size: ParityMetrics.physicalReportsDetailFontSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if controller.savingPath == log.relativePath {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.leading, ParityMetrics.physicalReportsIconInset)
        .padding(.trailing, 12)
        .frame(height: ParityMetrics.physicalReportsRowHeight)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Task { await controller.open(log) } }
        .contextMenu { actions }
        .help(log.relativePath)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(log.fileName), \(detail)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Open")) { Task { await controller.open(log) } }
        .accessibilityAction(named: Text("Show in Finder")) { Task { await controller.reveal(log) } }
        .accessibilityAction(named: Text("Save to…")) { Task { await controller.save(log) } }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Open") { Task { await controller.open(log) } }
        Button("Show in Finder") { Task { await controller.reveal(log) } }
        Button("Save to…") { Task { await controller.save(log) } }
    }

    /// "Today at 18:22:32 • 215 KB".
    private var detail: String {
        var parts: [String] = []
        if let date = log.shownDate { parts.append(Self.format(date)) }
        if let size = log.size {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        return parts.joined(separator: " • ")
    }

    /// Device Hub's dates: "Today at 18:22:32", "Yesterday at 23:59:44", and
    /// "27 Sep 2026 at 11:08:56" before that.
    static func format(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(.dateTime.hour().minute().second())
        if calendar.isDate(date, inSameDayAs: now) { return "Today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday at \(time)" }
        return "\(date.formatted(.dateTime.day().month(.abbreviated).year())) at \(time)"
    }
}
