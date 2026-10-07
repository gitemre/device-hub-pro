/// Keeps the Controls poll off the settings rows a write owns.
///
/// While a settings write runs, the poll leaves the settings rows alone: a
/// stale read would flip an optimistically updated row back to the
/// pre-write value before the reconcile lands. A poll whose reads merely
/// overlapped a write, even one that finished before the poll applies,
/// drops its settings rows too.
///
/// `DeviceControlsController` keeps one as `writeFence` (adopted in S17):
/// each settings write brackets itself with `beginSettingsWrite()` and
/// `endSettingsWrite()`, and `refreshControls` takes a `pollTicket` before
/// its reads and asks `admits(pollStartedAt:)` before it applies them. This
/// replaced `AppModel`'s `settingsWriteDepth` (with its didSet) and
/// `settingsWritesStarted`.
struct SettingsWriteFence: Equatable, Sendable {
    /// Settings writes in flight.
    private(set) var depth = 0 {
        didSet {
            if depth > oldValue { writesStarted &+= 1 }
        }
    }
    /// Settings writes started so far; wraps rather than traps.
    private(set) var writesStarted: UInt64

    /// A fence with no write in flight that has seen `writesStarted` writes
    /// start (0 for a new panel).
    init(writesStarted: UInt64 = 0) {
        self.writesStarted = writesStarted
    }

    /// Whether no write is in flight: the poll reads the settings rows only
    /// then.
    var isIdle: Bool { depth == 0 }

    /// What a poll records as its reads start.
    var pollTicket: UInt64 { writesStarted }

    /// A write starts: in flight until `endWrite()`, started for good.
    mutating func beginWrite() {
        depth += 1
    }

    /// The write started by the matching `beginWrite()` ended.
    mutating func endWrite() {
        depth -= 1
    }

    /// Whether a poll whose reads started at `ticket` may apply its settings
    /// rows: no write is in flight now and none started since.
    func admits(pollStartedAt ticket: UInt64) -> Bool {
        depth == 0 && writesStarted == ticket
    }
}
