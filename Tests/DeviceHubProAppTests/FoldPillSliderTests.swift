import AppKit
import SwiftUI
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The foldable simulator pill's hinge slider (Device Hub 27.1's, kept in view
/// all the time at the capsule's right end), its 3D button and the tiers it
/// narrows through, how a drag maps to the hinge, what a drag sends, and
/// Rotate's direction.
@MainActor
final class FoldPillSliderTests: XCTestCase {
    func testOptionBitAloneOrWithOthers() {
        XCTAssertTrue(OptionKeyMonitor.isOptionHeld([.option]))
        XCTAssertTrue(OptionKeyMonitor.isOptionHeld([.option, .shift]))
        XCTAssertFalse(OptionKeyMonitor.isOptionHeld([]))
        XCTAssertFalse(OptionKeyMonitor.isOptionHeld([.command, .shift]))
    }

    func testAFoldablesRotateTurnsRightAndLeftWithOption() {
        XCTAssertFalse(FoldPillSlider.rotatesLeft(optionHeld: false))
        XCTAssertTrue(FoldPillSlider.rotatesLeft(optionHeld: true))
    }

    // MARK: - Layout

    private let closed = FoldPillItem.posture(.preset(.closed))
    private let partlyOpen = FoldPillItem.posture(.preset(.halfOpened))
    private let open = FoldPillItem.posture(.preset(.opened))
    private let laptop = FoldPillItem.posture(.held(.laptop))
    private let tent = FoldPillItem.posture(.held(.tent))

    /// The capsule reads Rotate, 3D, a divider, Closed, Partially Open, Open,
    /// Laptop, Tent, a divider and the slider: the slider is not behind
    /// Option, and sits at the right end.
    func testTheWidestCapsuleEndsWithTheSliderAndHasTheModelButtonAfterRotate() {
        XCTAssertEqual(
            FoldPillLayout.full.items(offersModelToggle: true),
            [.rotate, .modelToggle, .divider, closed, partlyOpen, open, laptop, tent, .divider, .hingeSlider]
        )
        XCTAssertEqual(FoldPillLayout.allCases.first, .full)
    }

    func testTheModelButtonIsOnlyThereWithAModel() {
        for layout in FoldPillLayout.allCases {
            XCTAssertFalse(layout.items(offersModelToggle: false).contains(.modelToggle), "\(layout)")
        }
        XCTAssertEqual(
            FoldPillLayout.full.items(offersModelToggle: false),
            [.rotate, .divider, closed, partlyOpen, open, laptop, tent, .divider, .hingeSlider]
        )
        XCTAssertTrue(FoldPillLayout.full.items(offersModelToggle: true).contains(.modelToggle))
        XCTAssertTrue(FoldPillLayout.withoutSlider.items(offersModelToggle: true).contains(.modelToggle))
    }

    /// Narrower capsules give up Laptop and Tent, then the slider, then the
    /// 3D button, in that order; Rotate and Device Hub's three postures stay.
    func testTheCapsuleNarrowsThroughLaptopAndTentThenTheSliderThenTheModelButton() {
        XCTAssertEqual(
            FoldPillLayout.withoutHeldPostures.items(offersModelToggle: true),
            [.rotate, .modelToggle, .divider, closed, partlyOpen, open, .divider, .hingeSlider]
        )
        XCTAssertEqual(
            FoldPillLayout.withoutSlider.items(offersModelToggle: true),
            [.rotate, .modelToggle, .divider, closed, partlyOpen, open]
        )
        XCTAssertEqual(
            FoldPillLayout.posturesOnly.items(offersModelToggle: true),
            [.rotate, .divider, closed, partlyOpen, open]
        )
        for layout in FoldPillLayout.allCases {
            let items = layout.items(offersModelToggle: true)
            XCTAssertEqual(items.first, .rotate)
            XCTAssertTrue(items.contains(closed) && items.contains(partlyOpen) && items.contains(open), "\(layout)")
        }
    }

    func testTheSliderIsInEveryLayoutThatHasRoomForIt() {
        let withSlider = FoldPillLayout.allCases.filter { $0.items(offersModelToggle: true).contains(.hingeSlider) }
        XCTAssertEqual(withSlider, [.full, .withoutHeldPostures])
        for layout in withSlider {
            XCTAssertEqual(layout.items(offersModelToggle: true).last, .hingeSlider)
        }
    }

