import CoreVideo
import DeviceHubProKit
import Metal
import QuartzCore
import RealityKit
import SwiftUI
import Synchronization

/// A foldable simulator in Apple's own 3D model of the device
/// (`AppleDeviceModel`, read from the user's Xcode): the hinge follows the
/// fold the simulator was put in, the lit panel shows the live session and
/// takes the pointer as touches (worked out on the folded panel), and the
/// device turns when dragged anywhere else, a double click facing it to the
/// camera again.
///
/// The device is posed as it is held: half open, it turns so both halves
/// face the camera alike, the hinge away (`AppleDeviceModel.framing`); the
/// panel going dark keeps its last picture, blurred, while the device folds.
/// As Device Hub shows it (`DeviceModelPresentation.front`) the device stays
/// facing the camera; turnable (`.free`), a fold also shows the hinge's angle
/// beside it.
struct DeviceModelStageView: View {
    let model: AppleDeviceModel
    let session: any MirrorSessionProtocol
    /// The hinge, 0 (closed) to 180 (flat).
    let opening: Double
    /// How far the fold strip's last preset or held posture got in the
    /// simulator, which a fold follows (nil when the hinge moved otherwise).
    let foldProgress: @MainActor () -> SimulatorFoldProgress?
    let litPanel: SimulatorFoldPanel
    /// The fold's controller, for the hinge slider's live angle.
    let fold: SimulatorFoldController
    /// The pill's Laptop or Tent when it is the current posture: the device
    /// is posed as one only then (a device turned on its side and half open
    /// otherwise is a book seen from the front, as Device Hub draws it).
    var held: SimulatorHeldPosture? = nil
    let presentation: DeviceModelPresentation
    /// The model's finish (`AppleDeviceModel.colors`); the stage makes the
    /// view anew when it changes.
    let color: String
    /// The view's size, which the camera fits the device in.
    let size: CGSize
    /// The clockwise quarter turns that show a frame of (width, height)
    /// pixels upright on the model's panel, as the device is held.
    let panelTurns: (Int, Int) -> Int
    /// Counter-clockwise quarter turns the device is held at from its
    /// resting pose (the simulator turned to landscape, say).
    let roll: Int
    /// Counts Turn Around requests: each turns the device once round.
    let spinRequests: Int
    /// The stage zoom the front-on device is drawn at, a multiplier of its
    /// fitted height (1 at Zoom to Fit). It scales the model inside the
    /// view, which keeps its size: making the view `zoom` times larger made
    /// the stage swap layouts (the view rebuilt, the model loaded again,
    /// nothing drawn for half a second) and the drawable many times larger.
    var zoom: CGFloat = 1
    /// Whether this change of `zoom` is a zoom step, which the scene
    /// animates (`MotionMetrics.zoom`); else (an opening zoom, a correction
    /// to a scale mode, a new device) the device is drawn at the new size at
    /// once.
    var animatesZoom = false
    /// The window this view is in (each has a scene of its own).
    var surface: DeviceModelSurface = .main
    /// Marks this instance as the one showing the scene
    /// (`DeviceModelScenes.release`).
    @State private var lease = DeviceModelLease()
    @Environment(AppModel.self) private var appModel

    private var sceneKey: DeviceModelScenes.Key {
        DeviceModelScenes.Key(surface: surface, model: model, color: color)
    }

    /// The scene, held by the fold's controller rather than by this view: a
    /// view made anew shows the scene that is loaded already.
    private var scene: DeviceModelScene { fold.modelScenes.lend(sceneKey, to: lease) }

    /// Whether the stage shows the mirrored foldable in its turnable 3D
    /// model (`DeviceModelPresentation.free`): asked for (View ▸ Show 3D
    /// Model), a usable model in the user's Xcode, and the device drawn in
    /// its Apple chrome (Show Device Frame on). The stage zoom is off then
    /// (the model has its own); the front-on model zooms as the 2D frame.
    static func isShown(chrome: DeviceChrome, workspace: DeviceWorkspace, preferences: AppPreferences) -> Bool {
        guard case .appleChrome = chrome else { return false }
        return workspace.window.showDeviceFrame && preferences.showDeviceModel
            && workspace.simulatorFold.deviceModel != nil
    }

    /// Whether the stage draws the mirrored foldable's 3D model at all:
    /// turnable (`isShown`) or seen from the front as Device Hub draws it
    /// (the model in the user's Xcode, the device in its Apple chrome).
    static func isDrawn(chrome: DeviceChrome, workspace: DeviceWorkspace) -> Bool {
        guard case .appleChrome = chrome else { return false }
        return workspace.window.showDeviceFrame && workspace.simulatorFold.showsFoldControls
            && workspace.simulatorFold.deviceModel != nil
    }

    /// `isShown` for the workspace's mirrored device, with the chrome the
    /// stage resolves for it: the toolbar's zoom and the View menu's go by it.
    static func isShown(in workspace: DeviceWorkspace, model: AppModel) -> Bool {
        guard let device = workspace.context.device, device.platform == .apple,
              workspace.simulatorFold.deviceModel != nil, model.preferences.showDeviceModel
        else { return false }
        let chrome = DeviceChromeResolver.chrome(
            device: device,
            avdCards: model.catalog.avdCards,
            forceVector: model.launchOptions.forceVectorChrome,
            appleDisplayShapes: workspace.mirror.liveDisplayShapes,
            appleChrome: DeviceChromeResolver.appleChrome(
                for: device,
                simulators: model.simulators,
                physical: model.physicalInventory
            )
        )
        return isShown(chrome: chrome, workspace: workspace, preferences: model.preferences)
    }

    var body: some View {
        // On the lit panel the pointer touches the simulator; elsewhere it
        // turns the device, and a double click faces it to the camera again
        // (the canvas takes the mouse itself: SwiftUI's gestures never reach
        // a layer-hosting view).
        DeviceModelCanvas(
            scene: scene,
            model: model,
            color: color,
            forwardsKeyboard: appModel.preferences.keyboardForwardingEnabled,
            capturesShortcuts: appModel.preferences.captureKeyboardShortcuts,
            securesKeyboard: appModel.preferences.secureKeyboardEntry,
            unusable: { [simulators = appModel.simulators, model] in simulators.setDeviceModelUnusable(model) }
        )
        .overlay(alignment: .leading) {
            HingeReadout(scene: scene, isShown: presentation == .free)
        }
        .onChange(of: presentation, initial: true) { _, presentation in
            scene.present(presentation)
        }
        .onChange(of: size, initial: true) { _, size in
            scene.fit(in: size)
        }
        .onChange(of: zoom, initial: true) { _, zoom in
            scene.setFrontZoom(zoom, animated: animatesZoom)
        }
        .onChange(of: roll, initial: true) { _, turns in
            scene.roll(toTurns: turns)
        }
        .onChange(of: opening, initial: true) { _, degrees in
            scene.foldProgress = foldProgress
            scene.fold(toOpening: degrees)
        }
        .onChange(of: held, initial: true) { _, held in
            scene.hold(held)
        }
        .onChange(of: litPanel, initial: true) { _, panel in
            scene.show(session: session, on: panel, turns: panelTurns)
        }
        .onChange(of: ObjectIdentifier(session), initial: false) { _, _ in
            scene.show(session: session, on: litPanel, turns: panelTurns)
        }
        .onChange(of: spinRequests, initial: false) { _, _ in
            scene.spin()
        }
        .onAppear {
            _ = scene
            fold.modelScenes.claim(lease)
            // The hinge slider folds the model directly while it is dragged
            // (every window showing one: the main window's stays alive behind
            // the compact window).
            fold.onLiveHinge = { [weak scenes = fold.modelScenes] degrees in scenes?.foldLive(toOpening: degrees) }
            // A panel that stays black asks the simulator which one is lit.
            scene.onPanelDark = { [weak fold] likely in fold?.recheckLitPanel(likely: likely) }
            // A view made anew while the old one is still going away (or
            // just after it), or a stage back after it was left, starts the
            // feed again: the old one's disappearing does not stop a scene it
            // no longer owns.
            scene.show(session: session, on: litPanel, turns: panelTurns)
        }
        .onDisappear {
            let scenes = fold.modelScenes
            if scenes.release(lease) {
                scene.onPanelDark = nil
                scene.stopFeeding()
            }
            if !scenes.isShowing { fold.onLiveHinge = nil }
        }
        .accessibilityLabel("3D device")
    }
}

/// The hinge's angle beside a turnable model while it folds. A view of its
/// own so that only it watches the scene's readout, which changes with every
/// degree the hinge passes: the stage's `body` (the canvas, the modifiers and
/// their closures) was evaluated again for each of them.
private struct HingeReadout: View {
    let scene: DeviceModelScene
    /// Whether the presentation has a readout (`DeviceModelPresentation.free`);
    /// the scene's readout is not read otherwise.
    let isShown: Bool

    var body: some View {
        let readout = isShown ? scene.readout : nil
        Group {
            if let readout {
                Text(verbatim: "\(readout)°")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
                    .transition(.opacity)
                    .accessibilityLabel("Hinge \(readout) degrees")
            }
        }
        .animation(.easeOut(duration: 0.2), value: readout == nil)
    }
}

/// The scene drawn on demand: RealityKit's `RealityRenderer` into a Metal
/// layer, only when something changed (a fold, a turn, a frame on a panel).
/// RealityView drew at every display refresh and waited for its render
/// thread's frame pacing on the main thread (four fifths of the main
/// thread's time in a VM, which made the whole window lag).
struct DeviceModelCanvas: NSViewRepresentable {
    let scene: DeviceModelScene
    let model: AppleDeviceModel
    let color: String
    /// The Mac keyboard reaches the simulator (Keyboard Capture), as on the
    /// 2D stage.
    let forwardsKeyboard: Bool
    /// ⌘ shortcuts go to the simulator too, and other apps cannot read the
    /// keys (Settings ▸ Keyboard), as on the 2D stage.
    let capturesShortcuts: Bool
    let securesKeyboard: Bool
    /// The model did not load as one the scene can show (another build's
    /// file of another shape, say): the stage goes back to the 2D chrome.
    let unusable: @MainActor () -> Void

    func makeNSView(context: Context) -> DeviceModelCanvasView {
        let view = DeviceModelCanvasView()
        view.attach(scene: scene, model: model, color: color, unusable: unusable)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DeviceModelCanvasView, context: Context) {
        view.forwardsKeyboard = forwardsKeyboard
        view.capturesShortcuts = capturesShortcuts
        view.securesKeyboard = securesKeyboard
    }

    static func dismantleNSView(_ view: DeviceModelCanvasView, coordinator: ()) {
        SecureKeyboardEntry.shared.set(false, for: view)
        view.detach()
    }
}

/// A layer-hosting view whose display link steps the scene's motions once a
/// frame (`DeviceModelScene.step`) and draws a frame when the scene asked
/// for one and the renderer has room (`RenderCadence`); the link rests while
/// nothing moves or waits to be drawn. It hands the mouse to the scene, in
/// its own top-left points (the scene's view size).
@MainActor
final class DeviceModelCanvasView: NSView {
    private let metalLayer = CAMetalLayer()
    private var renderer: RealityRenderer?
    private weak var scene: DeviceModelScene?
    private var mouseStart: CGPoint?
    private var isPanning = false
    private var hoverArea: NSTrackingArea?
    private var showsKeyCursor = false
    private var link: CADisplayLink?
    /// The scene changed since the last frame was asked for. Setting it wakes
    /// the display link, which rests while nothing needs drawing
    /// (`RenderCadence.shouldPause`); a new request after `maxRenderRetries`
    /// failures (the scene changed) starts their count over.
    private var needsRender = true {
        didSet {
            guard needsRender else { return }
            link?.isPaused = false
            if !oldValue, renderFailures > Self.maxRenderRetries { renderFailures = 0 }
        }
    }
    /// The frames the renderer holds (`RenderCadence.maxFramesInFlight`).
    /// A new count with each renderer (`show`, `releaseRenderer`): a frame
    /// of a renderer that was let go may never report back, and a count stuck
    /// at its most would leave the view drawing nothing for good. A late
    /// completion ends the count it began on (`render` captures it).
    private var framesInFlight = FramesInFlight()
    /// When the last frame asked for is due on screen: the renderer's update
    /// advances by the time since.
    private var lastDue: CFTimeInterval?
    /// Frames in a row whose render threw.
    private var renderFailures = 0
    private var loadTask: Task<Void, Never>?
    /// No renderer could be made for this view (the stage went back to the
    /// 2D chrome): `tick` does not ask again.
    private var cannotRender = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = false
        metalLayer.maximumDrawableCount = 3
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer { metalLayer }

    var forwardsKeyboard = true {
        didSet { if forwardsKeyboard != oldValue { updateSecureInput() } }
    }
    var capturesShortcuts = false
    var securesKeyboard = false {
        didSet { if securesKeyboard != oldValue { updateSecureInput() } }
    }
    private var keyObservers: [NSObjectProtocol] = []

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Keys go to the lit panel's session as on the 2D stage
    /// (`MirrorKeyRouting`); without Keyboard Capture they stay the Mac's.
    override func keyDown(with event: NSEvent) {
        guard forwardsKeyboard,
              let command = MirrorKeyRouting.command(keyCode: event.keyCode, characters: event.characters, modifiers: event.modifierFlags),
              scene?.sendKey(command) == true
        else {
            super.keyDown(with: event)
            return
        }
    }

