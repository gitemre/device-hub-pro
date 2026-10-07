import AppKit
import SwiftUI
import DeviceHubProKit

/// A simulator on the live stage in its Apple chrome (device frame, design
/// §3.5): the device type's own DeviceKit chrome, read at runtime from the
/// user's Xcode (`AppleChromeFrameProvider`), built from its slices around
/// the screen, with the live canvas clipped to the screen's exact outline
/// and the chrome's buttons pressable.
///
/// The plan is the Kit's (`DeviceCompositionPlanner.appleChrome`), in the
/// device's native portrait, drawn with the same routines the stopped
/// page's hero and framed screenshots use (`AppleChromeDrawing`), here into
/// SwiftUI canvases so the chrome stays sharp at every size:
/// - the buttons drawn under the body, then the body (its slices over the
///   screen's black glass), then the video at the screen rect, then black
///   over the screen's corners outside its outline (the framebuffer mask),
///   then any button drawn over the body (a Home button);
/// - on the main stage and only with the live canvas
///   (`MirrorController.supportsChromeButtons`), a hotspot per button: the
///   pointer over it rolls the button out to its rollover offset, a click
///   holds it down (its pressed image) and holds its HID usage down on the
///   simulator until the mouse comes up. The compact window draws the
///   buttons at rest and offers none, as for a skin's buttons.
///
/// The chrome turns with the device, as Device Hub turns it: the whole
/// composition is turned by the simulator's device pose
/// (`SimulatorCanvasController.devicePose`) with `PosePresentation`, and the
/// video shows the native panel (the frames, posed by the interface, are
/// turned back per frame: `AppleChromePose.contentTurns`). So the iPhone
/// home screen, which does not turn, shows sideways in a landscape device,
/// and an app that turns shows upright.
///
/// No drop shadow, as on the skinned and vector stages.
struct AppleChromeDeviceView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.displayScale) private var displayScale
    @Environment(\.showsHardwareButtons) private var showsHardwareButtons
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: any MirrorSessionProtocol
    let frame: AppleChromeFrame
    /// The stage area the device is fitted into.
    let available: CGSize
    @State private var buttons = AppleChromeButtonsState()

    var body: some View {
        let plan = DeviceCompositionPlanner.appleChrome(frame)
        let devicePose = workspace.simulatorCanvas.devicePose
        let pose = PosePresentation(
            angle: devicePose.presentedAngle,
            restAngle: devicePose.restAngle,
            nativeSize: plan.layoutSize,
            box: CGSize(
                width: max(available.width - 16, 1),
                height: max(available.height - 16, 1)
            ),
            stage: available
        )
        let placed = plan.placed(pointsPerUnit: pose.layoutScale, pixelScale: displayScale)
        // View points per chrome point: layout units are the screen's pixels.
        let perPoint = pose.layoutScale * frame.scale
        // A physical iPhone's chrome takes button clicks while Control is on or the
        // buttons' own fast input is available (the reads make the view follow).
        let offersButtons = showsHardwareButtons && workspace.mirror.supportsChromeButtons
            && (!workspace.context.isPhysicalView || workspace.physicalControl.isReady
                || workspace.physicalControl.chromeButtonsAvailable)

        ZStack(alignment: .topLeading) {
            // Declaration order is draw order, the video's AppKit view
            // included (`FramedMirrorView`).
            AppleChromeButtonsArt(frame: frame, perPoint: perPoint, onTop: false, state: buttons)
            AppleChromeBodyView(frame: frame, perPoint: perPoint)
                .equatable()
            SpacerPlaced(rect: placed.screen) {
                MirrorView(
                    session: session,
                    state: workspace.mirror.mirrorViewState,
                    margin: 1.0,
                    allowsUpscaling: true,
                    forwardsKeyboard: model.preferences.keyboardForwardingEnabled,
                    cornerRadius: Double(AppleChromeScreenCorners.videoCornerRadius(frame) * perPoint),
                    cornerCurve: .continuous,
                    uprightsTexture: true,
                    textureTurns: Self.textureTurns(frame: frame, session: session, devicePose: devicePose)
                )
                .overlay {
                    if workspace.context.isPhysicalView, workspace.physicalControl.isReady {
                        TouchFeedbackOverlay(model: workspace.physicalControl.touchFeedback, perPoint: perPoint)
                    }
                }
            }
            AppleChromeScreenCorners(frame: frame, perPoint: perPoint)
                .equatable()
            AppleChromeButtonsArt(frame: frame, perPoint: perPoint, onTop: true, state: buttons)
            if offersButtons {
                AppleChromeButtonHotspots(frame: frame, perPoint: perPoint, state: buttons, reduceMotion: reduceMotion)
            }
        }
        .frame(width: placed.size.width, height: placed.size.height, alignment: .topLeading)
        .modifier(pose)
    }

    /// The per-frame turn that shows the native panel in the native screen
    /// rect: the frame's own turn from the panel (`AppleChromePose`), with
    /// the live session's reported rotation and the device pose's target.
    static func textureTurns(
        frame: AppleChromeFrame,
        session: any MirrorSessionProtocol,
        devicePose: StagePoseAnimator
    ) -> (Int, Int) -> Int {
        let native = frame.screenPixels
        let live = session as? SimulatorMirrorSession
        // A physical phone's native view turns the panel picture by its stage pose
        // (`PhysicalStageRotation`), upside down included, where the frame's shape alone
        // cannot tell a half turn from none.
        let physical = (session as? any PhysicalViewSession).flatMap { $0.viewKind == .nativeLive ? $0 : nil }
        return { width, height in
            MainActor.assumeIsolated {
                if let turns = physical?.stagePose?.chromeTurns {
                    let swapped = native.width != native.height && (width > height) != (native.width > native.height)
                    if (turns % 2 == 1) == swapped { return turns }
                }
                return AppleChromePose.contentTurns(
                    frame: CGSize(width: width, height: height),
                    native: native,
                    reported: live?.publishedRotation,
                    deviceTurns: devicePose.targetTurns
                )
            }
        }
    }
}

