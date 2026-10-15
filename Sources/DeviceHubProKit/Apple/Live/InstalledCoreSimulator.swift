import Foundation
import Synchronization

/// The installed CoreSimulator's version and the bridge's verdict for it
/// (`BridgeCompatibility`), kept between reads.
///
/// The app asks both whenever it decides what a foldable simulator offers
/// (`SimulatorFoldController.foldableEntry` goes through
/// `SimulatorCanvasController.canvas(for:)`), which the stage's views do
/// dozens of times for each body they build, and the hinge slider and a
/// preset's sweep once for each event and step: each ask read the framework's
/// Info.plist from disk and parsed it, twice. Here the file is looked at
/// again at most once per `recheckInterval`, read again only when its
/// modification date differs from the one last read (an Xcode update replaced
/// it), and the verdict is worked out again at each look (the environment
/// switches are read then), so a changed install shows within the interval.
public final class InstalledCoreSimulator: Sendable {
    /// How long a look at the file stands.
    public static let defaultRecheckInterval: Duration = .seconds(1)

    private struct State {
        var hasRead = false
        var modified: Date?
        var version: String?
        var verdict: BridgeCompatibility.Verdict = .disabled
        var checked: ContinuousClock.Instant?
    }

    private let infoPlist: URL
    private let recheckInterval: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let modificationDate: @Sendable (URL) -> Date?
    private let readVersion: @Sendable (URL) -> String?
    private let environment: @Sendable () -> [String: String]
    private let state = Mutex(State())

    /// The live probe: the system's CoreSimulator, the process's environment.
    /// The closures stand in for the clock, the file's date, the file's
    /// contents and the environment, for tests.
    public init(
        infoPlist: URL = BridgeCompatibility.coreSimulatorInfoPlist,
        recheckInterval: Duration = InstalledCoreSimulator.defaultRecheckInterval,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        modificationDate: @escaping @Sendable (URL) -> Date? = { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        },
        readVersion: @escaping @Sendable (URL) -> String? = { BridgeCompatibility.installedCoreSimulatorVersion(infoPlist: $0) },
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.infoPlist = infoPlist
        self.recheckInterval = recheckInterval
        self.now = now
        self.modificationDate = modificationDate
        self.readVersion = readVersion
        self.environment = environment
    }

    /// The installed CoreSimulator's `CFBundleVersion`; nil when it is
    /// missing or unreadable (`BridgeCompatibility.installedCoreSimulatorVersion`).
    public func version() -> String? {
        reading().version
    }

    /// Whether the bridge may load on it (`BridgeCompatibility.verdict`).
    public func verdict() -> BridgeCompatibility.Verdict {
        reading().verdict
    }

    private func reading() -> (version: String?, verdict: BridgeCompatibility.Verdict) {
        state.withLock { state in
            let instant = now()
            if let checked = state.checked, instant - checked < recheckInterval {
                return (state.version, state.verdict)
            }
            state.checked = instant
            let modified = modificationDate(infoPlist)
            if !state.hasRead || modified != state.modified {
                state.hasRead = true
                state.modified = modified
                state.version = readVersion(infoPlist)
            }
            state.verdict = BridgeCompatibility.verdict(coreSimulatorVersion: state.version, environment: environment())
            return (state.version, state.verdict)
        }
    }
}