    func testTheCapsuleWidthsAreTheirPartsAndPadding() {
        func width(_ layout: FoldPillLayout) -> Double {
            Double(layout.width(offersModelToggle: true))
        }
        XCTAssertEqual(width(.full), 354.3, accuracy: 0.001)
        XCTAssertEqual(width(.withoutHeldPostures), 286.3, accuracy: 0.001)
        XCTAssertEqual(width(.withoutSlider), 180.4, accuracy: 0.001)
        XCTAssertEqual(width(.posturesOnly), 146.4, accuracy: 0.001)
        // The widths fall as the layouts narrow.
        let widths = FoldPillLayout.allCases.map(width)
        XCTAssertEqual(widths, widths.sorted(by: >))
        // The narrowest is Device Hub's 145.6 pt capsule (measured).
        XCTAssertEqual(width(.posturesOnly), 145.6, accuracy: 1)
    }

    func testAModelLessCapsuleIsOneButtonNarrower() {
        for layout in [FoldPillLayout.full, .withoutHeldPostures, .withoutSlider] {
            XCTAssertEqual(
                layout.width(offersModelToggle: true) - layout.width(offersModelToggle: false),
                ParityMetrics.pillButtonWidth
            )
        }
        XCTAssertEqual(
            FoldPillLayout.posturesOnly.width(offersModelToggle: true),
            FoldPillLayout.posturesOnly.width(offersModelToggle: false)
        )
    }

    /// The 3D button is for a device whose model Xcode ships and that the
    /// stage draws in its frame: with the frame off there is no model to show
    /// or hide, and a button that changes nothing is not offered.
    func testTheModelButtonNeedsAModelAndTheDeviceFrame() {
        XCTAssertTrue(FoldPillLayout.offersModelToggle(hasModel: true, showsDeviceFrame: true))
        XCTAssertFalse(FoldPillLayout.offersModelToggle(hasModel: true, showsDeviceFrame: false))
        XCTAssertFalse(FoldPillLayout.offersModelToggle(hasModel: false, showsDeviceFrame: true))
        XCTAssertFalse(FoldPillLayout.offersModelToggle(hasModel: false, showsDeviceFrame: false))
    }

    func testTheModelButtonsSymbolExists() {
        XCTAssertNotNil(NSImage(systemSymbolName: "view.3d", accessibilityDescription: nil))
    }

    // MARK: - Tiers

    func testTheTiersNarrowFromTheWidestToAScaledPill() {
        let tiers = FoldPillTier.narrowing
        XCTAssertEqual(tiers.first, .widest)
        XCTAssertEqual(tiers.map(\.layout), [.full, .withoutHeldPostures, .withoutSlider, .posturesOnly, .posturesOnly, .posturesOnly])
        XCTAssertEqual(tiers.map(\.keepsReplay), [true, true, true, true, false, false])
        XCTAssertEqual(tiers.map(\.scalesToFit), [false, false, false, false, false, true])
    }

    /// Save Replay is drawn where the device offers it and the tier keeps it.
    func testSaveReplayIsKeptOnlyByTheTiersThatKeepIt() {
        XCTAssertEqual(FoldPillTier.narrowing.map { $0.showsReplay(offered: true) }, [true, true, true, true, false, false])
        for tier in FoldPillTier.narrowing {
            XCTAssertFalse(tier.showsReplay(offered: false), "\(tier)")
        }
    }

