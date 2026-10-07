import SwiftUI
import DeviceHubProKit

/// Live mirror inside the real SDK skin frame: background artwork, the Metal
/// video at the display rect, mask + onion overlays on top. The foldable
/// variant follows the live frame size; falls back to the flat mirror when
/// artwork is missing.
///
/// The composition is always built in the device's **native** orientation:
/// the skin artwork is unrotated, the video sits in the native screen rect
/// (the renderer samples the posed stream buffer upright), and the whole
/// composition is turned by `PosePresentation` with the stage's absolute
/// pose angle. That is what makes rotation animatable — a posed layout would
/// have to swap its transposed rects mid-animation. Its *size* is the fit of
/// the pose the device rests in, so at rest the video is not scaled by the
/// wrapper in any pose.
///
/// Size comes from the parent — a nested GeometryReader plus `.offset` on
/// `NSViewRepresentable` draws the Metal view a second time at (0, 0).
///
/// Everything is drawn from one plan (`DeviceCompositionPlanner.skin`, the
/// plan the static previews draw), placed at the rest pose's fit. On the
/// main stage a Pixel skin's side buttons are live (HW-01,
/// `HardwareButtonsLayer`): they roll out under the pointer and press power
/// and volume as real key down and up. They are offered only with an
/// emulator session (`supportsHardwareKeys`), on `pixel_` skins whose frame
/// paints them (`SkinButtonScanner`; not the 9 Pro Fold's flat cover), and
/// never in the compact window (`showsHardwareButtons`).
struct FramedMirrorView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.displayScale) private var displayScale
    @Environment(\.showsHardwareButtons) private var showsHardwareButtons
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: any MirrorSessionProtocol
    let skin: ResolvedSkin
    let available: CGSize
    /// The side buttons' pointer state, kept across a foldable's variant
    /// switch (the buttons release everything when a variant's go).
    @State private var buttons = HardwareButtonsState()

    var body: some View {
        let pixels = workspace.mirror.mirrorViewState.devicePixelSize
        let variant = pixels.flatMap { skin.variant(matching: $0) } ?? skin.preferredVariant
        Group {
            if let variant,
               let display = variant.layout?.preferred,
               let background = SkinThumbnailCache.shared.artwork(for: variant, display: display)
                   .background
            {
                framed(variant: variant, display: display, background: background)
                    .id(variant.id)
            } else {
                // No pose wrapper here, so the buffer is shown as streamed
                // (like the flat stage): uprighting it into the native rect
                // would leave landscape content sideways.
                MirrorView(
                    session: session,
                    state: workspace.mirror.mirrorViewState,
                    margin: 0.96,
                    forwardsKeyboard: model.preferences.keyboardForwardingEnabled
                )
            }
        }
        .frame(width: available.width, height: available.height, alignment: .center)
        // "Click to wake": the frame's power button goes down and up with it.
        .onChange(of: workspace.mirror.wakePulse) {
            Task { await buttons.pulse(.power, reduceMotion: reduceMotion) }
        }
    }

    @ViewBuilder
    private func framed(
        variant: SkinVariant,
        display: SkinDisplay,
        background: NSImage
    ) -> some View {
        let cache = SkinThumbnailCache.shared
        let art = cache.artwork(for: variant, display: display)
        let pose = PosePresentation(
            angle: workspace.mirror.stagePose.presentedAngle,
            restAngle: workspace.mirror.stagePose.restAngle,
            nativeSize: display.layoutSize,
            box: CGSize(
                width: max(available.width - 16, 1),
                height: max(available.height - 16, 1)
            ),
            stage: available
        )
        // Native layout (no pose transposition, no internal artwork
        // rotation) at the rest pose's fit: in landscape a portrait device is
        // laid out at its landscape size, not enlarged into it by the wrapper.
        let scale = pose.layoutScale
        let traits = cache.traits(for: variant, display: display)
        // A round watch's opaque square tile is clipped to its ring, so the
        // stage shows a circle (previews do the same in `SkinThumbnail.render`).
        let background = cache.stageBackground(background, traits: traits, variant: variant, display: display)
        // The video rect is the upright (natural) screen rect, which is
        // invariant across poses — derived from the frame being streamed so a
        // rotation transition can never flip the layout for a frame.
        let upright = uprightBufferSize(display: display)
        // The video is clipped to the device's own screen corner, capped at
        // the artwork's opening (`ScreenCornerPolicy`): the display the
        // device reports for the streamed frame (a foldable lists both
        // panels), or what the AVD last reported until this mirror session's read
        // answers. Status-bar and shade content (the clock) stays whole, as
        // on the device. The video is drawn above the artwork, and at or
        // under the opening's radius it covers the whole opening, so no
        // gap can show between the two.
        let corner = cache.screenCorner(
            for: variant,
            display: display,
            device: DisplayShape.matching(frame: upright, in: workspace.mirror.liveDisplayShapes)
        )
        // The side buttons, split out of the frame (once, off the main
        // thread) when this stage offers them. While every button rests the
        // artwork is drawn whole; while one is out of its place, the frame
        // without them over their sprites (`LiveButtonsFrame`).
        let offersButtons = showsHardwareButtons
            && workspace.mirror.supportsHardwareKeys
            && skin.name.hasPrefix("pixel_")
        let pressable = offersButtons ? cache.buttonArt(for: variant, display: display) : nil
        let plan = Self.plan(
            display: display,
            artworkPixelSize: background.artworkPixelSize,
            corner: corner,
            traits: traits,
            hasMask: art.mask != nil,
            hasOverlay: art.overlay != nil,
            buttons: pressable?.buttons ?? []
        )
        // With buttons the stage widens on both sides (so the device's
        // centre does not move) and the clip reaches into the right pad,
        // where they roll out; the fit stays the layout box's.
        let pad = pressable == nil ? 0 : HardwareButtonsLayout.buttonPad(plan, pointsPerUnit: scale)
        let placed = plan.placed(pointsPerUnit: scale, pixelScale: max(displayScale, 1), buttonPad: pad)
        let video = placed.videoRect(stream: upright)

        ZStack(alignment: .topLeading) {
            // Draw order is declaration order, the AppKit views included:
            // SwiftUI hosts a representable as a sibling layer and draws
            // the views declared after it above it (the mask and overlay
            // below do cover the video). The video's corner is clipped on
            // its own layer (`MirrorView.cornerRadius`) because SwiftUI clip
            // modifiers are not reliably honored by AppKit representables.
            // The buttons' sprites go under the frame, their hotspots over
            // everything.
            if let pressable, let artworkFrame = placed.artworkFrame {
                liveButtonsFrame(art: pressable, whole: background, artworkFrame: artworkFrame) {
                    FramedBodyLayers(
                        background: background,
                        composition: plan,
                        pointsPerUnit: scale,
                        buttonPad: pad,
                        parts: .backing
                    )
                }
            } else {
                FramedBodyLayers(background: background, composition: plan, pointsPerUnit: scale, buttonPad: pad)
            }
            videoLayer(videoOrigin: video.origin, fit: video.size, cornerRadius: placed.screenCornerRadius)
            if Self.drawsForegroundMask(plan: plan, display: display) {
                // Legacy skins: the foreground artwork shades the corners
                // that the display-radius clip leaves uncovered. A skin that
                // declares a camera hole (`cutout hole`) keeps its mask
                // above the video too, as the real phone and the emulator's
                // own window do: Android only draws the hole when it knows
                // the device's cutout (an emulation overlay), and the
                // frames of a stream that does not carry it covered the
                // artwork's camera dot.
                maskLayer(art: art, screen: placed.screen.size, origin: placed.screen.origin)
            }

            if let overlay = art.overlay {
                overlayLayer(
                    overlay: overlay,
                    frame: CGRect(
                        origin: placed.layoutOrigin,
                        size: CGSize(width: display.layoutSize.width * scale, height: display.layoutSize.height * scale)
                    )
                )
            }

            if let pressable {
                HardwareButtonHotspots(
                    art: pressable,
                    hotspots: HardwareButtonsLayout.hotspots(plan, placed: placed, pointsPerUnit: scale),
                    state: buttons,
                    reduceMotion: reduceMotion
                )
            }
        }
        .frame(width: placed.size.width, height: placed.size.height, alignment: .topLeading)
        .clipShape(PlacedClip(rect: placed.clipRect))
        .modifier(pose)
    }

    /// Whether the skin's foreground mask is drawn above the video: the
    /// legacy mask (the plan's flag), or the mask of a skin that declares a
    /// camera hole and has one.
    static func drawsForegroundMask(plan: DeviceComposition, display: SkinDisplay) -> Bool {
        guard case .skin(_, _, let legacy, _) = plan.body else { return false }
        return legacy || display.declaresCutout
    }

    /// The live stage's plan of a skin (`DeviceCompositionPlanner.skin`):
    /// under a modern skin's transparent opening a backing of the artwork's
    /// glass colour, the legacy mask only where the artwork has no opening,
    /// and the side `buttons` (artwork pixels) the stage offers.
    static func plan(
        display: SkinDisplay,
        artworkPixelSize: CGSize,
        corner: ScreenCorner,
        traits: SkinRenderTraits,
        hasMask: Bool,
        hasOverlay: Bool,
        buttons: [SkinHardwareButton] = []
    ) -> DeviceComposition {
        DeviceCompositionPlanner.skin(
            display: display,
            artworkPixelSize: artworkPixelSize,
            corner: corner,
            // Under the video, the opening is filled with the artwork's
            // glass color. A playing video covers all of it; it shows before
            // the first frame and in letterbox bars (a foldable's frame of
            // the other screen while the variant catches up), where the
            // stage's background would otherwise show through the frame.
            // It is also what the artwork's anti-aliased opening edge blends
            // with. Legacy and round skins get none.
            backing: traits.hasTransparentOpening && !traits.isCircularDisplay
                ? DeviceComposition.Backing(
                    cornerRadius: traits.openingCornerRadius ?? corner.radius,
                    color: RGBA(sRGB: traits.glassColor ?? traits.bezelColor ?? .black)
                )
                : nil,
            drawsLegacyMask: hasMask && !traits.hasTransparentOpening,
            hasOverlay: hasOverlay,
            buttons: buttons
        )
    }

    /// The frame artwork with the side buttons live (`LiveButtonsFrame`),
    /// drawn from the buttons' state, over `backing`.
    private func liveButtonsFrame(
        art: LiveButtonArt,
        whole: NSImage,
        artworkFrame: CGRect,
        @ViewBuilder backing: @escaping () -> some View
    ) -> some View {
        let pointsPerPixel = art.pixelSize.width > 0 ? artworkFrame.width / art.pixelSize.width : 0
        return LiveButtonsFrame(
            art: art,
            whole: whole,
            artworkFrame: artworkFrame,
            offsets: HardwareButtonSprites.offsets(
                art: art,
                state: buttons,
                pointsPerPixel: pointsPerPixel,
                reduceMotion: reduceMotion
            ),
            held: buttons.pressed,
            drawsSplit: buttons.drawsSplit,
            restFade: buttons.restFade,
            backing: backing
        )
    }

    /// The streamed buffer in the display's natural orientation.
    ///
    /// Derived from the frame currently in the store (with the settled state
    /// as a fallback) rather than the settled SwiftUI state alone: the state
    /// lags the stream by an update cycle, and a stale rotation would
    /// transpose the video rect for a frame at every rotation settle. The
    /// result is additionally oriented to the skin display's natural pose, so
    /// even an inconsistent (flipped buffer, stale rotation) pair yields the
    /// invariant natural size.
    private func uprightBufferSize(display: SkinDisplay) -> CGSize {
        let posed: CGSize
        let rotation: Int
        if let frame = session.frames.current {
            posed = CGSize(width: frame.width, height: frame.height)
            rotation = frame.rotation
        } else if let settled = workspace.mirror.mirrorViewState.devicePixelSize {
            posed = settled
            rotation = workspace.mirror.mirrorViewState.deviceRotation
        } else {
            return display.displaySize
        }
        let natural = TextureRotation.naturalSize(
            posedWidth: Int(posed.width.rounded()),
            posedHeight: Int(posed.height.rounded()),
            rotation: rotation,
            naturalIsPortrait: display.displaySize.height >= display.displaySize.width
        )
        return CGSize(width: natural.width, height: natural.height)
    }

    @ViewBuilder
    private func maskLayer(
        art: SkinArtwork,
        screen: CGSize,
        origin: CGPoint
    ) -> some View {
        if let mask = art.mask {
            Image(nsImage: mask)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .frame(width: screen.width, height: screen.height)
                .padding(.leading, origin.x)
                .padding(.top, origin.y)
                .allowsHitTesting(false)
        }
    }

    /// The legacy top overlay (`onion`), stretched to the layout box at
    /// `frame`. Every SDK onion that paints anything is layout-sized except
    /// `pixel_3_xl`'s (1692x3456 over a 1684x3246 layout): its notch ends at
    /// row 255, the frame artwork's at 240, and stretched it lands at 239.5.
    /// So the overlay keeps the layout mapping the background no longer
    /// uses.
    private func overlayLayer(overlay: NSImage, frame: CGRect) -> some View {
        Image(nsImage: overlay)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .allowsHitTesting(false)
    }

    /// Layout spacers, not `.offset`: AppKit representables ignore offset and
    /// also stay at the ZStack origin, which duplicated the live screen in the
    /// top-left of the canvas.
    private func videoLayer(
        videoOrigin: CGPoint,
        fit: CGSize,
        cornerRadius: CGFloat
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear
                .frame(width: max(videoOrigin.x, 0), height: 1)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                Color.clear
                    .frame(width: 1, height: max(videoOrigin.y, 0))
                    .allowsHitTesting(false)
                video(fit: fit, cornerRadius: cornerRadius)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func video(fit: CGSize, cornerRadius: CGFloat) -> some View {
        MirrorView(
            session: session,
            state: workspace.mirror.mirrorViewState,
            margin: 1.0,
            allowsUpscaling: true,
            forwardsKeyboard: model.preferences.keyboardForwardingEnabled,
            cornerRadius: cornerRadius,
            backgroundIsTransparent: true,
            uprightsTexture: true
        )
        .frame(width: fit.width, height: fit.height)
    }
}

