import QuartzCore

/// With `--log-readings`, counts the frames the main thread delivers each
/// second and the hitches among them, and logs them with the angle the sky
/// showed or was easing to, so a check can tell a stutter the app causes (a
/// late frame) from one a recording or the mirror adds.
///
/// A hitch is a frame that came more than 1.5 times the display's frame
/// duration after the one before: the frames it stands for were dropped.
/// A stall (a frame 100 ms or more late) is also logged on its own, with
/// the angle, to match it to what the sky was doing.
/// The link asks for no particular rate, so it runs at the rate the system
/// gives the app and does not raise it.
///
/// The main thread's busy time (outside its run loop's wait: working, or
/// blocked in a call such as a render waiting for the GPU) tells whose a
/// late frame is. In a hinge sweep on the iPhone Duo simulator some came
/// with the main thread busy for most of the gap, others (up to 1.2 s, and
/// with no sky drawn at all) with it idle: the system did not deliver the
/// frame.
@MainActor
final class FrameLog: NSObject {
    private let log: ReadingsLog
    /// The angle the sky shows now, or is easing to.
    private let angle: () -> Double?
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var expected = 0.0
    private var second: CFTimeInterval?
    private var frames = 0
    private var hitches = 0
    private var dropped = 0
    private var longest = 0.0
    /// Hitches during which the main thread was busy for more than a frame.
    private var busyHitches = 0
    private var observer: CFRunLoopObserver?
    /// The main thread's busy time since the last frame and over the current
    /// second, and when its current busy stretch began.
    private var busy = 0.0
    private var busySecond = 0.0
    private var busySince: CFTimeInterval?

    init(log: ReadingsLog, angle: @escaping () -> Double?) {
        self.log = log
        self.angle = angle
    }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.runLoop(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    private func runLoop(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        if activity == .afterWaiting {
            busySince = now
        } else if let since = busySince {
            busy += now - since
            busySince = nil
        }
    }

    /// The busy time since the last call, the current stretch included up
    /// to now (the rest of it counts toward the next).
    private func takeBusy(at now: CFTimeInterval) -> Double {
        var total = busy
        if let since = busySince {
            total += now - since
            busySince = now
        }
        busy = 0
        return total
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        let busyNow = takeBusy(at: CACurrentMediaTime())
        busySecond += busyNow
        if let last, expected > 0 {
            let interval = now - last
            frames += 1
            longest = max(longest, interval)
            if interval > 1.5 * expected {
                hitches += 1
                dropped += Int((interval / expected).rounded()) - 1
                if busyNow > expected { busyHitches += 1 }
            }
            if interval >= 0.1 {
                log.record("stall", [
                    "ms": jsonNumber(interval * 1000),
                    "busyMs": jsonNumber(busyNow * 1000),
                    "angle": angle().map { jsonNumber($0) } ?? NSNull(),
                ])
            }
        }
        last = now
        expected = link.targetTimestamp - link.timestamp
        guard let start = second else {
            second = now
            return
        }
        guard now - start >= 1 else { return }
        log.record("frames", [
            "frames": frames,
            "hitches": hitches,
            "dropped": dropped,
            "busyHitches": busyHitches,
            "longestMs": jsonNumber(longest * 1000),
            "busyMs": jsonNumber(busySecond * 1000),
            "frameMs": jsonNumber(expected * 1000, places: 2),
            "angle": angle().map { jsonNumber($0) } ?? NSNull(),
        ])
        second = now
        frames = 0
        hitches = 0
        dropped = 0
        busyHitches = 0
        longest = 0
        busySecond = 0
    }
}
