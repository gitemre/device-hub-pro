import Foundation

/// A snapshot of stream statistics for the UI overlay.
public struct MirrorStats: Sendable {
    public let fps: Double
    public let totalFrames: Int
    public let dropped: Int
    public let averageLatencyMs: Double

    public init(fps: Double, totalFrames: Int, dropped: Int, averageLatencyMs: Double) {
        self.fps = fps
        self.totalFrames = totalFrames
        self.dropped = dropped
        self.averageLatencyMs = averageLatencyMs
    }

    public var overlayText: String {
        String(
            format: "%5.1f fps   %6d frames   %4d dropped   %5.1f ms",
            fps, totalFrames, dropped, averageLatencyMs
        )
    }
}

/// Collects frame statistics. An actor because stream callbacks are `@Sendable`.
actor StreamStatsCounter {
    private let startedAt = Date()
    private var windowStart = Date()
    private var windowFrames = 0
    private var totalFrames = 0
    private var dropped = 0
    private var lastSeq: UInt32 = 0
    private var latencySum = 0.0
    private var latencyCount = 0
    private var currentFps = 0.0

    func record(seq: UInt32, timestampUs: UInt64) {
        let now = Date()
        totalFrames += 1
        windowFrames += 1

        if lastSeq != 0, seq > lastSeq + 1 {
            dropped += Int(seq - lastSeq - 1)
        }
        lastSeq = seq

        if timestampUs > 0 {
            let latency = (now.timeIntervalSince1970 * 1_000_000 - Double(timestampUs)) / 1000
            latencySum += latency
            latencyCount += 1
        }

        let window = now.timeIntervalSince(windowStart)
        if window >= 1.0 {
            currentFps = Double(windowFrames) / window
            windowStart = now
            windowFrames = 0
        }
    }

    func snapshot() -> MirrorStats {
        MirrorStats(
            fps: currentFps,
            totalFrames: totalFrames,
            dropped: dropped,
            averageLatencyMs: latencyCount > 0 ? latencySum / Double(latencyCount) : 0
        )
    }
}
