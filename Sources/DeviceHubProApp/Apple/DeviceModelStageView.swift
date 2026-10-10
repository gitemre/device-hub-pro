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
/// face the camera alike, the hinge away (`AppleDeviceModel.framing`); a fold
/// shows the hinge's angle beside it, and the panel going dark keeps its last
/// picture, blurred, while the device folds.
struct DeviceModelStageView: View {
    let model: AppleDeviceModel
    let session: any MirrorSessionProtocol
    /// The hinge, 0 (closed) to 180 (flat).
    let opening: Double
    let litPanel: SimulatorFoldPanel
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
    /// Holds the scene, made on first use: a `@State` initial value is
    /// evaluated on every init of this struct (each slider tick, resize
    /// frame), and the scene's renderer compiles a shader.
    @State private var holder = DeviceModelSceneHolder()
    @Environment(AppModel.self) private var appModel

    private var scene: DeviceModelScene { holder.scene }

    /// Whether the stage shows the mirrored foldable in its 3D model: asked
    /// for, a usable model in the user's Xcode, and the device drawn in its
    /// Apple chrome (Show Device Frame on). The stage, its zoom and the fold
    /// strip's 3D controls all go by this.
    static func isShown(chrome: DeviceChrome, workspace: DeviceWorkspace, preferences: AppPreferences) -> Bool {
        guard case .appleChrome = chrome else { return false }
        return workspace.window.showDeviceFrame && preferences.showDeviceModel
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
            forwardsKeyboard: appModel.preferences.keyboardForwardingEnabled,
            unusable: { [simulators = appModel.simulators, model] in simulators.setDeviceModelUnusable(model) }
        )
        .overlay(alignment: .leading) {
            if let readout = scene.readout {
                Text(verbatim: "\(readout)°")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
                    .transition(.opacity)
                    .accessibilityLabel("Hinge \(readout) degrees")
            }
        }
        .animation(.easeOut(duration: 0.2), value: scene.readout == nil)
        .onChange(of: size, initial: true) { _, size in
            scene.fit(in: size)
        }
        .onChange(of: roll, initial: true) { _, turns in
            scene.roll(toTurns: turns)
        }
        .onChange(of: opening, initial: true) { _, degrees in
            scene.fold(toOpening: degrees)
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
        .onDisappear { scene.stopFeeding() }
        .accessibilityLabel("3D device")
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
    /// The Mac keyboard reaches the simulator (Keyboard Capture), as on the
    /// 2D stage.
    let forwardsKeyboard: Bool
    /// The model did not load as one the scene can show (another build's
    /// file of another shape, say): the stage goes back to the 2D chrome.
    let unusable: @MainActor () -> Void

    func makeNSView(context: Context) -> DeviceModelCanvasView {
        let view = DeviceModelCanvasView()
        view.attach(scene: scene, model: model, unusable: unusable)
        view.forwardsKeyboard = forwardsKeyboard
        return view
    }

    func updateNSView(_ view: DeviceModelCanvasView, context: Context) {
        view.forwardsKeyboard = forwardsKeyboard
    }

    static func dismantleNSView(_ view: DeviceModelCanvasView, coordinator: ()) {
        view.detach()
    }
}

/// A layer-hosting view whose display link draws a frame when the scene
/// asked for one and the last has finished. It hands the mouse to the
/// scene, in its own top-left points (the scene's view size).
@MainActor
final class DeviceModelCanvasView: NSView {
    private let metalLayer = CAMetalLayer()
    private var renderer: RealityRenderer?
    private weak var scene: DeviceModelScene?
    private var mouseStart: CGPoint?
    private var link: CADisplayLink?
    private var needsRender = true
    private var rendering = false
    private var loadTask: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer { metalLayer }

    var forwardsKeyboard = true

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

    override func magnify(with event: NSEvent) {
        scene?.zoom(by: 1 + event.magnification)
    }

