import CoreGraphics

/// Maps a point of the stage (normalized 0...1 of the frame, in the phone's
/// current interface orientation) to the touch panel's normalized point, the
/// coordinates the fast input helper takes. The panel is portrait, top-left
/// origin, whatever the interface orientation; which rotation each landscape
/// or upside-down pose needs is `rotation(for:)`, the one table to set from
/// the live measurement (`FastInputLiveTests.testLandscapePanelMapping`).
public enum FastInputPanelMapping {
    /// How a stage point (u, v) becomes a panel point.
    public enum Rotation: String, CaseIterable, Sendable {
        case identity
        /// (u, v) -> (1 - v, u)
        case clockwise90
        /// (u, v) -> (v, 1 - u)
        case counterClockwise90
        /// (u, v) -> (1 - u, 1 - v)
        case turn180

        public func apply(_ p: CGPoint) -> CGPoint {
            switch self {
            case .identity: p
            case .clockwise90: CGPoint(x: 1 - p.y, y: p.x)
            case .counterClockwise90: CGPoint(x: p.y, y: 1 - p.x)
            case .turn180: CGPoint(x: 1 - p.x, y: 1 - p.y)
            }
        }
    }

    /// The rotation for an interface orientation; nil for a pose that says nothing
    /// (flat, unknown). Portrait, landscape left and right are measured
    /// (`FastInputLiveTests.testLandscapePanelMapping`). Upside down is the
    /// geometric half turn, not measured through the HID path: a Face ID iPhone never shows an upside-down
    /// interface, but the stage turns (frame and panel picture) and the tracker
    /// (`PhysicalInterfaceOrientationTracker`) reports the pose. The inverse turns the panel image
    /// upright (`PhysicalStageRotation`).
    public static func rotation(for orientation: PhysicalControlOrientation) -> Rotation? {
        switch orientation {
        case .portrait: .identity
        case .landscapeLeft: .clockwise90
        case .landscapeRight: .counterClockwise90
        case .portraitUpsideDown: .turn180
        case .faceUp, .faceDown, .unknown: nil
        }
    }

    /// Whether a frame of this size can be the stage of `orientation`
    /// (landscape poses are wider than tall, the others are not).
    public static func frame(_ frame: CGSize, fits orientation: PhysicalControlOrientation) -> Bool {
        switch orientation {
        case .landscapeLeft, .landscapeRight: frame.width > frame.height
        case .portrait, .portraitUpsideDown: frame.width <= frame.height
        case .faceUp, .faceDown, .unknown: false
        }
    }

    /// The panel point for a normalized stage point; nil when the pose is
    /// unknown or the frame's aspect contradicts it.
    public static func panelPoint(_ point: CGPoint, frame: CGSize, orientation: PhysicalControlOrientation) -> CGPoint? {
        guard let rotation = rotation(for: orientation), Self.frame(frame, fits: orientation) else { return nil }
        return rotation.apply(point)
    }
}
