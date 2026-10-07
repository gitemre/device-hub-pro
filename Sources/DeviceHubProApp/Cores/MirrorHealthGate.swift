import DeviceHubProKit

/// The grace gate that ends a physical mirror's reconnect episode: the
/// episode ends on the first frame-bearing stats poll, or on the second
/// consecutive clean poll when the transport shows no frame evidence at all,
/// and only once per session.
///
/// Frame delivery proves the transport on the spot, one poll behind the
/// first frames (~500 ms, well inside the ≤3 s perceived-resume budget);
/// otherwise two clean polls (~1 s) stand in, never the old six (~3 s). A
/// dead stream reports `lastError` and never reaches the gate.
///
/// `MirrorController` keeps one per session as `healthGate`: its
/// `noteCleanStatsPoll` reports health to the lifecycle when `noteCleanPoll`
/// says so, and every teardown resets it (`resetMirrorHealth`).
struct MirrorHealthGate: Equatable, Sendable {
    /// Consecutive clean polls that stand in for frame evidence on a
    /// transport showing none.
    static let threshold = 2

    /// Clean polls in the current session; stops counting once health is
    /// reported.
    private(set) var cleanPolls = 0
    /// Whether this mirror session's health has been reported: the frame signal
    /// can fire on the very first poll, and the episode ends exactly once.
    private(set) var reported = false

    init() {}

    /// The grace rule. `cleanPolls` counts the current poll; `totalFrames`
    /// and `fps` come from this mirror session's counter, so a previous episode's
    /// frames never count.
    static func signalReached(stats: MirrorStats, cleanPolls: Int) -> Bool {
        if stats.totalFrames > 0 || stats.fps > 0 { return true }
        return cleanPolls >= threshold
    }

    /// One clean poll of the session. True exactly when this poll ends the
    /// episode: its owner then reports the mirror healthy. Every later poll
    /// is ignored until `reset()`.
    mutating func noteCleanPoll(_ stats: MirrorStats) -> Bool {
        guard !reported else { return false }
        cleanPolls += 1
        guard Self.signalReached(stats: stats, cleanPolls: cleanPolls) else { return false }
        reported = true
        return true
    }

    /// The mirror stopped: the next session starts a new count.
    mutating func reset() {
        cleanPolls = 0
        reported = false
    }
}
