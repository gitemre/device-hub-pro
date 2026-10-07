import AppKit
import MetalKit
import SwiftUI
import DeviceHubProKit

/// The live mirror surface. Shows why the renderer could not be built
/// instead of a blank stage when the shared Metal pipeline failed.
struct MirrorView: View {
    let session: any MirrorSessionProtocol
    let state: MirrorViewState
    var margin: Double = 0.96
    /// Fill the view's drawable exactly (framed, vector and thin-bezel
    /// views) instead of capping at native size and centering with black
    /// around it.
    var allowsUpscaling: Bool = false
    /// Whether Mac key events are forwarded to the device (Device Hub's
    /// hardware-keyboard simulation mode).
    var forwardsKeyboard: Bool = true
    /// Clips the video to a rounded rect (points): the screen corner
    /// `ScreenCornerPolicy` decides (the device's own, capped at the skin's
    /// opening). Applied on the view's layer because SwiftUI clip modifiers
    /// are not reliably honored by AppKit representables.
    var cornerRadius: Double = 0
    /// The corner's curve: circular for Android (its skins' and panels'
    /// arcs), continuous for a simulator in its Apple chrome, whose screen
    /// outline is Apple's continuous corner (`AppleChromeDeviceView`).
    var cornerCurve: CALayerCornerCurve = .circular
    /// The camera cutout the host draws over the video, filled black: view
    /// points, top-left based, in the upright screen as shown
    /// (`PlacedComposition.cutoutPath(inVideoRect:)`); nil draws none. Only
    /// the vector body passes one.
    var cutout: CGPath?
    /// Makes the Metal surface's uncovered area (letterbox slack and any
    /// bounds overshoot of the AppKit view) transparent instead of opaque
    /// black. The framed mirror needs this: the skin artwork is transparent
    /// outside the device silhouette, so opaque black would show as patches.
    var backgroundIsTransparent: Bool = false
    /// Whether the streamed buffer is composed for the device's physical pose
    /// and must be sampled upright (framed, vector and thin-bezel paths).
    /// The flat path keeps `false` and displays the buffer exactly as
    /// streamed.
    ///
    /// The sampling rotation itself comes from the frame that is actually
    /// uploaded (its own `rotation` metadata), never from SwiftUI state: the
    /// state lags the stream by an update cycle, which showed as a frame or
    /// two of sideways content at every rotation settle.
    var uprightsTexture: Bool = false
    /// With `uprightsTexture`, the quarter turns a frame of (width, height)
    /// pixels is sampled upright by, in place of its `rotation`: a
    /// simulator's frames are posed by its interface with `rotation` 0, and
    /// its Apple chrome shows the native panel turned with the device
    /// (`AppleChromePose.contentTurns`). Asked on every draw, for the frame
    /// being drawn.
    var textureTurns: ((Int, Int) -> Int)?

    /// Publishes the drawn scale to `state.videoPointsPerPixel` (the main
    /// stage only): the stage zoom measures its steps and the physical size
    /// against it.
    @Environment(\.reportsStageScale) private var reportsStageScale

    /// Draws the screen black over the stream (`blanksMirror`).
    @Environment(\.blanksMirror) private var blanksMirror

    /// Reads the device's display density for input (absent in previews).
    @Environment(DeviceWorkspace.self) var workspace: DeviceWorkspace?

    private struct FramePauseKey: Equatable {
        let session: ObjectIdentifier
        let wanted: Bool
    }

