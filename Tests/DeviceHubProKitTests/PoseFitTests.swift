import XCTest
import CoreGraphics
@testable import DeviceHubProKit

final class PoseFitTests: XCTestCase {
    private let phone = CGSize(width: 1080, height: 2400)

    func testBoundingBoxAtQuarterTurnsTransposes() {
        let upright = PoseFit.rotatedBoundingBox(phone, angle: 0)
        XCTAssertEqual(upright.width, 1080, accuracy: 0.001)
        XCTAssertEqual(upright.height, 2400, accuracy: 0.001)

        let sideways = PoseFit.rotatedBoundingBox(phone, angle: -90)
        XCTAssertEqual(sideways.width, 2400, accuracy: 0.001)
        XCTAssertEqual(sideways.height, 1080, accuracy: 0.001)
    }

    /// Rest poses fit exactly like a plain layout of the posed size, at any
    /// turn count (`presentedAngle` keeps growing with repeated rotations).
    func testBoundingBoxIsExactAtQuarterTurnsOfAnyCount() {
        let transposed = CGSize(width: phone.height, height: phone.width)
        for turns in [-9, -5, -3, -1, 1, 3, 7, 11] {
            XCTAssertEqual(PoseFit.rotatedBoundingBox(phone, angle: -90 * Double(turns)), transposed, "\(turns)")
        }
        for turns in [-8, -4, -2, 0, 2, 6, 10] {
            XCTAssertEqual(PoseFit.rotatedBoundingBox(phone, angle: -90 * Double(turns)), phone, "\(turns)")
        }
        XCTAssertTrue(
            PoseFit.rotatedBoundingBox(phone, angle: .infinity).width.isNaN,
            "a non-finite angle takes the trigonometric path instead of trapping"
        )
    }

    func testBoundingBoxAt45DegreesUsesTheDiagonal() {
        let bounds = PoseFit.rotatedBoundingBox(phone, angle: 45)
        let diagonal = (phone.width + phone.height) * sqrt(2) / 2
        XCTAssertEqual(bounds.width, diagonal, accuracy: 0.001)
        XCTAssertEqual(bounds.height, diagonal, accuracy: 0.001)
    }

    func testScaleMatchesThePlainFitAtRest() {
        let box = CGSize(width: 800, height: 600)
        // Portrait: height-limited (600/2400 = 0.25); landscape: width-limited
        // (800/2400 = 0.333).
        XCTAssertEqual(PoseFit.scale(angle: 0, nativeSize: phone, box: box), 0.25, accuracy: 0.0001)
        XCTAssertEqual(PoseFit.scale(angle: -90, nativeSize: phone, box: box), 1.0 / 3.0, accuracy: 0.0001)
    }

    /// The stage lays the composition out at the rest pose's fit, so the
    /// wrapper's correction is exactly 1 at rest in every pose. Laid out at
    /// the natural pose's fit (the old rule), the landscape correction was
    /// 0.333 / 0.25 = 1.33 here: the video's drawable was enlarged 1.33x.
    func testCorrectionIsExactlyOneAtEveryRestPose() {
        let sizes = [
            phone,
            CGSize(width: 2204, height: 2274),     // pixel_9_pro_fold, open
            CGSize(width: 1236, height: 2554),     // pixel_9_pro_fold, cover
            CGSize(width: 1408, height: 2965),     // pixel_10_pro
            CGSize(width: 2798, height: 1837),     // pixel_tablet (landscape-native)
            CGSize(width: 10, height: 10),         // under the cap
        ]
        let boxes = [CGSize(width: 800, height: 600), CGSize(width: 1284, height: 810), CGSize(width: 204, height: 440)]
        for size in sizes {
            for box in boxes {
                for turns in -6...6 {
                    let rest = -90 * Double(turns)
                    XCTAssertEqual(
                        PoseFit.correction(angle: rest, restAngle: rest, nativeSize: size, box: box),
                        1,
                        "\(size) in \(box) at \(turns) turns"
                    )
                }
            }
        }
        XCTAssertEqual(
            PoseFit.scale(angle: -90, nativeSize: phone, box: CGSize(width: 800, height: 600))
                / PoseFit.scale(angle: 0, nativeSize: phone, box: CGSize(width: 800, height: 600)),
            4.0 / 3.0,
            accuracy: 0.0001,
            "the landscape enlargement the old natural-pose layout had"
        )
    }

