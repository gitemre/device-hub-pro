import XCTest
@testable import DeviceHubProKit

/// Pure mapping tests for the physical input path: `adb shell input` argument
/// construction, the macOS→Android special-key map, text escaping and the
/// gesture accumulator that turns the stage's per-event contact frames into one
/// tap/swipe command.
final class PhysicalInputTests: XCTestCase {
    // MARK: - adb arguments

    func testTapBecomesOneInputTap() {
        XCTAssertEqual(
            PhysicalInput.arguments(for: .tap(x: 12, y: 34), serial: "S"),
            ["-s", "S", "shell", "input", "tap", "12", "34"]
        )
    }

    func testSwipeCarriesStartEndAndDuration() {
        XCTAssertEqual(
            PhysicalInput.arguments(
                for: .swipe(fromX: 1, fromY: 2, toX: 3, toY: 4, durationMs: 120),
                serial: "S"
            ),
            ["-s", "S", "shell", "input", "swipe", "1", "2", "3", "4", "120"]
        )
    }

    func testTextArgumentsUseTheEscapedForm() {
        XCTAssertEqual(
            PhysicalInput.arguments(forKeyboard: .text("a b"), serial: "S"),
            ["-s", "S", "shell", "input", "text", "a%sb"]
        )
    }

    func testSpacesBecomeTheInputPlaceholder() {
        XCTAssertEqual(PhysicalInput.escapedText("hello world"), "hello%sworld")
    }

    func testShellMetacharactersAreBackslashEscaped() {
        XCTAssertEqual(
            PhysicalInput.escapedText("a&b;c|d<e>f(g)h*i?j[k]l{m}n~o#p!q$r`s\"t'u\\v^x"),
            "a\\&b\\;c\\|d\\<e\\>f\\(g\\)h\\*i\\?j\\[k\\]l\\{m\\}n\\~o\\#p\\!q\\$r\\`s\\\"t\\'u\\\\v\\^x"
        )
    }

    func testEmptyOrControlOnlyTextIsNotSent() {
        XCTAssertNil(PhysicalInput.arguments(forKeyboard: .text(""), serial: "S"))
        XCTAssertNil(PhysicalInput.arguments(forKeyboard: .text("\n\r\u{0}"), serial: "S"))
    }

    func testSpecialKeysMapToAndroidKeyEvents() {
        let expected: [UInt16: Int] = [
            51: 67,             // delete
            117: 112,           // forward delete
            53: 111,            // escape
            36: 66,             // return
            76: 160,            // keypad enter
            48: 61,             // tab
            123: 21,            // left
            124: 22,            // right
            125: 20,            // down
            126: 19,            // up
            115: 122,           // home
            119: 123,           // end
            116: 92,            // page up
            121: 93,            // page down
        ]
        for (macKeyCode, androidKeyCode) in expected {
            XCTAssertEqual(
                PhysicalInput.arguments(forKeyboard: .specialKey(macKeyCode), serial: "S"),
                ["-s", "S", "shell", "input", "keyevent", "\(androidKeyCode)"],
                "mac key code \(macKeyCode)"
            )
        }
    }

    func testUnknownSpecialKeyIsDropped() {
        XCTAssertNil(PhysicalInput.arguments(forKeyboard: .specialKey(999), serial: "S"))
    }

    // MARK: - Gesture tracker

    func testDownUpWithoutMotionIsATap() {
        var tracker = PhysicalGestureTracker()
        let start = Date()
        XCTAssertNil(tracker.accept([TouchCommand(phase: .down, x: 40, y: 80)], at: start))
        XCTAssertEqual(
            tracker.accept(
                [TouchCommand(phase: .up, x: 40, y: 80)],
                at: start.addingTimeInterval(0.05)
            ),
            .tap(x: 40, y: 80)
        )
    }

    func testDragBecomesASwipeFromDownToUp() {
        var tracker = PhysicalGestureTracker()
        let start = Date()
        XCTAssertNil(tracker.accept([TouchCommand(phase: .down, x: 100, y: 200)], at: start))
        XCTAssertNil(tracker.accept(
            [TouchCommand(phase: .move, x: 100, y: 180)],
            at: start.addingTimeInterval(0.05)
        ))
        XCTAssertNil(tracker.accept(
            [TouchCommand(phase: .move, x: 100, y: 100)],
            at: start.addingTimeInterval(0.1)
        ))
        XCTAssertEqual(
            tracker.accept(
                [TouchCommand(phase: .up, x: 100, y: 60)],
                at: start.addingTimeInterval(0.2)
            ),
            .swipe(fromX: 100, fromY: 200, toX: 100, toY: 60, durationMs: 200)
        )
    }