    var body: some View {
        let pipeline = MirrorRenderPipeline.shared
        if let failure = pipeline.failure {
            ContentUnavailableView {
                Label("Can't Show the Mirror", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            }
        } else {
            MirrorSurface(
                mirror: self,
                isPipelineReady: pipeline.resources != nil,
                isWindowVisible: workspace?.window.isStageVisible ?? true,
                reportsScale: reportsStageScale,
                seed: Self.seed(of: workspace?.mirror, for: session)
            )
                // Once per session, and again when the stream changes shape
                // (a foldable switching screens).
                .task(id: DisplayMetricsRequest(state: ObjectIdentifier(state), frame: state.devicePixelSize)) {
                    await workspace?.mirror.loadMirrorDisplayMetrics(for: state)
                }
                // A stage nobody sees (and nothing records) stops building
                // frames; showing it again repaints from a fresh screenshot.
                .task(id: FramePauseKey(
                    session: ObjectIdentifier(session),
                    wanted: (workspace?.window.isStageVisible ?? true) || (workspace?.media.isRecording ?? false)
                )) {
                    let wasPaused = session.frames.isPaused
                    session.frames.isPaused = !((workspace?.window.isStageVisible ?? true)
                        || (workspace?.media.isRecording ?? false))
                    if wasPaused, !session.frames.isPaused { await session.resync() }
                }
                // The screen's corners and cutout, on the same schedule; a
                // task of its own so neither read waits for the other.
                .task(id: DisplayMetricsRequest(state: ObjectIdentifier(state), frame: state.devicePixelSize)) {
                    await workspace?.mirror.loadDisplayShapes(for: state)
                }
                .overlay {
                    if blanksMirror {
                        RoundedRectangle(
                            cornerRadius: cornerRadius,
                            style: cornerCurve == .continuous ? .continuous : .circular
                        )
                        .fill(.black)
                        .allowsHitTesting(false)
                    }
                }
        }
    }

    /// The picture remembered for the device this mirror session shows, drawn until
    /// its first frame; nil for a session that is not the workspace's.
    static func seed(of mirror: MirrorController?, for session: any MirrorSessionProtocol) -> RememberedPicture? {
        guard let mirror, mirror.session === session else { return nil }
        return mirror.seedPicture
    }

    private struct DisplayMetricsRequest: Equatable {
        let state: ObjectIdentifier
        let frame: CGSize?
    }
}

/// The AppKit side of `MirrorView`.
private struct MirrorSurface: NSViewRepresentable {
    let mirror: MirrorView
    /// Part of the representable's value so the view redraws once the shared
    /// pipeline finished building.
    let isPipelineReady: Bool
    /// Whether the hosting window is on screen: while
    /// false, a new frame's arrival stops scheduling draws.
    let isWindowVisible: Bool
    /// Whether this surface answers for the stage's scale.
    let reportsScale: Bool
    /// The remembered picture to draw before the first frame.
    var seed: RememberedPicture?

    func makeNSView(context: Context) -> MirrorMetalView {
        let view = MirrorMetalView(frame: .zero, device: MirrorRenderPipeline.systemDevice)
        configure(view)
        return view
    }

    func updateNSView(_ nsView: MirrorMetalView, context: Context) {
        configure(nsView)
    }

    static func dismantleNSView(_ nsView: MirrorMetalView, coordinator: ()) {
        // A finger still down (or waiting for its lift) must reach the
        // session it went down on while `onContacts` still targets it.
        nsView.liftAllContacts()
        nsView.frames = nil
        nsView.onContacts = nil
        nsView.onKey = nil
        nsView.onEscapeWithoutCapture = nil
        nsView.onPhysicalKey = nil
        nsView.sendsPhysicalKeys = nil
        nsView.pointerInput = nil
    }

