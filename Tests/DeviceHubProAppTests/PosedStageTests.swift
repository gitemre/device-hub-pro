import XCTest
import SwiftUI
@testable import DeviceHubProKit
@testable import DeviceHubProApp

/// The live stage in every pose, hosted with the real views
/// (`MirrorStageContent`: the vector body, an Apple device's thin bezel and
/// `FramedMirrorView`, the fold also above its control strip) in an
/// offscreen window: at rest the video's Metal drawable is shown 1:1 (one
/// backing pixel per drawable pixel), a click lands on the device pixel under
/// it, and a rotation resizes the drawable once while the device turns about
/// a fixed centre.
///
/// The windows are hosted at a forced backing scale (`ScaledTestWindow`),
/// 1x and 2x, whatever the display the tests run on: SwiftUI rounds the
/// layout to a whole point at 1x and to a half at 2x, and every expectation
/// below is derived from the hosting window's scale.
///
/// The stage used to lay the device out at its natural pose's fit and let the
/// rotation wrapper enlarge it into landscape: in this 1300x866 pt stage the
/// landscape video of a phone, the thin bezel and the fold's cover was drawn
/// at 1.51x its drawable's size, the open fold's at 1.03x; the drawable also
/// churned through a new size on every frame of a turn.
@MainActor
final class PosedStageTests: XCTestCase {
    private static let stage = CGSize(width: 1300, height: 866)
    /// The backing scales every hosted check runs at.
    private static let scales: [CGFloat] = [1, 2]
    /// The stage one backing pixel wider: width − height is an odd number of
    /// pixels, so a quarter turn about its centre lands half a pixel off the
    /// grid unless the wrapper moves it back.
    private static func oddStage(scale: CGFloat) -> CGSize {
        CGSize(width: stage.width + 1 / scale, height: stage.height)
    }
    private static let phone = (width: 1080, height: 2400)

    // MARK: - The hosting scale

    /// The forced scale reaches everything the stage derives from it:
    /// SwiftUI's layout grid (the pose wrapper's `displayScale`), AppKit's
    /// backing conversion, and the video's drawable and contents scale.
    func testAForcedScaleReachesTheStage() async throws {
        for scale in Self.scales {
            let hosted = try host(chrome: .vector, stage: Self.oddStage(scale: scale), scale: scale)
            defer { hosted.window.close() }
            await pose(hosted, rotation: 1, natural: Self.phone)
            let view = try XCTUnwrap(mirrorView(in: hosted.host), "\(scale)x")
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(hosted.window.backingScaleFactor, scale)
            XCTAssertEqual(hosted.host.convertToBacking(hosted.host.bounds).width, hosted.host.bounds.width * scale, "\(scale)x")
            XCTAssertEqual(view.layer?.contentsScale, scale, "\(scale)x")
            XCTAssertEqual(view.drawableSize.width, view.bounds.width * scale, accuracy: 1e-9, "\(scale)x")
            // Landscape in the odd stage: on the grid only if the wrapper
            // moved it by `PoseFit.pixelGridOffset` for this scale.
            try assertOneToOne(hosted, "\(scale)x, rotation 1")
        }
    }

    // MARK: - At rest

    func testVectorBodyVideoIsShownOneToOneAtRestInEveryPose() async throws {
        for scale in Self.scales {
            for stage in [Self.stage, Self.oddStage(scale: scale)] {
                let hosted = try host(chrome: .vector, stage: stage, scale: scale)
                defer { hosted.window.close() }
                for rotation in 0..<4 {
                    await pose(hosted, rotation: rotation, natural: Self.phone)
                    try assertOneToOne(hosted, "vector body in \(stage) at \(scale)x, rotation \(rotation)")
                }
            }
        }
    }

    /// An Apple device keeps the thin bezel (`DeviceChrome.thinBezel`).
    func testAnAppleDevicesThinBezelVideoIsShownOneToOneAtRestInEveryPose() async throws {
        for scale in Self.scales {
            for stage in [Self.stage, Self.oddStage(scale: scale)] {
                let hosted = try host(chrome: .thinBezel, stage: stage, scale: scale)
                defer { hosted.window.close() }
                for rotation in 0..<4 {
                    await pose(hosted, rotation: rotation, natural: Self.phone)
                    try assertOneToOne(hosted, "thin bezel in \(stage) at \(scale)x, rotation \(rotation)")
                }
            }
        }
    }

