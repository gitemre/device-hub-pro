import Foundation

/// Appends one JSON line per mirror-stats poll to the file named by
/// `DHP_PERF_LOG`, for `Scripts/perf-check.sh` to read. Disabled — and
/// therefore free — unless the environment variable is set.
public actor PerfLogWriter {
    private let url: URL
    private let encoder = JSONEncoder()

    public init(url: URL) {
        self.url = url
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PerfLogWriter? {
        guard let path = environment["DHP_PERF_LOG"], !path.isEmpty else {
            return nil
        }
        return PerfLogWriter(url: URL(fileURLWithPath: path))
    }

    public func append(_ stats: MirrorStats, device: String, at date: Date = Date()) {
        let entry = Entry(
            t: date.timeIntervalSince1970,
            device: device,
            fps: stats.fps,
            frames: stats.totalFrames,
            dropped: stats.dropped,
            latencyMs: stats.averageLatencyMs
        )
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url)
        {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    private struct Entry: Codable {
        let t: TimeInterval
        /// Which device this sample belongs to (a `DeviceRef.id`: an adb
        /// serial or a UDID), so a two-device run can be read apart.
        let device: String
        let fps: Double
        let frames: Int
        let dropped: Int
        let latencyMs: Double
    }
}