    private func configure(_ view: MirrorMetalView) {
        view.isWindowVisible = isWindowVisible
        let session = mirror.session
        view.frames = session.frames
        view.state = mirror.state
        view.presentationMargin = mirror.margin
        view.allowsUpscaling = mirror.allowsUpscaling
        view.keyboardForwardingEnabled = mirror.forwardsKeyboard
        view.uprightsTexture = mirror.uprightsTexture
        view.textureTurns = mirror.textureTurns
        view.onContacts = { contacts in session.send(contacts: contacts) }
        // A TV takes the arrows, Return and Escape as remote buttons.
        let workspace = mirror.workspace
        view.onKey = { [weak workspace] command in
            if workspace?.forwardKeyToRemote(command) == true { return }
            session.send(command)
        }
        view.onEscapeWithoutCapture = { [weak workspace] in
            guard let window = workspace?.window, window.isLogFocus else { return false }
            window.exitLogFocus()
            return true
        }
        view.onPhysicalKey = { event in session.send(physical: event) }
        view.sendsPhysicalKeys = { session.acceptsPhysicalKeys }
        view.pointerInput = session as? any MirrorPointerInput
        view.layer?.cornerRadius = CGFloat(mirror.cornerRadius)
        // Android skins use circular corner arcs, not Apple's squircle.
        view.layer?.cornerCurve = mirror.cornerCurve
        view.layer?.masksToBounds = mirror.cornerRadius > 0
        view.cutout = mirror.cutout
        view.reportsScale = reportsScale
        view.seedPicture = seed
        view.setBackgroundTransparent(mirror.backgroundIsTransparent)
        if isPipelineReady {
            view.pipelineDidLoad()
        }
    }
}

/// Metal-backed mirror view. Draws on demand — when a new frame is ready, the
/// layout or backing changes, or a presentation property changes — instead
/// of running a 60 Hz loop that acquired a drawable on every vsync even for
/// a static screen. Mouse events are forwarded to the device as touches.
final class MirrorMetalView: MTKView {
    /// The session's frames. Swapping in another store (the compact window
    /// keeps its view across a session switch) drops everything derived
    /// from the old stream and clears the surface.
    ///
    /// It also lifts every contact still down: `configure` assigns the
    /// store before `onContacts`, so the lifts still reach the old session,
    /// and the new one never gets an `.up` without its `.down`.
    var frames: FrameStore? {
        didSet {
            guard frames !== oldValue else { return }
            liftAllContacts()
            frameObservation = nil
            geometry = SettledGeometry()
            lastObservedGeneration = 0
            presentedLayout = nil
            needsClear = true
            hasPresentedFrame = false
            seededPictureID = nil
            refreshBackground()
            uploader?.attach(frames)
            if let frames, let uploader {
                frameObservation = frames.observe { [weak uploader, visibility] in
                    // Occlusion gating: a hidden window's
                    // stream stops the per-frame work (texture upload, the
                    // Metal draw) at its source, instead of doing the work
                    // and discarding the result. This runs on the stream's
                    // own delivery thread (`FrameStore.observe`), never the
                    // main one, so it reads the flag through `visibility`
                    // and touches nothing else on the view.
                    guard visibility.isVisible else { return }
                    uploader?.frameArrived()
                }
            }
            applySeed()
            needsDisplay = true
        }
    }
    /// A picture remembered for the device (`LastPictureCache`), drawn until
    /// the stream's first frame is: the stage never shows an empty screen
    /// for a device it showed before. Dropped for good once a frame of the
    /// stream has been drawn.
    var seedPicture: RememberedPicture? {
        didSet { applySeed() }
    }
    /// The seed already handed to the uploader for the current store.
    private var seededPictureID: UInt64?