    /// The fold also above its control strip, as the main stage shows a
    /// foldable emulator: the device is fitted into the stage less the strip
    /// and sits at the top.
    func testFramedVideoIsShownOneToOneAtRestInEveryPose() async throws {
        let cases: [(skin: String, natural: (width: Int, height: Int), strip: Bool)] = [
            ("pixel_9_pro_fold", (2076, 2152), false),  // open
            ("pixel_9_pro_fold", (2076, 2152), true),
            ("pixel_9_pro_fold", (1080, 2424), false),  // cover
            ("pixel_9_pro_fold", (1080, 2424), true),
            ("pixel_10_pro", (1280, 2856), false),
        ]
        for scale in Self.scales {
            for (name, natural, strip) in cases {
                for stage in [Self.stage, Self.oddStage(scale: scale)] {
                    let hosted = try host(
                        chrome: .skin(sdkSkin(named: name)),
                        stage: stage,
                        scale: scale,
                        foldControls: strip
                    )
                    defer { hosted.window.close() }
                    for rotation in 0..<4 {
                        await pose(hosted, rotation: rotation, natural: natural)
                        try assertOneToOne(
                            hosted,
                            "\(name) \(natural) strip \(strip) in \(stage) at \(scale)x, rotation \(rotation)"
                        )
                    }
                }
            }
        }
    }

    /// The flat mirror caps its image at one frame pixel per point, so its
    /// image does not grow with the view, and its layer keeps center
    /// gravity: Core Animation then shows the last frame unscaled while a
    /// sidebar toggle or window resize changes the view's size, until the
    /// next draw. A configuration check: what the layer shows in that moment
    /// is Core Animation's and is not captured here. (The posed surfaces use
    /// resize gravity instead; `assertOneToOne` checks that.)
    func testTheFlatMirrorKeepsCentreGravity() async throws {
        let hosted = try host(chrome: .vector, stage: Self.stage, scale: 2, framed: false)
        defer { hosted.window.close() }
        await pose(hosted, rotation: 0, natural: Self.phone)
        let view = try XCTUnwrap(mirrorView(in: hosted.host))
        XCTAssertFalse(view.allowsUpscaling)
        XCTAssertEqual(view.layer?.contentsGravity, .center, "configured gravity")
    }

    // MARK: - Golden geometry

    /// The framed stage's video at rest, pinned before the stage is rebuilt
    /// on one composition plan (device frame, Tier 2): for the five framed
    /// cases of `testFramedVideoIsShownOneToOneAtRestInEveryPose` in the
    /// 1300x866 stage, in every rest pose, the `MirrorMetalView`'s rect in
    /// window coordinates (its turned bounding box: y up, transposed in
    /// rotations 1 and 3) and its layer's corner clip. A refactor that moves
    /// the video or changes its clip by a hundredth of a point fails here.
    ///
    /// Recorded from the stage at 69ed133 on a 2x display, with the
    /// installed SDK's skins and no device shapes, so the corner is the
    /// skin's own (`ScreenCornerPolicy`: the cover's and the 10 Pro's
    /// declared 75 and 99, the inner screen's artwork opening). SwiftUI
    /// rounds the layout to a different pixel grid at other scales, so the
    /// table only holds at 2x: it is hosted in a window forced to 2x, which
    /// lays the stage out as a 2x display does, so it also runs on a 1x
    /// display. A new SDK skin revision can move it too, and is then
    /// re-recorded from the measured values the failure messages print.
    func testFramedGeometryGolden() async throws {
        for golden in Self.framedGolden {
            let hosted = try host(
                chrome: .skin(sdkSkin(named: golden.skin)),
                stage: Self.stage,
                scale: 2,
                foldControls: golden.strip
            )
            defer { hosted.window.close() }
            XCTAssertEqual(hosted.window.backingScaleFactor, 2, "the golden geometry was recorded at 2x")
            for (rotation, want) in golden.poses.enumerated() {
                await pose(hosted, rotation: rotation, natural: golden.natural)
                let context = "\(golden.skin) \(golden.natural) strip \(golden.strip), rotation \(rotation)"
                let view = try XCTUnwrap(mirrorView(in: hosted.host), context)
                // SwiftUI applies the pose on its next update, which a busy
                // machine can hold back past `pose`'s wait.
                await waitUntil("\(context): the stage turned") {
                    abs(remainder(poseAngle(of: view) - hosted.model.workspace.mirror.stagePose.restAngle, 360)) < 1e-6
                }
                hosted.host.layoutSubtreeIfNeeded()
                view.layoutSubtreeIfNeeded()
                let rect = onScreenRect(of: view)
                let radius = try XCTUnwrap(view.layer?.cornerRadius, context)
                let measured = "\(context): measured (\(rect.minX), \(rect.minY), \(rect.width), \(rect.height)), radius \(radius)"
                XCTAssertEqual(rect.minX, want.rect.minX, accuracy: 0.01, "\(measured): x")
                XCTAssertEqual(rect.minY, want.rect.minY, accuracy: 0.01, "\(measured): y")
                XCTAssertEqual(rect.width, want.rect.width, accuracy: 0.01, "\(measured): width")
                XCTAssertEqual(rect.height, want.rect.height, accuracy: 0.01, "\(measured): height")
                XCTAssertEqual(radius, want.cornerRadius, accuracy: 0.01, "\(measured): corner radius")
            }
        }
    }

