import Foundation
import Synchronization

/// A foldable simulator's two touch panels: iPhone Duo's outer panel (lit
/// while closed) and its inner one (lit while open).
public struct SimulatorFoldPanels: Sendable, Hashable {
    public var outer: SimulatorDisplayProfile
    public var inner: SimulatorDisplayProfile

    /// A device type's panels (`SimulatorDisplayProfile.panels`) as a
    /// foldable's: exactly two, each with a screen ID, the lower ID outside.
    /// Nil for every other device.
    public init?(panels: [SimulatorDisplayProfile]) {
        guard panels.count == 2, let first = panels[0].screenID, let second = panels[1].screenID, first != second else {
            return nil
        }
        outer = first < second ? panels[0] : panels[1]
        inner = first < second ? panels[1] : panels[0]
    }

    public func profile(of panel: SimulatorFoldPanel) -> SimulatorDisplayProfile {
        panel == .outer ? outer : inner
    }
}

public enum SimulatorFoldPanel: String, Sendable, Hashable, Codable {
    case outer
    case inner
}

/// Folding a simulator, as Apple's Device Hub does with its hinge slider.
///
/// The hinge angle reaches the guest as a vendor-defined HID event on
/// dtuhidd's AVP custom service: usage page 0xFF61, usage 0x5B, version 1,
/// and IOKit's compact XML (what `IOCFUnserialize` reads; a full plist of
/// 329 bytes was refused as too large) of `{source: "hinge-slider-control",
/// type: "range", value: <degrees>}`. CoreMotion's device-state relay in the
/// guest turns it into hinge events, SpringBoard into a pose and a panel.
/// Established against Xcode 27.1 RC (27A9275, CoreSimulator 1174.9.2) with
/// iPhone Duo on iOS 27.1 (24A94232); `DeviceHubProSimBridgeSmoke --avp`
/// is the canary. `DHP_DISABLE_SIMULATOR_FOLD=1` turns it off.
public enum SimulatorFold {
    public static let disableVariable = "DHP_DISABLE_SIMULATOR_FOLD"