    private func applySeed() {
        guard let seed = seedPicture, !hasPresentedFrame, frames != nil,
              seededPictureID != seed.id
        else { return }
        seededPictureID = seed.id
        uploader?.seed(seed.frame, fullSize: seed.fullSize)
    }
    /// Whether the hosting window is on screen (set by
    /// `MirrorSurface.configure`): while false, a new frame's arrival does
    /// not upload a texture or schedule a draw — the per-frame work stops
    /// for a window nobody can see. Becoming visible again re-asks the
    /// uploader for the latest frame, catching the surface up to what
    /// streamed while it was hidden. A user-driven change (posing, a new
    /// session, a cutout edit) still requests a draw immediately regardless
    /// — those already happen once per real edit, never per streamed frame.
    var isWindowVisible = true {
        didSet {
            guard isWindowVisible != oldValue else { return }
            visibility.isVisible = isWindowVisible
            guard isWindowVisible else { return }
            uploader?.frameArrived()
            // Redraw the retained texture at once: when no new frame
            // arrives (a screen that only changes now and then), the
            // surface must not wait for one to show the picture again.
            needsDisplay = true
        }
    }
    /// `isWindowVisible` as the frame observer can read it: that closure
    /// runs on the stream's delivery thread, where neither this view nor
    /// its stored properties may be touched.
    private let visibility = FrameObserverVisibility()
    var onContacts: (([TouchCommand]) -> Void)?
    var onKey: ((KeyboardCommand) -> Void)?
    /// Physical keys (a physical iPhone with fast input): when `sendsPhysicalKeys` says yes,
    /// Mac keys go here as the same physical key instead of `onKey`'s text.
    var onPhysicalKey: ((PhysicalKeyEvent) -> Void)?
    var sendsPhysicalKeys: (() -> Bool)?
    private var resignObserver: NSObjectProtocol?
    /// Wheel and Back input for sessions that take real mouse events.
    var pointerInput: (any MirrorPointerInput)?
    var state = MirrorViewState()
    var presentationMargin: Double = 0.96 {
        didSet { if presentationMargin != oldValue { needsDisplay = true } }
    }
    /// Whether the image fills the view (framed, vector and thin-bezel
    /// surfaces) instead of being capped at one frame pixel per point.
    ///
    /// A filling surface is always laid out at the video's own aspect, so
    /// the image scales with its bounds, and the layer scales the last frame
    /// to new bounds until the next draw: that is where the next frame
    /// lands. As a turn starts the stage lays the device out at the new rest
    /// pose's size while the pose wrapper's scale keeps it the same size on
    /// screen; left unscaled, the old frame of a phone in the default window
    /// would show at 0.66x (turning to landscape) or 1.51x (back) for that
    /// moment.
    var allowsUpscaling = false {
        didSet {
            guard allowsUpscaling != oldValue else { return }
            layer?.contentsGravity = allowsUpscaling ? .resize : .center
            needsDisplay = true
        }
    }
    /// Whether the uploaded texture must be sampled upright (see
    /// `MirrorView.uprightsTexture`).
    var uprightsTexture = false {
        didSet { if uprightsTexture != oldValue { needsDisplay = true } }
    }
    /// See `MirrorView.textureTurns`. A closure never compares equal, so
    /// setting it asks for no draw: what it answers changes with the frames,
    /// which draw anyway.
    var textureTurns: ((Int, Int) -> Int)?
    /// Gates keyboard forwarding; toggled by the toolbar's keyboard button.
    var keyboardForwardingEnabled = true
    static let escapeKeyCode: UInt16 = 53
    /// Called for a bare Esc while the keyboard is not forwarded; true when it
    /// was used (leaving Log Focus).
    var onEscapeWithoutCapture: (() -> Bool)?
    /// The camera cutout filled black over the video (`MirrorView.cutout`):
    /// view points, top-left based; nil draws none.
    ///
    /// Drawn by a black `CAShapeLayer` sublayer of the view's own layer, the
    /// mechanism of the corner clip: it is composited with the video by Core
    /// Animation and clipped by the same corner, with no offscreen pass (a
    /// `layer.mask` would cost one on every frame). The view is unflipped, so
    /// its layer's y grows up and the outline is flipped into it. Clicks on
    /// the hole still reach the device.
    var cutout: CGPath? {
        didSet {
            guard cutout != oldValue else { return }
            updateCutoutLayer()
        }
    }
    /// The layer `cutout` is drawn with; nil while there is none.
    private(set) var cutoutLayer: CAShapeLayer?

