import XCTest
import SwiftUI
@testable import DeviceHubProKit
@testable import DeviceHubProApp

/// The live side buttons on the framed stage (device frame Tier 2, W4,
/// HW-01), hosted with the real views (`MirrorStageContent` and
/// `FramedMirrorView` on the installed SDK's `pixel_10_pro` and
/// `pixel_9_pro_fold` skins, skipped without the SDK) in offscreen windows
/// at 1x and 2x (`ScaledTestWindow`), with a `FakeMirrorSession` that
/// records the key events it is sent:
///
/// - each button's hotspot is an AppKit view found by the window's
///   hit-testing where the plan puts the button, in every rest pose
///   (`PoseHitTestTests`' method);
/// - a click is one key-down and one key-up, the up sent wherever the
///   pointer is when the mouse comes up;
/// - held keys are released when the device starts turning, the window
///   resigns key, or the buttons go away;
/// - there are no hotspots in the compact window, on the fold's flat cover,
///   on a vector body, on a non-Pixel skin or for a session without keys;
/// - the hotspots are accessible buttons, and a hotspot moved from under a
///   still pointer lets its button go;
/// - the buttons' pad does not move the device, and a click on the screen
///   still reaches the video;
/// - the stage switches to the frame split only as a button starts to move
///   and hands back to the artwork whole with a cross-fade, never a jump,
///   and Reduce Motion never moves a sprite (hover shows nothing, a press
///   only tints).
///
/// The skins are read in place and never copied; the stream frames are
/// generated input (blank buffers of the panels' sizes), not device output.
@MainActor
final class HardwareButtonsStageTests: XCTestCase {
    private static let stage = CGSize(width: 1300, height: 866)
    private static let scales: [CGFloat] = [1, 2]
    private static let tenPro = (width: 1280, height: 2856)
    private static let foldOpen = (width: 2076, height: 2152)
    private static let foldCover = (width: 1080, height: 2424)

    // MARK: - Hit-testing

    /// In every rest pose, at 1x and 2x: each hotspot's view covers the
    /// plan's button, widened 6 pt outward and 4 pt inward (within a
    /// backing pixel of where the pose puts it), and the window's
    /// hit-testing finds it at its centre, converting the click to its own
    /// centre; 2 pt past its top and bottom edges it finds another view.
    /// With the hotspots mounted, a click on the device's screen still
    /// reaches the video: at its centre, and 1 pt inside its edge on each
    /// button's row.
    func testHotspotsAreHitWhereTheButtonsAreInEveryRestPose() async throws {
        let cases: [(skin: String, natural: (width: Int, height: Int))] = [
            ("pixel_10_pro", Self.tenPro),
            ("pixel_9_pro_fold", Self.foldOpen),
        ]
        for (name, natural) in cases {
            let skin = try sdkSkin(named: name)
            for scale in Self.scales {
                let hosted = try host(chrome: .skin(skin), scale: scale)
                defer { hosted.window.close() }
                for rotation in 0..<4 {
                    let context = "\(name) at \(scale)x, rotation \(rotation)"
                    await pose(hosted, rotation: rotation, natural: natural)
                    let views = try await hotspots(in: hosted, context)
                    XCTAssertEqual(Set(views.keys), Set(HardwareKey.allCases), context)
                    let expected = try expectedHotspots(skin: skin, natural: natural, rotation: rotation, scale: scale)
                    let pixel = 1 / scale
                    for key in HardwareKey.allCases {
                        let at = "\(context), \(key)"
                        let view = try XCTUnwrap(views[key], at)
                        let want = try XCTUnwrap(expected.rects[key], at)
                        // Where the pose draws the hotspot: the bounding box
                        // of its corners, mapped into the window.
                        let corners = [
                            CGPoint(x: want.minX, y: want.minY), CGPoint(x: want.maxX, y: want.minY),
                            CGPoint(x: want.minX, y: want.maxY), CGPoint(x: want.maxX, y: want.maxY),
                        ].map { windowPoint($0, expected: expected, rotation: rotation, scale: scale) }
                        let drawn = view.convert(view.bounds, to: nil)
                        XCTAssertEqual(drawn.minX, corners.map(\.x).min()!, accuracy: pixel, "\(at): left")
                        XCTAssertEqual(drawn.maxX, corners.map(\.x).max()!, accuracy: pixel, "\(at): right")
                        XCTAssertEqual(drawn.minY, corners.map(\.y).min()!, accuracy: pixel, "\(at): bottom")
                        XCTAssertEqual(drawn.maxY, corners.map(\.y).max()!, accuracy: pixel, "\(at): top")

                        let centre = windowPoint(CGPoint(x: want.midX, y: want.midY), expected: expected, rotation: rotation, scale: scale)
                        let hit = hosted.content.hitTest(centre)
                        XCTAssertTrue(hit === view, "\(at): its centre \(centre) hit \(describe(hit))")
                        let local = view.convert(centre, from: nil)
                        XCTAssertEqual(local.x, view.bounds.midX, accuracy: pixel, "\(at): converted x")
                        XCTAssertEqual(local.y, view.bounds.midY, accuracy: pixel, "\(at): converted y")
                        for (side, miss) in [
                            ("top", CGPoint(x: want.midX, y: want.minY - 2)),
                            ("bottom", CGPoint(x: want.midX, y: want.maxY + 2)),
                        ] {
                            let point = windowPoint(miss, expected: expected, rotation: rotation, scale: scale)
                            XCTAssertFalse(hosted.content.hitTest(point) === view, "\(at): 2 pt past its \(side) edge still hit it")
                        }
                    }

                    // The screen is the video's. The mirror view is laid
                    // out upright inside the pose, so its own right edge is
                    // the device's, where the buttons are.
                    let mirror = try XCTUnwrap(mirrorView(in: hosted.host), context)
                    let screen = mirror.convert(CGPoint(x: mirror.bounds.midX, y: mirror.bounds.midY), to: nil)
                    let atCentre = hosted.content.hitTest(screen)
                    XCTAssertTrue(atCentre === mirror, "\(context): the screen's centre \(screen) hit \(describe(atCentre))")
                    for key in HardwareKey.allCases {
                        let view = try XCTUnwrap(views[key], context)
                        let centre = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                        let row = min(max(mirror.convert(centre, from: nil).y, mirror.bounds.minY + 1), mirror.bounds.maxY - 1)
                        let edge = mirror.convert(CGPoint(x: mirror.bounds.maxX - 1, y: row), to: nil)
                        let hit = hosted.content.hitTest(edge)
                        XCTAssertTrue(hit === mirror, "\(context), \(key)'s row: 1 pt inside the screen's edge, \(edge), hit \(describe(hit))")
                    }
                }
            }
        }
    }

    // MARK: - Clicks