    /// A scroll off the panel zooms (on it the simulator scrolls with a drag).
    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let scene, scene.framePoint(at: point) == nil, event.scrollingDeltaY != 0 else {
            return super.scrollWheel(with: event)
        }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
        scene.zoom(by: 1 + step)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        mouseStart = point
        scene?.pointerMoved(from: point, to: point, translation: .zero)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        scene?.pointerMoved(from: start, to: point, translation: CGSize(width: point.x - start.x, height: point.y - start.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = mouseStart else { return }
        mouseStart = nil
        let point = convert(event.locationInWindow, from: nil)
        scene?.pointerEnded(at: point, translation: CGSize(width: point.x - start.x, height: point.y - start.y))
    }

    func attach(scene: DeviceModelScene, model: AppleDeviceModel, unusable: @escaping @MainActor () -> Void) {
        self.scene = scene
        scene.onNeedsRender = { [weak self] in self?.needsRender = true }
        loadTask = Task { [weak self] in
            let root = await scene.load(model)
            guard !Task.isCancelled else { return }
            guard let root, let self, let renderer = try? RealityRenderer() else {
                unusable()
                return
            }
            renderer.entities.append(root)
            renderer.activeCamera = scene.camera
            renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0, alpha: 0))
            self.renderer = renderer
            self.needsRender = true
        }
    }

    func detach() {
        loadTask?.cancel()
        link?.invalidate()
        link = nil
        renderer = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
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

    /// The drawable at the screen's pixels; on a 1× screen twice that, for
    /// the layer to scale down (the renderer has no multisampling).
    private func resizeDrawable() {
        let scale = window?.backingScaleFactor ?? 2
        let supersample: CGFloat = scale < 2 ? 2 : 1
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(bounds.width * scale * supersample, 1), height: max(bounds.height * scale * supersample, 1))
        guard metalLayer.drawableSize != size else { return }
        metalLayer.drawableSize = size
        needsRender = true
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard needsRender, !rendering, let renderer, bounds.width > 1, bounds.height > 1,
              let drawable = metalLayer.nextDrawable()
        else { return }
        needsRender = false
        rendering = true
        let handoff = DrawableHandoff(drawable: drawable)
        do {
            let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: drawable.texture))
            try renderer.updateAndRender(deltaTime: 1.0 / 60, cameraOutput: output, onComplete: { _ in
                handoff.drawable.present()
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.rendering = false }
                }
            })
        } catch {
            rendering = false
        }
    }
}

/// A drawable handed to the renderer's completion, which presents it.
private struct DrawableHandoff: @unchecked Sendable {
    let drawable: CAMetalDrawable
}

