import CoreGraphics
import Foundation

/// How a picture is turned: the quarter turns its frame carried and whether
/// it is wider than tall. A remembered picture is only drawn again for a
/// stage at the same pose.
public struct PicturePose: Hashable, Sendable {
    public let rotation: Int
    public let isLandscape: Bool

    public init(rotation: Int, isLandscape: Bool) {
        self.rotation = rotation
        self.isLandscape = isLandscape
    }

    public init(frame: Frame) {
        self.init(rotation: frame.rotation, isLandscape: frame.width > frame.height)
    }

    /// Upright and tall: the pose a physical view's stage starts in.
    public static let portrait = PicturePose(rotation: 0, isLandscape: false)
}

/// The last picture one device showed, shrunk, with the size the stream had.
public struct RememberedPicture: Sendable {
    /// The picture as RGBA bytes at its shrunk size (`frame.width` x `frame.height`).
    public let frame: Frame
    /// The pixel size of the frame this was made from: the stage sizes the
    /// device's frame from it, not from the shrunk copy.
    public let fullSize: CGSize
    public let pose: PicturePose
    /// Tells two remembered pictures apart (a later one of the same device
    /// has another id).
    public let id: UInt64
}

/// The last frame each device showed, in memory only, so a stage that starts
/// a session for the device draws it until the first new frame arrives
/// instead of an empty screen. Holds at most `capacity` devices, the least
/// recently used going first; each picture is shrunk to `maxSide` on its
/// long side, so the whole cache stays a few megabytes.
public final class LastPictureCache: @unchecked Sendable {
    public static let defaultCapacity = 4
    public static let defaultMaxSide = 960

    private let capacity: Int
    private let maxSide: Int
    private let lock = NSLock()
    private var pictures: [String: RememberedPicture] = [:]
    /// Keys, least recently used first.
    private var order: [String] = []
    private var nextID: UInt64 = 0

    public init(capacity: Int = LastPictureCache.defaultCapacity, maxSide: Int = LastPictureCache.defaultMaxSide) {
        self.capacity = max(capacity, 1)
        self.maxSide = max(maxSide, 1)
    }

    /// The device keys held, most recently used first.
    public var keys: [String] {
        lock.withLock { order.reversed() }
    }

    /// Remembers `frame` as `key`'s picture, shrunk. A frame whose bytes do
    /// not fit its size is not kept (and the earlier picture stays).
    public func remember(_ frame: Frame, for key: String) {
        guard frame.width > 0, frame.height > 0,
              let shrunk = Self.shrunk(frame, maxSide: maxSide)
        else { return }
        lock.withLock {
            nextID += 1
            pictures[key] = RememberedPicture(
                frame: shrunk,
                fullSize: CGSize(width: frame.width, height: frame.height),
                pose: PicturePose(frame: frame),
                id: nextID
            )
            touch(key)
            while order.count > capacity {
                pictures[order.removeFirst()] = nil
            }
        }
    }

    /// `key`'s picture when it was taken at `pose`; nil when none is
    /// remembered or the device has turned since (a landscape picture would
    /// show sideways in an upright frame). Asking counts as a use.
    public func picture(for key: String, matching pose: PicturePose) -> RememberedPicture? {
        lock.withLock {
            guard let picture = pictures[key], picture.pose == pose else { return nil }
            touch(key)
            return picture
        }
    }

    public func forget(_ key: String) {
        lock.withLock {
            pictures[key] = nil
            order.removeAll { $0 == key }
        }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// `frame` at no more than `maxSide` pixels on its long side, as RGBA
    /// bytes in a plain byte frame; nil when its bytes do not fit its size.
    static func shrunk(_ frame: Frame, maxSide: Int) -> Frame? {
        let data = frame.data
        let bytesPerRow = frame.width * 4
        guard data.count >= bytesPerRow * frame.height else { return nil }
        let longSide = max(frame.width, frame.height)
        guard longSide > maxSide else {
            return Frame(data: data, width: frame.width, height: frame.height, seq: 0, rotation: frame.rotation)
        }
        let scale = Double(maxSide) / Double(longSide)
        let width = max(Int((Double(frame.width) * scale).rounded()), 1)
        let height = max(Int((Double(frame.height) * scale).rounded()), 1)
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: frame.width, height: frame.height,
                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                  space: space, bitmapInfo: CGBitmapInfo(rawValue: bitmap),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ),
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: space, bitmapInfo: bitmap
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.data else { return nil }
        let bytes = Data(bytes: base, count: width * 4 * height)
        return Frame(data: bytes, width: width, height: height, seq: 0, rotation: frame.rotation)
    }
}
