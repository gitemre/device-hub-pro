import Foundation
import Observation
import DeviceHubProKit

/// What Device Hub Pro keeps for each simulator, by UDID, whichever Controls panel
/// shows it: the location it set, the status bar model, the
/// languages waiting for a respring, the changes in flight and the zone its
/// boots take. App-global: every window's `AppleControlsController` reads
/// and writes this one instance, so two panels over one simulator agree
/// (a write in flight in one disables the row in the other).
@MainActor
@Observable
final class AppleDeviceMemory {
    /// The controls with a change in flight, per simulator (UDID →
    /// controls): a slow write on one simulator (VoiceOver takes about
    /// 1.5 s) never disables another's rows or skips its poll.
    var busyControls: [String: Set<AppleControl>] = [:]
    /// The simulators whose language changed since their last respring:
    /// their home screen and status bar still show the old one.
    var respringPending: Set<String> = []
    /// What Device Hub Pro set as each simulator's location (UDID → choice).
    var locations: [String: AppleLocationChoice] = [:]
    /// Each simulator's status bar model (UDID → state).
    var statusBars: [String: SimulatorStatusBarState] = [:]

    @ObservationIgnored private let preferences: AppPreferences

    init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    func markBusy(_ control: AppleControl, on udid: String) {
        busyControls[udid, default: []].insert(control)
    }

    func clearBusy(_ control: AppleControl, on udid: String) {
        busyControls[udid]?.remove(control)
        if busyControls[udid]?.isEmpty == true { busyControls[udid] = nil }
    }

    /// The zone chosen for `udid` (nil: the Mac's), for the boots Device Hub Pro
    /// starts; kept in Settings.
    func timeZone(for udid: String) -> String? { preferences.simulatorTimeZones[udid] }

    /// Chooses `udid`'s boot zone (nil: the Mac's).
    func setTimeZone(_ identifier: String?, udid: String) {
        preferences.setSimulatorTimeZone(identifier, udid: udid)
    }
}