@MainActor
final class DeviceModelSceneHolder {
    private(set) lazy var scene = DeviceModelScene()
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
    @ObservationIgnored private var deviceSize = SIMD3<Float>(repeating: 0)
    /// The hinge as shown (degrees, 0 closed, 180 flat).
    @ObservationIgnored private var shownOpening: Double = 180
    @ObservationIgnored private var viewSize = CGSize.zero
    /// The mouse's turn (radians: about the vertical axis, then the
    /// horizontal one), and where the drag under way began.
    @ObservationIgnored private var yaw: Float = 0
    @ObservationIgnored private var pitch: Float = 0
    @ObservationIgnored private var turnStart: (yaw: Float, pitch: Float)?
    @ObservationIgnored private var resetTask: Task<Void, Never>?
    /// The viewer's zoom (pinch, scroll): the camera's distance divided by it.
    @ObservationIgnored private var zoomFactor: Float = 1
    /// Turn Around's progress (radians about the vertical axis).
    @ObservationIgnored private var spinAngle: Float = 0
    @ObservationIgnored private var spinTask: Task<Void, Never>?
    /// The device pose's turn about the view axis (radians, counter-clockwise),
    /// and the quarter turns it heads for.
    @ObservationIgnored private var rollAngle: Float = 0
    @ObservationIgnored private var rollTurns = 0
    @ObservationIgnored private var rollTask: Task<Void, Never>?
    /// How far the device is posed as a laptop or a tent (0...1, blended so
    /// the camera moves between poses), the hinge it heads for, and the
    /// blend under way.
    @ObservationIgnored private var laptopWeight: Float = 0
    @ObservationIgnored private var tentWeight: Float = 0
    @ObservationIgnored private var targetOpening: Double = 180
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSession: (session: any MirrorSessionProtocol, panel: SimulatorFoldPanel, turns: (Int, Int) -> Int)?
    @ObservationIgnored private var pendingOpening: Double?
    @ObservationIgnored private var panelTurns: (Int, Int) -> Int = { _, _ in 0 }
    @ObservationIgnored private var modelEntity: ModelEntity?
    @ObservationIgnored private var controller: AnimationPlaybackController?
    @ObservationIgnored private var spec: AppleDeviceModel.Spec?
    /// This load's panel materials (RealityKit numbers them anew each load).
    @ObservationIgnored private var panels: AppleDeviceModel.PanelMaterials?
    /// The flat panels' bounds in the model's space (inner, outer): where a
    /// pointer lands on them is worked out from these and the fold.
    @ObservationIgnored private var panelBounds: (inner: (SIMD3<Float>, SIMD3<Float>), outer: (SIMD3<Float>, SIMD3<Float>))?
    /// The session the lit panel shows, and its last frame's size and turn.
    @ObservationIgnored private var feedingSession: (any MirrorSessionProtocol)?
    @ObservationIgnored private var shownFrame: (width: Int, height: Int, turns: Int)?
    /// What the pointer under way does, and where it last touched.
    @ObservationIgnored private var pointer: PointerUse?
    @ObservationIgnored private var lastTouch: (x: Int32, y: Int32)?
    @ObservationIgnored private var lastTurnClick: Date?

    private enum PointerUse {
        case touch
        case turn
    }

    /// The longest a click's pointer may move, and the longest between the
    /// clicks of a double click.
    static let clickSlop: CGFloat = 3
    static let doubleClickInterval: TimeInterval = 0.4
    @ObservationIgnored private var foldTask: Task<Void, Never>?
    @ObservationIgnored private var readoutTask: Task<Void, Never>?
    @ObservationIgnored private var darkenTask: Task<Void, Never>?
    @ObservationIgnored private var shownTime: Double?
    @ObservationIgnored private let feeder = PanelTextureFeeder()
    @ObservationIgnored private var observation: FrameObservation?
    @ObservationIgnored private var feedingPanel: SimulatorFoldPanel?

    /// How long the hinge takes to reach a slider's new angle on screen.
    static let foldDuration: Double = 0.15
    /// How long the device takes to face the camera again, or to turn to
    /// the way it is held.
    static let turnDuration: Double = 0.35
    /// Degrees past which a hinge change is a preset's, shown as long as the
    /// simulator's sweep.
    static let sweepThreshold: Double = 10
    /// How long Turn Around takes.
    static let spinDuration: Double = 2.2
    /// How long the readout stays once the hinge has stopped.
    static let readoutLinger: Duration = .milliseconds(900)
    /// How long a panel that went dark keeps its blurred last picture.
    static let darkenAfter: Duration = .milliseconds(700)
    /// The open device's width in the view's units (metres).
    static let framedSize: Float = 0.5
    /// The camera's vertical field of view: wide and close, so a half-open
    /// device's hinge reads with depth (at 137° the V at the hinge is 0.048
    /// of the device's height; 35° gave 0.037, 45° 0.045).
    static let fieldOfView: Float = 48
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

