import XCTest
import SwiftUI
import DeviceHubProKit
@testable import DeviceHubProApp

/// The emulator stage: the frame follows the device pose (the physical
/// model Rotate set), the picture follows the display rotation the stream
/// reports. The two are independent, so every pose x display rotation
/// combination exists (a phone upside down with Android still in landscape,
/// a tablet turned to 180 with the content upright).
@MainActor
final class EmulatorDevicePoseTests: XCTestCase {
    private func animator() -> StagePoseAnimator {
        StagePoseAnimator(reduceMotion: { false }, animate: { _, body, completion in
            body()
            completion()
        })
    }

    // MARK: - Settle logic

    /// The Rotate press confirms the pose it set; a display rotation that
    /// Android keeps (a phone at upside down) never reaches the animator.
    func testPressesReachUpsideDownAndTheConfirmedPoseSticks() {
        let pose = animator()
        for expected in [1, 2] {
            pose.beginRotation(.left)
            pose.settle(rotation: TextureRotation.normalized(pose.targetTurns))
            XCTAssertEqual(pose.targetTurns, expected)
            XCTAssertEqual(pose.presentedAngle, -90 * Double(expected), accuracy: 0.001)
            XCTAssertFalse(pose.isAnimating)
        }
        // A failed press after that goes back to upside down, not portrait.
        pose.beginRotation(.left)
        pose.cancelRotation()
        XCTAssertEqual(pose.targetTurns, 2)
    }

    /// Portrait straight to upside down by two turns the other way.
    func testTwoTurnsTheOtherWayReachUpsideDown() {
        let pose = animator()
        for _ in 0..<2 {
            pose.beginRotation(.right)
            pose.settle(rotation: TextureRotation.normalized(pose.targetTurns))
        }
        XCTAssertEqual(pose.targetTurns, -2)
        XCTAssertEqual(TextureRotation.normalized(pose.targetTurns), 2)
        XCTAssertEqual(pose.presentedAngle, 180, accuracy: 0.001)
    }

    /// A pose read from the emulator at a session's start is snapped to.
    func testSessionStartSnapsToTheModelPose() {
        let pose = animator()
        pose.snap(toTurns: AndroidDevicePose.turns(forRotationDegrees: 180))
        XCTAssertEqual(pose.targetTurns, 2)
        XCTAssertEqual(pose.presentedAngle, -180, accuracy: 0.001)
        pose.reset()
        XCTAssertEqual(pose.targetTurns, 0)
    }

    /// A pose changed from outside the app follows the model reading.
    func testAnExternalPoseChangeAnimatesToTheModelPose() {
        let pose = animator()
        pose.settle(rotation: AndroidDevicePose.turns(forRotationDegrees: -90))
        XCTAssertEqual(pose.targetTurns, -1)
        pose.settle(rotation: AndroidDevicePose.turns(forRotationDegrees: -180))
        XCTAssertEqual(TextureRotation.normalized(pose.targetTurns), 2)
    }

    // MARK: - Touch mapping, pose x display rotation

    /// Counter-clockwise quarter turns about the centre of a native `size`
    /// layout, y down: where the stage wrapper puts a native point.
    private func presented(_ p: CGPoint, native: CGSize, turns: Int) -> CGPoint {
        var dx = p.x - native.width / 2
        var dy = p.y - native.height / 2
        var w = native.width, h = native.height
        for _ in 0..<TextureRotation.normalized(turns) {
            (dx, dy) = (dy, -dx)
            (w, h) = (h, w)
        }
        return CGPoint(x: dx + w / 2, y: dy + h / 2)
    }

    /// The inverse: a click in the presented stage back in the native layout
    /// (what the pose wrapper's hit test does before the mirror sees it).
    private func native(fromPresented p: CGPoint, native size: CGSize, turns: Int) -> CGPoint {
        let n = TextureRotation.normalized(turns)
        let swapped = n % 2 == 1
        let w = swapped ? size.height : size.width
        let h = swapped ? size.width : size.height
        var dx = p.x - w / 2
        var dy = p.y - h / 2
        for _ in 0..<n { (dx, dy) = (-dy, dx) }
        return CGPoint(x: dx + size.width / 2, y: dy + size.height / 2)
    }

    /// A tap on the guest's pixel lands on that pixel in all 16 combinations
    /// of device pose and display rotation.
    func testATapReachesTheSameGuestPixelInEveryPoseAndDisplayRotation() throws {
        // The panel is 400 x 800 upright (portrait native); the guest buffer
        // is posed by the display rotation (swapped when odd).
        let nativeSize = CGSize(width: 400, height: 800)
        let upright = [(40, 60), (200, 400), (359, 740), (0, 0)]
        for pose in 0..<4 {
            for display in 0..<4 {
                let posedW = display % 2 == 1 ? 800 : 400
                let posedH = display % 2 == 1 ? 400 : 800
                let layout = try XCTUnwrap(MirrorLayout(
                    posedWidth: posedW,
                    posedHeight: posedH,
                    rotation: display,
                    margin: 1.0,
                    allowsUpscaling: true,
                    viewSize: nativeSize,
                    drawableSize: nativeSize
                ))
                for (ux, uy) in upright {
                    // The pixel's centre in the native layout, as drawn.
                    let nativePoint = CGPoint(x: Double(ux) + 0.5, y: Double(uy) + 0.5)
                    let shown = presented(nativePoint, native: nativeSize, turns: pose)
                    let back = native(fromPresented: shown, native: nativeSize, turns: pose)
                    XCTAssertEqual(back.x, nativePoint.x, accuracy: 0.001, "pose \(pose) display \(display)")
                    XCTAssertEqual(back.y, nativePoint.y, accuracy: 0.001, "pose \(pose) display \(display)")
                    let mapped = layout.framePoint(atViewPoint: back, isFlipped: true)
                    let expected = TextureRotation.posedPoint(
                        x: ux, y: uy, posedWidth: posedW, posedHeight: posedH, rotation: display
                    )
                    XCTAssertEqual(mapped?.x, Int32(expected.x), "pose \(pose) display \(display) (\(ux), \(uy))")
                    XCTAssertEqual(mapped?.y, Int32(expected.y), "pose \(pose) display \(display) (\(ux), \(uy))")
                }
            }
        }
    }

    /// The model: portrait to landscape to upside down on a phone leaves
    /// Android in landscape. The frame is at pose 2 and the picture keeps
    /// the landscape display's turn, which differs from a tablet that turned
    /// to 180 (display rotation 2, upright in the frame).
    func testPhoneKeepsItsLandscapeAtUpsideDownWhereATabletTurns() throws {
        let nativeSize = CGSize(width: 400, height: 800)
        func layout(display: Int) throws -> MirrorLayout {
            try XCTUnwrap(MirrorLayout(
                posedWidth: display % 2 == 1 ? 800 : 400,
                posedHeight: display % 2 == 1 ? 400 : 800,
                rotation: display, margin: 1.0, allowsUpscaling: true,
                viewSize: nativeSize, drawableSize: nativeSize
            ))
        }
        XCTAssertEqual(try layout(display: 1).uprightSize.width, 400, "the picture is the panel's native shape either way")
        XCTAssertEqual(try layout(display: 2).uprightSize.height, 800)
        // Same tap on the native panel, different guest pixel: the picture's turn.
        let tap = CGPoint(x: 100, y: 100)
        let phone = try layout(display: 1).framePoint(atViewPoint: tap, isFlipped: true)
        let tablet = try layout(display: 2).framePoint(atViewPoint: tap, isFlipped: true)
        XCTAssertNotEqual(phone?.x, tablet?.x)
    }
}