// MARK: - Body and screen

/// The chrome's body (`AppleChromeDrawing.drawBody`) over the whole canvas.
/// Equatable, so it is drawn again only when the frame or the size changes.
struct AppleChromeBodyView: View, Equatable {
    let frame: AppleChromeFrame
    let perPoint: CGFloat

    var body: some View {
        let size = frame.layout.canvasSize
        Canvas { context, _ in
            context.withCGContext { cg in
                cg.scaleBy(x: perPoint, y: perPoint)
                AppleChromeDrawing.drawBody(frame.layout, art: frame.art, in: cg)
            }
        }
        .frame(width: size.width * perPoint, height: size.height * perPoint)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The screen's exact shape over the video. The video's layer clips it to a
/// continuous-corner rounded rect 2 pt tighter in radius than the display's
/// (`videoCornerRadius`), which holds the framebuffer mask with room to
/// spare (measured on iPhone 17 Pro: the mask lies within the display
/// radius's continuous corner, at most a pixel inside it); this draws black
/// where the mask leaves the screen out, within that rect grown by one
/// point (`AppleChromeDrawing.drawScreenCorners`), over the body's black
/// glass. So the screen's edge is the mask's alone: with the layer's corner
/// at the mask's own radius, the two edges' antialiasing darkened the curve
/// by about a pixel. Clicks pass through to the video, the corner wedges
/// included, as on the vector body.
struct AppleChromeScreenCorners: View, Equatable {
    let frame: AppleChromeFrame
    let perPoint: CGFloat

    /// The video layer's corner, chrome points: the display's less 2 pt.
    static func videoCornerRadius(_ frame: AppleChromeFrame) -> CGFloat {
        max(frame.cornerRadius - 2, 0)
    }

    var body: some View {
        let size = frame.layout.canvasSize
        let screen = frame.layout.screen
        let within = RoundedRectangle(cornerRadius: Self.videoCornerRadius(frame) + 1, style: .continuous)
            .path(in: screen.insetBy(dx: -1, dy: -1))
            .cgPath
        Canvas { context, _ in
            context.withCGContext { cg in
                cg.scaleBy(x: perPoint, y: perPoint)
                AppleChromeDrawing.drawScreenCorners(
                    in: screen,
                    within: within,
                    art: frame.art,
                    cornerRadius: frame.cornerRadius,
                    context: cg
                )
            }
        }
        .frame(width: size.width * perPoint, height: size.height * perPoint)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Buttons

/// The chrome's buttons drawn under the body (`onTop` false) or over it:
/// each at its rest place, rolled out while the pointer is over it, its
/// pressed look while held (`AppleChromeButtonsState`).
struct AppleChromeButtonsArt: View {
    let frame: AppleChromeFrame
    let perPoint: CGFloat
    let onTop: Bool
    let state: AppleChromeButtonsState

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(frame.layout.buttons.filter { $0.input.onTop == onTop }, id: \.index) { button in
                let rest = Self.scaled(button.rest, perPoint)
                let out = state.rolledOut.contains(button.index)
                let rollover = Self.scaled(button.rollover, perPoint)
                AppleChromeButtonImage(
                    art: frame.art,
                    input: button.input,
                    pressed: state.pressed.contains(button.index)
                )
                .frame(width: rest.width, height: rest.height)
                .offset(x: out ? rollover.minX : rest.minX, y: out ? rollover.minY : rest.minY)
            }
        }
        .frame(
            width: frame.layout.canvasSize.width * perPoint,
            height: frame.layout.canvasSize.height * perPoint,
            alignment: .topLeading
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    nonisolated static func scaled(_ rect: CGRect, _ scale: CGFloat) -> CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }
}

/// One button's look at its own size (`AppleChromeDrawing.drawButton`).
struct AppleChromeButtonImage: View, Equatable {
    let art: AppleChromeArt
    let input: AppleChromeDescriptor.Input
    let pressed: Bool

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                AppleChromeDrawing.drawButton(
                    input,
                    art: art,
                    pressed: pressed,
                    in: CGRect(origin: .zero, size: size),
                    context: cg
                )
            }
        }
    }
}