/// A fixed rect as a clip shape, in the clipped view's own coordinates: the
/// plan's `clipRect` (the layout box, reaching into the right pad when the
/// stage offers buttons).
struct PlacedClip: Shape {
    let rect: CGRect

    func path(in _: CGRect) -> Path {
        Path(rect)
    }
}

/// The skin's body under the live video: the frame artwork and, on a modern
/// skin, the backing that fills its transparent opening, drawn from the
/// plan (`DeviceComposition.placed` at the view's own pixel scale).
/// Everything here is SwiftUI, so it renders without a session
/// (`FramedSeamTests` renders it with `ImageRenderer`).
///
/// The backing is drawn *under* the artwork and reaches two backing pixels
/// past the display rect on every side (`PlacedComposition.backingFrame`),
/// its radius grown by as much so it stays concentric with the opening. A
/// modern artwork's opening ends in a hard alpha step on the display rect;
/// drawn above the artwork at the display rect, the backing's anti-aliased
/// edge fell in the same pixel as the step at a fractional scale, and each
/// edge let the stage through where the other did not cover: up to 93 of
/// 255 levels on a white stage along the fold cover's straight edges. Under
/// the artwork's opaque band the backing's edge is hidden, and the step's
/// pixel blends the artwork over the backing only.
struct FramedBodyLayers: View {
    /// Which of the body's layers are drawn: the stage with live side
    /// buttons draws the backing alone and the artwork itself, with the
    /// buttons' frames between them (`LiveButtonsFrame`).
    enum Parts {
        case all
        case backing
    }

