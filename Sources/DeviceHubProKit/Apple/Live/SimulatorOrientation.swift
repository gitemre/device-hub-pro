import Foundation

/// A device orientation to put a simulator in, named the way
/// `devicectl device orientation set` names it: the physical pose, so
/// `landscapeLeft` is the device turned a quarter counter-clockwise (its top
/// edge, with the Dynamic Island, on the left).
///
/// An iPhone with Face ID never shows its interface upside down: asked for
/// `portraitUpsideDown`, it keeps the interface where it was.
public enum SimulatorOrientation: String, Sendable, CaseIterable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    /// The value the device-orientation GSEvent carries
    /// (`SimulatorGSEventBridging.sendOrientation`). PRIVATE-API CoreSimulator
    /// 1171.7: GSEvent 3 and devicectl's `landscapeLeft` both made an iOS 27.0
    /// iPhone report `uiOrientation` 4 with the Dynamic Island on the left
    /// (`Fixtures/ios27-simulator/bridge/orientation-uiOrientation.txt`).
    public var gsEventValue: UInt32 {
        switch self {
        case .portrait: return 1
        case .portraitUpsideDown: return 2
        case .landscapeLeft: return 3
        case .landscapeRight: return 4
        }
    }
}

/// How the simulator's framebuffer, which stays in the panel's native
/// portrait whatever the interface does, turns into the upright picture the
/// user sees, for the `uiOrientation` the screen reports.
///
/// The session publishes the upright picture (the scrcpy contract: frames are
/// display-oriented, `Frame.rotation` 0) and maps input back to native ratios
/// through the same rotation. Measured on iOS 27.0 (the bridge fixture):
/// with `uiOrientation` 3 the content's top faces the panel's left edge, with
/// 4 its right edge.
public enum SimulatorFrameRotation: Sendable, Equatable, CaseIterable {
    /// `uiOrientation` 1, and any value CoreSimulator did not document (0).
    case upright
    /// `uiOrientation` 2: the native buffer turned half a turn.
    case upsideDown
    /// `uiOrientation` 3: the native buffer turned a quarter clockwise.
    case clockwise
    /// `uiOrientation` 4: the native buffer turned a quarter counter-clockwise.
    case counterClockwise

    public init(uiOrientation: UInt32) {
        switch uiOrientation {
        case 2: self = .upsideDown
        case 3: self = .clockwise
        case 4: self = .counterClockwise
        default: self = .upright
        }
    }

    /// Whether the displayed frame swaps the native width and height.
    public var swapsAxes: Bool {
        self == .clockwise || self == .counterClockwise
    }

    /// The displayed frame's size for a native framebuffer of this size.
    public func displaySize(nativeWidth: Int, nativeHeight: Int) -> (width: Int, height: Int) {
        swapsAxes ? (nativeHeight, nativeWidth) : (nativeWidth, nativeHeight)
    }

    /// Where the native pixel (`x`, `y`) lands in the displayed frame.
    public func displayPixel(nativeX x: Int, nativeY y: Int, nativeWidth: Int, nativeHeight: Int) -> (x: Int, y: Int) {
        switch self {
        case .upright: return (x, y)
        case .upsideDown: return (nativeWidth - 1 - x, nativeHeight - 1 - y)
        case .clockwise: return (nativeHeight - 1 - y, x)
        case .counterClockwise: return (y, nativeWidth - 1 - x)
        }
    }

    /// The native-portrait ratios (0...1) of the displayed-frame pixel
    /// (`x`, `y`), taken at the pixel's centre and clamped into the frame:
    /// what `SimulatorHIDEvent.touch` takes.
    public func nativeRatio(displayX x: Double, displayY y: Double, displayWidth: Int, displayHeight: Int) -> SimulatorTouchPoint {
        guard displayWidth > 0, displayHeight > 0 else { return SimulatorTouchPoint(x: 0.5, y: 0.5) }
        let u = Self.clamp((x + 0.5) / Double(displayWidth))
        let v = Self.clamp((y + 0.5) / Double(displayHeight))
        switch self {
        case .upright: return SimulatorTouchPoint(x: u, y: v)
        case .upsideDown: return SimulatorTouchPoint(x: 1 - u, y: 1 - v)
        case .clockwise: return SimulatorTouchPoint(x: v, y: 1 - u)
        case .counterClockwise: return SimulatorTouchPoint(x: 1 - v, y: u)
        }
    }

    /// The native panel edge that a displayed-frame edge is. The digitizer's
    /// `edge` field is native: in `.counterClockwise` a swipe up from the
    /// displayed bottom went Home only tagged `.left` (measured on iOS 27.0).
    public func nativeEdge(forDisplayEdge edge: SimulatorTouchEdge) -> SimulatorTouchEdge {
        guard edge != .none else { return .none }
        switch self {
        case .upright:
            return edge
        case .upsideDown:
            switch edge {
            case .top: return .bottom
            case .bottom: return .top
            case .left: return .right
            case .right: return .left
            case .none: return .none
            }
        case .clockwise:
            switch edge {
            case .top: return .left
            case .right: return .top
            case .bottom: return .right
            case .left: return .bottom
            case .none: return .none
            }
        case .counterClockwise:
            switch edge {
            case .top: return .right
            case .left: return .top
            case .bottom: return .left
            case .right: return .bottom
            case .none: return .none
            }
        }
    }

    /// The displayed-frame edge a point starting a contact is on: within
    /// `zone` pixels of it, the nearest edge wins; `.none` elsewhere.
    public static func displayEdge(x: Double, y: Double, width: Int, height: Int, zone: Double) -> SimulatorTouchEdge {
        guard width > 0, height > 0 else { return .none }
        let distances: [(SimulatorTouchEdge, Double)] = [
            (.top, y),
            (.bottom, Double(height - 1) - y),
            (.left, x),
            (.right, Double(width - 1) - x),
        ]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < zone else { return .none }
        return nearest.0
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