    /// One framed case of the golden table: per rest pose (rotation 0...3),
    /// the video's rect in window coordinates and its layer's corner radius,
    /// points.
    private struct FramedGolden {
        let skin: String
        let natural: (width: Int, height: Int)
        let strip: Bool
        let poses: [(rect: CGRect, cornerRadius: CGFloat)]
    }

    private static let framedGolden: [FramedGolden] = [
        FramedGolden(skin: "pixel_9_pro_fold", natural: (2076, 2152), strip: false, poses: [  // open
            (CGRect(x: 261.5, y: 30.5, width: 775.5, height: 804.5), 44.7077),
            (CGRect(x: 235.5, y: 32.0, width: 830.0, height: 800.5), 46.1277),
            (CGRect(x: 263.0, y: 31.0, width: 775.5, height: 804.5), 44.7077),
            (CGRect(x: 234.5, y: 33.5, width: 830.0, height: 800.5), 46.1277),
        ]),
        FramedGolden(skin: "pixel_9_pro_fold", natural: (2076, 2152), strip: true, poses: [
            (CGRect(x: 279.5, y: 69.5, width: 739.5, height: 766.5), 42.6038),
            (CGRect(x: 255.0, y: 71.0, width: 791.0, height: 762.5), 43.9570),
            (CGRect(x: 281.0, y: 70.0, width: 739.5, height: 766.5), 42.6038),
            (CGRect(x: 254.0, y: 72.5, width: 791.0, height: 762.5), 43.9570),
        ]),
        FramedGolden(skin: "pixel_9_pro_fold", natural: (1080, 2424), strip: false, poses: [  // cover
            (CGRect(x: 475.5, y: 28.0, width: 359.5, height: 806.5), 24.9608),
            (CGRect(x: 43.0, y: 169.5, width: 1219.0, height: 543.0), 37.7056),
            (CGRect(x: 465.0, y: 31.5, width: 359.5, height: 806.5), 24.9608),
            (CGRect(x: 38.0, y: 153.5, width: 1219.0, height: 543.0), 37.7056),
        ]),
        FramedGolden(skin: "pixel_9_pro_fold", natural: (1080, 2424), strip: true, poses: [
            (CGRect(x: 484.0, y: 67.0, width: 342.5, height: 769.0), 23.7862),
            (CGRect(x: 43.0, y: 189.5, width: 1219.0, height: 543.0), 37.7056),
            (CGRect(x: 473.5, y: 70.0, width: 342.5, height: 769.0), 23.7862),
            (CGRect(x: 38.0, y: 173.5, width: 1219.0, height: 543.0), 37.7056),
        ]),
        FramedGolden(skin: "pixel_10_pro", natural: (1280, 2856), strip: false, poses: [
            (CGRect(x: 465.0, y: 22.0, width: 367.0, height: 819.0), 28.3811),
            (CGRect(x: 34.0, y: 153.5, width: 1237.0, height: 554.5), 42.8722),
            (CGRect(x: 468.0, y: 25.0, width: 367.0, height: 819.0), 28.3811),
            (CGRect(x: 29.0, y: 158.0, width: 1237.0, height: 554.5), 42.8722),
        ]),
    ]

    // MARK: - Input