    /// What is on screen (the layout's scale times the correction) depends
    /// only on the presented angle, never on the rest pose the layout was
    /// built for: the layout can switch to the new rest pose at the start
    /// of a rotation without anything moving, and every frame of the turn
    /// looks as it did with the natural-pose layout.
    func testOnScreenSizeDoesNotDependOnTheRestPose() {
        let box = CGSize(width: 1284, height: 810)
        for size in [phone, CGSize(width: 2204, height: 2274)] {
            for step in 0...36 {
                let angle = -Double(step) * 2.5
                let expected = PoseFit.scale(angle: angle, nativeSize: size, box: box)
                for rest in [0.0, -90, -180, 90] {
                    let layout = PoseFit.scale(angle: rest, nativeSize: size, box: box)
                    let correction = PoseFit.correction(angle: angle, restAngle: rest, nativeSize: size, box: box)
                    XCTAssertEqual(layout * correction, expected, accuracy: 1e-12, "\(size) at \(angle)° resting at \(rest)°")
                }
            }
        }
    }

    /// Mid-turn the correction dips below 1 toward the diagonal and, while a
    /// rotation leaves the pose with the larger fit, starts above 1.
    func testCorrectionMidTurn() {
        let box = CGSize(width: 800, height: 600)
        // To landscape: the layout already has the larger landscape fit.
        XCTAssertEqual(PoseFit.correction(angle: 0, restAngle: -90, nativeSize: phone, box: box), 0.75, accuracy: 1e-9)
        XCTAssertLessThan(PoseFit.correction(angle: -45, restAngle: -90, nativeSize: phone, box: box), 0.75)
        // Back to portrait: the first frames still show the landscape fit.
        XCTAssertEqual(PoseFit.correction(angle: -90, restAngle: 0, nativeSize: phone, box: box), 4.0 / 3.0, accuracy: 1e-9)
    }

    func testScaleShrinksAtIntermediateAngles() {
        let box = CGSize(width: 800, height: 600)
        let at45 = PoseFit.scale(angle: 45, nativeSize: phone, box: box)
        XCTAssertLessThan(at45, 0.25)
        XCTAssertGreaterThan(at45, 0.2)
    }

    func testScaleNeverUpscalesAndHonorsTheFloor() {
        let tiny = CGSize(width: 10, height: 10)
        XCTAssertEqual(PoseFit.scale(angle: 0, nativeSize: tiny, box: CGSize(width: 800, height: 600)), 1)
        XCTAssertEqual(
            PoseFit.scale(angle: 0, nativeSize: phone, box: .zero, floor: 0.05),
            1,
            "degenerate box falls back to the cap"
        )
    }

    func testDegenerateBoxReturnsTheCap() {
        XCTAssertEqual(PoseFit.scale(angle: 0, nativeSize: .zero, box: CGSize(width: 10, height: 10)), 1)
    }

    /// A quarter turn about the centre of a frame whose width − height is an
    /// odd number of pixels puts every pixel half a pixel off the grid; the
    /// offset moves it back, only as far as the turn has gone, and is 0 when
    /// the parity is even or the turn is a half one.
    func testPixelGridOffset() {
        let odd = CGSize(width: 1300.5, height: 866)      // 869 px apart at 2x
        let even = CGSize(width: 1300, height: 866)       // 868 px
        XCTAssertEqual(PoseFit.pixelGridOffset(angle: -90, size: odd, pixelScale: 2), -0.25, accuracy: 1e-12)
        XCTAssertEqual(PoseFit.pixelGridOffset(angle: 90, size: odd, pixelScale: 2), -0.25, accuracy: 1e-12)
        XCTAssertEqual(PoseFit.pixelGridOffset(angle: -270, size: odd, pixelScale: 2), -0.25, accuracy: 1e-12)
        XCTAssertEqual(PoseFit.pixelGridOffset(angle: 0, size: odd, pixelScale: 2), 0, accuracy: 1e-12)
        XCTAssertEqual(PoseFit.pixelGridOffset(angle: -180, size: odd, pixelScale: 2), 0, accuracy: 1e-12)
        XCTAssertEqual(PoseFit.pixelGridOffset(angle: -45, size: odd, pixelScale: 2), -0.25 * sqrt(0.5), accuracy: 1e-12)
        XCTAssertEqual(PoseFit.pixelGridOffset(angle: -90, size: even, pixelScale: 2), 0)
        // At 1x a whole point is a pixel: 867 x 866 is odd, 868 x 866 even.
        XCTAssertEqual(PoseFit.pixelGridOffset(angle: -90, size: CGSize(width: 867, height: 866), pixelScale: 1), -0.5, accuracy: 1e-12)
        XCTAssertEqual(PoseFit.pixelGridOffset(angle: -90, size: CGSize(width: 868, height: 866), pixelScale: 1), 0)
        XCTAssertEqual(PoseFit.pixelGridOffset(angle: -90, size: odd, pixelScale: 0), 0, "no scale, no offset")
    }