    func testTheTierWidthsAreTheirCapsules() {
        func width(_ tier: FoldPillTier, model: Bool = true, replay: Bool = true) -> Double {
            Double(tier.width(offersModelToggle: model, offersReplay: replay))
        }
        XCTAssertEqual(width(.widest), 504.8, accuracy: 0.001)
        XCTAssertEqual(width(.withoutHeldPostures), 436.8, accuracy: 0.001)
        XCTAssertEqual(width(.withoutSlider), 330.9, accuracy: 0.001)
        XCTAssertEqual(width(.posturesOnly), 296.9, accuracy: 0.001)
        XCTAssertEqual(width(.withoutReplay), 262.9, accuracy: 0.001)
        XCTAssertEqual(width(.scaled), 262.9, accuracy: 0.001)
        let widths = FoldPillTier.narrowing.map { width($0) }
        XCTAssertEqual(widths, widths.sorted(by: >))
        // Without the replay button or the model there is a button less.
        XCTAssertEqual(width(.widest) - width(.widest, replay: false), 34, accuracy: 0.001)
        XCTAssertEqual(width(.widest) - width(.widest, model: false), 34, accuracy: 0.001)
        XCTAssertEqual(width(.posturesOnly) - width(.posturesOnly, model: false), 0, accuracy: 0.001)
    }

    func testScalingOnlyShrinks() {
        XCTAssertEqual(ScaledToFitWidth<EmptyView>.scale(natural: 262.9, available: 258), 258 / 262.9, accuracy: 1e-9)
        XCTAssertEqual(ScaledToFitWidth<EmptyView>.scale(natural: 262.9, available: 180), 180 / 262.9, accuracy: 1e-9)
        XCTAssertEqual(ScaledToFitWidth<EmptyView>.scale(natural: 262.9, available: 300), 1)
        XCTAssertEqual(ScaledToFitWidth<EmptyView>.scale(natural: 0, available: 258), 1)
        XCTAssertEqual(ScaledToFitWidth<EmptyView>.scale(natural: 262.9, available: 0), 1)
    }

