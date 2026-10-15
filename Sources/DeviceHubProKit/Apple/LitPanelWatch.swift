import CoreVideo
import Foundation

/// Whether a simulator frame is (near) black, read from a few dozen pixels:
/// the lit-panel watchdog (`DarkPanelWatchdog`) asks it for every frame the
/// stage feeds, so it never walks a whole picture.
public enum FrameDarkness {
    /// A pixel whose brightest channel is below this is black. A foldable's
    /// unlit panel is pure black (iPhone Duo on iOS 27.1, 2026-10-14); a dark
    /// wallpaper keeps a few levels above it.
    public static let darkBelow: UInt8 = 10
    /// The grid of pixels sampled: evenly spread over the frame, so a picture
    /// with any content shows it in at least one of them.
    public static let columns = 32
    public static let rows = 48

    /// True when every sampled pixel of `buffer` is black; false when one is
    /// not (the scan ends there); nil for a buffer it cannot read (not
    /// 32BGRA, or locked elsewhere). 1,536 reads at most, whatever the size.
    public static func isDark(_ buffer: CVPixelBuffer) -> Bool? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let columns = min(width, Self.columns), rows = min(height, Self.rows)
        for row in 0..<rows {
            let line = bytes + ((row * 2 + 1) * height / (rows * 2)) * stride
            for column in 0..<columns {
                let pixel = line + ((column * 2 + 1) * width / (columns * 2)) * 4
                if max(pixel[0], pixel[1], pixel[2]) >= darkBelow { return false }
            }
        }
        return true
    }
}

/// Notices that the panel the stage feeds has gone dark, so the lit panel is
/// read off the simulator without waiting for the hinge to stop: the guest
/// lights a panel by how the hinge moved (a one-go drag lit the inner one
/// before 90°, iOS 27.1), and the app's own guess is corrected only by
/// reading the two panels' screenshots.
///
/// A dark spell starts at the first black frame and ends at the first lit
/// one. It asks for a check once the frames stayed black for `darkFor`, and
/// again after `retryGap` while they still are. The checks are counted from
/// the last hinge move or the last fresh panel or session, not from the spell:
/// a screen that is black for good, or flickers between black and lit (a
/// sleeping display, a black app, a video), is read `maximumChecks` times and
/// no more, because the check that found the shown panel to be the lit one
/// says nothing new the next time. A hinge that moves again earns new checks,
/// never closer than `minimumGap`.
///
/// Only frames are watched: a panel that publishes none (an unlit display)
/// is covered by the checks the stage asks for after every fold.
public struct DarkPanelWatchdog: Sendable, Equatable {
    /// How long the fed panel's frames stay black before a check is asked
    /// for: longer than a panel takes to light after the guest switches
    /// (about 100 ms) and shorter than the stage's wait after a drag (500 ms).
    public static let darkFor: Duration = .milliseconds(300)
    /// The wait between the checks one dark spell asks for.
    public static let retryGap: Duration = .milliseconds(1500)
    /// The shortest wait between two checks, whatever moved.
    public static let minimumGap: Duration = .seconds(1)
    /// The checks a hinge move (or a fresh panel) may ask for.
    public static let maximumChecks = 2

    private var darkSince: ContinuousClock.Instant?
    private var asked = 0
    private var lastAsked: ContinuousClock.Instant?

    public init() {}

    /// Whether the last frame seen was black.
    public var isDark: Bool { darkSince != nil }

    /// Notes what the fed panel's current frame looked like at `now`.
    public mutating func observe(dark: Bool, at now: ContinuousClock.Instant) {
        if dark {
            if darkSince == nil { darkSince = now }
        } else {
            darkSince = nil
        }
    }

    /// When the next check may be asked for; nil when the panel is lit or
    /// the checks are used up.
    public var due: ContinuousClock.Instant? {
        guard let darkSince, asked < Self.maximumChecks else { return nil }
        var due = darkSince + Self.darkFor
        if let lastAsked { due = max(due, lastAsked + (asked == 0 ? Self.minimumGap : Self.retryGap)) }
        return due
    }

    /// True, and counted, when a check is due at `now`.
    public mutating func take(at now: ContinuousClock.Instant) -> Bool {
        guard let due, now >= due else { return false }
        asked += 1
        lastAsked = now
        return true
    }

    /// The hinge moved to a new angle: it may light the other panel, so the
    /// watchdog may ask again.
    public mutating func hingeMoved() { asked = 0 }