    /// The thin-bezel path (an Apple device's chrome) expresses its bezel
    /// in the natural pose's scaled space; the fit at rest must come back
    /// exactly to the baked scale (the wrapper correction is 1 at rest, so
    /// nothing jumps when a rotation settles).
    func testBezelCompositionRatioIsOneAtRest() {
        let screen = CGSize(width: 1080, height: 2400)
        let bezel: CGFloat = 8
        let available = CGSize(width: 800, height: 600)
        let box = CGSize(
            width: available.width - bezel * 2 - 16,
            height: available.height - bezel * 2 - 16
        )
        let scale = PoseFit.scale(angle: 0, nativeSize: screen, box: box)
        let composition = CGSize(
            width: screen.width + bezel * 2 / scale,
            height: screen.height + bezel * 2 / scale
        )
        let fullBox = CGSize(width: available.width - 16, height: available.height - 16)
        XCTAssertEqual(
            PoseFit.scale(angle: 0, nativeSize: composition, box: fullBox),
            scale,
            accuracy: 0.0001
        )
    }

    /// The landscape twin, as `MirrorStageContent.screenContent` (an Apple
    /// device's thin bezel) lays it out: the composition is the natural
    /// pose's (the screen fitted inside
    /// the 8 pt bezel), laid out at the landscape pose's fit. At rest the
    /// correction is exactly 1, the rotated composition fills the box on its
    /// limiting axis, and the bezel is as wide as the wrapper's enlargement
    /// used to make it: the landscape stage looks as before, only sharper.
    func testLandscapeBezelCompositionIsLaidOutAtItsRestFit() {
        let screen = CGSize(width: 1080, height: 2400)
        let bezel: CGFloat = 8
        // The old landscape correction per stage: enlarged in wide stages,
        // shrunk in the compact window's tall one (a drawable bigger than
        // what was shown; now it is the shown size there too).
        let stages: [(available: CGSize, oldCorrection: CGFloat)] = [
            (CGSize(width: 800, height: 600), 1.3425),
            (CGSize(width: 1300, height: 866), 1.5106),
            (CGSize(width: 220, height: 440), 0.4811),
        ]
        for (available, expectedOldCorrection) in stages {
            let naturalBox = CGSize(
                width: available.width - bezel * 2 - 16,
                height: available.height - bezel * 2 - 16
            )
            let natural = min(naturalBox.width / screen.width, naturalBox.height / screen.height, 1)
            let composition = CGSize(
                width: screen.width + bezel * 2 / natural,
                height: screen.height + bezel * 2 / natural
            )
            let fullBox = CGSize(width: available.width - 16, height: available.height - 16)

            for turns in [1, 3, -1] {
                let rest = -90 * Double(turns)
                let scale = PoseFit.scale(angle: rest, nativeSize: composition, box: fullBox)
                XCTAssertEqual(
                    PoseFit.correction(angle: rest, restAngle: rest, nativeSize: composition, box: fullBox),
                    1,
                    "\(available)"
                )
                // The laid-out composition: screen at `scale`, bezel grown
                // with it. Rotated, it fits the box and touches it.
                let growth = scale / natural
                let outer = CGSize(
                    width: screen.width * scale + bezel * growth * 2,
                    height: screen.height * scale + bezel * growth * 2
                )
                XCTAssertLessThanOrEqual(outer.height, fullBox.width + 1e-9, "\(available)")
                XCTAssertLessThanOrEqual(outer.width, fullBox.height + 1e-9, "\(available)")
                XCTAssertEqual(
                    max(outer.height / fullBox.width, outer.width / fullBox.height),
                    1,
                    accuracy: 1e-9,
                    "\(available)"
                )
                // The old layout (natural fit) times the old correction.
                let oldCorrection = scale / natural
                XCTAssertEqual(outer.height, (screen.height * natural + bezel * 2) * oldCorrection, accuracy: 1e-9)
                XCTAssertEqual(bezel * growth, bezel * oldCorrection, accuracy: 1e-12)
                XCTAssertEqual(oldCorrection, expectedOldCorrection, accuracy: 0.0001, "\(available)")
            }
        }
    }