    /// Clicks go through AppKit's conversion (which undoes the rotation the
    /// wrapper applies) and the layout the renderer drew. On screen the
    /// posed buffer is upright, so a point a given fraction across and down
    /// the visible video is that fraction of the posed frame, in every pose;
    /// and a scroll delta in window points is converted with the layout's
    /// points per frame pixel, which is only the on-screen one at 1:1.
    ///
    /// The visible video is the frame aspect-fitted and centred in the
    /// view's on-screen rect, as the renderer fits it into the view's
    /// bounds. The view is laid out at the video's aspect only to within the
    /// pixel rounding of its sides, which at 1x (a whole point, 1.4 frame
    /// pixels of this phone) is as large as the click tolerance, so the
    /// fractions are taken of the video, not of the view.
    func testClicksLandOnTheDevicePixelUnderThemInEveryPose() async throws {
        try await loadPipeline()
        for scale in Self.scales {
            let hosted = try host(chrome: .vector, stage: Self.stage, scale: scale)
            defer { hosted.window.close() }
            for rotation in 0..<4 {
                let context = "\(scale)x, rotation \(rotation)"
                let posed = await pose(hosted, rotation: rotation, natural: Self.phone)
                let view = try XCTUnwrap(mirrorView(in: hosted.host), context)
                await waitUntil("\(context): the frame was drawn") {
                    view.presentedLayout?.rotation == rotation && view.presentedLayout?.posedWidth == posed.width
                }
                let layout = try XCTUnwrap(view.presentedLayout, context)
                let visible = onScreenRect(of: view)
                let fit = min(visible.width / CGFloat(posed.width), visible.height / CGFloat(posed.height))
                let video = CGRect(
                    x: visible.midX - CGFloat(posed.width) * fit / 2,
                    y: visible.midY - CGFloat(posed.height) * fit / 2,
                    width: CGFloat(posed.width) * fit,
                    height: CGFloat(posed.height) * fit
                )
                for (fx, fy) in [(0.1, 0.1), (0.8, 0.25), (0.3, 0.9), (0.5, 0.5)] {
                    // Window coordinates grow upward; `fy` runs down the screen.
                    let click = CGPoint(x: video.minX + fx * video.width, y: video.maxY - fy * video.height)
                    let pixel = try XCTUnwrap(view.devicePoint(at: view.convert(click, from: nil)), context)
                    XCTAssertEqual(Double(pixel.x), fx * Double(posed.width), accuracy: 1.5, "\(context) at (\(fx), \(fy))")
                    XCTAssertEqual(Double(pixel.y), fy * Double(posed.height), accuracy: 1.5, "\(context) at (\(fx), \(fy))")
                }
                XCTAssertEqual(layout.pointsPerFramePixel, fit, accuracy: 1e-6, "\(context): window points per frame pixel")
            }
        }
    }

    // MARK: - While turning

    /// The vector body's video is centred in its composition (the bezel is
    /// the same on every side), so it turns about the stage's centre itself.
    func testAVectorBodyTurnResizesTheDrawableOnceAboutAFixedCentre() async throws {
        let upright = CGSize(width: Self.phone.width, height: Self.phone.height)
        // What the stage plans with no device data: the 420 dpi fallback's
        // phone body.
        let composition = DeviceCompositionPlanner.vector(
            screen: upright,
            displays: [],
            fallbackDensityDpi: nil,
            quarterTurns: 0
        ).layoutSize
        let box = CGSize(width: Self.stage.width - 16, height: Self.stage.height - 16)
        let centre = CGPoint(x: Self.stage.width / 2, y: Self.stage.height / 2)
        for scale in Self.scales {
            let clock = TurnClock()
            let hosted = try host(chrome: .vector, stage: Self.stage, scale: scale, turnClock: clock)
            defer { hosted.window.close() }
            try await assertTurns(hosted, clock: clock, natural: Self.phone, "vector body at \(scale)x") { angle in
                let grid = PoseFit.pixelGridOffset(angle: angle, size: Self.stage, pixelScale: scale)
                return (
                    longSide: upright.height * PoseFit.scale(angle: angle, nativeSize: composition, box: box),
                    centre: CGPoint(x: centre.x + grid, y: centre.y - grid)
                )
            }
        }
    }

    /// An Apple device's thin bezel turns the same way.
    func testAnAppleDevicesThinBezelTurnResizesTheDrawableOnceAboutAFixedCentre() async throws {
        let upright = CGSize(width: Self.phone.width, height: Self.phone.height)
        let composition = thinBezelComposition(upright: upright, stage: Self.stage)
        let box = CGSize(width: Self.stage.width - 16, height: Self.stage.height - 16)
        let centre = CGPoint(x: Self.stage.width / 2, y: Self.stage.height / 2)
        for scale in Self.scales {
            let clock = TurnClock()
            let hosted = try host(chrome: .thinBezel, stage: Self.stage, scale: scale, turnClock: clock)
            defer { hosted.window.close() }
            try await assertTurns(hosted, clock: clock, natural: Self.phone, "thin bezel at \(scale)x") { angle in
                let grid = PoseFit.pixelGridOffset(angle: angle, size: Self.stage, pixelScale: scale)
                return (
                    longSide: upright.height * PoseFit.scale(angle: angle, nativeSize: composition, box: box),
                    centre: CGPoint(x: centre.x + grid, y: centre.y - grid)
                )
            }
        }
    }