    public static func isDisabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[disableVariable] == "1"
    }

    /// The AVP custom service's usage page and usage (dtuhidd reported them
    /// as its `PrimaryUsagePage` 65377 and `PrimaryUsage` 91).
    public static let usagePage: UInt32 = 0xFF61
    public static let usage: UInt32 = 0x5B
    public static let version: UInt32 = 1

    /// Measured on the simulator (2026-10-09): opening from closed lights
    /// the inner panel past 90° (92° did, 90° did not); closing from open
    /// lights the outer one again below 20° (18° did, 20° did not). In
    /// between, the lit panel stays.
    public static let innerPanelAbove: Double = 90
    public static let outerPanelBelow: Double = 20

    /// The panel lit after the hinge moves to `angle` from a fold showing
    /// `current`.
    public static func panel(afterAngle angle: Double, from current: SimulatorFoldPanel) -> SimulatorFoldPanel {
        if angle > innerPanelAbove { return .inner }
        if angle < outerPanelBelow { return .outer }
        return current
    }

    /// A hinge that moves by less than this in one go (an arrow key, VoiceOver,
    /// a drag the 2D stage sends event by event) is a stepwise move to the
    /// guest, not the one-go jump `innerPanelAbove` was measured with.
    public static let stepwiseSpan: Double = 20
    /// Moved a few degrees at a time, the outer panel stayed lit up to 120°
    /// (iPhone Duo on iOS 27.1, 2026-10-14; the inner one lit above, a guess
    /// the lit-panel read corrects).
    public static let stepwiseInnerAbove: Double = 120

    /// The panel lit after the hinge moves to `angle` from `previous`, with
    /// `current` lit: a step of less than `stepwiseSpan` keeps the lit panel
    /// up to `stepwiseInnerAbove` (`panel(afterAngle:from:)` would light the
    /// inner one at 91° and show a dark panel until the screenshots say
    /// otherwise); a bigger move goes by `panel(afterAngle:from:)`.
    public static func panel(
        afterStepTo angle: Double,
        from previous: Double,
        lit current: SimulatorFoldPanel
    ) -> SimulatorFoldPanel {
        guard abs(angle - previous) < stepwiseSpan else { return panel(afterAngle: angle, from: current) }
        if angle > stepwiseInnerAbove { return .inner }
        if angle < outerPanelBelow { return .outer }
        return current
    }

    /// The panel a booted foldable's two screenshots say is lit: the one
    /// that is not dark, or, when both show something, the one at least
    /// `dimmedPanelRatio` times as bright. A locked iPhone Duo shows its
    /// lock screen dimmed on the panel that is not lit (iOS 27.1, open and
    /// locked: the outer panel's mean grey 65/255 beside the inner lock
    /// screen's 137; asleep, both 65), where an unlocked one leaves it black.
    /// Nil when both are dark (a boot), both are as bright, or a screenshot
    /// is missing.
    public static func litPanel(
        outer: SimulatorReadiness.ScreenReading?,
        inner: SimulatorReadiness.ScreenReading?
    ) -> SimulatorFoldPanel? {
        guard let outer, let inner else { return nil }
        if let lit = litPanel(outer: outer.content, inner: inner.content) { return lit }
        guard outer.content != .dark, inner.content != .dark else { return nil }
        if outer.luminance >= inner.luminance * dimmedPanelRatio { return .outer }
        if inner.luminance >= outer.luminance * dimmedPanelRatio { return .inner }
        return nil
    }

    /// How much brighter the lit panel is than the dimmed one beside it at
    /// least (measured 2.1, `litPanel`).
    public static let dimmedPanelRatio = 1.6

    /// The panel a booted foldable's two screenshots say is lit, when they
    /// agree: the unlit panel is dark (iPhone Duo open on iOS 27.1: the outer
    /// panel's screenshot is black, the inner one shows the home screen).
    /// Nil when both are dark (a boot), both show something, or a screenshot
    /// is missing. Reads a fold something other than Device Hub Pro made.
    public static func litPanel(
        outer: SimulatorReadiness.ScreenContent?,
        inner: SimulatorReadiness.ScreenContent?
    ) -> SimulatorFoldPanel? {
        guard let outer, let inner else { return nil }
        switch (outer, inner) {
        case (.dark, .dark): return nil
        case (.dark, _): return .inner
        case (_, .dark): return .outer
        default: return nil
        }
    }

    /// A preset's hinge angle, as Xcode 27.1's Device Hub sets it: SpringBoard
    /// read its half open as 127.78°, and it reads a sent angle as 5 + angle
    /// × 170/180 (100 → 99.44, 128 → 125.89, 130 → 127.78, 150 → 146.67), so
    /// Device Hub sends 130. Whole degrees only (a `<real>` value was
    /// ignored); above `innerPanelAbove`, so the inner panel lights.
    public static func angle(for posture: PostureKind) -> Double {
        switch posture {
        case .closed: return 0
        case .halfOpened: return 130
        case .opened: return 180
        }
    }

    /// How long a preset takes to move the hinge, and the rate of the angles
    /// on the way: Device Hub sent about 35 hinge events 17–18 ms apart for
    /// one preset, easing into the angle (SpringBoard read 129, 136, 147.5,
    /// 157.6, 165, 170.7, 174.7 then 180 on the way to Open), so apps see the
    /// fold move, not jump.
    public static let sweepDuration: TimeInterval = 0.6
    public static let sweepRate: Double = 60

    /// The whole-degree angles a sweep from `start` to `end` sends, easing
    /// out (cubic): fast first, settling into `end`, which is always last.
    /// No angle repeats the one before it; none when `start` is `end`.
    public static func sweepAngles(from start: Double, to end: Double) -> [Int] {
        sweepSchedule(from: start, to: end).map(\.angle)
    }

    /// `sweepAngles` with when each goes out: frame `n` (1 through
    /// `sweepDuration × sweepRate`) leaves `n / sweepRate` seconds after the
    /// sweep began, so the last one leaves at `sweepDuration`.
    public static func sweepSchedule(from start: Double, to end: Double) -> [(frame: Int, angle: Int)] {
        let first = Int(sentAngle(start)), last = Int(sentAngle(end))
        guard first != last else { return [] }
        let frames = sweepFrames
        var schedule: [(frame: Int, angle: Int)] = []
        for frame in 1...frames {
            let progress = sweepEasing(Double(frame) / Double(frames))
            let angle = Int(sentAngle(Double(first) + Double(last - first) * progress))
            if angle != (schedule.last?.angle ?? first) { schedule.append((frame, angle)) }
        }
        if schedule.last?.angle != last { schedule.append((frames, last)) }
        return schedule
    }

    /// How many frames a sweep spans.
    public static var sweepFrames: Int { max(Int((sweepDuration * sweepRate).rounded()), 1) }

    /// A sweep's progress (0...1) at `linear` of its time: easing out
    /// (cubic), as Device Hub's angles did.
    public static func sweepEasing(_ linear: Double) -> Double {
        let clamped = min(max(linear, 0), 1)
        return 1 - pow(1 - clamped, 3)
    }

    /// What a preset sends, as Device Hub does: the device held as it is
    /// (`held`; Xcode 27.1's Device Hub, iPhone Duo turned to landscape and
    /// then closed, half open, open and closed again, kept it turned each
    /// time, 2026-10-13), then the hinge swept from where it is.
    public static func presetSteps(
        for posture: PostureKind,
        from angle: Double,
        held: SimulatorDevicePose = .portrait
    ) -> [SimulatorFoldStep] {
        [.pose(held), .sweep(from: angle, to: Self.angle(for: posture))]
    }

    /// The angle a hinge event carries (`hingeEvent`): whole degrees, 0...180.
    public static func sentAngle(_ degrees: Double) -> Double {
        min(max(degrees.isFinite ? degrees : 0, 0), 180).rounded()
    }

    /// Which side of the panel thresholds an angle is on (0 below
    /// `outerPanelBelow`, 1 between, 2 above `innerPanelAbove`): two angles
    /// in one zone light the same panel from wherever the hinge was.
    public static func zone(of degrees: Double) -> Int {
        let angle = sentAngle(degrees)
        if angle < outerPanelBelow { return 0 }
        return angle > innerPanelAbove ? 2 : 1
    }

    /// The preset an angle reads as: closed below `outerPanelBelow`, open
    /// at 180° (SpringBoard's "open flat": 179° still read as partially
    /// open), half in between.
    public static func posture(forAngle angle: Double) -> PostureKind {
        if angle < outerPanelBelow { return .closed }
        if angle.rounded() >= 180 { return .opened }
        return .halfOpened
    }

    /// The posture button the stage's pill shows as current for `record`:
    /// a laptop or a tent while the device is held on its side at that
    /// posture's hinge and panel, else Device Hub's three by the hinge
    /// (`posture(forAngle:)`: closed, partially open, open flat).
    public static func postureChoice(for record: SimulatorFoldRecord) -> SimulatorFoldPostureChoice {
        let angle = Int(sentAngle(record.angle))
        for held in SimulatorHeldPosture.allCases
        where record.pose == pose(for: held.orientation) && record.panel == held.panel && angle == Int(held.angle) {
            return .held(held)
        }
        return .preset(posture(forAngle: record.angle))
    }

    /// How a panel's picture rests: iPhone Duo's inner panel is turned 270°
    /// (`nativeRotation`) and reported `uiOrientation` 3 (a quarter
    /// clockwise) as soon as it lit; 90° and 180° follow by symmetry (no
    /// device type has them).
    public static func restingRotation(of panel: SimulatorDisplayProfile) -> SimulatorFrameRotation {
        switch ((panel.nativeRotation % 360) + 360) % 360 {
        case 270: return .clockwise
        case 90: return .counterClockwise
        case 180: return .upsideDown
        default: return .upright
        }
    }

    /// The event that moves the hinge to `degrees` (0...180, whole degrees).
    public static func hingeEvent(degrees: Double) -> SimulatorHIDEvent {
        let value = Int(sentAngle(degrees))
        let xml = "<dict><key>source</key><string>hinge-slider-control</string>"
            + "<key>type</key><string>range</string>"
            + "<key>value</key><integer>\(value)</integer></dict>"
        return .vendorDefined(usagePage: usagePage, usage: usage, version: version, data: Data(xml.utf8))
    }

    /// How the device is held, as CoreMotion's device state takes it on the
    /// same service as the hinge: `{source: "orientation-picker-control",
    /// type: "enum", value: <name>}`, what Device Hub's Device ▸ Orientation
    /// sends (locationd logged "Processing AVP event - Source:
    /// orientation-picker-control" and "Orientation set to: 2 (pud)",
    /// "5 (faceup)", "6 (facedown)" for its items; `portrait-upside-down`,
    /// `upside-down` and `face-up` were not taken). The orientation GSEvent
    /// turns backboardd's device orientation but leaves the open panel's
    /// interface landscape; this turns it (Settings on the open panel went
    /// from 2853×2007 to 2007×2853). Same build as the hinge.
    public static func pickerValue(for pose: SimulatorDevicePose) -> String {
        switch pose {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "pud"
        case .landscapeLeft: return "landscape-left"
        case .landscapeRight: return "landscape-right"
        case .faceUp: return "faceup"
        case .faceDown: return "facedown"
        }
    }

    /// The event that holds the device as `pose`.
    public static func poseEvent(_ pose: SimulatorDevicePose) -> SimulatorHIDEvent {
        let xml = "<dict><key>source</key><string>orientation-picker-control</string>"
            + "<key>type</key><string>enum</string>"
            + "<key>value</key><string>\(pickerValue(for: pose))</string></dict>"
        return .vendorDefined(usagePage: usagePage, usage: usage, version: version, data: Data(xml.utf8))
    }

    /// The pose that holds the device at an interface orientation.
    public static func pose(for orientation: SimulatorOrientation) -> SimulatorDevicePose {
        switch orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        }
    }

    /// The interface orientation a pose holds the device at; nil lying flat
    /// (face up or down), where the interface keeps the one it had.
    public static func orientation(for pose: SimulatorDevicePose) -> SimulatorOrientation? {
        switch pose {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .faceUp, .faceDown: return nil
        }
    }
}