    /// ⌘ shortcuts go to the lit panel's session as on the 2D stage
    /// (`MirrorMetalView.performKeyEquivalent`).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, capturesShortcuts, forwardsKeyboard, window?.firstResponder === self,
              let shortcut = MirrorKeyRouting.shortcut(keyCode: event.keyCode, modifiers: event.modifierFlags),
              !shortcut.staysOnTheMac, scene?.sendShortcut(shortcut) == true
        else { return super.performKeyEquivalent(with: event) }
        return true
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { DispatchQueue.main.async { [weak self] in self?.updateSecureInput() } }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { SecureKeyboardEntry.shared.set(false, for: self) }
        return resigned
    }

    /// Secure keyboard entry while the keyboard goes to the simulator from
    /// this view, the key window's first responder (`SecureKeyboardEntry`).
    func updateSecureInput() {
        let wanted = securesKeyboard && forwardsKeyboard && window?.isKeyWindow == true && window?.firstResponder === self
        SecureKeyboardEntry.shared.set(wanted, for: self)
    }

    override func magnify(with event: NSEvent) {
        scene?.zoom(by: 1 + event.magnification)
    }

    /// A zoomed front-on device moves with the scroll (as the 2D stage's
    /// scroll view does); a scroll off the panel zooms the turnable one (on
    /// it the simulator scrolls with a drag).
    override func scrollWheel(with event: NSEvent) {
        if let scene, scene.canPan {
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            if scene.pan(scrolledBy: CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale)) {
                return
            }
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let scene, scene.framePoint(at: point) == nil, event.scrollingDeltaY != 0 else {
            return super.scrollWheel(with: event)
        }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
        scene.zoom(by: 1 + step)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if hoverArea == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            hoverArea = area
        }
    }

    /// Over a hardware key the pointer becomes a pointing hand.
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let overKey = scene?.hover(at: point) ?? false
        guard overKey != showsKeyCursor else { return }
        showsKeyCursor = overKey
        (overKey ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        _ = scene?.hover(at: nil)
        guard showsKeyCursor else { return }
        showsKeyCursor = false
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        mouseStart = point
        // ⌥⌘ and a drag move a zoomed device round the view, as they pan
        // the 2D stage; the drag never reaches the device.
        if StageScrollSupport.isPanGesture(event.modifierFlags), scene?.canPan == true {
            isPanning = true
            NSCursor.closedHand.push()
            return
        }
        scene?.pointerMoved(from: point, to: point, translation: .zero)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        let translation = CGSize(width: point.x - start.x, height: point.y - start.y)
        if isPanning {
            scene?.pan(by: translation)
            return
        }
        scene?.pointerMoved(from: start, to: point, translation: translation)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = mouseStart else { return }
        mouseStart = nil
        if isPanning {
            isPanning = false
            NSCursor.pop()
            scene?.endPan()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        scene?.pointerEnded(at: point, translation: CGSize(width: point.x - start.x, height: point.y - start.y))
    }

    func attach(scene: DeviceModelScene, model: AppleDeviceModel, color: String, unusable: @escaping @MainActor () -> Void) {
        self.scene = scene
        scene.waitingViews.removeAll { $0.view == nil || $0.view === self }
        scene.waitingViews.append(WeakCanvasView(view: self))
        scene.onNeedsRender = { [weak self] in self?.needsRender = true }
        // The scene outlives a stage that went away and came back: its first
        // frame on the new link has no time behind it.
        scene.framesPaused()
        // A scene that is loaded already (the view was made anew) only needs
        // a renderer: at once, not after the next turn of the main actor.
        if let root = scene.loadedRoot {
            // Not inside this update (`makeNSView`): the stage's model is
            // marked unusable, which the stage observes.
            if !show(root, of: scene) { Task { @MainActor in unusable() } }
            return
        }
        loadTask = Task { [weak self] in
            let root = await scene.load(model, color: color)
            guard !Task.isCancelled else { return }
            guard let root, let self, self.show(root, of: scene) else {
                unusable()
                return
            }
        }
    }

    /// Draws `root` in a renderer of this view's; false when there is none.
    /// The view that drew the scene before lets go of it first: an entity
    /// tree sits in one renderer only, and a view made anew may be made
    /// before the old one is taken apart.
    private func show(_ root: Entity, of scene: DeviceModelScene) -> Bool {
        if renderer != nil, scene.host === self { return true }
        guard let renderer = try? RealityRenderer() else {
            cannotRender = true
            return false
        }
        if let previous = scene.host, previous !== self { previous.releaseRenderer() }
        scene.host = self
        scene.rendererChanged()
        renderer.entities.append(root)
        renderer.activeCamera = scene.camera
        renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0, alpha: 0))
        renderer.cameraSettings.antialiasing = .multisample4X
        self.renderer = renderer
        framesInFlight = FramesInFlight()
        // The scene's frames are asked of the view that draws it.
        scene.onNeedsRender = { [weak self] in self?.needsRender = true }
        needsRender = true
        return true
    }

    func detach() {
        loadTask?.cancel()
        link?.invalidate()
        link = nil
        releaseRenderer()
        if let scene {
            scene.waitingViews.removeAll { $0.view == nil || $0.view === self }
            if scene.host === self {
                scene.host = nil
                for waiting in scene.waitingViews { waiting.view?.needsRender = true }
            }
        }
        if isPanning {
            isPanning = false
            NSCursor.pop()
        }
    }

    /// Takes the scene out of this view's renderer, which the scene outlives:
    /// it goes into the next view's.
    fileprivate func releaseRenderer() {
        renderer?.entities.removeAll()
        renderer = nil
        framesInFlight = FramesInFlight()
    }

    /// A view without a renderer takes a loaded scene no other view draws:
    /// the view that had it was taken apart (two views waiting for the same
    /// load hand the scene to each other, and the one that came last may be
    /// the one that goes), and this one would stay blank.
    private func adoptLoadedScene() {
        guard renderer == nil, !cannotRender, let scene, scene.host == nil, let root = scene.loadedRoot else { return }
        _ = show(root, of: scene)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        updateSecureInput()
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateSecureInput() }
            })
        }
        // A window that is not on screen draws nothing (`tick`), and the
        // pictures that came meanwhile may have been dropped from the panels'
        // texture queues: when it shows again, the panel gets the session's
        // latest.
        keyObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.occlusionState.contains(.visible) == true else { return }
                self.needsRender = true
                self.scene?.refeed()
            }
        })
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastDue = nil
        // A new link (the view moved to another window mid-motion) has no
        // time behind its first frame.
        scene?.framesPaused()
        needsRender = true
        resizeDrawable()
    }

    override func layout() {
        super.layout()
        resizeDrawable()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resizeDrawable()
    }

    /// The drawable at one and a half times the screen's pixels, for the
    /// layer to scale down, with the renderer's 4× multisampling on top: at
    /// the screen's own pixels the metal edge of a device seen from the
    /// front broke into specks along its top and bottom (iPhone Duo on a 2×
    /// screen, 2026-10-11), and multisampling alone left steps on the curved
    /// bezel. Twice the pixels without multisampling looked the same and took
    /// 2.7 GB against 1.8 GB (full-screen stage on a 2× screen, 2026-10-13).
    /// Its longer side stays within `maxDrawableSide`.
    private func resizeDrawable() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let over = Self.supersampling
        var size = CGSize(width: max(bounds.width * scale * over, 1), height: max(bounds.height * scale * over, 1))
        let longest = max(size.width, size.height)
        if longest > Self.maxDrawableSide {
            size = CGSize(width: size.width * Self.maxDrawableSide / longest, height: size.height * Self.maxDrawableSide / longest)
        }
        guard metalLayer.drawableSize != size else { return }
        metalLayer.drawableSize = size
        needsRender = true
    }

    /// The largest drawable side drawn (a zoomed stage on a large screen
    /// would ask for more than the GPU's textures allow).
    static let maxDrawableSide: CGFloat = 8192

    /// The drawable's pixels per screen pixel (see `resizeDrawable`).
    static let supersampling: CGFloat = 1.5

    /// How many times in a row a frame whose render threw is asked for
    /// again.
    static let maxRenderRetries = 3

    /// One frame of the link: every motion of the scene takes its step for
    /// the moment the frame is due on screen, the scene poses the device once,
    /// and the frame is drawn when one is wanted. The link rests when nothing
    /// is.
    @objc private func tick(_ link: CADisplayLink) {
        let visible = window?.isVisible == true
        if visible {
            // Pictures that came while the window was not on screen were not
            // copied to the panels (`DeviceModelScene.frameArrived`).
            scene?.refeedIfSkipped()
            adoptLoadedScene()
        }
        let due = link.targetTimestamp
        scene?.step(at: due)
        // A window that is not on screen (the main window ordered out behind
        // the compact one, a minimized one) draws nothing; the frame it asked
        // for is drawn when it shows (the occlusion observer wakes the link).
        // One that is only covered by other windows keeps drawing.
        let canRender = renderer != nil && visible && bounds.width > 1 && bounds.height > 1
        if RenderCadence.shouldRender(needsRender: needsRender, canRender: canRender, inFlight: framesInFlight.count),
           let renderer, let drawable = metalLayer.nextDrawable() {
            render(drawable, with: renderer, due: due)
        }
        // A view waiting to take a loaded scene nobody draws keeps ticking
        // until it does (`adoptLoadedScene`).
        let adopting = visible && renderer == nil && !cannotRender && scene?.loadedRoot != nil && scene?.host == nil
        if !adopting, RenderCadence.shouldPause(needsRender: needsRender, canRender: canRender, animating: scene?.isAnimating ?? false) {
            scene?.framesPaused()
            link.isPaused = true
        }
    }

    /// Asks the renderer for a frame into `drawable`, presented as the GPU
    /// finishes it (on a thread of the renderer's: the count of frames in
    /// flight is locked, and there is no hop to the main queue to wait for).
    private func render(_ drawable: CAMetalDrawable, with renderer: RealityRenderer, due: CFTimeInterval) {
        needsRender = false
        let delta = RenderCadence.frameDelta(previous: lastDue, current: due)
        lastDue = due
        framesInFlight.begin()
        let frames = framesInFlight
        let handoff = DrawableHandoff(drawable: drawable)
        do {
            let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: drawable.texture))
            try renderer.updateAndRender(deltaTime: delta, cameraOutput: output, onComplete: { _ in
                handoff.drawable.present()
                frames.end()
            })
            renderFailures = 0
            scene?.noteDrawn()
        } catch {
            // The frame asked for was not drawn: ask again, or the stage
            // stays on the last one until something else changes. A render
            // that fails every time stops after `maxRenderRetries` and waits
            // for the scene to change.
            frames.end()
            renderFailures += 1
            needsRender = renderFailures <= Self.maxRenderRetries
        }
    }
}

/// A view attached to a scene, held weakly (`DeviceModelScene.waitingViews`).
@MainActor
struct WeakCanvasView {
    weak var view: DeviceModelCanvasView?
}

/// A drawable handed to the renderer's completion, which presents it.
private struct DrawableHandoff: @unchecked Sendable {
    let drawable: CAMetalDrawable
}

/// How the stage shows a foldable's 3D model.
enum DeviceModelPresentation: Equatable {
    /// As Device Hub 27.1 draws iPhone Duo: from the front through a long
    /// lens (the camera `DeviceModelScene.frontDistance` device heights
    /// away), the device `height` view points tall whatever its fold, never
    /// turned by the mouse. That is its fitted height: the stage zoom
    /// multiplies it (`DeviceModelScene.setFrontZoom`).
    case front(height: CGFloat)
    /// Turned and zoomed by the mouse, filling the view
    /// (View ▸ Show 3D Model).
    case free
}

/// The loaded model, its hinge animation, its pose and its panels' live
/// textures.
@MainActor
@Observable
final class DeviceModelScene {
    /// The hinge angle while the device folds (whole degrees), for the
    /// readout beside it; nil at rest.
    private(set) var readout: Int?

    /// Holds the camera and the lights, which stay put, and the turntable.
    @ObservationIgnored private var root: Entity?
    /// Turns the device: the mouse, Turn Around, the device's pose and the
    /// book turn of a half-open device.
    @ObservationIgnored private let turntable = Entity()
    @ObservationIgnored let camera = PerspectiveCamera()
    /// Asks the canvas for a frame: the scene changed (`DeviceModelCanvas`
    /// draws only then).
    @ObservationIgnored var onNeedsRender: (@MainActor () -> Void)?
    /// The loaded file's entity, scaled and moved inside the turntable.
    @ObservationIgnored private var deviceEntity: Entity?
    /// The open device's centre in the stand's frame, and its flat size
    /// there: x across both halves, y the thickness, z the height.
    @ObservationIgnored private var openCenter = SIMD3<Float>(repeating: 0)
    /// Where the hinge's middle puts the model (the device's position with
    /// the hinge at the origin), and how far the hinge's back stands out
    /// closed: half one half's thickness. In the view's units.
    @ObservationIgnored private var hingeCenter = SIMD3<Float>(repeating: 0)
    @ObservationIgnored private var hingeReach: Float = 0
    @ObservationIgnored private var deviceSize = SIMD3<Float>(repeating: 0)
    /// The hinge as shown (degrees, 0 closed, 180 flat).
    @ObservationIgnored private var shownOpening: Double = 180
    @ObservationIgnored private var viewSize = CGSize.zero
    /// The mouse's turn (radians: about the vertical axis, then the
    /// horizontal one), and where the drag under way began.
    @ObservationIgnored private var yaw: Float = 0
    @ObservationIgnored private var pitch: Float = 0
    @ObservationIgnored private var turnStart: (yaw: Float, pitch: Float)?
    @ObservationIgnored private var resetTask: FrameAnimation?
    /// The viewer's zoom (pinch, scroll): the camera's distance divided by it.
    @ObservationIgnored private var zoomFactor: Float = 1
    /// The stage zoom the front-on device is drawn at, the zoom it heads for
    /// (`setFrontZoom`) and the move that takes it there.
    @ObservationIgnored private var shownFrontZoom: CGFloat = 1
    @ObservationIgnored private var frontZoomTarget: CGFloat = 1
    @ObservationIgnored private var frontZoomTask: FrameAnimation?
    /// How far the zoomed front-on device has been moved off the middle of
    /// the view (points, right and down positive: ⌥⌘-drag, scroll), and where
    /// it was when the drag under way began.
    @ObservationIgnored private var panOffset = CGSize.zero
    @ObservationIgnored private var panStart: CGSize?
    @ObservationIgnored private var presentation: DeviceModelPresentation = .free
    /// Turn Around's progress (radians about the vertical axis).
    @ObservationIgnored private var spinAngle: Float = 0
    @ObservationIgnored private var spinTask: FrameAnimation?
    /// The device pose's turn about the view axis (radians, counter-clockwise),
    /// and the quarter turns it heads for.
    @ObservationIgnored private var rollAngle: Float = 0
    @ObservationIgnored private var rollTurns = 0
    @ObservationIgnored private var rollTarget: Float?
    @ObservationIgnored private var rollTask: FrameAnimation?
    /// How far the device is posed as a laptop or a tent (0...1, blended so
    /// the camera moves between poses), the hinge it heads for, and the
    /// blend under way.
    @ObservationIgnored private var laptopWeight: Float = 0
    @ObservationIgnored private var tentWeight: Float = 0
    @ObservationIgnored private var targetOpening: Double = 180
    /// The face the camera sees, and where the book turn of a device showing
    /// its inner face started: the turn eases from there to the target's as
    /// the hinge gets there (`innerTurn`).
    @ObservationIgnored private var facing = AppleDeviceModel.FoldFacing(opening: 180)
    @ObservationIgnored private var bookStart: (turn: Float, opening: Double) = (0, 180)
    /// The face a tent or a laptop holds to the camera; nil otherwise.
    @ObservationIgnored private var heldFace: SimulatorFoldPanel?
    /// The pill's Laptop or Tent when current (`hold`).
    @ObservationIgnored private var heldPosture: SimulatorHeldPosture?
    /// The device's centre as drawn and where it heads (`easedCenter`), and
    /// the book turn as drawn and where it heads (`easedBook`): both catch up
    /// with their targets on the frames `step` runs until `isSettled`.
    @ObservationIgnored private var shownCenter: SIMD2<Float>?
    @ObservationIgnored private var centerTarget: SIMD2<Float>?
    /// The book turn as drawn, and its swing to the other face (`easedBook`),
    /// on the clock of the frames posed (`frameNow`).
    @ObservationIgnored private var bookEase = BookTurnEase()
    /// The time of the frames the device was posed for: it moves on by each
    /// frame's delta (`applyLayout`), so the book turn eases by the frames
    /// drawn and a swing that begins after the link rested starts from the
    /// turn on screen.
    @ObservationIgnored private var frameNow = ContinuousClock.now
    /// The slider's angle the drawn hinge heads for, and the move that takes
    /// it there (`chase`).
    @ObservationIgnored private var chaseTarget: Double?
    @ObservationIgnored private var chaseTask: FrameAnimation?
    @ObservationIgnored private var holdTask: FrameAnimation?
    @ObservationIgnored private var pendingSession: (session: any MirrorSessionProtocol, panel: SimulatorFoldPanel, turns: (Int, Int) -> Int)?
    @ObservationIgnored private var pendingOpening: Double?
    @ObservationIgnored private var panelTurns: (Int, Int) -> Int = { _, _ in 0 }
    @ObservationIgnored private var modelEntity: ModelEntity?
    @ObservationIgnored private var controller: AnimationPlaybackController?
    @ObservationIgnored private var spec: AppleDeviceModel.Spec?
    /// This load's panel materials (RealityKit numbers them anew each load).
    @ObservationIgnored private var panels: AppleDeviceModel.PanelMaterials?
    /// The body's materials (all but the panels') as the file draws them,
    /// for the turnable view, and as Device Hub draws them seen from the
    /// front (`AppleDeviceModel.FrontLook`), by material index.
    @ObservationIgnored private var bodyLooks: (studio: [Int: any RealityKit.Material], front: [Int: any RealityKit.Material]) = ([:], [:])
    /// The studio's key and fill lights and its room, and the sky the
    /// front-on view is lit by alone.
    @ObservationIgnored private var studioLights: [Entity] = []
    @ObservationIgnored private var studioRoom: EnvironmentResource?
    @ObservationIgnored private var frontSky: EnvironmentResource?
    /// The flat panels' bounds in the model's space (inner, outer): where a
    /// pointer lands on them is worked out from these and the fold.
    @ObservationIgnored private var panelBounds: (inner: (SIMD3<Float>, SIMD3<Float>), outer: (SIMD3<Float>, SIMD3<Float>))?
    /// The model's hardware keys, nil when it shows none.
    @ObservationIgnored private var keys: AppleDeviceModel.Keys?
    /// Each key drawn on its own, taken out of the device's mesh so it can
    /// move as a key does: out under the pointer, in while pressed.
    @ObservationIgnored private var keyEntities: [KeyEntity] = []
    /// The key under the pointer, standing out.
    @ObservationIgnored private var raisedKey: SimulatorHardwareButton?

    private final class KeyEntity {
        let key: AppleDeviceModel.Key
        let entity: ModelEntity
        /// How far it stands out of its edge now (in when below zero).
        var travel: Float = 0
        var motion: FrameAnimation?

