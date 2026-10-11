import DeviceHubProKit
import Foundation
import Observation

/// The fold strip's driver for a foldable simulator (iPhone Duo), as
/// `EmulatorHardwareController` is a foldable emulator's: the presets and
/// the hinge slider send the angle (`SimulatorFoldSender`), the inventory
/// records it, and when the lit panel changes the stage's session follows
/// it to the other panel (`SimulatorCanvasController.followFold`).
@MainActor
@Observable
final class SimulatorFoldController: FoldControlDriving {
    @ObservationIgnored let simulators: SimulatorInventory
    @ObservationIgnored let canvas: SimulatorCanvasController
    /// The device the workspace mirrors.
    @ObservationIgnored var mirroredDevice: @MainActor () -> DeviceRef? = { nil }
    @ObservationIgnored var environment: [String: String] = ProcessInfo.processInfo.environment
    /// The batch of the last preset or held posture sent to a simulator,
    /// which the 3D model follows (`foldProgress`); nil once the hinge moved
    /// another way (the slider).
    @ObservationIgnored private var sweepBatch: (udid: String, batch: Int)?

    init(simulators: SimulatorInventory, canvas: SimulatorCanvasController) {
        self.simulators = simulators
        self.canvas = canvas
    }

    /// The mirrored simulator, when it is a booted foldable on the live
    /// canvas (the hinge goes through the bridge the live canvas uses).
    private var foldableEntry: SimulatorEntry? {
        guard !SimulatorFold.isDisabled(environment: environment),
              let device = mirroredDevice(), device.platform == .apple,
              let entry = simulators.entry(udid: device.id),
              entry.device.state == .booted,
              simulators.foldPanels(for: entry) != nil,
              simulators.foldSender != nil,
              canvas.canvas(for: entry).isLive
        else { return nil }
        return entry
    }

    var showsFoldControls: Bool { foldableEntry != nil }

    /// The device's 3D model, when Xcode ships a checked one.
    var deviceModel: AppleDeviceModel? {
        foldableEntry.flatMap { simulators.deviceModel(for: $0) }
    }

    /// The panel lit now (what the stage's session shows).
    var litPanel: SimulatorFoldPanel {
        foldableEntry.map { simulators.litPanel(of: $0) } ?? .outer
    }

    /// How the lit panel rests, in counter-clockwise quarter turns as
    /// `AppleChromePose` counts them: iPhone Duo's open panel rests a
    /// quarter turn round (3), its closed one upright (0).
    var restingTurns: Int {
        guard let entry = foldableEntry, let panels = simulators.foldPanels(for: entry) else { return 0 }
        return AppleChromePose.turns(
            for: SimulatorFold.restingRotation(of: panels.profile(of: simulators.litPanel(of: entry)))
        )
    }

    /// The angle Device Hub Pro last sent; 0 (closed) before any, which is
    /// how a simulator boots.
    var hingeAngle: Double? {
        foldableEntry.map { simulators.folds.record(of: $0.udid).angle }
    }

    /// Counts Turn Around requests for the 3D model, which turns once round
    /// for each (`DeviceModelStageView`).
    private(set) var spinRequests = 0

    func turnAround() {
        spinRequests += 1
    }

    /// Tells the Device menu's Orientation (`AppleControlsController`) how
    /// the device is held now, by UDID.
    @ObservationIgnored var onPoseChanged: (@MainActor (_ udid: String, _ pose: SimulatorDevicePose) -> Void)?

    /// Closed, Half and Opened as Device Hub sets them: the device held
    /// upright, then the hinge swept to the preset's angle
    /// (`SimulatorFold.presetSteps`).
    func setPostureAnimated(_ posture: PostureKind) {
        guard let entry = foldableEntry, let sender = simulators.foldSender else { return }
        let steps = SimulatorFold.presetSteps(for: posture, from: simulators.folds.record(of: entry.udid).angle)
        sweepBatch = (entry.udid, sender.send(steps, to: address(of: entry)))
        record(steps, for: entry)
    }

    var heldPostures: [SimulatorHeldPosture] {
        foldableEntry == nil ? [] : SimulatorHeldPosture.allCases
    }