/// One thing sent to a foldable simulator, in order (`SimulatorFoldSender`).
public enum SimulatorFoldStep: Sendable, Equatable {
    /// The hinge to this many degrees, at once (the slider).
    case hinge(Double)
    /// The hinge moved to `to` over `SimulatorFold.sweepDuration`
    /// (`sweepAngles`), from the angle sent last, else from `from`.
    case sweep(from: Double, to: Double)
    /// The device held this way (`SimulatorFold.poseEvent`).
    case pose(SimulatorDevicePose)
    /// A wait, so the guest settles one step (a panel lighting) before the
    /// next.
    case pause(TimeInterval)

    /// Whether the step moves the hinge (and so may light the other panel).
    public var movesHinge: Bool {
        switch self {
        case .hinge, .sweep: return true
        case .pose, .pause: return false
        }
    }
}

/// A hinge sweep as `SimulatorFoldSender` sends it: from and to (whole
/// degrees), its frames `1 / SimulatorFold.sweepRate` s apart from `began`.
/// The angle it has reached at any instant is known, so whatever shows the
/// hinge can follow the guest's instead of a clock of its own.
public struct SimulatorFoldSweep: Sendable, Equatable {
    public let from: Int
    public let to: Int
    public let began: ContinuousClock.Instant

    public init(from: Int, to: Int, began: ContinuousClock.Instant) {
        self.from = from
        self.to = to
        self.began = began
    }