    /// 262.9 pt of pill offered 180 pt (the compact window's least): the
    /// content is drawn across the whole width, scaled down about its
    /// centre, not clipped at either end. The first frame is already scaled
    /// (drawn before the content has been measured), not once at full width.
    func testTheScaledTierDrawsAllOfTheContentInTheWidthItIsGiven() throws {
        let width: CGFloat = 180
        let content = ScaledToFitWidth(naturalWidth: 262.9) {
            Color(red: 1, green: 0, blue: 0).frame(width: 262.9, height: ParityMetrics.pillHeight)
        }
        .frame(width: width)
        .background(Color.white)
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: width, height: ParityMetrics.pillHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        let middle = ParityMetrics.pillHeight / 2
        func assertScaledAndAcrossTheWidth(_ phase: String) throws {
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / width
            // Drawn (red, whichever space it lands in) rather than the white behind.
            func isRed(x: CGFloat, y: CGFloat) -> Bool {
                guard let color = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) else { return false }
                return color.redComponent > 0.6 && color.greenComponent < 0.6
            }
            XCTAssertTrue(isRed(x: 2, y: middle), "\(phase): the left end is drawn")
            XCTAssertTrue(isRed(x: width - 3, y: middle), "\(phase): the right end is drawn")
            XCTAssertTrue(isRed(x: width / 2, y: middle), phase)
            // Scaled to 180 / 262.9 = 0.685: 24.7 pt tall about the middle.
            XCTAssertFalse(isRed(x: width / 2, y: 2), "\(phase): the scaled content is shorter than the pill")
        }
        try assertScaledAndAcrossTheWidth("first frame")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try assertScaledAndAcrossTheWidth("measured")
    }

    // MARK: - The real pill

    private final class WidthBox {
        var width: CGFloat?
    }

    private static let narrowestStage = NarrowWindowBehavior.minimumWindowWidth - 272 - 260

    /// The width the real pill (`DeviceControlPill` with a foldable's capsule
    /// fixed) takes in a stage `offered` points wide: the width of the tier
    /// `FoldPillFitting` draws, the offered width when it is scaled.
    private func drawnWidth(offered: CGFloat, offersModelToggle: Bool = true, offersReplay: Bool = true) -> CGFloat? {
        let model = AppModel.testing()
        let box = WidthBox()
        let pill = DeviceControlPill(fixture: .init(offersModelToggle: offersModelToggle, offersReplay: offersReplay))
            .environment(model)
            .environment(model.workspace)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { box.width = $0 }
            .frame(maxWidth: offered, alignment: .leading)
        let host = NSHostingView(rootView: pill)
        host.frame = CGRect(x: 0, y: 0, width: offered, height: 60)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        // Until the width has been set and has stopped changing (a scaled
        // tier measures itself after its first frame), never a fixed wait.
        var last: CGFloat?
        var steady = 0
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, steady < 3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if let width = box.width, width == last { steady += 1 } else { steady = 0 }
            last = box.width
        }
        return box.width
    }

    /// What `FoldPillFitting` should draw at `offered` points: the first tier
    /// whose natural width fits, else the last (scaled to the width).
    private func expectedWidth(offered: CGFloat, offersModelToggle: Bool = true, offersReplay: Bool = true) -> (width: CGFloat, tier: FoldPillTier) {
        for tier in FoldPillTier.narrowing where !tier.scalesToFit {
            let natural = tier.width(offersModelToggle: offersModelToggle, offersReplay: offersReplay)
            if natural <= offered { return (natural, tier) }
        }
        return (offered, .scaled)
    }

    /// The widths the real pill takes follow the tiers' widths: every part
    /// each tier claims (the slider, the 3D button, Laptop and Tent, Save
    /// Replay) is in the drawn row, and nothing else, whichever tier the
    /// width allows. A tier that drew a part its width leaves out, or left
    /// one out, would sit between the widths below.
    func testTheRealPillDrawsTheWidestTierThatFits() throws {
        for offered in [920, 505, 500, 437, 430, Self.narrowestStage, 331, 320, 297, 290, 263, 258, 180] as [CGFloat] {
            let expected = expectedWidth(offered: offered)
            let drawn = try XCTUnwrap(drawnWidth(offered: offered), "\(offered)")
            XCTAssertEqual(Double(drawn), Double(expected.width), accuracy: 0.01, "at \(offered) pt, tier \(expected.tier)")
        }
    }

    func testTheRealPillGivesUpTheSliderBeforeTheModelButtonInTheNarrowestMainWindow() throws {
        XCTAssertEqual(Self.narrowestStage, 349)
        let expected = expectedWidth(offered: Self.narrowestStage)
        XCTAssertEqual(expected.tier, .withoutSlider)
        let drawn = try XCTUnwrap(drawnWidth(offered: Self.narrowestStage))
        XCTAssertEqual(Double(drawn), 330.9, accuracy: 0.01)
        // With the inspector closed the stage keeps the slider and the held postures.
        let wide = try XCTUnwrap(drawnWidth(offered: NarrowWindowBehavior.minimumWindowWidth - 272))
        XCTAssertEqual(Double(wide), 504.8, accuracy: 0.01)
    }

    /// The compact window opens 258 pt wide: Save Replay is given up before
    /// the pill is scaled, so it scales by 258 / 262.9, not by the width of
    /// a row that still holds the button.
    func testTheCompactWindowGivesUpSaveReplayThenScalesTheRest() throws {
        let drawn = try XCTUnwrap(drawnWidth(offered: 258))
        XCTAssertEqual(Double(drawn), 258, accuracy: 0.01)
        XCTAssertEqual(
            ScaledToFitWidth<EmptyView>.scale(
                natural: FoldPillTier.scaled.width(offersModelToggle: true, offersReplay: true), available: 258
            ),
            258 / 262.9, accuracy: 1e-4
        )
        // Offered 263 pt, the unscaled row without Save Replay fits.
        let fits = try XCTUnwrap(drawnWidth(offered: 263))
        XCTAssertEqual(Double(fits), 262.9, accuracy: 0.01)
    }

    func testWithoutAModelOrReplayTheRealPillFitsSooner() throws {
        for (model, replay, offered) in [
            (false, false, 450), (false, true, 410), (false, true, 400), (true, false, 470), (false, false, 263), (false, false, 258),
        ] as [(Bool, Bool, CGFloat)] {
            let expected = expectedWidth(offered: offered, offersModelToggle: model, offersReplay: replay)
            let drawn = try XCTUnwrap(drawnWidth(offered: offered, offersModelToggle: model, offersReplay: replay))
            XCTAssertEqual(
                Double(drawn), Double(expected.width), accuracy: 0.01,
                "model \(model), replay \(replay), at \(offered) pt, tier \(expected.tier)"
            )
        }
        // No 3D button (34 pt less) and no Save Replay (34 pt less).
        XCTAssertEqual(expectedWidth(offered: 450, offersModelToggle: false, offersReplay: false).tier, .widest)
        XCTAssertEqual(expectedWidth(offered: 410, offersModelToggle: false, offersReplay: true).tier, .withoutHeldPostures)
        XCTAssertEqual(expectedWidth(offered: 400, offersModelToggle: false, offersReplay: true).tier, .withoutSlider)
        // 108.5 + 8 + 146.4 = 262.9: the compact window's 258 pt scales it.
        XCTAssertEqual(expectedWidth(offered: 258, offersModelToggle: false, offersReplay: false).tier, .scaled)
    }

    /// Device Hub's slider: its three posture buttons less the inset either
    /// side, 84 pt for 180°.
    func testTheSliderIsDeviceHubsWidth() {
        let row = ParityMetrics.pillButtonWidth * CGFloat(PostureKind.allCases.count)
        XCTAssertEqual(row - ParityMetrics.foldPillSliderInset * 2, 84)
        XCTAssertEqual(FoldPillSlider.width, 84)
        XCTAssertEqual(FoldPillItem.hingeSlider.width, 102)
    }

    func testGlyphsFollowTheHeldOrientation() {
        // Resting pose and a half turn.
        XCTAssertFalse(FoldPostureGlyphs.isQuarterTurned(targetTurns: 0, restingTurns: 0))
        XCTAssertFalse(FoldPostureGlyphs.isQuarterTurned(targetTurns: 2, restingTurns: 0))
        XCTAssertFalse(FoldPostureGlyphs.isQuarterTurned(targetTurns: -3, restingTurns: 1))
        // A quarter turn either way, also from a resting pose that is turned.
        XCTAssertTrue(FoldPostureGlyphs.isQuarterTurned(targetTurns: 1, restingTurns: 0))
        XCTAssertTrue(FoldPostureGlyphs.isQuarterTurned(targetTurns: -1, restingTurns: 0))
        XCTAssertTrue(FoldPostureGlyphs.isQuarterTurned(targetTurns: 4, restingTurns: 1))

        let upright = [PostureKind.closed, .halfOpened, .opened].map {
            FoldPostureGlyphs.name(of: $0, productClass: "V68", quarterTurned: false)
        }
        XCTAssertEqual(upright, ["v68_Closed", "v68_HalfOpen_Landscape", "v68_Open"])
        let turned = [PostureKind.closed, .halfOpened, .opened].map {
            FoldPostureGlyphs.name(of: $0, productClass: "V68", quarterTurned: true)
        }
        XCTAssertEqual(turned, ["v68_Closed", "v68_HalfOpen_Portrait", "v68_Open"])

        XCTAssertEqual(FoldPostureGlyphs.rotationDegrees(of: .closed, quarterTurned: false), 0)
        XCTAssertEqual(FoldPostureGlyphs.rotationDegrees(of: .halfOpened, quarterTurned: false), 0)
        XCTAssertEqual(FoldPostureGlyphs.rotationDegrees(of: .opened, quarterTurned: false), 0)
        XCTAssertEqual(FoldPostureGlyphs.rotationDegrees(of: .closed, quarterTurned: true), 90)
        XCTAssertEqual(FoldPostureGlyphs.rotationDegrees(of: .halfOpened, quarterTurned: true), 0)
        XCTAssertEqual(FoldPostureGlyphs.rotationDegrees(of: .opened, quarterTurned: true), 90)
        XCTAssertEqual(FoldPostureGlyphs.rotateName, "rotate.device.right")
        XCTAssertEqual(FoldPostureGlyphs.rotateLeftName, "rotate.device.left")
    }

    func testADragSendsEachWholeDegreeOnce() {
        var coalescer = HingeCoalescer()
        XCTAssertEqual(coalescer.next(10.2), 10)
        XCTAssertNil(coalescer.next(10.4))
        XCTAssertEqual(coalescer.next(10.6), 11)
        XCTAssertNil(coalescer.next(.nan))
        XCTAssertEqual(coalescer.next(500), 180)
        XCTAssertNil(coalescer.next(180))
        XCTAssertEqual(coalescer.next(-4), 0)
        coalescer.reset()
        XCTAssertEqual(coalescer.next(0), 0)
    }
}
