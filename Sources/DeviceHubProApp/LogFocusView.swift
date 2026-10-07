import AppKit
import SwiftUI
import DeviceHubProKit

/// The wide log pane of Log focus mode: filters and actions on top, the
/// table of entries, and a strip with the selected line in full.
struct LogFocusView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @State private var focus = LogFocusModel()
    @FocusState private var isSearchFocused: Bool

    private var logcat: LogcatController { workspace.logcat }

    var body: some View {
        LogFocusContent(
            focus: focus,
            logcat: logcat,
            source: source,
            isSearchFocused: $isSearchFocused,
            onExit: { workspace.window.exitLogFocus() }
        )
        .logAudience(logcat, isWindowVisible: workspace.window.isWindowVisible)
        .onChange(of: source, initial: true) { _, source in
            openStream(for: source)
        }
    }

    private var source: LogSource {
        LogSource.resolve(
            selection: workspace.deviceSelection,
            liveSerial: workspace.liveSelectionSerial,
            simulatorIsReady: { model.simulatorLifecycle.isReady($0) }
        )
    }

    private func openStream(for source: LogSource) {
        switch source {
        case .adb(let serial): logcat.openLogcatIfNeeded(serial: serial)
        case .simulator(let udid): logcat.openSimulatorLogIfNeeded(udid: udid)
        case .physicalApple(let udid): logcat.openPhysicalLogIfNeeded(udid: udid)
        case .none: break
        }
    }
}

