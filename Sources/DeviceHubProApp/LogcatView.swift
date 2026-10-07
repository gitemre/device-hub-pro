import SwiftUI
import DeviceHubProKit

struct LogcatView: View {
    @Environment(DeviceWorkspace.self) private var workspace
    /// The filtered history the list, the placeholders and Export read;
    /// fed incrementally from the model's snapshots (see `LogcatFeed`).
    @State private var feed = LogcatFeed()
    @FocusState private var isSearchFocused: Bool

    /// The newest entries shown; the feed keeps (and Export writes) more.
    static let displayLimit = 800

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            entriesArea
        }
        .logAudience(workspace.logcat, isWindowVisible: workspace.window.isWindowVisible)
        .onAppear {
            feed.setFilter(level: workspace.logcat.logcatLevel, search: workspace.logcat.logcatSearch)
            feed.ingest(workspace.logcat.logcatEntries)
        }
        .onChange(of: snapshotKey) { feed.ingest(workspace.logcat.logcatEntries) }
        .onChange(of: workspace.logcat.logSourceID) { feed.reset() }
        .onChange(of: workspace.logcat.logcatLevel) {
            feed.setFilter(level: workspace.logcat.logcatLevel, search: workspace.logcat.logcatSearch)
        }
        .task(id: workspace.logcat.logcatSearch) {
            // Debounced: typing re-filters the history once it pauses.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            feed.setFilter(level: workspace.logcat.logcatLevel, search: workspace.logcat.logcatSearch)
        }
    }

    /// Changes whenever the model publishes a different snapshot; cheaper to
    /// compare than the entries themselves (the poll republishes every
    /// 400 ms, changed or not).
    private var snapshotKey: LogcatFeed.SnapshotKey {
        LogcatFeed.SnapshotKey(workspace.logcat.logcatEntries)
    }

    /// The newest matching entries the list shows (a slice: no copy).
    private var displayedEntries: ArraySlice<LogcatEntry> {
        feed.matches.suffix(Self.displayLimit)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("App", selection: Binding(
                    get: { workspace.logcat.selectedLogcatPackage ?? "" },
                    set: { newValue in
                        feed.reset()
                        workspace.logcat.setLogcatPackage(newValue.isEmpty ? nil : newValue)
                    }
                )) {
                    // Log Focus's words for the same choice.
                    Text(workspace.context.simulatorDevice != nil ? "All processes" : "All Apps").tag("")
                    ForEach(workspace.logcat.logcatPackages, id: \.self) { package in
                        Text(package).tag(package)
                    }
                }
                .labelsHidden()

                Picker("Level", selection: Binding(
                    get: { workspace.logcat.logcatLevel },
                    set: { workspace.logcat.logcatLevel = $0 }
                )) {
                    ForEach(LogcatLevel.allCases.reversed(), id: \.self) { level in
                        Text(level.label).tag(level)
                    }
                }
                .labelsHidden()
                .frame(width: 88)
            }

            // A simulator's tag is its process; its subsystem is searched too.
            TextField(
                workspace.logcat.simulatorLogUDID == nil ? "Search tag or message" : "Search process, subsystem or message",
                text: Binding(
                    get: { workspace.logcat.logcatSearch },
                    set: { workspace.logcat.logcatSearch = $0 }
                )
            )
            .textFieldStyle(.plain)
            .focused($isSearchFocused)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .textFieldHitArea(
                RoundedRectangle(cornerRadius: 8, style: .continuous),
                focus: $isSearchFocused
            )
            // Plain glass like the sidebar search: a text field does not
            // morph under the pointer.
            .liquidGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 8) {
                Text(workspace.logcat.logcatStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Toggle("Pause", isOn: Binding(
                    get: { workspace.logcat.logcatPaused },
                    set: { workspace.logcat.logcatPaused = $0 }
                ))
                .toggleStyle(.button)
                .controlSize(.small)
                Button {
                    feed.reset()
                    workspace.logcat.clearLogcat()
                } label: {
                    Image(systemName: "trash")
                }
                .glassButton()
                .accessibilityLabel("Clear")
                .help("Clear")
                Button {
                    workspace.logcat.exportLogcat(entries: feed.matches)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .glassButton()
                .accessibilityLabel("Export")
                .help("Export")
                .disabled(feed.matches.isEmpty)
                Button(role: .destructive) {
                    workspace.logcat.stopLogcat()
                } label: {
                    // A stop square, not an ×: beside Done the × read as "close".
                    Image(systemName: "stop.fill")
                }
                .glassButton()
                .accessibilityLabel("Stop Stream")
                .help("Stop Stream")
            }
            .controlSize(.small)
        }
        .padding(10)
    }

    /// Presentation-only states (spec §9.3c): no device / deliberately stopped
    /// / disconnected / paused / filter-empty / no output each get an
    /// inspector-style placeholder; a disconnected or paused non-empty list
    /// gets a banner. Streaming and filtering are untouched.
    @ViewBuilder
    private var entriesArea: some View {
        if let placeholder = resolvedPlaceholder {
            placeholderView(placeholder)
        } else {
            listArea
        }
    }

    private func placeholderView(_ placeholder: LogcatPlaceholder) -> some View {
        LogcatStateView(
            systemImage: placeholder.systemImage,
            title: placeholder.title,
            message: placeholder.message,
            onRetry: placeholder.offersRetry ? { retryLogcat() } : nil
        )
    }

    @ViewBuilder
    private var listArea: some View {
        VStack(spacing: 0) {
            if let reason = workspace.logcat.logcatStopReason {
                LogcatBanner(
                    systemImage: "bolt.horizontal.circle",
                    text: "Stream disconnected — \(reason)",
                    onRetry: { retryLogcat() }
                )
            } else if workspace.logcat.logcatPaused {
                LogcatBanner(
                    systemImage: "pause.circle",
                    text: "Paused — showing the last \(displayedEntries.count) entries"
                )
            }
            entriesList
        }
    }

    private var resolvedPlaceholder: LogcatPlaceholder? {
        LogcatPlaceholder.resolve(
            serial: workspace.logcat.logSourceID,
            wasStopped: workspace.logcat.logcatWasStopped,
            stopReason: workspace.logcat.logcatStopReason,
            isPaused: workspace.logcat.logcatPaused,
            hasStoredEntries: !feed.entries.isEmpty,
            hasVisibleEntries: !feed.matches.isEmpty
        )
    }

    /// The disconnected state's action: start the same device's stream
    /// again (an adb device's logcat, or a simulator's log).
    private func retryLogcat() {
        if let serial = workspace.logcat.logcatSerial {
            feed.reset()
            Task { await workspace.logcat.openLogcat(serial: serial) }
        } else if let udid = workspace.logcat.simulatorLogUDID {
            feed.reset()
            Task { await workspace.logcat.openSimulatorLog(udid: udid) }
        } else if let serial = workspace.liveSelectionSerial {
            // A stopped stream cleared its device: reopen the selected one.
            feed.reset()
            Task { await workspace.logcat.openLogcat(serial: serial) }
        } else if case .simulator(let udid)? = workspace.deviceSelection {
            feed.reset()
            Task { await workspace.logcat.openSimulatorLog(udid: udid) }
        }
    }

    private var entriesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(displayedEntries) { entry in
                    LogcatRow(entry: entry)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .defaultScrollAnchor(.bottom)
        .font(.system(size: 11, design: .monospaced))
    }
}