    private let inputControl = MirrorInputController()
    private var uploader: MirrorFrameUploader?
    private var frameObservation: FrameObservation?
    private var geometry = SettledGeometry()
    private var lastObservedGeneration: UInt64 = 0
    /// The layout of the last presented draw: input maps through exactly
    /// what is on screen.
    var presentedLayout: MirrorLayout?
    /// Whether this view answers for the stage's scale (`MirrorView`'s
    /// `reportsStageScale`).
    var reportsScale = false
    /// Set when the surface must be cleared because the stream it showed is
    /// gone and the new one has no frame yet.
    private var needsClear = false
    private var isBackgroundTransparent = false
    private var hasPipeline = false
    /// Whether a frame of the current stream has been drawn. Until one is,
    /// the surface shows `placeholderColor` instead of pure black, so a
    /// session that is still starting does not flash a black screen.
    private(set) var hasPresentedFrame = false
    /// Whether the last draw showed a remembered picture, not a frame.
    private(set) var presentedSeed = false

    /// The surface's color while a stream has no frame yet: a very dark
    /// gray, the stage's off-screen tone.
    static let placeholderColor = (red: 0.09, green: 0.09, blue: 0.10)

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        configure()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        colorPixelFormat = MirrorRenderPipeline.colorPixelFormat
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        // On-demand drawing: `needsDisplay` schedules one draw.
        isPaused = true
        enableSetNeedsDisplay = true
        // `syncDrawableSize` sizes the drawable (and the layer's contents
        // scale) from the bounds. MTKView's own resizing converts the size to
        // backing pixels through every ancestor's transform, so while the
        // stage's pose wrapper turned the view it reallocated the drawable on
        // every animation frame (30 sizes in one turn, down to 5x1661 px for
        // a 375x834 pt view) and left it transposed (2520x1133 px) at rest
        // in landscape until the next frame was drawn.
        autoResizeDrawable = false
        layer?.isOpaque = true
        // Until the next draw lands, a resized layer still shows the last
        // presented frame. The capped (flat) mirror keeps it unscaled: its
        // image does not grow with the view, so scaling it would stretch it
        // during sidebar toggles and window resizes. An upscaling surface
        // scales it instead (`allowsUpscaling`).
        layer?.contentsGravity = .center

