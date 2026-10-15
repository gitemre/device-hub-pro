import Foundation
import Observation
import SwiftUI
import UIKit

/// The time of day the sky shows, from the hinge, the Time-Lapse or (on an
/// iPhone without a hinge) the slider, and the counts the Readings sheet
/// shows. Nothing here comes from geometry: the layout is computed in the
/// view from the window, so no layout pass can write back into this model.
/// What a reading means is decided by `HingeFollower` (Shared/), which the
/// Mac tests run; this class carries it out.
@MainActor
@Observable
final class DayModel {
    typealias Availability = HingeFollower.Availability

    /// How the sky moves to a new angle.
    enum AngleMotion: Equatable {
        /// At once: the first reading, so the scene is simply right when it
        /// appears (SpringBoard shows a fold's move with a fade, not ours).
        case jump
        /// Eases after the hinge (26–30 updates a second during a sweep) or
        /// the slider, each update retargeting the last; also the sky's way
        /// into and out of a Time-Lapse.
        case follow

        var animation: Animation? {
            switch self {
            case .jump: return nil
            case .follow: return .smooth(duration: 0.35)
            }
        }
    }

    /// How often the deck, the clock, the phase and the Readings follow a
    /// playing Time-Lapse. The sky does not wait for these: it works out the
    /// Time-Lapse's angle every frame from its own clock (`TimeLapseRun`).
    nonisolated static let timeLapseReading = Duration.milliseconds(100)
    /// How long to wait for the first hinge callback before deciding the
    /// device has none. On the iOS 27.1 iPhone Duo simulator it came
    /// 0.35–2.6 s after launch over nine launches (0.17–1.9 s after the
    /// window appeared); three times the slowest, so a slow launch does not
    /// take a Duo for a hinge-less iPhone.
    nonisolated static let hingeGrace = Duration.seconds(8)

    private(set) var follower = HingeFollower()
    /// The latest hinge reading; nil while waiting or without a hinge.
    private(set) var hinge: DeviceHinge?
    /// Every `onHingeChange` call, repeats included.
    private(set) var hingeUpdates = 0
    private(set) var lastHingeUpdate: Date?

    /// The angle the deck, the clock, the phase and the Readings show, in
    /// degrees: the hinge's or the slider's, or during a Time-Lapse its angle
    /// ten times a second. Nil until one of them gives an angle, while the
    /// view shows the likeliest posture for its window
    /// (`shownAngle(regularWidth:)`).
    private(set) var displayedAngle: Double?
    /// The phase of `displayedAngle`.
    private(set) var phase: DayPhase?
    /// The angle the hinge or the slider gives the sky (nil before either):
    /// what it shows and follows outside a Time-Lapse, and what it settles
    /// on when one stops. A Time-Lapse leaves it alone.
    private(set) var restingAngle: Double?
    /// How the sky moves to a new `restingAngle`.
    private(set) var angleMotion = AngleMotion.jump
    /// The Time-Lapse, while it plays and, once stopped, while the sky eases
    /// from where it left the day; the next one replaces it.
    private(set) var timeLapse: TimeLapseRun?

    var showsReadings = false

    /// Writes `Documents/readings.jsonl` when launched with `--log-readings`
    /// (agents verify a fold with it); nil otherwise.
    @ObservationIgnored let log: ReadingsLog?
    /// `--time-lapse-after <seconds>[,<seconds>…]`: when to toggle the
    /// Time-Lapse by itself after launch, as the button does, so a check can
    /// play and stop it without touching the screen.
    @ObservationIgnored let timeLapseToggles: [Duration]
    /// Where the slider leaves the day on an iPhone without a hinge: set to
    /// the angle the sky shows when the device turns out to have none.
    @ObservationIgnored private var manualAngle = 0.0
    /// When each recent hinge update came (`systemUptime`), for the rate.
    @ObservationIgnored private var recentUpdates: [TimeInterval] = []
    @ObservationIgnored private var lastLoggedUpdate: TimeInterval?
    @ObservationIgnored private var timeLapseTask: Task<Void, Never>?
    /// The frame counts that go with the log (`FrameLog`).
    @ObservationIgnored private var frameLog: FrameLog?

    var availability: Availability { follower.availability }
    var isTimeLapsing: Bool { follower.isTimeLapsing }
    var hingeDegrees: Double? { hinge?.angle.degrees }

    /// A phase change the viewer caused by moving the hinge or the slider,
    /// which the haptic and VoiceOver mark. Not the first reading's jump,
    /// nor the Time-Lapse's eight steps a loop.
    var phaseChangeIsFelt: Bool { !isTimeLapsing && angleMotion == .follow }