    /// When its last frame is due. Its last angle may leave a few frames
    /// sooner: the curve comes within half a degree of `to` before the end
    /// (from 180 to 0 on frame 31 of 36), and no angle repeats.
    public var end: ContinuousClock.Instant {
        began + .seconds(Double(SimulatorFold.sweepFrames) / SimulatorFold.sweepRate)
    }

    /// The angle it has reached at `instant` (`from` before it began, `to`
    /// after it ended), on the curve its angles follow.
    public func angle(at instant: ContinuousClock.Instant) -> Double {
        let elapsed = instant - began
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let linear = seconds * SimulatorFold.sweepRate / Double(SimulatorFold.sweepFrames)
        return Double(from) + Double(to - from) * SimulatorFold.sweepEasing(linear)
    }
}

/// A posture button on the stage's pill: one of Device Hub's three, or a
/// posture past them.
public enum SimulatorFoldPostureChoice: Sendable, Equatable {
    case preset(PostureKind)
    case held(SimulatorHeldPosture)
}

/// How far `SimulatorFoldSender` got with a batch of steps it was handed.
public enum SimulatorFoldProgress: Sendable, Equatable {
    /// None of its sweeps has begun: an earlier batch is still going out.
    case waiting
    /// Its latest sweep began; later steps (a pause, another sweep) may wait.
    case sweeping(SimulatorFoldSweep)
    /// All of it was sent (or the simulator was forgotten).
    case done
}