/// The chrome buttons' pointer state on one stage: the buttons rolled out
/// under the pointer and those held down. It presses and releases their HID
/// usages on the session (`MirrorController.pressChromeButton`), so what the
/// stage shows held is what the simulator holds. Under Reduce Motion
/// nothing rolls out and a held button only changes its look.
@MainActor
@Observable
final class AppleChromeButtonsState {
    /// Buttons out at their rollover offset, by index in the chrome's inputs.
    private(set) var rolledOut: Set<Int> = []
    /// Buttons held down.
    private(set) var pressed: Set<Int> = []
    @ObservationIgnored private var hovered: Set<Int> = []
    @ObservationIgnored private var hoverOff: [Int: Task<Void, Never>] = [:]

    /// The pointer entered a button's hotspot: it rolls out.
    func enter(_ index: Int, reduceMotion: Bool) {
        hovered.insert(index)
        hoverOff.removeValue(forKey: index)?.cancel()
        guard !reduceMotion, !rolledOut.contains(index) else { return }
        withAnimation(MotionMetrics.chromeHoverOn) {
            _ = rolledOut.insert(index)
        }
    }

    /// The pointer left: once it stays away for `chromeHoverOffDelay`, the
    /// button eases back (unless it is held).
    func exit(_ index: Int, reduceMotion: Bool) {
        hovered.remove(index)
        hoverOff.removeValue(forKey: index)?.cancel()
        guard rolledOut.contains(index) else { return }
        hoverOff[index] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(MotionMetrics.chromeHoverOffDelay))
            guard let self, !Task.isCancelled, !self.hovered.contains(index), !self.pressed.contains(index) else { return }
            self.hoverOff[index] = nil
            withAnimation(reduceMotion ? nil : MotionMetrics.chromeHoverOff) {
                _ = self.rolledOut.remove(index)
            }
        }
    }

    /// A click went down on the button: its usage goes down on the
    /// simulator and it shows pressed.
    func press(_ index: Int, button: SimulatorHardwareButton, on mirror: MirrorController, reduceMotion: Bool) {
        if !pressed.contains(index) {
            withAnimation(reduceMotion ? nil : MotionMetrics.chromePress) {
                _ = pressed.insert(index)
            }
        }
        mirror.pressChromeButton(button)
    }

    /// The click came up (wherever the pointer is): the usage goes up.
    func release(_ index: Int, button: SimulatorHardwareButton, on mirror: MirrorController, reduceMotion: Bool) {
        if pressed.contains(index) {
            withAnimation(reduceMotion ? nil : MotionMetrics.chromePress) {
                _ = pressed.remove(index)
            }
            if !hovered.contains(index) { exit(index, reduceMotion: reduceMotion) }
        }
        mirror.releaseChromeButton(button)
    }

    /// Everything goes up and back to rest at once: the window resigned key,
    /// the buttons went away, or the device started turning.
    func releaseAll(on mirror: MirrorController) {
        for task in hoverOff.values { task.cancel() }
        hoverOff = [:]
        hovered = []
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if !pressed.isEmpty { pressed = [] }
            if !rolledOut.isEmpty { rolledOut = [] }
        }
        mirror.releaseAllChromeButtons()
    }
}

