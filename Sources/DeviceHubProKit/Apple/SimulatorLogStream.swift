import Foundation

/// One unified-log event from a simulator's `log stream --style ndjson`.
public struct SimulatorLogEntry: Sendable, Hashable, Identifiable {
    /// Monotonic id assigned by the stream; zero outside a stream.
    public var id: UInt64
    /// The device-local timestamp, verbatim ("2026-09-25 15:06:19.359577+0300").
    public let timestamp: String
    public let processID: Int
    public let threadID: Int
    /// The process image name ("MobileSafari").
    public let process: String
    public let subsystem: String
    public let category: String
    /// "Default", "Info", "Debug", "Error" or "Fault"; nil for activity
    /// records (`activityCreateEvent`), which carry no message type.
    public let messageType: String?
    /// "logEvent", "activityCreateEvent", …
    public let eventType: String
    public let message: String

    public init(
        id: UInt64 = 0,
        timestamp: String,
        processID: Int,
        threadID: Int,
        process: String,
        subsystem: String,
        category: String,
        messageType: String?,
        eventType: String,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.processID = processID
        self.threadID = threadID
        self.process = process
        self.subsystem = subsystem
        self.category = category
        self.messageType = messageType
        self.eventType = eventType
        self.message = message
    }

    /// The logcat level the entry shows as: Debug → D, Info and Default → I
    /// (os_log's default level is a notice), Error → E, Fault → F, and
    /// activity records → V.
    public var level: LogcatLevel {
        switch messageType {
        case "Debug": return .debug
        case "Info", "Default": return .info
        case "Error": return .error
        case "Fault": return .fatal
        default: return .verbose
        }
    }

    /// The entry in the shape the log view already renders for Android: the
    /// timestamp trimmed to logcat's `MM-dd HH:mm:ss.SSS`, the process name as
    /// the tag, the subsystem kept for the search.
    public var logcatEntry: LogcatEntry {
        LogcatEntry(
            id: id,
            timestamp: SimulatorLogParsing.logcatTimestamp(timestamp),
            pid: processID,
            tid: threadID,
            level: level,
            tag: process,
            message: message,
            subsystem: subsystem
        )
    }
}

/// Parses `log stream --style ndjson` lines.
public enum SimulatorLogParsing {
    public enum Line: Sendable, Equatable {
        case entry(SimulatorLogEntry)
        /// The record `log` writes when the stream ends on SIGINT,
        /// `{"count":N,"finished":1}`: N events were streamed.
        case finished(count: Int)
        /// Not an event: an empty line, or the stderr noise `simctl spawn`
        /// mixes in (`getpwuid_r did not find a match for uid 501`: the
        /// host's uid has no account inside the simulator).
        case ignored
    }

    public static func parse(_ line: String) -> Line {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") else { return .ignored }
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(trimmed.utf8)) else {
            return .ignored
        }
        if event.finished != nil, event.eventType == nil {
            return .finished(count: event.count ?? 0)
        }
        guard let eventType = event.eventType else { return .ignored }
        let process = event.processImagePath
            .map { ($0 as NSString).lastPathComponent }
            ?? ""
        return .entry(SimulatorLogEntry(
            timestamp: event.timestamp ?? "",
            processID: event.processID ?? 0,
            threadID: event.threadID ?? 0,
            process: process,
            subsystem: event.subsystem ?? "",
            category: event.category ?? "",
            messageType: event.messageType,
            eventType: eventType,
            message: event.eventMessage ?? ""
        ))
    }

    /// `2026-09-25 15:06:19.359577+0300` → `09-25 15:06:19.359`, logcat's
    /// threadtime format. Anything else comes back unchanged.
    public static func logcatTimestamp(_ timestamp: String) -> String {
        let parts = timestamp.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 10, parts[1].count >= 12 else { return timestamp }
        return "\(parts[0].dropFirst(5)) \(parts[1].prefix(12))"
    }

    /// The fields Device Hub Pro reads; the stream carries 32 keys per event.
    private struct Event: Decodable {
        let timestamp: String?
        let processID: Int?
        let threadID: Int?
        let processImagePath: String?
        let subsystem: String?
        let category: String?
        let messageType: String?
        let eventType: String?
        let eventMessage: String?
        let count: Int?
        let finished: Int?
    }
}