    func testJitterWithinSlopStaysATap() {
        var tracker = PhysicalGestureTracker()
        let start = Date()
        _ = tracker.accept([TouchCommand(phase: .down, x: 40, y: 80)], at: start)
        _ = tracker.accept(
            [TouchCommand(phase: .move, x: 43, y: 84)],
            at: start.addingTimeInterval(0.03)
        )
        XCTAssertEqual(
            tracker.accept(
                [TouchCommand(phase: .up, x: 42, y: 83)],
                at: start.addingTimeInterval(0.06)
            ),
            .tap(x: 40, y: 80)
        )
    }

    func testHeldStillGestureBecomesALongPressLengthSwipe() {
        var tracker = PhysicalGestureTracker()
        let start = Date()
        _ = tracker.accept([TouchCommand(phase: .down, x: 40, y: 80)], at: start)
        XCTAssertEqual(
            tracker.accept(
                [TouchCommand(phase: .up, x: 40, y: 80)],
                at: start.addingTimeInterval(0.8)
            ),
            .swipe(fromX: 40, fromY: 80, toX: 40, toY: 80, durationMs: 800)
        )
    }

    func testMultiContactGestureIsDropped() {
        var tracker = PhysicalGestureTracker()
        let start = Date()
        let pinchDown = [
            TouchCommand(phase: .down, x: 40, y: 80, id: 1),
            TouchCommand(phase: .down, x: 60, y: 80, id: 2),
        ]
        let pinchMove = [
            TouchCommand(phase: .move, x: 30, y: 80, id: 1),
            TouchCommand(phase: .move, x: 70, y: 80, id: 2),
        ]
        let pinchUp = [
            TouchCommand(phase: .up, x: 20, y: 80, id: 1),
            TouchCommand(phase: .up, x: 80, y: 80, id: 2),
        ]
        XCTAssertNil(tracker.accept(pinchDown, at: start))
        XCTAssertNil(tracker.accept(pinchMove, at: start.addingTimeInterval(0.05)))
        XCTAssertNil(tracker.accept(pinchUp, at: start.addingTimeInterval(0.1)))

        // A following single-finger gesture is still expressible.
        XCTAssertNil(tracker.accept(
            [TouchCommand(phase: .down, x: 5, y: 5)],
            at: start.addingTimeInterval(0.2)
        ))
        XCTAssertEqual(
            tracker.accept(
                [TouchCommand(phase: .up, x: 5, y: 5)],
                at: start.addingTimeInterval(0.25)
            ),
            .tap(x: 5, y: 5)
        )
    }

    func testMoveWithoutDownIsIgnored() {
        var tracker = PhysicalGestureTracker()
        XCTAssertNil(tracker.accept([TouchCommand(phase: .move, x: 5, y: 5)]))
    }

    func testUpWithoutDownIsIgnored() {
        var tracker = PhysicalGestureTracker()
        XCTAssertNil(tracker.accept([TouchCommand(phase: .up, x: 5, y: 5)]))
    }

    func testEmptyFrameIsIgnored() {
        var tracker = PhysicalGestureTracker()
        XCTAssertNil(tracker.accept([]))
    }

    func testSecondDownRestartsTheGesture() {
        var tracker = PhysicalGestureTracker()
        let start = Date()
        _ = tracker.accept([TouchCommand(phase: .down, x: 1, y: 1)], at: start)
        XCTAssertNil(tracker.accept(
            [TouchCommand(phase: .down, x: 9, y: 9)],
            at: start.addingTimeInterval(0.1)
        ))
        XCTAssertEqual(
            tracker.accept(
                [TouchCommand(phase: .up, x: 9, y: 9)],
                at: start.addingTimeInterval(0.15)
            ),
            .tap(x: 9, y: 9)
        )
    }

    // MARK: - Display scaling (fallback)

