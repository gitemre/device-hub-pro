import CoreVideo
import Metal
import MetalKit
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The mirror renderer's shared pipeline (MR-07), its off-main uploads
/// (zero-copy decoded frames, reusable byte-frame textures, MR-06/MR-12) and
/// the per-store reset of a reused view (MR-04).
@MainActor
final class MirrorRendererTests: XCTestCase {
    private func device() throws -> any MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        return device
    }

    // MARK: - Pipeline

    func testTheBundledShaderBuilds() throws {
        _ = try device()
        let result = MirrorRenderPipeline.build(shaderSource: MirrorRenderPipeline.bundledShaderSource)
        if case .failure(let error) = result {
            XCTFail("the bundled shader must build: \(error)")
        }
    }

    func testACompileFailureKeepsTheCompilerDiagnostics() throws {
        _ = try device()
        let result = MirrorRenderPipeline.build(shaderSource: { "fragment float4 broken( {" })
        guard case .failure(let error) = result else {
            return XCTFail("a broken shader must not build")
        }
        XCTAssertTrue(error.description.contains("did not compile"), error.description)
        XCTAssertGreaterThan(error.description.count, "The mirror shader did not compile: ".count)
    }

    func testThePipelineIsBuiltOnceAndAFailureIsKept() async throws {
        let pipeline = MirrorRenderPipeline()
        let builds = BuildCounter()
        let failing: @Sendable () -> Result<MirrorRenderPipeline.Resources, MirrorRendererError> = {
            builds.increment()
            return .failure(MirrorRendererError("no GPU in this test"))
        }

        pipeline.load(build: failing)
        pipeline.load(build: failing)
        await waitUntil { pipeline.failure != nil }

        XCTAssertEqual(pipeline.failure, "no GPU in this test")
        XCTAssertNil(pipeline.resources)
        pipeline.load(build: failing)
        XCTAssertEqual(builds.value, 1, "one build per process, however many views ask")
    }

    // MARK: - Uploads

    func testADecodedFrameIsSampledInPlace() throws {
        let device = try device()
        let (store, uploader, observation) = makeUploader(device: device)
        let pixelBuffer = try makeBGRAPixelBuffer(width: 64, height: 32)
        let conversions = BuildCounter()

        store.put(Frame(pixelBuffer: pixelBuffer, seq: 1) { _ in
            conversions.increment()
            return nil
        })
        uploader.drain()

        let prepared = try XCTUnwrap(uploader.acquire())
        XCTAssertEqual(prepared.texture.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(prepared.width, 64)
        XCTAssertEqual(prepared.height, 32)
        XCTAssertTrue(
            prepared.texture.iosurface === CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue(),
            "the texture must wrap the decoder's IOSurface, not a copy"
        )
        XCTAssertEqual(conversions.value, 0, "no CPU conversion for the renderer")
        uploader.release(prepared)
        withExtendedLifetime(observation) {}
    }

    func testAByteFrameIsUploadedWithItsPixels() throws {
        let device = try device()
        let (store, uploader, observation) = makeUploader(device: device)
        let pixels: [UInt8] = [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 9, 9, 9, 255,
        ]
        store.put(Frame(data: Data(pixels), width: 2, height: 2, seq: 1, rotation: 1))
        uploader.drain()

        let prepared = try XCTUnwrap(uploader.acquire())
        XCTAssertEqual(prepared.rotation, 1)
        XCTAssertEqual(prepared.texture.pixelFormat, .rgba8Unorm)
        var readBack = [UInt8](repeating: 0, count: 16)
        if prepared.texture.storageMode != .private {
            prepared.texture.getBytes(&readBack, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
            XCTAssertEqual(readBack, pixels)
        }
        uploader.release(prepared)
        withExtendedLifetime(observation) {}
    }

    func testAShortPayloadIsDroppedInsteadOfReadPastItsEnd() throws {
        let device = try device()
        let (store, uploader, observation) = makeUploader(device: device)
        store.put(Frame(data: Data(count: 100), width: 64, height: 64, seq: 1))
        uploader.drain()
        XCTAssertNil(uploader.acquire())
        withExtendedLifetime(observation) {}
    }

    func testByteFramesReuseAFewTexturesAndNeverOverwriteOneInUse() throws {
        let device = try device()
        let (store, uploader, observation) = makeUploader(device: device)
        var textures = Set<ObjectIdentifier>()

        // The first frame stays "on the GPU" for the whole run.
        store.put(Frame(data: Data(count: 16 * 16 * 4), width: 16, height: 16, seq: 0))
        uploader.drain()
        let held = try XCTUnwrap(uploader.acquire())
        textures.insert(ObjectIdentifier(held.texture))

        for seq in 1...12 {
            store.put(Frame(data: Data(repeating: UInt8(seq), count: 16 * 16 * 4), width: 16, height: 16, seq: UInt32(seq)))
            uploader.drain()
            let prepared = try XCTUnwrap(uploader.acquire())
            XCTAssertFalse(prepared.texture === held.texture, "a texture still being sampled was overwritten")
            textures.insert(ObjectIdentifier(prepared.texture))
            uploader.release(prepared)
        }
        XCTAssertLessThanOrEqual(textures.count, MirrorFrameUploader.maximumSlots, "no texture per frame")
        uploader.release(held)
        withExtendedLifetime(observation) {}
    }

    func testAFrameWaitsForAFreeTextureAndIsUploadedOnRelease() throws {
        let device = try device()
        let (store, uploader, observation) = makeUploader(device: device)
        var held: [PreparedFrame] = []
        for seq in 0..<MirrorFrameUploader.maximumSlots {
            store.put(Frame(data: Data(count: 4 * 4 * 4), width: 4, height: 4, seq: UInt32(seq)))
            uploader.drain()
            held.append(try XCTUnwrap(uploader.acquire()))
        }
        // Every texture is in flight: the newest frame has to wait.
        store.put(Frame(data: Data(count: 4 * 4 * 4), width: 4, height: 4, seq: 99))
        uploader.drain()
        let before = try XCTUnwrap(uploader.acquire())
        XCTAssertNotEqual(before.generation, store.currentGeneration)
        uploader.release(before)

        uploader.release(held.removeFirst())
        uploader.drain()
        let after = try XCTUnwrap(uploader.acquire())
        XCTAssertEqual(after.generation, store.currentGeneration)
        uploader.release(after)
        held.forEach(uploader.release)
        withExtendedLifetime(observation) {}
    }

    func testAttachingAnotherStoreDropsThePreviousStreamsFrame() throws {
        let device = try device()
        let (first, uploader, observation) = makeUploader(device: device)
        first.put(Frame(data: Data(count: 16), width: 2, height: 2, seq: 0))
        uploader.drain()
        XCTAssertNotNil(uploader.acquire().map { uploader.release($0) })

        let second = FrameStore()
        uploader.attach(second)
        uploader.drain()
        XCTAssertNil(uploader.acquire(), "the old session's frame must not be drawn for the new one")

        second.put(Frame(data: Data(count: 16), width: 2, height: 2, seq: 0))
        uploader.frameArrived()
        uploader.drain()
        XCTAssertEqual(uploader.acquire()?.generation, second.currentGeneration)
        withExtendedLifetime(observation) {}
    }

    func testReattachingTheSameStorePreparesItsFrameAgain() throws {
        let device = try device()
        let (store, uploader, observation) = makeUploader(device: device)
        store.put(Frame(data: Data(count: 16), width: 2, height: 2, seq: 0))
        uploader.drain()
        uploader.attach(nil)
        uploader.attach(store)
        uploader.drain()
        XCTAssertEqual(uploader.acquire()?.generation, store.currentGeneration, "a static screen must not stay blank")
        withExtendedLifetime(observation) {}
    }

    // MARK: - View

    func testTheViewDrawsOnDemandAndTakesTheFirstClick() throws {
        let view = MirrorMetalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), device: try device())
        XCTAssertTrue(view.isPaused, "no display-link loop")
        XCTAssertTrue(view.enableSetNeedsDisplay)
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    private func escape(_ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
            keyCode: MirrorMetalView.escapeKeyCode
        ))
    }

    /// A bare Esc reaches `onEscapeWithoutCapture` only while the keyboard is
    /// not forwarded and no modifier is down; a true answer ends the event
    /// there (nothing is sent to the device), a false one lets it fall on.
    func testABareEscapeLeavesLogFocusOnlyWhenTheKeyboardIsNotForwarded() throws {
        let view = MirrorMetalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), device: try device())
        var asked = 0
        var answer = true
        var sent = 0
        view.onEscapeWithoutCapture = { asked += 1; return answer }
        view.onKey = { _ in sent += 1 }

        view.keyboardForwardingEnabled = false
        view.keyDown(with: try escape())
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(sent, 0, "a used Esc stops there")

        answer = false
        view.keyDown(with: try escape())
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(sent, 0, "with forwarding off nothing reaches the device either way")

        for modifiers: NSEvent.ModifierFlags in [.shift, .command, .option, .control] {
            view.keyDown(with: try escape(modifiers))
        }
        XCTAssertEqual(asked, 2, "Esc with a modifier is not a bare Esc")

        view.keyboardForwardingEnabled = true
        view.keyDown(with: try escape())
        XCTAssertEqual(asked, 2, "with the keyboard forwarded Esc belongs to the device")
    }

    func testAReusedViewPresentsTheNewSessionsFrames() async throws {
        MirrorRenderPipeline.shared.load()
        await waitUntil { MirrorRenderPipeline.shared.resources != nil || MirrorRenderPipeline.shared.failure != nil }
        guard MirrorRenderPipeline.shared.resources != nil else { throw XCTSkip("no Metal pipeline") }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let view = MirrorMetalView(frame: NSRect(x: 0, y: 0, width: 200, height: 300), device: try device())
        window.contentView = view
        defer { window.close() }

        let first = FrameStore()
        view.frames = first
        first.put(Frame(data: Data(count: 100 * 200 * 4), width: 100, height: 200, seq: 0))
        await waitUntil { view.presentedLayout?.posedWidth == 100 }
        XCTAssertNotNil(view.devicePoint(at: CGPoint(x: 100, y: 150)))

        // The compact window keeps its view across a session switch.
        let second = FrameStore()
        view.frames = second
        XCTAssertNil(view.presentedLayout, "input must not map through the previous stream's layout")
        XCTAssertNil(view.devicePoint(at: CGPoint(x: 100, y: 150)))

        second.put(Frame(data: Data(count: 300 * 150 * 4), width: 300, height: 150, seq: 0))
        await waitUntil { view.presentedLayout?.posedWidth == 300 }
        XCTAssertEqual(view.state.devicePixelSize, CGSize(width: 300, height: 150))
    }

    func testSwitchingSessionsLiftsTheFingerOnTheSessionItWentDownOn() async throws {
        MirrorRenderPipeline.shared.load()
        await waitUntil { MirrorRenderPipeline.shared.resources != nil || MirrorRenderPipeline.shared.failure != nil }
        guard MirrorRenderPipeline.shared.resources != nil else { throw XCTSkip("no Metal pipeline") }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let view = MirrorMetalView(frame: NSRect(x: 0, y: 0, width: 200, height: 300), device: try device())
        window.contentView = view
        defer { window.close() }

        let first = FrameStore()
        var onFirst: [TouchCommand] = []
        view.frames = first
        view.onContacts = { onFirst.append(contentsOf: $0) }
        first.put(Frame(data: Data(count: 100 * 200 * 4), width: 100, height: 200, seq: 0))
        await waitUntil { view.presentedLayout != nil }

        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 150), in: window))
        XCTAssertEqual(onFirst.map(\.phase), [.down])

        // What `MirrorSurface.configure` does for another session: the
        // store first, then the new session's input.
        var onSecond: [TouchCommand] = []
        view.frames = FrameStore()
        view.onContacts = { onSecond.append(contentsOf: $0) }
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 110, y: 150), in: window))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 110, y: 150), in: window))

        XCTAssertEqual(onFirst.map(\.phase), [.down, .up], "the old device must not keep a finger down")
        XCTAssertTrue(onSecond.isEmpty, "the new device must not get an .up it never saw go down")
    }

    /// Occlusion gating: while `isWindowVisible` is false
    /// a new frame does not update the presented layout — the per-frame
    /// work stops for a window nobody can see — and setting it back to
    /// true catches the surface up to the latest frame without a new frame
    /// arriving.
    func testOcclusionGatingStopsAndResumesPerFrameWork() async throws {
        MirrorRenderPipeline.shared.load()
        await waitUntil { MirrorRenderPipeline.shared.resources != nil || MirrorRenderPipeline.shared.failure != nil }
        guard MirrorRenderPipeline.shared.resources != nil else { throw XCTSkip("no Metal pipeline") }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let view = MirrorMetalView(frame: NSRect(x: 0, y: 0, width: 200, height: 300), device: try device())
        window.contentView = view
        defer { window.close() }
        XCTAssertTrue(view.isWindowVisible, "visible by default, before any window binds")

        let store = FrameStore()
        view.frames = store
        store.put(Frame(data: Data(count: 100 * 200 * 4), width: 100, height: 200, seq: 0))
        await waitUntil { view.presentedLayout?.posedWidth == 100 }

        view.isWindowVisible = false
        store.put(Frame(data: Data(count: 300 * 150 * 4), width: 300, height: 150, seq: 1))
        // Give the (would-be) async upload a chance to run, then confirm it
        // did not: the surface still shows the frame from before occlusion.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(view.presentedLayout?.posedWidth, 100, "a hidden window must not upload a new frame")

        view.isWindowVisible = true
        await waitUntil { view.presentedLayout?.posedWidth == 300 }
    }

    /// A pause and resume keeps the last frame: the view's retained texture
    /// is drawn again on resume with no new frame, and the surface is the
    /// placeholder (not black) only until the first frame is drawn.
    func testResumeRedrawsTheRetainedFrameAndPlaceholderEndsAtTheFirstFrame() async throws {
        MirrorRenderPipeline.shared.load()
        await waitUntil { MirrorRenderPipeline.shared.resources != nil || MirrorRenderPipeline.shared.failure != nil }
        guard MirrorRenderPipeline.shared.resources != nil else { throw XCTSkip("no Metal pipeline") }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let view = MirrorMetalView(frame: NSRect(x: 0, y: 0, width: 200, height: 300), device: try device())
        window.contentView = view
        defer { window.close() }

        let store = FrameStore()
        view.frames = store
        let placeholder = MirrorMetalView.placeholderColor
        XCTAssertFalse(view.hasPresentedFrame)
        XCTAssertEqual(view.clearColor.red, placeholder.red, accuracy: 0.001, "not pure black before the first frame")
        XCTAssertGreaterThan(view.clearColor.red, 0)

        store.put(Frame(data: Data(count: 100 * 200 * 4), width: 100, height: 200, seq: 0))
        await waitUntil { view.presentedLayout?.posedWidth == 100 }
        XCTAssertTrue(view.hasPresentedFrame)
        XCTAssertEqual(view.clearColor.red, 0, "black round the picture once one is drawn")

        view.isWindowVisible = false
        view.presentedLayout = nil
        view.isWindowVisible = true
        await waitUntil { view.presentedLayout?.posedWidth == 100 }
        XCTAssertEqual(view.presentedLayout?.posedWidth, 100, "the retained texture is drawn again without a new frame")
    }

    /// A remembered picture is drawn before the stream's first frame, is
    /// not mistaken for the stream (no settled geometry, the placeholder
    /// stays until a real frame) and gives way to the first real frame.
    func testSeedPictureIsDrawnBeforeTheFirstFrameAndReplacedByIt() async throws {
        MirrorRenderPipeline.shared.load()
        await waitUntil { MirrorRenderPipeline.shared.resources != nil || MirrorRenderPipeline.shared.failure != nil }
        guard MirrorRenderPipeline.shared.resources != nil else { throw XCTSkip("no Metal pipeline") }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let view = MirrorMetalView(frame: NSRect(x: 0, y: 0, width: 200, height: 300), device: try device())
        window.contentView = view
        defer { window.close() }

        // A picture larger than the cache keeps: stored shrunk, laid out at its full size.
        let cache = LastPictureCache()
        cache.remember(Frame(data: Data(count: 600 * 1200 * 4), width: 600, height: 1200, seq: 0), for: "phone")
        let seed = try XCTUnwrap(cache.picture(for: "phone", matching: .portrait))
        XCTAssertLessThan(seed.frame.width, 600, "the cache keeps it shrunk")

        let store = FrameStore()
        view.reportsScale = true
        view.frames = store
        view.seedPicture = seed
        await waitUntil { view.presentedLayout?.posedWidth == 600 }
        XCTAssertTrue(view.presentedSeed, "the remembered picture is on screen")
        XCTAssertEqual(view.presentedLayout?.posedHeight, 1200, "laid out at the device's full size, so the stream's first frame changes no size")
        XCTAssertNotNil(view.state.videoPointsPerPixel, "its draw publishes the scale, so the opening zoom settles on it")
        XCTAssertFalse(view.hasPresentedFrame, "it is not a frame of the stream")
        XCTAssertNil(view.state.devicePixelSize, "it settles no geometry")

        store.put(Frame(data: Data(count: 100 * 200 * 4), width: 100, height: 200, seq: 1))
        await waitUntil { view.presentedLayout?.posedWidth == 100 }
        XCTAssertFalse(view.presentedSeed)
        XCTAssertTrue(view.hasPresentedFrame)
        XCTAssertNotNil(view.state.videoPointsPerPixel)

        // The same seed set again (a SwiftUI update) does not bring it back.
        view.seedPicture = seed
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(view.presentedLayout?.posedWidth, 100)
    }

    /// A real frame that is already in when the seed arrives wins: the
    /// remembered picture is never drawn over the live one.
    func testSeedIsNotDrawnOverARealFrameThatArrivedFirst() async throws {
        MirrorRenderPipeline.shared.load()
        await waitUntil { MirrorRenderPipeline.shared.resources != nil || MirrorRenderPipeline.shared.failure != nil }
        guard MirrorRenderPipeline.shared.resources != nil else { throw XCTSkip("no Metal pipeline") }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let view = MirrorMetalView(frame: NSRect(x: 0, y: 0, width: 200, height: 300), device: try device())
        window.contentView = view
        defer { window.close() }

        let cache = LastPictureCache()
        cache.remember(Frame(data: Data(count: 60 * 120 * 4), width: 60, height: 120, seq: 0), for: "phone")
        let seed = try XCTUnwrap(cache.picture(for: "phone", matching: .portrait))

        let store = FrameStore()
        view.frames = store
        store.put(Frame(data: Data(count: 100 * 200 * 4), width: 100, height: 200, seq: 1))
        await waitUntil { view.presentedLayout?.posedWidth == 100 }

        view.seedPicture = seed
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(view.presentedLayout?.posedWidth, 100)
        XCTAssertFalse(view.presentedSeed)
    }

    // MARK: - Helpers

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func makeUploader(device: any MTLDevice) -> (FrameStore, MirrorFrameUploader, FrameObservation) {
        let store = FrameStore()
        let uploader = MirrorFrameUploader(device: device) {}
        uploader.attach(store)
        let observation = store.observe { [weak uploader] in uploader?.frameArrived() }
        return (store, uploader, observation)
    }

    private func makeBGRAPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &pixelBuffer
        ), kCVReturnSuccess)
        return try XCTUnwrap(pixelBuffer)
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                return XCTFail("condition not met within \(timeout) s")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class BuildCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
