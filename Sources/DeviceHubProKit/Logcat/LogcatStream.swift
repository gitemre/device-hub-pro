import Foundation
import Synchronization

/// Streams `adb logcat -v threadtime` for one device and keeps a bounded history.
///
/// With no package set the stream is the device's whole log: the ring buffer
/// is replayed, then followed. With a package set the stream follows the app's
/// process id: it polls `pidof` and runs logcat with `--pid` only while the app
/// is alive. While the app is not running no logcat runs at all (the status is
/// `.running(pid: nil)`, "waiting for process"), so a followed package never
/// streams other processes' logs.
///
/// Only the first launch after a filter change replays the ring buffer. Every
/// relaunch (the app restarted, or a `pidof` hiccup) passes `-T <newest held
/// timestamp>`, so history the stream already holds is not re-dumped; the
/// boundary lines logd re-sends for that timestamp are dropped as duplicates.
public final class LogcatStream: @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        case idle
        case running(pid: Int?)
        case stopped(reason: String)
    }

    public let serial: String
    private let adbURL: URL
    private let capacity: Int
    private let pollInterval: Duration

    /// The most one entry's message may hold (continuation lines included).
    /// `capacity` counts entries, so without it a stream of lines that carry
    /// no logcat header (every one is glued to the entry before it) would
    /// grow a single message without end, and each glue copies it again.
    static let maximumMessageBytes = 64 << 10
    /// The most bytes kept while waiting for a newline: a stream that never
    /// sends one (binary output) is cut into lines of this size instead.
    static let maximumPartialLineBytes = 64 << 10
    /// How many bytes of output the reader may have queued for the parser
    /// before it stops reading, so a log that outruns the parser fills the
    /// pipe (and slows `adb`) instead of this process's heap.
    static let maximumQueuedBytes = 8 << 20
    /// The longest the reader waits for the parser to catch up, per chunk.
    static let queueWaitLimit: Duration = .seconds(1)

    /// How many of the newest held entries a relaunch compares incoming lines
    /// against; logd only re-sends the few lines at the `-T` boundary.
    private static let replayOverlapWindow = 64

    private let lock = NSLock()
    private var entries: [LogcatEntry] = []
    private var nextID: UInt64 = 1
    private var historyRevision: UInt64 = 0
    private var _status: Status = .idle
    private var _packageName: String?
    /// Bumped by every start and stop. Work queued for an older generation (a
    /// `pidof` answer that lands after `stop()`) is dropped, so a stopped
    /// stream can never relaunch.
    private var generation: UInt64 = 0
    private var pidTask: Task<Void, Never>?
    /// The device timestamp of the newest parsed entry: the `-T` floor for
    /// relaunches. Reset only by a filter change (`setPackage`).
    private var newestTimestamp: String?
    /// The pid of the newest held device entry while a package is followed:
    /// an entry from another pid means the app restarted, and a marker line
    /// goes before it. Reset with the history.
    private var lastFollowedPID: Int?
    /// The marker's tag, so views and tests can tell it from device lines.
    public static let restartMarkerTag = "DeviceHubPro"
    /// Header keys of the newest entries while a relaunch may re-send them;
    /// cleared by the first incoming entry that is not a duplicate.
    private var replayOverlap: Set<EntryKey>?
    /// A duplicate entry was dropped; its continuation lines go with it.
    private var droppingReplayedEntry = false

    private let ioQueue = DispatchQueue(label: "io.github.gitemre.devicehubpro.logcat")
    /// Bytes read from the pipe and not yet parsed (any thread).
    private let queuedBytes = Mutex((current: 0, peak: 0))
    /// The most bytes ever queued for the parser at once (tests).
    var peakQueuedBytes: Int { queuedBytes.withLock { $0.peak } }
    // ioQueue only.
    private var pending = Data()
    private var process: Process?
    /// The reading end of the current logcat's output, held until its end
    /// of file (or a deliberate stop): the finished `process` is dropped as
    /// soon as its exit is handled, which can come before its last output
    /// has been read, and a pipe freed with it discards that output.
    private var output: FileHandle?
    /// Bumped whenever the running logcat is replaced or deliberately killed,
    /// so output still in flight from the old process is not ingested.
    private var launchToken: UInt64 = 0
    /// How the current logcat is ending on its own: `.stopped` is reported
    /// once it has exited and its output has been read to the end, so the
    /// history then holds every line it printed.
    private var launchExitStatus: Int32?
    private var launchOutputEnded = false
    private var launchEndReported = false

    /// How long an exited logcat's stop waits for the rest of its output:
    /// a child it started may hold the pipe open. The stop is reported then
    /// anyway; lines that come later are still kept.
    static let outputDrainGrace: DispatchTimeInterval = .seconds(5)

    public init(
        adbURL: URL,
        serial: String,
        packageName: String? = nil,
        capacity: Int = 4000,
        pollInterval: Duration = .seconds(1)
    ) {
        self.adbURL = adbURL
        self.serial = serial
        self._packageName = packageName
        self.capacity = capacity
        self.pollInterval = pollInterval
    }

    public var packageName: String? {
        lock.lock()
        defer { lock.unlock() }
        return _packageName
    }

    public var status: Status {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    public func snapshot() -> [LogcatEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.suffix(capacity))
    }

    /// Bumped by every change to the held history (new lines, a clear, a
    /// filter change), so a poller can skip republishing an unchanged tail.
    public var revision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return historyRevision
    }

    /// Most recent entries, oldest first.
    public func tail(_ count: Int) -> [LogcatEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.suffix(min(count, capacity)))
    }

    /// Empties the local history. The device's ring is untouched, and a later
    /// relaunch still resumes after the newest line seen, so cleared lines do
    /// not come back.
    public func clear() {
        lock.lock()
        entries.removeAll()
        historyRevision &+= 1
        lastFollowedPID = nil
        replayOverlap = nil
        droppingReplayedEntry = false
        lock.unlock()
    }

    // MARK: - Lifecycle

    public func start() {
        let (generation, package) = beginGeneration(status: .running(pid: nil))
        ioQueue.async { [self] in
            terminateProcessOnQueue()
        }
        guard let package else {
            ioQueue.async { [weak self] in
                self?.launchLogcatOnQueue(pid: nil, generation: generation)
            }
            return
        }
        // `.running(pid: nil)` is "waiting for process": nothing streams until
        // the first `pidof` answer names one.
        startPIDFollow(package: package, generation: generation)
    }

    public func stop() {
        _ = beginGeneration(status: .idle)
        // Strong on purpose: callers drop the stream right after `stop()`,
        // and a weak capture would then skip the terminate and orphan the
        // `adb logcat` child.
        ioQueue.async { [self] in
            terminateProcessOnQueue()
        }
    }

    deinit {
        // Last line of defence for a stream released while running; nothing
        // else can reach `process` any more.
        pidTask?.cancel()
        output?.readabilityHandler = nil
        if let process {
            process.terminationHandler = nil
            process.terminate()
        }
    }

    /// Sets (or clears) the followed package and restarts the stream. The
    /// history is emptied: entries from the previous filter would otherwise
    /// mix with the new filter's replay.
    public func setPackage(_ name: String?) {
        lock.lock()
        _packageName = name
        entries.removeAll()
        historyRevision &+= 1
        lastFollowedPID = nil
        newestTimestamp = nil
        replayOverlap = nil
        droppingReplayedEntry = false
        // Retire the old filter's in-flight output together with the clear.
        generation &+= 1
        lock.unlock()
        start()
    }

    /// Invalidates everything the previous start queued and cancels its
    /// follow loop. `status` is applied atomically with the bump when given.
    private func beginGeneration(status: Status?) -> (UInt64, String?) {
        lock.lock()
        generation &+= 1
        let current = generation
        let package = _packageName
        let task = pidTask
        pidTask = nil
        if let status {
            _status = status
        }
        lock.unlock()
        task?.cancel()
        return (current, package)
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.generation == generation
    }

    // MARK: - PID follow

    private struct FollowState {
        var lastPID: Int?
        var isFirstAnswer = true
    }

    private func startPIDFollow(package: String, generation: UInt64) {
        // The loop holds the stream only during a poll, never across its
        // sleep, so a stream released without `stop()` still deinits.
        let task = Task { [weak self] in
            var state = FollowState()
            while !Task.isCancelled {
                guard let interval = await self?.pollOnce(
                    package: package,
                    generation: generation,
                    state: &state
                ) else {
                    return
                }
                try? await Task.sleep(for: interval)
            }
        }
        lock.lock()
        if self.generation == generation {
            pidTask = task
            lock.unlock()
        } else {
            lock.unlock()
            task.cancel()
        }
    }

    /// One poll of the follow loop: acts on a changed answer and returns the
    /// delay before the next poll, or nil when the loop must end.
    private func pollOnce(
        package: String,
        generation: UInt64,
        state: inout FollowState
    ) async -> Duration? {
        let pid = await queryPID(package)
        // A cancelled `pidof` reads as "no process"; acting on it would kill
        // (or relaunch) a stream that was just stopped.
        guard !Task.isCancelled, isCurrent(generation) else { return nil }
        if state.isFirstAnswer || pid != state.lastPID {
            state.isFirstAnswer = false
            state.lastPID = pid
            ioQueue.async { [weak self] in
                self?.followOnQueue(pid: pid, generation: generation)
            }
        }
        return pollInterval
    }

    private func queryPID(_ package: String) async -> Int? {
        let result = try? await ProcessRunner.run(
            executable: adbURL,
            arguments: ["-s", serial, "shell", "pidof", package],
            timeout: .seconds(5)
        )
        guard let result, result.exitCode == 0 else { return nil }
        let text = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(separator: " ").first.flatMap { Int($0) }
    }

    // MARK: - Process (ioQueue only)

    /// A followed app's process appeared, changed or went away: stream its
    /// pid, or stop streaming until it comes back.
    private func followOnQueue(pid: Int?, generation: UInt64) {
        guard isCurrent(generation) else { return }
        if let pid {
            launchLogcatOnQueue(pid: pid, generation: generation)
        } else {
            terminateProcessOnQueue()
            setStatus(.running(pid: nil), ifGeneration: generation)
        }
    }

    private func launchLogcatOnQueue(pid: Int?, generation: UInt64) {
        guard isCurrent(generation) else { return }
        terminateProcessOnQueue()

        let process = Process()
        process.executableURL = adbURL
        var arguments = ["-s", serial, "logcat", "-v", "threadtime"]
        if let pid {
            arguments.append("--pid=\(pid)")
        }
        if let floor = beginRelaunchOverlap() {
            arguments += ["-T", floor]
        }
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        launchToken &+= 1
        let token = launchToken
        launchExitStatus = nil
        launchOutputEnded = false
        launchEndReported = false
        output = pipe.fileHandleForReading
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // End of file: every line has been read. A handle at end of
                // file keeps calling its handler, so it goes now.
                handle.readabilityHandler = nil
                self?.ioQueue.async { [weak self] in
                    guard let self, self.launchToken == token else { return }
                    self.output = nil
                    self.launchOutputEnded = true
                    self.reportLaunchEnd(generation: generation)
                }
                return
            }
            guard let self else { return }
            // Backpressure: past the budget this handler (the pipe's own
            // thread) waits, so the child blocks on a full pipe instead of
            // the parser's backlog growing without bound.
            self.waitForRoom()
            self.queuedBytes.withLock {
                $0.current += data.count
                $0.peak = max($0.peak, $0.current)
            }
            self.ioQueue.async { [weak self] in
                guard let self else { return }
                self.queuedBytes.withLock { $0.current -= data.count }
                guard self.launchToken == token else { return }
                self.ingestOnQueue(data, generation: generation)
            }
        }

        do {
            // A logcat that exits on its own (adb died, device unplugged)
            // reports a stopped status so the UI can show its disconnected
            // state — once what it printed is in the history. Deliberate
            // stops nil the handler first.
            process.terminationHandler = { [weak self] finished in
                ChildProcessRegistry.unregister(finished)
                guard let self else { return }
                self.ioQueue.async { [weak self] in
                    guard let self, self.process === finished else { return }
                    self.process = nil
                    self.launchExitStatus = finished.terminationStatus
                    self.reportLaunchEnd(generation: generation)
                    self.ioQueue.asyncAfter(deadline: .now() + Self.outputDrainGrace) { [weak self] in
                        guard let self, self.launchToken == token else { return }
                        self.reportLaunchEnd(generation: generation, waitingForOutput: false)
                    }
                }
            }
            try process.run()
            ChildProcessRegistry.register(process)
            self.process = process
            setStatus(.running(pid: pid), ifGeneration: generation)
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            output = nil
            setStatus(.stopped(reason: "\(error)"), ifGeneration: generation)
        }
    }

    /// Blocks the caller while more than `maximumQueuedBytes` wait for the
    /// parser, for at most `queueWaitLimit`.
    private func waitForRoom() {
        let deadline = ContinuousClock.now + Self.queueWaitLimit
        while queuedBytes.withLock({ $0.current }) > Self.maximumQueuedBytes, ContinuousClock.now < deadline {
            usleep(2_000)
        }
    }

    /// Reports the current logcat's own exit as `.stopped`, once: when it
    /// has exited and its output has ended, or — `waitingForOutput` false,
    /// after `outputDrainGrace` — when it has exited at all.
    private func reportLaunchEnd(generation: UInt64, waitingForOutput: Bool = true) {
        guard !launchEndReported,
              let status = launchExitStatus,
              launchOutputEnded || !waitingForOutput
        else { return }
        launchEndReported = true
        setStatus(.stopped(reason: "logcat exited with status \(status)"), ifGeneration: generation)
    }

    private func terminateProcessOnQueue() {
        launchToken &+= 1
        pending.removeAll()
        // The reading end can outlive an exited process; a deliberate stop
        // or relaunch drops it (with its handler) whether or not a process
        // is still running.
        output?.readabilityHandler = nil
        output = nil
        guard let process else { return }
        process.terminationHandler = nil
        ChildProcessRegistry.unregister(process)
        process.terminate()
        self.process = nil
    }

    /// The `-T` floor for the launch about to start, or nil for the first
    /// launch after a filter change (which replays the ring on purpose). With
    /// a floor, the newest held entries are armed as the duplicate filter for
    /// the boundary lines logd re-sends.
    private func beginRelaunchOverlap() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let floor = newestTimestamp else {
            replayOverlap = nil
            return nil
        }
        let recent = entries.suffix(Self.replayOverlapWindow).map(EntryKey.init)
        replayOverlap = recent.isEmpty ? nil : Set(recent)
        droppingReplayedEntry = false
        return floor
    }

    // MARK: - Ingest (ioQueue only)

    private func ingestOnQueue(_ data: Data, generation: UInt64) {
        pending.append(data)
        var parsed: [LogcatParser.ParsedLine] = []
        var lineStart = pending.startIndex
        while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
            var lineEnd = newline
            // Older adb/device pairs deliver CRLF.
            if lineEnd > lineStart, pending[pending.index(before: lineEnd)] == 0x0D {
                lineEnd = pending.index(before: lineEnd)
            }
            let lineData = pending[lineStart..<lineEnd]
            lineStart = pending.index(after: newline)
            guard !lineData.isEmpty else { continue }
            // Lossy on purpose: liblog truncates messages mid-character and
            // native code logs raw bytes; a strict decode would drop the line.
            let line = String(decoding: lineData.prefix(Self.maximumMessageBytes), as: UTF8.self)
            // `--------- beginning of crash` and friends are buffer markers,
            // not log text; glued onto the previous entry they would make an
            // unrelated line read as a crash.
            guard !LogcatParser.isBufferMarker(line) else { continue }
            parsed.append(LogcatParser.parse(line))
        }
        pending.removeSubrange(pending.startIndex..<lineStart)
        if pending.count > Self.maximumPartialLineBytes {
            // No newline in a very long stretch: take it as a line.
            parsed.append(LogcatParser.parse(String(decoding: pending.prefix(Self.maximumMessageBytes), as: UTF8.self)))
            pending.removeAll()
        }
        if !parsed.isEmpty {
            append(parsed, generation: generation)
        }
    }

    private func append(_ lines: [LogcatParser.ParsedLine], generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        // Output of a stream that was stopped or re-filtered meanwhile.
        guard self.generation == generation else { return }

        if !lines.isEmpty { historyRevision &+= 1 }
        for parsed in lines {
            switch parsed {
            case .entry(var entry):
                if let overlap = replayOverlap {
                    if overlap.contains(EntryKey(entry)) {
                        droppingReplayedEntry = true
                        continue
                    }
                    replayOverlap = nil
                }
                droppingReplayedEntry = false
                if let package = _packageName, entry.pid != 0 {
                    if let previous = lastFollowedPID, previous != entry.pid {
                        var marker = LogcatEntry(
                            timestamp: entry.timestamp,
                            pid: entry.pid,
                            tid: entry.pid,
                            level: .info,
                            tag: Self.restartMarkerTag,
                            message: "── \(package) restarted: pid \(previous) → \(entry.pid). Lines above are from the previous run. ──"
                        )
                        marker.id = nextID
                        nextID += 1
                        entries.append(marker)
                    }
                    lastFollowedPID = entry.pid
                }
                entry.id = nextID
                nextID += 1
                if !entry.timestamp.isEmpty {
                    newestTimestamp = entry.timestamp
                }
                entries.append(entry)

            case .continuation(let text), .unparsed(let text):
                guard !droppingReplayedEntry else { continue }
                if var last = entries.popLast() {
                    if last.message.utf8.count < Self.maximumMessageBytes {
                        last.message += "\n" + text
                        if last.message.utf8.count >= Self.maximumMessageBytes {
                            last.message += "\n… (message cut at \(Self.maximumMessageBytes >> 10) KB)"
                        }
                    }
                    entries.append(last)
                } else {
                    var entry = LogcatEntry(
                        timestamp: "",
                        pid: 0,
                        tid: 0,
                        level: .info,
                        tag: "",
                        message: text
                    )
                    entry.id = nextID
                    nextID += 1
                    entries.append(entry)
                }
            }
        }

        // Trim in chunks: removeFirst moves every kept entry, so doing it
        // per batch costs O(capacity) each time. `snapshot()` and `tail`
        // never show more than `capacity`.
        if entries.count > capacity + capacity / 4 {
            entries.removeFirst(entries.count - capacity)
        }
    }

    private func setStatus(_ value: Status, ifGeneration generation: UInt64) {
        lock.lock()
        if self.generation == generation {
            _status = value
        }
        lock.unlock()
    }
}

/// The identity of one logcat line for duplicate detection across a `-T`
/// relaunch: the header plus the first message line (continuations appended
/// later must not make a re-sent line look new).
private struct EntryKey: Hashable {
    let timestamp: String
    let pid: Int
    let tid: Int
    let level: LogcatLevel
    let tag: String
    let firstLine: Substring

    init(_ entry: LogcatEntry) {
        timestamp = entry.timestamp
        pid = entry.pid
        tid = entry.tid
        level = entry.level
        tag = entry.tag
        firstLine = entry.message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first ?? ""
    }
}
