import AppKit
import SwiftUI
import DeviceHubProKit

// MARK: - Where the buttons are offered

extension EnvironmentValues {
    /// Whether the framed stage offers the skin's side buttons (HW-01). Only
    /// the main stage's `MirrorContainer` sets it; the compact window never
    /// shows them.
    @Entry var showsHardwareButtons = false
    /// Whether the mirror views below publish their scale (points per
    /// streamed pixel) to the stage zoom: the main stage only, so the compact
    /// window's own layout never answers for it (TB-08).
    @Entry var reportsStageScale = false
    /// Whether the mirror views below draw their screen black instead of the
    /// stream: a simulator that is still booting shows the device with a
    /// black screen and a spinner, as Device Hub does, not the boot logo.
    @Entry var blanksMirror = false
}

// MARK: - Geometry

/// Where the side buttons of a skin plan (`DeviceComposition.buttons`) sit
/// on the stage, and the room they get to roll out.
enum HardwareButtonsLayout {
    /// The most the stage widens on each side for the buttons, points.
    static let maxPad: CGFloat = 8
    /// The room past the artwork's overhang a button gets to roll out into,
    /// points: the most it rolls out.
    static let travelRoom: CGFloat = MotionMetrics.chromeHoverTravelMaxPoints
    /// How far the sprites' canvas reaches past the artwork's right edge,
    /// points: past the farthest a sprite rolls out, so nothing is drawn
    /// outside the canvas. Whole points, so the canvas's right edge falls on
    /// the pixel grid as the artwork's does, the same distance further on.
    static let spriteRoom: CGFloat = maxPad
    /// A hotspot reaches this far past its button's outer edge, points.
    static let hotspotOutset: CGFloat = 6
    /// And this far into the body past the button's inner edge, points.
    static let hotspotInset: CGFloat = 4

    /// The pad on both sides of the layout box that makes room for the
    /// buttons: `min(8, ceil(overhang + 6))` points, where the overhang is
    /// how far the artwork reaches past the layout box's right edge at
    /// `pointsPerUnit`. Symmetric, so the device's centre does not move.
    static func buttonPad(_ plan: DeviceComposition, pointsPerUnit: CGFloat) -> CGFloat {
        guard case let .skin(artworkRect, _, _, _) = plan.body else { return 0 }
        let overhang = max(0, artworkRect.maxX - plan.layoutSize.width) * pointsPerUnit
        return min(maxPad, (overhang + travelRoom).rounded(.up))
    }

    /// Each button's hotspot in the placed composition, points: its rect
    /// widened `hotspotOutset` outward and `hotspotInset` inward, and held
    /// inside the composition (a view outside it would not be hit).
    static func hotspots(_ plan: DeviceComposition, placed: PlacedComposition, pointsPerUnit: CGFloat) -> [HardwareKey: CGRect] {
        var hotspots: [HardwareKey: CGRect] = [:]
        for button in plan.buttons {
            let rect = button.rect
            let minX = placed.layoutOrigin.x + rect.minX * pointsPerUnit - hotspotInset
            let maxX = min(placed.layoutOrigin.x + rect.maxX * pointsPerUnit + hotspotOutset, placed.size.width)
            hotspots[button.key] = CGRect(
                x: minX,
                y: placed.layoutOrigin.y + rect.minY * pointsPerUnit,
                width: max(maxX - minX, 0),
                height: rect.height * pointsPerUnit
            )
        }
        return hotspots
    }
}

// MARK: - State

