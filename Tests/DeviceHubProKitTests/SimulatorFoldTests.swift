import XCTest
@testable import DeviceHubProKit

/// A foldable simulator: iPhone Duo's two panels from its `capabilities.plist`,
/// the panel a hinge angle lights, the presets and the hinge event.
///
/// The plist is Apple's and is never copied into the repository. The
/// dictionary below carries only the keys the parser reads, with the values
/// of `/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone
/// Duo.simdevicetype/Contents/Resources/capabilities.plist` (Xcode 27.1 RC
/// 27A9275, read with `plutil -p` on 2026-10-09). The thresholds and the
/// event were established against that Xcode's CoreSimulator 1174.9.2 with
/// iPhone Duo on iOS 27.1 (24A94232), `DeviceHubProSimBridgeSmoke --avp`.
final class SimulatorFoldTests: XCTestCase {
    /// iPhone Duo: the outer 1398 × 2034 @3x panel (screen 1, square-ish
    /// corners on the hinge side), the inner 2007 × 2853 @3x one (screen 3,
    /// turned 270°), then a TV-out and a CarPlay output, which are not panels.
    static var iPhoneDuo: [String: Any] { [
        "DeviceCornerRadius": 59,
        "DeviceSupportsDynamicIsland": true,
        "displays": [
            [
                "chromeIdentifier": "com.apple.dt.devicekit.chrome.phone15",
                "cornerRadiusLL": 8, "cornerRadiusLR": 59, "cornerRadiusUL": 8, "cornerRadiusUR": 59,
                "displayType": "integrated",
                "framebufferMaskIdentifier": "1C896A2B-F0D7-405C-8D0F-66E4B80AD044",
                "hasDigitizer": true,
                "hdpi": 460, "vdpi": 460,
                "height": 2034, "width": 1398, "scale": 3,
                "nativeRotation": 0,
                "screenID": 1,
            ],
            [
                "chromeIdentifier": "com.apple.dt.devicekit.chrome.phone14",
                "cornerRadiusLL": 55, "cornerRadiusLR": 55, "cornerRadiusUL": 55, "cornerRadiusUR": 55,
                "displayType": "integrated",
                "framebufferMaskIdentifier": "BF0DC480-5EE2-4EC1-B02B-C75E94759832",
                "hasDigitizer": true,
                "hdpi": 460, "vdpi": 460,
                "height": 2853, "width": 2007, "scale": 3,
                "nativeRotation": 270,
                "screenID": 3,
            ],
            ["displayType": "tvOut", "hasDigitizer": false, "height": 480, "width": 720, "scale": 1, "screenID": 2],
            ["displayType": "carPlay", "hasDigitizer": false, "height": 480, "width": 720, "scale": 1, "screenID": 4],
        ] as [[String: Any]],
    ] }

    func testBothPanelsAreReadInScreenOrder() throws {
        let panels = SimulatorDisplayProfile.panels(capabilities: Self.iPhoneDuo)
        XCTAssertEqual(panels.map(\.screenID), [1, 3])
        XCTAssertEqual(panels.map(\.chromeIdentifier), ["com.apple.dt.devicekit.chrome.phone15", "com.apple.dt.devicekit.chrome.phone14"])
        XCTAssertEqual(panels.map(\.nativeRotation), [0, 270])
        XCTAssertEqual(panels[1].width, 2007)
        XCTAssertEqual(panels[1].framebufferMaskIdentifier, "BF0DC480-5EE2-4EC1-B02B-C75E94759832")
        XCTAssertEqual(panels[0].topLeftRadius, 8)
        XCTAssertEqual(panels[0].topRightRadius, 59)
    }

    func testTheMainDisplayIsStillTheOuterPanel() throws {
        let main = try XCTUnwrap(SimulatorDisplayProfile.parse(capabilities: Self.iPhoneDuo))
        XCTAssertEqual(main.screenID, 1)
        XCTAssertEqual(main.width, 1398)
    }

