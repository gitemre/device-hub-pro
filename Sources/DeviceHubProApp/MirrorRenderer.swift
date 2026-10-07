import AppKit
import CoreVideo
import Metal
import Observation
import DeviceHubProKit

/// Why the mirror renderer could not be built.
struct MirrorRendererError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// The Metal state every mirror view shares: device, command queue, sampler
/// and render pipeline. It is built once per process, off the main thread
/// (a cold shader compile measured ~190 ms, paid by every view creation
/// before), and a build failure is kept for `MirrorView` to show instead of
/// leaving the stage silently blank.
@MainActor
@Observable
final class MirrorRenderPipeline {
    /// Starts building on first access, so the state a view reads is never
    /// changed by the view's own update.
    static let shared: MirrorRenderPipeline = {
        let pipeline = MirrorRenderPipeline()
        pipeline.load()
        return pipeline
    }()

    /// The drawable format every mirror view renders into.
    nonisolated static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm

    /// The one device the pipeline, every mirror view and their textures use.
    nonisolated static let systemDevice: (any MTLDevice)? = MTLCreateSystemDefaultDevice()

    struct Resources: Sendable {
        let device: any MTLDevice
        let commandQueue: any MTLCommandQueue
        let pipeline: any MTLRenderPipelineState
        let sampler: any MTLSamplerState
    }

    enum State {
        case idle
        case loading
        case ready(Resources)
        case failed(String)
    }

    private(set) var state: State = .idle

    var resources: Resources? {
        if case .ready(let resources) = state { return resources }
        return nil
    }

    var failure: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    /// Starts the build on first use; later calls do nothing. `build` is a
    /// test seam.
    func load(
        build: @escaping @Sendable () -> Result<Resources, MirrorRendererError> = {
            MirrorRenderPipeline.build(shaderSource: MirrorRenderPipeline.bundledShaderSource)
        }
    ) {
        guard case .idle = state else { return }
        state = .loading
        Task.detached(priority: .userInitiated) { [self] in
            let result = build()
            await finish(result)
        }
    }

    private func finish(_ result: Result<Resources, MirrorRendererError>) {
        switch result {
        case .success(let resources):
            state = .ready(resources)
        case .failure(let error):
            FileHandle.standardError.write(Data("(MirrorView) renderer unavailable: \(error)\n".utf8))
            state = .failed(error.description)
        }
    }

    /// The bundled shader source. SwiftPM copies `Shaders.metal` as a
    /// resource instead of compiling a default.metallib, so it is compiled
    /// at runtime.
    nonisolated static func bundledShaderSource() throws -> String {
        guard let url = bundledShaderURL() else {
            throw MirrorRendererError("The mirror shader is missing from the app's resources.")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// `Shaders.metal` in the app's resource bundle: the one packaged in the
    /// app's `Contents/Resources` first, then `Bundle.module`
    /// (`ResourceBundleLookup`). The parameters are a test seam.
    nonisolated static func bundledShaderURL(
        resourceDirectory: URL? = Bundle.main.resourceURL,
        module: () -> Bundle = { Bundle.module }
    ) -> URL? {
        ResourceBundleLookup.url(
            forResource: "Shaders",
            withExtension: "metal",
            bundleName: ResourceBundleLookup.appBundleName,
            resourceDirectory: resourceDirectory,
            module: module
        )
    }

    /// Compiles the mirror pipeline. Every failure carries the underlying
    /// message (the Metal compiler's diagnostics included).
    nonisolated static func build(
        shaderSource: () throws -> String
    ) -> Result<Resources, MirrorRendererError> {
        guard let device = systemDevice else {
            return .failure(MirrorRendererError("This Mac has no Metal device."))
        }
        guard let commandQueue = device.makeCommandQueue() else {
            return .failure(MirrorRendererError("Metal could not create a command queue."))
        }
        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(source: try shaderSource(), options: nil)
        } catch {
            return .failure(MirrorRendererError("The mirror shader did not compile: \(error)"))
        }
        guard let vertex = library.makeFunction(name: "mirror_vertex"),
              let fragment = library.makeFunction(name: "mirror_fragment")
        else {
            return .failure(MirrorRendererError("The mirror shader has no mirror_vertex/mirror_fragment."))
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        let pipeline: any MTLRenderPipelineState
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return .failure(MirrorRendererError("The mirror pipeline could not be built: \(error)"))
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            return .failure(MirrorRendererError("Metal could not create the mirror sampler."))
        }
        return .success(Resources(
            device: device,
            commandQueue: commandQueue,
            pipeline: pipeline,
            sampler: sampler
        ))
    }
}

/// A frame ready to draw: its texture plus the metadata it was made from.
///
/// `@unchecked Sendable`: immutable once published; the texture is only read
/// (by the GPU) from then on, and the slot bookkeeping is guarded by the
/// uploader's lock.
final class PreparedFrame: @unchecked Sendable {
    let texture: any MTLTexture
    let width: Int
    let height: Int
    let rotation: Int
    let generation: UInt64
    /// A remembered picture of the device (`LastPictureCache`) drawn before
    /// the stream's first frame: it never counts as a frame of the stream.
    fileprivate(set) var isSeed = false
    /// The size the frame is laid out at: its own, except for a remembered
    /// picture, which is stored shrunk but stands for a full-size frame of
    /// the device (`RememberedPicture.fullSize`), so the stage's size and
    /// zoom do not change when the stream's first frame replaces it.
    fileprivate(set) var layoutWidth = 0
    fileprivate(set) var layoutHeight = 0
    /// The reusable upload texture this frame occupies (byte frames only).
    fileprivate let slot: UploadSlot?
    /// Keeps a decoded buffer's texture valid until the GPU is done with it.
    private let pixelBufferTexture: CVMetalTexture?

