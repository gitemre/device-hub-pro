import SwiftUI

/// The one screen: the sky over the whole window, the cover clock or the
/// glass deck over it, and the toolbar items that join the vertical bar on
/// the cover and the wide inner window.
struct RootView: View {
    let model: DayModel

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        let regularWidth = horizontalSizeClass == .regular
        NavigationStack {
            DayStage(model: model)
        }
        // The angle sets the time, never the status: tent reads `closed`
        // at 71.1° on iOS 27.1.
        .onHingeChange { old, new in
            model.hingeChanged(old: old, new: new, regularWidth: regularWidth)
        }
        .modifier(PhaseFeedback(model: model))
        // Restarted when the window changes width class, so the hinge-less
        // start reads the sky the window shows.
        .task(id: regularWidth) {
            do {
                try await Task.sleep(for: DayModel.hingeGrace)
            } catch {
                return
            }
            model.hingeGraceEnded(regularWidth: regularWidth)
        }
        .task {
            var waited = Duration.zero
            for toggle in model.timeLapseToggles {
                do {
                    try await Task.sleep(for: toggle - waited)
                } catch {
                    return
                }
                waited = toggle
                model.toggleTimeLapse(regularWidth: horizontalSizeClass == .regular, reason: "launchArgument")
            }
        }
    }
}

/// The haptic and the VoiceOver announcement for a phase change the viewer
/// caused. A modifier of its own, so that only it reads the phase: read in
/// `RootView`, every phase change re-ran the root's body.
private struct PhaseFeedback: ViewModifier {
    let model: DayModel

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(.selection, trigger: model.phase) { _, _ in
                model.phaseChangeIsFelt
            }
            // A VoiceOver user folding the phone hears the time of day
            // change; the sky's own label only updates while it has focus.
            .onChange(of: model.phase) { _, phase in
                guard voiceOver, model.phaseChangeIsFelt, let phase else { return }
                AccessibilityNotification.Announcement(phase.title).post()
            }
    }
}

/// Reads the full window and hands it to the content as a value: the fold
/// from the division regions, the safe area from the outer reader. This
/// closure reads geometry and the environment only, so a hinge update or a
/// Time-Lapse step redraws the content, not the readers; and nothing it
/// reads is stored, so a layout pass can never cause another.
private struct DayStage: View {
    let model: DayModel

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.toolbarVerticalEdge) private var toolbarVerticalEdge

    var body: some View {
        // Two readers: a reader that ignores the safe area reports none
        // (iOS 27.1 logged zero insets beside the 84 pt vertical bar), so
        // the outer one, inside the safe area, reads the insets.
        GeometryReader { safe in
            let safeArea = safe.safeAreaInsets
            // The full window, not the safe area: the division regions are
            // in window coordinates, and the sky fills the window.
            GeometryReader { proxy in
                let window = readings(of: proxy, safeArea: safeArea)
                DayContent(model: model, window: window)
                    .onChange(of: window, initial: true) { _, window in
                        model.windowChanged(window)
                    }
            }
            .ignoresSafeArea()
        }
        .toolbarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar, .bottomBar)
        .toolbar {
            DayToolbar(model: model, hasTimeLapse: horizontalSizeClass != .regular)
        }
    }

    private func readings(of proxy: GeometryProxy, safeArea: EdgeInsets) -> WindowReadings {
        let regions = proxy.reservedRegions(kind: .division, options: .includeInactive).map(FoldRegion.init(reserved:))
        let layout = FoldLayout.layout(
            width: Double(proxy.size.width),
            height: Double(proxy.size.height),
            regularWidth: horizontalSizeClass == .regular,
            regions: regions
        )
        return WindowReadings(
            size: proxy.size,
            safeArea: safeArea,
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            regions: regions,
            layout: layout,
            barEdge: toolbarVerticalEdge
        )
    }
}

/// Everything on the stage that follows the day: the sky, and the cover
/// clock or the deck, placed from one window reading.
private struct DayContent: View {
    @Bindable var model: DayModel
    let window: WindowReadings

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var regularWidth: Bool { window.horizontalSizeClass == .regular }