/// The buttons' pointer state on one stage: the groups rolled out under the
/// pointer, the keys held down, and which frame the stage draws. It presses
/// and releases the keys on the session (`MirrorController.pressHardwareKey`),
/// so what the stage shows held is what the device holds.
///
/// While every button rests the stage draws the artwork whole; while one is
/// out of its place, the frame split into sprites (`LiveButtonArt`). The
/// two are not the same pixels once minified: filtered apart, the split at
/// rest differs from the artwork whole by up to 88 levels around the
/// buttons on a 1x display (46 along the 10 Pro's straight run), and 61 at
/// 2x at the buttons' ends. So the switch to the split happens only as a
/// button starts to move (hidden by the move), and the switch back is a
/// cross-fade once every button is at rest (`restFade`). Under Reduce
/// Motion nothing moves and the split is never drawn: hover shows nothing
/// and a held key is only tinted over the whole artwork
/// (`HardwareButtonTint`).
@MainActor
@Observable
final class HardwareButtonsState {
    /// Button groups rolled out (power; the rocker, whose two halves roll
    /// out together).
    private(set) var popped: Set<Int> = []
    /// Keys held down.
    private(set) var pressed: Set<HardwareKey> = []
    /// Whether the stage draws the frame split (the sprites under the frame
    /// without them) rather than the artwork whole only: from the moment a
    /// button starts to move until the hand-back to the artwork ends.
    private(set) var drawsSplit = false
    /// How far the hand-back from the split to the artwork whole has come:
    /// 0 while a button is away from rest, 1 at rest. Animated
    /// (`MotionMetrics.chromeRestFade`); the stage draws each frame at its
    /// share (`RestFadeOpacity`).
    private(set) var restFade: Double = 1
    /// Buttons still easing back to rest.
    private var returning = 0
    /// The hotspots under the pointer, with their group.
    @ObservationIgnored private var hovered: [HardwareKey: Int] = [:]
    @ObservationIgnored private var hoverOff: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var fadeGeneration = 0
    /// Runs a change in an animation and calls back when it completes
    /// (`withAnimation(_:_:completion:)`); a test completes them itself.
    @ObservationIgnored private let animate: Animate

    typealias Animate = @MainActor (Animation?, () -> Void, @escaping @MainActor () -> Void) -> Void

    init(animate: @escaping Animate = { animation, body, completion in
        withAnimation(animation, body, completion: completion)
    }) {
        self.animate = animate
    }

    /// A button is out of its place or on its way back.
    var isAwayFromRest: Bool {
        !popped.isEmpty || !pressed.isEmpty || returning > 0
    }