        init(key: AppleDeviceModel.Key, entity: ModelEntity) {
            self.key = key
            self.entity = entity
        }
    }
    /// The session the lit panel shows, and its last frame's size and turn.
    @ObservationIgnored private var feedingSession: (any MirrorSessionProtocol)?
    @ObservationIgnored private var shownFrame: (width: Int, height: Int, turns: Int)?
    /// What the pointer under way does, and where it last touched.
    @ObservationIgnored private var pointer: PointerUse?
    @ObservationIgnored private var lastTouch: (x: Int32, y: Int32)?
    @ObservationIgnored private var lastTurnClick: Date?

    private enum PointerUse: Equatable {
        case touch
        case turn
        /// A key held down on the simulator until the pointer comes up.
        case key(SimulatorHardwareButton)
    }

    /// How long after a sweep's last hinge event the guest goes on ignoring
    /// touches (about 100 ms measured), with a margin.
    static let touchSuppressionTail: Duration = .milliseconds(150)
    /// Touches made while the guest ignores them (`sendTouch`), the move that
    /// sends them on, and where the last fold strip sweep ended.
    @ObservationIgnored private var heldTouches: [(command: TouchCommand, at: ContinuousClock.Instant, session: any MirrorSessionProtocol)] = []
    @ObservationIgnored private var touchRelease: Task<Void, Never>?
    @ObservationIgnored private var lastSweepEnd: ContinuousClock.Instant?

    /// The longest a click's pointer may move, and the longest between the
    /// clicks of a double click.
    static let clickSlop: CGFloat = 3
    static let doubleClickInterval: TimeInterval = 0.4
    @ObservationIgnored private var foldTask: FrameAnimation?
    /// Where the fold strip's last batch got in the simulator
    /// (`DeviceModelStageView.foldProgress`).
    @ObservationIgnored var foldProgress: (@MainActor () -> SimulatorFoldProgress?)?
    @ObservationIgnored private var readoutTask: Task<Void, Never>?
    @ObservationIgnored private var darkenTask: Task<Void, Never>?
    @ObservationIgnored private var shownTime: Double?
    @ObservationIgnored private let feeder = PanelTextureFeeder()
    @ObservationIgnored private var observation: FrameObservation?
    @ObservationIgnored private var feedingPanel: SimulatorFoldPanel?
    /// A panel's new texture and its material's index, waiting for the
    /// texture's first picture.
    @ObservationIgnored private var pendingMaterials: [SimulatorFoldPanel: (texture: TextureResource, index: Int)] = [:]
    /// Each panel's frames that found no drawable since its last picture,
    /// and when it last took a new texture for that (`panelStalled`).
    @ObservationIgnored private var stalls: [SimulatorFoldPanel: Int] = [:]
    @ObservationIgnored private var lastNewTexture: [SimulatorFoldPanel: ContinuousClock.Instant] = [:]
    /// Frames drawn since the last stall that counted (`panelStalled`).
    @ObservationIgnored private var drawsSinceStall = 0
    /// Whether a renderer has drawn the scene (`rendererChanged`).
    @ObservationIgnored private var hadRenderer = false
    /// Asks the simulator which panel is lit: the panel being fed stayed
    /// black (`DarkPanelWatchdog`).
    /// Called with the other panel while the slider drags the hinge
    /// (`dragFacing`): the guest most likely lit it.
    @ObservationIgnored var onPanelDark: (@MainActor (_ likely: SimulatorFoldPanel?) -> Void)?
    @ObservationIgnored private var darkWatch = DarkPanelWatchdog()
    @ObservationIgnored private var darkWatchTask: Task<Void, Never>?
    @ObservationIgnored private var lastDarkSample: ContinuousClock.Instant?
    @ObservationIgnored private var sampleGap = DeviceModelScene.darkSampleInterval
    /// The panel waiting to go dark once the fold ends (`show`).
    @ObservationIgnored private var darkening: SimulatorFoldPanel?
    /// A panel waiting for its first picture, asked again with the session's
    /// current frame until it comes (`armMaterialRetry`).
    @ObservationIgnored private var materialRetries: [SimulatorFoldPanel: Task<Void, Never>] = [:]

    /// How long a quarter turn of the device takes, easing out: Device Hub
    /// 27.1 turned iPhone Duo (closed, Rotate Right) in 557 ms, fastest in
    /// its first 50 ms (a 60 fps window recording, 2026-10-13).
    static let rollDuration: Double = 0.55
    /// How far the drawn hinge trails the simulator's during a preset
    /// (seconds, a first-order lag on its eased sweep): Device Hub 27.1's
    /// iPhone Duo took 210 ms from its first movement to closed-looking
    /// (90°) going from open to closed, where ours, on the sweep itself,
    /// took 60–100 ms (60 fps window recordings, 2026-10-13); this lag gives
    /// 205 ms. The sweep's last angle is drawn about 0.65 s after it set off.
    static let sweepLag: Double = 0.15
    /// How far the drawn hinge trails the slider (seconds, a first-order
    /// lag): the hinge glides after the knob instead of stepping a degree at
    /// a time.
    static let chaseLag: Double = 0.06
    /// Degrees from the end under which the drawn hinge counts as there.
    static let sweepSettled: Double = 0.5
    /// How far behind the fold's centre the device's drawn centre follows
    /// (seconds, a first-order lag): closing iPhone Duo from open, Device
    /// Hub 27.1's device, folded by 115 ms, slid the last 91 pt to its
    /// closed place over 0.7 s, 57 % left after 115 ms more, 30 % after
    /// 227 ms, 17 % after 342 ms (a 60 fps window recording, 2026-10-13); ours
    /// was there with the hinge.
    static let centerLag: Double = 0.19
    /// The share of the device's width under which the drawn centre counts
    /// as there.
    static let centerSettled: Float = 0.0005
    /// How far the drawn book turn trails the face's turn (seconds), and the
    /// radians under which it counts as there.
    static let bookLag: Double = 0.08
    static let bookSettled: Float = 0.001
    /// How far the drawn book turn trails the face's turn while the device
    /// turns to the other face off a preset (the lit panel changed): a lag
    /// that gets 99 % of the way in `rollDuration`, fastest at first, as
    /// Device Hub's 0.55 s quarter turn eases out. The `bookLag` swing
    /// crossed a half turn in 0.2 s.
    static let faceTurnLag: Double = 0.12
    /// The longest a frame counts for in that turn, in seconds: the stage is
    /// still when a lit-panel change turns the device, so the time since the
    /// frame before says nothing of how far the turn has got (`BookTurnEase`).
    static let faceTurnStep: Double = 1.0 / 30
    /// How often the panel being fed is looked at for the watchdog, at most
    /// (frames come 60 times a second while the guest animates).
    static let darkSampleInterval: Duration = .milliseconds(100)
    /// What a look (the lock on the frame's surface and 1,536 reads) may cost
    /// on the main thread before the watchdog looks less often. Not measured
    /// on a live Duo: the reads are cheap, a lock on a surface the simulator's
    /// GPU wrote may wait.
    static let darkSampleBudget: Duration = .milliseconds(1)
    static let slowSampleInterval: Duration = .milliseconds(300)

    /// The wait before the panel being fed is looked at again, given what the
    /// last look cost.
    static func darkSampleGap(afterCost cost: Duration) -> Duration {
        cost > darkSampleBudget ? slowSampleInterval : darkSampleInterval
    }
    /// How often a preset's sweep is waited out by the watchdog.
    static let darkPoll: Duration = .milliseconds(200)
    /// How long a panel waiting for its first picture goes before it is fed
    /// the session's current frame again, three times: a static screen sends
    /// no frame to replace one that was lost.
    static let materialRetryDelays: [Duration] = [.milliseconds(250), .milliseconds(500), .seconds(1)]
    /// The share of the hinge's way by which the book turn arrives.
    static let bookLead: Double = 0.5
    /// How long the device takes to face the camera again, or to turn to
    /// the way it is held.
    static let turnDuration: Double = 0.35
    /// How long Turn Around takes.
    static let spinDuration: Double = 2.2
    /// How long the readout stays once the hinge has stopped.
    static let readoutLinger: Duration = .milliseconds(900)
    /// How long a panel that went dark keeps its blurred last picture when
    /// the fold was not the fold strip's (else as long as the hinge sweeps).
    static let darkenAfter: Duration = .milliseconds(700)
    /// How long a fold waits for the simulator's sweep to begin (an earlier
    /// batch still going out) before showing the angle at once.
    static let sweepWait: Duration = .seconds(2)
    /// The open device's width in the view's units (metres).
    static let framedSize: Float = 0.5
    /// The camera's vertical field of view: wide and close, so a half-open
    /// device's hinge reads with depth (at 137° the V at the hinge is 0.048
    /// of the device's height; 35° gave 0.037, 45° 0.045).
    static let fieldOfView: Float = 48
    /// How far Device Hub's camera stands from a foldable, in device heights
    /// (`DeviceModelPresentation.front`): iPhone Duo half open (a sent 130°)
    /// was 2.3 % taller 59 % of the way out to its edge than at the hinge
    /// (664 and 649 px at 2x, 2026-10-11), as a camera about 8 heights away
    /// draws it.
    static let frontDistance: Float = 8
    /// How much farther the camera stands from a device open flat than from
    /// its facing panel otherwise, eased in from half open (130°): Device Hub
    /// draws iPhone Duo open 0.3–0.56 % smaller than closed and half open
    /// 1.23–1.49 % larger (two windows, 2026-10-11), where the facing panel
    /// alone drew it open 0.22 % larger than closed.
    static let flatDistanceBias: Float = 0.0067
    /// How much of the sphere the device turns in the view frames while it
    /// faces the camera: a little less than all of it, so the device fills
    /// the stage at rest (its corners reach the sphere only when turned
    /// edge-on, and the camera backs off as it turns).
    static let fit: Float = 0.85
    /// The studio's exposure (`ImageBasedLightComponent.intensityExponent`).
    static let studioExposure: Float = -0.8
    /// Radians the device turns per point dragged, and how far it tips.
    static let turnRate: Float = 0.01
    static let maxPitch: Float = 1.2
    /// How far above a laptop and a tent the camera looks from, and how far
    /// round (radians).
    static let laptopElevation: Float = 0.35
    static let laptopTurn: Float = -0.3
    static let tentElevation: Float = 0.2
    static let tentTurn: Float = 0.35
    /// How long the camera takes to move to a laptop or a tent.
    static let holdDuration: Double = 0.6

    // MARK: - Frames

    /// Whether Reduce Motion is on: the system's setting (tests set their own).
    @ObservationIgnored var reduceMotion: () -> Bool = { MotionMetrics.reduceMotion }
    /// The motions that move with the display link's frames, in the order they
    /// began (`step`).
    @ObservationIgnored private var animations: [FrameAnimation] = []
    /// The device has to be posed again before the next frame (`layout`).
    @ObservationIgnored private var layoutRequested = false
    /// When the scene was last stepped; nil once the display link rested.
    @ObservationIgnored private var steppedAt: CFTimeInterval?
    /// How many times the device was posed, for tests: once a frame however
    /// many motions moved it.
    @ObservationIgnored private(set) var layoutPasses = 0

    /// Whether anything still moves: a motion under way, the device waiting
    /// to be posed, or the drawn centre and book turn still catching up with
    /// the fold. The display link rests when nothing does.
    var isAnimating: Bool { !animations.isEmpty || layoutRequested || !isSettled }

    /// Takes the frame due on screen at `time` (the display link's
    /// `targetTimestamp`): every motion under way takes its step, then the
    /// device is posed once if anything asked for it or the drawn centre and
    /// book turn are still catching up. Every motion goes by the time it is
    /// given, not by how many frames there were, so the lags and durations
    /// measured against Device Hub hold at any display rate. Before the first
    /// frame after the link rested the time since the last is taken as none.
    /// Returns the frame it took.
    @discardableResult
    func step(at time: CFTimeInterval) -> FrameClock {
        let frame = FrameClock(time: time, delta: steppedAt.map { max(time - $0, 0) } ?? 0)
        steppedAt = time
        if !animations.isEmpty {
            // A motion that begins in a step is first stepped on the next
            // frame (the loop goes over the motions there were).
            for animation in animations { animation.run(frame) }
            animations.removeAll { $0.isFinished }
        }
        if layoutRequested || !isSettled { applyLayout(delta: frame.delta) }
        return frame
    }

    /// The display link is resting: the next frame begins with no time
    /// behind it (`step`).
    func framesPaused() {
        steppedAt = nil
    }

    /// Puts `animation` on the display link's frames and asks for one (the
    /// link may be resting).
    private func begin(_ animation: FrameAnimation) -> FrameAnimation {
        animations.append(animation)
        setNeedsRender()
        return animation
    }

    /// The loaded model's root, nil until `load` has finished.
    var loadedRoot: Entity? { root }

    /// The view whose renderer holds the model now.
    @ObservationIgnored fileprivate(set) weak var host: DeviceModelCanvasView?
    /// The views attached to the scene that draw nothing yet: when the host
    /// goes, they are woken to take the scene (`adoptLoadedScene`), or one
    /// whose display link rested would stay blank.
    @ObservationIgnored fileprivate var waitingViews: [WeakCanvasView] = []

    /// The load under way, which a view made anew while it runs waits for
    /// (the scene outlives its views: two loads would build the model twice).
    @ObservationIgnored private var loading: Task<Entity?, Never>?

    func load(_ model: AppleDeviceModel, color: String) async -> Entity? {
        if let root { return root }
        if let loading { return await loading.value }
        let task = Task { @MainActor in await self.build(model, color: color) }
        loading = task
        let built = await task.value
        loading = nil
        return built
    }

