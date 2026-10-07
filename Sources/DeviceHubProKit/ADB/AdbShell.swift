import Foundation

/// The retained output of the device shell panel, bounded so a command that
/// never stops printing cannot grow memory: past `capacity` UTF-8 bytes the
/// oldest lines are dropped (and counted in `droppedLines`).
public struct ShellTranscript: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case command
        case output
        case status
    }

    public struct Line: Sendable, Equatable, Identifiable {
        public let id: Int
        public let kind: Kind
        public let text: String
    }

    /// The default bound on retained output.
    public static let defaultCapacity = 2 * 1024 * 1024

    public let capacity: Int
    public private(set) var lines: [Line] = []
    public private(set) var byteCount = 0
    public private(set) var droppedLines = 0
    private var nextID = 0

    public init(capacity: Int = ShellTranscript.defaultCapacity) {
        self.capacity = max(capacity, 1)
    }

    public mutating func append(_ text: String, kind: Kind) {
        var text = text
        // One line longer than the whole bound is cut to the bound.
        if text.utf8.count > capacity {
            text = String(decoding: text.utf8.prefix(capacity), as: UTF8.self) + "…"
        }
        lines.append(Line(id: nextID, kind: kind, text: text))
        nextID += 1
        byteCount += text.utf8.count + 1
        trim()
    }

    public mutating func clear() {
        lines.removeAll()
        byteCount = 0
        droppedLines = 0
    }

    private mutating func trim() {
        guard byteCount > capacity else { return }
        var drop = 0
        var bytes = byteCount
        while bytes > capacity, drop < lines.count - 1 {
            bytes -= lines[drop].text.utf8.count + 1
            drop += 1
        }
        guard drop > 0 else { return }
        lines.removeFirst(drop)
        byteCount = bytes
        droppedLines += drop
    }
}

/// The command history of the shell panel: up walks back, down forward, and
/// walking past the newest entry returns the unsent draft.
public struct ShellHistory: Sendable, Equatable {
    public let limit: Int
    public private(set) var entries: [String] = []
    private var cursor: Int?
    private var draft = ""

    public init(limit: Int = 200) {
        self.limit = max(limit, 1)
    }

    /// Records a sent command (a repeat of the newest entry is not stored)
    /// and resets the walk.
    public mutating func record(_ command: String) {
        cursor = nil
        draft = ""
        guard !command.isEmpty, entries.last != command else { return }
        entries.append(command)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    /// Up: the previous entry, remembering `current` as the draft on the first step.
    public mutating func previous(current: String) -> String {
        guard !entries.isEmpty else { return current }
        if let cursor {
            self.cursor = max(cursor - 1, 0)
        } else {
            draft = current
            cursor = entries.count - 1
        }
        return entries[cursor ?? 0]
    }

    /// Down: the next entry, then the draft.
    public mutating func next(current: String) -> String {
        guard let cursor else { return current }
        if cursor + 1 < entries.count {
            self.cursor = cursor + 1
            return entries[cursor + 1]
        }
        self.cursor = nil
        return draft
    }
}

extension AdbClient {
    /// Runs `adb -s <serial> shell <command>` once (not a PTY), delivering
    /// each output line (stdout and stderr merged) as it arrives. Returns the
    /// remote exit status adb reports. Cancelling the calling task stops the
    /// adb child and throws `CancellationError`. The command text goes to adb
    /// as one argument, so the device's shell parses it.
    public func runShell(
        serial: String,
        command: String,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> Int32 {
        guard isResolved else { throw AdbError.adbNotFound }
        return try await ProcessRunner.stream(
            executable: adbURL,
            arguments: ["-s", serial, "shell", command],
            onLine: onLine
        )
    }
}