    /// Forgets the spell: the fed panel or session changed, or a preset's
    /// sweep is under way (the panel it lights is dark until the guest gets
    /// there).
    public mutating func reset() {
        darkSince = nil
        asked = 0
        lastAsked = nil
    }
}

/// Which reads of a foldable's two panels run, wait and retry, by simulator
/// UDID: one at a time for each simulator, so a request made while a read is
/// under way is not lost (it reads again as soon as that one ends), and a read
/// that could not tell the lit panel (both dark, both lit, a screenshot
/// missing) is tried again a few times, after `retryDelays`, as the guest may
/// still be lighting the panel.
public struct LitPanelCheckQueue: Sendable, Equatable {
    /// The waits before the first, second and third retry of an inconclusive
    /// read.
    public static let retryDelays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]

    /// What to do after a read ended.
    public enum Next: Sendable, Equatable {
        case done
        /// A request came in meanwhile: read again now.
        case rerun
        /// The read was inconclusive: read again after the wait, unless a
        /// newer request supersedes it.
        case retry(after: Duration)
    }

    private var running: Set<String> = []
    private var queued: Set<String> = []
    private var retries: [String: Int] = [:]
    /// The simulators whose current read is not retried when inconclusive.
    private var impatient: Set<String> = []

    public init() {}

    /// A check was asked for: true when the caller reads now; false when a
    /// read is running (it reads again once it ends). A fresh request starts
    /// the retries over. With `retriesWhenInconclusive` false the read is
    /// taken once whatever it says (the stage's watchdog asks again itself,
    /// and a panel that is black for good must not be read four times); a
    /// request that retries makes the read it joins retry.
    public mutating func request(_ udid: String, retriesWhenInconclusive: Bool = true) -> Bool {
        retries[udid] = nil
        if retriesWhenInconclusive {
            impatient.remove(udid)
        } else if !running.contains(udid) {
            impatient.insert(udid)
        }
        guard running.insert(udid).inserted else {
            queued.insert(udid)
            return false
        }
        return true
    }

    /// The read for `udid` ended; `conclusive` when it told the lit panel (or
    /// the hinge moved meanwhile, which the next check reads).
    public mutating func finish(_ udid: String, conclusive: Bool) -> Next {
        running.remove(udid)
        if queued.remove(udid) != nil {
            retries[udid] = nil
            running.insert(udid)
            return .rerun
        }
        guard !conclusive, !impatient.contains(udid) else {
            retries[udid] = nil
            impatient.remove(udid)
            return .done
        }
        let attempt = retries[udid, default: 0]
        guard attempt < Self.retryDelays.count else {
            retries[udid] = nil
            return .done
        }
        retries[udid] = attempt + 1
        return .retry(after: Self.retryDelays[attempt])
    }

    /// A retry's wait is over: true when the caller reads now; false when a
    /// newer read is running or was asked for since.
    public mutating func retryDue(_ udid: String) -> Bool {
        running.insert(udid).inserted
    }

    /// The simulator went away: forgets its reads.
    public mutating func forget(_ udid: String) {
        running.remove(udid)
        queued.remove(udid)
        retries[udid] = nil
        impatient.remove(udid)
    }
}

/// What a read of a foldable's two panels means for the fold it was asked at.
public enum LitPanelRead {
    public struct Outcome: Sendable, Equatable {
        /// The panel the session should move to; nil when the record stands.
        public var switchTo: SimulatorFoldPanel?
        /// Whether the read settled the question. False for a read that could
        /// not tell the lit panel (both dark, both lit, a screenshot missing):
        /// `LitPanelCheckQueue.finish` tries it again.
        public var conclusive: Bool
    }

    /// `lit` is the panel the screenshots say is lit (nil when they did not
    /// tell), read while the book went from `asked` to `now`. A hinge that
    /// moved meanwhile is newer than the screenshots: the record stands, the
    /// read counts as settled, and the check that move asked for reads again.
    public static func outcome(
        asked: SimulatorFoldRecord,
        now: SimulatorFoldRecord,
        lit: SimulatorFoldPanel?
    ) -> Outcome {
        guard now.angle == asked.angle, now.panel == asked.panel else { return Outcome(switchTo: nil, conclusive: true) }
        guard let lit else { return Outcome(switchTo: nil, conclusive: false) }
        return Outcome(switchTo: lit == now.panel ? nil : lit, conclusive: true)
    }
}