/// Where each chrome button takes clicks: its visible part and a margin past
/// it, from the farthest it rolls out to a little inside the body (a Home
/// button: its own rect). View points, in the canvas.
enum AppleChromeButtonHotspotLayout {
    /// Past the button's outer edge, points.
    static let outset: CGFloat = HardwareButtonsLayout.hotspotOutset
    /// Into the body past its edge, points.
    static let inset: CGFloat = HardwareButtonsLayout.hotspotInset

    static func hotspot(_ button: AppleChromeLayout.Button, layout: AppleChromeLayout, perPoint: CGFloat) -> CGRect {
        let rest = AppleChromeButtonsArt.scaled(button.rest, perPoint)
        let rollover = AppleChromeButtonsArt.scaled(button.rollover, perPoint)
        let box = AppleChromeButtonsArt.scaled(layout.box, perPoint)
        let reach = rest.union(rollover)
        let rect: CGRect
        if button.input.onTop {
            rect = rest
        } else {
            switch button.input.anchor {
            case .left:
                rect = CGRect(x: reach.minX - outset, y: rest.minY, width: box.minX + inset - (reach.minX - outset), height: rest.height)
            case .right:
                rect = CGRect(x: box.maxX - inset, y: rest.minY, width: reach.maxX + outset - (box.maxX - inset), height: rest.height)
            case .top:
                rect = CGRect(x: rest.minX, y: reach.minY - outset, width: rest.width, height: box.minY + inset - (reach.minY - outset))
            case .bottom:
                rect = CGRect(x: rest.minX, y: box.maxY - inset, width: rest.width, height: reach.maxY + outset - (box.maxY - inset))
            }
        }
        // A view outside the canvas would not be hit.
        let canvas = CGRect(
            x: 0,
            y: 0,
            width: layout.canvasSize.width * perPoint,
            height: layout.canvasSize.height * perPoint
        )
        return rect.intersection(canvas)
    }

    /// What VoiceOver and the tooltip say for `input` ("Volume Up button";
    /// "Volume Up: click to press; hold to keep it down"), and the side
    /// button's long press ("Long-press Sleep/Wake": the power-off slider or
    /// Siri, as held on a device).
    static func description(for input: AppleChromeDescriptor.Input) -> HardwareButtonHotspotView.Description {
        let button = SimulatorHardwareButton(usagePage: input.usagePage, usage: input.usage)
        return HardwareButtonHotspotView.Description(
            label: "\(input.title) button",
            toolTip: "\(input.title): click to press; hold to keep it down",
            longPressName: button == .side ? "Long-press \(input.title)" : nil
        )
    }
}