    /// The framed fold above its control strip, as the Pixel 9 Pro
    /// Fold runs on the main stage: the skin composition (native hero
    /// layout, fitted into the stage less the strip, at the top) turns about
    /// the fitted area's centre. Its screen is not centred in the artwork, so
    /// the video's own centre swings with the turn: the display rect's
    /// offset from the layout's centre, scaled and turned by the pose.
    func testAFramedFoldTurnAboveTheStripResizesTheDrawableOnce() async throws {
        let skin = try sdkSkin(named: "pixel_9_pro_fold")
        let fitted = CGSize(
            width: Self.stage.width,
            height: Self.stage.height - FoldControlStrip.estimatedHeight - FoldControlStrip.stageBottomPadding
        )
        let box = CGSize(width: fitted.width - 16, height: fitted.height - 16)
        // In window coordinates (y up): the fitted area is the top of the stage.
        let centre = CGPoint(x: fitted.width / 2, y: Self.stage.height - fitted.height / 2)
        for scale in Self.scales {
            for natural in [(width: 2076, height: 2152), (width: 1080, height: 2424)] {
                let display = try XCTUnwrap(
                    skin.variant(matching: CGSize(width: natural.width, height: natural.height))?.layout?.preferred,
                    "fold \(natural)"
                )
                // Layout units: the video aspect-fitted into the display rect,
                // and the display rect's centre from the layout's (y down).
                let upright = CGSize(width: natural.width, height: natural.height)
                let fill = min(display.displaySize.width / upright.width, display.displaySize.height / upright.height)
                let longSide = max(upright.width, upright.height) * fill
                let offset = CGPoint(
                    x: display.screenRect.midX - display.layoutSize.width / 2,
                    y: display.screenRect.midY - display.layoutSize.height / 2
                )
                let clock = TurnClock()
                let hosted = try host(
                    chrome: .skin(skin),
                    stage: Self.stage,
                    scale: scale,
                    turnClock: clock,
                    foldControls: true
                )
                defer { hosted.window.close() }
                try await assertTurns(hosted, clock: clock, natural: natural, "fold \(natural) at \(scale)x") { angle in
                    let scaleAtAngle = PoseFit.scale(angle: angle, nativeSize: display.layoutSize, box: box)
                    let grid = PoseFit.pixelGridOffset(angle: angle, size: fitted, pixelScale: scale)
                    // SwiftUI's rotation turns y-down coordinates clockwise
                    // for a positive angle; the window's y grows up.
                    let radians = angle * .pi / 180
                    let turned = CGPoint(
                        x: offset.x * cos(radians) - offset.y * sin(radians),
                        y: offset.x * sin(radians) + offset.y * cos(radians)
                    )
                    return (
                        longSide: longSide * scaleAtAngle,
                        centre: CGPoint(
                            x: centre.x + turned.x * scaleAtAngle + grid,
                            y: centre.y - turned.y * scaleAtAngle - grid
                        )
                    )
                }
            }
        }
    }

    /// The frames of a turn that are checked, by the turn's progress: 0 (the
    /// turn has started, the angle has not moved), then every tenth of the
    /// way from 0.05 to 0.95. Never exactly halfway: AppKit asserts on a
    /// view turned by exactly 45° (a NaN frame in `_nsis_frameInEngine`),
    /// an angle a timed animation does not land on.
    private static let turnProgress: [Double] = [0] + (0..<10).map { (Double($0) + 0.5) / 10 }

