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
    /// The loaded 3D scenes, which outlive the views that show them
    /// (`DeviceModelScenes`).
    @ObservationIgnored let modelScenes = DeviceModelScenes()

    init(simulators: SimulatorInventory, canvas: SimulatorCanvasController) {
        self.simulators = simulators
        self.canvas = canvas
        // The model faces the lit panel again once a check after the slider
        // has read it (`DeviceModelScene.litPanelSettled`).
        canvas.onLitPanelSettled = { [weak self] udid in
            guard let self, self.foldableEntry?.udid == udid else { return }
            self.modelScenes.litPanelSettled()
        }
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

    /// The outer panel's 2D chrome (`SimulatorInventory.outerChromeFrame`).
    var outerChrome: AppleChromeFrame? {
        foldableEntry.flatMap { simulators.outerChromeFrame(for: $0) }
    }

    /// The outer panel's display (`SimulatorInventory.outerDisplayShape`).
    var outerDisplayShape: DisplayShape? {
        foldableEntry.flatMap { simulators.outerDisplayShape(for: $0) }
    }

    /// The outer panel's size in pixels, portrait.
    var outerPanelPixels: CGSize? {
        guard let entry = foldableEntry, let outer = simulators.foldPanels(for: entry)?.outer else { return nil }
        return CGSize(width: min(outer.width, outer.height), height: max(outer.width, outer.height))
    }

    /// The posture button the stage's pill shows as current.
    var postureChoice: SimulatorFoldPostureChoice? {
        foldableEntry.map { SimulatorFold.postureChoice(for: simulators.folds.record(of: $0.udid)) }
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

    /// Closed, Half and Opened as Device Hub sets them: the device held as
    /// it is, then the hinge swept to the preset's angle
    /// (`SimulatorFold.presetSteps`).
    func setPostureAnimated(_ posture: PostureKind) {
        guard let entry = foldableEntry, let sender = simulators.foldSender else { return }
        dragFilter.reset()
        let fold = simulators.folds.record(of: entry.udid)
        let steps = SimulatorFold.presetSteps(
            for: posture,
            from: fold.angle,
            held: fold.pose ?? SimulatorFold.pose(for: fold.orientation)
        )
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
        dragFilter.reset()
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
        // The panel the thresholds say is lit is a guess (the guest lights one
        // by how the hinge moved): read it once the sweep is over.
        if steps.contains(where: \.movesHinge) { checkLitPanelSoon(entry.udid) }
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
        // One step of a slow move (the arrow keys, VoiceOver, the 2D stage's
        // drag): a few degrees at a time the guest kept the outer panel lit up
        // to 120°, so the 90° of a one-go move is not the threshold here.
        let changed = simulators.noteFold(udid: entry.udid, angle: angle, stepwise: true)
        if changed { canvas.followFold(entry.udid) }
        // Booked by a guess: the screenshots say which panel the guest lit
        // once the hinge is still.
        checkLitPanelSoon(entry.udid)
        return changed
    }

    func setHingeAngle(_ degrees: Double) {
        guard degrees.isFinite, let entry = foldableEntry else { return }
        dragFilter.reset()
        moveHinge(entry, to: degrees)
    }

    /// Draws the hinge slider's angle as it is dragged: the 3D stage sets it
    /// and folds the model straight away, outside SwiftUI.
    @ObservationIgnored var onLiveHinge: (@MainActor (Double) -> Void)?
    /// The dragged angle the fold book has not taken yet (`endHingeDrag`).
    @ObservationIgnored private var draggedAngle: (udid: String, angle: Double)?
    /// What the drag has sent, so that an event within the degree last sent
    /// reaches the model but not the simulator.
    @ObservationIgnored private var dragFilter = HingeDragFilter()

    /// The hinge slider while it is dragged, at the angle the knob is at
    /// (not rounded; events come at the mouse's rate): the angle goes to the
    /// 3D model as it is, so the model follows the knob smoothly, and to the
    /// simulator as a whole degree, and only when the degree changes
    /// (`HingeDragFilter`). It goes into the fold book only when it lights
    /// the other panel (the session follows) or the drag ends. Booking every
    /// degree made SwiftUI lay out the whole window and rebuild the menus each
    /// time, which held the model to 8–10 frames a second.
    func dragHinge(_ degrees: Double) {
        guard degrees.isFinite, let entry = foldableEntry, let sender = simulators.foldSender,
              let move = dragFilter.next(udid: entry.udid, degrees: degrees)
        else { return }
        guard onLiveHinge != nil else {
            if let angle = move.send {
                draggedAngle = nil
                moveHinge(entry, to: angle)
            }
            return
        }
        if let angle = move.send {
            sender.send(degrees: angle, to: address(of: entry))
            sweepBatch = nil
            draggedAngle = (entry.udid, angle)
            checkLitPanelSoon(entry.udid)
        }
        onLiveHinge?(move.live)
    }

    /// The slider was let go: the fold book takes the last dragged angle with
    /// the panel lit until now; the simulator's screenshots say whether that
    /// changed (`checkLitPanelSoon`). The guest lights a panel by how the
    /// hinge moved: dragged a few degrees at a time to 120° it kept the outer
    /// one lit, dragged in one go it lit the inner one before 90°, so the
    /// thresholds a preset's sweep follows would light the wrong panel here.
    /// The model settles on the whole degree the simulator got.
    func endHingeDrag() {
        dragFilter.reset()
        guard let dragged = draggedAngle else { return }
        draggedAngle = nil
        guard let entry = foldableEntry, entry.udid == dragged.udid else { return }
        onLiveHinge?(dragged.angle)
        modelScenes.hingeDragEnded()
        let panel = simulators.folds.record(of: entry.udid).panel
        _ = simulators.noteFold(udid: entry.udid, angle: dragged.angle, panel: panel)
        checkLitPanelSoon(entry.udid)
    }

    /// The one task that waits for the hinge to be still, and when it does
    /// (`litCheckDue`, pushed back by each hinge event instead of a task for
    /// each) and for which simulator.
    @ObservationIgnored private var litCheck: Task<Void, Never>?
    @ObservationIgnored private var litCheckDue: ContinuousClock.Instant?
    @ObservationIgnored private var litCheckUdid: String?
    @ObservationIgnored private var litCheckRetries = true

    /// Reads the lit panel off the simulator once the hinge has been still
    /// for `delay` (the guest takes a moment to light a panel), and never
    /// while a preset's hinge is sweeping: the panel it lights is dark until
    /// the guest gets there, so the read comes `litCheckDelay` after the
    /// sweep ends. One task waits for it (`litCheckDue`), pushed back by each
    /// later request instead of a task for each (the slider asks at the
    /// mouse's rate); a request due sooner (the stage saw its panel stay
    /// black) starts the wait again. The canvas queues a second read behind
    /// one in flight.
    private func checkLitPanelSoon(
        _ udid: String,
        after delay: Duration = SimulatorFoldController.litCheckDelay,
        retriesWhenInconclusive: Bool = true
    ) {
        let now = ContinuousClock.now
        let due = now + delay
        let sooner = litCheckDue.map { due < $0 } ?? true
        // A wait whose deadline passed is already reading or waiting out a
        // sweep: a new request starts it over rather than being lost.
        let pastDue = litCheckDue.map { $0 <= now } ?? false
        // A request that does not retry (the stage saw its panel stay black)
        // does not take that from one waiting that does.
        litCheckRetries = (litCheck != nil && litCheckRetries) || retriesWhenInconclusive
        litCheckDue = due
        litCheckUdid = udid
        if litCheck != nil {
            guard sooner || pastDue else { return }
            litCheck?.cancel()
        }
        litCheck = Task { @MainActor [weak self] in
            // Waits for the deadline (pushed back by later requests), then for
            // a sweep to end and `litCheckDelay` more, again as long as a new
            // sweep began meanwhile.
            while true {
                while let self, let due = self.litCheckDue, !Task.isCancelled {
                    let remaining = due - ContinuousClock.now
                    guard remaining > .zero else { break }
                    try? await Task.sleep(for: remaining)
                }
                guard !Task.isCancelled, let self else { return }
                guard self.isSweeping else { break }
                let waited = ContinuousClock.now
                while !Task.isCancelled, self.isSweeping, ContinuousClock.now - waited < Self.sweepWaitLimit {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard !Task.isCancelled else { return }
                // A sweep that outlasts `sweepWaitLimit` is read anyway.
                if self.isSweeping { break }
                self.litCheckDue = max(self.litCheckDue ?? .now, .now + Self.litCheckDelay)
            }
            guard let self else { return }
            guard !Task.isCancelled else { return }
            let udid = self.litCheckUdid
            let retriesWhenInconclusive = self.litCheckRetries
            self.litCheck = nil
            self.litCheckDue = nil
            guard let udid, self.draggedAngle == nil || self.draggedAngle?.udid == udid else { return }
            // Mid-drag the angle is not booked yet: book it with the panel
            // lit now, so the check compares like with like.
            if let dragged = self.draggedAngle {
                let panel = self.simulators.folds.record(of: udid).panel
                _ = self.simulators.noteFold(udid: udid, angle: dragged.angle, panel: panel)
            }
            self.canvas.checkLitPanel(udid, retriesWhenInconclusive: retriesWhenInconclusive)
        }
    }

    /// The stage saw the panel it shows stay black (`DarkPanelWatchdog`): the
    /// guest may have lit the other one since, so the lit panel is read now,
    /// without the wait a hinge that stopped gets.
    ///
    /// With `likely` (the hinge is being dragged and the fed panel went
    /// black, so the guest most likely lit the other one) the stage moves to
    /// that panel at once and the read confirms it after `litCheckDelay`:
    /// reading first kept the face black about 1.2 s after a one-go drag lit
    /// the inner panel, and up to 6 s after a drag closed the device past the
    /// point where the guest lit the outer one (0.3 s of black frames, two
    /// screenshots taking 1.5 s, a new session; iOS 27.1, 2026-10-14).
    func recheckLitPanel(likely: SimulatorFoldPanel? = nil) {
        guard let entry = foldableEntry else { return }
        let record = simulators.folds.record(of: entry.udid)
        if let likely, likely != record.panel {
            let angle = draggedAngle.map { Double($0.angle) } ?? record.angle
            if simulators.noteFold(udid: entry.udid, angle: angle, panel: likely) { canvas.followFold(entry.udid) }
            checkLitPanelSoon(entry.udid)
            return
        }
        checkLitPanelSoon(entry.udid, after: .zero, retriesWhenInconclusive: false)
    }

    /// Whether the fold strip's last batch is still moving the hinge.
    private var isSweeping: Bool {
        switch foldProgress() {
        case .sweeping?, .waiting?: return true
        case .done?, nil: return false
        }
    }

    static let litCheckDelay: Duration = .milliseconds(500)
    /// The longest a lit-panel check waits for a sweep to end (a sweep takes
    /// 0.6 s; an earlier batch still going out can hold it back for seconds).
    static let sweepWaitLimit: Duration = .seconds(5)

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
