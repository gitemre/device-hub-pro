import Foundation
import XCTest

/// What a hinge reading does to the sky (Shared/HingeFollower.swift). The
/// angles are ones the iOS 27.1 iPhone Duo simulator reported: closed 0°,
/// 15.4° early in an unfold, tent 71.1°, the half-open book 127.8°.
final class HingeFollowerTests: XCTestCase {
    func testTheFirstReadingJumpsAndLaterOnesFollow() {
        var follower = HingeFollower()
        XCTAssertEqual(follower.availability, .waiting)
        // SwiftUI's first call has no old hinge.
        XCTAssertEqual(follower.reading(old: nil, new: 0), .show(degrees: 0, jump: true))
        XCTAssertEqual(follower.availability, .present)
        XCTAssertEqual(follower.reading(old: 0, new: 15.4), .show(degrees: 15.4, jump: false))
        // At rest SwiftUI repeats the value; the model drops the write.
        XCTAssertEqual(follower.reading(old: 127.8, new: 127.8), .show(degrees: 127.8, jump: false))
    }

    /// A Duo whose first reading comes after the grace: the reading still
    /// arrives at once, and the device has a hinge again.
    func testAReadingAfterTheGraceStillJumps() {
        var follower = HingeFollower()
        XCTAssertEqual(follower.graceEnded(), .noHinge)
        XCTAssertEqual(follower.availability, .absent)
        XCTAssertEqual(follower.reading(old: nil, new: 0), .show(degrees: 0, jump: true))
        XCTAssertEqual(follower.availability, .present)
        // Even if SwiftUI had passed an old hinge, it arrives.
        var other = HingeFollower()
        _ = other.graceEnded()
        XCTAssertEqual(other.reading(old: 71.1, new: 71.1), .show(degrees: 71.1, jump: true))
    }

    func testTheGraceEndsOnlyAWait() {
        var follower = HingeFollower()
        _ = follower.reading(old: nil, new: 0)
        XCTAssertEqual(follower.graceEnded(), .none)
        XCTAssertEqual(follower.availability, .present)
    }

    func testNoHingeIsSaidOnce() {
        var follower = HingeFollower()
        XCTAssertEqual(follower.reading(old: nil, new: nil), .noHinge)
        XCTAssertEqual(follower.availability, .absent)
        XCTAssertEqual(follower.reading(old: nil, new: nil), .none)
        XCTAssertEqual(follower.graceEnded(), .none)
        // A hinge that went away: the slider takes over from there.
        var present = HingeFollower()
        _ = present.reading(old: nil, new: 127.8)
        XCTAssertEqual(present.reading(old: 127.8, new: nil), .noHinge)
    }

    func testANonFiniteAngleIsIgnored() {
        var follower = HingeFollower()
        XCTAssertEqual(follower.reading(old: nil, new: .nan), .none)
        XCTAssertEqual(follower.availability, .waiting)
    }

    /// More than 2° from where the hinge rested stops the Time-Lapse; a
    /// hand on the device does not.
    func testTheTimeLapseStopsOnAMoveOfMoreThanTwoDegrees() {
        var follower = HingeFollower()
        _ = follower.reading(old: nil, new: 127.8)
        follower.timeLapseStarted(hinge: 127.8)
        XCTAssertTrue(follower.isTimeLapsing)
        XCTAssertEqual(follower.reading(old: 127.8, new: 127.8), .none)
        XCTAssertEqual(follower.reading(old: 127.8, new: 129.7), .none)
        XCTAssertEqual(follower.reading(old: 129.7, new: 125.9), .none)
        XCTAssertEqual(follower.reading(old: 125.9, new: 124.0), .stopTimeLapse)
        follower.timeLapseStopped()
        XCTAssertFalse(follower.isTimeLapsing)
        XCTAssertNil(follower.timeLapseAnchor)
        XCTAssertEqual(follower.reading(old: 124.0, new: 71.1), .show(degrees: 71.1, jump: false))
    }

    /// Started before the first reading: that reading is where the hinge
    /// rests, not a move.
    func testATimeLapseStartedBeforeTheFirstReadingAnchorsOnIt() {
        var follower = HingeFollower()
        follower.timeLapseStarted(hinge: nil)
        XCTAssertNil(follower.timeLapseAnchor)
        XCTAssertEqual(follower.reading(old: nil, new: 0), .none)
        XCTAssertEqual(follower.timeLapseAnchor, 0)
        XCTAssertEqual(follower.availability, .present)
        XCTAssertEqual(follower.reading(old: 0, new: 1.5), .none)
        XCTAssertEqual(follower.reading(old: 1.5, new: 71.1), .stopTimeLapse)
    }

    /// Before the first reading: night on the cover, golden hour inside.
    func testTheLikelyAngleIsTheWindowsPosture() {
        XCTAssertEqual(HingeFollower.likelyAngle(regularWidth: false), 0)
        XCTAssertEqual(HingeFollower.likelyAngle(regularWidth: true), 127.8)
        XCTAssertEqual(DayCycle.phase(progress: DayCycle.progress(angleDegrees: HingeFollower.likelyAngle(regularWidth: true))), .goldenHour)
    }
}

/// The Time-Lapse's day (Shared/TimeLapseDay.swift).
final class TimeLapseDayTests: XCTestCase {
    func testOneDayIsNightNoonNight() {
        XCTAssertEqual(TimeLapseDay.angle(elapsed: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(TimeLapseDay.angle(elapsed: 4), 90, accuracy: 1e-9)
        XCTAssertEqual(TimeLapseDay.angle(elapsed: 8), 180, accuracy: 1e-9)
        XCTAssertEqual(TimeLapseDay.angle(elapsed: 12), 90, accuracy: 1e-9)
        XCTAssertEqual(TimeLapseDay.angle(elapsed: 16), 0, accuracy: 1e-9)
        XCTAssertEqual(TimeLapseDay.angle(elapsed: 20), 90, accuracy: 1e-9)
    }

    /// Starting from the angle the sky shows: the rising half reaches it at
    /// the time the inverse gives.
    func testTheInverseStartsOnTheRisingHalf() {
        for degrees in stride(from: 0.0, through: 180, by: 0.5) {
            let elapsed = TimeLapseDay.elapsed(risingTo: degrees)
            XCTAssertTrue((0...8).contains(elapsed), "\(degrees)°: \(elapsed)")
            XCTAssertEqual(TimeLapseDay.angle(elapsed: elapsed), degrees, accuracy: 1e-9, "\(degrees)°")
        }
        XCTAssertEqual(TimeLapseDay.elapsed(risingTo: -5), 0)
        XCTAssertEqual(TimeLapseDay.elapsed(risingTo: 200), 8, accuracy: 1e-9)
        XCTAssertEqual(TimeLapseDay.elapsed(risingTo: .nan), 0)
    }
}