        if let device {
            uploader = MirrorFrameUploader(device: device) { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.needsDisplay = true }
                }
            }
        } else {
            Self.log("no Metal device available")
        }

        inputControl.logicalPoint = { [weak self] location in
            self?.devicePoint(at: location)
        }
        inputControl.frameSize = { [weak self] in
            guard let layout = self?.presentedLayout else { return nil }
            return CGSize(width: layout.posedWidth, height: layout.posedHeight)
        }
        inputControl.pointsPerFramePixel = { [weak self] in
            self?.presentedLayout?.pointsPerFramePixel
        }
        inputControl.reportedPixelsPerDp = { [weak self] frame in
            self?.state.displayMetrics?.pixelsPerDp(frame: frame)
        }
        inputControl.sendContacts = { [weak self] contacts in
            self?.onContacts?(contacts)
        }
        inputControl.pointerInput = { [weak self] in
            self?.pointerInput
        }
    }

    /// The shared pipeline is built: draw what is waiting, once (SwiftUI
    /// reports readiness on every later update too).
    func pipelineDidLoad() {
        guard !hasPipeline else { return }
        hasPipeline = true
        needsDisplay = true
    }

    /// Clears or restores the opaque surface behind the video. Transparent
    /// is for the framed mirror, where the skin artwork is transparent
    /// outside the device silhouette.
    func setBackgroundTransparent(_ transparent: Bool) {
        guard transparent != isBackgroundTransparent || layer?.backgroundColor == nil else { return }
        isBackgroundTransparent = transparent
        layer?.isOpaque = !transparent
        refreshBackground()
        needsDisplay = true
    }

    /// Sets the clear color and the layer's background from the transparency
    /// and whether the stream has drawn a frame yet.
    private func refreshBackground() {
        let color: (red: Double, green: Double, blue: Double, alpha: Double)
        if isBackgroundTransparent {
            color = (0, 0, 0, 0)
        } else if hasPresentedFrame {
            color = (0, 0, 0, 1)
        } else {
            let placeholder = Self.placeholderColor
            color = (placeholder.red, placeholder.green, placeholder.blue, 1)
        }
        clearColor = MTLClearColorMake(color.red, color.green, color.blue, color.alpha)
        layer?.backgroundColor = CGColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    override func layout() {
        super.layout()
        syncDrawableSize()
        updateCutoutLayer()
        needsDisplay = true
    }

    /// A new size (the stage's layout for a new pose, a window resize) gets
    /// its drawable and a draw at once, whether or not a layout pass follows.
    override func setFrameSize(_ newSize: NSSize) {
        let old = bounds.size
        super.setFrameSize(newSize)
        guard bounds.size != old else { return }
        syncDrawableSize()
        updateCutoutLayer()
        needsDisplay = true
    }

    /// Puts `cutout` on its sublayer: the layer fills the bounds and holds
    /// the outline flipped into the layer's y-up space (y′ = height − y).
    /// Removed when there is no cutout. Without implicit animations: the
    /// hole must move with the video in the same frame, not ease after it.
    private func updateCutoutLayer() {
        guard let cutout, let layer else {
            cutoutLayer?.removeFromSuperlayer()
            cutoutLayer = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let shape: CAShapeLayer
        if let existing = cutoutLayer {
            shape = existing
        } else {
            shape = CAShapeLayer()
            shape.fillColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            shape.strokeColor = nil
            layer.addSublayer(shape)
            cutoutLayer = shape
        }
        shape.frame = layer.bounds
        shape.contentsScale = window?.backingScaleFactor ?? layer.contentsScale
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
        shape.path = cutout.copy(using: &flip)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawableSize()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A key held while the window loses the keyboard never sends its key-up here.
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = window.map {
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: $0, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onPhysicalKey?(.releaseAll) }
            }
        }
        syncDrawableSize()
        needsDisplay = true
    }

    /// Sizes the drawable to the bounds in backing pixels, the one place it
    /// is sized (`autoResizeDrawable` is off). Called on every bounds or
    /// backing change and before each draw: a static stream sends no frames
    /// to trigger another draw, so a wrong-sized drawable would stay on
    /// screen.
    ///
    /// The layer's contents scale is set with it: MTKView keeps it only
    /// while it resizes the drawable itself, and the flat mirror's layer
    /// shows the drawable unscaled (`contentsGravity` center), at its pixel
    /// size over that scale. Sized so, the drawable is one pixel per backing
    /// pixel under either gravity.
    private func syncDrawableSize() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        if let layer, layer.contentsScale != scale {
            layer.contentsScale = scale
        }
        // The cutout is rasterized at its own scale: kept at the backing's,
        // or its arc would be drawn at 1x and scaled up on a Retina display.
        if let cutoutLayer, cutoutLayer.contentsScale != scale {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cutoutLayer.contentsScale = scale
            CATransaction.commit()
        }
        let expected = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if drawableSize != expected {
            drawableSize = expected
        }
    }

    override func draw(_ rect: CGRect) {
        syncDrawableSize()
        guard let resources = MirrorRenderPipeline.shared.resources else { return }
        guard let uploader, let frame = uploader.acquire() else {
            if needsClear {
                clearSurface(resources)
            }
            return
        }
        var committed = false
        defer {
            if !committed { uploader.release(frame) }
        }
        if !frame.isSeed, !hasPresentedFrame {
            hasPresentedFrame = true
            refreshBackground()
        }

        // A remembered picture is not the stream: it does not settle the
        // stream's geometry.
        if !frame.isSeed, frame.generation != lastObservedGeneration {
            lastObservedGeneration = frame.generation
            // The settled geometry flips only once a size/rotation repeats,
            // so a lone transitional frame never resizes the layout — while
            // landscape-native poses (an opened foldable) still track.
            if geometry.observe(width: frame.width, height: frame.height, rotation: frame.rotation) {
                state.devicePixelSize = geometry.size
                state.deviceRotation = geometry.rotation
                // The stage's pose animator rebases its texture uprighting in
                // the same frame as the layout swap.
                state.onSettledGeometry?(geometry.rotation)
            }
        }

        // The view's bounds are the upright (native) screen rect when the
        // texture is uprighted, so the fit uses the upright dimensions and
        // the shader rotates the posed texture. Responsive, aspect-correct:
        // recomputed on every draw, so dragging panels or resizing the window
        // scales the mirror smoothly and it is never stretched.
        guard
            let layout = MirrorLayout(
                posedWidth: frame.layoutWidth,
                posedHeight: frame.layoutHeight,
                rotation: uprightsTexture ? (textureTurns?(frame.layoutWidth, frame.layoutHeight) ?? frame.rotation) : 0,
                margin: presentationMargin,
                allowsUpscaling: allowsUpscaling,
                viewSize: bounds.size,
                drawableSize: drawableSize
            ),
            let descriptor = currentRenderPassDescriptor,
            let drawable = currentDrawable,
            let commandBuffer = resources.commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            return
        }

        let viewport = layout.drawableViewport
        encoder.setViewport(MTLViewport(
            originX: viewport.x,
            originY: viewport.y,
            width: viewport.width,
            height: viewport.height,
            znear: 0.0,
            zfar: 1.0
        ))
        encoder.setRenderPipelineState(resources.pipeline)
        encoder.setFragmentTexture(frame.texture, index: 0)
        encoder.setFragmentSamplerState(resources.sampler, index: 0)
        var rotationUniform = Int32(layout.rotation)
        encoder.setFragmentBytes(&rotationUniform, length: MemoryLayout<Int32>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { [weak uploader] _ in
            uploader?.release(frame)
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        committed = true
        presentedLayout = layout
        presentedSeed = frame.isSeed
        needsClear = false
        // A remembered picture publishes its scale too, so the opening zoom
        // (`WindowState.resolvePendingZoom`) settles on it; the stage stays
        // invisible until then (`DeviceStageView.hidesUntilZoomSettles`).
        if reportsScale { state.publishVideoScale(Double(layout.pointsPerFramePixel)) }
    }

    /// Presents the clear color alone (the previous stream's last frame must
    /// not linger while the new one has not produced a frame yet).
    private func clearSurface(_ resources: MirrorRenderPipeline.Resources) {
        guard
            let descriptor = currentRenderPassDescriptor,
            let drawable = currentDrawable,
            let commandBuffer = resources.commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            return
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        needsClear = false
    }

    // MARK: - Input forwarding

    /// Lifts every synthesized touch still down through the current
    /// `onContacts` (see `MirrorInputController.liftAll`).
    func liftAllContacts() {
        inputControl.liftAll()
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    /// The first click on an inactive window (the floating compact mirror
    /// while another app is frontmost) must reach the device, not only
    /// activate the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        inputControl.mouseDown(event, in: self)
    }

    override func mouseDragged(with event: NSEvent) {
        inputControl.mouseDragged(event, in: self)
    }

    override func mouseUp(with event: NSEvent) {
        inputControl.mouseUp(event, in: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        if !inputControl.secondaryClick() {
            super.rightMouseDown(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        inputControl.magnify(with: event, in: self)
    }

    override func scrollWheel(with event: NSEvent) {
        inputControl.scrollWheel(with: event, in: self)
    }

    private var physicalKeys: Bool { keyboardForwardingEnabled && sendsPhysicalKeys?() == true }

    override func keyDown(with event: NSEvent) {
        // Esc leaves Log Focus from the stage too, unless the Mac keyboard is
        // forwarded to the device (Keyboard Capture on): then Esc is the device's.
        if event.keyCode == MirrorMetalView.escapeKeyCode, !keyboardForwardingEnabled,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           onEscapeWithoutCapture?() == true {
            return
        }
        if physicalKeys {
            // The phone repeats a held key itself; AppKit's repeats are dropped.
            if !event.isARepeat {
                onPhysicalKey?(.key(code: event.keyCode, isDown: true,
                                    modifiers: PhysicalKeyModifiers.mask(rawFlags: event.modifierFlags.rawValue)))
            }
            return
        }
        // Device Hub-style hardware keyboard switch: when forwarding is off,
        // the Mac keyboard does not reach the device.
        guard keyboardForwardingEnabled,
              let command = MirrorKeyRouting.command(
                  keyCode: event.keyCode,
                  characters: event.characters,
                  modifiers: event.modifierFlags
              )
        else {
            super.keyDown(with: event)
            return
        }
        onKey?(command)
    }

    override func keyUp(with event: NSEvent) {
        guard physicalKeys else { return super.keyUp(with: event) }
        onPhysicalKey?(.key(code: event.keyCode, isDown: false,
                            modifiers: PhysicalKeyModifiers.mask(rawFlags: event.modifierFlags.rawValue)))
    }

    override func flagsChanged(with event: NSEvent) {
        guard physicalKeys else { return super.flagsChanged(with: event) }
        if event.keyCode == MacKeyUsage.capsLock {
            // Caps Lock reports once per press: a tap.
            let mask = PhysicalKeyModifiers.mask(rawFlags: event.modifierFlags.rawValue)
            onPhysicalKey?(.key(code: event.keyCode, isDown: true, modifiers: mask))
            onPhysicalKey?(.key(code: event.keyCode, isDown: false, modifiers: mask))
        } else {
            onPhysicalKey?(.modifiers(PhysicalKeyModifiers.mask(rawFlags: event.modifierFlags.rawValue)))
        }
    }

    override func resignFirstResponder() -> Bool {
        if physicalKeys { onPhysicalKey?(.releaseAll) }
        return super.resignFirstResponder()
    }

    /// Maps a point in view coordinates to posed frame coordinates through
    /// the layout of the last draw — the image the user is clicking on — so
    /// input and rendering share one fit (in points, on every backing scale).
    ///
    /// The view may show the frame upright (the renderer samples the posed
    /// buffer rotated); the layout maps the point in upright space and back
    /// into the posed frame's coordinates, which is what
    /// `MirrorSession.translated` / `TouchMapping` expect.
    func devicePoint(at location: CGPoint) -> (x: Int32, y: Int32)? {
        presentedLayout?.framePoint(atViewPoint: location, isFlipped: isFlipped)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("(MirrorView) \(message)\n".utf8))
    }
}

/// Which Mac key presses reach the device, and as what.
enum MirrorKeyRouting {
    /// macOS virtual key codes forwarded as special keys (not text).
    static let specialKeyCodes: Set<UInt16> = [
        51, 117,            // delete / forward delete
        53,                 // escape
        36, 76,             // return / keypad enter
        48,                 // tab
        123, 124, 125, 126, // arrows
        115, 119,           // home / end
        116, 121,           // page up / page down
    ]

    /// The command a key press forwards, or nil to leave it to the Mac:
    /// ⌘ shortcuts stay menu shortcuts, and Control combinations are not
    /// typed (Ctrl+digit or Ctrl+punctuation report printable characters
    /// that would otherwise be inserted as text).
    static func command(
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> KeyboardCommand? {
        if modifiers.contains(.command) {
            return nil
        }
        if specialKeyCodes.contains(keyCode) {
            return .specialKey(keyCode)
        }
        if modifiers.contains(.control) {
            return nil
        }
        if let characters, !characters.isEmpty {
            return .text(characters)
        }
        return nil
    }
}

/// Whether a mirror view's window is on screen, readable from the frame
/// stream's delivery thread. `MirrorMetalView` is main-actor
/// bound and its frame observer is not, so the flag the observer consults
/// lives here instead of on the view.
final class FrameObserverVisibility: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true

    var isVisible: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}
