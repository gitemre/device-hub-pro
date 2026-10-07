import Foundation

/// Settles the live display geometry from the frame stream.
///
/// Around an orientation change or posture switch the emulator can emit a
/// frame whose size and rotation disagree for a beat (the metadata lags the
/// buffer). A single such frame must not flip the UI: a new geometry is only
/// accepted once it repeats on consecutive frames. Requiring repetition
/// instead of a rotation-parity rule also accepts landscape-native poses —
/// an opened foldable is landscape at rotation 0, which a parity rule
/// rejects forever, freezing the layout on a stale size.
public struct SettledGeometry: Sendable, Hashable {
    /// Last accepted size, in pixels.
    public private(set) var size: CGSize?
    /// Last accepted rotation (0...3).
    public private(set) var rotation: Int = 0

    private var pending: Geometry?
    private var pendingCount = 0

    public init() {}

    private struct Geometry: Sendable, Hashable {
        var width: Int
        var height: Int
        var rotation: Int
    }

    /// Observes one frame. Returns true when the settled geometry changed
    /// and the UI should re-read `size`/`rotation`.
    @discardableResult
    public mutating func observe(width: Int, height: Int, rotation: Int) -> Bool {
        let seen = Geometry(width: width, height: height, rotation: rotation)
        if let size,
           seen == Geometry(
               width: Int(size.width),
               height: Int(size.height),
               rotation: self.rotation
           )
        {
            // Still settled: drop any half-seen flap.
            pending = nil
            pendingCount = 0
            return false
        }
        if size == nil {
            // First frame ever: accept immediately, there is nothing stale
            // to protect.
            commit(seen)
            return true
        }
        if pending == seen {
            pendingCount += 1
        } else {
            pending = seen
            pendingCount = 1
        }
        if pendingCount >= 2 {
            commit(seen)
            pending = nil
            pendingCount = 0
            return true
        }
        return false
    }

    private mutating func commit(_ geometry: Geometry) {
        size = CGSize(width: geometry.width, height: geometry.height)
        rotation = geometry.rotation
    }
}