/// The Logcat view's filtered history, maintained incrementally.
///
/// The model republishes the stream's newest entries (`logcatEntries`) every
/// 400 ms. Filtering that snapshot in `body` ran the level/search filter —
/// lowercasing the query, tag and message of every entry — three or four
/// times per render. The feed instead appends only the entries it has not
/// seen (ids grow monotonically within a stream), filters just those, and
/// re-filters its history once when the level or search changes, matching
/// case-insensitively without lowercasing copies. It accumulates across
/// snapshots up to the stream's own history size, so the filters and Export
/// see everything the stream retained while the view was open, not only the
/// snapshot's window. Entries that came and went between two snapshots (a
/// burst faster than the poll, or a long pause) leave a gap in the ids; the
/// feed puts a marker entry there ("N entries skipped"), which every filter
/// keeps, so neither the list nor Export looks complete when it is not.
@MainActor
@Observable
final class LogcatFeed {
    /// Identifies a snapshot cheaply: a different stream, a clear or new
    /// lines all change it.
    struct SnapshotKey: Equatable {
        let count: Int
        let firstID: UInt64?
        let lastID: UInt64?

        init(_ snapshot: [LogcatEntry]) {
            count = snapshot.count
            firstID = snapshot.first?.id
            lastID = snapshot.last?.id
        }
    }

    /// Every entry held, oldest first; at most `capacity`.
    private(set) var entries: [LogcatEntry] = []
    /// The ids of the gap markers among `entries`.
    private var gapMarkerIDs: Set<UInt64> = []
    /// The entries passing the filter, oldest first.
    private(set) var matches: [LogcatEntry] = []
    private(set) var minimumLevel: LogcatLevel = .debug
    private(set) var search = ""
    /// `LogcatStream`'s own history size.
    let capacity: Int