/// The chrome buttons' hotspots over the stage, placed with layout spacers
/// (AppKit views: a click reaches them through the pose wrapper, and a held
/// click's mouse-up comes back to the one it went down on).
struct AppleChromeButtonHotspots: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let frame: AppleChromeFrame
    let perPoint: CGFloat
    let state: AppleChromeButtonsState
    let reduceMotion: Bool

    var body: some View {
        let mirror = workspace.mirror
        let state = self.state
        let reduceMotion = self.reduceMotion
        ZStack(alignment: .topLeading) {
            ForEach(frame.layout.buttons, id: \.index) { button in
                let index = button.index
                let usage = SimulatorHardwareButton(usagePage: button.input.usagePage, usage: button.input.usage)
                SpacerPlaced(rect: AppleChromeButtonHotspotLayout.hotspot(button, layout: frame.layout, perPoint: perPoint)) {
                    AppleChromeButtonHotspot(
                        description: AppleChromeButtonHotspotLayout.description(for: button.input),
                        onPress: { state.press(index, button: usage, on: mirror, reduceMotion: reduceMotion) },
                        onRelease: { state.release(index, button: usage, on: mirror, reduceMotion: reduceMotion) },
                        onHover: { inside in
                            if inside {
                                state.enter(index, reduceMotion: reduceMotion)
                            } else {
                                state.exit(index, reduceMotion: reduceMotion)
                            }
                        },
                        onResignKey: { state.releaseAll(on: mirror) }
                    )
                }
            }
        }
        // Nothing may stay held once the buttons go or the device starts
        // turning (hit-testing is off while it turns).
        .onDisappear { state.releaseAll(on: mirror) }
        .onChange(of: workspace.simulatorCanvas.devicePose.isAnimating) { _, isAnimating in
            if isAnimating { state.releaseAll(on: mirror) }
        }
    }
}

/// One Apple chrome button's hotspot: the skin buttons' hotspot view
/// (`HardwareButtonHotspotView`: mouse down and up, hover, the window
/// resigning key, accessibility), named for the chrome's button.
struct AppleChromeButtonHotspot: NSViewRepresentable {
    let description: HardwareButtonHotspotView.Description
    let onPress: () -> Void
    let onRelease: () -> Void
    let onHover: (Bool) -> Void
    let onResignKey: () -> Void

    func makeNSView(context: Context) -> HardwareButtonHotspotView {
        let view = HardwareButtonHotspotView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ view: HardwareButtonHotspotView, context: Context) {
        configure(view)
    }

    static func dismantleNSView(_ view: HardwareButtonHotspotView, coordinator: ()) {
        view.tearDown()
    }

    private func configure(_ view: HardwareButtonHotspotView) {
        view.buttonDescription = description
        view.onPress = onPress
        view.onRelease = onRelease
        view.onHover = onHover
        view.onResignKey = onResignKey
    }
}

// MARK: - Touch feedback

/// Renders `TouchFeedbackModel`'s dots over the live picture: a translucent
/// ~44 pt (phone points) circle for a press, a faint ring while the runner
/// works, a dashed grey dot for a dropped tap. Thin: all state is the model.
struct TouchFeedbackOverlay: View {
    let model: TouchFeedbackModel
    /// View points per screen pixel; the phone's ~3 px per point is folded in.
    let perPoint: CGFloat

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(paused: model.isEmpty)) { timeline in
                let now = ProcessInfo.processInfo.systemUptime
                let _ = timeline.date
                ZStack(alignment: .topLeading) {
                    ForEach(Array(model.visibleDots(now: now).enumerated()), id: \.offset) { _, dot in
                        let size = 44 * 3 * perPoint
                        dotShape(dot.phase)
                            .frame(width: size, height: size)
                            .opacity(model.opacity(of: dot, now: now))
                            .position(x: dot.point.x * proxy.size.width, y: dot.point.y * proxy.size.height)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func dotShape(_ phase: TouchFeedbackModel.Dot.Phase) -> some View {
        switch phase {
        case .pressing:
            Circle().fill(Color.white.opacity(0.45)).overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1.5))
        case .inFlight, .fading:
            Circle().stroke(Color.white, lineWidth: 2)
        case .dropped:
            Circle().stroke(Color.gray, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
        }
    }
}