    fileprivate init(
        texture: any MTLTexture,
        frame: Frame,
        slot: UploadSlot?,
        pixelBufferTexture: CVMetalTexture?
    ) {
        self.texture = texture
        self.width = frame.width
        self.height = frame.height
        self.layoutWidth = frame.width
        self.layoutHeight = frame.height
        self.rotation = frame.rotation
        self.generation = frame.generation
        self.slot = slot
        self.pixelBufferTexture = pixelBufferTexture
    }
}

/// One reusable upload texture; `inFlight` counts the draws still sampling it
/// (guarded by the uploader's lock).
private final class UploadSlot {
    let texture: any MTLTexture
    var inFlight = 0

    init(texture: any MTLTexture) {
        self.texture = texture
    }
}

/// Turns the newest frame of one `FrameStore` into a texture on a private
/// queue, so no pixel copy runs on the main thread:
///
/// - a decoded video frame (`Frame.pixelBuffer`, IOSurface-backed BGRA) is
///   wrapped by `CVMetalTextureCache`: the GPU samples the decoder's buffer
///   in place, no copy and no channel swizzle;
/// - a byte frame (the emulator's raw and MMAP transports) is copied into
///   one of a few reusable textures that no draw is still sampling, so the
///   copy never overwrites pixels in use and no texture is allocated per
///   frame (only when the frame size changes).
///
/// Uploads coalesce: while one is queued, further frames only make it take
/// the newest frame. `@unchecked Sendable`: the shared state is guarded by
/// `lock`; the texture cache and upload bookkeeping are confined to `queue`.
final class MirrorFrameUploader: @unchecked Sendable {
    /// Textures in the byte-frame ring: one on screen, one in flight on the
    /// GPU, one being written.
    static let maximumSlots = 3
    /// The largest texture every Metal Mac supports.
    static let maximumTextureDimension = 16_384

    private let device: any MTLDevice
    private let onPrepared: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.devicehubpro.mirror.upload", qos: .userInteractive)

    // Guarded by `lock`.
    private let lock = NSLock()
    private var store: FrameStore?
    private var epoch: UInt64 = 0
    private var ready: PreparedFrame?
    private var uploadScheduled = false
    private var waitingForSlot = false

    // Confined to `queue`.
    private var textureCache: CVMetalTextureCache?
    private var slots: [UploadSlot] = []
    private var lastPreparedGeneration: UInt64 = 0
    private var reportedInvalidFrame = false

    /// `onPrepared` runs on the upload queue whenever a new frame is ready;
    /// the view hops to the main thread from there.
    init(device: any MTLDevice, onPrepared: @escaping @Sendable () -> Void) {
        self.device = device
        self.onPrepared = onPrepared
    }

    /// Serves `store` from now on (nil detaches) and forgets the frame
    /// prepared from the previous one, so it is never drawn for the new
    /// session.
    func attach(_ store: FrameStore?) {
        lock.lock()
        self.store = store
        epoch &+= 1
        ready = nil
        lock.unlock()
        queue.async {
            // Prepare the store's current frame even when it is the one
            // prepared last (the same store attached again).
            self.lastPreparedGeneration = 0
            self.uploadNewest()
        }
    }

    /// Shows `frame` (a remembered picture) until a frame of the attached
    /// store is prepared: ignored when one already is, or when another store
    /// was attached meanwhile.
    func seed(_ frame: Frame, fullSize: CGSize? = nil) {
        let epoch = lock.withLock { self.epoch }
        queue.async {
            guard case .ready(let prepared) = self.prepare(frame) else { return }
            prepared.isSeed = true
            if let fullSize, fullSize.width >= 1, fullSize.height >= 1 {
                prepared.layoutWidth = Int(fullSize.width)
                prepared.layoutHeight = Int(fullSize.height)
            }
            self.lock.lock()
            guard self.epoch == epoch, self.ready == nil else {
                self.lock.unlock()
                return
            }
            self.ready = prepared
            self.lock.unlock()
            self.onPrepared()
        }
    }

    /// The store has a new frame (its observer).
    func frameArrived() {
        scheduleUpload()
    }

    /// The newest prepared frame, reserved for one draw. Every acquired
    /// frame must be passed to `release` once the GPU is done with it (or
    /// the draw was abandoned).
    func acquire() -> PreparedFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard let ready else { return nil }
        ready.slot?.inFlight += 1
        return ready
    }

