/// Which mirror frames the frame feed stages for its consumers (the replay
/// ring and the recorder), and when the replay ring is rebuilt.
///
/// A frame is fed once: a repeat of the last staged generation is skipped.
/// While more than ``stagingLimit`` conversions are pending on the feed
/// queue the frame is dropped, and a dropped frame stays un-fed so a static
/// screen's only frame is offered again on the next tick. The ring is
/// rebuilt when replay is on and there is none yet or the frame size
/// changed.
///
/// `MediaCaptureController` runs every poll tick's frame through its
/// `admission`; the ring, the pool and the feed queue stay with the
/// controller.
struct FeedAdmission: Equatable, Sendable {
    /// How many RGBA→BGRA conversions may be pending on the feed queue
    /// before the poll drops frames instead of staging more full-frame
    /// `Data`.
    static let stagingLimit = 2

    /// A frame's pixel size.
    struct PixelSize: Equatable, Sendable {
        let width: Int
        let height: Int
    }

    /// The generation of the last staged frame; nil when the next frame
    /// counts as new whatever its generation.
    private(set) var lastGeneration: UInt64?
    /// The size the current replay ring was built for.
    private(set) var ringSize: PixelSize?
    /// Conversions queued or executing on the feed queue. Deliberately
    /// never reset when the feed restarts: conversions from the previous
    /// run still decrement it, so a reset would transiently over-admit.
    private(set) var pending = 0

    init() {}

    /// Backpressure for the feed queue: one more frame may be staged while
    /// at most ``stagingLimit`` conversions are pending.
    static func stagingAccepts(pending: Int) -> Bool {
        pending <= stagingLimit
    }

    /// Whether a frame is worth feeding: it has pixels and is not the frame
    /// fed last.
    func isNew(width: Int, height: Int, generation: UInt64) -> Bool {
        width > 0 && height > 0 && generation != lastGeneration
    }

    /// Whether the replay ring must be (re)built for a frame of this size:
    /// replay is on and there is no ring yet (`hasRing`) or it was built for
    /// another size. Records the new ring's size when it must.
    mutating func ringNeedsRebuild(replayEnabled: Bool, hasRing: Bool, width: Int, height: Int) -> Bool {
        guard replayEnabled,
              !hasRing
                || ringSize?.width != width
                || ringSize?.height != height
        else { return false }
        ringSize = PixelSize(width: width, height: height)
        return true
    }

    /// Admits a new frame for one conversion when something consumes it and
    /// the queue has room. An admitted frame is recorded as fed and counted
    /// pending until `conversionFinished()`; a refused one is left un-fed.
    mutating func stage(generation: UInt64, hasConsumer: Bool) -> Bool {
        guard hasConsumer else { return false }
        guard Self.stagingAccepts(pending: pending) else { return false }
        lastGeneration = generation
        pending += 1
        return true
    }

    /// One staged conversion finished (or was abandoned); never below zero.
    mutating func conversionFinished() {
        pending = max(0, pending - 1)
    }

    /// The ring was dropped: the next frame builds a fresh one, and counts
    /// as new. Pending conversions are kept.
    mutating func resetRing() {
        ringSize = nil
        lastGeneration = nil
    }

    /// A recording started: the current frame is offered again, since on a
    /// static screen it is the only one the recorder would get.
    mutating func offerCurrentFrameAgain() {
        lastGeneration = nil
    }
}