    /// Runs `body`, a change that brings a button back to rest, in
    /// `animation`, counting it as returning until the animation completes
    /// (a completion from before `releaseAll` counts for nothing); then,
    /// if every button rests, the frame is handed back to the artwork.
    private func returnToRest(_ animation: Animation?, _ body: () -> Void) {
        returning += 1
        let generation = self.generation
        animate(animation, body) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.returning = max(self.returning - 1, 0)
            self.handBackIfAtRest()
        }
    }

    /// A button starts to move: the stage draws the split from this frame
    /// on, at once (never faded in: the move hides the switch), whether or
    /// not a hand-back was under way.
    private func leaveRest() {
        guard !drawsSplit || restFade != 0 else { return }
        fadeGeneration += 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            drawsSplit = true
            restFade = 0
        }
    }

    /// Every button is at rest: the split cross-fades back to the artwork
    /// whole, and is dropped when the fade ends (a later move cancels it).
    private func handBackIfAtRest() {
        guard drawsSplit, restFade == 0, !isAwayFromRest else { return }
        let fadeGeneration = self.fadeGeneration
        animate(MotionMetrics.chromeRestFade, { restFade = 1 }) { [weak self] in
            guard let self, self.fadeGeneration == fadeGeneration else { return }
            self.drawsSplit = false
        }
    }

    /// The pointer entered `key`'s hotspot: its group rolls out. Under
    /// Reduce Motion nothing rolls out, and hover shows nothing.
    func enter(_ key: HardwareKey, group: Int, reduceMotion: Bool) {
        hovered[key] = group
        hoverOff.removeValue(forKey: group)?.cancel()
        guard !reduceMotion, !popped.contains(group) else { return }
        leaveRest()
        withAnimation(MotionMetrics.chromeHoverOn) {
            _ = popped.insert(group)
        }
    }

    /// The pointer left `key`'s hotspot: once no hotspot of its group is
    /// under the pointer for `chromeHoverOffDelay`, the group eases back.
    /// Crossing from one rocker half to the other keeps it out, whichever
    /// order AppKit reports the two in.
    func exit(_ key: HardwareKey, reduceMotion: Bool) {
        guard let group = hovered.removeValue(forKey: key),
              !hovered.values.contains(group)
        else {
            return
        }
        hoverOff.removeValue(forKey: group)?.cancel()
        guard popped.contains(group) else { return }
        hoverOff[group] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(MotionMetrics.chromeHoverOffDelay))
            guard let self, !Task.isCancelled, !self.hovered.values.contains(group) else { return }
            self.hoverOff[group] = nil
            self.returnToRest(reduceMotion ? nil : MotionMetrics.chromeHoverOff) {
                _ = self.popped.remove(group)
            }
        }
    }

    /// A click went down on `key`'s button: the key goes down on the
    /// device and the button sinks (under Reduce Motion it is only tinted).
    func press(_ key: HardwareKey, on mirror: MirrorController, reduceMotion: Bool) {
        if !pressed.contains(key) {
            if !reduceMotion { leaveRest() }
            withAnimation(reduceMotion ? nil : MotionMetrics.chromePress) {
                _ = pressed.insert(key)
            }
        }
        mirror.pressHardwareKey(key)
    }

    /// `key`'s button sinks and comes back without anything reaching the
    /// device: the stage's "Click to wake" shows the power button a real
    /// phone would need (the wake itself is KEYCODE_WAKEUP, which a second
    /// Power press would undo). Under Reduce Motion it is only tinted.
    func pulse(_ key: HardwareKey, reduceMotion: Bool) async {
        guard !pressed.contains(key) else { return }
        if !reduceMotion { leaveRest() }
        withAnimation(reduceMotion ? nil : MotionMetrics.chromePress) {
            _ = pressed.insert(key)
        }
        try? await Task.sleep(for: .milliseconds(180))
        guard pressed.contains(key) else { return }
        returnToRest(reduceMotion ? nil : MotionMetrics.chromePress) {
            _ = pressed.remove(key)
        }
    }

    /// The click came up (wherever the pointer is): the key goes up.
    func release(_ key: HardwareKey, on mirror: MirrorController, reduceMotion: Bool) {
        if pressed.contains(key) {
            returnToRest(reduceMotion ? nil : MotionMetrics.chromePress) {
                _ = pressed.remove(key)
            }
        }
        mirror.releaseHardwareKey(key)
    }

    /// Every held key goes up and every button comes back to rest, at
    /// once, the artwork drawn whole again: the stage calls it when a
    /// click's mouse-up can no longer arrive or no longer means anything
    /// (the window resigns key, the buttons go away, the device starts
    /// turning).
    func releaseAll(on mirror: MirrorController) {
        for task in hoverOff.values { task.cancel() }
        hoverOff = [:]
        hovered = [:]
        generation += 1
        fadeGeneration += 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if !pressed.isEmpty { pressed = [] }
            if !popped.isEmpty { popped = [] }
            if returning != 0 { returning = 0 }
            if drawsSplit { drawsSplit = false }
            if restFade != 1 { restFade = 1 }
        }
        mirror.releaseAllHardwareKeys()
    }
}

/// One of the two frames the stage cross-fades between as the buttons come
/// back to rest (`HardwareButtonsState.restFade`, `progress`): over the
/// first half the artwork whole fades in over the split, over the second
/// the split fades out under it. Where the artwork is opaque the two mix
/// linearly and the stage never shows through; each end is exactly one
/// frame drawn alone, so neither the fade's start nor the split's removal
/// at its end changes a pixel.
struct RestFadeOpacity: ViewModifier, Animatable {
    enum Layer {
        /// The sprites and the frame without them.
        case split
        /// The artwork drawn whole.
        case whole
    }

    var progress: Double
    let layer: Layer

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.opacity(Self.opacity(of: layer, progress: progress))
    }

    nonisolated static func opacity(of layer: Layer, progress: Double) -> Double {
        switch layer {
        case .whole: min(max(2 * progress, 0), 1)
        case .split: min(max(2 - 2 * progress, 0), 1)
        }
    }
}

// MARK: - Frame

