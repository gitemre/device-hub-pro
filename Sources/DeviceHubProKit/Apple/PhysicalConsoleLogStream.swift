import Foundation

/// Parses the lines `devicectl device process launch --console` prints while
/// an app runs with `OS_ACTIVITY_DT_MODE` set.
///
/// Captured live against the dedicated test iPhone (iOS 27.0, Xcode 27.0
/// 27A266a; `Fixtures/ios27-device/devicectl-console-launch.txt`):
///
///     2026-10-01 23:53:20.030000+0300 DeviceHubProAgentHost[1025:229467] [host] host app launched
///
/// that is: the device-local timestamp, the process name, `[pid:tid]`, the
/// os_log category in brackets (absent for NSLog and a bare `os_log`, empty
/// for a Logger without one), then the message. The subsystem and the level
/// are not part of the line: every message shows as Info. A line without that
/// prefix is the app's own standard output (`print`) or the rest of a
/// multi-line message; devicectl's own status lines open and close the output.
public enum PhysicalConsoleLogParsing {
    public enum Line: Sendable, Equatable {
        /// A mirrored os_log / Logger / NSLog message.
        case entry(timestamp: String, process: String, pid: Int, tid: Int, category: String, message: String)
        /// Text without the prefix: the app's `print` output, a continuation
        /// of a multi-line message, or a devicectl error line.
        case plain(String)
        /// devicectl's `App terminated due to signal 2.` / exit line: the
        /// session ended.
        case ended(String)
        /// devicectl's opening status lines and blanks.
        case ignored
    }

    private static let prefix = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+[+-]\d{4}) (.*?)\[(\d+):(\d+)\] (.*)$"#
    )
    private static let category = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"^\[([^\]\s]*)\] (.*)$"#
    )

    public static func parse(_ rawLine: String) -> Line {
        var line = rawLine
        while line.hasSuffix("\r") { line.removeLast() }
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return .ignored }
        if line.hasPrefix("Launched application with ") || line == "Waiting for the application to terminate..." {
            return .ignored
        }
        if line.hasPrefix("App terminated") || line.hasPrefix("App exited") {
            return .ended(line)
        }
        let whole = NSRange(line.startIndex..., in: line)
        guard let match = prefix.firstMatch(in: line, range: whole) else { return .plain(line) }
        func group(_ index: Int) -> String {
            Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
        var message = group(5)
        var categoryName = ""
        if let tagged = category.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
           let name = Range(tagged.range(at: 1), in: message),
           let rest = Range(tagged.range(at: 2), in: message) {
            categoryName = String(message[name])
            message = String(message[rest])
        }
        return .entry(
            timestamp: group(1),
            process: group(2),
            pid: Int(group(3)) ?? 0,
            tid: Int(group(4)) ?? 0,
            category: categoryName,
            message: message
        )
    }
}

/// Streams one app's console through `DevicectlPhysicalClient.consoleCommandLine`
/// into a bounded history of `LogcatEntry` — the physical-iPhone counterpart of
/// `SimulatorLogStream`. Starting it launches the app on the phone
/// (`--terminate-existing`), and stopping it ends devicectl with SIGINT, which
/// devicectl forwards to the app: stopping the stream ends the app session.
/// A child that ignores the signal is killed after
/// `ProcessRunner.terminationGracePeriod`.
public final class PhysicalConsoleLogStream: @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        case idle
        case running
        /// devicectl ended: the app exited or crashed, the phone went away, or
        /// the launch failed (`reason`).
        case stopped(reason: String)
    }

    public let bundleID: String
    private let argv: [String]
    private let devicectlURL: URL
    private let environment: [String: String]
    private let capacity: Int

    private let lock = NSLock()
    private var entries: [LogcatEntry] = []
    private var nextID: UInt64 = 1
    private var _status: Status = .idle
    private var streamTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    /// What devicectl said besides log lines (the end line, an error): the
    /// reason shown when the session ends.
    private var notes: [String] = []
    private var lastProcess: String
    private var lastTimestamp = ""

    /// The stream of `bundleID` on the client's phone. Throws, without
    /// launching anything, unless the client's gate allows the command.
    public init(client: DevicectlPhysicalClient, bundleID: String, capacity: Int = 4000) throws {
        self.argv = try client.consoleCommandLine(bundleID: bundleID)
        self.devicectlURL = client.devicectlURL
        self.environment = client.developerDirectory.map { ["DEVELOPER_DIR": $0.path] } ?? [:]
        self.bundleID = bundleID
        self.capacity = capacity
        self.lastProcess = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    deinit {
        streamTask?.cancel()
    }

    public var arguments: [String] { argv }

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

    /// The held entries newer than `id`, oldest first.
    public func entries(after id: UInt64) -> [LogcatEntry] {
        lock.lock()
        defer { lock.unlock() }
        var low = 0
        var high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].id <= id { low = middle + 1 } else { high = middle }
        }
        return Array(entries[low...])
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    // MARK: Lifecycle

    public func start() {
        lock.lock()
        generation &+= 1
        let generation = self.generation
        let previous = streamTask
        _status = .running
        notes = []
        lock.unlock()
        previous?.cancel()

        let executable = devicectlURL
        let argv = self.argv
        let environment = self.environment
        let task = Task { [weak self] in
            do {
                let exitCode = try await ProcessRunner.stream(
                    executable: executable,
                    arguments: argv,
                    environment: environment,
                    stopSignal: .interrupt,
                    onLine: { [weak self] line in
                        self?.ingest(line, generation: generation)
                    }
                )
                self?.finish(generation: generation, exitCode: exitCode)
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

    /// Ends devicectl, and with it the app session. Returns once the stop is
    /// requested; the child is gone within the grace period at the latest.
    public func stop() {
        _ = takeTaskForStop()?.cancel()
    }

    /// Ends devicectl and waits until the child process has exited.
    public func stopAndWait() async {
        let task = takeTaskForStop()
        task?.cancel()
        await task?.value
    }

    private func takeTaskForStop() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        let task = streamTask
        streamTask = nil
        _status = .idle
        return task
    }

    // MARK: Ingest (reader thread)

    private func ingest(_ rawLine: String, generation: UInt64) {
        let parsed = PhysicalConsoleLogParsing.parse(rawLine)
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation else { return }
        switch parsed {
        case .entry(let timestamp, let process, let pid, let tid, let category, let message):
            lastProcess = process
            let shown = SimulatorLogParsing.logcatTimestamp(timestamp)
            lastTimestamp = shown
            append(LogcatEntry(
                timestamp: shown, pid: pid, tid: tid, level: .info,
                tag: process, message: message, subsystem: category
            ))
        case .plain(let text):
            notes.append(text)
            if notes.count > 5 { notes.removeFirst() }
            append(LogcatEntry(
                timestamp: lastTimestamp, pid: 0, tid: 0, level: .info,
                tag: lastProcess, message: text, subsystem: "stdout"
            ))
        case .ended(let text):
            notes.append(text)
        case .ignored:
            break
        }
    }

    private func append(_ entry: LogcatEntry) {
        var entry = entry
        entry.id = nextID
        nextID &+= 1
        entries.append(entry)
        if entries.count > capacity + max(capacity / 4, 1) {
            entries.removeFirst(entries.count - capacity)
        }
    }

    private func finish(generation: UInt64, exitCode: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation else { return }
        streamTask = nil
        let detail = notes.last.map { ": \($0)" } ?? ""
        _status = .stopped(reason: "the app session ended (devicectl status \(exitCode))\(detail)")
    }

    private func finish(generation: UInt64, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation else { return }
        streamTask = nil
        _status = .stopped(reason: reason)
    }
}
