import CoreGraphics
import Observation
import DeviceHubProKit

/// UI state that must survive SwiftUI view re-creation (window resize, entering
/// fullscreen, tab switches).
///
/// `devicePixelSize` is the streamed buffer size in pixels, published by the
/// renderer on the first frame. It drives the mirror's layout.
///
/// `deviceRotation` is the settled stream rotation (0...3). The stage's pose
/// animator follows it (`onSettledGeometry`); the renderer itself samples
/// with the rotation of the frame it draws, never with this lagging copy.
@Observable
final class MirrorViewState {
    var devicePixelSize: CGSize?
    var deviceRotation = 0

    /// The video's points per streamed pixel as the main stage last drew it
    /// (before the zoom animation's presentation scale); nil until the first
    /// draw. The stage zoom's steps, limits and Physical Size are counted in
    /// it (`ZoomMath`).
    private(set) var videoPointsPerPixel: Double?

    /// Stores a drawn scale, ignoring changes below a thousandth so a draw
    /// that lands on the same layout does not invalidate the views reading
    /// it.
    func publishVideoScale(_ scale: Double) {
        guard scale > 0 else { return }
        if let current = videoPointsPerPixel, abs(current - scale) <= scale * 0.001 { return }
        videoPointsPerPixel = scale
    }

    /// Invoked on the main thread in the same frame the settled geometry is
    /// committed, before SwiftUI re-renders. The stage's pose animator uses it
    /// to rebase its texture uprighting atomically with the layout swap; it
    /// must be idempotent because every mirror view reports.
    @ObservationIgnored var onSettledGeometry: ((Int) -> Void)?

    /// The mirrored display's size and density as the device reported them
    /// (`loadDisplayMetrics`); nil until read. Input reads it on demand, so
    /// it is not observed.
    @ObservationIgnored private(set) var displayMetrics: MirrorDisplayMetrics?
    /// `displayMetrics`' density, observed: the vector body plans with it
    /// when no reported display fits the frame, so a body planned at the
    /// default density before `wm density` answered is planned again when
    /// it does (its bezel width, and the phone or tablet line, follow the
    /// density).
    private(set) var displayDensityDpi: Int?
    /// The stream size when `displayMetrics` was read: metrics that do not
    /// fit the frame they were read under are not read again for it.
    @ObservationIgnored private var displayMetricsFrame: CGSize?
    /// The read of `displayMetrics` in flight, shared by the mirror views
    /// showing this mirror session (main stage, compact window). True once it
    /// stored metrics.
    @ObservationIgnored private var displayMetricsRead: Task<Bool, Never>?

    /// Reads the display metrics with `read` unless the known ones fit the
    /// frame being streamed.
    ///
    /// The read runs in its own task, which a caller joins rather than owns:
    /// a view's request is superseded (and cancelled) as soon as the first
    /// frame settles, and cancelling the adb read there would leave the
    /// metrics unread while the newer request waits on it. Metrics read
    /// before the stream changed shape (a foldable switching screens) are
    /// read once more.
    @MainActor
    func loadDisplayMetrics(reading read: @escaping @Sendable () async -> MirrorDisplayMetrics?) async {
        for _ in 0..<2 {
            if let inFlight = displayMetricsRead {
                guard await inFlight.value else { return }
                continue
            }
            if let metrics = displayMetrics {
                guard let frame = devicePixelSize,
                      metrics.pixelsPerDp(frame: frame) == nil,
                      frame != displayMetricsFrame
                else { return }
            }
            let streamed = devicePixelSize
            let task = Task { @MainActor [weak self] in
                let metrics = await read()
                guard let self else { return false }
                displayMetricsRead = nil
                guard let metrics else { return false }
                displayMetrics = metrics
                displayMetricsFrame = streamed
                if displayDensityDpi != metrics.dpi {
                    displayDensityDpi = metrics.dpi
                }
                return true
            }
            displayMetricsRead = task
            guard await task.value else { return }
        }
    }

    /// Every display the device lists, with its corner radii and cutout, as
    /// this mirror session's `dumpsys display` reported them (`loadDisplayShapes`);
    /// empty until read. Observed: the framed stage clips the screen to the
    /// one matching the streamed frame.
    private(set) var displayShapes: [DisplayShape] = []
    /// The stream size when `displayShapes` was read.
    @ObservationIgnored private var displayShapesFrame: CGSize?
    /// The read of `displayShapes` in flight, joined like `displayMetricsRead`.
    @ObservationIgnored private var displayShapesRead: Task<Bool, Never>?

    /// Reads the display shapes with `read` unless one of the known ones
    /// fits the frame being streamed.
    ///
    /// One read serves the whole session: it lists every panel, so a
    /// foldable switching screens finds the other one in the same list. It
    /// is read again only for a frame no listed display fits, once per such
    /// frame. The read is joined, not owned, for the same reason as
    /// `loadDisplayMetrics`'s.
    @MainActor
    func loadDisplayShapes(reading read: @escaping @Sendable () async -> [DisplayShape]) async {
        for _ in 0..<2 {
            if let inFlight = displayShapesRead {
                guard await inFlight.value else { return }
                continue
            }
            if !displayShapes.isEmpty {
                guard let frame = devicePixelSize,
                      DisplayShape.matching(frame: frame, in: displayShapes) == nil,
                      frame != displayShapesFrame
                else { return }
            }
            let streamed = devicePixelSize
            let task = Task { @MainActor [weak self] in
                let shapes = await read()
                guard let self else { return false }
                displayShapesRead = nil
                // An empty list is a failed read: the next request retries.
                guard !shapes.isEmpty else { return false }
                displayShapes = shapes
                displayShapesFrame = streamed
                return true
            }
            displayShapesRead = task
            guard await task.value else { return }
        }
    }