    var body: some View {
        let areas = ControlAreas(safeArea: EdgePadding(window.safeArea), layout: window.layout)
        let angle = model.shownAngle(regularWidth: regularWidth)
        let phase = DayCycle.phase(progress: DayCycle.progress(angleDegrees: angle))
        let resting = model.restingAngle(regularWidth: regularWidth)
        ZStack {
            SkyScene(
                angle: resting,
                timeLapse: model.timeLapse,
                timeLapseWeight: model.isTimeLapsing ? 1 : 0,
                layout: window.layout, focusX: focusX, clearMaxX: clearMaxX
            )
            .animation(reduceMotion ? nil : model.angleMotion.animation, value: resting)
            .animation(reduceMotion ? nil : DayModel.AngleMotion.follow.animation, value: model.isTimeLapsing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(skyLabel(angle: angle, phase: phase))
            .accessibilityAddTraits([.isImage, .updatesFrequently])
            if regularWidth {
                Deck(
                    angle: angle,
                    phase: phase,
                    timeLapse: { model.toggleTimeLapse(regularWidth: true) },
                    isTimeLapsing: model.isTimeLapsing,
                    scrubbing: scrubbing(angle)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(EdgeInsets(areas.deck))
            } else {
                VStack(spacing: 16) {
                    CoverClock(
                        phase: phase,
                        progress: DayCycle.progress(angleDegrees: angle),
                        shortSide: min(window.size.width, window.size.height),
                        isLandscape: window.size.width > window.size.height
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let scrubbing = scrubbing(angle) {
                        Deck(angle: angle, phase: phase, scrubbing: scrubbing)
                    }
                }
                .padding(EdgeInsets(areas.safe))
            }
        }
        .sheet(isPresented: $model.showsReadings) {
            ReadingsSheet(model: model, window: window)
        }
    }

    /// On the cover, the middle of the safe area, where the clock is
    /// centred: the vertical bar takes 84 pt from one side, which would
    /// otherwise leave the sun rising off to one side of the time.
    private var focusX: Double? {
        guard !regularWidth else { return nil }
        let insets = window.safeArea
        return Double(insets.leading + (window.size.width - insets.leading - insets.trailing) / 2)
    }

    /// Where the vertical bar (or nothing) begins on the right.
    private var clearMaxX: Double {
        Double(window.size.width - window.safeArea.trailing)
    }

    /// The slider's value, only once the device is known to have no hinge.
    private func scrubbing(_ angle: Double) -> Binding<Double>? {
        guard model.availability == .absent else { return nil }
        return Binding(get: { angle }, set: { model.scrub(to: $0) })
    }

    private func skyLabel(angle: Double, phase: DayPhase) -> String {
        if let degrees = model.hingeDegrees {
            return "Sky at \(phase.title), hinge \(Int(degrees.rounded())) degrees"
        }
        return "Sky at \(phase.title), \(Int(angle.rounded())) degrees"
    }
}

/// Readings, and on the cover the Time-Lapse; inside, the deck is the
/// Time-Lapse's control. Both join the vertical bar where there is one, and
/// in the tall laptop window Readings sits in the bottom bar, on the base.
private struct DayToolbar: ToolbarContent {
    let model: DayModel
    let hasTimeLapse: Bool

    var body: some ToolbarContent {
        if hasTimeLapse {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.toggleTimeLapse(regularWidth: false)
                } label: {
                    Label("Time-Lapse", systemImage: model.isTimeLapsing ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(model.isTimeLapsing ? "Pause Time-Lapse" : "Play Time-Lapse")
                .accessibilityHint("Plays a day from night to noon and back. Moving the hinge stops it.")
            }
            .axisBehavior(.verticalPreferred)
        }
        ToolbarItem(placement: .bottomBar) {
            Button {
                model.showsReadings = true
            } label: {
                Label("Readings", systemImage: "gauge.with.needle")
            }
            .accessibilityHint("Shows the hinge and window readings.")
        }
        .axisBehavior(.verticalPreferred)
    }
}

extension EdgePadding {
    init(_ insets: EdgeInsets) {
        self.init(
            top: Double(insets.top),
            leading: Double(insets.leading),
            bottom: Double(insets.bottom),
            trailing: Double(insets.trailing)
        )
    }
}

extension EdgeInsets {
    init(_ padding: EdgePadding) {
        self.init(
            top: CGFloat(padding.top),
            leading: CGFloat(padding.leading),
            bottom: CGFloat(padding.bottom),
            trailing: CGFloat(padding.trailing)
        )
    }
}

extension FoldRegion {
    /// A SwiftUI division region, in the coordinates of the geometry that
    /// reported it.
    init(reserved region: ReservedRegion) {
        self.init(
            x: Double(region.frame.minX),
            y: Double(region.frame.minY),
            width: Double(region.frame.width),
            height: Double(region.frame.height),
            isActive: region.isActive
        )
    }
}
