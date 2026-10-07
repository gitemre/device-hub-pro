import Foundation
import Observation
import SwiftUI
import DeviceHubProKit

/// Where the Log focus mode's lines come from for the selected device. The
/// seam for a new source: add a case, resolve it in `resolve`, and show it in
/// `LogFocusView`. A physical iPhone streams the console of one app it
/// launches (`PhysicalConsoleLogStream`).
enum LogSource: Equatable {
    /// An Android emulator or phone: `adb logcat`.
    case adb(serial: String)
    /// A booted simulator: `simctl spawn <UDID> log stream`.
    case simulator(udid: String)
    /// A physical iPhone or iPad (hardware UDID): the console of one launched app.
    case physicalApple(udid: String)
    case none

    static func resolve(
        selection: DeviceSelection?,
        liveSerial: String?,
        simulatorIsReady: (String) -> Bool
    ) -> LogSource {
        if let liveSerial { return .adb(serial: liveSerial) }
        switch selection {
        case .simulator(let udid)? where simulatorIsReady(udid): return .simulator(udid: udid)
        case .physicalApple(let udid)?: return .physicalApple(udid: udid)
        default: return .none
        }
    }

    /// Whether a stream of `LogcatController` serves this source.
    var streams: Bool {
        switch self {
        case .adb, .simulator, .physicalApple: return true
        case .none: return false
        }
    }
}

/// Whether the log follows its tail. It stops when the user scrolls away
/// from the bottom, counts the lines that arrived meanwhile, and resumes at
/// "Jump to latest" or when the user scrolls back to the bottom.
struct LogFollowState: Equatable {
    private(set) var isFollowing = true
    private(set) var unseenCount = 0

    mutating func entriesArrived(_ count: Int) {
        guard !isFollowing, count > 0 else { return }
        unseenCount += count
    }

    mutating func userScrolled(atBottom: Bool) {
        isFollowing = atBottom
        if atBottom { unseenCount = 0 }
    }

    mutating func jumpToLatest() {
        isFollowing = true
        unseenCount = 0
    }
}

/// The window layout Log focus mode replaced, put back on exit.
struct LogFocusSnapshot: Equatable {
    var columnVisibility: NavigationSplitViewVisibility
    var showInspector: Bool
}

/// What the log pane shows: the filtered history (a `LogcatFeed`, fed
/// incrementally from the controller's snapshots), the selection, wrapping and
/// the follow state. UI-free so the tests can drive it.
@MainActor
@Observable
final class LogFocusModel {
    let feed = LogcatFeed()
    var wrap = false
    var selection: Set<UInt64> = []
    private(set) var follow = LogFollowState()
    /// Bumped by every change of what the list shows, so the table reloads
    /// on one cheap comparison.
    private(set) var revision = 0
    /// Bumped by "Jump to latest": the table scrolls to the bottom.
    private(set) var jumpToken = 0

    var entries: [LogcatEntry] { feed.matches }

    func ingest(_ snapshot: [LogcatEntry]) {
        let beforeLast = feed.matches.last?.id
        let beforeCount = feed.matches.count
        feed.ingest(snapshot)
        let afterLast = feed.matches.last?.id
        if afterLast != beforeLast || feed.matches.count != beforeCount {
            revision &+= 1
            // The history is capped, so the count may not grow while lines
            // arrive: a new newest id counts as at least one.
            let added = feed.matches.count - beforeCount
            follow.entriesArrived(afterLast != beforeLast ? max(added, 1) : 0)
        }
    }

    func setFilter(level: LogcatLevel, search: String) {
        guard level != feed.minimumLevel || search != feed.search else { return }
        feed.setFilter(level: level, search: search)
        pruneSelection()
        revision &+= 1
    }

    func reset() {
        feed.reset()
        selection = []
        follow.jumpToLatest()
        revision &+= 1
    }

    func userScrolled(atBottom: Bool) {
        guard follow.isFollowing != atBottom || (atBottom && follow.unseenCount != 0) else { return }
        follow.userScrolled(atBottom: atBottom)
    }

    func jumpToLatest() {
        follow.jumpToLatest()
        jumpToken &+= 1
    }

    /// The selected entries, oldest first (what Copy Selected writes).
    var selectedEntries: [LogcatEntry] {
        guard !selection.isEmpty else { return [] }
        return feed.matches.filter { selection.contains($0.id) }
    }

    private func pruneSelection() {
        guard !selection.isEmpty else { return }
        let present = Set(feed.matches.map(\.id))
        selection.formIntersection(present)
    }

    /// The text of the detail strip: the one selected entry in full.
    static func detailText(for entry: LogcatEntry) -> String {
        var header = "\(entry.timestamp)  \(entry.level.rawValue)  \(entry.tag)"
        if !entry.subsystem.isEmpty { header += "  \(entry.subsystem)" }
        return header + "\n" + entry.message
    }
}

/// The geometry the table and its tests share: how many rows a message wraps
/// to in a monospaced column.
enum LogRowMetrics {
    static let fontSize: CGFloat = 11.5
    static let lineHeight: CGFloat = 15
    static let verticalPadding: CGFloat = 3

    /// Lines a message takes when wrapped at `columns` characters per line:
    /// each newline starts a line, each line breaks by character.
    static func wrappedLineCount(of message: String, columns: Int) -> Int {
        let columns = max(columns, 1)
        var lines = 0
        for part in message.split(separator: "\n", omittingEmptySubsequences: false) {
            lines += max(1, (part.count + columns - 1) / columns)
        }
        return lines
    }

    static func rowHeight(lines: Int) -> CGFloat {
        CGFloat(lines) * lineHeight + verticalPadding * 2
    }
}