    @Environment(\.displayScale) private var displayScale

    let background: NSImage
    /// A skin plan (`FramedMirrorView.plan`).
    let composition: DeviceComposition
    /// Points per layout unit.
    let pointsPerUnit: CGFloat
    /// The stage's button pad, points (`HardwareButtonsLayout.buttonPad`).
    let buttonPad: CGFloat
    let parts: Parts

    init(
        background: NSImage,
        composition: DeviceComposition,
        pointsPerUnit: CGFloat,
        buttonPad: CGFloat = 0,
        parts: Parts = .all
    ) {
        self.background = background
        self.composition = composition
        self.pointsPerUnit = pointsPerUnit
        self.buttonPad = buttonPad
        self.parts = parts
    }

    /// The layers of `display`'s frame at `hero`'s scale, with the backing
    /// taking `videoRadius` hero points (the video's corner) where the
    /// artwork's opening measured none.
    init(
        background: NSImage,
        display: SkinDisplay,
        hero: SkinHeroLayout,
        traits: SkinRenderTraits,
        videoRadius: CGFloat
    ) {
        self.init(
            background: background,
            composition: FramedMirrorView.plan(
                display: display,
                artworkPixelSize: background.artworkPixelSize,
                corner: ScreenCorner(radius: hero.scale > 0 ? videoRadius / hero.scale : 0, source: .declared),
                traits: traits,
                hasMask: false,
                hasOverlay: false
            ),
            pointsPerUnit: hero.scale
        )
    }

