import Foundation
import Observation
import DeviceHubProKit

/// What the simulator canvas learns about each simulator in its current
/// boot, by UDID, whichever window's stage showed it: the live
/// canvas's failure, whether dtuhidd was already connected, and the
/// interface orientation it was last turned to. App-global: every window's
/// `SimulatorCanvasController` reads and writes this one instance, so a
/// simulator whose live canvas failed in one window gets the view-only
/// canvas in another as well.
@MainActor
@Observable
final class SimulatorCanvasMemory {
    /// Why the live canvas failed for a simulator in its current boot, by
    /// UDID; cleared when it is seen shut down, and by a retry.
    var liveCanvasFailures: [String: String] = [:]
    /// Whether dtuhidd was already connected in the simulator's boot when
    /// its live session last started, by UDID: the flag read before any
    /// input. Nil until read, when it could not be read, and after the
    /// simulator is seen shut down (a boot starts at 0).
    var dtuhiddWasActive: [String: Bool] = [:]
    /// The interface orientation each simulator was last turned to, so a
    /// Face ID iPhone that keeps its interface in landscape when asked for
    /// upside down still turns on (`SimulatorCanvasController`).
    @ObservationIgnored var orientations: [String: SimulatorOrientation] = [:]
    /// The HID channel an Apple TV simulator's remote sends through, by UDID,
    /// for the boot it connected in (`SimulatorCanvasController.pressRemote`).
    @ObservationIgnored var remoteInputs: [String: any SimulatorInputBridging] = [:]

    init() {}

    /// A new listing: a simulator no longer booted forgets its boot's
    /// failure and flag, so its next boot may try the live canvas again.
    func forgetAllBut(booted: Set<String>) {
        for udid in liveCanvasFailures.keys where !booted.contains(udid) {
            liveCanvasFailures[udid] = nil
        }
        for udid in remoteInputs.keys where !booted.contains(udid) {
            remoteInputs[udid]?.disconnect()
            remoteInputs[udid] = nil
        }
        for udid in dtuhiddWasActive.keys where !booted.contains(udid) {
            dtuhiddWasActive[udid] = nil
        }
    }
}