    /// A rotation to landscape and back, frame by frame: the drawable takes
    /// the rest pose's size once, as the turn starts, and keeps it; and every
    /// frame of the turn shows the video where and as large as the
    /// natural-pose layout did (`expected` at the frame's angle: its size is
    /// `PoseFit.scale` at that angle, which dips toward 45° and does not
    /// depend on the rest pose). With Reduce Motion on the animator snaps,
    /// so there is no turn to check.
    ///
    /// The host runs the turn on `clock` (`SteppedTurn`), not on the wall
    /// clock: the test moves it to each step, waits until the stage shows
    /// that step's angle, and checks that frame. A busy machine can delay a
    /// frame but can no longer skip one, or end the turn before it is seen.
    ///
    /// The Metal view draws the frame the stage rests on before the turn
    /// starts: a view's first drawn frame settles the stream geometry at
    /// once (`SettledGeometry`), so a first draw that came late, of a frame
    /// uploaded before the turn's, would settle the old pose and turn the
    /// stage back in the middle of the check.
    ///
    /// Within a backing pixel at 2x, the bound this check always had (half a
    /// point): with the turn stepped, every checked frame is the same on
    /// every run, and each is within it. At 1x the bound is a pixel scaled
    /// by the wrapper: SwiftUI rounds each edge of the laid-out video to the
    /// pixel grid (half a point at 1x), so its size can be a pixel off and
    /// its centre half of one, and the wrapper's scale in that frame scales
    /// the error with the video. The scale is below 1 while turning toward
    /// the pose the layout rests in less room, and up to 1.51 in this stage
    /// as a turn back to portrait starts (the portrait layout enlarged to
    /// landscape's size): a pixel of rounding at 1x shows as 1.5 pt there,
    /// and a flat pixel fails the vector body's turn by 1.47 pt at its
    /// first frame.
    private func assertTurns(
        _ hosted: Hosted,
        clock: TurnClock,
        natural: (width: Int, height: Int),
        _ context: String,
        expected: (_ angle: Double) -> (longSide: CGFloat, centre: CGPoint),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try XCTSkipIf(MotionMetrics.reduceMotion, "Reduce Motion is on: the pose snaps instead of turning")
        let drawsFrames = await pipelineLoads()
        await pose(hosted, rotation: 0, natural: natural)
        await waitUntil("\(context): at rest", file: file, line: line) { !hosted.model.workspace.mirror.stagePose.isAnimating }
        let view = try XCTUnwrap(mirrorView(in: hosted.host), context, file: file, line: line)
        if drawsFrames {
            await waitUntil("\(context): the rest frame was drawn", file: file, line: line) {
                view.presentedLayout?.posedWidth == natural.width && view.presentedLayout?.rotation == 0
            }
        }
        let pixel = 1 / hosted.window.backingScaleFactor

        for rotation in [1, 0] {
            let start = hosted.model.workspace.mirror.stagePose.restAngle
            var drawables = [view.drawableSize]
            clock.progress = 0
            stream(hosted, rotation: rotation, natural: natural)
            let end = hosted.model.workspace.mirror.stagePose.restAngle
            XCTAssertTrue(hosted.model.workspace.mirror.stagePose.isAnimating, "\(context), rotation \(rotation): the turn started", file: file, line: line)
            // The layout takes the new rest pose as the turn starts, before
            // the angle moves.
            await waitUntil("\(context), rotation \(rotation): laid out for the new rest pose", file: file, line: line) {
                view.drawableSize != drawables[0]
            }

            for progress in Self.turnProgress {
                clock.progress = progress
                let target = start + (end - start) * progress
                await waitUntil("\(context), rotation \(rotation): the turn reached \(progress)", file: file, line: line) {
                    abs(remainder(poseAngle(of: view) - target, 360)) < 1e-3
                }
                if drawables.last != view.drawableSize { drawables.append(view.drawableSize) }
                let size = onScreenSize(of: view)
                let rect = onScreenRect(of: view)
                let angle = poseAngle(of: view)
                let want = expected(angle)
                // At 1x the wrapper's scale in this frame carries the
                // layout's rounding with it; 2x keeps its flat pixel.
                let wrapperScale = max(size.width, size.height) / max(view.bounds.width, view.bounds.height)
                let tolerance = hosted.window.backingScaleFactor >= 2 ? pixel : pixel * max(wrapperScale, 1)
                let at = "\(context), rotation \(rotation) at \(angle)° (progress \(progress))"
                XCTAssertEqual(max(size.width, size.height), want.longSide, accuracy: tolerance, "\(at): long side", file: file, line: line)
                XCTAssertEqual(rect.midX, want.centre.x, accuracy: tolerance, "\(at): centre x", file: file, line: line)
                XCTAssertEqual(rect.midY, want.centre.y, accuracy: tolerance, "\(at): centre y", file: file, line: line)
            }

            clock.progress = 1
            await waitUntil("\(context), rotation \(rotation): the turn ended", file: file, line: line) {
                !hosted.model.workspace.mirror.stagePose.isAnimating
            }
            if drawables.last != view.drawableSize { drawables.append(view.drawableSize) }
            XCTAssertEqual(drawables.count, 2, "\(context): one resize, not one per frame: \(drawables)", file: file, line: line)
            XCTAssertEqual(
                remainder(poseAngle(of: view) - hosted.model.workspace.mirror.stagePose.presentedAngle, 360),
                0,
                accuracy: 1e-6,
                "\(context): the measured angle is the pose's",
                file: file,
                line: line
            )
            try assertOneToOne(hosted, "\(context), after turning to rotation \(rotation)", file: file, line: line)
        }
    }

    // MARK: - Hosting

    private struct Hosted {
        let stage: CGSize
        let window: NSWindow
        let host: NSView
        let model: AppModel
        let session: FakeMirrorSession
    }