/// The pane without the environment, so a test can render it from a plain
/// controller and model.
struct LogFocusContent: View {
    let focus: LogFocusModel
    let logcat: LogcatController
    let source: LogSource
    var isSearchFocused: FocusState<Bool>.Binding
    var onExit: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            if source.streams || source == .none {
                controls
                Divider()
            } else {
                HStack {
                    Spacer()
                    Button(action: onExit) { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                        .glassButton()
                        .controlSize(.small)
                        .help("Exit Log Focus (Esc)")
                        .accessibilityLabel("Exit Log Focus")
                }
                .padding(10)
            }
            entriesArea
            if !focus.selection.isEmpty {
                Divider()
                detailStrip
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            focus.setFilter(level: logcat.logcatLevel, search: logcat.logcatSearch)
            focus.ingest(logcat.logcatEntries)
        }
        .onChange(of: LogcatFeed.SnapshotKey(logcat.logcatEntries)) { focus.ingest(logcat.logcatEntries) }
        .onChange(of: logcat.logSourceID) { focus.reset() }
        .onChange(of: logcat.logcatLevel) {
            focus.setFilter(level: logcat.logcatLevel, search: logcat.logcatSearch)
        }
        .task(id: logcat.logcatSearch) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            focus.setFilter(level: logcat.logcatLevel, search: logcat.logcatSearch)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if source.isPhysical { physicalAppControls } else { appPicker }

                if !source.isPhysical { levelPicker }

                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField(
                        source.isSimulator ? "Search process, subsystem or message"
                            : source.isPhysical ? "Search category or message" : "Search tag or message",
                        text: Binding(get: { logcat.logcatSearch }, set: { logcat.logcatSearch = $0 })
                    )
                    .textFieldStyle(.plain)
                    .focused(isSearchFocused)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .textFieldHitArea(
                    RoundedRectangle(cornerRadius: 8, style: .continuous),
                    focus: isSearchFocused
                )
                .liquidGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(spacing: 8) {
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)

                Toggle("Wrap", isOn: Binding(get: { focus.wrap }, set: { focus.wrap = $0 }))
                    .toggleStyle(.button)
                    .help("Wrap long messages, or keep one line per entry and scroll sideways")
                Toggle("Pause", isOn: Binding(get: { logcat.logcatPaused }, set: { logcat.logcatPaused = $0 }))
                    .toggleStyle(.button)
                    .help("Stop adding new lines")

                Menu {
                    Button("Copy Selected") { copy(focus.selectedEntries) }
                        .disabled(focus.selection.isEmpty)
                    Button("Copy All Visible") { copy(focus.entries) }
                        .disabled(focus.entries.isEmpty)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Copy")
                .accessibilityLabel("Copy")

                iconButton("trash", help: "Clear") {
                    focus.reset()
                    logcat.clearLogcat()
                }
                iconButton("square.and.arrow.down", help: "Export", disabled: focus.entries.isEmpty) {
                    logcat.exportLogcat(entries: focus.entries)
                }
                iconButton("arrow.down.right.and.arrow.up.left", help: "Exit Log Focus (Esc)", action: onExit)
            }
            .controlSize(.small)

            if source.isPhysical {
                Text(PhysicalLogPane.footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
    }

    private var appPicker: some View {
        Picker("App", selection: Binding(
            get: { logcat.selectedLogcatPackage ?? "" },
            set: { newValue in
                focus.reset()
                logcat.setLogcatPackage(newValue.isEmpty ? nil : newValue)
            }
        )) {
            Text(source.isSimulator ? "All processes" : "All Apps").tag("")
            ForEach(logcat.logcatPackages, id: \.self) { package in
                Text(package).tag(package)
            }
        }
        .labelsHidden()
        .frame(minWidth: 140, maxWidth: 280)
        .help(source.isSimulator ? "Follow one app's process" : "Show one app's lines")
    }

    private var levelPicker: some View {
        Picker("Level", selection: Binding(
            get: { logcat.logcatLevel },
            set: { logcat.logcatLevel = $0 }
        )) {
            ForEach(LogcatLevel.allCases.reversed(), id: \.self) { level in
                Text(level.label).tag(level)
            }
        }
        .labelsHidden()
        .frame(width: 92)
        .help("Lowest level shown")
    }

    /// The physical iPhone's app picker and its Launch & Stream / Stop button:
    /// the log shows one app's console, and Stop ends that app's session.
    @ViewBuilder
    private var physicalAppControls: some View {
        let phase = logcat.physicalLogPhase
        Picker("App", selection: Binding(
            get: { logcat.physicalSelectedBundle ?? "" },
            set: { logcat.physicalSelectedBundle = $0.isEmpty ? nil : $0 }
        )) {
            Text("Choose an app").tag("")
            ForEach(logcat.physicalLogApps) { app in
                Text(app.title).tag(app.bundleID)
            }
        }
        .labelsHidden()
        .frame(minWidth: 160, maxWidth: 300)
        .disabled(phase.isStreaming || phase == .loadingApps || phase == .unavailable)
        .help("The installed app to launch and follow")

        Button {
            if phase.isStreaming {
                logcat.stopPhysicalStream()
            } else if let bundle = logcat.physicalSelectedBundle {
                focus.reset()
                Task { await logcat.launchPhysicalApp(bundleID: bundle) }
            }
        } label: {
            Label(
                PhysicalLogPane.actionTitle(for: phase),
                systemImage: phase.isStreaming ? "stop.fill" : "play.fill"
            )
        }
        .glassButton()
        .controlSize(.small)
        .disabled(!PhysicalLogPane.canAct(phase: phase, selectedBundle: logcat.physicalSelectedBundle))
        .help(phase.isStreaming ? PhysicalLogPane.stopHelp : "Launches the app on the iPhone and streams its output")
        .accessibilityHint(phase.isStreaming ? PhysicalLogPane.stopHelp : "Launches the app and streams its log")
    }

    private func iconButton(_ symbol: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .glassButton()
            .help(help)
            .accessibilityLabel(help)
            .disabled(disabled)
    }

    private var statusLine: String {
        let count = focus.entries.count
        let lines = "\(count) \(count == 1 ? "line" : "lines")"
        var status = logcat.logcatStatusText
        if source.isPhysical, status.isEmpty {
            let phase = logcat.physicalLogPhase
            let title = logcat.physicalLogApps.first { $0.bundleID == logcat.physicalSelectedBundle }?.title
            status = PhysicalLogPane.statusText(phase: phase, appTitle: title)
        }
        return status.isEmpty ? lines : "\(status) · \(lines)"
    }

    private func copy(_ entries: [LogcatEntry]) {
        guard !entries.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(LogcatController.logcatExportText(entries), forType: .string)
    }

    // MARK: - Entries

    @ViewBuilder
    private var entriesArea: some View {
        if let placeholder = placeholder {
            LogcatStateView(
                systemImage: placeholder.systemImage,
                title: placeholder.title,
                message: placeholder.message,
                onRetry: placeholder.offersRetry ? { retry() } : nil
            )
        } else {
            VStack(spacing: 0) {
                if let reason = logcat.logcatStopReason {
                    LogcatBanner(
                        systemImage: "bolt.horizontal.circle",
                        text: "Stream disconnected — \(reason)",
                        onRetry: { retry() }
                    )
                } else if logcat.logcatPaused {
                    LogcatBanner(systemImage: "pause.circle", text: "Paused — new lines are not added")
                }
                table
            }
        }
    }

    private var table: some View {
        LogTableView(
            entries: focus.entries,
            revision: focus.revision,
            wrap: focus.wrap,
            jumpToken: focus.jumpToken,
            isFollowing: focus.follow.isFollowing,
            selection: Binding(get: { focus.selection }, set: { focus.selection = $0 }),
            onUserScroll: { focus.userScrolled(atBottom: $0) },
            onCopy: { copy($0) }
        )
        .overlay(alignment: .bottomTrailing) {
            if !focus.follow.isFollowing {
                Button {
                    focus.jumpToLatest()
                } label: {
                    Label(
                        focus.follow.unseenCount > 0 ? "Jump to latest · \(focus.follow.unseenCount) new" : "Jump to latest",
                        systemImage: "arrow.down.to.line"
                    )
                    .font(.caption)
                }
                .glassButton()
                .controlSize(.small)
                .padding(12)
                .accessibilityHint("Scrolls to the newest line and follows the log again")
            }
        }
    }

    private var placeholder: LogcatPlaceholder? {
        if source.isPhysical, logcat.logcatStopReason == nil, !logcat.physicalLogPhase.isStreaming,
           focus.feed.entries.isEmpty {
            return .physicalIdle
        }
        return LogcatPlaceholder.resolve(
            serial: logcat.logSourceID,
            wasStopped: logcat.logcatWasStopped,
            stopReason: logcat.logcatStopReason,
            isPaused: logcat.logcatPaused,
            hasStoredEntries: !focus.feed.entries.isEmpty,
            hasVisibleEntries: !focus.entries.isEmpty
        )
    }

    private func retry() {
        if let serial = logcat.logcatSerial {
            focus.reset()
            Task { await logcat.openLogcat(serial: serial) }
        } else if let udid = logcat.simulatorLogUDID {
            focus.reset()
            Task { await logcat.openSimulatorLog(udid: udid) }
        } else if logcat.physicalLogUDID != nil, let bundle = logcat.physicalSelectedBundle {
            focus.reset()
            Task { await logcat.launchPhysicalApp(bundleID: bundle) }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailStrip: some View {
        let selected = focus.selectedEntries
        Group {
            if selected.count == 1, let entry = selected.first {
                ScrollView {
                    Text(LogFocusModel.detailText(for: entry))
                        .font(.system(size: LogRowMetrics.fontSize, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 130)
            } else {
                HStack(spacing: 8) {
                    Text("\(selected.count) lines selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Selected") { copy(selected) }
                        .glassButton()
                        .controlSize(.small)
                }
                .padding(10)
            }
        }
        .background(Color.primary.opacity(ParityMetrics.inspectorCardFillOpacity))
    }
}

private extension LogSource {
    var isPhysical: Bool {
        if case .physicalApple = self { return true }
        return false
    }

    var isSimulator: Bool {
        if case .simulator = self { return true }
        return false
    }
}