    private func build(_ model: AppleDeviceModel, color: String) async -> Entity? {
        // The colour asked for (a layer over the file, unless it is the
        // file's own), else the file as it is.
        var loaded: (entity: Entity, found: ModelEntity, animation: AnimationResource)?
        let colored = color == AppleDeviceModel.fileColor ? nil : Self.colorVariantFile(for: model, color: color)
        for url in [colored, model.url].compactMap({ $0 }) where loaded == nil {
            guard let entity = try? await Entity(contentsOf: url) else { continue }
            var found: ModelEntity?
            func find(_ node: Entity) {
                if let candidate = node as? ModelEntity, candidate.components[ModelComponent.self] != nil { found = candidate }
                node.children.forEach(find)
            }
            find(entity)
            guard let found, let animation = entity.availableAnimations.first,
                  model.fits(animationDuration: animation.definition.duration)
            else { continue }
            loaded = (entity, found, animation)
        }
        guard let (entity, found, animation) = loaded, var component = found.components[ModelComponent.self] else { return nil }
        var parts: [AppleDeviceModel.Part] = []
        for mesh in component.mesh.contents.models {
            for part in mesh.parts {
                var lower = SIMD3<Float>(repeating: .infinity), upper = SIMD3<Float>(repeating: -.infinity)
                for point in part.positions.elements {
                    lower = simd_min(lower, point)
                    upper = simd_max(upper, point)
                }
                parts.append(AppleDeviceModel.Part(material: part.materialIndex, lower: lower, upper: upper))
            }
        }
        guard let panels = AppleDeviceModel.panels(in: parts),
              component.materials.indices.contains(panels.inner),
              component.materials.indices.contains(panels.outer)
        else { return nil }
        let controller = entity.playAnimation(animation)
        controller.speed = 0
        controller.time = model.spec.openTime
        // Both panels dark until a frame arrives for the lit one; the glass
        // over them stays Apple's (`AppleDeviceModel.panels`).
        component.materials[panels.inner] = UnlitMaterial(color: .black)
        component.materials[panels.outer] = UnlitMaterial(color: .black)
        bodyLooks = ([:], [:])
        for (index, material) in component.materials.enumerated() where index != panels.inner && index != panels.outer {
            bodyLooks.studio[index] = material
            bodyLooks.front[index] = Self.frontLook(of: material)
        }
        found.components.set(component)
        self.panels = panels
        func flatBounds(_ material: Int) -> (SIMD3<Float>, SIMD3<Float>)? {
            parts.filter { $0.material == material && $0.upper.y - $0.lower.y < 0.001 }
                .max { ($0.upper.x - $0.lower.x) * ($0.upper.z - $0.lower.z) < ($1.upper.x - $1.lower.x) * ($1.upper.z - $1.lower.z) }
                .map { ($0.lower, $0.upper) }
        }
        if let inner = flatBounds(panels.inner), let outer = flatBounds(panels.outer) {
            panelBounds = (inner, outer)
        }
        keys = AppleDeviceModel.keys(in: parts)
        if let keys, var keyed = found.components[ModelComponent.self] {
            detachKeys(keys, from: found, component: &keyed)
            found.components.set(keyed)
        }
        // The model lies flat, its inner panel facing up (+Y) with the
        // device's top edge away (-Z): stand it up to face the camera.
        let stand = Entity()
        stand.addChild(entity)
        stand.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        turntable.addChild(stand)
        // The model is life size (16.5 cm open, under the file's own
        // centimetre scale): scaled to `framedSize`. Measured flat (the
        // bounds of a skinned mesh do not follow its animation); the fold's
        // own geometry places it from there (`layout`).
        let bounds = entity.visualBounds(relativeTo: stand)
        let largest = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        guard largest > 0 else { return nil }
        let factor = Self.framedSize / largest
        entity.scale *= factor
        openCenter = -bounds.center * factor
        deviceSize = bounds.extents * factor
        if let (inner, outer) = panelBounds {
            let face = found.convert(position: [0, inner.1.y, 0], to: stand)
            let back = found.convert(position: [0, outer.0.y, 0], to: stand)
            hingeCenter = SIMD3(-face.x, -face.y, openCenter.z)
            hingeReach = abs(face.y - back.y) / 2
        } else {
            hingeCenter = openCenter
        }
        let root = Entity()
        root.addChild(turntable)
        camera.camera.fieldOfViewInDegrees = Self.fieldOfView
        camera.camera.fieldOfViewOrientation = .vertical
        root.addChild(camera)
        // The studio lights the metal and the back; a soft key and fill give
        // the matte back its fall-off.
        studioLights = []
        for (direction, intensity) in [(SIMD3<Float>(0.4, 0.8, 1), Float(300)), (SIMD3<Float>(-0.8, -0.3, 0.6), Float(100))] {
            let light = DirectionalLight()
            light.light.intensity = intensity
            light.look(at: .zero, from: direction, relativeTo: nil)
            root.addChild(light)
            studioLights.append(light)
        }
        studioRoom = await Self.studioLight()
        frontSky = await Self.frontSkyLight()
        if let environment = studioRoom ?? frontSky {
            root.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: Self.studioExposure))
            // On the model itself: the receiver is not passed down from the
            // file's root, and polished metal lit by the key alone is black.
            found.components.set(ImageBasedLightReceiverComponent(imageBasedLight: root))
            entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: root))
            for key in keyEntities {
                key.entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: root))
            }
        }
        feeder.onPresented = { [weak self] panel, queue in self?.panelPresented(panel, queue: queue) }
        feeder.onStalled = { [weak self] panel in self?.panelStalled(panel) }
        self.modelEntity = found
        self.deviceEntity = entity
        self.controller = controller
        self.spec = model.spec
        self.root = root
        applyLook()
        layout()
        if let pending = pendingOpening { fold(toOpening: pending) }
        if let pendingSession {
            show(session: pendingSession.session, on: pendingSession.panel, turns: pendingSession.turns)
        }
        return root
    }

    /// Fits the camera to a view of `size` points.
    func fit(in size: CGSize) {
        viewSize = size
        layout()
    }

    /// Lights and dresses the body for the presentation: seen from the
    /// front as Device Hub draws it, lit by `frontSkyLight` alone; turnable
    /// in the file's own materials, in the studio.
    private func applyLook() {
        let front = presentation != .free
        let materials = front ? bodyLooks.front : bodyLooks.studio
        func dress(_ entity: ModelEntity) {
            guard var component = entity.components[ModelComponent.self] else { return }
            for (index, material) in materials where component.materials.indices.contains(index) {
                component.materials[index] = material
            }
            entity.components.set(component)
        }
        if let modelEntity { dress(modelEntity) }
        for key in keyEntities { dress(key.entity) }
        for light in studioLights { light.isEnabled = !front }
        if let root, let environment = front ? frontSky ?? studioRoom : studioRoom ?? frontSky {
            root.components.set(ImageBasedLightComponent(
                source: .single(environment),
                intensityExponent: front && frontSky != nil ? 0 : Self.studioExposure
            ))
        }
    }

    /// Shows the device as `presentation` asks; facing the camera again,
    /// unzoomed, when it leaves the free view.
    func present(_ presentation: DeviceModelPresentation) {
        guard presentation != self.presentation else { return }
        let wasFree = self.presentation == .free
        self.presentation = presentation
        if wasFree != (presentation == .free) { applyLook() }
        if presentation != .free {
            resetTask?.cancel()
            spinTask?.cancel()
            spinTask = nil
            turnStart = nil
            yaw = 0
            pitch = 0
            spinAngle = 0
            zoomFactor = 1
            readoutTask?.cancel()
            readout = nil
        } else {
            panOffset = .zero
            panStart = nil
        }
        layout()
    }

    /// The camera's vertical field of view (degrees) that draws the
    /// front-on device `height` × `zoom` points tall in a view `viewHeight`
    /// points tall, a camera `frontDistance` device heights away.
    static func frontFieldOfView(viewHeight: CGFloat, height: CGFloat, zoom: CGFloat) -> Float {
        let tanHalf = Float(viewHeight / max(height * zoom, 1)) / 2 / frontDistance
        return 2 * atan(tanHalf) * 180 / .pi
    }

    /// Draws the front-on device at `zoom` times its fitted height: the
    /// stage zoom's steps, animated like the 2D stage's (`MotionMetrics.zoom`,
    /// the size growing by the same factor each frame) when `animated`, else
    /// at once. The view stays the size it is, so the model is never made
    /// anew by a zoom and the device is never absent from the stage; a model
    /// larger than the view is cut off by the stage.
    func setFrontZoom(_ zoom: CGFloat, animated: Bool) {
        let target = zoom.isFinite && zoom > 0 ? zoom : 1
        guard target != frontZoomTarget else { return }
        frontZoomTarget = target
        frontZoomTask?.cancel()
        frontZoomTask = nil
        if !Self.canPan(zoom: target) {
            panOffset = .zero
            panStart = nil
        }
        let from = shownFrontZoom
        guard animated, root != nil, presentation != .free, !reduceMotion(),
              abs(target - from) > 0.0005 * from
        else {
            shownFrontZoom = target
            layout()
            return
        }
        frontZoomTask = animate(over: MotionMetrics.zoomDuration) { [weak self] eased in
            self?.shownFrontZoom = from * pow(target / from, CGFloat(eased))
            self?.layout()
        } done: { [weak self] in
            self?.shownFrontZoom = target
            self?.frontZoomTask = nil
            self?.layout()
        }
    }

    /// The zoom above which the device is moved around the view (⌥⌘-drag,
    /// scroll), as the stage's scroll view scrolls from `WindowState.zoomOverflows`.
    static let panFromZoom: CGFloat = 1.05

    static func canPan(zoom: CGFloat) -> Bool { zoom > panFromZoom }

    /// Whether ⌥⌘-drag and scrolling move the device: front-on, zoomed.
    var canPan: Bool { presentation != .free && Self.canPan(zoom: frontZoomTarget) }

    /// The front-on device's outline (points) as the view sees it: `height`
    /// tall upright, `aspect` times that wide open (its flat model's
    /// proportions) and half that closed, when only the outer panel faces the
    /// camera (the half-open book is narrower than the open device, which
    /// leaves the pan a little more room than it needs there), then turned
    /// by the hold's `roll` (radians): on its side the outline swaps its
    /// width and height.
    static func frontOutline(height: CGFloat, aspect: CGFloat, isClosed: Bool, roll: Float) -> CGSize {
        let width = height * aspect * (isClosed ? 0.5 : 1)
        let cosine = abs(CGFloat(cos(roll))), sine = abs(CGFloat(sin(roll)))
        return CGSize(width: width * cosine + height * sine, height: width * sine + height * cosine)
    }

    /// `pan` kept where the device's `outline` (points) still reaches into
    /// `view`: it moves as far as its edge goes past the view's, not
    /// further, and not at all along an axis it does not overhang.
    static func clampedPan(_ pan: CGSize, view: CGSize, outline: CGSize) -> CGSize {
        func limit(_ value: CGFloat, view: CGFloat, outline: CGFloat) -> CGFloat {
            let reach = max((outline - view) / 2, 0)
            return min(max(value, -reach), reach)
        }
        return CGSize(
            width: limit(pan.width, view: view.width, outline: outline.width),
            height: limit(pan.height, view: view.height, outline: outline.height)
        )
    }

    /// Moves the zoomed device by a drag's `translation` from where it
    /// began, the picture following the pointer.
    func pan(by translation: CGSize) {
        guard canPan else { return }
        let start = panStart ?? panOffset
        panStart = start
        panOffset = CGSize(width: start.width + translation.width, height: start.height + translation.height)
        layout()
    }

    func endPan() {
        panStart = nil
    }

    /// Moves the zoomed device by a scroll of `delta` points (the picture
    /// following the fingers); false when it does not move.
    @discardableResult
    func pan(scrolledBy delta: CGSize) -> Bool {
        guard canPan else { return false }
        let before = panOffset
        panOffset = CGSize(width: before.width + delta.width, height: before.height + delta.height)
        layout()
        return panOffset != before
    }

    private func setNeedsRender() {
        onNeedsRender?()
    }

    /// Asks for the device to be posed again for what changed; it is posed
    /// once on the next frame (`step`), however many things changed before.
    private func layout() {
        layoutRequested = true
        setNeedsRender()
    }

    /// Poses the device for the hinge as shown: placed by the fold's own
    /// geometry, turned by the book turn, the device pose, the mouse and
    /// Turn Around, and the camera backed off until the sphere it turns in
    /// fits the view's shorter field of view. `delta` is the seconds since
    /// the last frame, which the drawn centre and book turn catch up by.
    private func applyLayout(delta: Double) {
        layoutRequested = false
        layoutPasses += 1
        frameNow += .seconds(delta)
        defer { setNeedsRender() }
        guard let deviceEntity, deviceSize.x > 0 else { return }
        let framing = AppleDeviceModel.framing(
            opening: shownOpening, width: deviceSize.x, height: deviceSize.z, thickness: deviceSize.y,
            hingeReach: hingeReach
        )
        // The framing counts from the hinge: on the inner panel's face, in
        // the middle across (the model's bounds' centre is lower, in the
        // thickness of the device, which put a half-open device 10 pt off
        // the middle once turned as a book).
        let center = easedCenter(towards: framing.center, delta: delta)
        deviceEntity.position = hingeCenter - SIMD3(center.x, center.y, 0)
        // The face the camera sees (`AppleDeviceModel.FoldFacing`): the outer
        // panel square to it, the other half swinging out of sight behind,
        // or both halves alike as a book. A laptop shows its inner face, a
        // tent its outer one.
        let showsOuter = showsOuterFace
        let book = simd_quatf(angle: easedBook(towards: showsOuter ? AppleDeviceModel.FoldFacing.outerTurn(opening: shownOpening) : innerTurn()), axis: [0, 1, 0])
        // The roll is how the lit panel is held, seen from its own face.
        let roll = simd_quatf(angle: rollAngle, axis: [0, 0, 1])
        // On its side the hinge runs across the view: a laptop tips about it
        // until its lower half lies flat, seen from a little above; a tent
        // stands on its two edges, the hinge on top, its outer panel leaning
        // back by half the opening (both halves alike, as the other app
        // stands it), seen from a little above and to the side.
        let fold = Float((180 - shownOpening) * .pi / 180)
        let laptopTilt = fold / 2 - .pi / 2 + Self.laptopElevation
        let tentTilt = Self.tentElevation - Float(shownOpening * .pi / 180) / 2
        let tilt = laptopWeight * laptopTilt + tentWeight * tentTilt
        let holdTurn = laptopWeight * Self.laptopTurn + tentWeight * Self.tentTurn
        turntable.orientation = simd_quatf(angle: pitch, axis: [1, 0, 0])
            * simd_quatf(angle: yaw + spinAngle + holdTurn, axis: [0, 1, 0])
            * simd_quatf(angle: tilt, axis: [1, 0, 0])
            * roll
            * book
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        if case .front(let height) = presentation {
            // A long lens a fixed number of device heights away keeps
            // Device Hub's perspective at any size; its field of view makes
            // the device `height` points tall. Measured from the middle of
            // the panel facing the camera (its nearest and farthest corners),
            // so the device keeps its size in every posture, as in Device Hub
            // (from the open device's plane, ours drew iPhone Duo closed 3.4 %
            // taller than open, its half-open hinge 3.3 % shorter).
            camera.camera.fieldOfViewInDegrees = Self.frontFieldOfView(viewHeight: viewSize.height, height: height, zoom: shownFrontZoom)
            let flat = Float(min(max((shownOpening - 130) / 50, 0), 1))
            let bias = Self.flatDistanceBias * flat * flat * (3 - 2 * flat)
            // A moved device is the camera moved the other way, by the
            // device's height in the scene over its height on screen per
            // point.
            let shown = max(height * shownFrontZoom, 1)
            panOffset = Self.clampedPan(
                panOffset, view: viewSize,
                outline: Self.frontOutline(
                    height: shown,
                    aspect: deviceSize.z > 0 ? CGFloat(deviceSize.x / deviceSize.z) : 1,
                    isClosed: showsOuterFace,
                    roll: rollAngle
                )
            )
            let perPoint = deviceSize.z * (1 + bias) / Float(shown)
            camera.position = [
                -Float(panOffset.width) * perPoint,
                Float(panOffset.height) * perPoint,
                facingPanelDepth() + deviceSize.z * Self.frontDistance * (1 + bias),
            ]
            return
        }
        camera.camera.fieldOfViewInDegrees = Self.fieldOfView
        let vertical = Self.fieldOfView * .pi / 180 / 2
        let horizontal = atan(Float(viewSize.width / viewSize.height) * tan(vertical))
        // Tight while the device faces the camera; the whole sphere it turns
        // in as it turns away (an edge-on device's corners reach the sphere).
        let turnedAway = max(abs(sin(yaw + spinAngle)), abs(sin(pitch)))
        let fit = Self.fit + (1 - Self.fit) * turnedAway
        camera.position = [0, 0, framing.radius * fit / sin(min(vertical, horizontal)) / zoomFactor]
    }

    /// The device's centre as drawn: it follows the fold's own centre with a
    /// lag (`centerLag`), as Device Hub's does, settling on its own once the
    /// hinge stopped; at once with Reduce Motion on or before the first draw.
    private func easedCenter(towards target: SIMD2<Float>, delta: Double) -> SIMD2<Float> {
        var center = target
        if let shown = shownCenter, !reduceMotion() {
            center = shown + (target - shown) * Float(DeviceModelMotion.lagShare(delta: delta, lag: Self.centerLag))
        }
        shownCenter = center
        centerTarget = target
        return center
    }

    /// The book turn as drawn: it follows the face's turn with a short lag
    /// (`bookLag`), so turning to the other face is a quick swing, not a
    /// jump (closing, the device jumped 35 pt in one frame as it turned to
    /// its outer face; Device Hub's slides on).
    private func easedBook(towards target: Float) -> Float {
        let book = bookEase.advance(towards: target, at: frameNow, reduceMotion: reduceMotion())
        return book
    }

    /// Whether the drawn centre and book turn are where they head. Until they
    /// are, every frame poses the device again (`step`).
    private var isSettled: Bool {
        let centerThere = zip([shownCenter], [centerTarget]).allSatisfy { shown, target in
            guard let shown, let target else { return true }
            return simd_distance(shown, target) <= Self.centerSettled * max(deviceSize.x, 0.001)
        }
        return centerThere && bookEase.isSettled
    }

    /// The hinge slider moved the device and the simulator's lit panel has
    /// not been read since. While the fed panel shows a picture the device
    /// faces it (dragged a little at a time the guest keeps the outer panel
    /// lit to 120°); once its frames go black the face is the hinge's
    /// (`AppleDeviceModel.FoldFacing`, Device Hub's 55° and 43°), as Device
    /// Hub draws a dragged hinge. Facing the fed panel whatever its frames
    /// showed a device opened in one go from behind, its outer panel square to
    /// the camera, black (the guest had lit the inner one) and the other
    /// half's back with its cameras, for about a second until a read turned it
    /// (iOS 27.1, 2026-10-14).
    @ObservationIgnored private var dragFacing = false
    @ObservationIgnored private var dragFacingFallback: Task<Void, Never>?
    /// How long a dragged hinge's face waits for the lit panel's read before
    /// it faces the recorded panel anyway (a read that never comes).
    static let dragFacingLimit: Duration = .seconds(3)

    /// The hinge slider's angle: folds as `fold(toOpening:)`, the face going
    /// by the hinge until the lit panel is read again (`litPanelSettled`).
    func dragFold(toOpening degrees: Double) {
        dragFacing = true
        dragFacingFallback?.cancel()
        dragFacingFallback = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.dragFacingLimit)
            guard !Task.isCancelled else { return }
            self?.litPanelSettled()
        }
        fold(toOpening: degrees)
    }

    /// The slider was let go. A fed panel still showing a picture is lit
    /// (dragged a little at a time, the guest keeps the outer one lit to
    /// 120°): the device faces it now rather than after the screenshots' read,
    /// which kept the hinge's dark face up for about 2 s. A black one waits for
    /// the read, or for the watchdog's move to the panel faced
    /// (`onPanelDark`).
    func hingeDragEnded() {
        guard dragFacing, let buffer = feedingSession?.frames.current?.pixelBuffer,
              FrameDarkness.isDark(buffer) == false
        else { return }
        litPanelSettled()
    }

    /// The lit panel was read after the slider moved the hinge: the device
    /// faces it again, turning to it if the hinge's face was the other.
    func litPanelSettled() {
        guard dragFacing else { return }
        dragFacing = false
        dragFacingFallback?.cancel()
        dragFacingFallback = nil
        alignFacingWithLitPanel()
    }

    /// Outside a preset's sweep (the hinge slider, a fold made elsewhere)
    /// the camera sees the face whose panel the simulator lights: the guest
    /// lights a panel by how the hinge moved (dragged a few degrees at a time
    /// to 120°, iOS 27.1 kept the outer one lit), so the face the hinge alone
    /// picks showed a dark panel while the picture was on the other.
    ///
    /// The face is the fed panel's at any opening, never the angle's: the
    /// hinge slider dragged through 55°, 90° or 107° leaves the face alone,
    /// and a lit panel that changes (a read of the simulator's screenshots, the
    /// watchdog) turns the device to the new face as a swing from the turn
    /// drawn now (`BookTurnEase`), not in a snap.
    private func alignFacingWithLitPanel() {
        guard !dragFacing else { return }
        faceFedPanel()
    }

    /// Faces the fed panel, as `alignFacingWithLitPanel` does, whether or not
    /// the hinge is being dragged.
    private func faceFedPanel() {
        guard heldFace == nil, let lit = feedingPanel, facing.hold(outer: lit == .outer) else { return }
        if lit == .inner {
            bookStart = (AppleDeviceModel.FoldFacing.outerTurn(opening: shownOpening), shownOpening)
        }
        bookEase.startSwing(at: frameNow)
        layout()
    }

    /// Whether the camera sees the outer face (a tent's, never a laptop's).
    private var showsOuterFace: Bool { facing.showsOuter }

    /// The book turn of a device showing its inner face: from where it
    /// stood when the hinge set off towards `targetOpening` to the target's
    /// own, in step with the hinge.
    private func innerTurn() -> Float {
        let target = AppleDeviceModel.FoldFacing.bookTurn(target: targetOpening)
        let span = targetOpening - bookStart.opening
        guard abs(span) > 0.001 else { return target }
        // Device Hub's book is there half way: opening from closed to half
        // open, the half that stays reached the end's turn by 77°.
        let progress = Float(min(max((shownOpening - bookStart.opening) / span / Self.bookLead, 0), 1))
        return bookStart.turn + (target - bookStart.turn) * progress
    }

    /// The depth (the view's z) half way between the nearest and the
    /// farthest corner of the panel that faces the camera: the inner one
    /// unless the device is closed. Zero before the model loads.
    private func facingPanelDepth() -> Float {
        guard let model = modelEntity, let bounds = panelBounds else { return 0 }
        let depths = AppleDeviceModel.PanelHit.regions(of: showsOuterFace ? .outer : .inner, inner: bounds.inner, outer: bounds.outer, opening: shownOpening)
            .flatMap { [$0.origin, $0.alongU, $0.alongV, $0.alongU + $0.alongV - $0.origin] }
            .map { model.convert(position: $0, to: nil).z }
        guard let near = depths.max(), let far = depths.min() else { return 0 }
        return (near + far) / 2
    }

    /// Turns the device by a drag's `translation` from where it began.
    func turn(by translation: CGSize) {
        resetTask?.cancel()
        let start = turnStart ?? (yaw, pitch)
        turnStart = start
        yaw = start.yaw + Float(translation.width) * Self.turnRate
        pitch = min(max(start.pitch + Float(translation.height) * Self.turnRate, -Self.maxPitch), Self.maxPitch)
        layout()
    }

    func endTurn() {
        turnStart = nil
    }

    /// Zooms the camera by `factor`, within 0.6× (the whole device small)
    /// and 2× (a close look at the panel, the camera still outside the device).
    func zoom(by factor: CGFloat) {
        guard presentation == .free, factor.isFinite, factor > 0 else { return }
        zoomFactor = min(max(zoomFactor * Float(factor), Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        layout()
    }

    static let zoomRange: ClosedRange<Float> = 0.6...2

    /// Faces the device to the camera again, animated: on a double click
    /// (which also undoes the zoom), and whenever the hinge moves to a new
    /// angle.
    func resetTurn(zoom resetsZoom: Bool = false) {
        if resetsZoom, zoomFactor != 1 {
            zoomFactor = 1
            layout()
        }
        resetTask?.cancel()
        turnStart = nil
        // The short way round.
        let fromYaw = remainder(yaw, 2 * .pi), fromPitch = pitch
        guard abs(fromYaw) > 0.001 || abs(fromPitch) > 0.001 else { return }
        resetTask = animate(over: Self.turnDuration) { [weak self] eased in
            self?.yaw = fromYaw * (1 - eased)
            self?.pitch = fromPitch * (1 - eased)
            self?.layout()
        }
    }

    /// Turn Around: once round the vertical axis, to show the back. With
    /// Reduce Motion on it turns the device a half turn at once instead
    /// (again to face it back).
    func spin() {
        guard presentation == .free, root != nil, spinTask == nil else { return }
        if reduceMotion() {
            resetTask?.cancel()
            yaw = remainder(yaw + .pi, 2 * .pi)
            layout()
            return
        }
        spinTask = animate(over: Self.spinDuration) { [weak self] eased in
            self?.spinAngle = 2 * .pi * eased
            self?.layout()
        } done: { [weak self] in
            self?.spinAngle = 0
            self?.spinTask = nil
            self?.layout()
        }
    }

    /// Holds the device `turns` counter-clockwise quarter turns from its
    /// resting pose, animated the short way round once the model shows.
    func roll(toTurns turns: Int) {
        rollTurns = turns
        updateHold()
        retargetRoll()
    }

    /// Shows the face a tent or a laptop holds: a laptop's inner one at once,
    /// a tent's outer one once the hinge is below the point where the
    /// device faces out (`FoldFacing.outerBelow`), or at once when no fold
    /// strip sweep is moving it: a tent made from an open device folds shut
    /// showing its inner face first, as any fold does.
    private func holdFace() {
        if heldFace != nil { bookEase.endSwing() }
        if let heldFace, heldFace == .inner || facing.showsOuter || !isSweeping
            || shownOpening < AppleDeviceModel.FoldFacing.outerBelow,
           facing.hold(outer: heldFace == .outer), heldFace == .inner {
            bookStart = (AppleDeviceModel.FoldFacing.outerTurn(opening: shownOpening), shownOpening)
        }
        retargetRoll()
    }

    /// Whether the fold strip's batch is moving the simulator's hinge (a tent
    /// set up some other way, a session that came back, shows its face at
    /// once).
    private var isSweeping: Bool {
        switch foldProgress?() {
        case .sweeping?, .waiting?: return true
        case .done?, nil: return false
        }
    }

    /// Turns the device to the way it is held, the short way round. A tent
    /// shows its outer panel, whose interface the guest turns the other way
    /// round (the same hold seen from the device's back): it stands with the
    /// hinge on top. Turning into or out of a laptop or a tent takes as long
    /// as the device takes to tip, so the two move as one.
    private func retargetRoll() {
        let turns = heldFace == .outer && facing.showsOuter ? -rollTurns : rollTurns
        let target = Float(turns) * .pi / 2
        guard target != rollTarget else { return }
        rollTarget = target
        let from = rollAngle
        let delta = remainder(target - from, 2 * .pi)
        rollTask?.cancel()
        guard root != nil, abs(delta) > 0.001 else {
            rollAngle = target
            layout()
            return
        }
        rollTask = animate(over: heldFace == nil ? Self.rollDuration : Self.holdDuration, easingOut: heldFace == nil) { [weak self] eased in
            self?.rollAngle = from + delta * eased
            self?.layout()
        }
    }

    /// Poses the device as `posture` (the pill's Laptop or Tent), or as a
    /// book seen from the front when nil.
    func hold(_ posture: SimulatorHeldPosture?) {
        guard posture != heldPosture else { return }
        heldPosture = posture
        updateHold()
    }

    /// Poses the device as a laptop (on its side, half open, the inner panel
    /// lit) or a tent (the outer panel lit), or as a book otherwise; the
    /// camera moves there.
    private func updateHold() {
        let laptop: Float = heldPosture == .laptop ? 1 : 0
        let tent: Float = heldPosture == .tent ? 1 : 0
        // A tent shows its outer face and a laptop its inner one all the way
        // there and back: no turn to the other face on the way.
        heldFace = tent == 1 ? .outer : laptop == 1 ? .inner : nil
        holdFace()
        guard laptop != laptopWeight || tent != tentWeight else { return }
        holdTask?.cancel()
        guard root != nil else {
            laptopWeight = laptop
            tentWeight = tent
            return
        }
        let from = (laptopWeight, tentWeight)
        holdTask = animate(over: Self.holdDuration) { [weak self] eased in
            self?.laptopWeight = from.0 + (laptop - from.0) * eased
            self?.tentWeight = from.1 + (tent - from.1) * eased
            self?.layout()
        }
    }

    /// Moves the hinge to `degrees`, animated, the readout showing the
    /// angle as it goes; a new angle faces the device to the camera again,
    /// unzoomed.
    func fold(toOpening degrees: Double) {
        // The slider sends an angle at the mouse's rate: while the hinge
        // chases the last, heading the same way, only the target moves.
        if continuesChase(towards: degrees) {
            targetOpening = degrees
            chaseTarget = degrees
            return
        }
        // The book turn eases on from where it stands now: from the outer
        // face's turn when the device turns to its inner one for this fold.
        let from = facing.showsOuter ? AppleDeviceModel.FoldFacing.outerTurn(opening: shownOpening) : innerTurn()
        targetOpening = degrees
        // A hinge that moves again may light the other panel: a panel that
        // stays black earns the lit panel's read again.
        darkWatch.hingeMoved()
        if darkWatch.isDark { armDarkWatch() }
        updateHold()
        if isSweeping {
            // A preset after the slider: its sweep sets the face.
            dragFacing = false
            dragFacingFallback?.cancel()
        }
        if heldFace == nil {
            if dragFacing, !isSweeping, !darkWatch.isDark {
                // A dragged hinge whose fed panel shows a picture faces it.
                bookStart = (from, shownOpening)
                faceFedPanel()
            } else if isSweeping || dragFacing {
                // A preset's face turn is the hinge's (Device Hub's 55° and
                // 43°), at the book turn's own pace, and so is a dragged
                // hinge's until the lit panel is read.
                bookEase.endSwing()
                facing.update(opening: shownOpening, target: degrees)
                if !facing.showsOuter { bookStart = (from, shownOpening) }
            } else {
                bookStart = (from, shownOpening)
                alignFacingWithLitPanel()
            }
        }
        guard let spec, let controller else {
            pendingOpening = degrees
            return
        }
        let target = spec.animationTime(forOpening: degrees)
        let start = shownTime ?? target
        guard abs(target - start) > 0.001 else {
            cancelFoldMotion()
            apply(time: target, controller: controller)
            return
        }
        resetTurn(zoom: true)
        readoutTask?.cancel()
        let sweeping: Bool
        switch foldProgress?() {
        case .sweeping?, .waiting?: sweeping = true
        case .done?, nil: sweeping = false
        }
        guard !reduceMotion() else {
            cancelFoldMotion()
            apply(time: target, controller: controller)
            return
        }
        if sweeping {
            // A preset moves as the simulator's hinge sweeps.
            cancelFoldMotion(lingering: false)
            foldTask = followSweep(to: degrees, spec: spec, controller: controller)
            return
        }
        // The slider (and a fold made elsewhere): one move that heads for
        // each new angle as it comes, rather than a new animation for every
        // degree.
        chaseTarget = degrees
        if !isChasing {
            foldTask?.cancel()
            chaseTask = chase(spec: spec, controller: controller)
            foldTask = chaseTask
        }
    }

    /// Whether the hinge is chasing the slider (`chase`).
    private var isChasing: Bool { chaseTask.map { !$0.isFinished } ?? false }

    /// Whether `degrees` is only a new target for the chase under way: the
    /// slider is still heading the way the last angle did (on the same side
    /// of the drawn hinge), with no tent or laptop held and no preset
    /// sweeping. The slider's angles come at the mouse's rate, and each one
    /// began the fold's work again: the book turn's start, the hold, the
    /// device facing the camera, the readout. A slider that turned back is
    /// not (the book turn would otherwise jump at the turn).
    private func continuesChase(towards degrees: Double) -> Bool {
        guard isChasing, spec != nil, heldFace == nil, !reduceMotion(),
              (degrees - shownOpening) * (targetOpening - shownOpening) >= 0,
              !isSweeping
        else { return false }
        return true
    }

    /// Stops the move that draws the hinge (the chase, or the sweep it
    /// follows). The readout lingers a moment if the chase was showing it.
    private func cancelFoldMotion(lingering: Bool = true) {
        let wasChasing = isChasing
        foldTask?.cancel()
        chaseTask = nil
        chaseTarget = nil
        if lingering, wasChasing { lingerReadout() }
    }

    /// Follows the slider's angle (`chaseTarget`) frame by frame, trailing
    /// it by `chaseLag`, until the hinge is there.
    private func chase(spec: AppleDeviceModel.Spec, controller: AnimationPlaybackController) -> FrameAnimation {
        begin(FrameAnimation { [weak self] frame in
            guard let self, let target = self.chaseTarget else { return false }
            let step = DeviceModelMotion.chase(
                from: self.shownOpening, to: target, delta: frame.delta,
                lag: Self.chaseLag, settledWithin: Self.sweepSettled
            )
            self.apply(time: spec.animationTime(forOpening: step.angle), controller: controller)
            self.showReadout()
            guard step.settled else { return true }
            self.chaseTask = nil
            self.chaseTarget = nil
            self.lingerReadout()
            return false
        })
    }

    /// Draws the hinge after the simulator's while the fold strip's batch
    /// goes out: each frame heads for the angle its sweep has reached
    /// (`SimulatorFoldSweep.angle(at:)`, read at the moment the frame is due
    /// on screen), trailing it by `sweepLag` as Device Hub's does, so the
    /// model and what the guest shows on its panels keep together however
    /// late a frame comes (in a busy VM the first came up to 370 ms after the
    /// click, and a model on its own clock trailed the hinge by as much).
    /// Holds while the batch waits (an earlier sweep, a pause between two) and
    /// settles on `target` once it was sent; shows `target` at once if it
    /// does not begin within `sweepWait`.
    private func followSweep(to target: Double, spec: AppleDeviceModel.Spec, controller: AnimationPlaybackController) -> FrameAnimation {
        let asked = ContinuousClock.now
        // The angle drawn, trailing the hinge (`sweepLag`).
        var drawn = shownOpening
        return begin(FrameAnimation { [weak self] frame in
            guard let self else { return false }
            let due = Self.instant(atMediaTime: frame.time)
            var angle = target
            var swept = true
            switch self.foldProgress?() {
            case .sweeping(let sweep)?:
                angle = sweep.angle(at: due)
                self.lastSweepEnd = sweep.end
                swept = false
            case .waiting?:
                if due - asked < Self.sweepWait {
                    angle = drawn
                    swept = false
                }
            case .done?, nil:
                break
            }
            drawn = DeviceModelMotion.followed(drawn, towards: angle, delta: frame.delta, lag: Self.sweepLag, reduceMotion: self.reduceMotion())
            let settled = swept && abs(drawn - target) < Self.sweepSettled
            if settled { drawn = target }
            self.apply(time: spec.animationTime(forOpening: drawn), controller: controller)
            self.showReadout()
            guard settled else { return true }
            self.lingerReadout()
            return false
        })
    }

    /// The clock instant a frame due at `time` (`CACurrentMediaTime`'s
    /// seconds, the display link's) falls on; the fold strip's sweeps are
    /// timed on the continuous clock.
    static func instant(atMediaTime time: CFTimeInterval) -> ContinuousClock.Instant {
        .now.advanced(by: .seconds(time - CACurrentMediaTime()))
    }

    /// Shows the hinge's angle beside the turnable model (the stage reads it
    /// there only), once per degree.
    private func showReadout() {
        guard presentation == .free else { return }
        let degrees = Int(shownOpening.rounded())
        if readout != degrees { readout = degrees }
    }

    /// Hides the hinge's readout a moment after it stopped.
    private func lingerReadout() {
        readoutTask?.cancel()
        readoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.readoutLinger)
            guard !Task.isCancelled, self?.readout != nil else { return }
            self?.readout = nil
        }
    }

    /// Shows the hinge at animation `time`.
    private func apply(time: Double, controller: AnimationPlaybackController) {
        controller.time = time
        shownTime = time
        guard let spec, spec.closedTime != spec.openTime else { return }
        let closedness = min(max((time - spec.openTime) / (spec.closedTime - spec.openTime), 0), 1)
        shownOpening = 180 * (1 - closedness)
        // Turning to the inner face, Device Hub holds the device at once as
        // the book the hinge is heading for.
        // A preset closing the device keeps its inner face, the half that
        // stays square to the camera, until the hinge is shut, where the two
        // faces' poses meet: Device Hub's closes without a turn (turning out
        // at 43° on the way swung the device 43° in a frame).
        if heldFace != nil {
            holdFace()
        } else if dragFacing, !isSweeping {
            // A dragged hinge (`dragFacing`): the fed panel's face while it
            // shows a picture, the hinge's once it went black, the book turn
            // easing on from the outer face's when it turns in.
            if !darkWatch.isDark {
                faceFedPanel()
            } else if facing.update(opening: shownOpening, target: targetOpening), !facing.showsOuter {
                bookStart = (AppleDeviceModel.FoldFacing.outerTurn(opening: shownOpening), shownOpening)
            }
        } else if !isSweeping {
            alignFacingWithLitPanel()
        } else if facing.showsOuter || targetOpening >= AppleDeviceModel.FoldFacing.innerFrom {
            if facing.update(opening: shownOpening, target: targetOpening), !facing.showsOuter {
                bookStart = (AppleDeviceModel.FoldFacing.bookTurn(target: targetOpening), shownOpening)
            }
        }
        layout()
    }

    /// Runs `step` with the eased progress (0...1) on every frame for
    /// `duration` seconds, then `done`, beginning with the next frame at
    /// progress 0; with Reduce Motion on, the next frame is the last.
    func animate(
        over duration: Double,
        easingOut: Bool = false,
        _ step: @escaping @MainActor (Float) -> Void,
        done: (@MainActor () -> Void)? = nil
    ) -> FrameAnimation {
        let duration = reduceMotion() ? 0 : duration
        var began: Double?
        return begin(FrameAnimation { frame in
            let from = began ?? frame.time
            began = from
            let progress = DeviceModelMotion.progress(elapsed: frame.time - from, duration: duration)
            // Easing out as the simulator's hinge sweeps
            // (`SimulatorFold.sweepAngles`) and Device Hub turns the
            // device, else in and out.
            step(DeviceModelMotion.eased(progress, easingOut: easingOut))
            guard progress >= 1 else { return true }
            done?()
            return false
        })
    }

    // MARK: - Pointer

    /// Sends a key to the lit panel's session; false without one.
    func sendKey(_ command: KeyboardCommand) -> Bool {
        guard let feedingSession else { return false }
        feedingSession.send(command)
        return true
    }

    /// A ⌘ shortcut for the lit panel's session; false when it takes none.
    func sendShortcut(_ shortcut: KeyShortcut) -> Bool {
        guard let feedingSession, feedingSession.acceptsShortcuts else { return false }
        feedingSession.send(shortcut: shortcut)
        return true
    }

    /// Sends a touch to the lit panel, or holds it while the guest ignores
    /// touches after a fold: SpringBoard's hinge-motion monitor suppressed
    /// them from the sweep's first event until about 100 ms after its last
    /// (iOS 27.1, 2026-10-13), so a tap made as the device settled was lost
    /// and only a second one landed. Held touches go out, in order and as far
    /// apart as they came (at most 100 ms), once that has passed.
    private func sendTouch(_ command: TouchCommand, to session: any MirrorSessionProtocol) {
        let now = ContinuousClock.now
        if heldTouches.isEmpty, touchesSuppressed(at: now) == nil {
            session.send(command)
            return
        }
        heldTouches.append((command, now, session))
        guard touchRelease == nil else { return }
        touchRelease = Task { @MainActor [weak self] in
            while !Task.isCancelled, let end = self?.touchesSuppressed(at: .now) {
                try? await Task.sleep(until: end, clock: .continuous)
            }
            var previous: ContinuousClock.Instant?
            while !Task.isCancelled, let self, !self.heldTouches.isEmpty {
                let touch = self.heldTouches.removeFirst()
                if let previous, touch.at > previous {
                    try? await Task.sleep(for: min(touch.at - previous, .milliseconds(100)))
                }
                previous = touch.at
                touch.session.send(touch.command)
            }
            self?.touchRelease = nil
        }
    }

    /// When the guest takes touches again, while a fold strip sweep moves
    /// the hinge or just after; nil when it takes them now.
    private func touchesSuppressed(at now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        let end: ContinuousClock.Instant?
        switch foldProgress?() {
        case .sweeping(let sweep)?:
            lastSweepEnd = sweep.end
            end = sweep.end + Self.touchSuppressionTail
        case .waiting?:
            end = now + .milliseconds(50)
        case .done?, nil:
            end = lastSweepEnd.map { $0 + Self.touchSuppressionTail }
        }
        guard let end, end > now else { return nil }
        return end
    }

    func pointerMoved(from start: CGPoint, to location: CGPoint, translation: CGSize) {
        if pointer == nil {
            if let point = framePoint(at: start), let session = feedingSession {
                pointer = .touch
                lastTouch = point
                sendTouch(TouchCommand(phase: .down, x: point.x, y: point.y), to: session)
            } else if let button = button(at: start), let sender = buttonSender {
                pointer = .key(button)
                sender.send(button: button, isDown: true)
                move(button, to: -AppleDeviceModel.Keys.pressTravel)
            } else {
                pointer = .turn
            }
        }
        switch pointer {
        case .touch:
            // Off the panel the touch stays where it left it.
            guard let point = framePoint(at: location) ?? lastTouch, let session = feedingSession else { return }
            lastTouch = point
            sendTouch(TouchCommand(phase: .move, x: point.x, y: point.y), to: session)
        case .turn:
            // Device Hub's front-on device does not turn.
            guard presentation == .free else { return }
            if hypot(translation.width, translation.height) >= Self.clickSlop { turn(by: translation) }
        case .key, nil:
            break
        }
    }

    func pointerEnded(at location: CGPoint, translation: CGSize) {
        defer { pointer = nil }
        switch pointer {
        case .touch:
            guard let point = framePoint(at: location) ?? lastTouch, let session = feedingSession else { return }
            sendTouch(TouchCommand(phase: .up, x: point.x, y: point.y), to: session)
            lastTouch = nil
        case .turn:
            endTurn()
            guard presentation == .free, hypot(translation.width, translation.height) < Self.clickSlop else { return }
            if let last = lastTurnClick, Date().timeIntervalSince(last) < Self.doubleClickInterval {
                lastTurnClick = nil
                resetTurn(zoom: true)
            } else {
                lastTurnClick = Date()
            }
        case .key(let button):
            buttonSender?.send(button: button, isDown: false)
            // Back out under the pointer, or to rest when it left the key.
            let over = self.button(at: location)
            move(button, to: over == button ? AppleDeviceModel.Keys.hoverTravel : 0)
            if let over, over != button { move(over, to: AppleDeviceModel.Keys.hoverTravel) }
            raisedKey = over
        case nil:
            break
        }
    }

    /// The session's button path, when it takes the device's buttons now.
    private var buttonSender: (any SimulatorButtonSending)? {
        guard let sender = feedingSession as? any SimulatorButtonSending, sender.acceptsButtons else { return nil }
        return sender
    }

    /// The hardware key under `location` (view points), nil off the keys,
    /// behind the device, or when the session takes no buttons.
    func button(at location: CGPoint) -> SimulatorHardwareButton? {
        guard let keys, let model = modelEntity, buttonSender != nil, let ray = ray(at: location) else { return nil }
        let origin = model.convert(position: ray.origin, from: nil)
        let direction = model.convert(direction: ray.direction, from: nil)
        return keys.key(
            alongRayFrom: origin, direction: direction,
            opening: shownOpening, pivotY: panelBounds?.inner.1.y ?? 0
        )?.button
    }

    /// The pointer moved to `location` (nil: it left the view) with no
    /// button down: the key under it stands out. Returns whether one does.
    func hover(at location: CGPoint?) -> Bool {
        guard pointer == nil else { return raisedKey != nil }
        let button = location.flatMap(button(at:))
        if button != raisedKey {
            if let raisedKey { move(raisedKey, to: 0) }
            if let button { move(button, to: AppleDeviceModel.Keys.hoverTravel) }
            raisedKey = button
        }
        return button != nil
    }

    /// Moves the key that presses `button` to stand `travel` out of its edge
    /// (in, below zero), quickly, as a key moves.
    private func move(_ button: SimulatorHardwareButton, to travel: Float) {
        guard let key = keyEntities.first(where: { $0.key.button == button }), key.travel != travel else { return }
        key.motion?.cancel()
        let from = key.travel
        key.motion = animate(over: Self.keyMotion) { [weak self] eased in
            key.travel = from + (travel - from) * eased
            key.entity.position = key.key.outward * key.travel
            self?.setNeedsRender()
        }
    }

    /// Takes the parts each key is drawn from out of the device's mesh and
    /// draws them as an entity of its own in the same place, with the
    /// device's materials. The keys sit on the half that never folds, so a
    /// static copy of their parts (no joint influences) stays on the edge.
    /// Leaves the mesh as it was when a key's parts are not all found.
    private func detachKeys(_ keys: AppleDeviceModel.Keys, from model: ModelEntity, component: inout ModelComponent) {
        let contents = component.mesh.contents
        var kept: [MeshResource.Model] = []
        var keyParts = [[MeshResource.Part]](repeating: [], count: keys.keys.count)
        for mesh in contents.models {
            var parts: [MeshResource.Part] = []
            for part in mesh.parts {
                var lower = SIMD3<Float>(repeating: .infinity), upper = SIMD3<Float>(repeating: -.infinity)
                for point in part.positions.elements {
                    lower = simd_min(lower, point)
                    upper = simd_max(upper, point)
                }
                if let index = keys.keyIndex(ofPartFrom: lower, to: upper) {
                    var copy = part
                    copy.jointInfluences = nil
                    copy.skeletonID = nil
                    keyParts[index].append(copy)
                } else {
                    parts.append(part)
                }
            }
            kept.append(MeshResource.Model(id: mesh.id, parts: parts))
        }
        guard keyParts.allSatisfy({ !$0.isEmpty }) else { return }
        var entities: [KeyEntity] = []
        for (index, parts) in keyParts.enumerated() {
            var keyContents = MeshResource.Contents()
            keyContents.models = MeshModelCollection([MeshResource.Model(id: "key\(index)", parts: parts)])
            keyContents.instances = MeshInstanceCollection([MeshResource.Instance(id: "key\(index)", model: "key\(index)")])
            guard let mesh = try? MeshResource.generate(from: keyContents) else { return }
            entities.append(KeyEntity(key: keys.keys[index], entity: ModelEntity(mesh: mesh, materials: component.materials)))
        }
        var deviceContents = contents
        deviceContents.models = MeshModelCollection(kept)
        guard (try? component.mesh.replace(with: deviceContents)) != nil else { return }
        for key in entities { model.addChild(key.entity) }
        keyEntities = entities
    }

    /// How long a key takes to move out or in.
    static let keyMotion: Double = 0.08

    /// A layer showing `model` in `color` (`AppleDeviceModel.colorVariantLayer`),
    /// written to the temporary folder; nil when it cannot be written.
    static func colorVariantFile(for model: AppleDeviceModel, color: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceHubPro-DeviceModels", isDirectory: true)
        let file = folder.appendingPathComponent("\(model.spec.productClass)-\(color).usda")
        let layer = AppleDeviceModel.colorVariantLayer(referencing: model.url, color: color)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(layer.utf8).write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    /// The camera's ray through `location` (view points), in the scene's
    /// space.
    private func ray(at location: CGPoint) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let tanHalf = tan(camera.camera.fieldOfViewInDegrees * .pi / 180 / 2)
        let aspect = Float(viewSize.width / viewSize.height)
        let ndc = SIMD2<Float>(Float(location.x / viewSize.width) * 2 - 1, 1 - Float(location.y / viewSize.height) * 2)
        let origin = camera.position(relativeTo: nil)
        let direction = simd_normalize(camera.convert(direction: [ndc.x * tanHalf * aspect, ndc.y * tanHalf, -1], to: nil))
        return (origin, direction)
    }

    /// The pixel of the lit panel's frame under `location` (view points),
    /// nil off the panel or behind it: the camera's ray through the point
    /// against the panel as folded (the half that stays flat, the other
    /// turned about the hinge by the fold), in the model's own space carried
    /// to the view's by its entity, so turns, poses and the fold all count.
    func framePoint(at location: CGPoint) -> (x: Int32, y: Int32)? {
        guard let model = modelEntity, let bounds = panelBounds, let panel = feedingPanel, let frame = shownFrame,
              let ray = ray(at: location)
        else { return nil }
        let (origin, direction) = ray

        let regions = AppleDeviceModel.PanelHit.regions(
            of: panel, inner: bounds.inner, outer: bounds.outer, opening: shownOpening
        )
        var best: (distance: Float, u: Float, v: Float)?
        for region in regions {
            let corner = model.convert(position: region.origin, to: nil)
            guard let hit = AppleDeviceModel.PanelHit.intersect(
                origin: origin, direction: direction, corner: corner,
                edgeU: model.convert(position: region.alongU, to: nil) - corner,
                edgeV: model.convert(position: region.alongV, to: nil) - corner
            ) else { continue }
            if best.map({ hit.distance < $0.distance }) ?? true {
                best = (hit.distance, region.u0 + hit.a * (region.u1 - region.u0), hit.b)
            }
        }
        guard let best else { return nil }
        return AppleDeviceModel.PanelHit.framePixel(u: best.u, v: best.v, turns: frame.turns, width: frame.width, height: frame.height)
    }

    /// A bright, slightly warm photographer's studio in high dynamic range
    /// (linear, half floats): a pale room, its floor nearly as light as its
    /// walls, a wide overhead softbox and tall strips far brighter than the
    /// room. The polished titanium band and the camera rings mirror the
    /// strips; the matte back takes the room's warm light. (A dark floor or
    /// dark flags at the sides made the band read black.)
    static func studioLight() async -> EnvironmentResource? {
        let width = 1024, height = 512
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                    | CGBitmapInfo.byteOrder16Little.rawValue
              )
        else { return nil }
        // Warm: a little less green, less blue.
        func light(_ value: CGFloat) -> CGColor {
            CGColor(colorSpace: space, components: [value, value * 0.955, value * 0.88, 1])!
        }
        guard let room = CGGradient(colorsSpace: space, colors: [light(1), light(0.85), light(0.9)] as CFArray, locations: [0, 0.5, 1])
        else { return nil }
        context.drawLinearGradient(room, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])
        // (centre across, centre down, width, height) as fractions of the
        // map, and the light; across wraps round.
        let boxes: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.5, 0.05, 1.0, 0.10, 8), (0.40, 0.35, 0.05, 0.40, 8), (0.60, 0.35, 0.05, 0.40, 8),
            (0.15, 0.40, 0.04, 0.45, 8), (0.85, 0.40, 0.04, 0.45, 8), (0.5, 0.40, 0.12, 0.30, 4.8),
        ]
        for (across, down, boxWidth, boxHeight, value) in boxes {
            context.setFillColor(light(value))
            for wrap in [-1.0, 0.0, 1.0] as [CGFloat] {
                context.fill(CGRect(
                    x: (across + wrap - boxWidth / 2) * CGFloat(width),
                    y: CGFloat(height) - (down + boxHeight / 2) * CGFloat(height),
                    width: boxWidth * CGFloat(width), height: boxHeight * CGFloat(height)
                ))
            }
        }
        guard let image = context.makeImage() else { return nil }
        return try? await EnvironmentResource(equirectangular: image)
    }

    /// `material` as Device Hub draws it from the front: pure black for the
    /// black round a panel, else in the neutral grey as bright as its colour
    /// (`AppleDeviceModel.FrontLook`).
    static func frontLook(of material: any RealityKit.Material) -> any RealityKit.Material {
        guard var lit = material as? PhysicallyBasedMaterial,
              let tint = lit.baseColor.tint.usingColorSpace(.sRGB)
        else { return material }
        let color = SIMD3<Float>(Float(tint.redComponent), Float(tint.greenComponent), Float(tint.blueComponent))
        let look = AppleDeviceModel.FrontLook.Material(
            baseColor: color,
            hasBaseTexture: lit.baseColor.texture != nil,
            metallic: lit.metallic.scale,
            roughness: lit.roughness.scale
        )
        if AppleDeviceModel.FrontLook.isBlack(look) { return UnlitMaterial(color: .black) }
        let grey = CGFloat(AppleDeviceModel.FrontLook.grey(of: color))
        lit.baseColor.tint = NSColor(srgbRed: grey, green: grey, blue: grey, alpha: tint.alphaComponent)
        return lit
    }

    /// `AppleDeviceModel.FrontLook`'s sky, in high dynamic range (linear
    /// grey, floats), laid out on the map as it was fitted: toward the
    /// viewer the half round the map's left and right edges, across its
    /// right half against its left.
    static func frontSkyLight() async -> EnvironmentResource? {
        let width = 512, height = 256
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearGray),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 32, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ),
              let data = context.data
        else { return nil }
        let pixels = data.bindMemory(to: Float.self, capacity: width * height)
        for row in 0..<height {
            let elevation = Float.pi / 2 - Float(row) / Float(height - 1) * .pi
            for column in 0..<width {
                let around = (Float(column) / Float(width) - 0.5) * 2 * .pi
                pixels[row * width + column] = AppleDeviceModel.FrontLook.sky(
                    elevation: elevation,
                    towardViewer: max(0, -cos(around)) * cos(elevation),
                    across: sin(around) * cos(elevation)
                )
            }
        }
        guard let image = context.makeImage() else { return nil }
        return try? await EnvironmentResource(equirectangular: image)
    }

    /// Feeds `session`'s frames to `panel`. The panel that was lit
    /// keeps its last picture, blurred, while the device folds (until the
    /// hinge's sweep ends, `waitForFold`), then goes dark; on the first
    /// session the other panel is dark at once.
    func show(session: any MirrorSessionProtocol, on panel: SimulatorFoldPanel, turns: @escaping (Int, Int) -> Int) {
        guard modelEntity != nil else {
            pendingSession = (session, panel, turns)
            return
        }
        pendingSession = nil
        observation = nil
        // Touches held for the old session are dropped with it, but a touch
        // under way keeps going to the new one.
        heldTouches.removeAll { $0.session !== session }
        let previous = feedingPanel
        feedingPanel = panel
        feedingSession = session
        // Another panel or session: what the last one looked like says
        // nothing of this one.
        resetDarkWatch()
        if !isSweeping { alignFacingWithLitPanel() }
        shownFrame = nil
        panelTurns = turns
        updateHold()
        let other: SimulatorFoldPanel = panel == .inner ? .outer : .inner
        // The lit panel and the session change together (the session follows
        // the fold): the second call leaves the other panel's blur running.
        if previous == panel {
            // The other panel still shows a picture and none is waiting to
            // go dark: the stage was away while the device folded.
            if darkening == nil, feeder.hasPicture(other) { darken(other) }
        } else if previous == other, feeder.holdLast(on: other, blurred: presentation == .free) {
            darkenTask?.cancel()
            darkening = other
            darkenTask = Task { @MainActor [weak self] in
                await self?.waitForFold()
                guard !Task.isCancelled else { return }
                self?.darkening = nil
                guard self?.feedingPanel != other else { return }
                self?.darken(other)
            }
        } else {
            darkenTask?.cancel()
            darkening = nil
            darken(other)
        }
        let frames = session.frames
        observation = frames.observe { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.frameArrived(frames) }
            }
        }
        frameArrived(frames)
    }

    /// Returns when the hinge has stopped for the fold strip's last batch:
    /// its sweep ended (the panel going dark keeps its blurred picture as
    /// long as the device folds), or `darkenAfter` on when the fold was not
    /// the strip's.
    private func waitForFold() async {
        let began = ContinuousClock.now
        var swept = false
        while !Task.isCancelled {
            let elapsed = ContinuousClock.now - began
            switch foldProgress?() {
            case .sweeping(let sweep)?:
                swept = true
                if ContinuousClock.now >= sweep.end { return }
            case .waiting?:
                if elapsed >= Self.sweepWait { return }
            case .done?, nil:
                if swept || elapsed >= Self.darkenAfter { return }
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// Turns `panel` black. One that showed frames keeps its texture and
    /// material, cleared: putting a black material on and making the
    /// texture again when it lit cost the main thread up to 50 ms in the
    /// middle of each fold (iPhone Duo in a VM).
    private func darken(_ panel: SimulatorFoldPanel) {
        materialRetries.removeValue(forKey: panel)?.cancel()
        if feeder.clear(panel) {
            setNeedsRender()
            return
        }
        guard let modelEntity, let panels, var component = modelEntity.components[ModelComponent.self] else { return }
        component.materials[panel == .inner ? panels.inner : panels.outer] = UnlitMaterial(color: .black)
        modelEntity.components.set(component)
        pendingMaterials[panel] = nil
        feeder.forget(panel)
        setNeedsRender()
    }

    func stopFeeding() {
        if pointer == .touch, let point = lastTouch {
            feedingSession?.send(TouchCommand(phase: .up, x: point.x, y: point.y))
        }
        if case .key(let button) = pointer { buttonSender?.send(button: button, isDown: false) }
        for key in keyEntities { move(key.key.button, to: 0) }
        raisedKey = nil
        pointer = nil
        lastTouch = nil
        observation = nil
        for task in [readoutTask, darkenTask, touchRelease] { task?.cancel() }
        for animation in [foldTask, resetTask, rollTask, spinTask, holdTask] { animation?.cancel() }
        chaseTask = nil
        chaseTarget = nil
        // A panel waiting to go dark while the stage was left would keep its
        // blurred picture for good: it goes dark now.
        if let waiting = darkening {
            darkening = nil
            darken(waiting)
        }
        for task in materialRetries.values { task.cancel() }
        materialRetries = [:]
        resetDarkWatch()
        touchRelease = nil
        heldTouches = []
        spinTask = nil
        // A turn cut short is turned again when the stage comes back, and the
        // device stands where its fold puts it.
        rollTarget = nil
        shownCenter = nil
        bookEase.forget()
    }

    /// Puts the session's latest picture on the lit panel again.
    func refeed() {
        guard let frames = feedingSession?.frames else { return }
        skippedFrame = false
        frameArrived(frames)
    }

    /// `refeed`, when pictures came while the view was not on screen.
    func refeedIfSkipped() {
        if skippedFrame { refeed() }
    }

    /// Whether the scene copies a session's pictures to its panels: not
    /// while the view's window is off screen (the main window ordered out
    /// behind the compact one shows the same device in a scene of its own,
    /// and nobody sees this one). A view that is not in a window yet, or a
    /// scene without a view, takes them.
    static func copiesFrames(hostWindowVisible: Bool?) -> Bool {
        hostWindowVisible != false
    }

    /// A picture arrived while `copiesFrames` was false.
    @ObservationIgnored private var skippedFrame = false

    private func frameArrived(_ frames: FrameStore) {
        // A callback queued before the session changed.
        guard frames === feedingSession?.frames else { return }
        guard Self.copiesFrames(hostWindowVisible: host?.window?.isVisible) else {
            skippedFrame = true
            return
        }
        watchFedPanel()
        guard let frame = frames.current, let buffer = frame.pixelBuffer,
              let panel = feedingPanel, let panels, let modelEntity
        else { return }
        let index = panel == .inner ? panels.inner : panels.outer
        let turns = ((panelTurns(frame.width, frame.height) % 4) + 4) % 4
        shownFrame = (frame.width, frame.height, turns)
        let size = turns % 2 == 1 ? (frame.height, frame.width) : (frame.width, frame.height)
        guard let texture = feeder.texture(for: panel, width: size.0, height: size.1) else { return }
        if feeder.needsMaterial(panel) {
            // The panel takes its new texture once the texture has a
            // picture (`panelPresented`): RealityKit drew nothing of the
            // whole device while a material's drawable texture had none yet
            // (three frames, each time a fold lit the other panel). Asked
            // again with each frame until then, in case one never reached it,
            // and with the current frame when none comes (`armMaterialRetry`).
            pendingMaterials[panel] = (texture, index)
            armMaterialRetry(panel)
        }
        feeder.copy(buffer, to: panel, turns: turns)
    }

    /// Feeds `panel` the session's current frame again while it still waits
    /// for its first picture, after 0.25, 0.5 and 1 s: a static screen sends
    /// no frame to replace the one a drawable queue that was full dropped, or
    /// the one the panel's new texture (a size change after a rotation or a
    /// fold) never received, and the panel would stay on the black
    /// placeholder.
    private func armMaterialRetry(_ panel: SimulatorFoldPanel) {
        guard materialRetries[panel] == nil else { return }
        materialRetries[panel] = Task { @MainActor [weak self] in
            for delay in Self.materialRetryDelays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.pendingMaterials[panel] != nil, self.feedingPanel == panel,
                      let frames = self.feedingSession?.frames
                else { break }
                self.frameArrived(frames)
            }
            if !Task.isCancelled { self?.materialRetries[panel] = nil }
        }
    }

    // MARK: - A panel that stays black

    private func resetDarkWatch() {
        darkWatchTask?.cancel()
        darkWatchTask = nil
        darkWatch.reset()
        lastDarkSample = nil
        sampleGap = Self.darkSampleInterval
    }

    /// Looks at the panel being fed, for the watchdog, at most every
    /// `darkSampleInterval` (`slowSampleInterval` after a look that cost more
    /// than `darkSampleBudget`), and only while no timer waits to look again:
    /// a lit panel costs a glance a tenth of a second, no timer.
    private func watchFedPanel() {
        guard darkWatchTask == nil else { return }
        let now = ContinuousClock.now
        if let last = lastDarkSample, now - last < sampleGap { return }
        sampleFedPanel(at: now)
        armDarkWatch()
    }

    /// Notes whether the fed panel's current frame is black. A preset's sweep
    /// lights the panel it heads for as it goes (dark until the guest gets
    /// there): nothing is held against it until the sweep is over.
    private func sampleFedPanel(at now: ContinuousClock.Instant) {
        lastDarkSample = now
        guard feedingPanel != nil, let frames = feedingSession?.frames else { return }
        if isSweeping {
            darkWatch.reset()
            return
        }
        if let buffer = frames.current?.pixelBuffer, let dark = FrameDarkness.isDark(buffer) {
            darkWatch.observe(dark: dark, at: now)
            sampleGap = Self.darkSampleGap(afterCost: ContinuousClock.now - now)
        }
    }

    /// Wakes when the next check is due (the panel stayed black for
    /// `DarkPanelWatchdog.darkFor`), or soon after a sweep started to look
    /// again once it ended.
    private func armDarkWatch() {
        guard darkWatchTask == nil, feedingPanel != nil else { return }
        let wake: ContinuousClock.Instant
        if isSweeping {
            wake = .now + Self.darkPoll
        } else if let due = darkWatch.due {
            wake = due
        } else {
            return
        }
        darkWatchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(until: wake, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.darkWatchTask = nil
            let now = ContinuousClock.now
            self.sampleFedPanel(at: now)
            if self.darkWatch.take(at: now) {
                // While the slider drags the hinge the guest switches panels
                // as it goes, so the other panel is the likely one; at rest a
                // black panel may be a black app, and only a read tells.
                let other: SimulatorFoldPanel? = self.feedingPanel.map { $0 == .outer ? .inner : .outer }
                self.onPanelDark?(self.dragFacing ? other : nil)
            }
            self.armDarkWatch()
        }
    }

    /// The scene is drawn by another renderer now (a view made anew): each
    /// panel takes a texture of its own again, fed the current frame. The
    /// drawables of a panel's queue went on to the renderer that drew it
    /// before and never came back: after the stage was left and shown again
    /// (a simulator's reboot), every frame found no drawable and the panel
    /// kept its last picture for good, the 2D stage meanwhile live
    /// (2026-10-15).
    func rendererChanged() {
        // The first renderer: no other one took the drawables.
        guard hadRenderer else {
            hadRenderer = true
            return
        }
        rebuildTextures([.outer, .inner])
    }

    /// The scene's renderer drew a frame (`panelStalled`).
    func noteDrawn() {
        drawsSinceStall += 1
    }

    /// A frame for `panel` found no drawable: the scene draws, so RealityKit
    /// takes the drawables it holds. A queue that stays starved has lost its
    /// drawables (`rendererChanged`): after `stallsBeforeNewTexture` stalls
    /// with no picture through, the panel takes a new texture, at most once
    /// every `newTextureInterval`.
    private func panelStalled(_ panel: SimulatorFoldPanel) {
        setNeedsRender()
        // A renderer that rests (a window that is not drawing) takes no
        // drawable either: only a stall after a frame was drawn counts.
        guard drawsSinceStall > 0 else { return }
        drawsSinceStall = 0
        let count = (stalls[panel] ?? 0) + 1
        stalls[panel] = count
        let now = ContinuousClock.now
        guard Self.takesNewTexture(stalls: count, lastNewTexture: lastNewTexture[panel], now: now) else { return }
        lastNewTexture[panel] = now
        rebuildTextures([panel])
    }

    /// The stalls after which a panel's texture is made anew, and how often
    /// at most.
    static let stallsBeforeNewTexture = 3
    static let newTextureInterval: Duration = .seconds(3)

    /// Whether a panel whose frames found no drawable `stalls` times in a row
    /// takes a new texture now, its last new one made at `lastNewTexture`.
    static func takesNewTexture(
        stalls: Int,
        lastNewTexture: ContinuousClock.Instant?,
        now: ContinuousClock.Instant
    ) -> Bool {
        guard stalls >= stallsBeforeNewTexture else { return false }
        return lastNewTexture.map { now - $0 >= newTextureInterval } ?? true
    }

    /// Drops `panels`' textures and feeds the panel lit now again: its
    /// material keeps showing the old texture until the new one has its
    /// first picture (`panelPresented`). Another panel goes dark at once,
    /// its material black: the old texture's queue would not take the black
    /// either.
    private func rebuildTextures(_ panels: [SimulatorFoldPanel]) {
        for panel in panels where feeder.hasTexture(panel) {
            stalls[panel] = nil
            pendingMaterials[panel] = nil
            materialRetries.removeValue(forKey: panel)?.cancel()
            feeder.forget(panel)
            // A panel held while the device folds goes dark when the fold
            // ends (`darkenTask`).
            if panel != feedingPanel, panel != darkening { darken(panel) }
        }
        if let panel = feedingPanel, panels.contains(panel), let frames = feedingSession?.frames {
            frameArrived(frames)
        }
    }

    /// A picture reached `panel`'s texture: the panel takes a texture
    /// waiting for its first one, and the scene draws again.
    private func panelPresented(_ panel: SimulatorFoldPanel, queue: ObjectIdentifier) {
        if feeder.isCurrent(queue: queue, for: panel) { stalls[panel] = nil }
        // A picture drawn for the texture before (the panel's frames turned)
        // does not count for the new one.
        if let pending = pendingMaterials[panel], feeder.isCurrent(pending.texture, queue: queue, for: panel),
           let modelEntity, var component = modelEntity.components[ModelComponent.self],
           component.materials.indices.contains(pending.index) {
            // The simulator's own pixels: tone mapping, which the lit
            // device takes, greyed and dimmed them (Device Hub's are not).
            var material = UnlitMaterial(applyPostProcessToneMap: false)
            material.color = .init(texture: .init(pending.texture))
            component.materials[pending.index] = material
            modelEntity.components.set(component)
            pendingMaterials[panel] = nil
            materialRetries.removeValue(forKey: panel)?.cancel()
            feeder.markMaterialSet(panel)
        }
        setNeedsRender()
    }
}

/// Copies a session's frames (IOSurface-backed BGRA pixel buffers) into a
/// RealityKit texture through a drawable queue, one per panel, turned so
/// the picture stands upright on the model's panel.
///
/// The drawing runs on a queue of its own (`PanelRenderer`): a drawable
/// queue hands out a drawable only once RealityKit took the last ones, and
/// asking on the main thread froze the app when it did not (the panel's
/// texture had just been replaced for the interface's turn). Each panel
/// draws its newest frame only; the ones that came meanwhile are dropped.
@MainActor
final class PanelTextureFeeder {
    private let renderer = PanelRenderer()
    /// Runs on the main actor after a frame reached a panel's texture.
    var onPresented: (@MainActor (SimulatorFoldPanel, ObjectIdentifier) -> Void)? {
        didSet {
            renderer.setPresented { [weak self] panel, queue in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onPresented?(panel, queue) } }
            }
        }
    }
    /// Runs on the main actor when a panel's drawable queue had no drawable
    /// for a frame (RealityKit took none since): the scene should draw, so it
    /// takes the queue's drawables, and the frame is tried again.
    var onStalled: (@MainActor (SimulatorFoldPanel) -> Void)? {
        didSet {
            renderer.setStalled { [weak self] panel, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onStalled?(panel) } }
            }
        }
    }
    private var textures: [SimulatorFoldPanel: (resource: TextureResource, queue: TextureResource.DrawableQueue, width: Int, height: Int)] = [:]
    private var materialSet: Set<SimulatorFoldPanel> = []
    /// Each panel's last picture and its turn, for the blur of a panel
    /// going dark.
    private var last: [SimulatorFoldPanel: (buffer: CVPixelBuffer, turns: Int)] = [:]

    /// The blur's reach on a panel going dark, in source pixels per tap.
    static let blurStep: Float = 9

    func texture(for panel: SimulatorFoldPanel, width: Int, height: Int) -> TextureResource? {
        if let existing = textures[panel], existing.width == width, existing.height == height { return existing.resource }
        guard width > 0, height > 0,
              let placeholder = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage(),
              let resource = try? TextureResource(image: placeholder, options: .init(semantic: .color)),
              let queue = try? TextureResource.DrawableQueue(.init(
                  pixelFormat: .bgra8Unorm_srgb, width: width, height: height,
                  usage: [.shaderRead, .renderTarget], mipmapsMode: .none
              ))
        else { return nil }
        queue.allowsNextDrawableTimeout = true
        resource.replace(withDrawables: queue)
        textures[panel] = (resource, queue, width, height)
        materialSet.remove(panel)
        return resource
    }

    func needsMaterial(_ panel: SimulatorFoldPanel) -> Bool { !materialSet.contains(panel) }
    /// Whether `panel` still shows a picture (it was fed one and not cleared).
    func hasPicture(_ panel: SimulatorFoldPanel) -> Bool { last[panel] != nil }
    /// Whether `texture` is `panel`'s texture and `queue` its drawable queue.
    func isCurrent(_ texture: TextureResource, queue: ObjectIdentifier, for panel: SimulatorFoldPanel) -> Bool {
        guard let current = textures[panel] else { return false }
        return current.resource === texture && ObjectIdentifier(current.queue) == queue
    }
    func markMaterialSet(_ panel: SimulatorFoldPanel) { materialSet.insert(panel) }
    /// Whether `panel` has a texture.
    func hasTexture(_ panel: SimulatorFoldPanel) -> Bool { textures[panel] != nil }
    /// Whether `queue` is `panel`'s drawable queue now.
    func isCurrent(queue: ObjectIdentifier, for panel: SimulatorFoldPanel) -> Bool {
        textures[panel].map { ObjectIdentifier($0.queue) == queue } ?? false
    }

    /// Draws `panel`'s last picture again, blurred when `blurred`; false
    /// when it has none. Device Hub keeps the picture sharp on the panel
    /// folding away (iPhone Duo seen from the front); the turnable view
    /// blurs it, as the other app's does.
    func holdLast(on panel: SimulatorFoldPanel, blurred: Bool) -> Bool {
        guard let picture = last[panel] else { return false }
        return copy(picture.buffer, to: panel, turns: picture.turns, blur: blurred ? Self.blurStep : 0)
    }

    /// Draws `panel` black, keeping its texture for the next time it lights;
    /// false when it has none.
    func clear(_ panel: SimulatorFoldPanel) -> Bool {
        guard let target = textures[panel] else { return false }
        last[panel] = nil
        renderer.submit(PanelRenderer.Job(buffer: nil, queue: target.queue, turns: 0, blur: 0), for: panel)
        return true
    }

    /// Lets go of `panel`'s last picture (the session's buffer) and texture:
    /// the panel is dark.
    func forget(_ panel: SimulatorFoldPanel) {
        last[panel] = nil
        textures[panel] = nil
        materialSet.remove(panel)
        renderer.drop(panel)
    }

    /// Queues `buffer` for `panel`'s next drawable, turned by `turns`
    /// clockwise quarter turns (the drawable already has the turned size),
    /// blurred by `blur` source pixels a tap when above zero. False when the
    /// panel has no texture of that size.
    @discardableResult
    func copy(_ buffer: CVPixelBuffer, to panel: SimulatorFoldPanel, turns: Int, blur: Float = 0) -> Bool {
        guard let target = textures[panel] else { return false }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let turned = turns % 2 == 1 ? (height, width) : (width, height)
        guard turned == (target.width, target.height) else { return false }
        if blur <= 0 { last[panel] = (buffer, turns) }
        renderer.submit(PanelRenderer.Job(buffer: buffer, queue: target.queue, turns: turns, blur: blur), for: panel)
        return true
    }
}