    func release(_ frame: PreparedFrame) {
        lock.lock()
        frame.slot?.inFlight -= 1
        let retry = waitingForSlot
        waitingForSlot = false
        lock.unlock()
        if retry {
            scheduleUpload()
        }
    }

    /// Waits until the queued uploads ran (tests).
    func drain() {
        queue.sync {}
    }

    private func scheduleUpload() {
        lock.lock()
        if uploadScheduled {
            lock.unlock()
            return
        }
        uploadScheduled = true
        lock.unlock()
        queue.async { self.uploadNewest() }
    }

    private func uploadNewest() {
        lock.lock()
        uploadScheduled = false
        let store = self.store
        let epoch = self.epoch
        lock.unlock()

        guard let frame = store?.current, frame.generation != lastPreparedGeneration else {
            return
        }
        let prepared: PreparedFrame
        switch prepare(frame) {
        case .ready(let frame):
            prepared = frame
        case .waitForSlot:
            return
        case .invalid:
            lastPreparedGeneration = frame.generation
            return
        }

        lock.lock()
        guard self.epoch == epoch else {
            // The view moved on to another store meanwhile.
            lock.unlock()
            return
        }
        ready = prepared
        lock.unlock()
        lastPreparedGeneration = frame.generation
        onPrepared()
    }

    private enum Preparation {
        case ready(PreparedFrame)
        case waitForSlot
        case invalid
    }

    private func prepare(_ frame: Frame) -> Preparation {
        guard frame.width > 0, frame.height > 0,
              frame.width <= Self.maximumTextureDimension,
              frame.height <= Self.maximumTextureDimension
        else {
            reportInvalid(frame, bytes: nil)
            return .invalid
        }
        if let pixelBuffer = frame.pixelBuffer,
           let wrapped = wrap(pixelBuffer)
        {
            return .ready(PreparedFrame(
                texture: wrapped.texture,
                frame: frame,
                slot: nil,
                pixelBufferTexture: wrapped.owner
            ))
        }
        return upload(frame)
    }

    /// Wraps a decoded IOSurface-backed BGRA buffer as a texture, or nil
    /// (the frame then takes the byte path).
    private func wrap(_ pixelBuffer: CVPixelBuffer) -> (texture: any MTLTexture, owner: CVMetalTexture)? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetIOSurface(pixelBuffer) != nil
        else {
            return nil
        }
        if textureCache == nil {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            textureCache = cache
        }
        guard let textureCache else { return nil }
        // Releases the cache's textures for buffers nobody holds any more.
        CVMetalTextureCacheFlush(textureCache, 0)
        var owner: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer),
            CVPixelBufferGetHeight(pixelBuffer),
            0,
            &owner
        )
        guard status == kCVReturnSuccess, let owner,
              let texture = CVMetalTextureGetTexture(owner)
        else {
            return nil
        }
        return (texture, owner)
    }

    /// Copies a byte frame into a free ring texture.
    private func upload(_ frame: Frame) -> Preparation {
        let data = frame.data
        let bytesPerRow = frame.width * 4
        guard data.count >= bytesPerRow * frame.height else {
            // A short payload would make `replace` read past the buffer.
            reportInvalid(frame, bytes: data.count)
            return .invalid
        }

        lock.lock()
        // A new frame size retires the ring; textures still on screen or in
        // flight stay alive through their prepared frames until released.
        slots.removeAll { $0.texture.width != frame.width || $0.texture.height != frame.height }
        let onScreen = ready?.slot
        var slot = slots.first { $0.inFlight == 0 && $0 !== onScreen }
        if slot == nil, slots.count < Self.maximumSlots {
            lock.unlock()
            guard let created = makeUploadSlot(width: frame.width, height: frame.height) else {
                reportInvalid(frame, bytes: data.count)
                return .invalid
            }
            lock.lock()
            slots.append(created)
            slot = created
        }
        guard let slot else {
            // Every texture is still being sampled; retry on the next release.
            waitingForSlot = true
            lock.unlock()
            return .waitForSlot
        }
        lock.unlock()

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            slot.texture.replace(
                region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: bytesPerRow
            )
        }
        return .ready(PreparedFrame(texture: slot.texture, frame: frame, slot: slot, pixelBufferTexture: nil))
    }

    private func makeUploadSlot(width: Int, height: Int) -> UploadSlot? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        // CPU-written textures: shared on unified memory, managed on a
        // discrete GPU (shared textures are Apple-GPU only on macOS).
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        return device.makeTexture(descriptor: descriptor).map(UploadSlot.init(texture:))
    }

    private func reportInvalid(_ frame: Frame, bytes: Int?) {
        guard !reportedInvalidFrame else { return }
        reportedInvalidFrame = true
        let payload = bytes.map { ", \($0) bytes" } ?? ""
        FileHandle.standardError.write(Data(
            "(MirrorView) dropping a \(frame.width)×\(frame.height) frame\(payload)\n".utf8
        ))
    }
}