    func testOnlyATwoPanelDeviceIsAFoldable() throws {
        let duo = try XCTUnwrap(SimulatorFoldPanels(panels: SimulatorDisplayProfile.panels(capabilities: Self.iPhoneDuo)))
        XCTAssertEqual(duo.outer.screenID, 1)
        XCTAssertEqual(duo.inner.screenID, 3)
        XCTAssertEqual(duo.profile(of: .inner).nativeRotation, 270)

        var onePanel = Self.iPhoneDuo
        onePanel["displays"] = [(Self.iPhoneDuo["displays"] as! [[String: Any]])[0]]
        XCTAssertNil(SimulatorFoldPanels(panels: SimulatorDisplayProfile.panels(capabilities: onePanel)))

        var noIDs = SimulatorDisplayProfile.panels(capabilities: Self.iPhoneDuo)
        noIDs[1].screenID = nil
        XCTAssertNil(SimulatorFoldPanels(panels: noIDs))
    }

    /// Opening from closed lights the inner panel past 90° (92° did, 90° did
    /// not); closing lights the outer one below 20° (18° did, 20° did not);
    /// in between the lit panel stays.
    func testTheLitPanelFollowsTheMeasuredHysteresis() {
        XCTAssertEqual(SimulatorFold.panel(afterAngle: 90, from: .outer), .outer)
        XCTAssertEqual(SimulatorFold.panel(afterAngle: 92, from: .outer), .inner)
        XCTAssertEqual(SimulatorFold.panel(afterAngle: 60, from: .outer), .outer)
        XCTAssertEqual(SimulatorFold.panel(afterAngle: 60, from: .inner), .inner)
        XCTAssertEqual(SimulatorFold.panel(afterAngle: 20, from: .inner), .inner)
        XCTAssertEqual(SimulatorFold.panel(afterAngle: 18, from: .inner), .outer)
        XCTAssertEqual(SimulatorFold.panel(afterAngle: 0, from: .inner), .outer)
        XCTAssertEqual(SimulatorFold.panel(afterAngle: 180, from: .outer), .inner)
    }

    /// A fold made elsewhere (Device Hub, a test) is read off the two
    /// panels' screenshots: the dark one is the unlit one. Two dark panels
    /// (a boot), two lit ones or a missing screenshot say nothing.
    func testTheLitPanelIsReadOffTheScreenshots() {
        XCTAssertEqual(SimulatorFold.litPanel(outer: .dark, inner: .homeScreen), .inner)
        XCTAssertEqual(SimulatorFold.litPanel(outer: .dark, inner: .bootScreen), .inner)
        XCTAssertEqual(SimulatorFold.litPanel(outer: .homeScreen, inner: .dark), .outer)
        XCTAssertNil(SimulatorFold.litPanel(outer: .dark, inner: .dark))
        XCTAssertNil(SimulatorFold.litPanel(outer: .homeScreen, inner: .homeScreen))
        XCTAssertNil(SimulatorFold.litPanel(outer: nil, inner: .homeScreen))
        XCTAssertNil(SimulatorFold.litPanel(outer: .dark, inner: nil))
    }

    /// Half is 110°, past the opening threshold, so the preset shows the
    /// inner panel from closed too; 180° is the only open-flat angle.
    func testPresetsAndTheirAngles() {
        XCTAssertEqual(SimulatorFold.angle(for: .closed), 0)
        XCTAssertEqual(SimulatorFold.angle(for: .halfOpened), 130, "Device Hub's half open")
        XCTAssertEqual(SimulatorFold.angle(for: .opened), 180)
        XCTAssertEqual(SimulatorFold.panel(afterAngle: SimulatorFold.angle(for: .halfOpened), from: .outer), .inner)
        for posture in PostureKind.allCases {
            XCTAssertEqual(SimulatorFold.posture(forAngle: SimulatorFold.angle(for: posture)), posture)
        }
        XCTAssertEqual(SimulatorFold.posture(forAngle: 179), .halfOpened)
        XCTAssertEqual(SimulatorFold.posture(forAngle: 19), .closed)
    }

