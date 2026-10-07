import SwiftUI
import DeviceHubProKit

/// A right-click menu entry for an emulator control button.
struct EmulatorMenuItem {
    let title: String
    var isEnabled = true
    let action: () async -> Void

    init(title: String, isEnabled: Bool = true, action: @escaping () async -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.action = action
    }
}

/// A control button with tap, optional long-press and a right-click menu —
/// mirroring the hardware/emulator button behaviours. Like a system button,
/// dragging a press off the button shows it released and a release there
/// does nothing; the pointer feedback is Device Hub's hover/press `platter`
/// (PL-01/PL-02).
struct EmulatorPressButton<Label: View>: View {
    var size: CGSize = CGSize(width: 44, height: 38)
    /// The part of `size` that takes the pointer, centred (DH's pill buttons
    /// are 32 × 28 pt targets in 34 pt slots); nil is all of it.
    var hitSize: CGSize?
    var platter: PlatterShape?
    let onTap: () async -> Void
    var onLongPress: (() async -> Void)?
    var menuItems: [EmulatorMenuItem] = []
    var accessibilityTitle: String = ""
    /// Whether the title is also the button's tooltip. Device Hub's stage
    /// pill has none (measured: no help text on any pill button).
    var showsTooltip = true
    /// A tooltip of its own, shown whether or not `showsTooltip` is on (the
    /// physical pill's reason a button is off).
    var help: String?
    @ViewBuilder var label: () -> Label

    @State private var holdTask: Task<Void, Never>?
    @State private var isPressing = false
    /// Whether the pressing pointer is over the button.
    @State private var isPressInside = false
    @State private var isHovered = false
    @State private var longPressTriggered = false
    /// True while the drag gesture runs; SwiftUI resets it when the gesture
    /// ends *or is cancelled* — a cancelled one never reaches `onEnded`.
    @GestureState private var isGestureActive = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label()
            .frame(width: size.width, height: size.height)
            .opacity(isEnabled ? 1 : ParityMetrics.chromeDisabledGlyphOpacity)
            .background {
                if let platter {
                    PlatterView(
                        shape: platter,
                        fill: PointerFeedback.fill(
                            isHovered: isHovered,
                            isPressed: isPressing && isPressInside,
                            isEnabled: isEnabled
                        )
                    )
                }
            }
            .contentShape(Path(hitRect))
            .onHover { isHovered = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isGestureActive) { _, active, _ in active = true }
                    .onChanged { value in
                        guard isEnabled else { return }
                        isPressInside = hitRect.contains(value.location)
                        startPressIfNeeded()
                    }
                    .onEnded { value in
                        endPress(inside: isEnabled && hitRect.contains(value.location))
                    }
            )
            // A press the system cancelled (the pill disabled or removed
            // mid-press) must not stay drawn pressed, nor leave a fired
            // long press to swallow the next click.
            .onChange(of: isGestureActive) { _, active in
                if !active { resetPress() }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { resetPress() }
            }
            .onDisappear { resetPress() }
            .help(help ?? (showsTooltip ? accessibilityTitle : ""))
            .contextMenu {
                ForEach(Array(menuItems.enumerated()), id: \.offset) { _, item in
                    Button(item.title) {
                        Task { await item.action() }
                    }
                    .disabled(!item.isEnabled)
                }
            }
            // Keyboard: with keyboard navigation on, Tab reaches the button
            // and Space or Return taps it, like a system button. Nothing
            // around it may be a `GlassEffectContainer` (`DeviceControlPill`).
            .contentShape(.focusEffect, Capsule())
            .focusable(interactions: .activate)
            .onKeyActivation([.space, .return]) {
                guard isEnabled else { return .ignored }
                Task { await onTap() }
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityTitle.isEmpty ? "Emulator control" : accessibilityTitle)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                guard isEnabled else { return }
                Task { await onTap() }
            }
    }

    /// The pointer's target, in the button's own coordinates.
    private var hitRect: CGRect {
        let hit = hitSize ?? size
        return CGRect(x: (size.width - hit.width) / 2, y: (size.height - hit.height) / 2, width: hit.width, height: hit.height)
    }

    /// Whether a gesture location (the button's own coordinates) is on it.
    static func contains(_ location: CGPoint, in size: CGSize) -> Bool {
        CGRect(origin: .zero, size: size).contains(location)
    }

    private func startPressIfNeeded() {
        guard !isPressing else { return }
        isPressing = true
        longPressTriggered = false

        // Only a button with a long-press action turns a held press into
        // one: without it a slow click (≥ 350 ms) was swallowed — the hold
        // marked the press as a long press and the release skipped the tap.
        guard let onLongPress else { return }
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, isPressing, isPressInside else { return }
            longPressTriggered = true
            // Its own task: the release cancels the hold timer, and with it
            // it cancelled the action it had started (a copy to the
            // clipboard or a rotation still in flight when the button came
            // up).
            Task { await onLongPress() }
        }
    }

    private func endPress(inside: Bool) {
        guard isPressing else { return }
        isPressing = false
        holdTask?.cancel()
        holdTask = nil

        if !longPressTriggered, inside {
            Task { await onTap() }
        }
        longPressTriggered = false
    }

    /// Clears a press without acting on it.
    private func resetPress() {
        guard isPressing || longPressTriggered else { return }
        isPressing = false
        isPressInside = false
        holdTask?.cancel()
        holdTask = nil
        longPressTriggered = false
    }
}