    func load(_ model: AppleDeviceModel) async -> Entity? {
        if let root { return root }
        guard let entity = try? await Entity(contentsOf: model.url) else { return nil }
        var found: ModelEntity?
        func find(_ node: Entity) {
            if let candidate = node as? ModelEntity, candidate.components[ModelComponent.self] != nil { found = candidate }
            node.children.forEach(find)
        }
        find(entity)
        guard let found, let animation = entity.availableAnimations.first,
              model.fits(animationDuration: animation.definition.duration),
              var component = found.components[ModelComponent.self]
        else { return nil }
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
        let root = Entity()
        root.addChild(turntable)
        camera.camera.fieldOfViewInDegrees = Self.fieldOfView
        camera.camera.fieldOfViewOrientation = .vertical
        root.addChild(camera)
        // The studio lights the metal and the back; a soft key and fill give
        // the matte back its fall-off.
        for (direction, intensity) in [(SIMD3<Float>(0.4, 0.8, 1), Float(300)), (SIMD3<Float>(-0.8, -0.3, 0.6), Float(100))] {
            let light = DirectionalLight()
            light.light.intensity = intensity
            light.look(at: .zero, from: direction, relativeTo: nil)
            root.addChild(light)
        }
        if let environment = await Self.studioLight() {
            root.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: Self.studioExposure))
            // On the model itself: the receiver is not passed down from the
            // file's root, and polished metal lit by the key alone is black.
            found.components.set(ImageBasedLightReceiverComponent(imageBasedLight: root))
            entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: root))
        }
        feeder.onPresented = { [weak self] in self?.setNeedsRender() }
        self.modelEntity = found
        self.deviceEntity = entity
        self.controller = controller
        self.spec = model.spec
        self.root = root
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

    private func setNeedsRender() {
        onNeedsRender?()
    }

    /// Poses the device for the hinge as shown: placed by the fold's own
    /// geometry, turned by the book turn, the device pose, the mouse and
    /// Turn Around, and the camera backed off until the sphere it turns in
    /// fits the view's shorter field of view.
    private func layout() {
        defer { setNeedsRender() }
        guard let deviceEntity, deviceSize.x > 0 else { return }
        let framing = AppleDeviceModel.framing(
            opening: shownOpening, width: deviceSize.x, height: deviceSize.z, thickness: deviceSize.y
        )
        deviceEntity.position = openCenter - SIMD3(framing.center.x, framing.center.y, 0)
        let book = simd_quatf(angle: framing.bookTurn, axis: [0, 1, 0])
        let roll = simd_quatf(angle: rollAngle, axis: [0, 0, 1])
        // On its side the hinge runs across the view: a laptop tips about it
        // until its lower half lies flat, seen from a little above; a tent
        // stands on both edges, the hinge on top, turned to show its outer
        // panel.
        let fold = Float((180 - shownOpening) * .pi / 180)
        let laptopTilt = fold / 2 - .pi / 2 + Self.laptopElevation
        let tentTilt = Float.pi / 2 + Self.tentElevation
        var tentTurn = Self.tentTurn
        if tentWeight > 0 {
            // The outer panel's normal on the half that folds over, in the
            // stand's frame turned into the turntable's.
            let outer = (simd_quatf(angle: tentTilt, axis: [1, 0, 0]) * roll * book).act([-sin(fold), 0, -cos(fold)])
            if outer.z < 0 { tentTurn += .pi }
        }
        let tilt = laptopWeight * laptopTilt + tentWeight * tentTilt
        let holdTurn = laptopWeight * Self.laptopTurn + tentWeight * tentTurn
        turntable.orientation = simd_quatf(angle: pitch, axis: [1, 0, 0])
            * simd_quatf(angle: yaw + spinAngle + holdTurn, axis: [0, 1, 0])
            * simd_quatf(angle: tilt, axis: [1, 0, 0])
            * roll
            * book
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        let vertical = Self.fieldOfView * .pi / 180 / 2
        let horizontal = atan(Float(viewSize.width / viewSize.height) * tan(vertical))
        // Tight while the device faces the camera; the whole sphere it turns
        // in as it turns away (an edge-on device's corners reach the sphere).
        let turnedAway = max(abs(sin(yaw + spinAngle)), abs(sin(pitch)))
        let fit = Self.fit + (1 - Self.fit) * turnedAway
        camera.position = [0, 0, framing.radius * fit / sin(min(vertical, horizontal)) / zoomFactor]
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
        guard factor.isFinite, factor > 0 else { return }
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
        guard root != nil, spinTask == nil else { return }
        if MotionMetrics.reduceMotion {
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
        let target = Float(turns) * .pi / 2
        let from = rollAngle
        let delta = remainder(target - from, 2 * .pi)
        rollTask?.cancel()
        guard root != nil, abs(delta) > 0.001 else {
            rollAngle = target
            layout()
            return
        }
        rollTask = animate(over: Self.turnDuration) { [weak self] eased in
            self?.rollAngle = from + delta * eased
            self?.layout()
        }
    }

    /// Poses the device as a laptop (on its side, half open, the inner panel
    /// lit) or a tent (the outer panel lit), or as a book otherwise; the
    /// camera moves there.
    private func updateHold() {
        let sideways = rollTurns % 2 != 0
        let halfOpen = targetOpening > 10 && targetOpening < 170
        let laptop: Float = sideways && halfOpen && feedingPanel == .inner ? 1 : 0
        let tent: Float = sideways && halfOpen && feedingPanel == .outer ? 1 : 0
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
        targetOpening = degrees
        updateHold()
        guard let spec, let controller else {
            pendingOpening = degrees
            return
        }
        let target = spec.animationTime(forOpening: degrees)
        let start = shownTime ?? target
        foldTask?.cancel()
        guard abs(target - start) > 0.001 else {
            apply(time: target, controller: controller)
            return
        }
        resetTurn(zoom: true)
        readoutTask?.cancel()
        // A preset (a large change) moves as long as the simulator's hinge
        // sweeps; the slider's small steps follow at once.
        let sweep = abs(target - start) / abs(spec.closedTime - spec.openTime) * 180 > Self.sweepThreshold
        foldTask = animate(over: sweep ? SimulatorFold.sweepDuration : Self.foldDuration, easingOut: true) { [weak self] eased in
            guard let self else { return }
            self.apply(time: start + (target - start) * Double(eased), controller: controller)
            self.readout = Int(self.shownOpening.rounded())
        } done: { [weak self] in
            self?.readoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.readoutLinger)
                guard !Task.isCancelled else { return }
                self?.readout = nil
            }
        }
    }

    /// Shows the hinge at animation `time`.
    private func apply(time: Double, controller: AnimationPlaybackController) {
        controller.time = time
        shownTime = time
        guard let spec, spec.closedTime != spec.openTime else { return }
        let closedness = min(max((time - spec.openTime) / (spec.closedTime - spec.openTime), 0), 1)
        shownOpening = 180 * (1 - closedness)
        layout()
    }

    /// Runs `step` with the eased progress (0...1) about every frame for
    /// `duration` seconds, then `done`; at once with Reduce Motion on.
    private func animate(
        over duration: Double,
        easingOut: Bool = false,
        _ step: @escaping @MainActor (Float) -> Void,
        done: (@MainActor () -> Void)? = nil
    ) -> Task<Void, Never> {
        let duration = MotionMetrics.reduceMotion ? 0 : duration
        return Task { @MainActor in
            let began = Date()
            while !Task.isCancelled {
                let progress = duration > 0 ? Float(min(Date().timeIntervalSince(began) / duration, 1)) : 1
                // Easing out as the simulator's hinge sweeps
                // (`SimulatorFold.sweepAngles`), else in and out.
                step(easingOut ? 1 - pow(1 - progress, 3) : progress * progress * (3 - 2 * progress))
                if progress >= 1 {
                    done?()
                    break
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    // MARK: - Pointer

    /// Sends a key to the lit panel's session; false without one.
    func sendKey(_ command: KeyboardCommand) -> Bool {
        guard let feedingSession else { return false }
        feedingSession.send(command)
        return true
    }

    func pointerMoved(from start: CGPoint, to location: CGPoint, translation: CGSize) {
        if pointer == nil {
            if let point = framePoint(at: start), let session = feedingSession {
                pointer = .touch
                lastTouch = point
                session.send(TouchCommand(phase: .down, x: point.x, y: point.y))
            } else {
                pointer = .turn
            }
        }
        switch pointer {
        case .touch:
            // Off the panel the touch stays where it left it.
            guard let point = framePoint(at: location) ?? lastTouch, let session = feedingSession else { return }
            lastTouch = point
            session.send(TouchCommand(phase: .move, x: point.x, y: point.y))
        case .turn:
            if hypot(translation.width, translation.height) >= Self.clickSlop { turn(by: translation) }
        case nil:
            break
        }
    }

    func pointerEnded(at location: CGPoint, translation: CGSize) {
        defer { pointer = nil }
        switch pointer {
        case .touch:
            guard let point = framePoint(at: location) ?? lastTouch, let session = feedingSession else { return }
            session.send(TouchCommand(phase: .up, x: point.x, y: point.y))
            lastTouch = nil
        case .turn:
            endTurn()
            guard hypot(translation.width, translation.height) < Self.clickSlop else { return }
            if let last = lastTurnClick, Date().timeIntervalSince(last) < Self.doubleClickInterval {
                lastTurnClick = nil
                resetTurn(zoom: true)
            } else {
                lastTurnClick = Date()
            }
        case nil:
            break
        }
    }

    /// The pixel of the lit panel's frame under `location` (view points),
    /// nil off the panel or behind it: the camera's ray through the point
    /// against the panel as folded (the half that stays flat, the other
    /// turned about the hinge by the fold), in the model's own space carried
    /// to the view's by its entity, so turns, poses and the fold all count.
    func framePoint(at location: CGPoint) -> (x: Int32, y: Int32)? {
        guard let model = modelEntity, let bounds = panelBounds, let panel = feedingPanel, let frame = shownFrame,
              viewSize.width > 0, viewSize.height > 0
        else { return nil }
        let tanHalf = tan(Self.fieldOfView * .pi / 180 / 2)
        let aspect = Float(viewSize.width / viewSize.height)
        let ndc = SIMD2<Float>(Float(location.x / viewSize.width) * 2 - 1, 1 - Float(location.y / viewSize.height) * 2)
        let origin = camera.position(relativeTo: nil)
        let direction = simd_normalize(camera.convert(direction: [ndc.x * tanHalf * aspect, ndc.y * tanHalf, -1], to: nil))

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

    /// Feeds `session`'s frames to `panel`. The panel that was lit
    /// keeps its last picture, blurred, while the device folds, then goes
    /// dark; on the first session the other panel is dark at once.
    func show(session: any MirrorSessionProtocol, on panel: SimulatorFoldPanel, turns: @escaping (Int, Int) -> Int) {
        guard modelEntity != nil else {
            pendingSession = (session, panel, turns)
            return
        }
        pendingSession = nil
        observation = nil
        let previous = feedingPanel
        feedingPanel = panel
        feedingSession = session
        shownFrame = nil
        panelTurns = turns
        updateHold()
        let other: SimulatorFoldPanel = panel == .inner ? .outer : .inner
        // The lit panel and the session change together (the session follows
        // the fold): the second call leaves the other panel's blur running.
        if previous == panel {
            // Nothing to dim.
        } else if previous == other, feeder.blurLast(on: other) {
            darkenTask?.cancel()
            darkenTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.darkenAfter)
                guard !Task.isCancelled, self?.feedingPanel != other else { return }
                self?.darken(other)
            }
        } else {
            darkenTask?.cancel()
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

    private func darken(_ panel: SimulatorFoldPanel) {
        guard let modelEntity, let panels, var component = modelEntity.components[ModelComponent.self] else { return }
        component.materials[panel == .inner ? panels.inner : panels.outer] = UnlitMaterial(color: .black)
        modelEntity.components.set(component)
        feeder.forget(panel)
        setNeedsRender()
    }

    func stopFeeding() {
        if pointer == .touch, let point = lastTouch {
            feedingSession?.send(TouchCommand(phase: .up, x: point.x, y: point.y))
        }
        pointer = nil
        lastTouch = nil
        observation = nil
        for task in [foldTask, resetTask, rollTask, spinTask, readoutTask, darkenTask, holdTask] { task?.cancel() }
        spinTask = nil
    }

    private func frameArrived(_ frames: FrameStore) {
        // A callback queued before the session changed.
        guard frames === feedingSession?.frames else { return }
        guard let frame = frames.current, let buffer = frame.pixelBuffer,
              let panel = feedingPanel, let panels, let modelEntity
        else { return }
        let index = panel == .inner ? panels.inner : panels.outer
        let turns = ((panelTurns(frame.width, frame.height) % 4) + 4) % 4
        shownFrame = (frame.width, frame.height, turns)
        let size = turns % 2 == 1 ? (frame.height, frame.width) : (frame.width, frame.height)
        guard let texture = feeder.texture(for: panel, width: size.0, height: size.1) else { return }
        if feeder.needsMaterial(panel), var component = modelEntity.components[ModelComponent.self] {
            var material = UnlitMaterial()
            material.color = .init(texture: .init(texture))
            component.materials[index] = material
            modelEntity.components.set(component)
            feeder.markMaterialSet(panel)
        }
        feeder.copy(buffer, to: panel, turns: turns)
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
    var onPresented: (@MainActor () -> Void)? {
        didSet {
            renderer.setPresented { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onPresented?() } }
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
    func markMaterialSet(_ panel: SimulatorFoldPanel) { materialSet.insert(panel) }

    /// Draws `panel`'s last picture again, blurred; false when it has none.
    func blurLast(on panel: SimulatorFoldPanel) -> Bool {
        guard let picture = last[panel] else { return false }
        return copy(picture.buffer, to: panel, turns: picture.turns, blur: Self.blurStep)
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
        let buffer: CVPixelBuffer
        let queue: TextureResource.DrawableQueue
        let turns: Int
        let blur: Float
    }

    private let device = MTLCreateSystemDefaultDevice()
    private let commandQueue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private var cache: CVMetalTextureCache?
    private let queue = DispatchQueue(label: "com.devicehubpro.device-model.panels", qos: .userInteractive)
    /// Runs on the drawing queue after each frame reached its texture.
    private let presented = Mutex<(@Sendable () -> Void)?>(nil)
    private let state = Mutex<(waiting: [SimulatorFoldPanel: Job], drawing: Set<SimulatorFoldPanel>)>(([:], []))

    func setPresented(_ handler: @escaping @Sendable () -> Void) {
        presented.withLock { $0 = handler }
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
        let start = state.withLock { state -> Bool in
            state.waiting[panel] = job
            return state.drawing.insert(panel).inserted
        }
        if start { queue.async { [self] in drain(panel) } }
    }

    /// Drops `panel`'s waiting job (the panel went dark).
    func drop(_ panel: SimulatorFoldPanel) {
        state.withLock { _ = $0.waiting.removeValue(forKey: panel) }
    }

    private func drain(_ panel: SimulatorFoldPanel) {
        while let job = state.withLock({ state -> Job? in
            guard let job = state.waiting.removeValue(forKey: panel) else {
                state.drawing.remove(panel)
                return nil
            }
            return job
        }) {
            draw(job)
        }
    }

    /// One frame into the job's next drawable. A drawable not handed out in
    /// time (RealityKit took none since) drops the frame.
    private func draw(_ job: Job) {
        guard let commandQueue, let pipeline, let cache,
              CVPixelBufferGetPixelFormatType(job.buffer) == kCVPixelFormatType_32BGRA,
              let drawable = try? job.queue.nextDrawable()
        else { return }
        // Lets go of the textures of buffers nobody holds any more, as the
        // 2D renderer does (`MirrorRenderer.wrap`).
        CVMetalTextureCacheFlush(cache, 0)
        let width = CVPixelBufferGetWidth(job.buffer), height = CVPixelBufferGetHeight(job.buffer)
        var wrapped: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, job.buffer, nil, .bgra8Unorm_srgb, width, height, 0, &wrapped)
        guard let wrapped, let source = CVMetalTextureGetTexture(wrapped),
              let commands = commandQueue.makeCommandBuffer()
        else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
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
        presented.withLock { $0 }?()
    }
}