    func testWmSizePrefersTheOverrideSize() throws {
        let physicalOnly = try XCTUnwrap(PhysicalInput.parseDisplaySize(fromWmSize: "Physical size: 1080x2400\n"))
        XCTAssertEqual(physicalOnly.width, 1080)
        XCTAssertEqual(physicalOnly.height, 2400)

        let overridden = try XCTUnwrap(PhysicalInput.parseDisplaySize(
            fromWmSize: "Physical size: 1440x3200\r\nOverride size: 1080x2400\r\n"
        ))
        XCTAssertEqual(overridden.width, 1080)
        XCTAssertEqual(overridden.height, 2400)

        XCTAssertNil(PhysicalInput.parseDisplaySize(fromWmSize: ""))
        XCTAssertNil(PhysicalInput.parseDisplaySize(fromWmSize: "Error: no display"))
        XCTAssertEqual(
            PhysicalInput.displaySizeArguments(serial: "S"),
            ["-s", "S", "shell", "wm", "size"]
        )
    }

    /// `wm size` is in the natural orientation; a landscape video means the
    /// display is quarter-turned, so its logical size is swapped.
    func testDisplaySizeFollowsTheVideoOrientation() {
        let portrait = PhysicalInput.displaySize(
            natural: (1080, 2400),
            orientedLikeVideoWidth: 1080,
            videoHeight: 2400
        )
        XCTAssertEqual(portrait.width, 1080)
        XCTAssertEqual(portrait.height, 2400)

        let landscape = PhysicalInput.displaySize(
            natural: (1080, 2400),
            orientedLikeVideoWidth: 1920,
            videoHeight: 864
        )
        XCTAssertEqual(landscape.width, 2400)
        XCTAssertEqual(landscape.height, 1080)
    }

    /// The failure the scaling fixes: frames downsized to 864x1920 on a
    /// 1440x3200 display put the mirror's centre in the screen's upper-left
    /// quadrant.
    func testGesturesAreScaledFromVideoToDisplayPixels() {
        XCTAssertEqual(
            PhysicalInput.scaled(
                .tap(x: 432, y: 960),
                videoWidth: 864, videoHeight: 1920,
                displayWidth: 1440, displayHeight: 3200
            ),
            .tap(x: 720, y: 1600)
        )
        XCTAssertEqual(
            PhysicalInput.scaled(
                .swipe(fromX: 0, fromY: 1919, toX: 863, toY: 0, durationMs: 250),
                videoWidth: 864, videoHeight: 1920,
                displayWidth: 1440, displayHeight: 3200
            ),
            .swipe(fromX: 0, fromY: 3199, toX: 1439, toY: 0, durationMs: 250)
        )
    }

    func testEqualSizesScaleToTheIdentity() {
        for (x, y) in [(0, 0), (539, 1199), (1079, 2399)] {
            XCTAssertEqual(
                PhysicalInput.scaled(
                    .tap(x: Int32(x), y: Int32(y)),
                    videoWidth: 1080, videoHeight: 2400,
                    displayWidth: 1080, displayHeight: 2400
                ),
                .tap(x: Int32(x), y: Int32(y))
            )
        }
    }

    // MARK: - Control messages

    func testContactsBecomeTouchEventsWithTheVideoSize() {
        let messages = PhysicalInput.controlMessages(
            forContacts: [
                TouchCommand(phase: .down, x: 10, y: 20, id: 0),
                TouchCommand(phase: .move, x: -5, y: 9_999, id: 3),
                TouchCommand(phase: .up, x: 30, y: 40, id: 0),
            ],
            videoWidth: 1080,
            videoHeight: 2400
        )

        XCTAssertEqual(messages, [
            .injectTouch(
                action: .down, pointerID: 0,
                position: ScrcpyPosition(x: 10, y: 20, screenWidth: 1080, screenHeight: 2400),
                pressure: 1
            ),
            .injectTouch(
                action: .move, pointerID: 3,
                position: ScrcpyPosition(x: 0, y: 2399, screenWidth: 1080, screenHeight: 2400),
                pressure: 1
            ),
            .injectTouch(
                action: .up, pointerID: 0,
                position: ScrcpyPosition(x: 30, y: 40, screenWidth: 1080, screenHeight: 2400),
                pressure: 0
            ),
        ])
    }

    func testContactsNeedAVideoSize() {
        XCTAssertEqual(
            PhysicalInput.controlMessages(
                forContacts: [TouchCommand(phase: .down, x: 1, y: 1)],
                videoWidth: 0,
                videoHeight: 0
            ),
            []
        )
    }