/// Streams one simulator's unified log (`simctl spawn <UDID> log stream
/// --style ndjson`) into a bounded history — the simulator counterpart of
/// `LogcatStream`.
///
/// The stream is loud: about 340 events/s on a settled device, and bursts of
/// over 14,000 events/s were measured right after a boot while an app
/// launched. Lines are parsed on the reader thread and only the newest
/// `capacity` entries are kept. `predicate` narrows the stream on the device
/// side (`log stream --predicate`), which is the cheap way to follow one app.
public final class SimulatorLogStream: @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        case idle
        case running
        case stopped(reason: String)
    }

    /// `log stream --level`: the lowest level streamed.
    public enum Level: String, Sendable, CaseIterable {
        case `default`
        case info
        case debug
    }

    public let udid: String
    public let level: Level
    public let predicate: String?
    private let simctl: SimctlClient
    private let capacity: Int

    private let lock = NSLock()
    private var entries: [SimulatorLogEntry] = []
    private var nextID: UInt64 = 1
    private var _status: Status = .idle
    private var _ignoredLineCount = 0
    private var streamTask: Task<Void, Never>?
    /// Bumped by every start and stop, so lines still in flight from a
    /// previous stream are dropped.
    private var generation: UInt64 = 0
    /// The pid of the newest held event while one app's process is followed
    /// (`predicate` set): an event from another pid means the app restarted,
    /// and a marker event goes before it. Reset with the history.
    private var lastFollowedPID: Int?
    /// The marker's process name (the tag it shows under), shared with
    /// Android's `LogcatStream.restartMarkerTag`.
    public static let restartMarkerProcess = LogcatStream.restartMarkerTag

    public init(
        simctl: SimctlClient,
        udid: String,
        level: Level = .debug,
        predicate: String? = nil,
        capacity: Int = 4000
    ) {
        self.simctl = simctl
        self.udid = udid
        self.level = level
        self.predicate = predicate
        self.capacity = capacity
    }

    deinit {
        streamTask?.cancel()
    }

    /// The `simctl` arguments of the stream (without the `--set` prefix the
    /// client adds).
    public var arguments: [String] {
        var arguments = ["spawn", udid, "log", "stream", "--style", "ndjson", "--level", level.rawValue]
        if let predicate {
            arguments += ["--predicate", predicate]
        }
        return arguments
    }

    public var status: Status {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    /// Lines that were not events (stderr noise, blank lines).
    public var ignoredLineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _ignoredLineCount
    }

    public func snapshot() -> [SimulatorLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.suffix(capacity))
    }

    /// The history as logcat entries, oldest first.
    public func logcatSnapshot() -> [LogcatEntry] {
        snapshot().map(\.logcatEntry)
    }

    /// Most recent entries, oldest first.
    public func tail(_ count: Int) -> [SimulatorLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.suffix(min(count, capacity)))
    }

    /// The most recent entries as logcat entries, oldest first, converted
    /// outside the lock.
    public func logcatTail(_ count: Int) -> [LogcatEntry] {
        tail(count).map(\.logcatEntry)
    }

    /// The held entries newer than `id`, oldest first: everything a reader
    /// that has seen up to `id` has not read yet, as far as the history
    /// still holds it (up to a quarter over `capacity` between trims).
    public func entries(after id: UInt64) -> [SimulatorLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        // Binary search: ids grow with the history.
        var low = 0
        var high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].id <= id { low = middle + 1 } else { high = middle }
        }
        return Array(entries[low...])
    }

    /// `entries(after:)` as logcat entries, converted outside the lock: what
    /// the log view polls, so each event is converted once.
    public func logcatEntries(after id: UInt64) -> [LogcatEntry] {
        entries(after: id).map(\.logcatEntry)
    }

    /// `log stream --predicate` for one process by its name (an app's
    /// `CFBundleExecutable`), which keeps following the app across
    /// relaunches: `process == "MobileSafari"`, with `\` and `"` escaped
    /// for the predicate's string literal.
    public static func processPredicate(_ processName: String) -> String {
        let escaped = processName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "process == \"\(escaped)\""
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        lastFollowedPID = nil
        lock.unlock()
    }

    // MARK: Lifecycle

    public func start() {
        let argv: [String]
        do {
            try SimctlClient.validateUDID(udid)
            argv = try simctl.commandLine(arguments)
        } catch {
            setStatus(.stopped(reason: "\(error)"))
            return
        }

        lock.lock()
        generation &+= 1
        let generation = self.generation
        let previous = streamTask
        _status = .running
        lock.unlock()
        previous?.cancel()

        let executable = simctl.simctlURL
        let environment = simctl.environment
        let task = Task { [weak self] in
            do {
                let exitCode = try await ProcessRunner.stream(
                    executable: executable,
                    arguments: argv,
                    environment: environment,
                    onLine: { [weak self] line in
                        self?.ingest(line, generation: generation)
                    }
                )
                self?.finish(generation: generation, reason: "log stream exited with status \(exitCode)")
            } catch is CancellationError {
                // A stop or restart: the status was set by whoever cancelled.
            } catch {
                self?.finish(generation: generation, reason: "\(error)")
            }
        }
        lock.lock()
        if self.generation == generation {
            streamTask = task
            lock.unlock()
        } else {
            lock.unlock()
            task.cancel()
        }
    }

    public func stop() {
        lock.lock()
        generation &+= 1
        let task = streamTask
        streamTask = nil
        _status = .idle
        lock.unlock()
        task?.cancel()
    }

    // MARK: Ingest (reader thread)

    private func ingest(_ line: String, generation: UInt64) {
        let parsed = SimulatorLogParsing.parse(line)
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation else { return }
        switch parsed {
        case .entry(var entry):
            if predicate != nil, entry.processID != 0 {
                if let previous = lastFollowedPID, previous != entry.processID {
                    var marker = SimulatorLogEntry(
                        timestamp: entry.timestamp,
                        processID: entry.processID,
                        threadID: entry.processID,
                        process: Self.restartMarkerProcess,
                        subsystem: "",
                        category: "",
                        messageType: "Info",
                        eventType: "logEvent",
                        message: "── \(entry.process) restarted: pid \(previous) → \(entry.processID). Lines above are from the previous run. ──"
                    )
                    marker.id = nextID
                    nextID &+= 1
                    entries.append(marker)
                }
                lastFollowedPID = entry.processID
            }
            entry.id = nextID
            nextID &+= 1
            entries.append(entry)
            // Trimmed in chunks: at thousands of events a second, dropping
            // one element per append would shift the whole history each time.
            if entries.count > capacity + max(capacity / 4, 1) {
                entries.removeFirst(entries.count - capacity)
            }
        case .finished:
            break
        case .ignored:
            if !line.isEmpty {
                _ignoredLineCount += 1
            }
        }
    }

    private func finish(generation: UInt64, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation else { return }
        streamTask = nil
        _status = .stopped(reason: reason)
    }

    private func setStatus(_ status: Status) {
        lock.lock()
        _status = status
        lock.unlock()
    }
}