    init(arguments: [String]) {
        log = arguments.contains("--log-readings") ? ReadingsLog() : nil
        timeLapseToggles = Self.durations(after: "--time-lapse-after", in: arguments)
        guard let log else { return }
        let device = UIDevice.current
        log.record("app.launch", [
            "arguments": Array(arguments.dropFirst()),
            "system": "\(device.systemName) \(device.systemVersion)",
            "model": device.model,
            "file": log.url.lastPathComponent,
        ])
        let frameLog = FrameLog(log: log) { [weak self] in self?.angleNow }
        frameLog.start()
        self.frameLog = frameLog
    }

    /// The angle the deck, the clock and the Readings show: before anything
    /// gave one, the likeliest posture for the window
    /// (`HingeFollower.likelyAngle`), so the inner panel does not open on
    /// night for the moment before the first reading.
    func shownAngle(regularWidth: Bool) -> Double {
        displayedAngle ?? HingeFollower.likelyAngle(regularWidth: regularWidth)
    }

    /// The sky's resting angle, or before any reading the likeliest posture.
    func restingAngle(regularWidth: Bool) -> Double {
        restingAngle ?? HingeFollower.likelyAngle(regularWidth: regularWidth)
    }

    /// The angle the sky shows at this moment, or is easing to, for the
    /// frame log: a playing Time-Lapse's own, else the one the deck shows
    /// (the model does not see the animation, so while the sky eases after
    /// the hinge or out of a stopped Time-Lapse this is where it goes).
    private var angleNow: Double? {
        guard let timeLapse, timeLapse.isPlaying else { return displayedAngle }
        return timeLapse.angle(at: Date.timeIntervalSinceReferenceDate)
    }

    // MARK: Hinge

    /// `onHingeChange`: stores the reading (it fires about 30 times a second
    /// during a sweep and repeats values at rest) and moves the sky, unless
    /// the Time-Lapse plays and the hinge stayed within the tolerance.
    func hingeChanged(old: DeviceHingeContext, new: DeviceHingeContext, regularWidth: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        hingeUpdates += 1
        lastHingeUpdate = Date()
        recentUpdates.append(now)
        if recentUpdates.count > 64 { recentUpdates.removeFirst() }
        log?.record("hinge", [
            "n": hingeUpdates,
            "dtMs": lastLoggedUpdate.map { jsonNumber((now - $0) * 1000) } ?? NSNull(),
            "old": Self.json(old.hinge),
            "new": Self.json(new.hinge),
        ])
        lastLoggedUpdate = now

        if hinge != new.hinge { hinge = new.hinge }
        var follower = self.follower
        let step = follower.reading(old: old.hinge?.angle.degrees, new: new.hinge?.angle.degrees)
        // A repeat changes nothing, and a write would redraw every view
        // that reads the availability.
        if follower != self.follower { self.follower = follower }
        switch step {
        case .none:
            break
        case let .show(degrees, jump):
            show(degrees, motion: jump ? .jump : .follow, source: "hinge")
        case .stopTimeLapse:
            stopTimeLapse(reason: "hinge")
        case .noHinge:
            log?.record("hinge.none", ["reason": "callback"])
            settleWithoutHinge(regularWidth: regularWidth)
        }
    }

    /// No callback within `hingeGrace`: treat the device as hinge-less.
    func hingeGraceEnded(regularWidth: Bool) {
        var follower = self.follower
        guard follower.graceEnded() == .noHinge else { return }
        self.follower = follower
        log?.record("hinge.none", ["reason": "grace", "afterMs": jsonNumber(Self.hingeGrace / .milliseconds(1))])
        settleWithoutHinge(regularWidth: regularWidth)
    }

    /// The one start for a device without a hinge, however it is found out:
    /// the slider takes over at the angle the sky shows, so nothing moves
    /// (a late first reading on a Duo then jumps to the real angle).
    private func settleWithoutHinge(regularWidth: Bool) {
        let angle = shownAngle(regularWidth: regularWidth)
        manualAngle = angle
        guard !isTimeLapsing else { return }
        show(angle, motion: .jump, source: "slider")
    }

