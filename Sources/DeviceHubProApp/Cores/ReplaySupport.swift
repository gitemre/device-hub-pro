import CoreGraphics

/// Which devices keep a replay ring ("Save the last N seconds"), and the
/// size it encodes at.
///
/// An Android device (emulator or phone) keeps one from its mirror's frames;
/// a simulator on the live canvas keeps one from the canvas's frames. The
/// view-only simulator canvas (a screenshot about once a second) has nothing
/// worth a replay, and a physical iPhone's view is out of scope: both hide
/// the button and the menu items, and their feed never fills a ring.
enum ReplaySupport {
    /// The kind of device whose mirror is attached.
    enum DeviceKind: Equatable, Sendable {
        case none
        case android
        case simulatorLive
        case simulatorViewOnly
        case physicalApple
    }

    /// Whether `kind` keeps a ring while the Settings switch is `enabled`.
    static func isOffered(kind: DeviceKind, enabled: Bool) -> Bool {
        guard enabled else { return false }
        switch kind {
        case .android, .simulatorLive: return true
        case .none, .simulatorViewOnly, .physicalApple: return false
        }
    }

    /// The pixel size a simulator's frame is encoded at: scaled down to fit
    /// 1080 × 1920 (portrait or landscape), never up. Android frames keep
    /// their size (the existing behaviour).
    static func encodedSize(width: Int, height: Int, kind: DeviceKind) -> (width: Int, height: Int) {
        guard kind == .simulatorLive, width > 0, height > 0 else { return (width, height) }
        let longLimit = 1920.0, shortLimit = 1080.0
        let long = Double(max(width, height)), short = Double(min(width, height))
        let scale = min(1.0, longLimit / long, shortLimit / short)
        guard scale < 1 else { return (width, height) }
        // H.264 wants even dimensions.
        func even(_ value: Int) -> Int { max(2, Int((Double(value) * scale / 2).rounded()) * 2) }
        return (even(width), even(height))
    }

    /// Whether the feed may hand frames to the ring: a hidden or occluded
    /// window pauses it (nothing is encoded for a screen nobody sees),
    /// unless a recording needs the feed anyway.
    static func feedsRing(isStageVisible: Bool, isRecording: Bool) -> Bool {
        isStageVisible || isRecording
    }

    /// The tooltip of the pill's Save Replay button.
    static func tooltip(windowSeconds: Double) -> String {
        "Save the last \(Int(windowSeconds)) seconds (⌥⌘R)"
    }

    /// The one-time hint's text.
    static func hintText(windowSeconds: Double) -> String {
        "Missed a bug? Save the last \(Int(windowSeconds)) seconds."
    }
}
