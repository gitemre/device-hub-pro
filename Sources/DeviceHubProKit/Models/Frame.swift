import CoreVideo
import Foundation

/// A single mirror frame: pixel bytes (the emulator's raw transport, or a
/// copy of its shared-memory frame for MMAP), or a decoded video pixel buffer
/// (the scrcpy transport).
public struct Frame: Sendable {
    /// The frame as RGBA8888 bytes, `width * 4` per row. A pixel-buffer frame
    /// makes them from its buffer on first request and keeps them, so only
    /// consumers that need bytes pay for the conversion.
    public var data: Data {
        switch pixels {
        case .bytes(let data): return data
        case .decoded(let decoded): return decoded.rgba()
        }
    }

    /// The decoded video buffer (32BGRA, IOSurface-backed) when the frame
    /// came from a decoder, nil for byte frames. A renderer can sample it in
    /// place instead of copying `data`. Nobody may write to it.
    public var pixelBuffer: CVPixelBuffer? {
        switch pixels {
        case .bytes: return nil
        case .decoded(let decoded): return decoded.pixelBuffer
        }
    }

    public let width: Int
    public let height: Int
    /// The emulator's frame sequence number, for drop statistics only: a
    /// one-shot screenshot always carries 0, so it cannot tell two stored
    /// frames apart. Use `generation` for that.
    public let seq: UInt32
    /// Stamped by `FrameStore.put` from one process-wide counter: strictly
    /// increasing for every stored frame and never reused by another store,
    /// so a consumer that remembers the last generation it drew never skips
    /// a repaint — not for two snapshots in a row (both have seq 0), and not
    /// when it is handed a new session's store. Zero until the frame is
    /// stored.
    public internal(set) var generation: UInt64 = 0
    /// The emulator's coarse-grained device rotation for this frame (0...3).
    /// Frame content is already composed for this orientation, so the UI rotates
    /// the frame/bezel to match while keeping the content upright.
    public let rotation: Int

    private let pixels: Pixels

    private enum Pixels: Sendable {
        case bytes(Data)
        case decoded(DecodedPixels)
    }

    public init(data: Data, width: Int, height: Int, seq: UInt32, rotation: Int = 0) {
        self.pixels = .bytes(data)
        self.width = width
        self.height = height
        self.seq = seq
        self.rotation = rotation
    }

    /// A decoded video frame. `rgba` converts the buffer into the RGBA bytes
    /// `data` returns; it runs at most once, when a consumer first asks.
    init(
        pixelBuffer: CVPixelBuffer,
        seq: UInt32,
        rotation: Int = 0,
        rgba: @escaping @Sendable (CVPixelBuffer) -> Data?
    ) {
        self.pixels = .decoded(DecodedPixels(pixelBuffer: pixelBuffer, convert: rgba))
        self.width = CVPixelBufferGetWidth(pixelBuffer)
        self.height = CVPixelBufferGetHeight(pixelBuffer)
        self.seq = seq
        self.rotation = rotation
    }
}

/// The pixels of a decoded frame, shared by every copy of the `Frame`.
///
/// `@unchecked Sendable`: `CVPixelBuffer` is not `Sendable`, but a decoded
/// buffer is never written again (a decoder's pool recycles a buffer only
/// once every reference to it is gone), and the RGBA bytes made on demand are
/// guarded by the lock.
private final class DecodedPixels: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    private let convert: @Sendable (CVPixelBuffer) -> Data?
    private let lock = NSLock()
    private var bytes: Data?

    init(pixelBuffer: CVPixelBuffer, convert: @escaping @Sendable (CVPixelBuffer) -> Data?) {
        self.pixelBuffer = pixelBuffer
        self.convert = convert
    }

    /// The RGBA bytes, converted once; empty when the conversion failed
    /// (consumers already check the length against the frame size).
    func rgba() -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let bytes { return bytes }
        let made = convert(pixelBuffer) ?? Data()
        bytes = made
        return made
    }
}

/// Holds the most recent frame; the renderer consumes it. Keeping only the latest
/// frame is the display backpressure: if rendering is slower than the stream, older
/// frames are dropped instead of queued.
public final class FrameStore: @unchecked Sendable {
    /// Shared by every store: MirrorView swaps a new session's store into the
    /// same renderer, which must not mistake that session's first frames for
    /// ones it already drew from the previous store.
    private static let generationLock = NSLock()
    nonisolated(unsafe) private static var lastGeneration: UInt64 = 0

    private let lock = NSLock()
    private var latest: Frame?
    private var size: (width: Int, height: Int)?
    private var generation: UInt64 = 0
    private var observers: [UInt64: @Sendable () -> Void] = [:]
    private var nextObserverID: UInt64 = 0

    public init() {}

    private var _isPaused = false
    /// While true, a session that checks it drops stream frames before
    /// building a `Frame` (no per-frame copy for a stage nobody sees). The
    /// owner clears it and asks the session to `resync()` when the stage
    /// shows again, so the stored frame never stays stale.
    public var isPaused: Bool {
        get { lock.withLock { _isPaused } }
        set { lock.withLock { _isPaused = newValue } }
    }

    func put(_ frame: Frame) {
        lock.lock()
        store(frame)
        let notify = Array(observers.values)
        lock.unlock()
        notify.forEach { $0() }
    }

    /// Stores `frame` only while the newest stored frame is still generation
    /// `expected` — a repair taken from a slower source (a screenshot RPC)
    /// must not replace a stream frame that arrived in the meantime.
    @discardableResult
    func put(_ frame: Frame, ifGeneration expected: UInt64) -> Bool {
        lock.lock()
        guard generation == expected else {
            lock.unlock()
            return false
        }
        store(frame)
        let notify = Array(observers.values)
        lock.unlock()
        notify.forEach { $0() }
        return true
    }

    /// Calls `observer` after every stored frame, on the thread that stored
    /// it and outside the store's lock, until the returned observation is
    /// cancelled or released. The observer must be cheap (it runs on the
    /// stream's delivery path): read `current` or hand off, never render.
    public func observe(_ observer: @escaping @Sendable () -> Void) -> FrameObservation {
        lock.lock()
        nextObserverID += 1
        let id = nextObserverID
        observers[id] = observer
        lock.unlock()
        return FrameObservation(store: self, id: id)
    }

    fileprivate func removeObserver(_ id: UInt64) {
        lock.lock()
        observers[id] = nil
        lock.unlock()
    }

    /// The generation of the newest stored frame (0 before the first one).
    public var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    private static func nextGeneration() -> UInt64 {
        generationLock.withLock {
            lastGeneration += 1
            return lastGeneration
        }
    }

    private func store(_ frame: Frame) {
        generation = Self.nextGeneration()
        var stamped = frame
        stamped.generation = generation
        latest = stamped
        size = (frame.width, frame.height)
    }

    public func take() -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        let frame = latest
        latest = nil
        return frame
    }

    /// The most recent frame without consuming it. Renderers use this so a
    /// re-created view can immediately redraw the last frame.
    public var current: Frame? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    public var currentSize: (width: Int, height: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return size
    }
}

/// Keeps one `FrameStore.observe` observer registered; it is removed by
/// `cancel()` or when the observation is released.
public final class FrameObservation: Sendable {
    private let store: FrameStore
    private let id: UInt64

    fileprivate init(store: FrameStore, id: UInt64) {
        self.store = store
        self.id = id
    }

    /// Stops the observer. Idempotent.
    public func cancel() {
        store.removeObserver(id)
    }

    deinit {
        store.removeObserver(id)
    }
}