    /// Hinge updates a second, over the last second.
    func updateRate(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int {
        recentUpdates.reduce(0) { count, time in now - time <= 1 ? count + 1 : count }
    }

    // MARK: Slider (no hinge)

    /// The slider on an iPhone without a hinge; scrubbing stops the Time-Lapse.
    func scrub(to degrees: Double) {
        let degrees = min(max(degrees, 0), 180)
        if isTimeLapsing { stopTimeLapse(reason: "slider", rest: false) }
        manualAngle = degrees
        show(degrees, motion: .follow, source: "slider")
    }

    // MARK: Time-Lapse

    /// The button (and `--time-lapse-after`): plays from the angle the sky
    /// shows in a window of that width class, or stops.
    func toggleTimeLapse(regularWidth: Bool, reason: String = "button") {
        if isTimeLapsing {
            stopTimeLapse(reason: reason)
        } else {
            startTimeLapse(from: shownAngle(regularWidth: regularWidth), reason: reason)
        }
    }

    /// Starts on the rising half of the day at `angle`, so the sky carries on
    /// from where it is instead of jumping to night; right after a stop, from
    /// where the stopped run left it (`TimeLapseRun.start`). The run is
    /// written once; the sky reads its angle every frame, and the deck and
    /// the phase ten times a second.
    private func startTimeLapse(from angle: Double, reason: String) {
        var follower = self.follower
        follower.timeLapseStarted(hinge: hingeDegrees)
        self.follower = follower
        let now = Date.timeIntervalSinceReferenceDate
        let run = TimeLapseRun.start(after: timeLapse, shown: angle, at: now)
        timeLapse = run
        log?.record("timeLapse.start", ["angle": jsonNumber(run.angle(at: now)), "reason": reason])
        timeLapseTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.readTimeLapse()
                try? await Task.sleep(for: Self.timeLapseReading)
            }
        }
    }

    private func readTimeLapse() {
        guard let timeLapse, timeLapse.isPlaying else { return }
        display(timeLapse.angle(at: Date.timeIntervalSinceReferenceDate), source: "timeLapse")
    }

    /// Stops the Time-Lapse where it is; with `rest`, the sky eases from
    /// there to the hinge, the slider's angle or, before the first reading,
    /// the likeliest posture (without, the slider moves it next).
    private func stopTimeLapse(reason: String, rest: Bool = true) {
        timeLapseTask?.cancel()
        timeLapseTask = nil
        let now = Date.timeIntervalSinceReferenceDate
        timeLapse?.stop(at: now)
        var follower = self.follower
        follower.timeLapseStopped()
        self.follower = follower
        let angle = timeLapse?.angle(at: now) ?? displayedAngle
        log?.record("timeLapse.stop", ["reason": reason, "angle": angle.map { jsonNumber($0) } ?? NSNull()])
        guard rest else { return }
        switch availability {
        case .present: show(hingeDegrees ?? restingAngle, motion: .follow, source: "hinge")
        case .absent: show(manualAngle, motion: .follow, source: "slider")
        case .waiting: show(nil, motion: .follow, source: "hinge")
        }
    }

    // MARK: Showing an angle

    /// The one place the hinge or the slider moves the sky (nil: back to
    /// the likeliest posture), and with it what the deck shows. Writes only
    /// what changed: the hinge repeats values, and every write redraws the
    /// sky.
    private func show(_ degrees: Double?, motion: AngleMotion, source: String) {
        if angleMotion != motion { angleMotion = motion }
        if restingAngle != degrees { restingAngle = degrees }
        display(degrees, source: source)
    }

    /// The angle and phase the deck, the clock and the Readings show.
    private func display(_ degrees: Double?, source: String) {
        if displayedAngle != degrees { displayedAngle = degrees }
        let newPhase = degrees.map { DayCycle.phase(progress: DayCycle.progress(angleDegrees: $0)) }
        guard newPhase != phase else { return }
        log?.record("phase", [
            "from": phase?.rawValue ?? NSNull(),
            "to": newPhase?.rawValue ?? NSNull(),
            "angle": degrees.map { jsonNumber($0) } ?? NSNull(),
            "source": source,
        ])
        phase = newPhase
    }

    // MARK: Layout (log only)

    /// The window's layout, for the log. Deliberately writes nothing the
    /// views observe: the views compute the layout from geometry, and a
    /// write here would feed geometry back into layout.
    func windowChanged(_ window: WindowReadings) {
        log?.record("layout", window.json, dedupeKey: "layout")
    }

    // MARK: Names

    static func name(of status: DeviceHinge.Status) -> String {
        switch status {
        case .closed: return "closed"
        case .partiallyOpen: return "partiallyOpen"
        case .fullyOpen: return "fullyOpen"
        default: return "other"
        }
    }

    private static func json(_ hinge: DeviceHinge?) -> Any {
        guard let hinge else { return NSNull() }
        return [
            "status": name(of: hinge.status),
            "deg": jsonNumber(hinge.angle.degrees),
        ] as [String: Any]
    }

    /// The comma-separated seconds after `flag`, as durations; none when the
    /// flag is missing or a value is not a number of seconds.
    private static func durations(after flag: String, in arguments: [String]) -> [Duration] {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return [] }
        let seconds = arguments[index + 1].split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !seconds.isEmpty, seconds.allSatisfy({ $0.map { $0.isFinite && $0 >= 0 } ?? false }) else { return [] }
        return seconds.compactMap { $0 }.sorted().map { Duration.seconds($0) }
    }
}
