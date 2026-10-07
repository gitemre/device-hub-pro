import SwiftUI
import DeviceHubProKit

/// The live stage's vector device body (device frame, Tier 2): a concentric
/// graphite body around the live screen, for the Android devices without a
/// skin — skinless AVDs, physical phones, and every Android device under
/// `DHP_FORCE_VECTOR_CHROME` (`DeviceChromeResolver`).
///
/// The plan is the Kit's (`DeviceCompositionPlanner.vector`), built from what
/// the device reports about its own screen: the panel's corner radius (square
/// when it reports none), its density (the bezel is millimetres, so it keeps
/// a real device's proportions at any resolution) and its camera cutout. The
/// stopped device's hero and framed screenshots draw the same plan with
/// `DeviceCompositionRenderer`; `VectorBodyParityTests` holds the two together.
///
/// Drawn here as flat rounded-rect bands (`VectorBodyBands`, vector shapes,
/// so the body stays sharp at every zoom), then the live video at the screen
/// rect: clipped to the screen corner on its own layer, with the cutout
/// filled black over it (`MirrorView.cutout`). Clicks are not masked: the
/// corner wedges and the camera hole go to the device, as in Google's
/// emulator, so Android's corner swipes keep working.
///
/// The composition is native, like the framed stage's: an emulator's posed
/// stream is sampled upright and `PosePresentation` turns the whole body with
/// the stage's pose angle, laid out at the fit of the pose it rests in, so
/// the video is 1:1 at rest in every pose. A phone's scrcpy frames arrive
/// already posed (rotation 0), so its body is planned from the posed size
/// and its cutout turned by the display rotation `dumpsys display` reports
/// (`MirrorViewState.displayRotation`, watched while the body is shown:
/// `MirrorController.watchDisplayRotation`); until that is read the cutout
/// is drawn only while the screen shows in the panel's natural orientation.
///
/// No drop shadow, as on the skinned stage (P2-FRAME) and in Device Hub's
/// live stage: inside the pose wrapper a shadow turns with the device and
/// falls sideways in landscape.
struct VectorDeviceView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    let session: any MirrorSessionProtocol
    /// The settled stream size: the fallback while the frame store is empty.
    let pixels: CGSize
    /// The stage area the device is fitted into.
    let available: CGSize

    var body: some View {
        let screen = Self.screenSize(workspace: workspace, session: session, pixels: pixels)
        let plan = Self.composition(workspace: workspace, session: session, screen: screen)
        let pose = PosePresentation(
            angle: workspace.mirror.stagePose.presentedAngle,
            restAngle: workspace.mirror.stagePose.restAngle,
            nativeSize: plan.layoutSize,
            box: CGSize(
                width: max(available.width - 16, 1),
                height: max(available.height - 16, 1)
            ),
            stage: available
        )
        let placed = plan.placed(pointsPerUnit: pose.layoutScale, pixelScale: displayScale)
        let video = placed.videoRect(stream: screen)
        let signature = "\(Int(screen.width))x\(Int(screen.height))"

        ZStack(alignment: .topLeading) {
            VectorBodyBands(bands: placed.bands)
            videoLayer(
                video: video,
                cornerRadius: placed.screenCornerRadius,
                cutout: placed.cutoutPath(inVideoRect: video)
            )
        }
        .frame(width: placed.size.width, height: placed.size.height, alignment: .topLeading)
        // A foldable switching screens (or a phone turning) grows the body
        // into its new shape instead of snapping.
        .animation(reduceMotion ? nil : MotionMetrics.standard, value: signature)
        .modifier(pose)
        // A phone's display rotation, which turns the cutout on its posed
        // frames: read as the frame settles and on every turn between
        // portrait and landscape, and watched while the body is shown for
        // the turns that keep the frame's size. Here, not on `MirrorView`:
        // the body is the only reader, and the watch polls. The controller
        // reads it for physical sessions only.
        .task(id: RotationWatch(
            state: ObjectIdentifier(workspace.mirror.mirrorViewState),
            isLandscape: workspace.mirror.mirrorViewState.devicePixelSize.map { $0.width > $0.height }
        )) {
            await workspace.mirror.watchDisplayRotation(for: workspace.mirror.mirrorViewState)
        }
    }

    private struct RotationWatch: Equatable {
        let state: ObjectIdentifier
        let isLandscape: Bool?
    }

    /// Whether `session` is a phone's scrcpy session (or an emulator forced
    /// through it, `DHP_FORCE_PHYSICAL`): its frames arrive posed.
    static func isPhysical(_ session: any MirrorSessionProtocol) -> Bool {
        session is any PhysicalSessionControlling
    }

    /// The screen the body is planned around, in stream pixels: an
    /// emulator's frame upright (its natural orientation), a phone's as
    /// posed. Read from the frame being streamed, with the settled state as
    /// the fallback, so a rotation transition can never transpose the body
    /// for a frame.
    static func screenSize(
        workspace: DeviceWorkspace,
        session: any MirrorSessionProtocol,
        pixels: CGSize
    ) -> CGSize {
        let current = session.frames.current
        let posed = current.map { CGSize(width: $0.width, height: $0.height) } ?? pixels
        if isPhysical(session) { return posed }
        let rotation = current?.rotation ?? workspace.mirror.mirrorViewState.deviceRotation
        let upright = TextureRotation.uprightSize(
            posedWidth: Int(posed.width.rounded()),
            posedHeight: Int(posed.height.rounded()),
            rotation: rotation
        )
        return CGSize(width: upright.width, height: upright.height)
    }

    /// The body's plan for `screen`: every display the device reported (this
    /// session's read, else the AVD's or the phone model's stored shapes),
    /// the density `wm density` reported as the fallback (observed, so the
    /// body is planned again when it arrives), the AVD's hinge count, and
    /// the display rotation — 0 for an emulator's upright frame, the one
    /// read for a phone's posed frame (nil until read).
    static func composition(
        workspace: DeviceWorkspace,
        session: any MirrorSessionProtocol,
        screen: CGSize
    ) -> DeviceComposition {
        let state = workspace.mirror.mirrorViewState
        return DeviceCompositionPlanner.vector(
            screen: screen,
            displays: workspace.mirror.liveDisplayShapes,
            fallbackDensityDpi: state.displayDensityDpi.map(Double.init),
            hingeCount: workspace.context.hingeCount,
            quarterTurns: isPhysical(session) ? state.displayRotation : 0
        )
    }

    /// Layout spacers, not `.offset`: AppKit representables ignore offset
    /// (see `FramedMirrorView.videoLayer`).
    private func videoLayer(video: CGRect, cornerRadius: CGFloat, cutout: CGPath?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear
                .frame(width: max(video.minX, 0), height: 1)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                Color.clear
                    .frame(width: 1, height: max(video.minY, 0))
                    .allowsHitTesting(false)
                MirrorView(
                    session: session,
                    state: workspace.mirror.mirrorViewState,
                    margin: 1.0,
                    allowsUpscaling: true,
                    forwardsKeyboard: model.preferences.keyboardForwardingEnabled,
                    cornerRadius: cornerRadius,
                    cutout: cutout,
                    uprightsTexture: true
                )
                .frame(width: video.width, height: video.height)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A placed vector body's bands (`PlacedComposition.bands`): filled rounded
/// rects, outside-in, each drawn over the one before, so a band shows as the
/// ring between its rect and the next one's and the last, the glass, fills
/// the rest (under the screen too, where it shows before the first frame and
/// in letterbox bars). Circular corners, as Android's. Plain SwiftUI shapes
/// that take no clicks, so `ImageRenderer` can draw them without a session.
///
/// Each band is a shape over the whole body with its outline at the band's
/// own rect, not a shape framed to that rect: SwiftUI puts a frame on the
/// pixel grid, which moved each band's edges by up to half a pixel on its
/// own and turned the one-pixel rim into none or two. Drawn so, the edges
/// lie where the plan puts them, as in the Kit renderer's bitmaps.
struct VectorBodyBands: View {
    let bands: [PlacedBand]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(bands.indices, id: \.self) { index in
                let band = bands[index]
                PlacedRoundedRect(rect: band.rect, cornerRadius: band.cornerRadius)
                    .fill(Color(srgb: band.color))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A rounded rect at a fixed place in the shape's own coordinates, with
/// circular corners held to half its short side: the outline
/// `DeviceCompositionRenderer` fills for the same band. Its rect and corner
/// animate, so the body grows into a new shape with the video (a foldable
/// switching screens) instead of jumping ahead of it.
struct PlacedRoundedRect: Shape {
    var rect: CGRect
    var cornerRadius: CGFloat

    var animatableData: AnimatablePair<CGRect.AnimatableData, CGFloat> {
        get { AnimatablePair(rect.animatableData, cornerRadius) }
        set {
            rect.animatableData = newValue.first
            cornerRadius = newValue.second
        }
    }

    func path(in _: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let corner = min(max(cornerRadius, 0), rect.width / 2, rect.height / 2)
        return Path(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
    }
}

extension Color {
    /// A chrome colour (`ChromeSpec`, sRGB components) as SwiftUI draws it:
    /// in sRGB, like the Kit renderer's `RGBA.srgbColor`, so the live body
    /// and the static images agree (a Generic RGB colour would land the
    /// highlight's #7E7E7E as #919191).
    init(srgb color: RGBA) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}