/// The frame artwork as the stage draws it with live side buttons, bottom
/// to top: the sprites, `backing` (which they never overlap), the frame
/// without the buttons, the artwork whole, and a held key's tint.
///
/// While every button rests only the artwork whole is drawn, exactly as
/// the stage draws it without buttons (the sprites stay in place, empty, so
/// the next move animates from rest). While one is out of its place
/// (`drawsSplit`) the split is drawn instead, and as they come back to
/// rest the two cross-fade (`restFade`, `RestFadeOpacity`). Under Reduce
/// Motion the split is never drawn and a held key is tinted over the
/// artwork whole (`HardwareButtonTint`).
struct LiveButtonsFrame<Backing: View>: View {
    let art: LiveButtonArt
    /// The artwork drawn whole.
    let whole: NSImage
    /// The artwork's frame in the composition, points.
    let artworkFrame: CGRect
    /// Each key's travel from rest, artwork pixels
    /// (`HardwareButtonSprites.offsets`).
    let offsets: [HardwareKey: CGFloat]
    /// Keys held down.
    let held: Set<HardwareKey>
    let drawsSplit: Bool
    let restFade: Double
    @ViewBuilder let backing: () -> Backing

    var body: some View {
        let room = HardwareButtonsLayout.spriteRoom
        HardwareButtonSprites(art: art, offsets: offsets, tinted: held, isShown: drawsSplit, trailingRoom: room)
            .frame(width: artworkFrame.width + room, height: artworkFrame.height)
            .offset(x: artworkFrame.minX, y: artworkFrame.minY)
            .modifier(RestFadeOpacity(progress: restFade, layer: .split))
        backing()
        if drawsSplit {
            FramedArtwork(image: art.background, frame: artworkFrame)
                .modifier(RestFadeOpacity(progress: restFade, layer: .split))
                // Switched at once with the sprites, never faded in or out
                // on its own: the stage would show through the frame.
                .transition(.identity)
        }
        FramedArtwork(image: whole, frame: artworkFrame)
            .modifier(RestFadeOpacity(progress: restFade, layer: .whole))
        HardwareButtonTint(art: art, keys: drawsSplit ? [] : held)
            .frame(width: artworkFrame.width, height: artworkFrame.height)
            .offset(x: artworkFrame.minX, y: artworkFrame.minY)
    }
}

/// A held key's tint over the artwork drawn whole, where the button does
/// not move (Reduce Motion): its sprite's silhouette in black at
/// `1 − chromePressTint`, which darkens the opaque button 8 % as the
/// darkened sprite does (`LiveButtonArt.darkKeys`) and leaves every other
/// pixel of the frame as it is. Laid out as the artwork is.
struct HardwareButtonTint: View {
    let art: LiveButtonArt
    let keys: Set<HardwareKey>