/// Single bottom-center control pill, Device Hub style: the [home │
/// screenshot │ record] capsule plus a separate rotate circle — exactly DH's
/// silhouette, with no `…` slot. The Android navigation keys and the emulator
/// extras live in the Device/Controls menus and on the device's own on-screen
/// navigation bar; the pill's buttons keep their long-press and right-click
/// behaviours, and carry no tooltips, like DH's.
///
/// The first button is Home (DH's "Home", `app.grid.3x3`): it presses the
/// device's Home button. The inspector's Apps tab is reached from the
/// toolbar's segments, as in DH.
struct DeviceControlPill: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: ParityMetrics.pillSpacing) {
            HStack(spacing: 0) {
                EmulatorPressButton(
                    size: pillButtonSize,
                    hitSize: ParityMetrics.pillButtonHitSize,
                    platter: .capsule(ParityMetrics.pillPlatterSize),
                    onTap: { await pressHome() },
                    accessibilityTitle: "Home",
                    showsTooltip: false,
                    // A physical iPhone without Control says why in the
                    // tooltip (Home starts Control on demand).
                    help: physicalActionReason
                ) {
                    PillGridGlyph()
                }
                .disabled(!canPressHome)
                .padding(.leading, ParityMetrics.pillCapsulePadding)

                EmulatorPressButton(
                    size: pillButtonSize,
                    hitSize: ParityMetrics.pillButtonHitSize,
                    platter: .capsule(ParityMetrics.pillPlatterSize),
                    onTap: { await workspace.capture.takeScreenshot() },
                    onLongPress: { await workspace.capture.copyScreenshotToClipboard() },
                    menuItems: [
                        // The annotation editor, off the default path:
                        // DH's button saves at once.
                        EmulatorMenuItem(title: "Annotate Screenshot…", isEnabled: workspace.capture.canTakeScreenshot) {
                            await workspace.capture.annotateScreenshot()
                        },
                        EmulatorMenuItem(title: "Copy to Clipboard", isEnabled: workspace.capture.canTakeScreenshot) {
                            await workspace.capture.copyScreenshotToClipboard()
                        },
                        EmulatorMenuItem(
                            title: model.preferences.includeDeviceFrameInScreenshots
                                ? "Exclude Device Frame"
                                : "Include Device Frame",
                            isEnabled: workspace.capture.canTakeScreenshot
                        ) {
                            model.preferences.setIncludeDeviceFrameInScreenshots(
                                !model.preferences.includeDeviceFrameInScreenshots
                            )
                        },
                    ],
                    accessibilityTitle: "Screenshot",
                    showsTooltip: false
                ) {
                    pillLabel("camera.viewfinder")
                }
                // Off (no platter, dimmed) where it cannot act, as in
                // the Device menu; a simulator captures from its canvas.
                .disabled(!workspace.capture.canTakeScreenshot)
                .padding(.trailing, isPhysicalPill ? ParityMetrics.pillCapsulePadding : 0)

                // Device Hub's Record Screen is disabled for a physical
                // iPhone: its pill has no Record button (recording stays
                // reachable through the Controls menu's item).
                if !isPhysicalPill {
                    EmulatorPressButton(
                        size: pillButtonSize,
                        hitSize: ParityMetrics.pillButtonHitSize,
                        platter: .capsule(ParityMetrics.pillPlatterSize),
                        onTap: { await workspace.media.toggleRecording() },
                        menuItems: recordMenuItems,
                        accessibilityTitle: workspace.media.isRecording ? "Stop Recording" : "Record",
                        showsTooltip: false
                    ) {
                        // The glyph swap animates as a symbol replace (it
                        // snapped) when recording starts or stops.
                        pillLabel(workspace.media.isRecording ? "stop.circle.fill" : "record.circle")
                            .contentTransition(.symbolEffect(.replace))
                            .animation(reduceMotion ? nil : MotionMetrics.banner, value: workspace.media.isRecording)
                    }
                    .padding(.trailing, showsReplayButton ? 0 : ParityMetrics.pillCapsulePadding)

                    // Save the last N seconds: only where a replay ring
                    // exists for this device (an Android device, a
                    // simulator's live canvas), off only while it saves or
                    // before the ring has frames.
                    if showsReplayButton {
                        EmulatorPressButton(
                            size: pillButtonSize,
                            hitSize: ParityMetrics.pillButtonHitSize,
                            platter: .capsule(ParityMetrics.pillPlatterSize),
                            onTap: { await workspace.media.saveReplay() },
                            accessibilityTitle: "Save Replay",
                            showsTooltip: false,
                            help: workspace.media.replayTooltip
                        ) {
                            pillLabel("clock.arrow.circlepath")
                        }
                        .disabled(!workspace.media.canSaveReplayNow)
                        .padding(.trailing, ParityMetrics.pillCapsulePadding)
                        .popover(
                            isPresented: Binding(
                                get: { workspace.media.replayHintVisible },
                                set: { workspace.media.replayHintVisible = $0 }
                            ),
                            arrowEdge: .top
                        ) {
                            Text(workspace.media.replayHintText)
                                .font(.callout)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                    }
                }
            }
            // One interactive glass capsule behind the three buttons, and no
            // GlassEffectContainer: on macOS 27 the buttons' own interactive
            // glass, joined with `glassEffectUnion` inside a container, sent
            // AppKit's key-view walk (AutoFill runs it each time a text field
            // takes focus: the sidebar's search, the log search) into a loop
            // that never ended, and the app hung at 100 % CPU while a device
            // was live (SIM-18, `DeviceControlPillKeyViewTests`). The
            // toolbar's capsule groups have one parent glass too
            // (`toolbarControlSurface`).
            .background(ParityMetrics.pillLift, in: Capsule())
            .liquidGlass(interactive: true, tint: ParityMetrics.pillTint, in: Capsule())
            .glassHairline(in: Capsule())
            .dhGlassRim(in: Capsule())

            // A TV, a watch and a car do not rotate: no Rotate button.
            if workspace.deviceRotates {
            EmulatorPressButton(
                size: CGSize(
                    width: ParityMetrics.pillCircleDiameter,
                    height: ParityMetrics.pillCircleDiameter
                ),
                platter: .circle(diameter: ParityMetrics.pillCirclePlatterDiameter),
                onTap: { await rotate(left: true) },
                onLongPress: { await rotate(left: false) },
                menuItems: [
                    EmulatorMenuItem(title: "Rotate Left", isEnabled: canRotate) { await rotate(left: true) },
                    EmulatorMenuItem(title: "Rotate Right", isEnabled: canRotate) { await rotate(left: false) },
                ],
                accessibilityTitle: "Rotate Left",
                showsTooltip: false,
                help: isPhysicalPill ? workspace.physicalLive.rotationAvailability : nil
            ) {
                PillRotateGlyph()
            }
            // A simulator turns only where its session can (the live
            // canvas, or devicectl at T2); an Android device as before; a
            // physical iPhone turns through devicectl, no Control.
            .disabled(!canRotate)
            .background(ParityMetrics.pillLift, in: Circle())
            .liquidGlass(interactive: true, tint: ParityMetrics.pillTint, in: Circle())
            .glassHairline(in: Circle())
            .dhGlassRim(in: Circle())
            }
        }
    }

    /// The record button's right-click menu. Save Replay is listed where a
    /// replay ring exists (`MediaCaptureController.offersReplay`).
    private var recordMenuItems: [EmulatorMenuItem] {
        var items = [
            EmulatorMenuItem(title: workspace.media.isRecording ? "Stop Recording" : "Start Recording") {
                await workspace.media.toggleRecording()
            },
        ]
        if workspace.media.offersReplay {
            items.append(EmulatorMenuItem(
                title: "Save Replay (\(workspace.media.replayWindowLabel))",
                isEnabled: workspace.media.canSaveReplay
            ) {
                await workspace.media.saveReplay()
            })
        }
        return items
    }

    /// Whether the pill carries the Save Replay button.
    private var showsReplayButton: Bool { !isPhysicalPill && workspace.media.offersReplay }

    private var pillButtonSize: CGSize {
        CGSize(width: ParityMetrics.pillButtonWidth, height: ParityMetrics.pillHeight)
    }

    private func pillLabel(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: ParityMetrics.pillIconSize, weight: .medium))
    }

    // MARK: - Home

    /// Home works wherever the device has a Home to press: an Android
    /// device (its key event), a simulator whose session takes hardware
    /// buttons, a physical iPhone under Control.
    private var canPressHome: Bool {
        // A physical iPhone: Home starts Control on demand, so it is
        // available whenever Control could start (a Development Team ID is
        // set and the picture shows) or already runs.
        if isPhysicalPill { return Self.physicalActionAvailable(reason: workspace.physicalLive.controlAvailability) }
        return Self.homeAvailable(
            device: workspace.context.device,
            isPhysicalView: workspace.context.isPhysicalView,
            capabilities: workspace.context.capabilities,
            physicalControlReady: workspace.physicalControl.isReady
        )
    }

    /// The physical pill's Home and Rotate (Device Hub's, white and enabled):
    /// on whenever Control can start or runs, else off with the reason as the
    /// tooltip. `reason` is `DeviceWorkspace.physicalLive.controlAvailability`.
    static func physicalActionAvailable(reason: String?) -> Bool {
        reason == nil
    }

    /// The physical pill has three buttons (Home, Screenshot, Rotate) and no
    /// Record.
    private var isPhysicalPill: Bool { workspace.context.isPhysicalView }

    /// Why a physical iPhone's Home and Rotate are off; nil elsewhere and
    /// when they are on.
    private var physicalActionReason: String? {
        isPhysicalPill ? workspace.physicalLive.controlAvailability : nil
    }

    private var canRotate: Bool {
        if isPhysicalPill { return Self.physicalActionAvailable(reason: workspace.physicalLive.rotationAvailability) }
        return !(workspace.context.device?.platform == .apple && !workspace.context.capabilities.contains(.rotate))
    }

    private func rotate(left: Bool) async {
        if isPhysicalPill {
            workspace.physicalLive.rotate(left: left)
        } else {
            await workspace.rotateDevice(left ? .left : .right)
        }
    }

    static func homeAvailable(
        device: DeviceRef?,
        isPhysicalView: Bool,
        capabilities: DeviceCapabilities,
        physicalControlReady: Bool
    ) -> Bool {
        guard let device else { return false }
        if isPhysicalView { return physicalControlReady }
        switch device.platform {
        case .android: return true
        case .apple: return capabilities.contains(.hardwareButtons)
        }
    }

    private func pressHome() async {
        guard canPressHome else { return }
        if workspace.context.isPhysicalView {
            workspace.physicalLive.pressHome()
        } else if workspace.context.device?.platform == .apple {
            workspace.simulatorCanvas.home()
        } else {
            await workspace.mirror.goHome()
        }
    }
}