    /// The plan at this view's scale and pixel grid.
    private var placed: PlacedComposition {
        composition.placed(pointsPerUnit: pointsPerUnit, pixelScale: max(displayScale, 1), buttonPad: buttonPad)
    }

    var body: some View {
        let placed = placed
        ZStack(alignment: .topLeading) {
            if let backing = placed.backingFrame, let color = placed.backingColor {
                RoundedRectangle(cornerRadius: placed.backingRadius, style: .circular)
                    .fill(Color(srgb: color))
                    .frame(width: backing.width, height: backing.height)
                    .padding(.leading, backing.minX)
                    .padding(.top, backing.minY)
                    .allowsHitTesting(false)
            }
            if parts == .all, let artworkFrame = placed.artworkFrame {
                FramedArtwork(image: background, frame: artworkFrame)
            }
        }
    }
}

/// A frame artwork at `frame`, at its natural size (the stage clips any
/// overhang past the layout box). `.offset` is safe here: this is a SwiftUI
/// image, not an AppKit representable (see `FramedMirrorView.videoLayer`).
/// High interpolation: the full-size artwork is minified, 0.25–0.35 pt per
/// artwork pixel at stage fit and ~0.17 in the default compact window,
/// where the default filter breaks the thin metal rim highlights into
/// jaggies.
struct FramedArtwork: View {
    let image: NSImage
    let frame: CGRect

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .allowsHitTesting(false)
    }
}
