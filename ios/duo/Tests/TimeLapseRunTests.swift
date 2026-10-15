import Foundation
import XCTest

/// A Time-Lapse as a function of time (Shared/TimeLapseDay.swift): the sky
/// works out its angle every frame from it, so these pin that it starts
/// where the sky is, moves with no steps, holds where it stopped and hands
/// the sky back without a jump. Times are reference-date seconds, as the
/// app's timeline gives them.
final class TimeLapseRunTests: XCTestCase {
    private let now = 802_000_000.0

    func testItStartsAtTheShownAngleAndRises() {
        for degrees in [0, 45.3, 71.1, 127.8, 180] {
            let run = TimeLapseRun(from: degrees, at: now)
            XCTAssertTrue(run.isPlaying)
            // Reference-date seconds carry about 0.1 µs at this size: a
            // few millionths of a degree.
            XCTAssertEqual(run.angle(at: now), degrees, accuracy: 1e-4, "\(degrees)°")
            if degrees < 180 {
                XCTAssertGreaterThan(run.angle(at: now + 0.1), degrees, "\(degrees)° rises")
            }
        }
    }

    /// One day from night: noon half a period on, night again a period on.
    func testItPlaysTheDayFromItsOwnClock() {
        let run = TimeLapseRun(from: 0, at: now)
        XCTAssertEqual(run.angle(at: now + TimeLapseDay.period / 4), 90, accuracy: 1e-4)
        XCTAssertEqual(run.angle(at: now + TimeLapseDay.period / 2), 180, accuracy: 1e-4)
        XCTAssertEqual(run.angle(at: now + TimeLapseDay.period), 0, accuracy: 1e-4)
    }

    /// Any frame time gives the angle for that time: at 120 frames a second
    /// no frame moves the sky more than the day's fastest speed allows
    /// (90° · 2π / 16 s, about 35° a second), and a late frame simply moves
    /// further instead of the sky holding and then jumping.
    func testFramesMoveInProportionToTheirTime() {
        let run = TimeLapseRun(from: 0, at: now)
        let fastest = 90 * 2 * Double.pi / TimeLapseDay.period
        var time = now
        var previous = run.angle(at: time)
        for _ in 0..<(16 * 120) {
            time += 1.0 / 120
            let angle = run.angle(at: time)
            XCTAssertLessThanOrEqual(abs(angle - previous), fastest / 120 + 1e-9)
            previous = angle
        }
        // Sunrise (104.4°) is near the fastest part of the day: a frame
        // three times as long moves the sun three times as far.
        let sunrise = now + TimeLapseDay.elapsed(risingTo: 104.4)
        let step = run.angle(at: sunrise + 1.0 / 60) - run.angle(at: sunrise)
        let late = run.angle(at: sunrise + 3.0 / 60) - run.angle(at: sunrise)
        XCTAssertEqual(late / step, 3, accuracy: 0.01)
    }

    func testAStoppedRunHoldsTheAngleItStoppedAt() {
        var run = TimeLapseRun(from: 30, at: now)
        let stop = now + 1.7
        let held = run.angle(at: stop)
        run.stop(at: stop)
        XCTAssertFalse(run.isPlaying)
        XCTAssertEqual(run.angle(at: stop + 5), held, accuracy: 1e-9)
        // A second stop keeps the first.
        run.stop(at: stop + 2)
        XCTAssertEqual(run.stoppedAt, stop)
    }

    /// The weight eases the sky between the run and the resting angle: all
    /// run at 1, all hinge at 0, no jump when the run stops (it holds) or
    /// when the weight starts to fall.
    func testTheWeightBlendsTheRunIntoTheRestingAngle() {
        var run = TimeLapseRun(from: 100, at: now)
        XCTAssertEqual(run.angle(at: now + 1, weight: 1, resting: 0), run.angle(at: now + 1), accuracy: 1e-9)
        XCTAssertEqual(run.angle(at: now + 1, weight: 0, resting: 71.1), 71.1)
        let stop = now + 2
        let before = run.angle(at: stop, weight: 1, resting: 180)
        run.stop(at: stop)
        XCTAssertEqual(run.angle(at: stop + 0.016, weight: 1, resting: 180), before, accuracy: 1e-9)
        XCTAssertEqual(run.angle(at: stop + 0.2, weight: 0.5, resting: 180), (before + 180) / 2, accuracy: 1e-9)
        // Out-of-range weights, as an overshooting animation could give.
        XCTAssertEqual(run.angle(at: stop, weight: 1.2, resting: 180), before, accuracy: 1e-9)
        XCTAssertEqual(run.angle(at: stop, weight: -0.1, resting: 180), 180)
        XCTAssertEqual(run.angle(at: stop, weight: .nan, resting: 180), 180)
    }

    /// A play right after a stop carries on from the angle the stopped run
    /// holds, while the sky still shows part of it: the blend is the same
    /// before and after the restart, whatever the weight has eased to.
    /// Once the weight is spent, a play starts from the shown angle again.
    func testARestartDuringTheEaseOutCarriesOnFromTheStoppedRun() {
        var stopped = TimeLapseRun(from: 127.8, at: now)
        let stop = now + 7
        let held = stopped.angle(at: stop)
        stopped.stop(at: stop)
        let hinge = 127.8
        for delay in [0.0, 0.1, 0.2, 0.3, 0.49] {
            let restart = stop + delay
            let run = TimeLapseRun.start(after: stopped, shown: hinge, at: restart)
            XCTAssertTrue(run.isPlaying)
            XCTAssertEqual(run.angle(at: restart), held, accuracy: 1e-4, "restart \(delay) s after the stop")
            for weight in [0.03, 0.13, 0.46, 1] {
                XCTAssertEqual(
                    run.angle(at: restart, weight: weight, resting: hinge),
                    stopped.angle(at: restart, weight: weight, resting: hinge),
                    accuracy: 1e-4, "restart \(delay) s after the stop, weight \(weight)"
                )
            }
        }
        let late = stop + 2
        XCTAssertEqual(TimeLapseRun.start(after: stopped, shown: hinge, at: late).angle(at: late), hinge, accuracy: 1e-4)
        XCTAssertEqual(TimeLapseRun.start(after: stopped, shown: hinge, at: stop + TimeLapseRun.easeOut).angle(at: stop + TimeLapseRun.easeOut), hinge, accuracy: 1e-4)
        XCTAssertEqual(TimeLapseRun.start(after: nil, shown: 71.1, at: now).angle(at: now), 71.1, accuracy: 1e-4)
    }
}
