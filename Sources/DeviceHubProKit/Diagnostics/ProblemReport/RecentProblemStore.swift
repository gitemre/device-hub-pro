import Foundation
import os

/// Who an error may name that the inventory may not list later: the serials of
/// the phones that were connected, and the values of the Apple devices (the
/// names their owners gave them, their UDIDs). An error such as `adb -s
/// <serial> reboot failed … device '<serial>' not found` is recorded while the
/// phone is plugged in and reported after it was unplugged, so the problem log
/// keeps these beside the error, and the report scrubs them from every string.
public struct RecentProblemIdentifiers: Codable, Sendable, Equatable {
    /// One group per phone: every adb serial it is known by (its transports'
    /// serials and its hardware serial).
    public var phones: [[String]]
    /// Values removed wherever they occur.
    public var secrets: [String]

    public init(phones: [[String]] = [], secrets: [String] = []) {
        self.phones = phones
        self.secrets = secrets
    }

    public var isEmpty: Bool { phones.isEmpty && secrets.isEmpty }

    /// Both sets, without repeats.
    public func merging(_ other: RecentProblemIdentifiers) -> RecentProblemIdentifiers {
        var merged = self
        func key(_ group: [String]) -> [String] { group.map { $0.lowercased() }.sorted() }
        var seen = Set(phones.map(key))
        for group in other.phones where !group.isEmpty && seen.insert(key(group)).inserted {
            merged.phones.append(group)
        }
        for secret in other.secrets where !merged.secrets.contains(secret) { merged.secrets.append(secret) }
        return merged
    }
}

/// The errors the app showed lately, kept so a problem report can say what the
/// user saw before they filed it: at most 20, newest first, the same message
/// within a minute counted instead of repeated.
///
/// The entries are written to `~/Library/Logs/DeviceHubPro/recent-problems.json`
/// (the folder 0700, the file 0600) so they survive a relaunch, as raw text on
/// the user's own Mac beside the raw emulator logs: they are scrubbed only when
/// a report is made. Each entry carries the identifiers of the devices that
/// were connected when it was recorded (`RecentProblemIdentifiers`), which the
/// report never encodes. This is the one writer of the problem report feature;
/// the collection itself writes nothing.
public final class RecentProblemStore: @unchecked Sendable {
    public static let capacity = 20
    public static let maxMessageLength = 2_000
    public static let maxDetailsLength = 4_000
    public static let coalesceWindow: TimeInterval = 60

    /// `home/Library/Logs/DeviceHubPro/recent-problems.json`.
    public static func liveFileURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Logs/DeviceHubPro/recent-problems.json")
    }

    private struct Entry {
        var problem: ProblemReport.RecentProblem
        var identifiers = RecentProblemIdentifiers()
        /// The error revision of `StatusCenter` that recorded it; memory only.
        var revision: Int?
    }

    /// An entry as written to the file: the report's fields and the identifiers
    /// (absent in a file written before they were kept).
    private struct Stored: Codable {
        var at: Date
        var message: String
        var details: [String]?
        var count: Int
        var identifiers: RecentProblemIdentifiers?

        init(_ entry: Entry) {
            at = entry.problem.at
            message = entry.problem.message
            details = entry.problem.details
            count = entry.problem.count
            identifiers = entry.identifiers.isEmpty ? nil : entry.identifiers
        }

        var entry: Entry {
            Entry(
                problem: ProblemReport.RecentProblem(at: at, message: message, details: details, count: count),
                identifiers: identifiers ?? RecentProblemIdentifiers(),
                revision: nil
            )
        }
    }

    private struct State {
        var loaded = false
        var entries: [Entry] = []
    }

    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "com.devicehubpro.recent-problems", qos: .utility)

    /// `fileURL` nil keeps the entries in memory only.
    public init(fileURL: URL?, now: @escaping @Sendable () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
    }

    /// Records an error. A message equal to the newest entry's, within
    /// `coalesceWindow` of it, raises its count and refreshes its time
    /// instead of adding an entry; the revision moves to the new error.
    /// `identifiers` are those of the devices connected now.
    public func record(
        message: String,
        details: String? = nil,
        revision: Int? = nil,
        identifiers: RecentProblemIdentifiers = RecentProblemIdentifiers()
    ) {
        let text = ProblemTextCut.prefix(message, Self.maxMessageLength)
        let lines = details.map(Self.lines)
        let when = now()
        let snapshot = lock.withLock { state -> [Stored] in
            load(into: &state)
            if let newest = state.entries.first, newest.problem.message == text,
               when.timeIntervalSince(newest.problem.at) <= Self.coalesceWindow {
                state.entries[0].problem.count += 1
                state.entries[0].problem.at = when
                state.entries[0].revision = revision
                state.entries[0].identifiers = state.entries[0].identifiers.merging(identifiers)
                if let lines { state.entries[0].problem.details = lines }
            } else {
                state.entries.insert(
                    Entry(
                        problem: ProblemReport.RecentProblem(at: when, message: text, details: lines),
                        identifiers: identifiers,
                        revision: revision
                    ),
                    at: 0
                )
                if state.entries.count > Self.capacity { state.entries.removeLast(state.entries.count - Self.capacity) }
            }
            return state.entries.map(Stored.init)
        }
        persist(snapshot)
    }

    /// Sets the details of the entry recorded for `revision` (the alert's
    /// "Show Details" text arrives after its message).
    public func attachDetails(_ details: String, revision: Int) {
        let lines = Self.lines(details)
        let snapshot = lock.withLock { state -> [Stored]? in
            load(into: &state)
            guard let index = state.entries.firstIndex(where: { $0.revision == revision }) else { return nil }
            state.entries[index].problem.details = lines
            return state.entries.map(Stored.init)
        }
        if let snapshot { persist(snapshot) }
    }

    /// Newest first.
    public func entries() -> [ProblemReport.RecentProblem] {
        lock.withLock { state in
            load(into: &state)
            return state.entries.map(\.problem)
        }
    }

    /// The identifiers of every entry kept, for the report to scrub: the
    /// devices that were connected when the errors were recorded.
    public func identifiers() -> RecentProblemIdentifiers {
        lock.withLock { state in
            load(into: &state)
            return state.entries.reduce(RecentProblemIdentifiers()) { $0.merging($1.identifiers) }
        }
    }

    /// Waits for the pending write to finish (tests).
    public func flush() {
        queue.sync {}
    }

    // MARK: Storage

    private static func lines(_ details: String) -> [String] {
        ProblemTextCut.prefix(details, maxDetailsLength)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }

    /// Reads the file the first time the store is used; a missing or damaged
    /// file starts empty.
    private func load(into state: inout State) {
        guard !state.loaded else { return }
        state.loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let stored = try? ProblemReport.decoder().decode([Stored].self, from: data)
        else { return }
        state.entries = stored.prefix(Self.capacity).map(\.entry)
    }

    /// Writes the whole array on a private queue: a temporary file made 0600,
    /// moved over the old one, in a folder that is 0700.
    private func persist(_ entries: [Stored]) {
        guard let fileURL else { return }
        queue.async {
            guard let data = try? ProblemReport.encoder().encode(entries) else { return }
            let manager = FileManager.default
            let folder = fileURL.deletingLastPathComponent()
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let temporary = folder.appendingPathComponent(".recent-problems.json.tmp")
            guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
            // Best effort: a failed move leaves the old file as it was, and the
            // next write replaces the temporary file.
            _ = rename(temporary.path, fileURL.path)
        }
    }
}