    init(capacity: Int = 4000) {
        self.capacity = capacity
    }

    /// Takes the model's latest snapshot. It continues the held history when
    /// it overlaps or follows it; an empty snapshot (a clear, a new stream)
    /// or one from another stream starts over.
    func ingest(_ snapshot: [LogcatEntry]) {
        guard let newest = snapshot.last else {
            reset()
            return
        }
        guard let held = entries.last else {
            append(snapshot[...])
            return
        }
        if newest.id < held.id {
            // Ids restart with every stream: this is another one.
            reset()
            append(snapshot[...])
            return
        }
        if let index = Self.index(of: held.id, in: snapshot) {
            guard snapshot[index] == held else {
                // Same id, different line: another stream.
                reset()
                append(snapshot[...])
                return
            }
            append(snapshot[(index + 1)...], after: held)
        } else if let oldest = snapshot.first, oldest.id > held.id {
            // More arrived than one snapshot holds: all of it is new, and
            // what came between is gone.
            append(snapshot[...], after: held)
        } else {
            reset()
            append(snapshot[...])
        }
    }

    /// Sets the level and search text; re-filters the history only when
    /// either changed.
    func setFilter(level: LogcatLevel, search: String) {
        guard level != minimumLevel || search != self.search else { return }
        minimumLevel = level
        self.search = search
        matches = entries.filter(matchesFilter)
    }

    func reset() {
        if !entries.isEmpty { entries.removeAll() }
        if !matches.isEmpty { matches.removeAll() }
        if !gapMarkerIDs.isEmpty { gapMarkerIDs.removeAll() }
    }

    /// Appends what continues `held`, after a marker when ids were skipped
    /// between them. The marker takes the id before the first new entry,
    /// which no entry held can have (the skipped ones are gone), and that
    /// entry's time.
    private func append(_ new: ArraySlice<LogcatEntry>, after held: LogcatEntry) {
        if let first = new.first, first.id > held.id + 1 {
            let skipped = first.id - held.id - 1
            let marker = LogcatEntry(
                id: first.id - 1,
                timestamp: first.timestamp,
                pid: 0,
                tid: 0,
                level: .warning,
                tag: "DeviceHubPro",
                message: "\(skipped.formatted()) \(skipped == 1 ? "line" : "lines") not shown: the device logged faster than the log view keeps up"
            )
            gapMarkerIDs.insert(marker.id)
            append([marker][...])
        }
        append(new)
    }

    private func append(_ new: ArraySlice<LogcatEntry>) {
        guard !new.isEmpty else { return }
        entries.append(contentsOf: new)
        matches.append(contentsOf: new.filter(matchesFilter))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
            if let oldest = entries.first?.id,
               let keep = matches.firstIndex(where: { $0.id >= oldest }),
               keep > 0 {
                matches.removeFirst(keep)
            }
        }
    }

    private func matchesFilter(_ entry: LogcatEntry) -> Bool {
        // A gap is news whatever the filter: the matches around it are not
        // all there were.
        if gapMarkerIDs.contains(entry.id) { return true }
        guard entry.level.severity >= minimumLevel.severity else { return false }
        guard !search.isEmpty else { return true }
        // A logcat entry's subsystem is empty, so only a simulator's event
        // can match on it.
        return entry.tag.range(of: search, options: .caseInsensitive) != nil
            || entry.message.range(of: search, options: .caseInsensitive) != nil
            || (!entry.subsystem.isEmpty && entry.subsystem.range(of: search, options: .caseInsensitive) != nil)
    }

    /// Binary search: snapshots are sorted by id.
    private static func index(of id: UInt64, in snapshot: [LogcatEntry]) -> Int? {
        var low = 0
        var high = snapshot.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let value = snapshot[middle].id
            if value == id { return middle }
            if value < id { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }
}

/// The Logcat area's placeholder decision (spec §9.3c), split out so the
/// state mapping is testable without a live stream. `nil` means the entry
/// list is shown.
enum LogcatPlaceholder: Equatable {
    case noDevice
    case stopped
    case disconnected(reason: String)
    case paused
    case noMatches
    case noOutput
    /// A physical iPhone's pane before an app is launched: nothing streams
    /// until the user presses Launch & Stream.
    case physicalIdle

    static func resolve(
        serial: String?,
        wasStopped: Bool,
        stopReason: String?,
        isPaused: Bool,
        hasStoredEntries: Bool,
        hasVisibleEntries: Bool
    ) -> LogcatPlaceholder? {
        guard serial != nil else { return wasStopped ? .stopped : .noDevice }
        guard !hasVisibleEntries else { return nil }
        if let stopReason { return .disconnected(reason: stopReason) }
        // Before `.paused`: paused entries that the filter hides are "no
        // matches", not "nothing captured yet".
        if hasStoredEntries { return .noMatches }
        if isPaused { return .paused }
        return .noOutput
    }