    /// The display's rotation (`Surface.ROTATION_*`, 0...3) as the device
    /// last reported it (`loadDisplayRotation`); nil until read. Observed: a
    /// phone's posed frames carry no rotation of their own, and the vector
    /// body turns its cutout by this.
    private(set) var displayRotation: Int?
    /// Whether the settled frame was landscape when `displayRotation` was
    /// read.
    @ObservationIgnored private var displayRotationIsLandscape: Bool?
    /// When the last read of the rotation ended, answered or failed, and
    /// whether the settled frame was landscape then: a refresh
    /// (`loadDisplayRotation(refreshingAfter:)`) is not repeated sooner.
    @ObservationIgnored private var displayRotationReadEnded: (at: ContinuousClock.Instant, isLandscape: Bool)?
    /// The read of `displayRotation` in flight, joined like
    /// `displayMetricsRead`.
    @ObservationIgnored private var displayRotationRead: Task<Bool, Never>?

    /// Reads the display rotation with `read` for the settled frame, unless
    /// the known one still stands.
    ///
    /// Nothing is read before a frame settles: the rotation belongs to the
    /// orientation the frame shows. A plain request reads only when none is
    /// known for the frame's orientation: first, and whenever the frame
    /// turns between portrait and landscape. A turn by 180° keeps the frame's
    /// size, so the stream shows nothing of it (scrcpy re-frames only when
    /// the display's size changes); a request with `refreshingAfter` reads
    /// again anyway once the last read for this orientation, answered or
    /// failed, is that old, which is how the phone's watch
    /// (`MirrorController.watchDisplayRotation`) finds such a turn, and it
    /// keeps a second view's watch from reading the same rotation twice.
    ///
    /// The read is joined, not owned, for the same reason as
    /// `loadDisplayMetrics`'s, and a frame that turned while it ran is read
    /// for once more. A failed read leaves the last value.
    @MainActor
    func loadDisplayRotation(
        refreshingAfter maxAge: Duration? = nil,
        reading read: @escaping @Sendable () async -> Int?
    ) async {
        var maxAge = maxAge
        for _ in 0..<2 {
            if let inFlight = displayRotationRead {
                guard await inFlight.value else { return }
                // A read just ended: only a turn of the frame reads again.
                maxAge = nil
                continue
            }
            guard let frame = devicePixelSize else { return }
            let isLandscape = frame.width > frame.height
            if let maxAge {
                if let ended = displayRotationReadEnded,
                   ended.isLandscape == isLandscape,
                   ended.at.duration(to: .now) < maxAge
                {
                    return
                }
            } else if displayRotation != nil, displayRotationIsLandscape == isLandscape {
                return
            }
            let task = Task { @MainActor [weak self] in
                let rotation = await read()
                guard let self else { return false }
                displayRotationRead = nil
                displayRotationReadEnded = (.now, isLandscape)
                guard let rotation else { return false }
                let normalized = TextureRotation.normalized(rotation)
                // Unchanged, it is not set again: a refresh that finds the
                // same turn must not redraw the stage.
                if displayRotation != normalized {
                    displayRotation = normalized
                }
                displayRotationIsLandscape = isLandscape
                return true
            }
            displayRotationRead = task
            guard await task.value else { return }
            maxAge = nil
        }
    }
}

/// A display's size and density as the device reports them (`wm size`,
/// `wm density`; an override wins, as that is what apps see). It turns dp
/// distances into frame pixels at whatever size the display is streamed.
struct MirrorDisplayMetrics: Equatable, Sendable {
    /// Pixels, in the display's natural orientation.
    var width: Int
    var height: Int
    /// Dots per inch; 160 is one pixel per dp.
    var dpi: Int

    /// How far a frame's aspect ratio may stray from the display's and still
    /// show it: a downscaled stream rounds its sides (scrcpy to multiples of
    /// 8), while a foldable's other screen differs by far more.
    static let shapeTolerance: CGFloat = 0.03

    init(width: Int, height: Int, dpi: Int) {
        self.width = width
        self.height = height
        self.dpi = dpi
    }

    /// Parses the output of `wm size` and `wm density`, run in one shell.
    init?(wmOutput output: String) {
        guard let size = PhysicalInput.parseDisplaySize(fromWmSize: output),
              let dpi = Self.parseDensity(fromWmDensity: output)
        else {
            return nil
        }
        self.init(width: size.width, height: size.height, dpi: dpi)
    }

    /// The density `wm density` reports: the override when one is set (it
    /// is what apps see), else the physical density. Lines of other
    /// commands' output (`wm size`) are skipped.
    static func parseDensity(fromWmDensity output: String) -> Int? {
        var physical: Int?
        var override: Int?
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let value = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                  value > 0
            else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            if label.hasPrefix("override") {
                override = value
            } else if label.hasPrefix("physical") {
                physical = value
            }
        }
        return override ?? physical
    }

    /// Frame pixels per dp for a frame showing this display, in either
    /// orientation and at any stream scale; nil when the frame has another
    /// shape (a foldable showing its other screen), so the caller estimates.
    func pixelsPerDp(frame: CGSize) -> CGFloat? {
        let displayShort = CGFloat(min(width, height))
        let displayLong = CGFloat(max(width, height))
        let frameShort = min(frame.width, frame.height)
        let frameLong = max(frame.width, frame.height)
        guard displayShort > 0, frameShort > 0, dpi > 0 else { return nil }
        let shape = (frameLong / frameShort) / (displayLong / displayShort)
        guard abs(shape - 1) <= Self.shapeTolerance else { return nil }
        return frameShort / displayShort * CGFloat(dpi) / 160
    }
}