/// The fold strip's postures past Apple's presets: the device on its side,
/// half open. On a laptop the inner panel lies along the hinge, the lower
/// half flat and the upper one up; a tent stands on both edges, the outer
/// panel lit outside.
public enum SimulatorHeldPosture: String, CaseIterable, Identifiable, Sendable {
    case laptop
    case tent

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .laptop: return "Laptop"
        case .tent: return "Tent"
        }
    }

    public var systemImage: String {
        switch self {
        case .laptop: return "laptopcomputer"
        case .tent: return "tent"
        }
    }

    /// The hinge: a laptop past `SimulatorFold.innerPanelAbove`, a tent
    /// short of it, so each keeps its panel lit.
    public var angle: Double {
        switch self {
        case .laptop: return 105
        case .tent: return 70
        }
    }

    public var panel: SimulatorFoldPanel {
        switch self {
        case .laptop: return .inner
        case .tent: return .outer
        }
    }

    /// Both lie on the device's side, the hinge across the view, each held
    /// landscape left. A tent so held shows its outer panel's interface
    /// upright (iOS 27.1: held landscape right it was upside down under the
    /// hinge). A laptop so held lies on its flat half, the one whose back is
    /// the outer panel, and stands the half with the cameras on its back up
    /// as its lid; held landscape right it lay on the camera bump, its lid
    /// the outer panel's half. Seen from their own faces the two holds are
    /// half a turn apart, so going from one to the other the device turns
    /// round as it tips, as the other app's does.
    public var orientation: SimulatorOrientation {
        switch self {
        case .laptop: return .landscapeLeft
        case .tent: return .landscapeLeft
        }
    }

    /// How long the guest takes to light the other panel, once the hinge
    /// got there, before the device turns.
    public static let panelSwitchPause: TimeInterval = 0.4

    /// The fold a laptop opened with the outer panel lit starts from: the
    /// guest lights the inner panel on the way open only from a fold this far
    /// shut (iOS 27.1, iPhone Duo: from a tent at 70° the inner panel stayed
    /// dark at 105°, even at 120°; after folding to 40° first it lit, after
    /// 50° it did not).
    public static let laptopDip: Double = 30

    /// The steps from a fold at `angle` lighting `current`: when the posture
    /// needs the other panel, the hinge first sweeps past that panel's
    /// threshold (flat, or closed) and the guest lights it; then the device
    /// turns on its side and the hinge sweeps to the posture's angle.
    public func steps(from current: SimulatorFoldPanel, angle start: Double) -> [SimulatorFoldStep] {
        var steps: [SimulatorFoldStep] = []
        var from = start
        // A laptop opened from a fold short of `innerPanelAbove` passes it on
        // the way: the guest lights the inner panel as it goes, so the device
        // turns and opens in one move, as the other app's laptop does.
        let lightsOnTheWay = panel == .inner && start <= SimulatorFold.innerPanelAbove && angle > SimulatorFold.innerPanelAbove
        // Above `laptopDip` the guest keeps the outer panel lit on the way to
        // a laptop: the hinge folds that far first.
        if lightsOnTheWay, current == .outer, start > Self.laptopDip {
            steps.append(.sweep(from: from, to: Self.laptopDip))
            from = Self.laptopDip
        }
        if current != panel, !lightsOnTheWay {
            let extreme: Double = panel == .inner ? 180 : 0
            steps += [.sweep(from: from, to: extreme), .pause(Self.panelSwitchPause)]
            from = extreme
        }
        return steps + [.pose(SimulatorFold.pose(for: orientation)), .sweep(from: from, to: angle)]
    }
}

/// The panel a simulator session mirrors and sends touches to.
public struct SimulatorSessionPanel: Sendable, Hashable {
    /// The screen the bridge resolves (0: the lowest ID, the main screen).
    public var screenID: UInt32
    /// The digitizer events' `target` (0: the main screen).
    public var digitizerTarget: UInt32

    public init(screenID: UInt32, digitizerTarget: UInt32) {
        self.screenID = screenID
        self.digitizerTarget = digitizerTarget
    }

    /// The main screen: every device's, and a folded iPhone Duo's.
    public static let main = SimulatorSessionPanel(screenID: 0, digitizerTarget: 0)

    /// A foldable's `panel`: the outer one is the main screen; the inner one
    /// is resolved and targeted by its screen ID (a tap on iPhone Duo's
    /// inner panel landed with target 3 and with none of 0, 1 or 2).
    public static func foldable(_ panel: SimulatorFoldPanel, of panels: SimulatorFoldPanels) -> SimulatorSessionPanel {
        switch panel {
        case .outer:
            return SimulatorSessionPanel(screenID: panels.outer.screenID ?? 0, digitizerTarget: 0)
        case .inner:
            let id = panels.inner.screenID ?? 0
            return SimulatorSessionPanel(screenID: id, digitizerTarget: id)
        }
    }
}