    /// The stage content in an offscreen window of the stage's size at
    /// `scale` (`ScaledTestWindow`), framed unless `framed` is off (the flat
    /// mirror), with the fold control strip under the device when
    /// `foldControls` is on (the main stage showing a foldable emulator; the
    /// strip keeps its estimated height). Without `turnClock` a pose change
    /// lands at once (the test is about the rest pose, not the turn); with
    /// it, the turn runs on that clock.
    private func host(
        chrome: DeviceChrome,
        stage: CGSize,
        scale: CGFloat,
        turnClock: TurnClock? = nil,
        framed: Bool = true,
        foldControls: Bool = false
    ) throws -> Hosted {
        let model = AppModel.testing()
        model.workspace.window.showDeviceFrame = framed
        let session = FakeMirrorSession()
        let content = MirrorStageContent(
            session: session,
            chrome: chrome,
            available: stage,
            showsFoldControls: foldControls
        )
            .environment(model).environment(model.workspace)
            .transaction { transaction in
                if let turnClock {
                    if transaction.animation != nil {
                        transaction.animation = Animation(SteppedTurn(clock: turnClock))
                    }
                } else {
                    transaction.animation = nil
                }
            }
        let host = NSHostingView(rootView: content)
        let window = ScaledTestWindow.hosting(host, size: stage, scale: scale)
        return Hosted(stage: stage, window: window, host: host, model: model, session: session)
    }

    /// Resets the pose animator, then streams and settles a frame turned
    /// `rotation` quarter turns, which puts the stage in that pose (at once
    /// on a host without a turn clock).
    @discardableResult
    private func pose(_ hosted: Hosted, rotation: Int, natural: (width: Int, height: Int)) async -> (width: Int, height: Int) {
        hosted.model.workspace.mirror.stagePose.reset()
        let posed = stream(hosted, rotation: rotation, natural: natural)
        // Best effort: the sleep fails only on cancellation.
        try? await Task.sleep(for: .milliseconds(50))
        hosted.host.layoutSubtreeIfNeeded()
        return posed
    }

    /// Streams a frame of the natural display turned `rotation` quarter
    /// turns and settles on it the way `MirrorMetalView.draw` does once a
    /// streamed geometry settles: the view state first, then the pose
    /// animator (which turns the stage when the rotation is new).
    @discardableResult
    private func stream(_ hosted: Hosted, rotation: Int, natural: (width: Int, height: Int)) -> (width: Int, height: Int) {
        let posed = rotation % 2 == 1 ? (width: natural.height, height: natural.width) : natural
        hosted.session.frames.put(Frame(
            data: Data(count: posed.width * posed.height * 4),
            width: posed.width,
            height: posed.height,
            seq: 0,
            rotation: rotation
        ))
        hosted.model.workspace.mirror.mirrorViewState.devicePixelSize = CGSize(width: posed.width, height: posed.height)
        hosted.model.workspace.mirror.mirrorViewState.deviceRotation = rotation
        hosted.model.workspace.mirror.stagePose.settle(rotation: rotation)
        return posed
    }

    /// Loads the shared Metal pipeline, skipping the test without one.
    private func loadPipeline() async throws {
        guard await pipelineLoads() else { throw XCTSkip("no Metal pipeline") }
    }

    /// Loads the shared Metal pipeline; whether the mirror views can draw.
    private func pipelineLoads() async -> Bool {
        MirrorRenderPipeline.shared.load()
        await waitUntil { MirrorRenderPipeline.shared.resources != nil || MirrorRenderPipeline.shared.failure != nil }
        return MirrorRenderPipeline.shared.resources != nil
    }

    private func sdkSkin(named name: String) throws -> ResolvedSkin {
        guard let skins = SkinLocator.skinsDirectory() else {
            throw XCTSkip("no Android SDK skins directory")
        }
        let entry = try XCTUnwrap(
            SkinResolver.catalog(skinsDirectory: skins).first(where: { $0.name == name }),
            "missing skin \(name)"
        )
        return ResolvedSkin(name: entry.name, directory: entry.directory, source: .skinName, variants: entry.variants)
    }

    /// `MirrorStageContent.screenContent`'s composition (an Apple device's
    /// thin bezel): the upright screen plus the 8 pt bezel, expressed at the
    /// natural pose's fit.
    private func thinBezelComposition(upright: CGSize, stage: CGSize) -> CGSize {
        let bezel: CGFloat = 8
        let natural = min(
            (stage.width - bezel * 2 - 16) / upright.width,
            (stage.height - bezel * 2 - 16) / upright.height,
            1
        )
        return CGSize(width: upright.width + bezel * 2 / natural, height: upright.height + bezel * 2 / natural)
    }

    // MARK: - Measuring

