import DeviceHubProKit
import SwiftUI

/// One part of a foldable simulator's capsule, left to right.
enum FoldPillItem: Equatable {
    case rotate
    /// View ▸ Show 3D Model (`AppPreferences.showDeviceModel`): offered
    /// where Xcode ships the device's model.
    case modelToggle
    case divider
    case posture(SimulatorFoldPostureChoice)
    case hingeSlider

    /// Its width in the capsule, in points.
    var width: CGFloat {
        switch self {
        case .rotate, .modelToggle, .posture:
            ParityMetrics.pillButtonWidth
        case .divider:
            ParityMetrics.foldPillDividerWidth + ParityMetrics.foldPillDividerGap * 2
        case .hingeSlider:
            FoldPillSlider.width + ParityMetrics.foldPillSliderInset * 2
        }
    }
}

/// What a foldable simulator's capsule holds, widest first. The widest is
/// Rotate, the 3D button, a divider, Closed, Partially Open, Open, Laptop,
/// Tent, a divider and the hinge slider, always in view (Device Hub shows
/// the slider only while Option is held, in place of the postures: ours
/// stays, a deliberate departure). Where the stage is too narrow for it
/// (`FoldPillFitting`) the capsule gives up Laptop and Tent, then the
/// slider, then the 3D button; the last is Device Hub's own capsule.
enum FoldPillLayout: CaseIterable, Equatable {
    case full
    case withoutHeldPostures
    case withoutSlider
    case posturesOnly

    var showsModelToggle: Bool { self != .posturesOnly }

    /// Whether the 3D button is offered at all: where Xcode ships the
    /// device's model and the stage draws the device in its frame (View ▸
    /// Show Device Frame; without it there is no model to show or hide, and
    /// a button that changes nothing would be a dead control).
    static func offersModelToggle(hasModel: Bool, showsDeviceFrame: Bool) -> Bool {
        hasModel && showsDeviceFrame
    }

    var showsHeldPostures: Bool { self == .full }

    var showsSlider: Bool { self == .full || self == .withoutHeldPostures }

    /// The capsule's parts, left to right. The 3D button is there only when
    /// the model is (`offersModelToggle`).
    func items(offersModelToggle: Bool) -> [FoldPillItem] {
        var items: [FoldPillItem] = [.rotate]
        if showsModelToggle, offersModelToggle { items.append(.modelToggle) }
        items.append(.divider)
        items += SimulatorFoldPostureChoice.pillOrder
            .filter { showsHeldPostures || $0.isPreset }
            .map { .posture($0) }
        if showsSlider { items += [.divider, .hingeSlider] }
        return items
    }

    /// The capsule's width: its parts and the padding either side.
    func width(offersModelToggle: Bool) -> CGFloat {
        items(offersModelToggle: offersModelToggle).reduce(ParityMetrics.pillCapsulePadding * 2) { $0 + $1.width }
    }
}

extension SimulatorFoldPostureChoice {
    /// One of Device Hub's three, not Laptop or Tent.
    var isPreset: Bool {
        if case .preset = self { return true }
        return false
    }
}

/// How much of the whole pill is drawn at one stage width, widest first
/// (`FoldPillFitting` takes the first that fits). The first capsule is
/// Home, Screenshot and Record (108.5 pt), with Save Replay where it is
/// offered (142.5 pt); the capsules sit 8 pt apart.
///
/// With the capsule's widths (354.3, 286.3, 180.4 and 146.4 pt) the pill is
/// 504.8 pt with Save Replay and the full capsule, 436.8 without Laptop and
/// Tent, 330.9 without the slider, 296.9 postures only, and 262.9 without
/// Save Replay. The narrowest main window with the inspector open leaves the
/// stage 349 pt (`NarrowWindowBehavior`): the pill drops the slider there. Under
/// 262.9 pt (the compact window opens 258 pt wide, down to 180) the last
/// tier scales it down to fit.
///
/// What each tier holds is decided here (`showsReplay`, `width`), and the
/// pill draws what these say, so the tests that pin the widths pin what is
/// drawn.
struct FoldPillTier: Equatable {
    let layout: FoldPillLayout
    /// Whether Save Replay stays in the first capsule where it is offered:
    /// it is also in Record's right-click menu.
    let keepsReplay: Bool
    /// Whether the row is scaled down to the width it is given.
    var scalesToFit = false

