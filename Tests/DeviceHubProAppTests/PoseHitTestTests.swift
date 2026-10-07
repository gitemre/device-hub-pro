import XCTest
import SwiftUI
@testable import DeviceHubProKit
@testable import DeviceHubProApp

/// The gate for the device frame's hardware-button hotspots (Tier 2): small
/// AppKit views placed in the framed stage's composition the way the video
/// is (`FramedMirrorView.videoLayer`'s spacers, since representables ignore
/// `.offset`), inside `PosePresentation`, are found by the window's
/// hit-testing in every rest pose and see a click where it was aimed.
///
/// SwiftUI gestures cannot be driven by synthetic events in an offscreen
/// window, so hotspots that tests can press are `NSView`s; they only work if
/// a click reaches them through the view the pose wrapper turns. The
/// composition has the shape the buttons need: the layout box plus a
/// symmetric pad for the buttons' hover travel (so the device's centre does
/// not move), clipped to the layout box extended by the pad on the right
/// only. Its zones: the screen, two that straddle the layout box's right
/// edge as a real hotspot does, one wholly in the pad outside the layout
/// box, and one in the pad near the device's bottom end, which in landscape
/// lies outside the stage's frame before the wrapper turns it.
///
/// Generated input, not device output: a portrait layout of 1408x2965 units
/// (the size of the `pixel_10_pro` skin's layout) and hand-placed zones.
///
/// Hosted at a forced backing scale (`ScaledTestWindow`), 1x and 2x,
/// whatever the display the tests run on; the pixel grid, the grid offset
/// and the tolerances follow the hosting window's scale.
@MainActor
final class PoseHitTestTests: XCTestCase {
    private static let stage = CGSize(width: 1300, height: 866)
    /// The backing scales the gate runs at.
    private static let scales: [CGFloat] = [1, 2]
    /// The same stage one backing pixel wider, as in `PosedStageTests`: a
    /// quarter turn about its centre lands half a pixel off the grid unless
    /// the wrapper moves it back (`PoseFit.pixelGridOffset`), which the
    /// mapping below then has to follow.
    private static func oddStage(scale: CGFloat) -> CGSize {
        CGSize(width: stage.width + 1 / scale, height: stage.height)
    }
    private static let native = CGSize(width: 1408, height: 2965)
    /// The pad on each side of the layout box, points.
    private static let pad: CGFloat = 7

    /// For each rest pose (`StagePoseAnimator` rests at −90° per quarter
    /// turn) and each zone: the zone's centre, mapped through the pose into
    /// the window, hit-tests to the zone's own view and converts back to
    /// within one backing pixel of its centre; a point 2 pt off each of its
    /// edges hit-tests to some other view.
    ///
    /// One backing pixel because SwiftUI puts each edge of each view on the
    /// pixel grid (half a point at 1x, a quarter at 2x): the zone's own
    /// centre can move by half a pixel, and the composition it lies in by
    /// another half, and at 180° the two add up.
    func testHotspotsAreHitWhereTheyAreDrawnInEveryRestPose() async throws {
        for scale in Self.scales {
            for stage in [Self.stage, Self.oddStage(scale: scale)] {
                try await assertHotspots(stage: stage, scale: scale)
            }
        }
    }