/// Sends hinge angles and held orientations to foldable simulators, in
/// order. A drag of the fold slider makes angles faster than they need to
/// reach the guest, so an angle not sent yet is replaced by a newer one that
/// follows it directly, when both light the same panel (`SimulatorFold.zone`:
/// an angle that crosses a threshold is always sent, or the guest would keep
/// the panel the app no longer shows); one input channel per simulator, all
/// on one serial queue, connected on the first send (or by `prepare`).
/// Each `send` is a batch whose progress can be asked for, so the stage can
/// draw the hinge where the guest's is (`SimulatorFoldSweep`).
public final class SimulatorFoldSender: Sendable {
    private let bridge: any SimulatorBridging
    private let queue = DispatchQueue(label: "com.devicehubpro.simulator-fold", qos: .userInitiated)
    private let state = Mutex(State())

    private struct Queued {
        let step: SimulatorFoldStep
        let batch: Int
    }

    private struct State {
        var pending: [SimulatorAddress: [Queued]] = [:]
        var drainScheduled = false
        var inputs: [SimulatorAddress: any SimulatorInputBridging] = [:]
        var lastError: [SimulatorAddress: String] = [:]
        /// The hinge angle each simulator was sent last: where a sweep starts.
        var lastAngle: [SimulatorAddress: Int] = [:]
        var nextBatch = 1
        /// The batch whose step is going out, the last batch sent whole and
        /// the latest sweep begun, per simulator.
        var inFlight: [SimulatorAddress: Int] = [:]
        var sentBatch: [SimulatorAddress: Int] = [:]
        var sweep: [SimulatorAddress: (batch: Int, sweep: SimulatorFoldSweep)] = [:]
    }

    public init(bridge: any SimulatorBridging) {
        self.bridge = bridge
    }

    /// Queues `degrees` for `address`, replacing an angle that waits last.
    public func send(degrees: Double, to address: SimulatorAddress) {
        send([.hinge(degrees)], to: address)
    }

    /// Queues `steps` for `address` after those waiting; a first hinge step
    /// replaces a hinge step waiting last in the same zone. Returns the
    /// batch they make (`progress(of:for:)`).
    @discardableResult
    public func send(_ steps: [SimulatorFoldStep], to address: SimulatorAddress) -> Int {
        guard !steps.isEmpty else { return 0 }
        let (batch, schedule) = state.withLock { state -> (Int, Bool) in
            let batch = state.nextBatch
            state.nextBatch += 1
            var queued = state.pending[address] ?? []
            if case .hinge(let new)? = steps.first, case .hinge(let old)? = queued.last?.step,
               SimulatorFold.zone(of: new) == SimulatorFold.zone(of: old) {
                queued.removeLast()
            }
            state.pending[address] = queued + steps.map { Queued(step: $0, batch: batch) }
            guard !state.drainScheduled else { return (batch, false) }
            state.drainScheduled = true
            return (batch, true)
        }
        if schedule { queue.async { [self] in drain() } }
        return batch
    }

    /// How far `batch` (a `send`'s) for `address` got. A batch that was
    /// never sent, replaced or dropped with the simulator is done.
    public func progress(of batch: Int, for address: SimulatorAddress) -> SimulatorFoldProgress {
        state.withLock { state in
            if batch <= state.sentBatch[address] ?? 0 { return .done }
            if let current = state.sweep[address], current.batch == batch { return .sweeping(current.sweep) }
            if state.inFlight[address] == batch || state.pending[address]?.contains(where: { $0.batch == batch }) == true {
                return .waiting
            }
            return .done
        }
    }

    /// Connects `address`'s channel now, so the first fold does not wait for
    /// it: iPhone Duo's first connect took about half a second, which held
    /// the sweep back while the stage moved.
    public func prepare(_ address: SimulatorAddress) {
        queue.async { [self] in
            let input = input(for: address)
            if !input.isConnected { _ = try? input.connect() }
        }
    }

    /// The last send's failure for `address`, if it failed.
    public func lastError(for address: SimulatorAddress) -> String? {
        state.withLock { $0.lastError[address] }
    }

    /// Closes `address`'s channel (the simulator shut down).
    public func forget(_ address: SimulatorAddress) {
        let input = state.withLock { state -> (any SimulatorInputBridging)? in
            state.pending[address] = nil
            state.lastError[address] = nil
            state.lastAngle[address] = nil
            state.inFlight[address] = nil
            state.sweep[address] = nil
            return state.inputs.removeValue(forKey: address)
        }
        if let input { queue.async { input.disconnect() } }
    }

    /// The hinge angle `address` was sent last, if any.
    public func lastAngle(for address: SimulatorAddress) -> Int? {
        state.withLock { $0.lastAngle[address] }
    }