    /// A click as the window routes it: the mouse-down goes to the view the
    /// window's hit-testing finds under the pointer (the hotspot, in a
    /// landscape pose too), and the drag and the mouse-up go to that same
    /// view wherever the pointer is by then (AppKit's mouse-down view; an
    /// offscreen test window does not dispatch synthetic events itself).
    /// The key goes down once and up once, the up with the pointer over
    /// the device's screen and then the far corner of the stage.
    func testAClickIsOneKeyDownAndOneKeyUpWhereverTheMouseComesUp() async throws {
        let skin = try sdkSkin(named: "pixel_10_pro")
        for scale in Self.scales {
            let hosted = try host(chrome: .skin(skin), scale: scale)
            defer { hosted.window.close() }
            for rotation in [0, 1] {
                await pose(hosted, rotation: rotation, natural: Self.tenPro)
                let views = try await hotspots(in: hosted, "\(scale)x, rotation \(rotation)")
                for key in [HardwareKey.power, .volumeDown] {
                    let context = "\(scale)x, rotation \(rotation), \(key)"
                    let view = try XCTUnwrap(views[key], context)
                    let centre = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                    let target = try XCTUnwrap(hosted.content.hitTest(centre), context)
                    XCTAssertTrue(target === view, "\(context): the window finds the hotspot under the pointer")
                    let before = hosted.session.hardwareKeyEvents.count
                    target.mouseDown(with: mouse(.leftMouseDown, at: centre, in: hosted.window))
                    XCTAssertEqual(
                        Array(hosted.session.hardwareKeyEvents.dropFirst(before)),
                        [HardwareKeyEvent(key: key, isDown: true)],
                        "\(context): the mouse-down"
                    )
                    let screen = CGPoint(x: Self.stage.width / 2, y: Self.stage.height / 2)
                    XCTAssertFalse(hosted.content.hitTest(screen) === view, "\(context): the pointer left the button")
                    target.mouseDragged(with: mouse(.leftMouseDragged, at: screen, in: hosted.window))
                    target.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 2, y: 2), in: hosted.window))
                    XCTAssertEqual(
                        Array(hosted.session.hardwareKeyEvents.dropFirst(before)),
                        [HardwareKeyEvent(key: key, isDown: true), HardwareKeyEvent(key: key, isDown: false)],
                        "\(context): the mouse-up outside the button"
                    )
                }
            }
        }
    }

    /// The hotspot itself: a mouse-up with the pointer anywhere releases
    /// the key its mouse-down pressed, and the stage shows the key held
    /// in between.
    func testTheHotspotReleasesOnAMouseUpAnywhere() async throws {
        let hosted = try host(chrome: .skin(sdkSkin(named: "pixel_10_pro")), scale: 2)
        defer { hosted.window.close() }
        await pose(hosted, rotation: 1, natural: Self.tenPro)
        let power = try await hotspot(.power, in: hosted, "2x")
        power.mouseDown(with: mouse(.leftMouseDown, at: .zero, in: hosted.window))
        XCTAssertTrue(power.isTracking)
        power.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: -500, y: -500), in: hosted.window))
        XCTAssertFalse(power.isTracking)
        XCTAssertEqual(hosted.session.hardwareKeyEvents, [
            HardwareKeyEvent(key: .power, isDown: true),
            HardwareKeyEvent(key: .power, isDown: false),
        ])
    }

    // MARK: - Nothing left held

    /// The device starting to turn releases a held key at once: hit-testing
    /// is off while it turns, and the button is no longer under the pointer.
    func testTurningTheDeviceReleasesHeldKeys() async throws {
        try XCTSkipIf(MotionMetrics.reduceMotion, "Reduce Motion is on: the pose snaps instead of turning")
        let clock = HeldTurn.Clock()
        let hosted = try host(chrome: .skin(sdkSkin(named: "pixel_10_pro")), scale: 2, heldTurn: clock)
        defer { hosted.window.close() }
        await pose(hosted, rotation: 0, natural: Self.tenPro)
        let volumeUp = try await hotspot(.volumeUp, in: hosted, "2x")
        volumeUp.mouseDown(with: mouse(.leftMouseDown, at: .zero, in: hosted.window))
        XCTAssertEqual(hosted.session.hardwareKeyEvents, [HardwareKeyEvent(key: .volumeUp, isDown: true)])

        hosted.model.workspace.mirror.stagePose.beginRotation(.left)
        XCTAssertTrue(hosted.model.workspace.mirror.stagePose.isAnimating)
        await waitUntil(timeout: 5, "the held key was released as the turn started") {
            hosted.session.hardwareKeyEvents.count == 2
        }
        XCTAssertEqual(hosted.session.hardwareKeyEvents, [
            HardwareKeyEvent(key: .volumeUp, isDown: true),
            HardwareKeyEvent(key: .volumeUp, isDown: false),
        ])
        XCTAssertTrue(hosted.model.workspace.mirror.stagePose.isAnimating, "released while turning, not after")
        // The mouse-up that comes later sends nothing more.
        volumeUp.mouseUp(with: mouse(.leftMouseUp, at: .zero, in: hosted.window))
        clock.progress = 1
        await waitUntil("the turn ended") { !hosted.model.workspace.mirror.stagePose.isAnimating }
        XCTAssertEqual(hosted.session.hardwareKeyEvents.count, 2)
    }

    /// The window resigning key (another window or app takes the keyboard,
    /// and a mouse-up may never come) releases a held key, and the next
    /// click presses anew.
    func testTheWindowResigningKeyReleasesHeldKeys() async throws {
        let hosted = try host(chrome: .skin(sdkSkin(named: "pixel_10_pro")), scale: 1)
        defer { hosted.window.close() }
        await pose(hosted, rotation: 0, natural: Self.tenPro)
        let power = try await hotspot(.power, in: hosted, "1x")
        power.mouseDown(with: mouse(.leftMouseDown, at: .zero, in: hosted.window))

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: hosted.window)
        await waitUntil("released on resign key") { hosted.session.hardwareKeyEvents.count == 2 }
        XCTAssertEqual(hosted.session.hardwareKeyEvents, [
            HardwareKeyEvent(key: .power, isDown: true),
            HardwareKeyEvent(key: .power, isDown: false),
        ])
        XCTAssertFalse(power.isTracking)

        // Another window resigning key is not this stage's business.
        power.mouseDown(with: mouse(.leftMouseDown, at: .zero, in: hosted.window))
        let other = NSWindow()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(hosted.session.hardwareKeyEvents.count, 3, "the new press is still held")
        power.mouseUp(with: mouse(.leftMouseUp, at: .zero, in: hosted.window))
        XCTAssertEqual(hosted.session.hardwareKeyEvents.last, HardwareKeyEvent(key: .power, isDown: false))
        XCTAssertEqual(hosted.session.hardwareKeyEvents.count, 4)
    }

    /// The buttons going away releases a held key: Show Device Frame off
    /// (the framed stage disappears) and a foldable switching screens (the
    /// variant's view is swapped by its id, and the cover has no buttons).
    func testHeldKeysAreReleasedWhenTheButtonsGo() async throws {
        do {
            let hosted = try host(chrome: .skin(sdkSkin(named: "pixel_10_pro")), scale: 2)
            defer { hosted.window.close() }
            await pose(hosted, rotation: 0, natural: Self.tenPro)
            let power = try await hotspot(.power, in: hosted, "frame off")
            power.mouseDown(with: mouse(.leftMouseDown, at: .zero, in: hosted.window))
            hosted.model.workspace.window.showDeviceFrame = false
            await waitUntil("released when the frame went") { hosted.session.hardwareKeyEvents.count == 2 }
            XCTAssertEqual(hosted.session.hardwareKeyEvents, [
                HardwareKeyEvent(key: .power, isDown: true),
                HardwareKeyEvent(key: .power, isDown: false),
            ])
            XCTAssertTrue(hotspotViews(in: hosted.host).isEmpty, "no hotspots on the flat mirror")
        }
        do {
            let hosted = try host(chrome: .skin(sdkSkin(named: "pixel_9_pro_fold")), scale: 2)
            defer { hosted.window.close() }
            await pose(hosted, rotation: 0, natural: Self.foldOpen)
            let volumeDown = try await hotspot(.volumeDown, in: hosted, "fold open")
            volumeDown.mouseDown(with: mouse(.leftMouseDown, at: .zero, in: hosted.window))
            await pose(hosted, rotation: 0, natural: Self.foldCover)
            await waitUntil("released when the fold closed") { hosted.session.hardwareKeyEvents.count == 2 }
            XCTAssertEqual(hosted.session.hardwareKeyEvents, [
                HardwareKeyEvent(key: .volumeDown, isDown: true),
                HardwareKeyEvent(key: .volumeDown, isDown: false),
            ])
            XCTAssertTrue(hotspotViews(in: hosted.host).isEmpty, "the cover's flat edge has no buttons")
        }
    }

    // MARK: - Where there are none

    /// The compact window (the flag unset), the fold's flat cover, a
    /// session without hardware keys, a vector body and a non-Pixel skin
    /// whose frame does paint buttons (`nexus_5x`) show no hotspots; the
    /// first three with the skin's own artwork, not the split one.
    func testThereAreNoHotspotsWhereTheStageOffersNoButtons() async throws {
        struct Case {
            let name: String
            let chrome: DeviceChrome
            let natural: (width: Int, height: Int)
            var shows = true
            var keys = true
        }
        let tenPro = try sdkSkin(named: "pixel_10_pro")
        let fold = try sdkSkin(named: "pixel_9_pro_fold")
        var cases = [
            Case(name: "compact window", chrome: .skin(tenPro), natural: Self.tenPro, shows: false),
            Case(name: "fold cover", chrome: .skin(fold), natural: Self.foldCover),
            Case(name: "no hardware keys", chrome: .skin(tenPro), natural: Self.tenPro, keys: false),
            Case(name: "vector body", chrome: .vector, natural: Self.tenPro),
        ]
        if let nexus = try? sdkSkin(named: "nexus_5x") {
            cases.append(Case(name: "nexus_5x", chrome: .skin(nexus), natural: (width: 1080, height: 1920)))
        }
        for testCase in cases {
            let (name, chrome, natural) = (testCase.name, testCase.chrome, testCase.natural)
            let hosted = try host(chrome: chrome, scale: 2, showsButtons: testCase.shows, supportsHardwareKeys: testCase.keys)
            defer { hosted.window.close() }
            await pose(hosted, rotation: 0, natural: natural)
            // Long enough for a split the stage asked for to have landed.
            try await Task.sleep(for: .milliseconds(400))
            hosted.host.layoutSubtreeIfNeeded()
            XCTAssertTrue(hotspotViews(in: hosted.host).isEmpty, "\(name): no hotspots")
        }
    }

    /// With the flag unset the stage lays the device out exactly as without
    /// buttons: the pad and the button split are the main stage's only.
    func testTheButtonsPadDoesNotMoveTheDevice() async throws {
        let skin = try sdkSkin(named: "pixel_10_pro")
        for scale in Self.scales {
            let plain = try host(chrome: .skin(skin), scale: scale, showsButtons: false)
            defer { plain.window.close() }
            let buttons = try host(chrome: .skin(skin), scale: scale)
            defer { buttons.window.close() }
            for rotation in 0..<4 {
                let context = "\(scale)x, rotation \(rotation)"
                await pose(plain, rotation: rotation, natural: Self.tenPro)
                await pose(buttons, rotation: rotation, natural: Self.tenPro)
                _ = try await hotspots(in: buttons, context)
                let without = try XCTUnwrap(mirrorView(in: plain.host), context)
                let with = try XCTUnwrap(mirrorView(in: buttons.host), context)
                without.layoutSubtreeIfNeeded()
                with.layoutSubtreeIfNeeded()
                let a = without.convert(without.bounds, to: nil)
                let b = with.convert(with.bounds, to: nil)
                XCTAssertEqual(b.minX, a.minX, accuracy: 0.01, "\(context): x")
                XCTAssertEqual(b.minY, a.minY, accuracy: 0.01, "\(context): y")
                XCTAssertEqual(b.width, a.width, accuracy: 0.01, "\(context): width")
                XCTAssertEqual(b.height, a.height, accuracy: 0.01, "\(context): height")
                XCTAssertEqual(with.layer?.cornerRadius ?? -1, without.layer?.cornerRadius ?? -2, accuracy: 0.01, "\(context): corner")
            }
        }
    }

    // MARK: - Accessibility

    /// Each hotspot is a button named for its key with the tooltip as its
    /// help; pressing it holds the key for 100 ms, and Power alone has a
    /// "Long-press Power" action that holds it for a second.
    func testTheHotspotsAreAccessibleButtons() async throws {
        let hosted = try host(chrome: .skin(sdkSkin(named: "pixel_10_pro")), scale: 2)
        defer { hosted.window.close() }
        await pose(hosted, rotation: 0, natural: Self.tenPro)
        let views = try await hotspots(in: hosted, "2x")
        let labels: [HardwareKey: String] = [
            .power: "Power button",
            .volumeUp: "Volume up button",
            .volumeDown: "Volume down button",
        ]
        for key in HardwareKey.allCases {
            let view = try XCTUnwrap(views[key])
            XCTAssertTrue(view.isAccessibilityElement(), "\(key)")
            XCTAssertEqual(view.accessibilityRole(), .button, "\(key)")
            XCTAssertEqual(view.accessibilityLabel(), labels[key], "\(key)")
            XCTAssertEqual(view.toolTip, HardwareButtonHotspotView.toolTip(for: key), "\(key)")
            XCTAssertEqual(view.accessibilityHelp(), view.toolTip, "\(key)")
            XCTAssertFalse(view.acceptsFirstResponder, "\(key): the keyboard stays with the video")
            let actions = view.accessibilityCustomActions() ?? []
            XCTAssertEqual(actions.map(\.name), key == .power ? ["Long-press Power"] : [], "\(key)")
        }
        XCTAssertEqual(HardwareButtonHotspotView.toolTip(for: .power), "Power: click to lock or wake; hold for a long press")

        let volumeUp = try XCTUnwrap(views[.volumeUp])
        let pressed = Date()
        XCTAssertTrue(volumeUp.accessibilityPerformPress())
        XCTAssertEqual(hosted.session.hardwareKeyEvents, [HardwareKeyEvent(key: .volumeUp, isDown: true)])
        await waitUntil("the press came up") { hosted.session.hardwareKeyEvents.count == 2 }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(pressed), 0.1)
        XCTAssertEqual(hosted.session.hardwareKeyEvents.last, HardwareKeyEvent(key: .volumeUp, isDown: false))

        let power = try XCTUnwrap(views[.power])
        let longPress = try XCTUnwrap(power.accessibilityCustomActions()?.first)
        let held = Date()
        XCTAssertTrue(longPress.handler?() ?? false)
        XCTAssertEqual(hosted.session.hardwareKeyEvents.last, HardwareKeyEvent(key: .power, isDown: true))
        await waitUntil("the long press came up") { hosted.session.hardwareKeyEvents.count == 4 }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(held), 1.0)
        XCTAssertEqual(hosted.session.hardwareKeyEvents.last, HardwareKeyEvent(key: .power, isDown: false))
    }

    /// The long press reaches assistive apps only through an override of
    /// `accessibilityCustomActions()`: SwiftUI's element standing in for a
    /// representable's view passes the view's custom actions on to an AX
    /// client only when the class overrides the getter, so actions stored
    /// with the setter read back in-process (the test above) yet VoiceOver
    /// saw only AXPress. An out-of-process check needs Accessibility trust
    /// for the test runner and an unlocked screen, so this pins the
    /// override instead; the live check is in the parity audit (HW-01).
    func testTheLongPressIsAnOverrideSwiftUIExports() throws {
        let selector = #selector(NSView.accessibilityCustomActions)
        let own = try XCTUnwrap(class_getInstanceMethod(HardwareButtonHotspotView.self, selector))
        let inherited = try XCTUnwrap(class_getInstanceMethod(NSView.self, selector))
        XCTAssertNotEqual(
            method_getImplementation(own), method_getImplementation(inherited),
            "HardwareButtonHotspotView must override accessibilityCustomActions()"
        )
        // Nothing is stored for SwiftUI's element to miss: the actions come
        // from the override whatever the setter was last given.
        let view = HardwareButtonHotspotView(frame: .zero)
        view.setAccessibilityCustomActions([])
        XCTAssertEqual(view.accessibilityCustomActions()?.map(\.name), ["Long-press Power"])
        view.key = .volumeUp
        XCTAssertEqual(view.accessibilityCustomActions()?.map(\.name), [])
    }

    // MARK: - Hover and press

    /// The pointer over either rocker half rolls out the whole rocker, and
    /// crossing from one half to the other keeps it out whichever order the
    /// enter and exit come in; it eases back `chromeHoverOffDelay` after the
    /// pointer left the last half.
    func testTheRockerRollsOutAsOneAndEasesBackAfterTheDelay() async throws {
        let state = HardwareButtonsState()
        state.enter(.volumeUp, group: 1, reduceMotion: false)
        XCTAssertEqual(state.popped, [1])
        // Enter before exit, then exit before enter.
        state.enter(.volumeDown, group: 1, reduceMotion: false)
        state.exit(.volumeUp, reduceMotion: false)
        state.exit(.volumeDown, reduceMotion: false)
        state.enter(.volumeUp, group: 1, reduceMotion: false)
        try await Task.sleep(for: .seconds(MotionMetrics.chromeHoverOffDelay * 3))
        XCTAssertEqual(state.popped, [1], "still under the pointer")

        state.exit(.volumeUp, reduceMotion: false)
        XCTAssertEqual(state.popped, [1], "not before the delay")
        await waitUntil("eased back") { state.popped.isEmpty }
    }

    /// Under Reduce Motion the pointer over a button shows nothing: no
    /// group rolls out and the stage keeps drawing the artwork whole. A
    /// press holds the key (tinted over the whole artwork), and nothing is
    /// ever handed back.
    func testUnderReduceMotionHoverShowsNothingAndAPressOnlyTints() async throws {
        let state = HardwareButtonsState()
        let mirror = MirrorController(adbClient: nil, context: ActiveDeviceContext(), status: StatusCenter(), perfLog: nil)
        state.enter(.volumeUp, group: 1, reduceMotion: true)
        state.enter(.power, group: 0, reduceMotion: true)
        XCTAssertEqual(state.popped, [], "nothing rolls out")
        XCTAssertFalse(state.drawsSplit, "the artwork stays whole")
        XCTAssertEqual(state.restFade, 1)

        state.press(.power, on: mirror, reduceMotion: true)
        XCTAssertEqual(state.pressed, [.power])
        XCTAssertFalse(state.drawsSplit, "a held key is tinted over the artwork whole")
        state.release(.power, on: mirror, reduceMotion: true)
        state.exit(.power, reduceMotion: true)
        state.exit(.volumeUp, reduceMotion: true)
        XCTAssertEqual(state.pressed, [])
        await waitUntil("back at rest") { !state.isAwayFromRest }
        try await Task.sleep(for: .seconds(MotionMetrics.chromeRestFadeDuration + 0.1))
        XCTAssertFalse(state.drawsSplit)
        XCTAssertEqual(state.restFade, 1)
    }

    /// The stage draws the frame split from the moment a button starts to
    /// move (at once: `restFade` 0) until, every button back at rest, the
    /// split has cross-faded back to the artwork whole (`restFade` 1, then
    /// the split dropped): rolled out, held, easing back after the pointer
    /// left or the click came up, and fading. A move during the fade takes
    /// the split back at once, and the old fade's end does not drop it.
    /// Releasing everything is at rest at once, and no completion from
    /// before counts. The animations are completed by the test, in order.
    func testTheSplitIsDrawnFromAMoveUntilTheHandBackEnds() async throws {
        let animations = ManualAnimations()
        let state = HardwareButtonsState(animate: animations.animate)
        let mirror = MirrorController(adbClient: nil, context: ActiveDeviceContext(), status: StatusCenter(), perfLog: nil)
        XCTAssertFalse(state.isAwayFromRest)
        XCTAssertFalse(state.drawsSplit)
        XCTAssertEqual(state.restFade, 1)

        state.enter(.power, group: 0, reduceMotion: false)
        XCTAssertTrue(state.isAwayFromRest, "rolled out")
        XCTAssertTrue(state.drawsSplit, "the split from the first frame of the move")
        XCTAssertEqual(state.restFade, 0)
        state.exit(.power, reduceMotion: false)
        await waitUntil("easing back") { state.popped.isEmpty }
        XCTAssertTrue(state.isAwayFromRest, "still easing back")
        XCTAssertTrue(state.drawsSplit)
        XCTAssertEqual(state.restFade, 0, "no fade before the ease ends")
        animations.complete(1)
        XCTAssertFalse(state.isAwayFromRest, "at rest")
        XCTAssertEqual(state.restFade, 1, "handing back")
        XCTAssertTrue(state.drawsSplit, "the split stays drawn until the fade ends")
        animations.complete(1)
        XCTAssertFalse(state.drawsSplit, "the split dropped once the fade ended")
        XCTAssertEqual(animations.pending, 0)

        state.press(.volumeDown, on: mirror, reduceMotion: false)
        XCTAssertTrue(state.isAwayFromRest, "held")
        XCTAssertTrue(state.drawsSplit)
        XCTAssertEqual(state.restFade, 0)
        state.release(.volumeDown, on: mirror, reduceMotion: false)
        XCTAssertTrue(state.pressed.isEmpty)
        XCTAssertTrue(state.isAwayFromRest, "easing back from the press")
        animations.complete(1)
        XCTAssertEqual(state.restFade, 1, "handing back")

        // A move during the fade.
        state.enter(.volumeUp, group: 1, reduceMotion: false)
        XCTAssertTrue(state.drawsSplit)
        XCTAssertEqual(state.restFade, 0, "the split back at once")
        animations.complete(1)
        XCTAssertTrue(state.drawsSplit, "the old fade's end does not drop the split")
        XCTAssertEqual(state.restFade, 0)
        XCTAssertEqual(state.popped, [1])

        state.press(.volumeUp, on: mirror, reduceMotion: false)
        state.release(.volumeUp, on: mirror, reduceMotion: false)
        XCTAssertEqual(animations.pending, 1, "easing back from the press")
        state.releaseAll(on: mirror)
        XCTAssertFalse(state.isAwayFromRest, "at once after releasing everything")
        XCTAssertFalse(state.drawsSplit)
        XCTAssertEqual(state.restFade, 1)
        animations.complete(1)
        XCTAssertFalse(state.isAwayFromRest, "a completion from before does not count")
        XCTAssertFalse(state.drawsSplit)
        XCTAssertEqual(state.restFade, 1)
        XCTAssertEqual(animations.pending, 0, "and starts no fade")
    }

    /// The state's animations, run at once and completed when the test
    /// says, oldest first.
    @MainActor
    private final class ManualAnimations {
        private var completions: [@MainActor () -> Void] = []

        var pending: Int { completions.count }

        func animate(_ animation: Animation?, _ body: () -> Void, _ completion: @escaping @MainActor () -> Void) {
            body()
            completions.append(completion)
        }

        func complete(_ count: Int) {
            for _ in 0..<count where !completions.isEmpty {
                completions.removeFirst()()
            }
        }
    }

    /// The hotspots drive the pointer state the sprites are drawn from and
    /// the keys: the pointer over a hotspot rolls its group out, a click
    /// holds its key (on the device too) until its mouse-up, and releasing
    /// everything puts every button back at rest. Hosted on their own, with
    /// hand-placed rects (generated input).
    func testTheHotspotsDriveTheButtonsState() async throws {
        let art = try tenProArt()
        let model = AppModel.testing()
        let session = FakeMirrorSession()
        model.mirror.session = session
        let state = HardwareButtonsState()
        let rects: [HardwareKey: CGRect] = [
            .power: CGRect(x: 10, y: 10, width: 20, height: 40),
            .volumeUp: CGRect(x: 10, y: 60, width: 20, height: 40),
            .volumeDown: CGRect(x: 10, y: 100, width: 20, height: 40),
        ]
        let content = HardwareButtonHotspots(art: art, hotspots: rects, state: state, reduceMotion: false)
            .frame(width: 100, height: 200, alignment: .topLeading)
            .environment(model).environment(model.workspace)
        let host = NSHostingView(rootView: content)
        let window = ScaledTestWindow.hosting(host, size: CGSize(width: 100, height: 200), scale: 2)
        defer { window.close() }
        await waitUntil("the hotspots appeared") {
            host.layoutSubtreeIfNeeded()
            return hotspotViews(in: host).count == 3
        }
        var views: [HardwareKey: HardwareButtonHotspotView] = [:]
        for view in hotspotViews(in: host) { views[view.key] = view }
        let power = try XCTUnwrap(views[.power])
        let volumeUp = try XCTUnwrap(views[.volumeUp])
        // Placed where they were asked to be (window y grows up).
        let drawn = power.convert(power.bounds, to: nil)
        XCTAssertEqual(drawn.minX, 10, accuracy: 0.5)
        XCTAssertEqual(drawn.maxY, 200 - 10, accuracy: 0.5)
        XCTAssertEqual(drawn.width, 20, accuracy: 0.5)

        power.pointerMoved(to: centre(of: power))
        XCTAssertEqual(state.popped, [0])
        power.mouseDown(with: mouse(.leftMouseDown, at: .zero, in: window))
        XCTAssertEqual(state.pressed, [.power])
        XCTAssertEqual(session.hardwareKeyEvents, [HardwareKeyEvent(key: .power, isDown: true)])
        power.mouseUp(with: mouse(.leftMouseUp, at: .zero, in: window))
        XCTAssertEqual(state.pressed, [])
        XCTAssertEqual(session.hardwareKeyEvents.last, HardwareKeyEvent(key: .power, isDown: false))

        volumeUp.pointerMoved(to: centre(of: volumeUp))
        XCTAssertEqual(state.popped, [0, 1])
        volumeUp.mouseDown(with: mouse(.leftMouseDown, at: .zero, in: window))
        state.releaseAll(on: model.mirror)
        XCTAssertEqual(state.popped, [])
        XCTAssertEqual(state.pressed, [])
        XCTAssertEqual(session.hardwareKeyEvents.suffix(2), [
            HardwareKeyEvent(key: .volumeUp, isDown: true),
            HardwareKeyEvent(key: .volumeUp, isDown: false),
        ])
    }

    /// A hotspot that moves out from under a still pointer (a zoom step, a
    /// window resize, a scroll of the zoomed stage) gets no mouse-exited:
    /// its tracking area is rebuilt where it now is. Rebuilt, it reads
    /// where the pointer is, and its button eases back; moved back under
    /// the pointer, it rolls out again. AppKit rebuilds the area as the
    /// view's geometry changes; the test calls `updateTrackingAreas` as it
    /// would, and stands in for the pointer. Hosted on their own, with
    /// hand-placed rects (generated input).
    func testAHotspotMovedFromUnderAStillPointerLetsItsButtonGo() async throws {
        let art = try tenProArt()
        for scale in Self.scales {
            let context = "\(scale)x"
            let model = AppModel.testing()
            model.mirror.session = FakeMirrorSession()
            let state = HardwareButtonsState()
            func content(powerX: CGFloat) -> AnyView {
                let rects: [HardwareKey: CGRect] = [
                    .power: CGRect(x: powerX, y: 10, width: 20, height: 40),
                    .volumeUp: CGRect(x: 10, y: 60, width: 20, height: 40),
                    .volumeDown: CGRect(x: 10, y: 100, width: 20, height: 40),
                ]
                return AnyView(
                    HardwareButtonHotspots(art: art, hotspots: rects, state: state, reduceMotion: false)
                        .frame(width: 100, height: 200, alignment: .topLeading)
                        .environment(model).environment(model.workspace)
                )
            }
            let host = NSHostingView(rootView: content(powerX: 10))
            let window = ScaledTestWindow.hosting(host, size: CGSize(width: 100, height: 200), scale: scale)
            defer { window.close() }
            await waitUntil("\(context): the hotspots appeared") {
                host.layoutSubtreeIfNeeded()
                return hotspotViews(in: host).count == 3
            }
            let power = try XCTUnwrap(hotspotViews(in: host).first { $0.key == .power }, context)
            // Over the power button as first placed (window y grows up).
            let pointer = NSPoint(x: 20, y: 200 - 30)
            power.pointerLocation = { pointer }

            power.updateTrackingAreas()
            XCTAssertTrue(power.isHovered, "\(context): rebuilt under the pointer")
            XCTAssertEqual(state.popped, [0], context)

            host.rootView = content(powerX: 60)
            host.layoutSubtreeIfNeeded()
            XCTAssertFalse(power.convert(power.bounds, to: nil).contains(pointer), "\(context): moved from under the pointer")
            power.updateTrackingAreas()
            XCTAssertFalse(power.isHovered, context)
            await waitUntil("\(context): eased back") { state.popped.isEmpty }

            host.rootView = content(powerX: 10)
            host.layoutSubtreeIfNeeded()
            power.updateTrackingAreas()
            XCTAssertTrue(power.isHovered, "\(context): moved back under the pointer")
            XCTAssertEqual(state.popped, [0], context)

            // The stage let every button go (the device turned, say) with
            // the pointer still there: rebuilt under it, the button rolls
            // out again.
            state.releaseAll(on: model.mirror)
            XCTAssertEqual(state.popped, [], context)
            power.updateTrackingAreas()
            XCTAssertEqual(state.popped, [0], "\(context): rebuilt under the pointer after everything was let go")

            // The pointer leaving the window after that lets it go; a
            // repeated leave changes nothing.
            power.pointerMoved(to: nil)
            power.pointerMoved(to: nil)
            XCTAssertFalse(power.isHovered, context)
            await waitUntil("\(context): eased back after the exit") { state.popped.isEmpty }
        }
    }

    /// Tier 2 live check 4, bug 1: hover died after the first turn, in
    /// every pose, while clicks kept working. Once turned, SwiftUI hosts the
    /// hotspots under a view it rotates with `frameCenterRotation` (after
    /// four left turns a residual 1.4e-14° stays), where AppKit tracking does
    /// not reach them. The hover area now lives on the window's content view,
    /// which is never turned. On the open fold at 1x and 2x, at rest and
    /// after each of four quarter turns (back to portrait): the area is on an
    /// unturned view, and the pointer's moves reported through it roll the
    /// power button out over the drawn hotspot and back off it, and never
    /// over the unturned spot.
    func testHoverFollowsTheHotspotThroughEveryTurn() async throws {
        try XCTSkipIf(MotionMetrics.reduceMotion, "Reduce Motion is on: the pose snaps instead of turning")
        for scale in Self.scales {
            let clock = HeldTurn.Clock()
            let hosted = try host(chrome: .skin(sdkSkin(named: "pixel_9_pro_fold")), scale: scale, heldTurn: clock)
            defer { hosted.window.close() }
            await pose(hosted, rotation: 0, natural: Self.foldOpen)
            var restCentre: CGPoint?
            for turn in 0...4 {
                let context = "\(scale)x after \(turn) turns"
                if turn > 0 {
                    clock.progress = 0
                    hosted.model.workspace.mirror.stagePose.beginRotation(.left)
                    clock.progress = 1
                    await waitUntil("\(context): the turn ended") { !hosted.model.workspace.mirror.stagePose.isAnimating }
                }
                let power = try await hotspot(.power, in: hosted, context)
                let area = try XCTUnwrap(power.hoverTrackingArea, "\(context): a hover area")
                let tracking = try XCTUnwrap(
                    hosted.content.trackingAreas.first { $0 === area },
                    "\(context): the area is on the content view"
                )
                XCTAssertFalse(hosted.content.isRotatedOrScaledFromBase, context)
                XCTAssertTrue(tracking.options.contains(.mouseMoved), context)
                let owner = try XCTUnwrap(tracking.owner as? NSResponder, context)

                let drawn = power.convert(power.bounds, to: nil)
                let centre = CGPoint(x: drawn.midX, y: drawn.midY)
                if turn == 0 { restCentre = centre }
                owner.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 5, y: 5), in: hosted.window))
                XCTAssertFalse(power.isHovered, "\(context): off the button")
                owner.mouseEntered(with: try enterExit(.mouseEntered, at: centre, in: hosted.window))
                owner.mouseMoved(with: mouse(.mouseMoved, at: centre, in: hosted.window))
                XCTAssertTrue(power.isHovered, "\(context): over the drawn button at \(centre)")
                owner.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 5, y: 5), in: hosted.window))
                XCTAssertFalse(power.isHovered, "\(context): moved off")
                if turn % 2 == 1, let restCentre {
                    owner.mouseMoved(with: mouse(.mouseMoved, at: restCentre, in: hosted.window))
                    XCTAssertFalse(power.isHovered, "\(context): the unturned spot is not the button")
                }
                owner.mouseMoved(with: mouse(.mouseMoved, at: centre, in: hosted.window))
                owner.mouseExited(with: try enterExit(.mouseExited, at: CGPoint(x: 5, y: 5), in: hosted.window))
                XCTAssertFalse(power.isHovered, "\(context): the pointer left the window")
            }
            // Four left turns leave the stage turned by a hair, so AppKit
            // still counts it as rotated: what broke the old area.
            let power = try await hotspot(.power, in: hosted, "\(scale)x")
            XCTAssertTrue(
                sequence(first: power.superview, next: { $0?.superview }).contains { $0?.frameRotation != 0 },
                "\(scale)x: a turned ancestor after four turns (the setting the old area failed in)"
            )
        }
    }

    /// A view's centre in window coordinates.
    private func centre(of view: NSView) -> NSPoint {
        let rect = view.convert(view.bounds, to: nil)
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    private func enterExit(_ type: NSEvent.EventType, at location: CGPoint = .zero, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
    }

    // MARK: - Frame

    /// Under Reduce Motion no sprite moves and the split is never drawn:
    /// with both groups under the pointer, the stage's frame
    /// (`LiveButtonsFrame`) is the artwork whole, pixel for pixel; with
    /// power held too, only power's button changes, and only darker, by at
    /// most the press's 8 % (a sprite that moved would uncover the stage
    /// somewhere). Without Reduce Motion the same pointer moves them. Over
    /// white, at 1x and 2x.
    func testReduceMotionNeverMovesASprite() throws {
        let art = try tenProArt()
        let whole = try XCTUnwrap(tenProBackground())
        let mirror = MirrorController(adbClient: nil, context: ActiveDeviceContext(), status: StatusCenter(), perfLog: nil)
        let pointsPerPixel: CGFloat = 0.283
        let size = CGSize(width: art.pixelSize.width * pointsPerPixel, height: art.pixelSize.height * pointsPerPixel)
        func states(reduceMotion: Bool) -> (hovered: HardwareButtonsState, held: HardwareButtonsState) {
            let hovered = HardwareButtonsState()
            let held = HardwareButtonsState()
            for state in [hovered, held] {
                state.enter(.power, group: 0, reduceMotion: reduceMotion)
                state.enter(.volumeUp, group: 1, reduceMotion: reduceMotion)
            }
            held.press(.power, on: mirror, reduceMotion: reduceMotion)
            return (hovered, held)
        }
        let reduced = states(reduceMotion: true)
        let moving = states(reduceMotion: false)
        XCTAssertFalse(reduced.hovered.drawsSplit)
        XCTAssertFalse(reduced.held.drawsSplit)
        XCTAssertTrue(moving.held.drawsSplit)
        let power = try XCTUnwrap(art.keys[.power]?.rect)

        for scale: CGFloat in [1, 2] {
            let context = "\(scale)x"
            let region = spriteRegion(art, pointsPerPixel: pointsPerPixel, scale: scale)
            func frame(_ state: HardwareButtonsState, reduceMotion: Bool) throws -> Pixels {
                try render(
                    stageFrame(art, whole: whole, size: size, state: state, reduceMotion: reduceMotion),
                    size: size,
                    white: true,
                    scale: scale
                )
            }
            let rest = try render(FramedArtwork(image: whole, frame: CGRect(origin: .zero, size: size)), size: size, white: true, scale: scale)
            let hovered = try frame(reduced.hovered, reduceMotion: true)
            let held = try frame(reduced.held, reduceMotion: true)
            let moved = try frame(moving.held, reduceMotion: false)
            // Power's rect, and the filter's reach of a pixel or two past it.
            let factor = pointsPerPixel * scale
            let tinted = (
                minX: Int((power.minX * factor).rounded(.down)) - 3,
                maxX: Int((power.maxX * factor).rounded(.up)) + 3,
                minY: Int((power.minY * factor).rounded(.down)) - 3,
                maxY: Int((power.maxY * factor).rounded(.up)) + 3
            )
            var hoverDifference = 0
            var outsideDifference = 0
            var lighter = 0
            var tooDark = 0
            var darkened = 0
            var moves = 0
            for y in region.minY..<region.maxY {
                for x in region.minX..<region.maxX {
                    hoverDifference = max(hoverDifference, rest.difference(from: hovered, x, y))
                    let inPower = x >= tinted.minX && x < tinted.maxX && y >= tinted.minY && y < tinted.maxY
                    if inPower {
                        for (was, now) in [(rest.red(x, y), held.red(x, y)), (rest.green(x, y), held.green(x, y)), (rest.blue(x, y), held.blue(x, y))] {
                            if now > was { lighter += 1 }
                            if Double(now) < Double(was) * MotionMetrics.chromePressTint - 1.5 { tooDark += 1 }
                        }
                        if held.green(x, y) < rest.green(x, y) { darkened += 1 }
                    } else {
                        outsideDifference = max(outsideDifference, rest.difference(from: held, x, y))
                    }
                    if rest.difference(from: moved, x, y) > 32 { moves += 1 }
                }
            }
            XCTAssertEqual(hoverDifference, 0, "\(context): the pointer alone shows nothing")
            XCTAssertEqual(outsideDifference, 0, "\(context): nothing but the held button changed")
            XCTAssertEqual(lighter, 0, "\(context): the held button only darkens")
            XCTAssertEqual(tooDark, 0, "\(context): by at most the press's tint")
            XCTAssertGreaterThan(darkened, 0, "\(context): the held button is darkened")
            XCTAssertGreaterThan(moves, 0, "\(context): without Reduce Motion the same pointer moves them")
        }
    }

    /// The frame split at rest (the sprites under the frame without them),
    /// as the stage draws it the moment a button starts to move and while
    /// it hands back (`LiveButtonsFrame`), against the artwork drawn whole,
    /// at the stage's fit (the 10 Pro's 0.283 pt per pixel, the open fold's
    /// 0.36, the Pixel 8's 0.3), at quarter-point origins, over white, at
    /// 1x and 2x. Minified, the two are not the same pixels (the filter
    /// sees each piece alone), which is why the stage never shows the split
    /// at rest; how far apart they are is held to what was measured, far
    /// under a seam that lets the white stage through (≈200 levels):
    ///
    /// - along each button's straight run (the middle 60 % of its rows, from
    ///   40 pixels inside the body to past the button): at 2x at most 7
    ///   levels, where the rocker's halves drawn apart without the seam
    ///   fill leave 27 on the 10 Pro, which this sees; at 1x, where the
    ///   filter's reach spans a whole button, up to 47;
    /// - around the buttons, their ends included (8 pixels past each
    ///   group's rows): at 2x up to 61, at 1x up to 88.
    func testTheSplitFrameShowsNoSeamAlongTheButtons() throws {
        for (name, variant, pointsPerPixel) in Self.fits {
            let (original, art) = try splitArt(name, variant: variant)
            let size = CGSize(width: art.pixelSize.width * pointsPerPixel, height: art.pixelSize.height * pointsPerPixel)
            for scale in Self.scales {
                let context = "\(name) at \(scale)x"
                let tolerance = try XCTUnwrap(Self.splitTolerance[name]?[scale], context)
                let factor = pointsPerPixel * scale
                var worstRun = (difference: 0, x: 0, y: 0)
                var worstAround = (difference: 0, x: 0, y: 0)
                var worstApart = 0
                for origin: CGFloat in [0, 0.25, 0.5, 0.75] {
                    let whole = try render(
                        FramedArtwork(image: original, frame: CGRect(origin: .zero, size: size)),
                        size: size, origin: origin, white: true, scale: scale
                    )
                    let split = try render(
                        stageFrame(art, whole: original, size: size, drawsSplit: true, restFade: 0),
                        size: size, origin: origin, white: true, scale: scale
                    )
                    let apart = try render(
                        ZStack(alignment: .topLeading) {
                            Canvas { canvas, size in
                                for piece in art.keys.values {
                                    let rect = piece.rect
                                    canvas.draw(
                                        Image(decorative: piece.sprite, scale: 1).interpolation(.high).antialiased(true),
                                        in: CGRect(
                                            x: rect.minX * size.width / art.pixelSize.width,
                                            y: rect.minY * size.height / art.pixelSize.height,
                                            width: rect.width * size.width / art.pixelSize.width,
                                            height: rect.height * size.height / art.pixelSize.height
                                        )
                                    )
                                }
                            }
                            FramedArtwork(image: art.background, frame: CGRect(origin: .zero, size: size))
                        },
                        size: size, origin: origin, white: true, scale: scale
                    )
                    for group in Set(art.buttons.map(\.group)) {
                        let rows = art.buttons.filter { $0.group == group }.map(\.rect).reduce(CGRect.null) { $0.union($1) }
                        let left = Int(((rows.minX - 40) * factor + origin * scale).rounded(.down))
                        let right = Int(((art.pixelSize.width + 16) * factor + origin * scale).rounded(.up))
                        let runTop = Int(((rows.minY + rows.height * 0.2) * factor + origin * scale).rounded(.up))
                        let runBottom = Int(((rows.maxY - rows.height * 0.2) * factor + origin * scale).rounded(.down))
                        let top = Int(((rows.minY - 8) * factor + origin * scale).rounded(.down))
                        let bottom = Int(((rows.maxY + 8) * factor + origin * scale).rounded(.up))
                        for y in top..<bottom {
                            let onRun = y >= runTop && y < runBottom
                            for x in left..<right {
                                let difference = whole.difference(from: split, x, y)
                                if difference > worstAround.difference { worstAround = (difference, x, y) }
                                if onRun {
                                    if difference > worstRun.difference { worstRun = (difference, x, y) }
                                    worstApart = max(worstApart, whole.difference(from: apart, x, y))
                                }
                            }
                        }
                    }
                }
                XCTAssertLessThanOrEqual(
                    worstRun.difference,
                    tolerance.run,
                    "\(context): along a straight run, pixel (\(worstRun.x), \(worstRun.y)) differs by \(worstRun.difference) levels"
                )
                XCTAssertLessThanOrEqual(
                    worstAround.difference,
                    tolerance.around,
                    "\(context): around the buttons, pixel (\(worstAround.x), \(worstAround.y)) differs by \(worstAround.difference) levels"
                )
                if name == "pixel_10_pro", scale == 2 {
                    XCTAssertGreaterThan(worstApart, 20, "\(context): drawn apart, the halves' seam shows at some origin")
                }
            }
        }
    }

    /// The hand-back from the split to the artwork whole as the stage draws
    /// it (`LiveButtonsFrame`, `RestFadeOpacity`), at the three fits, at
    /// quarter-point origins, over white, at 1x and 2x: at its start it is
    /// the split drawn alone and at its end the artwork drawn alone, as at
    /// rest (so neither the fade's start nor the split's removal after it
    /// changes a pixel), and no twentieth of the fade changes a pixel
    /// around the buttons by more than `fadeStepTolerance` levels, where
    /// switching at once changes them by up to 88 (measured: at most 9 a
    /// step).
    func testTheSplitHandsBackToTheWholeArtworkWithoutAJump() throws {
        for (name, variant, pointsPerPixel) in Self.fits {
            let (original, art) = try splitArt(name, variant: variant)
            let size = CGSize(width: art.pixelSize.width * pointsPerPixel, height: art.pixelSize.height * pointsPerPixel)
            for scale in Self.scales {
                let context = "\(name) at \(scale)x"
                var worstSwitch = 0
                var worstStep = 0
                var worstStart = 0
                var worstEnd = 0
                for origin: CGFloat in [0, 0.25, 0.5, 0.75] {
                    let region = spriteRegion(art, pointsPerPixel: pointsPerPixel, scale: scale, origin: origin)
                    func worst(_ a: Pixels, _ b: Pixels) -> Int {
                        var worst = 0
                        for y in region.minY..<region.maxY {
                            for x in region.minX..<region.maxX {
                                worst = max(worst, a.difference(from: b, x, y))
                            }
                        }
                        return worst
                    }
                    func frame(_ progress: Double, drawsSplit: Bool = true) throws -> Pixels {
                        try render(
                            stageFrame(art, whole: original, size: size, drawsSplit: drawsSplit, restFade: progress),
                            size: size, origin: origin, white: true, scale: scale
                        )
                    }
                    let whole = try render(
                        FramedArtwork(image: original, frame: CGRect(origin: .zero, size: size)),
                        size: size, origin: origin, white: true, scale: scale
                    )
                    let split = try render(
                        ZStack(alignment: .topLeading) {
                            HardwareButtonSprites(art: art, offsets: [:], tinted: [])
                            FramedArtwork(image: art.background, frame: CGRect(origin: .zero, size: size))
                        },
                        size: size, origin: origin, white: true, scale: scale
                    )
                    let rest = try frame(1, drawsSplit: false)
                    XCTAssertEqual(worst(rest, whole), 0, "\(context), origin \(origin): at rest the stage draws the artwork whole")
                    worstSwitch = max(worstSwitch, worst(split, whole))
                    var previous = try frame(0)
                    worstStart = max(worstStart, worst(previous, split))
                    for step in 1...20 {
                        let next = try frame(Double(step) / 20)
                        worstStep = max(worstStep, worst(previous, next))
                        previous = next
                    }
                    worstEnd = max(worstEnd, worst(previous, whole))
                }
                XCTAssertLessThanOrEqual(worstStart, 1, "\(context): the fade starts from the split")
                XCTAssertEqual(worstEnd, 0, "\(context): the fade ends on the artwork whole")
                XCTAssertLessThanOrEqual(worstStep, Self.fadeStepTolerance, "\(context): a twentieth of the fade")
                XCTAssertGreaterThan(worstSwitch, worstStep, "\(context): switching at once is the jump the fade hides")
            }
        }
    }

    /// The stage fits the frame tests draw at: the 10 Pro's, the open
    /// fold's and the Pixel 8's, points per artwork pixel.
    private static let fits: [(name: String, variant: String?, pointsPerPixel: CGFloat)] = [
        ("pixel_10_pro", nil, 0.283),
        ("pixel_9_pro_fold", "default", 0.36),
        ("pixel_8", nil, 0.3),
    ]

    /// Levels (of 255) the split frame at rest may differ from the artwork
    /// whole, per skin and scale: along the buttons' straight runs and
    /// around them. Measured: 10 Pro 1x 46 / 46, 2x 1 / 14; open fold 1x
    /// 47 / 88, 2x 7 / 61; Pixel 8 1x 17 / 56, 2x 3 / 40.
    private static let splitTolerance: [String: [CGFloat: (run: Int, around: Int)]] = [
        "pixel_10_pro": [1: (48, 48), 2: (8, 16)],
        "pixel_9_pro_fold": [1: (49, 90), 2: (8, 63)],
        "pixel_8": [1: (19, 58), 2: (8, 42)],
    ]

    /// Levels (of 255) a twentieth of the hand-back may change a pixel
    /// around the buttons (measured: at most 9, the open fold at 1x).
    private static let fadeStepTolerance = 12

    /// `LiveButtonsFrame` as the stage draws it at `size` (the artwork's
    /// frame at the origin), with no backing, from `state`.
    private func stageFrame(
        _ art: LiveButtonArt,
        whole: NSImage,
        size: CGSize,
        state: HardwareButtonsState,
        reduceMotion: Bool
    ) -> some View {
        stageFrame(
            art,
            whole: whole,
            size: size,
            offsets: HardwareButtonSprites.offsets(
                art: art,
                state: state,
                pointsPerPixel: size.width / art.pixelSize.width,
                reduceMotion: reduceMotion
            ),
            held: state.pressed,
            drawsSplit: state.drawsSplit,
            restFade: state.restFade
        )
    }

    private func stageFrame(
        _ art: LiveButtonArt,
        whole: NSImage,
        size: CGSize,
        offsets: [HardwareKey: CGFloat] = [:],
        held: Set<HardwareKey> = [],
        drawsSplit: Bool,
        restFade: Double
    ) -> some View {
        ZStack(alignment: .topLeading) {
            LiveButtonsFrame(
                art: art,
                whole: whole,
                artworkFrame: CGRect(origin: .zero, size: size),
                offsets: offsets,
                held: held,
                drawsSplit: drawsSplit,
                restFade: restFade
            ) {
                EmptyView()
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// An installed skin's frame artwork and its live split.
    private func splitArt(_ name: String, variant: String?) throws -> (NSImage, LiveButtonArt) {
        let skin = try sdkSkin(named: name)
        let entry = try XCTUnwrap(variant.map { id in skin.variants.first { $0.id == id } } ?? skin.preferredVariant, name)
        let display = try XCTUnwrap(entry.layout?.preferred, name)
        let file = try XCTUnwrap(display.backgroundImage, name)
        let original = try XCTUnwrap(SkinThumbnail.loadImage(named: file, in: entry.directory), name)
        let art = try XCTUnwrap(LiveButtonArt.make(artworkURL: entry.directory.appendingPathComponent(file)), name)
        return (original, art)
    }

    // MARK: - Hosting

    private struct Hosted {
        let window: NSWindow
        let host: NSView
        let content: NSView
        let model: AppModel
        let session: FakeMirrorSession
    }

    /// `MirrorStageContent` in `chrome`, as the main stage shows it
    /// (`showsButtons`) or the compact window does, on an emulator session
    /// (`supportsHardwareKeys`) the model's mirror also holds, in an
    /// offscreen window of the stage's size at `scale`. Changes land at
    /// once, unless `heldTurn` holds every animation until its clock is 1.
    private func host(
        chrome: DeviceChrome,
        scale: CGFloat,
        showsButtons: Bool = true,
        supportsHardwareKeys: Bool = true,
        heldTurn: HeldTurn.Clock? = nil
    ) throws -> Hosted {
        let model = AppModel.testing()
        let session = FakeMirrorSession()
        session.supportsHardwareKeys = supportsHardwareKeys
        model.mirror.session = session
        let content = MirrorStageContent(session: session, chrome: chrome, available: Self.stage)
            .environment(\.showsHardwareButtons, showsButtons)
            .environment(model).environment(model.workspace)
            .transaction { transaction in
                if let heldTurn {
                    if transaction.animation != nil {
                        transaction.animation = Animation(HeldTurn(clock: heldTurn))
                    }
                } else {
                    transaction.animation = nil
                }
            }
        let host = NSHostingView(rootView: content)
        let window = ScaledTestWindow.hosting(host, size: Self.stage, scale: scale)
        XCTAssertEqual(window.backingScaleFactor, scale)
        return Hosted(window: window, host: host, content: try XCTUnwrap(window.contentView), model: model, session: session)
    }

    /// Resets the pose, then streams and settles a frame of the natural
    /// display turned `rotation` quarter turns (`PosedStageTests.stream`).
    private func pose(_ hosted: Hosted, rotation: Int, natural: (width: Int, height: Int)) async {
        hosted.model.workspace.mirror.stagePose.reset()
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
        // Best effort: the sleep fails only on cancellation.
        try? await Task.sleep(for: .milliseconds(50))
        hosted.host.layoutSubtreeIfNeeded()
    }

    /// The hotspot views by key, once the button split has landed and the
    /// stage rests in its pose.
    private func hotspots(in hosted: Hosted, _ context: String) async throws -> [HardwareKey: HardwareButtonHotspotView] {
        await waitUntil(timeout: 10, "\(context): the hotspots appeared") {
            hosted.host.layoutSubtreeIfNeeded()
            return hotspotViews(in: hosted.host).count == HardwareKey.allCases.count
        }
        if let mirror = mirrorView(in: hosted.host) {
            await waitUntil("\(context): the stage turned") {
                abs(remainder(poseAngle(of: mirror) - hosted.model.workspace.mirror.stagePose.restAngle, 360)) < 1e-6
            }
        }
        hosted.host.layoutSubtreeIfNeeded()
        var views: [HardwareKey: HardwareButtonHotspotView] = [:]
        for view in hotspotViews(in: hosted.host) { views[view.key] = view }
        return views
    }

    private func hotspot(_ key: HardwareKey, in hosted: Hosted, _ context: String) async throws -> HardwareButtonHotspotView {
        let views = try await hotspots(in: hosted, context)
        return try XCTUnwrap(views[key], "\(context): \(key)")
    }

    private func hotspotViews(in view: NSView) -> [HardwareButtonHotspotView] {
        if let hotspot = view as? HardwareButtonHotspotView { return [hotspot] }
        return view.subviews.flatMap { hotspotViews(in: $0) }
    }

    private func mirrorView(in view: NSView) -> MirrorMetalView? {
        if let mirror = view as? MirrorMetalView { return mirror }
        for subview in view.subviews {
            if let mirror = mirrorView(in: subview) { return mirror }
        }
        return nil
    }

    private func poseAngle(of view: NSView) -> Double {
        var ancestor = view.superview
        while let current = ancestor {
            if current.frameCenterRotation != 0 { return Double(current.frameCenterRotation) }
            ancestor = current.superview
        }
        return 0
    }

    private func describe(_ view: NSView?) -> String {
        guard let view else { return "nothing" }
        if let hotspot = view as? HardwareButtonHotspotView { return "hotspot \(hotspot.key)" }
        return String(describing: type(of: view))
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )!
    }

    // MARK: - Expected geometry

    /// The composition the stage should lay out, derived here from the
    /// plan: its size, and each button's hotspot in it, points.
    private struct Expected {
        let size: CGSize
        let rects: [HardwareKey: CGRect]
    }

    /// The hotspots of `skin`'s variant for a `natural` frame in the rest
    /// pose `rotation`: the scan's buttons in layout units, at the pose's
    /// fit, `min(8, ceil(overhang + 6))` points in from the left, widened
    /// 4 pt inward and 6 pt outward (held inside the composition).
    private func expectedHotspots(
        skin: ResolvedSkin,
        natural: (width: Int, height: Int),
        rotation: Int,
        scale: CGFloat
    ) throws -> Expected {
        let variant = try XCTUnwrap(skin.variant(matching: CGSize(width: natural.width, height: natural.height)))
        let display = try XCTUnwrap(variant.layout?.preferred)
        let image = try XCTUnwrap(display.backgroundImage)
        let artworkURL = variant.directory.appendingPathComponent(image)
        let pixelSize = try XCTUnwrap(SkinThumbnail.pixelSize(named: image, in: variant.directory))
        let angle = Double(-90 * rotation)
        let layoutScale = PoseFit.scale(
            angle: angle,
            nativeSize: display.layoutSize,
            box: CGSize(width: Self.stage.width - 16, height: Self.stage.height - 16)
        )
        let artworkRect = display.artworkRect(pixelSize: pixelSize)
        let pad = min(8, (max(0, artworkRect.maxX - display.layoutSize.width) * layoutScale + 6).rounded(.up))
        let size = CGSize(width: display.layoutSize.width * layoutScale + 2 * pad, height: display.layoutSize.height * layoutScale)
        let artworkScale = artworkRect.width / pixelSize.width
        var rects: [HardwareKey: CGRect] = [:]
        for button in SkinButtonScanner.scan(artworkURL: artworkURL) {
            // Artwork pixels into layout units, then points.
            let rect = CGRect(
                x: artworkRect.minX + button.rect.minX * artworkScale,
                y: artworkRect.minY + button.rect.minY * artworkScale,
                width: button.rect.width * artworkScale,
                height: button.rect.height * artworkScale
            )
            let minX = pad + rect.minX * layoutScale - 4
            let maxX = min(pad + rect.maxX * layoutScale + 6, size.width)
            rects[button.key] = CGRect(
                x: minX,
                y: rect.minY * layoutScale,
                width: maxX - minX,
                height: rect.height * layoutScale
            )
        }
        return Expected(size: size, rects: rects)
    }

    /// Where the pose draws `point` (composition points, y down) in the
    /// window: the composition centred in the stage, turned about the
    /// stage's centre by the rest angle at scale 1, moved by
    /// `PoseFit.pixelGridOffset`; the window's y grows up.
    private func windowPoint(_ point: CGPoint, expected: Expected, rotation: Int, scale: CGFloat) -> CGPoint {
        let angle = Double(-90 * rotation)
        let dx = point.x - expected.size.width / 2
        let dy = point.y - expected.size.height / 2
        let radians = angle * .pi / 180
        let grid = PoseFit.pixelGridOffset(angle: angle, size: Self.stage, pixelScale: scale)
        let x = Self.stage.width / 2 + dx * cos(radians) - dy * sin(radians) + grid
        let y = Self.stage.height / 2 + dx * sin(radians) + dy * cos(radians) + grid
        return CGPoint(x: x, y: Self.stage.height - y)
    }

    // MARK: - Skins

    private func sdkSkin(named name: String) throws -> ResolvedSkin {
        guard let skins = SkinLocator.skinsDirectory() else {
            throw XCTSkip("no Android SDK skins directory")
        }
        guard let entry = SkinResolver.catalog(skinsDirectory: skins).first(where: { $0.name == name }) else {
            throw XCTSkip("\(name) is not installed")
        }
        return ResolvedSkin(name: entry.name, directory: entry.directory, source: .skinName, variants: entry.variants)
    }

    private func tenProVariant() throws -> SkinVariant {
        try XCTUnwrap(sdkSkin(named: "pixel_10_pro").preferredVariant)
    }

    private func tenProBackground() throws -> NSImage? {
        let variant = try tenProVariant()
        let display = try XCTUnwrap(variant.layout?.preferred)
        return SkinThumbnail.loadImage(named: display.backgroundImage, in: variant.directory)
    }

    private func tenProArt() throws -> LiveButtonArt {
        let variant = try tenProVariant()
        let display = try XCTUnwrap(variant.layout?.preferred)
        let url = variant.directory.appendingPathComponent(try XCTUnwrap(display.backgroundImage))
        return try XCTUnwrap(LiveButtonArt.make(artworkURL: url))
    }

    // MARK: - Rendering

    /// The rendered pixels (at `scale`, the artwork drawn at `origin`
    /// points) of the buttons' rows and 8 artwork pixels past them, from 40
    /// artwork pixels inside the body's edge to past the farthest a sprite
    /// rolls out.
    private func spriteRegion(
        _ art: LiveButtonArt,
        pointsPerPixel: CGFloat,
        scale: CGFloat,
        origin: CGFloat = 0
    ) -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        let rects = art.keys.values.map(\.rect)
        let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        let factor = pointsPerPixel * scale
        let shift = origin * scale
        return (
            Int(((union.minX - 40) * factor + shift).rounded(.down)),
            Int(((art.pixelSize.width + 16) * factor + shift).rounded(.up)),
            Int(((union.minY - 8) * factor + shift).rounded(.down)),
            Int(((union.maxY + 8) * factor + shift).rounded(.up))
        )
    }

    /// `view` framed to `size` at `origin` points in a canvas 20 pt wider
    /// and 2 pt taller, over white or transparency, rendered at `scale`.
    private func render(
        _ view: some View,
        size: CGSize,
        origin: CGFloat = 0,
        white: Bool = false,
        scale: CGFloat = 2
    ) throws -> Pixels {
        let content = ZStack(alignment: .topLeading) {
            if white { Color.white }
            view
                .frame(width: size.width, height: size.height)
                .padding(.leading, origin)
                .padding(.top, origin)
        }
        .frame(width: (size.width + 20).rounded(.up), height: (size.height + 2).rounded(.up), alignment: .topLeading)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        return try Pixels(image: XCTUnwrap(renderer.cgImage, "rendered"))
    }

    /// A rendered image redrawn as premultiplied 8-bit sRGB RGBA, row 0 at
    /// the top.
    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(image: CGImage) throws {
            let width = image.width
            let height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                ) else {
                    return false
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            XCTAssertTrue(drawn)
            self.width = width
            self.height = height
            self.bytes = bytes
        }

        private func byte(_ x: Int, _ y: Int, _ channel: Int) -> UInt8 {
            guard x >= 0, y >= 0, x < width, y < height else { return 0 }
            return bytes[(y * width + x) * 4 + channel]
        }

        /// The largest difference of one colour channel at (x, y), levels.
        func difference(from other: Pixels, _ x: Int, _ y: Int) -> Int {
            (0..<3).map { abs(Int(byte(x, y, $0)) - Int(other.byte(x, y, $0))) }.max() ?? 0
        }

        func red(_ x: Int, _ y: Int) -> UInt8 { byte(x, y, 0) }
        func green(_ x: Int, _ y: Int) -> UInt8 { byte(x, y, 1) }
        func blue(_ x: Int, _ y: Int) -> UInt8 { byte(x, y, 2) }
        func alpha(_ x: Int, _ y: Int) -> UInt8 { byte(x, y, 3) }
    }
}

// MARK: - A turn held by the test

/// An animation that ignores time and holds every animated change where it
/// started until the test's clock reaches 1, so the stage stays turning as
/// long as the test needs (`PosedStageTests`' `SteppedTurn`).
private struct HeldTurn: CustomAnimation {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double = 0

        var progress: Double {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    let clock: Clock

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        let progress = clock.progress
        guard progress < 1 else { return nil }
        return value.scaled(by: progress)
    }

    static func == (lhs: HeldTurn, rhs: HeldTurn) -> Bool {
        lhs.clock === rhs.clock
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(clock))
    }
}