    /// The pill as it is drawn when there is room, and for any device that
    /// has no fold capsule.
    static let widest = FoldPillTier(layout: .full, keepsReplay: true)
    static let withoutHeldPostures = FoldPillTier(layout: .withoutHeldPostures, keepsReplay: true)
    static let withoutSlider = FoldPillTier(layout: .withoutSlider, keepsReplay: true)
    static let posturesOnly = FoldPillTier(layout: .posturesOnly, keepsReplay: true)
    static let withoutReplay = FoldPillTier(layout: .posturesOnly, keepsReplay: false)
    static let scaled = FoldPillTier(layout: .posturesOnly, keepsReplay: false, scalesToFit: true)

    /// Widest first.
    static let narrowing: [FoldPillTier] = [
        .widest, .withoutHeldPostures, .withoutSlider, .posturesOnly, .withoutReplay, .scaled,
    ]

    /// Whether the first capsule draws Save Replay: where the device offers
    /// it and the tier keeps it.
    func showsReplay(offered: Bool) -> Bool { offered && keepsReplay }

    /// The first capsule's width: Home, Screenshot and Record, and Save
    /// Replay where `showsReplay`, and the padding either side.
    func mainCapsuleWidth(offersReplay: Bool) -> CGFloat {
        let buttons = showsReplay(offered: offersReplay) ? 4 : 3
        return ParityMetrics.pillButtonWidth * CGFloat(buttons) + ParityMetrics.pillCapsulePadding * 2
    }

    /// The whole pill's natural width: both capsules and the space between.
    func width(offersModelToggle: Bool, offersReplay: Bool) -> CGFloat {
        mainCapsuleWidth(offersReplay: offersReplay) + ParityMetrics.pillSpacing
            + layout.width(offersModelToggle: offersModelToggle)
    }
}

/// Draws a foldable simulator's pill in the widest tier that fits the width
/// it is offered (`FoldPillTier.narrowing`): `row` builds the whole pill for
/// one tier. `ViewThatFits` measures each row's ideal width; the last tier
/// takes any width, scaled down to it. `offersModelToggle` and
/// `offersReplay` say what the pill holds, for the width that tier is
/// scaled from.
struct FoldPillFitting<Row: View>: View {
    let offersModelToggle: Bool
    let offersReplay: Bool
    @ViewBuilder let row: (FoldPillTier) -> Row

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(FoldPillTier.narrowing.enumerated()), id: \.offset) { _, tier in
                if tier.scalesToFit {
                    ScaledToFitWidth(
                        naturalWidth: tier.width(offersModelToggle: offersModelToggle, offersReplay: offersReplay)
                    ) { row(tier) }
                } else {
                    row(tier)
                }
            }
        }
    }
}

/// Its content at its own width, scaled down about its centre when the width
/// it is offered is less; a press on the scaled content lands where it is
/// drawn. `naturalWidth` is the content's width before it is measured, so
/// that the first frame is already scaled to fit and not drawn once at full
/// width, overflowing; the measured width takes over after.
struct ScaledToFitWidth<Content: View>: View {
    let naturalWidth: CGFloat
    @ViewBuilder let content: Content
    @State private var measuredWidth: CGFloat?

    /// The scale that fits `natural` into `available`: 1 unless it is wider.
    static func scale(natural: CGFloat, available: CGFloat) -> CGFloat {
        guard natural > 0, available > 0, natural > available else { return 1 }
        return available / natural
    }

    var body: some View {
        GeometryReader { proxy in
            content
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
                .scaleEffect(Self.scale(natural: measuredWidth ?? naturalWidth, available: proxy.size.width))
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: ParityMetrics.pillHeight)
    }
}