    var systemImage: String {
        switch self {
        case .noDevice: return "iphone.slash"
        case .stopped: return "stop.circle"
        case .disconnected: return "bolt.horizontal.circle"
        case .paused: return "pause.circle"
        case .noMatches: return "line.3.horizontal.decrease.circle"
        case .noOutput: return "text.alignleft"
        case .physicalIdle: return "play.circle"
        }
    }

    var title: String {
        switch self {
        case .noDevice: return "No device"
        case .stopped: return "Log stream stopped"
        case .disconnected: return "Stream disconnected"
        case .paused: return "Paused"
        case .noMatches: return "No matching entries"
        case .noOutput: return "No log output"
        case .physicalIdle: return "Launch an app to see its logs"
        }
    }

    var message: String? {
        switch self {
        case .noDevice:
            return "Select a device to see its logs."
        case .stopped:
            return "The log stream was stopped. Press Retry to start it again."
        case .disconnected(let reason):
            return "The device stopped sending its log. Press Retry to reconnect.\n\(reason)"
        case .paused:
            return "No entries captured yet."
        case .noMatches:
            return "Adjust the level or the search text."
        case .noOutput:
            return "Entries appear here as the device writes them."
        case .physicalIdle:
            return "Choose an app above and press Launch & Stream. Stop ends the app's session on the iPhone."
        }
    }

    /// Whether the state offers a Retry that re-runs `openLogcat`.
    var offersRetry: Bool {
        switch self {
        case .disconnected, .stopped: return true
        default: return false
        }
    }
}

/// A compact inspector-language placeholder: a small SF symbol over
/// secondary text, centered in the log area.
struct LogcatStateView: View {
    let systemImage: String
    let title: String
    let message: String?
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: ParityMetrics.logcatStateSpacing) {
            Image(systemName: systemImage)
                .font(.system(size: ParityMetrics.logcatStateIconSize))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            if let onRetry {
                Button("Retry", action: onRetry)
                    .glassButton()
                    .accessibilityHint("Starts the log stream again")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(ParityMetrics.logcatStatePadding)
    }
}

/// A one-line status strip above the entry list while the stream is paused
/// or has stopped with entries still on screen.
struct LogcatBanner: View {
    let systemImage: String
    let text: String
    var onRetry: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let onRetry {
                Button(action: onRetry) {
                    // The whole banner-high cell takes the click, not just
                    // the 11 pt word.
                    Text("Retry")
                        .padding(.horizontal, ParityMetrics.logcatRetryHorizontalPadding)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The word stays where it was drawn.
                .padding(.horizontal, -ParityMetrics.logcatRetryHorizontalPadding)
                .foregroundStyle(Color.accentColor)
                .help("Starts the log stream again")
            }
        }
        .font(.system(size: ParityMetrics.logcatPausedBannerFontSize))
        .foregroundStyle(.secondary)
        .padding(.horizontal, ParityMetrics.logcatPausedBannerHorizontalInset)
        .frame(height: ParityMetrics.logcatPausedBannerHeight)
        .background(Color.primary.opacity(ParityMetrics.inspectorCardFillOpacity))
    }
}

private struct LogcatRow: View {
    let entry: LogcatEntry

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(shortTimestamp)
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)

            Text(entry.level.rawValue)
                .fontWeight(.bold)
                .foregroundStyle(levelColor)

            Text(entry.tag)
                .foregroundStyle(.teal)
                .frame(minWidth: 60, alignment: .leading)

            message
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .background(entry.isCrash ? Color.red.opacity(0.12) : Color.clear)
    }

    /// The message; a simulator's event ends with its subsystem, dimmed, so
    /// a subsystem the search matched shows while the message still reads
    /// first in the inspector's narrow column.
    private var message: Text {
        guard !entry.subsystem.isEmpty else { return Text(entry.message) }
        // Both parts are `Text(String)`s, so nothing is read as Markdown.
        return Text("\(Text(entry.message)) \(Text(entry.subsystem).foregroundStyle(.tertiary))")
    }

    private var shortTimestamp: String {
        guard let space = entry.timestamp.firstIndex(of: " ") else { return entry.timestamp }
        return String(entry.timestamp[entry.timestamp.index(after: space)...])
    }

    private var levelColor: Color {
        switch entry.level {
        case .verbose, .debug: return .secondary
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        case .fatal: return .purple
        }
    }
}