/// Draws panel frames into drawable queues on a serial queue, newest frame
/// first: a panel whose draw is under way keeps only the latest job waiting.
/// `@unchecked Sendable`: its Metal objects are thread-safe, the jobs are
/// handed over under the lock, and every draw runs on `queue`.
final class PanelRenderer: @unchecked Sendable {
    struct Job: @unchecked Sendable {
        /// The frame; nil clears the drawable to black.
        let buffer: CVPixelBuffer?
        let queue: TextureResource.DrawableQueue
        let turns: Int
        let blur: Float
        /// Set on the second try (`retryDelay`): a frame is tried twice.
        var retried = false
    }

    private let device = MTLCreateSystemDefaultDevice()
    private let commandQueue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private var cache: CVMetalTextureCache?
    private let queue = DispatchQueue(label: "com.devicehubpro.device-model.panels", qos: .userInteractive)
    /// Runs on the drawing queue after each frame reached its texture.
    /// Boxed: a closure held in a `Mutex` is reabstracted and written back
    /// by every `withLock { $0 }`, its thunk chain two frames deeper each
    /// read, until a drawing thread's stack overflows (measured: 2,232
    /// frames after 1,111 reads).
    private let presented = Mutex<PresentedHandler?>(nil)
    /// Runs on the drawing queue when a frame found no drawable.
    private let stalled = Mutex<PresentedHandler?>(nil)

