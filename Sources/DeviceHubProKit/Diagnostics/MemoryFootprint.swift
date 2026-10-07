import Darwin
import Foundation

/// This process's memory footprint, the number Activity Monitor's Memory
/// column and macOS's "your system has run out of application memory" dialog
/// use (`phys_footprint`: dirty and compressed pages, IOSurface and GPU
/// memory the process owns included). Not resident size, which leaves out
/// compressed pages and counts shared ones.
public enum MemoryFootprint {
    /// The footprint in bytes, nil when the kernel does not answer.
    public static func current() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    /// The share of the Mac's memory macOS counts as available, 0...100
    /// (`kern.memorystatus_level`), nil when the kernel does not answer.
    public static func systemFreePercent() -> Int? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 else { return nil }
        return Int(level)
    }

    /// A message when a soak run must stop now: this process holds over
    /// `footprintLimit` or the Mac has under `minimumFreePercent` available.
    public static func soakAbortReason(
        footprintLimit: UInt64 = 1_536 << 20,
        minimumFreePercent: Int = 20
    ) -> String? {
        if let footprint = current(), footprint > footprintLimit {
            return "soak aborted: footprint \(megabytes(footprint)) is over \(megabytes(footprintLimit))"
        }
        if let free = systemFreePercent(), free < minimumFreePercent {
            return "soak aborted: only \(free)% of the Mac's memory is free (limit \(minimumFreePercent)%)"
        }
        return nil
    }

    /// `bytes` as megabytes with one decimal, for log lines.
    public static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}

/// Watches the process's footprint and writes a line to a log file when it
/// grows, so a memory event that ends in macOS's out-of-memory dialog leaves
/// evidence of what the process held and when. It samples every `interval`
/// (a `task_info` call, free), and writes
///
/// - a `start` line, with the process id and its parent's;
/// - a `heartbeat` line every `heartbeatEvery` samples while nothing else is
///   written, so the log shows the footprint's course over a long run;
/// - a `grew` line each time the footprint passes the next of `thresholds`
///   (and a `fell` line when it drops back under the one below), with what
///   the app says it holds (`context`: sessions, cache sizes);
/// - for the first `breakdownLimit` thresholds passed, the process's own
///   `footprint` breakdown by memory category, when `/usr/bin/footprint`
///   answers for this process.
///
/// The file is rotated to `<name>.1` past `maximumBytes`. It holds numbers
/// and counts only: no device names, serials or log text.
public final class FootprintWatchdog: @unchecked Sendable {
    public static let defaultThresholds: [UInt64] = [1, 2, 4, 8, 16].map { $0 << 30 }
    public static let defaultInterval: Duration = .seconds(30)

    private let url: URL
    private let interval: Duration
    private let thresholds: [UInt64]
    private let heartbeatEvery: Int
    private let breakdownLimit: Int
    private let maximumBytes: Int
    private let reader: @Sendable () -> UInt64?
    private let context: @Sendable () -> String
    private let breakdown: @Sendable () -> String?
    private let now: @Sendable () -> Date

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var level = 0
    private var samples = 0
    private var breakdownsTaken = 0
    private var peak: UInt64 = 0

    /// - Parameters:
    ///   - url: the log file; its folder is created.
    ///   - context: a short summary of what the app holds (read on each
    ///     line, from any thread).
    ///   - reader, breakdown, now: test seams.
    public init(
        url: URL,
        interval: Duration = FootprintWatchdog.defaultInterval,
        thresholds: [UInt64] = FootprintWatchdog.defaultThresholds,
        heartbeatEvery: Int = 20,
        breakdownLimit: Int = 3,
        maximumBytes: Int = 1 << 20,
        context: @escaping @Sendable () -> String = { "" },
        reader: @escaping @Sendable () -> UInt64? = { MemoryFootprint.current() },
        breakdown: @escaping @Sendable () -> String? = { FootprintWatchdog.processBreakdown() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.url = url
        self.interval = interval
        self.thresholds = thresholds.sorted()
        self.heartbeatEvery = max(heartbeatEvery, 1)
        self.breakdownLimit = breakdownLimit
        self.maximumBytes = maximumBytes
        self.context = context
        self.reader = reader
        self.breakdown = breakdown
        self.now = now
    }

    /// The default log: `~/Library/Logs/DeviceHubPro/footprint.log`.
    public static var defaultLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DeviceHubPro/footprint.log")
    }

    deinit { task?.cancel() }

    /// Starts sampling; calling it again does nothing.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }
        write("start", footprint: reader() ?? 0, extra: "pid \(getpid()) ppid \(getppid())")
        task = Task.detached(priority: .background) { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                sample()
            }
        }
    }

    public func stop() {
        lock.lock()
        task?.cancel()
        task = nil
        lock.unlock()
    }

    /// One sample: writes a line when the footprint crossed a threshold or
    /// the heartbeat is due. Public for the tests.
    public func sample() {
        guard let footprint = reader() else { return }
        var wantsBreakdown = false
        lock.lock()
        samples += 1
        peak = max(peak, footprint)
        let newLevel = thresholds.filter { footprint >= $0 }.count
        if newLevel > level {
            level = newLevel
            write("grew", footprint: footprint, extra: "passed \(MemoryFootprint.megabytes(thresholds[newLevel - 1]))")
            if breakdownsTaken < breakdownLimit {
                breakdownsTaken += 1
                wantsBreakdown = true
            }
        } else if newLevel < level {
            level = newLevel
            let floor = newLevel > 0 ? MemoryFootprint.megabytes(thresholds[newLevel - 1]) : "the first threshold"
            write("fell", footprint: footprint, extra: "back under \(newLevel < thresholds.count ? MemoryFootprint.megabytes(thresholds[newLevel]) : floor)")
        } else if samples % heartbeatEvery == 0 {
            write("heartbeat", footprint: footprint, extra: "")
        }
        lock.unlock()
        // The breakdown runs a child process: never under the lock.
        if wantsBreakdown, let text = breakdown() {
            lock.lock()
            append("--- footprint breakdown at \(MemoryFootprint.megabytes(footprint)) ---\n\(text)\n--- end ---\n")
            lock.unlock()
        }
    }

    private func write(_ kind: String, footprint: UInt64, extra: String) {
        var line = "\(Self.timestamp(now())) \(kind) footprint \(MemoryFootprint.megabytes(footprint)) peak \(MemoryFootprint.megabytes(max(peak, footprint)))"
        if !extra.isEmpty { line += " \(extra)" }
        let held = context()
        if !held.isEmpty { line += " | \(held)" }
        append(line + "\n")
    }

    private func append(_ text: String) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maximumBytes {
            let rotated = url.appendingPathExtension("1")
            try? fileManager.removeItem(at: rotated)
            try? fileManager.moveItem(at: url, to: rotated)
        }
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// `/usr/bin/footprint` for this process, trimmed to its summary and the
    /// largest categories; nil when it is missing, refuses or takes over 20 s.
    public static func processBreakdown() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
        process.arguments = ["-p", String(getpid())]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        return String(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(40).joined(separator: "\n"))
    }
}