    /// The vector body (device frame, Tier 2) is one composition in every
    /// pose, the plan's layout box turned by the wrapper, laid out at the
    /// fit of the pose it rests in: at 0°, 90°, 180° and 270° the correction
    /// is exactly 1 and the turned body fills the stage's box on its
    /// limiting axis. Its bezel is even, so the screen is centred in it and
    /// the video turns about the stage's centre.
    ///
    /// Plans from the API 37 Pixel 9 Pro Fold emulator's real `dumpsys
    /// display` (`api37-emulator/adb-core/shell-dumpsys-display.txt`: the
    /// inner and cover panels) and, as generated input, not device output,
    /// a phone that reports nothing (420 dpi).
    func testVectorCompositionIsLaidOutAtItsRestFit() throws {
        let shapes = DisplayShape.parse(dumpsysDisplay: try AdbCoreFixtureTests.text("shell-dumpsys-display.txt"))
        let plans: [(String, DeviceComposition)] = [
            ("inner", DeviceCompositionPlanner.vector(
                screen: CGSize(width: 2076, height: 2152), displays: shapes, fallbackDensityDpi: nil, hingeCount: 1, quarterTurns: 0
            )),
            ("cover", DeviceCompositionPlanner.vector(
                screen: CGSize(width: 1080, height: 2424), displays: shapes, fallbackDensityDpi: nil, hingeCount: 1, quarterTurns: 0
            )),
            ("phone", DeviceCompositionPlanner.vector(
                screen: phone, displays: [], fallbackDensityDpi: 420, quarterTurns: 0
            )),
        ]
        XCTAssertEqual(plans[0].1.layoutSize.width, 2208.047, accuracy: 0.01, "the inner panel's worked layout")
        XCTAssertEqual(plans[0].1.layoutSize.height, 2284.047, accuracy: 0.01)
        let stages = [CGSize(width: 800, height: 600), CGSize(width: 1300, height: 866), CGSize(width: 220, height: 440)]
        for (name, plan) in plans {
            for available in stages {
                let box = CGSize(width: available.width - 16, height: available.height - 16)
                for turns in 0..<4 {
                    let rest = -90 * Double(turns)
                    let context = "\(name) in \(available), \(turns) turns"
                    XCTAssertEqual(
                        PoseFit.correction(angle: rest, restAngle: rest, nativeSize: plan.layoutSize, box: box),
                        1,
                        accuracy: 1e-12,
                        context
                    )
                    let scale = PoseFit.scale(angle: rest, nativeSize: plan.layoutSize, box: box)
                    let turned = PoseFit.rotatedBoundingBox(
                        CGSize(width: plan.layoutSize.width * scale, height: plan.layoutSize.height * scale),
                        angle: rest
                    )
                    XCTAssertLessThanOrEqual(turned.width, box.width + 1e-9, context)
                    XCTAssertLessThanOrEqual(turned.height, box.height + 1e-9, context)
                    XCTAssertEqual(max(turned.width / box.width, turned.height / box.height), 1, accuracy: 1e-9, context)

                    let placed = plan.placed(pointsPerUnit: scale, pixelScale: 2)
                    XCTAssertEqual(placed.screen.midX, placed.size.width / 2, accuracy: 1e-9, "\(context): centred")
                    XCTAssertEqual(placed.screen.midY, placed.size.height / 2, accuracy: 1e-9, "\(context): centred")
                }
            }
        }
    }
}