    /// Stage contact ids never collide with scrcpy's reserved mouse and
    /// finger ids (-1, -2, -3).
    func testPointerIDsNeverHitTheReservedIDs() {
        XCTAssertEqual(PhysicalInput.pointerID(forContact: 0), 0)
        XCTAssertEqual(PhysicalInput.pointerID(forContact: 2), 2)
        XCTAssertEqual(PhysicalInput.pointerID(forContact: -1), 0xFFFF_FFFF)
        XCTAssertNotEqual(PhysicalInput.pointerID(forContact: -1), ScrcpyControl.pointerIDMouse)
    }

    func testKeyboardControlMessages() {
        XCTAssertEqual(PhysicalInput.controlMessages(forKeyboard: .specialKey(51)), [
            .injectKeycode(action: .down, keycode: 67),
            .injectKeycode(action: .up, keycode: 67),
        ])
        XCTAssertEqual(PhysicalInput.controlMessages(forKeyboard: .specialKey(9_999)), [])
        XCTAssertEqual(
            PhysicalInput.controlMessages(forKeyboard: .text("it's 5 $")),
            [.injectText("it's 5 $")]
        )
        XCTAssertEqual(PhysicalInput.controlMessages(forKeyboard: .text("\u{7}")), [])
        XCTAssertEqual(PhysicalInput.controlMessages(forKeyboard: .text("")), [])
    }

    /// INJECT_TEXT types through the device's virtual key map, which drops
    /// the Turkish letters (and anything else it cannot map) without an
    /// error; such text is pasted through the clipboard instead.
    func testNonASCIITextIsPasted() {
        XCTAssertEqual(
            PhysicalInput.controlMessages(forKeyboard: .text("Işık çiçeği")),
            [.setClipboard(sequence: 0, paste: true, text: "Işık çiçeği")]
        )
        XCTAssertEqual(
            PhysicalInput.controlMessages(forKeyboard: .text("line1\nline2")),
            [.setClipboard(sequence: 0, paste: true, text: "line1\nline2")]
        )
    }

    func testLongASCIITextIsSplitAtTheMessageCap() {
        let messages = PhysicalInput.controlMessages(
            forKeyboard: .text(String(repeating: "q", count: 700))
        )
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages.first, .injectText(String(repeating: "q", count: 300)))
        XCTAssertEqual(messages.last, .injectText(String(repeating: "q", count: 100)))
    }

    // MARK: - Pointer filter

    /// Android drops a move or release for a pointer that never went down;
    /// the control socket must never send one.
    func testPointerFilterDropsMovesAndReleasesWithoutADown() {
        var filter = PhysicalPointerFilter()
        XCTAssertEqual(filter.accept([TouchCommand(phase: .move, x: 1, y: 1)]).count, 0)
        XCTAssertEqual(filter.accept([TouchCommand(phase: .up, x: 1, y: 1)]).count, 0)

        let down = filter.accept([TouchCommand(phase: .down, x: 2, y: 2)])
        XCTAssertEqual(down.map(\.phase), [.down])
        XCTAssertEqual(filter.accept([TouchCommand(phase: .move, x: 3, y: 3)]).map(\.phase), [.move])
        XCTAssertEqual(filter.accept([TouchCommand(phase: .up, x: 3, y: 3)]).map(\.phase), [.up])
        XCTAssertEqual(filter.accept([TouchCommand(phase: .up, x: 3, y: 3)]).count, 0, "a second release")
    }

    func testPointerFilterTurnsARepeatedDownIntoAMoveAndTracksPointersApart() {
        var filter = PhysicalPointerFilter()
        _ = filter.accept([TouchCommand(phase: .down, x: 1, y: 1, id: 1)])

        let frame = filter.accept([
            TouchCommand(phase: .down, x: 5, y: 5, id: 1),
            TouchCommand(phase: .down, x: 9, y: 9, id: 2),
        ])
        XCTAssertEqual(frame.map(\.phase), [.move, .down])
        XCTAssertEqual(frame.map(\.id), [1, 2])

        let release = filter.accept([
            TouchCommand(phase: .up, x: 5, y: 5, id: 1),
            TouchCommand(phase: .up, x: 9, y: 9, id: 2),
        ])
        XCTAssertEqual(release.map(\.phase), [.up, .up])
    }

    func testBackFallsBackToKeycodeBack() {
        XCTAssertEqual(
            PhysicalInput.backArguments(serial: "S"),
            ["-s", "S", "shell", "input", "keyevent", "4"]
        )
    }
}
