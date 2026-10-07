import Accelerate
import CoreVideo
import Foundation
import IOSurface

/// Copies a simulator's live framebuffer into a pooled, IOSurface-backed
/// 32BGRA pixel buffer, turned upright on the way (`SimulatorFrameRotation`).
///
/// CoreSimulator rewrites the one framebuffer in place for every frame, so a
/// copy can catch a frame half written. The copier reads the surface's seed
/// when it locks the surface and again after the copy; when the seed moved it
/// copies once more, and if it moved again it hands the copy over marked
/// torn (the next frame callback follows right behind such a write, so the
/// session republishes soon).
///
/// Not thread-safe: one session queue owns it.
final class SimulatorFrameCopier {
    struct Outcome {
        let buffer: CVPixelBuffer
        let rotation: SimulatorFrameRotation
        /// The whole copy (both attempts when retried), in milliseconds.
        let milliseconds: Double
        /// The first copy saw the seed move and was done again.
        let retried: Bool
        /// The seed moved during the second copy too.
        let torn: Bool
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case unsupportedPixelFormat(OSType)
        case emptySurface
        case poolFailed(CVReturn)
        case lockFailed(Int32)
        case rotateFailed(Int)

        var description: String {
            switch self {
            case .unsupportedPixelFormat(let format):
                return String(format: "the simulator framebuffer has pixel format 0x%08x, not 32BGRA", format)
            case .emptySurface: return "the simulator framebuffer is empty"
            case .poolFailed(let status): return "no pixel buffer for the frame (CVReturn \(status))"
            case .lockFailed(let status): return "could not lock a frame buffer (\(status))"
            case .rotateFailed(let status): return "vImage could not turn the frame (\(status))"
            }
        }
    }

    /// Buffers the pool keeps ready: one being filled, one in the store, one
    /// in the renderer's hands.
    static let minimumPooledBuffers = 3

    /// Test seam: runs after each copy attempt (1 or 2), once the surface is
    /// unlocked and before its seed is read again. A test writes to the
    /// surface here to make the copy look torn.
    var afterCopyAttempt: ((IOSurface, Int) -> Void)?

    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    func copy(_ surface: IOSurface, rotation: SimulatorFrameRotation) throws -> Outcome {
        let started = DispatchTime.now().uptimeNanoseconds
        guard surface.pixelFormat == kCVPixelFormatType_32BGRA else {
            throw Failure.unsupportedPixelFormat(surface.pixelFormat)
        }
        let nativeWidth = surface.width
        let nativeHeight = surface.height
        guard nativeWidth > 0, nativeHeight > 0 else { throw Failure.emptySurface }
        let size = rotation.displaySize(nativeWidth: nativeWidth, nativeHeight: nativeHeight)
        let buffer = try makeBuffer(width: size.width, height: size.height)

        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        guard lockStatus == kCVReturnSuccess else { throw Failure.lockFailed(lockStatus) }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.lockFailed(kCVReturnInvalidArgument) }
        let destinationRowBytes = CVPixelBufferGetBytesPerRow(buffer)

        var retried = false
        var torn = false
        for attempt in 1...2 {
            var seedBefore: UInt32 = 0
            let status = surface.lock(options: .readOnly, seed: &seedBefore)
            guard status == KERN_SUCCESS else { throw Failure.lockFailed(status) }
            let copyError = Self.copyPixels(
                from: surface.baseAddress,
                rowBytes: surface.bytesPerRow,
                width: nativeWidth,
                height: nativeHeight,
                to: destination,
                rowBytes: destinationRowBytes,
                rotation: rotation
            )
            surface.unlock(options: .readOnly, seed: nil)
            if let copyError { throw copyError }
            afterCopyAttempt?(surface, attempt)
            if surface.seed == seedBefore { break }
            if attempt == 1 {
                retried = true
            } else {
                torn = true
            }
        }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        return Outcome(buffer: buffer, rotation: rotation, milliseconds: milliseconds, retried: retried, torn: torn)
    }

    /// Copies (upright) or turns (the others) one BGRA image into another.
    /// The destination must have the displayed size.
    static func copyPixels(
        from source: UnsafeMutableRawPointer,
        rowBytes sourceRowBytes: Int,
        width: Int,
        height: Int,
        to destination: UnsafeMutableRawPointer,
        rowBytes destinationRowBytes: Int,
        rotation: SimulatorFrameRotation
    ) -> Failure? {
        let rowLength = width * 4
        if rotation == .upright {
            if sourceRowBytes == destinationRowBytes {
                memcpy(destination, source, sourceRowBytes * height)
            } else {
                for row in 0..<height {
                    memcpy(destination + row * destinationRowBytes, source + row * sourceRowBytes, rowLength)
                }
            }
            return nil
        }
        let displayed = rotation.displaySize(nativeWidth: width, nativeHeight: height)
        var sourceBuffer = vImage_Buffer(
            data: source,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: sourceRowBytes
        )
        var destinationBuffer = vImage_Buffer(
            data: destination,
            height: vImagePixelCount(displayed.height),
            width: vImagePixelCount(displayed.width),
            rowBytes: destinationRowBytes
        )
        let constant: Int
        switch rotation {
        case .upright: constant = kRotate0DegreesClockwise
        case .upsideDown: constant = kRotate180DegreesClockwise
        case .clockwise: constant = kRotate90DegreesClockwise
        case .counterClockwise: constant = kRotate90DegreesCounterClockwise
        }
        var background: [UInt8] = [0, 0, 0, 0xFF]
        let error = vImageRotate90_ARGB8888(&sourceBuffer, &destinationBuffer, UInt8(constant), &background, vImage_Flags(kvImageNoFlags))
        return error == kvImageNoError ? nil : .rotateFailed(error)
    }

    private func makeBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        if pool == nil || poolWidth != width || poolHeight != height {
            // A rotation changes the size: the old pool's buffers are dropped
            // as their frames go.
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            let poolAttributes: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: Self.minimumPooledBuffers]
            var created: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(nil, poolAttributes as CFDictionary, attributes as CFDictionary, &created)
            guard status == kCVReturnSuccess, let created else { throw Failure.poolFailed(status) }
            pool = created
            poolWidth = width
            poolHeight = height
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw Failure.poolFailed(status) }
        return buffer
    }
}
