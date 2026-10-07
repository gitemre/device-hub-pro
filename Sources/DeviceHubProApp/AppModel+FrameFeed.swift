import CoreVideo

/// A `CVPixelBufferPool` of one BGRA size, for the mirror's frame feed
/// (replay ring and recorder). The feed converts every fed frame; drawing
/// the destination from a pool reuses IOSurface-backed buffers instead of
/// allocating one per frame (~10 MB each on a 1080×2400 panel).
///
/// `@unchecked Sendable` because `CVPixelBufferPool` is not annotated: the
/// fields never change after `init`, and CoreVideo pools are
/// safe to draw from on any thread — the feed queue draws while the main
/// actor may already have made the next size's pool.
final class BGRAPixelBufferPool: @unchecked Sendable {
    let width: Int
    let height: Int
    private let pool: CVPixelBufferPool

    init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            Self.attributes(width: width, height: height) as CFDictionary,
            &pool
        ) == kCVReturnSuccess, let pool else {
            return nil
        }
        self.width = width
        self.height = height
        self.pool = pool
    }

    /// A buffer from the pool; nil when CoreVideo has none to give.
    func makeBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess
        else { return nil }
        return buffer
    }

    /// A one-off buffer of the same kind, for when no pool could be made.
    static func makeUnpooledBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &buffer
        ) == kCVReturnSuccess else { return nil }
        return buffer
    }

    private static func attributes(width: Int, height: Int) -> [CFString: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
    }
}