    /// A laptop or a tent: the lit panel switched first when needed, the
    /// device turned on its side, the hinge set (`SimulatorHeldPosture.steps`).
    func setHeldPosture(_ posture: SimulatorHeldPosture) {
        guard let entry = foldableEntry, let sender = simulators.foldSender else { return }
        let record = simulators.folds.record(of: entry.udid)
        let steps = posture.steps(from: record.panel, angle: record.angle)
        sweepBatch = (entry.udid, sender.send(steps, to: address(of: entry)))
        self.record(steps, for: entry)
    }

    /// Device ▸ Orientation and the stage's rotate on the mirrored foldable:
    /// held through the orientation picker, as Device Hub does (the GSEvent
    /// leaves the open panel's interface as it was). False for any other
    /// device, which the caller turns its own way.
    @discardableResult
    func setHeldPose(_ pose: SimulatorDevicePose, udid: String) -> Bool {
        guard let entry = foldableEntry, entry.udid == udid, let sender = simulators.foldSender else { return false }
        let steps: [SimulatorFoldStep] = [.pose(pose)]
        sender.send(steps, to: address(of: entry))
        record(steps, for: entry)
        return true
    }

    /// Records what `steps` leave the simulator at; the stage follows the
    /// lit panel (a new session) or, on the same panel, the way it is held.
    private func record(_ steps: [SimulatorFoldStep], for entry: SimulatorEntry) {
        var panelChanged = false
        for step in steps {
            switch step {
            case .hinge(let degrees), .sweep(_, let degrees):
                panelChanged = simulators.noteFold(udid: entry.udid, angle: SimulatorFold.sentAngle(degrees)) || panelChanged
            case .pose(let pose):
                // The book keeps the pose for Device ▸ Orientation while the
                // simulator stays booted.
                simulators.noteFold(udid: entry.udid, pose: pose)
                onPoseChanged?(entry.udid, pose)
            case .pause:
                break
            }
        }
        if panelChanged {
            canvas.followFold(entry.udid)
        } else {
            canvas.settleFoldPose(entry.udid)
        }
    }

    private func address(of entry: SimulatorEntry) -> SimulatorAddress {
        SimulatorAddress(udid: entry.udid, deviceSetPath: simulators.deviceSet?.path)
    }

    /// Sends the hinge to `degrees` and records it; true when the lit panel
    /// changed and the session followed it.
    @discardableResult
    private func moveHinge(_ entry: SimulatorEntry, to degrees: Double) -> Bool {
        guard let sender = simulators.foldSender else { return false }
        // Recorded as sent: whole degrees (90.3 reaches the guest as 90,
        // which does not light the inner panel).
        let angle = SimulatorFold.sentAngle(degrees)
        sender.send(degrees: angle, to: address(of: entry))
        sweepBatch = nil
        guard simulators.noteFold(udid: entry.udid, angle: angle) else { return false }
        canvas.followFold(entry.udid)
        return true
    }

    func setHingeAngle(_ degrees: Double) {
        guard degrees.isFinite, let entry = foldableEntry else { return }
        moveHinge(entry, to: degrees)
    }

    /// How far the mirrored foldable's last preset or held posture got in
    /// the simulator; nil when the hinge last moved another way.
    func foldProgress() -> SimulatorFoldProgress? {
        guard let entry = foldableEntry, let batch = sweepBatch, batch.udid == entry.udid,
              let sender = simulators.foldSender
        else { return nil }
        return sender.progress(of: batch.batch, for: address(of: entry))
    }

    /// Opens the hinge's channel to the mirrored foldable before its first
    /// fold (`SimulatorFoldSender.prepare`).
    func prepareFold() {
        guard let entry = foldableEntry, let sender = simulators.foldSender else { return }
        sender.prepare(address(of: entry))
    }

    /// Device ▸ Fold / Unfold: closed opens flat, anything else closes.
    func toggleFold() {
        let closed = SimulatorFold.posture(forAngle: hingeAngle ?? 0) == .closed
        setPostureAnimated(closed ? .opened : .closed)
    }
}