    private func assertHotspots(stage: CGSize, scale: CGFloat) async throws {
        let composition = { (angle: Double) in
            HotspotComposition(angle: angle, stage: stage, native: Self.native, pad: Self.pad)
        }
        let host = NSHostingView(rootView: HotspotStage(composition: composition(0)))
        let window = ScaledTestWindow.hosting(host, size: stage, scale: scale)
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(window.backingScaleFactor, scale)
        let pixel = 1 / window.backingScaleFactor

        for turns in 0..<4 {
            let angle = Double(-90 * turns)
            let posed = composition(angle)
            host.rootView = HotspotStage(composition: posed)
            // SwiftUI applies the new pose on its next update.
            await waitUntil("\(stage) at \(scale)x: the stage turned to \(angle)°") {
                zoneView(named: "screen", in: host).map { abs(remainder(poseAngle(of: $0) - angle, 360)) < 1e-6 } ?? false
            }
            host.layoutSubtreeIfNeeded()

            for zone in posed.zones {
                let at = "\(stage) at \(scale)x, \(angle)°, zone \(zone.name)"
                let view = try XCTUnwrap(zoneView(named: zone.name, in: host), at)
                let centre = windowPoint(
                    CGPoint(x: zone.rect.midX, y: zone.rect.midY),
                    composition: posed.size,
                    angle: angle,
                    stage: stage,
                    pixelScale: window.backingScaleFactor
                )
                let hit = content.hitTest(centre)
                XCTAssertTrue(hit === view, "\(at): its centre, \(centre), hit \(describe(hit))")
                let local = view.convert(centre, from: nil)
                XCTAssertEqual(local.x, view.bounds.midX, accuracy: pixel, "\(at): converted x")
                XCTAssertEqual(local.y, view.bounds.midY, accuracy: pixel, "\(at): converted y")

                let misses = [
                    ("left", CGPoint(x: zone.rect.minX - 2, y: zone.rect.midY)),
                    ("right", CGPoint(x: zone.rect.maxX + 2, y: zone.rect.midY)),
                    ("top", CGPoint(x: zone.rect.midX, y: zone.rect.minY - 2)),
                    ("bottom", CGPoint(x: zone.rect.midX, y: zone.rect.maxY + 2)),
                ]
                for (side, miss) in misses {
                    let point = windowPoint(
                        miss,
                        composition: posed.size,
                        angle: angle,
                        stage: stage,
                        pixelScale: window.backingScaleFactor
                    )
                    let hit = content.hitTest(point)
                    XCTAssertFalse(hit === view, "\(at): 2 pt off its \(side) edge, \(point) still hit it")
                }
            }
        }
    }

    // MARK: - Mapping

    /// Where the wrapper draws `point` (composition coordinates, points, y
    /// down) in the window: the composition is centred in the stage and
    /// turned about the stage's centre by `angle` (clockwise on screen for a
    /// positive angle, in SwiftUI's y-down space) at the scale the wrapper
    /// applies at rest, exactly 1, then moved by `PoseFit.pixelGridOffset`;
    /// the window's y grows up.
    private func windowPoint(
        _ point: CGPoint,
        composition size: CGSize,
        angle: Double,
        stage: CGSize,
        pixelScale: CGFloat
    ) -> CGPoint {
        let dx = point.x - size.width / 2
        let dy = point.y - size.height / 2
        let radians = angle * .pi / 180
        let grid = PoseFit.pixelGridOffset(angle: angle, size: stage, pixelScale: pixelScale)
        let x = stage.width / 2 + dx * cos(radians) - dy * sin(radians) + grid
        let y = stage.height / 2 + dx * sin(radians) + dy * cos(radians) + grid
        return CGPoint(x: x, y: stage.height - y)
    }

    /// The angle AppKit shows `view` at: SwiftUI turns a host view of the
    /// composition by the wrapper's angle.
    private func poseAngle(of view: NSView) -> Double {
        var ancestor = view.superview
        while let current = ancestor {
            if current.frameCenterRotation != 0 { return Double(current.frameCenterRotation) }
            ancestor = current.superview
        }
        return 0
    }

    private func zoneView(named name: String, in view: NSView) -> HitZoneView? {
        if let zone = view as? HitZoneView, zone.name == name { return zone }
        for subview in view.subviews {
            if let zone = zoneView(named: name, in: subview) { return zone }
        }
        return nil
    }

    private func describe(_ view: NSView?) -> String {
        guard let view else { return "nothing" }
        if let zone = view as? HitZoneView { return "zone \(zone.name)" }
        return String(describing: type(of: view))
    }
}

// MARK: - The composition