/// Device Hub's Rotate glyph (a custom symbol, not in SF Symbols): a rounded
/// square, 9.8 pt with a 1.2 pt stroke, with a curved arrow at its top right
/// (ending in a head that points left) and the same arrow turned half a turn
/// at its bottom left; measured on DH 27.0 at 2x, the whole glyph 18.8 x 21 pt.
struct PillRotateGlyph: View {
    var body: some View {
        Canvas { context, size in
            var context = context
            context.translateBy(x: size.width / 2 - 0.5, y: size.height / 2)
            let stroke = StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
            context.stroke(
                Path(roundedRect: CGRect(x: -4.9, y: -4.9, width: 9.8, height: 9.8), cornerRadius: 1.9, style: .continuous),
                with: .foreground,
                style: stroke
            )
            var arrow = Path()
            arrow.move(to: CGPoint(x: 8.9, y: -4.5))
            arrow.addCurve(
                to: CGPoint(x: 5.4, y: -8.9),
                control1: CGPoint(x: 8.9, y: -7.0),
                control2: CGPoint(x: 7.5, y: -8.9)
            )
            var head = Path()
            head.move(to: CGPoint(x: 2.7, y: -8.9))
            head.addLine(to: CGPoint(x: 5.7, y: -11.0))
            head.addLine(to: CGPoint(x: 5.7, y: -6.9))
            head.closeSubpath()
            for turns in 0..<2 {
                var placed = context
                if turns == 1 { placed.rotate(by: .degrees(180)) }
                placed.stroke(arrow, with: .foreground, style: stroke)
                placed.fill(head, with: .foreground)
                placed.stroke(head, with: .foreground, style: StrokeStyle(lineWidth: 0.5, lineJoin: .round))
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

/// Device Hub's Home glyph (`app.grid.3x3`, a custom symbol of its own, not
/// in SF Symbols): nine small squares, 12.75 pt across (measured: each
/// 3.25 pt with 1.5 pt between).
struct PillGridGlyph: View {
    var body: some View {
        Canvas { context, size in
            let dot = ParityMetrics.pillGridDot
            let gap = ParityMetrics.pillGridGap
            let total = dot * 3 + gap * 2
            let origin = CGPoint(x: (size.width - total) / 2, y: (size.height - total) / 2)
            for row in 0..<3 {
                for column in 0..<3 {
                    let rect = CGRect(
                        x: origin.x + CGFloat(column) * (dot + gap),
                        y: origin.y + CGFloat(row) * (dot + gap),
                        width: dot,
                        height: dot
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: ParityMetrics.pillGridCorner, style: .continuous),
                        with: .foreground
                    )
                }
            }
        }
        .frame(width: ParityMetrics.pillGridDot * 3 + ParityMetrics.pillGridGap * 2,
               height: ParityMetrics.pillGridDot * 3 + ParityMetrics.pillGridGap * 2)
        .accessibilityHidden(true)
    }
}