    var body: some View {
        let pieces = HardwareKey.allCases.filter(keys.contains).compactMap { art.keys[$0] }
        Canvas { context, size in
            guard !pieces.isEmpty, art.pixelSize.width > 0, art.pixelSize.height > 0 else { return }
            let sx = size.width / art.pixelSize.width
            let sy = size.height / art.pixelSize.height
            context.addFilter(.colorMultiply(.black))
            context.opacity = 1 - MotionMetrics.chromePressTint
            for piece in pieces {
                let rect = piece.rect
                context.draw(
                    Image(decorative: piece.sprite, scale: 1).interpolation(.high).antialiased(true),
                    in: CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Sprites

/// The buttons' sprites, drawn under the frame without them
/// (`LiveButtonArt.background`) in the artwork's own frame while a button
/// is out of its place (`LiveButtonsFrame`): a group rolls out on hover and
/// a held key sinks into the body, darkened (`MotionMetrics`). While every
/// button rests the stage draws the artwork whole and this draws nothing
/// (`isShown`), but stays in place, so the next move animates from rest.
///
/// One canvas laid out exactly as the artwork is (the same offset in the
/// same stack, the artwork's width plus `trailingRoom` whole points), so each
/// sprite lands on the pixels it was cut from, and a rolled-out sprite draws
/// past the artwork's edge into the stage's button pad inside the canvas.
struct HardwareButtonSprites: View, Animatable {
    let art: LiveButtonArt
    /// Each key's travel from rest, artwork pixels (outward positive).
    var power: CGFloat
    var volumeUp: CGFloat
    var volumeDown: CGFloat
    /// Keys drawn darkened.
    let tinted: Set<HardwareKey>
    /// Whether the sprites are drawn (the frame without them is): switched
    /// at once, never faded.
    let isShown: Bool
    /// How much wider than the artwork the canvas is laid out, points
    /// (`HardwareButtonsLayout.spriteRoom`).
    let trailingRoom: CGFloat

    init(
        art: LiveButtonArt,
        offsets: [HardwareKey: CGFloat],
        tinted: Set<HardwareKey>,
        isShown: Bool = true,
        trailingRoom: CGFloat = 0
    ) {
        self.art = art
        power = offsets[.power] ?? 0
        volumeUp = offsets[.volumeUp] ?? 0
        volumeDown = offsets[.volumeDown] ?? 0
        self.tinted = tinted
        self.isShown = isShown
        self.trailingRoom = trailingRoom
    }

    /// The offsets `state` asks for: a held key's press travel, else its
    /// group's hover travel when rolled out, else 0; all 0 under Reduce
    /// Motion.
    static func offsets(
        art: LiveButtonArt,
        state: HardwareButtonsState,
        pointsPerPixel: CGFloat,
        reduceMotion: Bool
    ) -> [HardwareKey: CGFloat] {
        var offsets: [HardwareKey: CGFloat] = [:]
        for button in art.buttons {
            if state.pressed.contains(button.key) {
                offsets[button.key] = MotionMetrics.chromePressTravel(depth: button.depth, reduceMotion: reduceMotion)
            } else if state.popped.contains(button.group) {
                offsets[button.key] = MotionMetrics.chromeHoverTravel(
                    depth: button.depth,
                    pointsPerPixel: pointsPerPixel,
                    reduceMotion: reduceMotion
                )
            } else {
                offsets[button.key] = 0
            }
        }
        return offsets
    }

    nonisolated var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(power, AnimatablePair(volumeUp, volumeDown)) }
        set {
            power = newValue.first
            volumeUp = newValue.second.first
            volumeDown = newValue.second.second
        }
    }

    func offset(of key: HardwareKey) -> CGFloat {
        switch key {
        case .power: return power
        case .volumeUp: return volumeUp
        case .volumeDown: return volumeDown
        }
    }

    /// What is drawn: each group as one piece while its keys are level
    /// (its held keys darkened in it), each key's own piece while they are
    /// not (a held rocker half sinks alone). See `LiveButtonArt` for why.
    func pieces() -> [(piece: LiveButtonArt.Piece, offset: CGFloat)] {
        var drawn: [(LiveButtonArt.Piece, CGFloat)] = []
        for group in art.groups.keys.sorted() {
            let keys = art.keys(in: group)
            guard let first = keys.first else { continue }
            let level = keys.allSatisfy { abs(offset(of: $0) - offset(of: first)) < 1e-3 }
            if level, let joined = art.groups[group]?[tinted.intersection(keys)] {
                drawn.append((joined, offset(of: first)))
            } else {
                for key in keys {
                    let piece = tinted.contains(key) ? art.darkKeys[key] : art.keys[key]
                    if let piece { drawn.append((piece, offset(of: key))) }
                }
            }
        }
        return drawn
    }

    var body: some View {
        let pieces = isShown ? pieces() : []
        let trailingRoom = self.trailingRoom
        Canvas { context, size in
            guard !pieces.isEmpty, art.pixelSize.width > 0, art.pixelSize.height > 0 else { return }
            let sx = (size.width - trailingRoom) / art.pixelSize.width
            let sy = size.height / art.pixelSize.height
            func scaled(_ rect: CGRect) -> CGRect {
                CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
            }
            let underBody = CGFloat(LiveButtonArt.seamUnderBody)
            let underSprite = CGFloat(LiveButtonArt.seamUnderSprite)
            for (piece, offset) in pieces {
                let rect = piece.rect
                // Sunk into the body, the sprite runs on under the body's
                // edge and needs no fill; its outer edge may lie inside the
                // fill's reach.
                if offset >= 0 {
                    // Under the body's edge and the sprite's rest place.
                    context.draw(
                        Self.image(piece.seam),
                        in: scaled(CGRect(
                            x: rect.minX - underBody,
                            y: rect.minY,
                            width: underBody + underSprite,
                            height: rect.height
                        ))
                    )
                }
                if offset > 0 {
                    // Rolled out: the stem spans the gap, on under the
                    // sprite.
                    context.draw(
                        Self.image(piece.stem),
                        in: scaled(CGRect(x: rect.minX, y: rect.minY, width: offset + underSprite, height: rect.height))
                    )
                }
                context.draw(Self.image(piece.sprite), in: scaled(rect.offsetBy(dx: offset, dy: 0)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Drawn as the artwork is (`FramedBodyLayers`): minified with high
    /// interpolation.
    private static func image(_ image: CGImage) -> Image {
        Image(decorative: image, scale: 1)
            .interpolation(.high)
            .antialiased(true)
    }
}

// MARK: - Hotspots

/// The buttons' hotspots over the stage (`HardwareButtonHotspotView`),
/// placed with the video's layout spacers: AppKit views, so a click reaches
/// them through the pose wrapper and a held click's mouse-up comes back to
/// the one it went down on.
struct HardwareButtonHotspots: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let art: LiveButtonArt
    /// Each key's hotspot in the composition, points.
    let hotspots: [HardwareKey: CGRect]
    let state: HardwareButtonsState
    let reduceMotion: Bool

    var body: some View {
        let mirror = workspace.mirror
        let state = self.state
        let reduceMotion = self.reduceMotion
        ZStack(alignment: .topLeading) {
            ForEach(HardwareKey.allCases.filter { hotspots[$0] != nil }, id: \.self) { key in
                let group = art.group(of: key) ?? 0
                SpacerPlaced(rect: hotspots[key] ?? .zero) {
                    HardwareButtonHotspot(
                        key: key,
                        onPress: { state.press(key, on: mirror, reduceMotion: reduceMotion) },
                        onRelease: { state.release(key, on: mirror, reduceMotion: reduceMotion) },
                        onHover: { inside in
                            if inside {
                                state.enter(key, group: group, reduceMotion: reduceMotion)
                            } else {
                                state.exit(key, reduceMotion: reduceMotion)
                            }
                        },
                        onResignKey: { state.releaseAll(on: mirror) }
                    )
                }
            }
        }
        // Nothing may stay held once the buttons go (a variant switch
        // included) or the device starts turning: hit-testing is off while
        // it turns, and a turned button is no longer under the pointer.
        .onDisappear { state.releaseAll(on: mirror) }
        .onChange(of: workspace.mirror.stagePose.isAnimating) { _, isAnimating in
            if isAnimating { state.releaseAll(on: mirror) }
        }
    }
}

/// `content` at `rect` in its container, placed with layout spacers, not
/// `.offset`: AppKit representables ignore offset
/// (`FramedMirrorView.videoLayer`).
struct SpacerPlaced<Content: View>: View {
    let rect: CGRect
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear
                .frame(width: max(rect.minX, 0), height: 1)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                Color.clear
                    .frame(width: 1, height: max(rect.minY, 0))
                    .allowsHitTesting(false)
                content()
                    .frame(width: rect.width, height: rect.height)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
    }
}

struct HardwareButtonHotspot: NSViewRepresentable {
    let key: HardwareKey
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
        view.key = key
        view.onPress = onPress
        view.onRelease = onRelease
        view.onHover = onHover
        view.onResignKey = onResignKey
    }
}

/// One side button's hotspot: a mouse-down presses the key, the mouse-up
/// releases it wherever the pointer is by then (AppKit sends it to the view
/// the mouse went down in), and the pointer entering or leaving rolls the
/// button out or back. It never takes first responder, so the keyboard
/// stays with the video. To accessibility it is a button that presses the
/// key briefly, with Power's long press as a custom action.
final class HardwareButtonHotspotView: NSView {
    /// VoiceOver's press: down, then up this much later.
    static let accessibilityPressDuration: Duration = .milliseconds(100)
    /// "Long-press Power": down, then up this much later, past Android's
    /// long-press timeout (the power menu or the assistant).
    static let longPressDuration: Duration = .seconds(1)
    static let longPressActionName = "Long-press Power"

    var key: HardwareKey = .power {
        didSet {
            if key != oldValue { buttonDescription = Self.description(for: key) }
        }
    }
    /// What accessibility and the tooltip say, and whether the button has a
    /// long-press action: `key`'s for a skin's side button, the chrome's
    /// own title for an Apple chrome button (`AppleChromeButtonHotspot`).
    var buttonDescription = HardwareButtonHotspotView.description(for: .power) {
        didSet {
            if buttonDescription != oldValue { describe() }
        }
    }

    /// A hotspot's words: its accessibility label, its tooltip (also its
    /// accessibility help), and the name of its long-press action, if any.
    struct Description: Equatable {
        var label: String
        var toolTip: String
        var longPressName: String?
    }
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onResignKey: (() -> Void)?

    /// A click is down on this button.
    private(set) var isTracking = false
    /// The pointer was last reported over this button (`onHover`).
    private(set) var isHovered = false
    /// Where the pointer is, in window coordinates, while the app is
    /// active and the window on screen; nil otherwise. Read when the
    /// hotspot's tracking area is rebuilt. A test stands in for the pointer.
    var pointerLocation: () -> NSPoint? = { nil }
    /// An accessibility press is down, going up when this ends.
    private var timedRelease: Task<Void, Never>?
    /// The hover's tracking area, on the window's content view (see
    /// `updateHoverTracking()`), and the object it reports to.
    private(set) var hoverTrackingArea: NSTrackingArea?
    private weak var hoverTrackingView: NSView?
    private lazy var hoverTracker = HoverTracker(hotspot: self)
    nonisolated(unsafe) private var resignKeyObserver: (any NSObjectProtocol)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        pointerLocation = { [weak self] in
            // Hover is reported only in the active app
            // (`.activeInActiveApp`), and only over a window on screen.
            guard NSApp?.isActive == true, let window = self?.window, window.isVisible else { return nil }
            return window.mouseLocationOutsideOfEventStream
        }
        describe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
    }

    static func label(for key: HardwareKey) -> String {
        switch key {
        case .power: return "Power button"
        case .volumeUp: return "Volume up button"
        case .volumeDown: return "Volume down button"
        }
    }

    static func toolTip(for key: HardwareKey) -> String {
        switch key {
        case .power: return "Power: click to lock or wake; hold for a long press"
        case .volumeUp: return "Volume up: click for one step; hold to keep raising it"
        case .volumeDown: return "Volume down: click for one step; hold to keep lowering it"
        }
    }

    static func description(for key: HardwareKey) -> Description {
        Description(
            label: label(for: key),
            toolTip: toolTip(for: key),
            longPressName: key == .power ? longPressActionName : nil
        )
    }

    private func describe() {
        toolTip = buttonDescription.toolTip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(buttonDescription.label)
        setAccessibilityHelp(buttonDescription.toolTip)
        longPressAction = buttonDescription.longPressName.map { name in
            NSAccessibilityCustomAction(name: name) { [weak self] in
                MainActor.assumeIsolated {
                    self?.timedPress(for: Self.longPressDuration)
                }
                return true
            }
        }
    }

    // MARK: Mouse

    override var acceptsFirstResponder: Bool {
        false
    }

    /// As the video: the first click on an inactive window reaches the
    /// device.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        finishTimedPress()
        isTracking = true
        onPress?()
    }

    /// The key stays down wherever the pointer goes.
    override func mouseDragged(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isTracking else { return }
        isTracking = false
        onRelease?()
    }

    /// Hover is tracked on the window's content view, not on the hotspot.
    /// The hotspot sits inside the stage's pose wrapper, and once the device
    /// has turned SwiftUI hosts it under a view it turns with
    /// `frameCenterRotation` (after four quarter turns a residual 1.4e-14°
    /// stays, so it is never unturned again). AppKit supports neither cursor
    /// rects nor tracking in rotated views, and never rebuilt the hotspot's
    /// own area as that rotation changed: hover died after the first turn,
    /// in every pose, until a relaunch (Tier 2 live check 4, bug 1), while
    /// clicks, found by hit-testing, kept working. So the pointer's moves
    /// over the whole content view (never turned) come to `HoverTracker`,
    /// and the hotspot is hovered while it is the view a click there would
    /// reach: turned or not, with the hit-testing clicks use.
    private func updateHoverTracking() {
        removeHoverTracking()
        guard let content = window?.contentView else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: hoverTracker,
            userInfo: nil
        )
        content.addTrackingArea(area)
        hoverTrackingArea = area
        hoverTrackingView = content
    }

    private func removeHoverTracking() {
        if let area = hoverTrackingArea { hoverTrackingView?.removeTrackingArea(area) }
        hoverTrackingArea = nil
        hoverTrackingView = nil
    }

    /// Whether the pointer at `location` (window coordinates) is over this
    /// hotspot: inside its bounds, turned as it is drawn, and the view the
    /// window's hit-testing finds there (nothing covers it, and the stage
    /// takes hits: not while the device turns).
    func isUnderPointer(at location: NSPoint) -> Bool {
        guard bounds.contains(convert(location, from: nil)),
              let content = window?.contentView
        else { return false }
        let point = content.superview.map { $0.convert(location, from: nil) } ?? location
        return content.hitTest(point) === self
    }

    /// The pointer moved to `location` (window coordinates), or left the
    /// content view (nil).
    func pointerMoved(to location: NSPoint?) {
        let inside = location.map(isUnderPointer(at:)) ?? false
        if inside != isHovered { setHovered(inside) }
    }

    /// The view's geometry changed. A hotspot that moved under a still
    /// pointer (a zoom step, a window resize, a scroll of the zoomed stage)
    /// gets no move for it, so the hover is set from where the pointer is
    /// now, or a button would stay rolled out with the pointer elsewhere.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Reported under the pointer again even if it already was: the
        // stage may have let every button go since (`releaseAll`), and a
        // repeated enter changes nothing.
        if let location = pointerLocation() {
            let inside = isUnderPointer(at: location)
            if inside || isHovered { setHovered(inside) }
        }
    }

    private func setHovered(_ hovered: Bool) {
        isHovered = hovered
        onHover?(hovered)
    }

    /// Owns the content view's hover area and passes the pointer on
    /// (weakly: the area outlives neither).
    final class HoverTracker: NSResponder {
        weak var hotspot: HardwareButtonHotspotView?

        init(hotspot: HardwareButtonHotspotView) {
            self.hotspot = hotspot
            super.init()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func mouseEntered(with event: NSEvent) {
            hotspot?.pointerMoved(to: event.locationInWindow)
        }

        override func mouseMoved(with event: NSEvent) {
            hotspot?.pointerMoved(to: event.locationInWindow)
        }

        override func mouseExited(with event: NSEvent) {
            hotspot?.pointerMoved(to: nil)
        }
    }

    // MARK: Window

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        removeHoverTracking()
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        updateHoverTracking()
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.windowDidResignKey()
            }
        }
    }

    /// A click held while the window stops being key may never see its
    /// mouse-up: nothing is left held, and the next click presses anew.
    func windowDidResignKey() {
        isTracking = false
        isHovered = false
        finishTimedPress()
        onResignKey?()
    }

    /// The view is going away: a held click or accessibility press goes up
    /// first, so no key is left down on the device.
    func tearDown() {
        if isTracking {
            isTracking = false
            onRelease?()
        }
        finishTimedPress()
        isHovered = false
        removeHoverTracking()
        onPress = nil
        onRelease = nil
        onHover = nil
        onResignKey = nil
    }

    // MARK: Accessibility

    /// The long-press action, if the button has one (`describe()`).
    private var longPressAction: NSAccessibilityCustomAction?

    /// Returned from an override, never stored with
    /// `setAccessibilityCustomActions(_:)`: SwiftUI's accessibility element
    /// that stands in for a representable's view to assistive apps passes
    /// on the view's custom actions only when its class overrides this
    /// getter. Actions set through the setter still read back in-process,
    /// but VoiceOver and other AX clients saw `AXCustomActions` empty and
    /// only `AXPress` (established against macOS 27.0 (26A428), Xcode 27.0;
    /// a plain AppKit view exports either way).
    /// `testTheLongPressIsAnOverrideSwiftUIExports` pins the override.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        longPressAction.map { [$0] } ?? []
    }

    override func accessibilityPerformPress() -> Bool {
        timedPress(for: Self.accessibilityPressDuration)
        return true
    }

    /// Presses the key and releases it `duration` later.
    func timedPress(for duration: Duration) {
        finishTimedPress()
        onPress?()
        timedRelease = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, !Task.isCancelled else { return }
            self.timedRelease = nil
            self.onRelease?()
        }
    }

    /// An accessibility press still down goes up now.
    private func finishTimedPress() {
        guard let task = timedRelease else { return }
        task.cancel()
        timedRelease = nil
        onRelease?()
    }
}