    /// Waits, at most `timeout`, until every queued angle was sent (tests).
    public func waitUntilIdle(timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let done = queue.sync { state.withLock { $0.pending.isEmpty && !$0.drainScheduled } }
            if done { return }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    /// On the queue: `address`'s channel, made on first use.
    private func input(for address: SimulatorAddress) -> any SimulatorInputBridging {
        if let existing = state.withLock({ $0.inputs[address] }) { return existing }
        let input = bridge.makeInput(for: address)
        state.withLock { $0.inputs[address] = input }
        return input
    }

    /// On the queue: sends each simulator's steps in order until none waits.
    private func drain() {
        while true {
            let next = state.withLock { state -> (SimulatorAddress, Queued)? in
                guard let (address, steps) = state.pending.first(where: { !$0.value.isEmpty }) else {
                    state.pending = [:]
                    state.drainScheduled = false
                    return nil
                }
                state.pending[address] = Array(steps.dropFirst())
                state.inFlight[address] = steps[0].batch
                return (address, steps[0])
            }
            guard let (address, queued) = next else { return }
            let input = input(for: address)
            switch queued.step {
            case .hinge(let degrees):
                send(SimulatorFold.hingeEvent(degrees: degrees), on: input, to: address, angle: Int(SimulatorFold.sentAngle(degrees)))
            case .sweep(let from, let to):
                let start = state.withLock { $0.lastAngle[address] }.map(Double.init) ?? from
                let schedule = SimulatorFold.sweepSchedule(from: start, to: to)
                guard let last = schedule.last else { break }
                // Each angle leaves on its frame's time, however long the
                // sends before it took, so the sweep lasts its duration and
                // `SimulatorFoldSweep.angle(at:)` says where the hinge is.
                let sweep = SimulatorFoldSweep(from: Int(SimulatorFold.sentAngle(start)), to: last.angle, began: .now)
                state.withLock { $0.sweep[address] = (queued.batch, sweep) }
                for (frame, angle) in schedule {
                    Self.sleep(until: sweep.began + .seconds(Double(frame) / SimulatorFold.sweepRate))
                    send(SimulatorFold.hingeEvent(degrees: Double(angle)), on: input, to: address, angle: angle)
                }
            case .pose(let pose):
                send(SimulatorFold.poseEvent(pose), on: input, to: address, angle: nil)
            case .pause(let seconds):
                Thread.sleep(forTimeInterval: seconds)
            }
            state.withLock { state in
                guard state.inFlight[address] == queued.batch else { return }
                state.inFlight[address] = nil
                if state.pending[address]?.contains(where: { $0.batch == queued.batch }) != true {
                    state.sentBatch[address] = max(state.sentBatch[address] ?? 0, queued.batch)
                }
            }
        }
    }

    private static func sleep(until deadline: ContinuousClock.Instant) {
        let wait = deadline - .now
        guard wait > .zero else { return }
        Thread.sleep(forTimeInterval: Double(wait.components.seconds) + Double(wait.components.attoseconds) / 1e18)
    }

    /// On the queue: one event; a hinge event's angle becomes the one sent last.
    private func send(_ event: SimulatorHIDEvent, on input: any SimulatorInputBridging, to address: SimulatorAddress, angle: Int?) {
        do {
            try input.send(event)
            state.withLock { state in
                state.lastError[address] = nil
                if let angle { state.lastAngle[address] = angle }
            }
        } catch {
            state.withLock { $0.lastError[address] = "\(error)" }
        }
    }
}

/// Where Device Hub Pro last put a foldable simulator's hinge, and the panel
/// that lit.
public struct SimulatorFoldRecord: Sendable, Equatable, Codable {
    public var angle: Double
    public var panel: SimulatorFoldPanel
    /// How the device is held (`SimulatorFold.orientationEvent`).
    public var orientation: SimulatorOrientation
    /// The pose the orientation picker last held it at (Device ▸
    /// Orientation's check, which devicectl does not read back); nil before
    /// any.
    public var pose: SimulatorDevicePose?

    public init(
        angle: Double,
        panel: SimulatorFoldPanel,
        orientation: SimulatorOrientation = .portrait,
        pose: SimulatorDevicePose? = nil
    ) {
        self.angle = angle
        self.panel = panel
        self.orientation = orientation
        self.pose = pose
    }