    func testTheHingeEventIsTheAVPDictionaryInCompactXML() throws {
        guard case let .vendorDefined(page, usage, version, data) = SimulatorFold.hingeEvent(degrees: 180) else {
            return XCTFail("not a vendor-defined event")
        }
        XCTAssertEqual(page, 0xFF61)
        XCTAssertEqual(usage, 0x5B)
        XCTAssertEqual(version, 1)
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "<dict><key>source</key><string>hinge-slider-control</string><key>type</key><string>range</string><key>value</key><integer>180</integer></dict>"
        )
        XCTAssertLessThan(data.count, 200, "the relay refused a 329-byte payload")
    }

    func testTheHingeEventClampsAndRounds() throws {
        func value(_ degrees: Double) -> String? {
            guard case let .vendorDefined(_, _, _, data) = SimulatorFold.hingeEvent(degrees: degrees) else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            return text.components(separatedBy: "<integer>").last?.components(separatedBy: "</integer>").first
        }
        XCTAssertEqual(value(-5), "0")
        XCTAssertEqual(value(200), "180")
        XCTAssertEqual(value(89.6), "90")
        XCTAssertEqual(value(.nan), "0")
    }

    /// A burst of angles ends with the newest on the simulator, through one
    /// channel per simulator.
    func testTheSenderDeliversTheNewestAngleOnOneChannel() throws {
        let bridge = FakeSimulatorBridge()
        let sender = SimulatorFoldSender(bridge: bridge)
        let duo = SimulatorAddress(udid: "F01DAB1E-0000-0000-0000-000000000001")
        for degrees in stride(from: 0.0, through: 180, by: 15) {
            sender.send(degrees: degrees, to: duo)
        }
        sender.waitUntilIdle()
        XCTAssertEqual(bridge.inputs.count, 1)
        let sent = try XCTUnwrap(bridge.inputs.first?.sent)
        XCTAssertFalse(sent.isEmpty)
        XCTAssertEqual(sent.last, SimulatorFold.hingeEvent(degrees: 180))

        sender.send(degrees: 0, to: duo)
        sender.waitUntilIdle()
        XCTAssertEqual(bridge.inputs.count, 1, "the channel is kept")
        XCTAssertEqual(bridge.inputs.first?.sent.last, SimulatorFold.hingeEvent(degrees: 0))
        XCTAssertNil(sender.lastError(for: duo))

        sender.forget(duo)
        sender.send(degrees: 90, to: duo)
        sender.waitUntilIdle()
        XCTAssertEqual(bridge.inputs.count, 2, "a forgotten simulator gets a new channel")
    }

    /// Steps go out in order: a tent from the open device sweeps the hinge
    /// closed, holds the device on its side (landscape left, as its outer
    /// panel is seen), and sweeps it to 70°, each sweep from the angle sent
    /// last.
    func testTheSenderSendsStepsInOrder() throws {
        let bridge = FakeSimulatorBridge()
        let sender = SimulatorFoldSender(bridge: bridge)
        let duo = SimulatorAddress(udid: "F01DAB1E-0000-0000-0000-000000000001")
        sender.send(degrees: 180, to: duo)
        sender.send(SimulatorHeldPosture.tent.steps(from: .inner, angle: 180), to: duo)
        sender.waitUntilIdle(timeout: 10)
        let expected = [SimulatorFold.hingeEvent(degrees: 180)]
            + SimulatorFold.sweepAngles(from: 180, to: 0).map { SimulatorFold.hingeEvent(degrees: Double($0)) }
            + [SimulatorFold.poseEvent(.landscapeLeft)]
            + SimulatorFold.sweepAngles(from: 0, to: 70).map { SimulatorFold.hingeEvent(degrees: Double($0)) }
        XCTAssertEqual(try XCTUnwrap(bridge.inputs.first?.sent), expected)
        XCTAssertEqual(sender.lastAngle(for: duo), 70)
    }

    /// A sweep starts from the angle the simulator was sent last, not the one
    /// the app thought it was at.
    func testASweepStartsWhereTheHingeIs() throws {
        let bridge = FakeSimulatorBridge()
        let sender = SimulatorFoldSender(bridge: bridge)
        let duo = SimulatorAddress(udid: "F01DAB1E-0000-0000-0000-000000000001")
        sender.send(degrees: 40, to: duo)
        sender.send([.sweep(from: 0, to: 128)], to: duo)
        sender.waitUntilIdle(timeout: 10)
        let sent = try XCTUnwrap(bridge.inputs.first?.sent)
        XCTAssertEqual(sent.count, 1 + SimulatorFold.sweepAngles(from: 40, to: 128).count)
        XCTAssertEqual(sent.last, SimulatorFold.hingeEvent(degrees: 128))
    }

    /// Device Hub's presets: about 35 angles at 60 Hz over 0.6 s, easing into
    /// the target (fast first), whole degrees, never repeating one.
    func testASweepEasesIntoItsAngle() {
        let open = SimulatorFold.sweepAngles(from: 128, to: 180)
        XCTAssertEqual(open.last, 180)
        XCTAssertLessThanOrEqual(open.count, 36)
        XCTAssertGreaterThan(open.count, 20)
        XCTAssertEqual(open, open.sorted(), "monotonic")
        XCTAssertEqual(Set(open).count, open.count, "no repeats")
        let steps = zip(open, open.dropFirst()).map { $1 - $0 }
        XCTAssertGreaterThan(steps.first ?? 0, steps.last ?? 0, "faster at first")

        let close = SimulatorFold.sweepAngles(from: 180, to: 0)
        XCTAssertEqual(close.last, 0)
        XCTAssertEqual(close, close.sorted(by: >))
        XCTAssertEqual(SimulatorFold.sweepAngles(from: 90.2, to: 90), [], "already there")
        XCTAssertEqual(SimulatorFold.sweepAngles(from: 0, to: 1), [1])
    }

    /// A preset holds the device upright first, as Device Hub does, then
    /// sweeps from where the hinge is.
    func testAPresetHoldsTheDeviceUprightThenSweeps() {
        XCTAssertEqual(SimulatorFold.presetSteps(for: .halfOpened, from: 0), [.pose(.portrait), .sweep(from: 0, to: 130)])
        XCTAssertEqual(SimulatorFold.presetSteps(for: .closed, from: 130), [.pose(.portrait), .sweep(from: 130, to: 0)])
    }

    /// While a step is under way, a newer angle replaces one still waiting
    /// only when both light the same panel: an angle that crosses a
    /// threshold reaches the guest, as the app recorded it.
    func testAWaitingAngleThatCrossesAThresholdIsKept() throws {
        let bridge = FakeSimulatorBridge()
        let sender = SimulatorFoldSender(bridge: bridge)
        let duo = SimulatorAddress(udid: "F01DAB1E-0000-0000-0000-000000000001")
        sender.send([.pause(0.3)], to: duo)
        sender.send(degrees: 120, to: duo)
        sender.send(degrees: 60, to: duo)
        sender.send(degrees: 50, to: duo)
        sender.waitUntilIdle(timeout: 5)
        XCTAssertEqual(try XCTUnwrap(bridge.inputs.first?.sent), [
            SimulatorFold.hingeEvent(degrees: 120),
            SimulatorFold.hingeEvent(degrees: 50),
        ])
    }

    /// The angle recorded is the one sent: whole degrees, clamped.
    func testTheSentAngleAndItsZone() {
        XCTAssertEqual(SimulatorFold.sentAngle(90.3), 90)
        XCTAssertEqual(SimulatorFold.sentAngle(90.6), 91)
        XCTAssertEqual(SimulatorFold.sentAngle(-4), 0)
        XCTAssertEqual(SimulatorFold.sentAngle(.nan), 0)
        XCTAssertEqual(SimulatorFold.zone(of: 19.4), 0)
        XCTAssertEqual(SimulatorFold.zone(of: 19.6), 1, "sent as 20, which keeps the panel")
        XCTAssertEqual(SimulatorFold.zone(of: 90.3), 1, "sent as 90, which does not light the inner panel")
        XCTAssertEqual(SimulatorFold.zone(of: 91), 2)
    }

    /// iPhone Duo is held through CoreMotion's orientation picker, on the
    /// hinge's service, with the names Device Hub's Device ▸ Orientation
    /// sends (locationd took `pud`, `faceup` and `facedown`).
    func testThePoseEventIsThePickerDictionary() throws {
        guard case .vendorDefined(let page, let usage, let version, let data) = SimulatorFold.poseEvent(.landscapeLeft) else {
            return XCTFail("not a vendor-defined event")
        }
        XCTAssertEqual(page, 0xFF61)
        XCTAssertEqual(usage, 0x5B)
        XCTAssertEqual(version, 1)
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "<dict><key>source</key><string>orientation-picker-control</string>"
                + "<key>type</key><string>enum</string><key>value</key><string>landscape-left</string></dict>"
        )
        let names = SimulatorDevicePose.allCases.map { SimulatorFold.pickerValue(for: $0) }
        XCTAssertEqual(names, ["portrait", "pud", "landscape-left", "landscape-right", "faceup", "facedown"])
    }

    /// Lying flat holds no interface orientation: the stage keeps its pose.
    func testPosesAndInterfaceOrientations() {
        for orientation in SimulatorOrientation.allCases {
            XCTAssertEqual(SimulatorFold.orientation(for: SimulatorFold.pose(for: orientation)), orientation)
        }
        XCTAssertNil(SimulatorFold.orientation(for: .faceUp))
        XCTAssertNil(SimulatorFold.orientation(for: .faceDown))
    }

    /// A laptop lights the inner panel and a tent keeps the outer one: from
    /// the other panel the hinge first passes its threshold and waits.
    func testHeldPosturesSwitchThePanelFirst() {
        XCTAssertEqual(
            SimulatorHeldPosture.laptop.steps(from: .inner, angle: 128),
            [.pose(.landscapeRight), .sweep(from: 128, to: 105)]
        )
        XCTAssertEqual(
            SimulatorHeldPosture.laptop.steps(from: .outer, angle: 0),
            [.sweep(from: 0, to: 180), .pause(0.4), .pose(.landscapeRight), .sweep(from: 180, to: 105)]
        )
        XCTAssertEqual(SimulatorHeldPosture.tent.steps(from: .outer, angle: 0), [.pose(.landscapeLeft), .sweep(from: 0, to: 70)])
        XCTAssertEqual(
            SimulatorHeldPosture.tent.steps(from: .inner, angle: 180),
            [.sweep(from: 180, to: 0), .pause(0.4), .pose(.landscapeLeft), .sweep(from: 0, to: 70)]
        )
        for posture in SimulatorHeldPosture.allCases {
            XCTAssertEqual(SimulatorFold.panel(afterAngle: posture.angle, from: posture.panel), posture.panel)
        }
    }

    func testTheFoldBookKeepsTheOrientation() {
        var book = SimulatorFoldBook()
        book.note(udid: "A", pose: .landscapeRight)
        XCTAssertTrue(book.note(udid: "A", angle: 180))
        XCTAssertEqual(
            book.record(of: "A"),
            SimulatorFoldRecord(angle: 180, panel: .inner, orientation: .landscapeRight, pose: .landscapeRight)
        )
        book.note(udid: "A", pose: .faceUp)
        XCTAssertEqual(book.record(of: "A").orientation, .landscapeRight, "lying flat keeps the interface orientation")
        XCTAssertEqual(book.record(of: "A").pose, .faceUp)
        book.note(udid: "A", pose: .portrait)
        XCTAssertEqual(book.record(of: "A").angle, 180)
        XCTAssertEqual(book.record(of: "A").orientation, .portrait)
    }

    /// A fold holds for the boot it was recorded in: kept on disk with that
    /// boot, kept by a listing that shows the same boot, forgotten by one
    /// that shows another boot or no boot at all. A fold whose boot is not
    /// known is not kept on disk.
    func testTheFoldBookHoldsForOneBoot() throws {
        let boot = Date(timeIntervalSinceReferenceDate: 813_000_000)
        let later = boot.addingTimeInterval(600)
        var book = SimulatorFoldBook()
        book.note(udid: "A", angle: 180, bootedAt: boot)
        book.note(udid: "A", pose: .faceUp, bootedAt: boot)
        book.note(udid: "B", angle: 180)

        let restored = try JSONDecoder().decode(SimulatorFoldBook.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(restored.records, ["A": SimulatorFoldRecord(angle: 180, panel: .inner, pose: .faceUp)])
        XCTAssertEqual(restored.boots, ["A": boot])

        var same = restored
        same.keep(only: ["A": boot])
        XCTAssertEqual(same.record(of: "A").panel, .inner, "the simulator stayed booted while the app was closed")

        var rebooted = restored
        rebooted.keep(only: ["A": later])
        XCTAssertEqual(rebooted.record(of: "A"), .closed, "booted again: it boots closed")
        XCTAssertTrue(rebooted.boots.isEmpty)

        var shutDown = restored
        shutDown.keep(only: [:])
        XCTAssertEqual(shutDown.record(of: "A"), .closed)

        var unknown = book
        unknown.keep(only: ["B": nil, "A": boot])
        XCTAssertEqual(unknown.record(of: "B").panel, .inner, "a boot the listing did not give keeps the fold in this run")
        unknown.keep(only: ["B": later])
        XCTAssertEqual(unknown.boots["B"], later, "stamped with the first boot a listing gives")

        // Noting in a new boot starts from closed, as the simulator does.
        var noted = restored
        XCTAssertFalse(noted.note(udid: "A", angle: 60, bootedAt: later), "60° from closed keeps the outer panel")
        XCTAssertEqual(noted.record(of: "A"), SimulatorFoldRecord(angle: 60, panel: .outer))
        XCTAssertEqual(noted.boots["A"], later)
    }

    func testTheInnerPanelRestsTurnedClockwise() throws {
        let duo = try XCTUnwrap(SimulatorFoldPanels(panels: SimulatorDisplayProfile.panels(capabilities: Self.iPhoneDuo)))
        XCTAssertEqual(SimulatorFold.restingRotation(of: duo.inner), .clockwise)
        XCTAssertEqual(SimulatorFold.restingRotation(of: duo.outer), .upright)
    }

    /// A simulator never moved is closed; the book follows the hysteresis
    /// and says when the lit panel changed; a reboot forgets it.
    func testTheFoldBook() {
        var book = SimulatorFoldBook()
        XCTAssertEqual(book.record(of: "A"), .closed)
        XCTAssertFalse(book.note(udid: "A", angle: 60), "60° from closed keeps the outer panel")
        XCTAssertTrue(book.note(udid: "A", angle: 180))
        XCTAssertEqual(book.record(of: "A"), SimulatorFoldRecord(angle: 180, panel: .inner))
        XCTAssertFalse(book.note(udid: "A", angle: 30), "30° from open keeps the inner panel")
        XCTAssertTrue(book.note(udid: "A", angle: 0))
        XCTAssertEqual(book.record(of: "A").panel, .outer)

        book.note(udid: "A", angle: 180)
        book.note(udid: "B", angle: 180)
        book.keep(only: ["B": nil])
        XCTAssertEqual(book.record(of: "A"), .closed, "A shut down")
        XCTAssertEqual(book.record(of: "B").panel, .inner)
    }

    func testTheKillSwitch() {
        XCTAssertTrue(SimulatorFold.isDisabled(environment: [SimulatorFold.disableVariable: "1"]))
        XCTAssertFalse(SimulatorFold.isDisabled(environment: [:]))
        XCTAssertFalse(SimulatorFold.isDisabled(environment: [SimulatorFold.disableVariable: "0"]))
    }
}