    final class PresentedHandler: Sendable {
        let call: @Sendable (SimulatorFoldPanel, ObjectIdentifier) -> Void
        init(_ call: @escaping @Sendable (SimulatorFoldPanel, ObjectIdentifier) -> Void) { self.call = call }
    }
    private let state = Mutex(PanelJobBoard<Job>())

    /// How long a frame that found no drawable waits before its second try:
    /// the scene is asked to draw meanwhile, so RealityKit takes the drawables
    /// it holds.
    static let retryDelay: DispatchTimeInterval = .milliseconds(30)

    func setPresented(_ handler: @escaping @Sendable (SimulatorFoldPanel, ObjectIdentifier) -> Void) {
        presented.withLock { $0 = PresentedHandler(handler) }
    }

    func setStalled(_ handler: @escaping @Sendable (SimulatorFoldPanel, ObjectIdentifier) -> Void) {
        stalled.withLock { $0 = PresentedHandler(handler) }
    }

    /// Calls the handler, as a drawn frame does.
    /// Reports a picture that reached `panel`'s texture through `queue`.
    func notifyPresented(_ panel: SimulatorFoldPanel, queue: ObjectIdentifier) {
        presented.withLock { $0 }?.call(panel, queue)
    }

    init() {
        commandQueue = device?.makeCommandQueue()
        pipeline = Self.makePipeline(device: device)
        if let device { CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) }
    }

    /// Samples the frame turned by `turns` clockwise quarter turns, as the
    /// mirror's own shader does (`Shaders.metal`, `mirror_fragment`); with a
    /// `blur` step, a 7 × 7 Gaussian of taps that far apart.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct PanelVertex {
        float4 position [[position]];
        float2 uv;
    };

    vertex PanelVertex panel_vertex(uint vertexID [[vertex_id]]) {
        const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        const float2 uvs[3] = { float2(0.0, 1.0), float2(2.0, 1.0), float2(0.0, -1.0) };
        PanelVertex out;
        out.position = float4(positions[vertexID], 0.0, 1.0);
        out.uv = uvs[vertexID];
        return out;
    }

    fragment float4 panel_fragment(
        PanelVertex in [[stage_in]],
        texture2d<float> frame [[texture(0)]],
        constant int &turns [[buffer(0)]],
        constant float &blur [[buffer(1)]]
    ) {
        constexpr sampler nearest(coord::normalized, filter::nearest, address::clamp_to_edge);
        constexpr sampler smooth(coord::normalized, filter::linear, address::clamp_to_edge);
        float2 uv = in.uv;
        switch ((turns % 4 + 4) % 4) {
            case 1: uv = float2(uv.y, 1.0 - uv.x); break;
            case 2: uv = float2(1.0 - uv.x, 1.0 - uv.y); break;
            case 3: uv = float2(1.0 - uv.y, uv.x); break;
            default: break;
        }
        if (blur <= 0.0) {
            return frame.sample(nearest, uv);
        }
        float2 texel = blur / float2(frame.get_width(), frame.get_height());
        float4 sum = float4(0.0);
        float total = 0.0;
        for (int i = -3; i <= 3; i++) {
            for (int j = -3; j <= 3; j++) {
                float weight = exp(-float(i * i + j * j) / 8.0);
                sum += frame.sample(smooth, uv + float2(i, j) * texel) * weight;
                total += weight;
            }
        }
        return sum / total;
    }
    """

    private static func makePipeline(device: MTLDevice?) -> MTLRenderPipelineState? {
        guard let device, let library = try? device.makeLibrary(source: shaderSource, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "panel_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "panel_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Queues `job` for `panel`, replacing one still waiting.
    func submit(_ job: Job, for panel: SimulatorFoldPanel) {
        let start = state.withLock { $0.submit(job, for: panel).start }
        if start { queue.async { [self] in drain(panel) } }
    }

    /// Drops `panel`'s waiting job (the panel went dark), and with it any
    /// second try of an earlier frame.
    func drop(_ panel: SimulatorFoldPanel) {
        state.withLock { $0.drop(panel) }
    }

    private func drain(_ panel: SimulatorFoldPanel) {
        while let (job, sequence) = state.withLock({ $0.next(for: panel) }) {
            if !draw(job, for: panel), !job.retried { retryLater(job, sequence: sequence, for: panel) }
        }
    }

    /// A frame that found no drawable is tried once more shortly after, unless
    /// a newer one came meanwhile (that one is the picture the panel should
    /// show): the newest frame was lost with the queue full, and a static
    /// screen sends no other.
    private func retryLater(_ job: Job, sequence: UInt64, for panel: SimulatorFoldPanel) {
        stalled.withLock { $0 }?.call(panel, ObjectIdentifier(job.queue))
        queue.asyncAfter(deadline: .now() + Self.retryDelay) { [self] in
            var again = job
            again.retried = true
            let start = state.withLock { $0.requeue(again, sequence: sequence, for: panel) }
            if start { drain(panel) }
        }
    }

    /// One frame into the job's next drawable; false when it found none (the
    /// queue was full, RealityKit having taken no drawable since), which a
    /// second try can mend.
    @discardableResult
    private func draw(_ job: Job, for panel: SimulatorFoldPanel) -> Bool {
        guard let buffer = job.buffer else {
            return clear(job.queue, for: panel)
        }
        guard let commandQueue, let pipeline, let cache,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA
        else { return true }
        guard let drawable = try? job.queue.nextDrawable() else { return false }
        // Lets go of the textures of buffers nobody holds any more, as the
        // 2D renderer does (`MirrorRenderer.wrap`).
        CVMetalTextureCacheFlush(cache, 0)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var wrapped: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm_srgb, width, height, 0, &wrapped)
        guard let wrapped, let source = CVMetalTextureGetTexture(wrapped),
              let commands = commandQueue.makeCommandBuffer()
        else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var quarterTurns = Int32(job.turns)
        var blurStep = job.blur
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentBytes(&quarterTurns, length: MemoryLayout<Int32>.size, index: 0)
        encoder.setFragmentBytes(&blurStep, length: MemoryLayout<Float>.size, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.addCompletedHandler { _ in
            // Keeps the pixel buffer's texture alive until the draw is done.
            _ = wrapped
        }
        commands.commit()
        commands.waitUntilScheduled()
        drawable.present()
        notifyPresented(panel, queue: ObjectIdentifier(job.queue))
        return true
    }

    /// The queue's next drawable, black.
    private func clear(_ queue: TextureResource.DrawableQueue, for panel: SimulatorFoldPanel) -> Bool {
        guard let commandQueue else { return true }
        guard let drawable = try? queue.nextDrawable(), let commands = commandQueue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilScheduled()
        drawable.present()
        notifyPresented(panel, queue: ObjectIdentifier(queue))
        return true
    }
}

/// The frames `PanelRenderer` has to draw, by panel: the newest one waiting
/// for each, which panels are being drawn, and which frame is the newest each
/// panel was handed, so a frame that found no drawable is tried again only
/// while no newer one came (a stale picture must never replace a newer one).
struct PanelJobBoard<Job> {
    private var waiting: [SimulatorFoldPanel: (job: Job, sequence: UInt64)] = [:]
    private var drawing: Set<SimulatorFoldPanel> = []
    private var latest: [SimulatorFoldPanel: UInt64] = [:]
    private var counter: UInt64 = 0

    /// Queues `job` for `panel`, replacing one still waiting; `start` when
    /// nothing is drawing the panel yet, so the caller starts draining it.
    mutating func submit(_ job: Job, for panel: SimulatorFoldPanel) -> (sequence: UInt64, start: Bool) {
        counter += 1
        latest[panel] = counter
        waiting[panel] = (job, counter)
        return (counter, drawing.insert(panel).inserted)
    }

    /// The job to draw next for `panel` and its sequence; nil when none is
    /// waiting, which ends the draining.
    mutating func next(for panel: SimulatorFoldPanel) -> (Job, UInt64)? {
        guard let next = waiting.removeValue(forKey: panel) else {
            drawing.remove(panel)
            return nil
        }
        return (next.job, next.sequence)
    }

    /// Queues `job` again, as the frame with `sequence` once handed to
    /// `panel`; `start` when the caller drains the panel. Nothing happens
    /// (nil) when a newer frame was handed to the panel since, or the panel
    /// was dropped.
    mutating func requeue(_ job: Job, sequence: UInt64, for panel: SimulatorFoldPanel) -> Bool {
        guard latest[panel] == sequence, waiting[panel] == nil else { return false }
        waiting[panel] = (job, sequence)
        return drawing.insert(panel).inserted
    }

    /// Forgets `panel`'s waiting job (it went dark) and makes every frame
    /// handed to it before stale.
    mutating func drop(_ panel: SimulatorFoldPanel) {
        waiting.removeValue(forKey: panel)
        counter += 1
        latest[panel] = counter
    }
}