    /// How a simulator boots: closed, its outer panel lit, upright.
    public static let closed = SimulatorFoldRecord(angle: 0, panel: .outer)
}

/// The folds of the booted foldable simulators Device Hub Pro moved, by
/// UDID. One it never moved is closed, as a simulator boots, until its
/// screenshots show it open (`SimulatorFold.litPanel`).
///
/// Each fold holds for the boot it was recorded in: the simulator keeps its
/// hinge while Device Hub Pro quits and opens again, so the book is kept on
/// disk, and a simulator that shut down or booted again since is forgotten
/// (`keep(only:)`). A boot is simctl's `lastUsedAt`, which the listing of a
/// booted simulator sets to the moment it booted (the start of its
/// `launchd_sim`) and leaves while it runs.
public struct SimulatorFoldBook: Sendable, Equatable, Codable {
    public private(set) var records: [String: SimulatorFoldRecord] = [:]
    /// When each recorded simulator booted, where the listing said.
    public private(set) var boots: [String: Date] = [:]

    public init() {}

    public func record(of udid: String) -> SimulatorFoldRecord {
        records[udid] ?? .closed
    }

    /// Records the hinge at `angle` for `udid` (`SimulatorFold.panel`'s
    /// hysteresis), in the boot at `bootedAt`; returns whether the lit panel
    /// changed. With `stepwise` the move is one step of a slow one (the arrow
    /// keys): see `SimulatorFold.panel(afterStepTo:from:lit:)`.
    @discardableResult
    public mutating func note(udid: String, angle: Double, stepwise: Bool = false, bootedAt: Date? = nil) -> Bool {
        let before = current(udid, bootedAt: bootedAt)
        var after = before
        after.angle = angle
        after.panel = stepwise
            ? SimulatorFold.panel(afterStepTo: angle, from: before.angle, lit: before.panel)
            : SimulatorFold.panel(afterAngle: angle, from: before.panel)
        records[udid] = after
        return after.panel != before.panel
    }

    /// Records the hinge at `angle` for `udid` with `panel` lit, as the
    /// simulator's screenshots showed it: its lit panel depends on how fast
    /// the hinge moved, not only on where it stopped (a slider dragged a few
    /// degrees at a time to 120° kept the outer panel lit, iOS 27.1). Returns
    /// whether the lit panel changed.
    @discardableResult
    public mutating func note(udid: String, angle: Double, panel: SimulatorFoldPanel, bootedAt: Date? = nil) -> Bool {
        let before = current(udid, bootedAt: bootedAt)
        var after = before
        after.angle = angle
        after.panel = panel
        records[udid] = after
        return after.panel != before.panel
    }

    /// Records `udid` held at `pose`, in the boot at `bootedAt`: lying flat
    /// keeps the interface orientation it had.
    public mutating func note(udid: String, pose: SimulatorDevicePose, bootedAt: Date? = nil) {
        var record = current(udid, bootedAt: bootedAt)
        record.pose = pose
        if let orientation = SimulatorFold.orientation(for: pose) { record.orientation = orientation }
        records[udid] = record
    }

    /// Keeps the folds of the simulators booted now, each mapped to when it
    /// booted (nil where the listing did not say): one that shut down, or
    /// booted again since its fold was recorded, is forgotten.
    public mutating func keep(only booted: [String: Date?]) {
        for udid in Array(records.keys) {
            guard let boot = booted[udid] else {
                records[udid] = nil
                continue
            }
            guard let boot else { continue }
            if let recorded = boots[udid], recorded != boot {
                records[udid] = nil
            } else {
                boots[udid] = boot
            }
        }
        boots = boots.filter { records[$0.key] != nil }
    }

    /// `udid`'s record for the boot at `bootedAt`: closed when the one kept
    /// is from an earlier boot.
    private mutating func current(_ udid: String, bootedAt boot: Date?) -> SimulatorFoldRecord {
        if let boot {
            if let recorded = boots[udid], recorded != boot { records[udid] = nil }
            boots[udid] = boot
        }
        return record(of: udid)
    }

    private enum CodingKeys: String, CodingKey {
        case records, boots
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        records = try container.decode([String: SimulatorFoldRecord].self, forKey: .records)
        boots = try container.decode([String: Date].self, forKey: .boots)
        records = records.filter { boots[$0.key] != nil }
    }

    /// Only the folds whose boot is known: the next launch's listing checks
    /// each against the simulator's boot before it is used.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(records.filter { boots[$0.key] != nil }, forKey: .records)
        try container.encode(boots, forKey: .boots)
    }
}