    /// At rest the video's bounds are its size on screen (the wrapper only
    /// turns it), its drawable is those bounds at the backing scale, and it
    /// sits on whole backing pixels: one drawable pixel per backing pixel,
    /// not resampled.
    private func assertOneToOne(
        _ hosted: Hosted,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let view = try XCTUnwrap(mirrorView(in: hosted.host), context, file: file, line: line)
        view.layoutSubtreeIfNeeded()
        let backing = hosted.window.backingScaleFactor
        let size = onScreenSize(of: view)
        XCTAssertGreaterThan(view.bounds.width, 10, context, file: file, line: line)
        XCTAssertEqual(size.width / view.bounds.width, 1, accuracy: 1e-6, "\(context): on-screen / laid-out width", file: file, line: line)
        XCTAssertEqual(size.height / view.bounds.height, 1, accuracy: 1e-6, "\(context): on-screen / laid-out height", file: file, line: line)
        XCTAssertEqual(view.drawableSize.width, size.width * backing, accuracy: 1, "\(context): drawable width", file: file, line: line)
        XCTAssertEqual(view.drawableSize.height, size.height * backing, accuracy: 1, "\(context): drawable height", file: file, line: line)
        XCTAssertEqual(view.layer?.contentsScale, backing, "\(context): layer contents scale", file: file, line: line)
        // Configuration, not a capture: resize gravity asks Core Animation
        // to scale a stale frame to the bounds, where the next one lands (see
        // `MirrorMetalView.allowsUpscaling`). That scales it without
        // distortion only because the surface is laid out at the video's
        // own (upright) aspect, which is checked here to within the pixel
        // rounding of its two sides: SwiftUI puts each edge on the pixel
        // grid, so each side can be up to a backing pixel off, the height's
        // error counting at the aspect's ratio.
        XCTAssertEqual(view.layer?.contentsGravity, .resize, "\(context): configured contents gravity", file: file, line: line)
        if let frame = hosted.session.frames.current {
            let upright = frame.rotation % 2 == 1
                ? CGSize(width: frame.height, height: frame.width)
                : CGSize(width: frame.width, height: frame.height)
            let aspect = upright.width / upright.height
            XCTAssertEqual(
                view.bounds.width,
                view.bounds.height * aspect,
                accuracy: (1 + aspect) / backing,
                "\(context): laid out at the video's aspect",
                file: file,
                line: line
            )
        }
        let origin = onScreenRect(of: view).origin
        for (axis, value) in [("x", origin.x * backing), ("y", origin.y * backing)] {
            XCTAssertEqual(value, value.rounded(), accuracy: 1e-3, "\(context): \(axis) on the pixel grid", file: file, line: line)
        }
    }

    private func mirrorView(in view: NSView) -> MirrorMetalView? {
        if let mirror = view as? MirrorMetalView { return mirror }
        for subview in view.subviews {
            if let mirror = mirrorView(in: subview) { return mirror }
        }
        return nil
    }

    /// The view's own width and height as drawn in the window (the lengths
    /// of its converted edges, so any rotation and scale in between count).
    private func onScreenSize(of view: NSView) -> CGSize {
        let origin = view.convert(NSPoint.zero, to: nil)
        let alongWidth = view.convert(NSPoint(x: view.bounds.width, y: 0), to: nil)
        let alongHeight = view.convert(NSPoint(x: 0, y: view.bounds.height), to: nil)
        return CGSize(
            width: hypot(alongWidth.x - origin.x, alongWidth.y - origin.y),
            height: hypot(alongHeight.x - origin.x, alongHeight.y - origin.y)
        )
    }

    /// The window-space bounding box of the view as drawn.
    private func onScreenRect(of view: NSView) -> CGRect {
        view.convert(view.bounds, to: nil)
    }

    /// The pose angle AppKit shows the video at: SwiftUI turns the
    /// representable's host view by the wrapper's angle.
    private func poseAngle(of view: NSView) -> Double {
        var ancestor = view.superview
        while let current = ancestor {
            if current.frameCenterRotation != 0 { return Double(current.frameCenterRotation) }
            ancestor = current.superview
        }
        return 0
    }
}

// MARK: - A turn the test steps

/// How far the stage's turn has come, 0...1, as the test sets it.
private final class TurnClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0

    var progress: Double {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// An animation that ignores time: SwiftUI asks it for the value on every
/// frame it draws while it runs, and it answers the test's `clock` progress
/// of the change, finishing once the progress reaches 1. The host swaps it
/// in for the pose animator's own (`MotionMetrics.hero`), so the turn's
/// frames are the test's to pick and cannot be skipped by a stalled main
/// thread; the animator's completion still ends the turn.
private struct SteppedTurn: CustomAnimation {
    let clock: TurnClock

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        let progress = clock.progress
        guard progress < 1 else { return nil }
        return value.scaled(by: progress)
    }

    static func == (lhs: SteppedTurn, rhs: SteppedTurn) -> Bool {
        lhs.clock === rhs.clock
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(clock))
    }
}
