/// The bookkeeping of in-app AVD starts (Start, including an attach to a
/// running VM, and Power On): which starts are in flight, which of them show
/// the booting panel, and which the user stopped while they ran.
///
/// `EmulatorBootController` keeps it, unobserved except for `starting`
/// (its `startingAvdNames`), and `bootEmulator` reads the stop marks.
/// `AppModel`'s orchestrators (`startAndMirror`, `powerOnDevice`,
/// `stopEmulator`) drive it through the controller and still claim a start
/// before its first await.
struct AvdStartRegistry: Equatable, Sendable {
    /// The AVDs with a Start (launch or attach) or Power On in flight, from
    /// the moment it is asked for: claimed before its first await, so a
    /// second request for the same AVD is a no-op and a Stop always finds
    /// it. Not shown anywhere: attaching to a running AVD must not show its
    /// booting panel, which `starting` drives.
    private(set) var inFlight: Set<String> = []
    /// The AVDs an in-app start or restart is booting (`startingAvdNames`).
    /// The canvas shows their booting panel until the boot completes (spec
    /// §6.4). A set: two AVDs can boot at once, and one finishing must not
    /// end the other's.
    private(set) var starting: Set<String> = []
    /// Starts the user stopped while they were in flight: they end silently
    /// (no "exited during startup") and never start a session on the VM
    /// being shut down.
    private(set) var stoppedByUser: Set<String> = []

    /// Claims `avd` for a start. False, and nothing changes, when a start of
    /// it is already in flight: a second launch would shut the booting
    /// instance down.
    mutating func claim(_ avd: String) -> Bool {
        guard !inFlight.contains(avd) else { return false }
        inFlight.insert(avd)
        return true
    }

    /// The claimed start is booting a VM: the stage shows its booting panel.
    mutating func markBooting(_ avd: String) {
        starting.insert(avd)
    }

    /// Android finished booting: the booting panel ends, while the claim
    /// holds until `finish(_:)`.
    mutating func markBooted(_ avd: String) {
        starting.remove(avd)
    }

    /// Whether `avd` shows its booting panel.
    func isStarting(_ avd: String) -> Bool {
        starting.contains(avd)
    }

    /// Whether a start of `avd` is in flight.
    func isInFlight(_ avd: String) -> Bool {
        inFlight.contains(avd)
    }

    /// The user stops `avd`. Only a start in flight is marked: it then ends
    /// silently instead of reporting the VM's exit, and starts no session.
    mutating func requestStop(_ avd: String) {
        if inFlight.contains(avd) {
            stoppedByUser.insert(avd)
        }
    }

    /// The stop failed and the VM lives on, so a boot still waiting on it
    /// must report as usual.
    mutating func withdrawStop(_ avd: String) {
        stoppedByUser.remove(avd)
    }

    /// Whether the user stopped the start of `avd` while it was in flight.
    func isStoppedByUser(_ avd: String) -> Bool {
        stoppedByUser.contains(avd)
    }

    /// The VM exited during startup: true, consuming the mark, when that is
    /// the user's stop; false when the exit is a failure to report.
    mutating func consumeStop(_ avd: String) -> Bool {
        stoppedByUser.remove(avd) != nil
    }

    /// The start ended, however it ended: its claim, its booting panel and
    /// its stop mark all go.
    mutating func finish(_ avd: String) {
        inFlight.remove(avd)
        starting.remove(avd)
        stoppedByUser.remove(avd)
    }
}