/// A zone of the composition, in points from the composition's top-left
/// corner (the layout box starts `pad` in).
private struct HitZone: Identifiable {
    let name: String
    let rect: CGRect
    var id: String { name }
}

/// The framed stage's shape with zones in place of the video and the
/// artwork's buttons: the layout box at the rest pose's fit (a plain fill
/// that takes no clicks, like the artwork), padded on both sides, the zones
/// laid out with the video's spacers, clipped to the layout box extended
/// right by the pad, and turned by `PosePresentation` at rest.
private struct HotspotComposition: View {
    let angle: Double
    let stage: CGSize
    let native: CGSize
    let pad: CGFloat

    private var pose: PosePresentation {
        PosePresentation(
            angle: angle,
            restAngle: angle,
            nativeSize: native,
            box: CGSize(width: max(stage.width - 16, 1), height: max(stage.height - 16, 1)),
            stage: stage
        )
    }

    /// The layout box, points.
    var layout: CGSize {
        CGSize(width: native.width * pose.layoutScale, height: native.height * pose.layoutScale)
    }

    /// The whole composition: the layout box plus the pad on both sides.
    var size: CGSize {
        CGSize(width: layout.width + pad * 2, height: layout.height)
    }

    var zones: [HitZone] {
        let right = pad + layout.width
        let height = layout.height
        return [
            HitZone(
                name: "screen",
                rect: CGRect(x: pad + layout.width * 0.04, y: height * 0.02, width: layout.width * 0.92, height: height * 0.96)
            ),
            // Sized as a hotspot is: its sprite widened 6 pt outward and
            // 4 pt inward, across the layout box's right edge.
            HitZone(name: "power", rect: CGRect(x: right - 7, y: height * 0.28, width: 13, height: height * 0.08)),
            // Wholly in the pad, outside the layout box.
            HitZone(name: "volumeUp", rect: CGRect(x: right + 0.5, y: height * 0.40, width: 6, height: height * 0.06)),
            HitZone(name: "volumeDown", rect: CGRect(x: right - 7, y: height * 0.49, width: 13, height: height * 0.06)),
            // In the pad at the bottom end: before the wrapper turns a
            // landscape pose, below the stage's frame.
            HitZone(name: "bottomEnd", rect: CGRect(x: right + 0.5, y: height * 0.92, width: 6, height: height * 0.05)),
        ]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.gray
                .frame(width: layout.width, height: layout.height)
                .offset(x: pad)
                .allowsHitTesting(false)
            ForEach(zones) { zone in
                placed(zone)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(ClipRect(rect: CGRect(x: pad, y: 0, width: layout.width + pad, height: layout.height)))
        .modifier(pose)
    }

    /// `FramedMirrorView.videoLayer`'s layout spacers.
    private func placed(_ zone: HitZone) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear
                .frame(width: max(zone.rect.minX, 0), height: 1)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                Color.clear
                    .frame(width: 1, height: max(zone.rect.minY, 0))
                    .allowsHitTesting(false)
                HitZoneRepresentable(name: zone.name)
                    .frame(width: zone.rect.width, height: zone.rect.height)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The stage at the window's top-left corner: a window's content size is
/// whole points, so a stage half a point narrower would otherwise be centred
/// in it, off the origin the mapping assumes.
private struct HotspotStage: View {
    let composition: HotspotComposition

    var body: some View {
        composition
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A fixed rect as a clip shape, in the clipped view's coordinates.
private struct ClipRect: Shape {
    let rect: CGRect

    func path(in _: CGRect) -> Path {
        Path(rect)
    }
}

/// A plain AppKit view, named for the zone it fills.
private final class HitZoneView: NSView {
    var name = ""
}

private struct HitZoneRepresentable: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> HitZoneView {
        let view = HitZoneView()
        view.name = name
        return view
    }

    func updateNSView(_ view: HitZoneView, context: Context) {
        view.name = name
    }
}
