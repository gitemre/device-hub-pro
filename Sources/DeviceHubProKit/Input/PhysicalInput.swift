import Foundation

/// A completed device gesture that `adb shell input` can express.
public enum PhysicalGesture: Equatable, Sendable {
    case tap(x: Int32, y: Int32)
    case swipe(fromX: Int32, fromY: Int32, toX: Int32, toY: Int32, durationMs: Int)
}

/// Turns the stage's contact-frame stream into `PhysicalGesture`s.
///
/// The stage emits one frame per input event (a `down`, then `move`s, then an
/// `up`), but `adb shell input` cannot stream a gesture: each invocation
/// spawns a device-side JVM, and a gesture must arrive as one `tap`/`swipe`
/// command. This tracker therefore accumulates the frames between `down` and
/// `up` and emits the whole gesture on release.
///
/// Multi-contact frames (the trackpad pinch and Option+drag gestures in
/// `MirrorInputController`) have no `adb shell input` representation — the
/// command takes a single pointer — so they are dropped here. This tracker
/// only serves the `adb shell input` fallback; the scrcpy control socket
/// streams every contact, multi-touch included (``PhysicalInput``).
public struct PhysicalGestureTracker: Sendable {
    /// Travel within this many device pixels (and under the long-press
    /// threshold) is a tap; a larger stroke is a swipe. Android apps apply
    /// their own touch slop, so borderline strokes still read as taps there.
    public static let tapSlop: Double = 10
    /// A still gesture held at least this long is replayed as a same-point
    /// swipe of the measured duration, which Android turns into a long press.
    public static let longPressSeconds: TimeInterval = 0.5
    /// A replayed swipe never runs longer than this; the gesture was already
    /// shown late (it is emitted on release), and an over-long replay would
    /// stall the next gesture behind it.
    public static let maximumSwipeMs = 3_000

    private struct Active {
        let startX: Int32
        let startY: Int32
        var lastX: Int32
        var lastY: Int32
        var traveled: Double
        let startedAt: Date
        /// Set when a multi-contact frame joins the gesture: no `input`
        /// command can finish it, so the release emits nothing.
        var expressible: Bool
    }

    private var active: Active?

    public init() {}

    /// Feeds one input frame (all contacts of one stage event) and returns the
    /// completed gesture when this frame released one.
    public mutating func accept(
        _ contacts: [TouchCommand],
        at time: Date = Date()
    ) -> PhysicalGesture? {
        guard !contacts.isEmpty else { return nil }

        guard contacts.count == 1, let contact = contacts.first else {
            // Pinch/zoom: not expressible through `adb shell input`. Mark the
            // in-flight gesture so its release is swallowed too.
            active?.expressible = false
            return nil
        }

        switch contact.phase {
        case .down:
            active = Active(
                startX: contact.x,
                startY: contact.y,
                lastX: contact.x,
                lastY: contact.y,
                traveled: 0,
                startedAt: time,
                expressible: true
            )
            return nil

        case .move:
            guard var current = active else { return nil }
            current.traveled += Self.distance(
                from: (current.lastX, current.lastY),
                to: (contact.x, contact.y)
            )
            current.lastX = contact.x
            current.lastY = contact.y
            active = current
            return nil

        case .up:
            guard let current = active else { return nil }
            active = nil
            guard current.expressible else { return nil }

            let traveled = current.traveled + Self.distance(
                from: (current.lastX, current.lastY),
                to: (contact.x, contact.y)
            )
            let elapsed = time.timeIntervalSince(current.startedAt)

            if traveled <= Self.tapSlop, elapsed < Self.longPressSeconds {
                return .tap(x: current.startX, y: current.startY)
            }

            let durationMs = min(
                Self.maximumSwipeMs,
                max(1, Int((elapsed * 1000).rounded()))
            )
            return .swipe(
                fromX: current.startX,
                fromY: current.startY,
                toX: contact.x,
                toY: contact.y,
                durationMs: durationMs
            )
        }
    }

    private static func distance(
        from: (Int32, Int32),
        to: (Int32, Int32)
    ) -> Double {
        Double(hypot(
            Double(to.0 - from.0),
            Double(to.1 - from.1)
        ))
    }
}

/// Keeps the control socket's pointer stream consistent.
///
/// Android's input dispatcher drops a move or release for a pointer that
/// never went down, and the stage can produce one (a release after the
/// session restarted mid-gesture, a scroll that ends twice). The `adb shell
/// input` path never saw them because ``PhysicalGestureTracker`` only replays
/// complete gestures; the control socket streams every event, so they are
/// filtered here: moves and releases need a pointer that is down, and a
/// repeated down becomes a move.
public struct PhysicalPointerFilter: Sendable {
    private var down: Set<Int32> = []

    public init() {}

    public mutating func accept(_ contacts: [TouchCommand]) -> [TouchCommand] {
        contacts.compactMap { contact in
            switch contact.phase {
            case .down:
                guard down.insert(contact.id).inserted else {
                    return TouchCommand(phase: .move, x: contact.x, y: contact.y, id: contact.id)
                }
                return contact
            case .move:
                return down.contains(contact.id) ? contact : nil
            case .up:
                return down.remove(contact.id) != nil ? contact : nil
            }
        }
    }
}

/// Builds the input of a physical mirror.
///
/// The primary path is scrcpy's control socket
/// (``controlMessages(forContacts:videoWidth:videoHeight:)``,
/// ``controlMessages(forKeyboard:)``): events stream as they happen, in
/// video-frame coordinates the server maps to the display itself, with
/// multi-touch. The `adb` argv builders below are the fallback for a session
/// without a usable control socket; each invocation costs an adb round trip
/// plus a device-side JVM, so gestures are replayed on release and scaled to
/// the display with ``scaled(_:videoWidth:videoHeight:displayWidth:displayHeight:)``.
///
/// Everything is a pure function of the gesture/command so it is unit-testable;
/// `PhysicalMirrorSession` sends the result.
public enum PhysicalInput {
    /// The full `adb` argv for one gesture.
    public static func arguments(for gesture: PhysicalGesture, serial: String) -> [String] {
        switch gesture {
        case .tap(let x, let y):
            return ["-s", serial, "shell", "input", "tap", "\(x)", "\(y)"]
        case .swipe(let fromX, let fromY, let toX, let toY, let durationMs):
            return [
                "-s", serial, "shell", "input", "swipe",
                "\(fromX)", "\(fromY)", "\(toX)", "\(toY)", "\(durationMs)",
            ]
        }
    }

    /// The full `adb` argv for one keyboard command, or nil when it has no
    /// `adb shell input` equivalent (unknown special key, empty text).
    public static func arguments(forKeyboard command: KeyboardCommand, serial: String) -> [String]? {
        switch command {
        case .text(let text):
            let escaped = escapedText(text)
            guard !escaped.isEmpty else { return nil }
            return ["-s", serial, "shell", "input", "text", escaped]

        case .specialKey(let macKeyCode):
            guard let androidKeyCode = androidKeyCode(forMacKeyCode: macKeyCode) else {
                return nil
            }
            return ["-s", serial, "shell", "input", "keyevent", "\(androidKeyCode)"]
        }
    }

    /// The macOS virtual key codes the mirror view forwards as special keys
    /// (`MirrorMetalView.specialKeyCodes`) mapped to Android `KEYCODE_*`
    /// values. Unlisted codes return nil.
    public static func androidKeyCode(forMacKeyCode keyCode: UInt16) -> Int? {
        switch keyCode {
        case 51: return 67    // delete → KEYCODE_DEL
        case 117: return 112  // forward delete → KEYCODE_FORWARD_DEL
        case 53: return 111   // escape → KEYCODE_ESCAPE
        case 36: return 66    // return → KEYCODE_ENTER
        case 76: return 160   // keypad enter → KEYCODE_NUMPAD_ENTER
        case 48: return 61    // tab → KEYCODE_TAB
        case 123: return 21   // left arrow → KEYCODE_DPAD_LEFT
        case 124: return 22   // right arrow → KEYCODE_DPAD_RIGHT
        case 125: return 20   // down arrow → KEYCODE_DPAD_DOWN
        case 126: return 19   // up arrow → KEYCODE_DPAD_UP
        case 115: return 122  // home → KEYCODE_MOVE_HOME
        case 119: return 123  // end → KEYCODE_MOVE_END
        case 116: return 92   // page up → KEYCODE_PAGE_UP
        case 121: return 93   // page down → KEYCODE_PAGE_DOWN
        default: return nil
        }
    }

    /// Prepares typed text for `adb shell input text`.
    ///
    /// `adb shell` joins its arguments and the device shell parses the result,
    /// so shell metacharacters are backslash-escaped; spaces become `input`'s
    /// own `%s` placeholder. Control characters (a pasted newline, for
    /// instance) cannot be injected by `input text` and are dropped. A literal
    /// `%s` in the text is indistinguishable from a space to `input` — the
    /// same limitation scrcpy's README documents for its own `input text`
    /// fallback.
    public static func escapedText(_ text: String) -> String {
        let shellMetacharacters: Set<Unicode.Scalar> = [
            "'", "\"", "`", "$", "&", ";", "|", "<", ">", "(",
            ")", "*", "?", "[", "]", "{", "}", "~", "#", "!", "^",
        ]

        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case " ":
                result += "%s"
            case "\\":
                result += "\\\\"
            case let value where shellMetacharacters.contains(value):
                result.unicodeScalars.append("\\")
                result.unicodeScalars.append(scalar)
            default:
                if scalar.value >= 0x20, scalar.value != 0x7F {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    /// BACK for the fallback path (the control socket's BACK_OR_SCREEN_ON
    /// also wakes a sleeping screen; `input keyevent` cannot tell).
    public static func backArguments(serial: String) -> [String] {
        ["-s", serial, "shell", "input", "keyevent", "4"]
    }
}

// MARK: - Display scaling (adb fallback)

extension PhysicalInput {
    public static func displaySizeArguments(serial: String) -> [String] {
        ["-s", serial, "shell", "wm", "size"]
    }

    /// The size `wm size` reports, in the display's natural orientation. An
    /// `Override size` (set with `wm size WxH`) is what apps and `input`
    /// see, so it wins over the `Physical size`.
    public static func parseDisplaySize(fromWmSize output: String) -> (width: Int, height: Int)? {
        var physical: (width: Int, height: Int)?
        var override: (width: Int, height: Int)?
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let dimensions = parts[1].trimmingCharacters(in: .whitespaces)
                .split(separator: "x")
            guard dimensions.count == 2,
                  let width = Int(dimensions[0]), let height = Int(dimensions[1]),
                  width > 0, height > 0
            else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            if label.hasPrefix("override") {
                override = (width, height)
            } else if label.hasPrefix("physical") {
                physical = (width, height)
            }
        }
        return override ?? physical
    }

    /// The logical display size in the video frame's orientation: `wm size`
    /// reports the natural orientation, and a quarter-turned display (the
    /// server re-frames the video on rotation) swaps it.
    public static func displaySize(
        natural: (width: Int, height: Int),
        orientedLikeVideoWidth videoWidth: Int,
        videoHeight: Int
    ) -> (width: Int, height: Int) {
        let videoIsLandscape = videoWidth > videoHeight
        let naturalIsLandscape = natural.width > natural.height
        guard videoIsLandscape != naturalIsLandscape, videoWidth != videoHeight else {
            return natural
        }
        return (natural.height, natural.width)
    }

    /// Maps a gesture from video-frame pixels to display pixels.
    ///
    /// `input tap`/`swipe` take display coordinates, but the scrcpy server
    /// may stream a smaller picture than the display (`max_size`, or its
    /// encoder-failure downsizing to 1920/1600/1280/… lines), so a frame
    /// point is only a display point after scaling. Pixel centres are mapped,
    /// so equal sizes are the identity.
    public static func scaled(
        _ gesture: PhysicalGesture,
        videoWidth: Int,
        videoHeight: Int,
        displayWidth: Int,
        displayHeight: Int
    ) -> PhysicalGesture {
        guard videoWidth > 0, videoHeight > 0, displayWidth > 0, displayHeight > 0 else {
            return gesture
        }
        func x(_ value: Int32) -> Int32 {
            scale(value, from: videoWidth, to: displayWidth)
        }
        func y(_ value: Int32) -> Int32 {
            scale(value, from: videoHeight, to: displayHeight)
        }
        switch gesture {
        case .tap(let tapX, let tapY):
            return .tap(x: x(tapX), y: y(tapY))
        case .swipe(let fromX, let fromY, let toX, let toY, let durationMs):
            return .swipe(
                fromX: x(fromX),
                fromY: y(fromY),
                toX: x(toX),
                toY: y(toY),
                durationMs: durationMs
            )
        }
    }

    private static func scale(_ value: Int32, from source: Int, to target: Int) -> Int32 {
        let mapped = ((Double(value) + 0.5) * Double(target) / Double(source)).rounded(.down)
        return Int32(max(0, min(Double(target - 1), mapped)))
    }
}

// MARK: - Control socket (scrcpy v3.1)

extension PhysicalInput {
    /// The scrcpy pointer id of a stage contact. Contact ids are small and
    /// non-negative; the bit pattern is widened unsigned so no id can collide
    /// with the reserved mouse / generic-finger / virtual-finger ids (-1…-3).
    public static func pointerID(forContact id: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: id))
    }

    /// One INJECT_TOUCH_EVENT per contact of a stage input frame, positioned
    /// in the current video frame (`videoWidth` × `videoHeight`). The server
    /// maps the point to the display itself, and ignores it when the size is
    /// stale (the device rotated since), so no display lookup is needed.
    /// Each contact keeps its own pointer id, so a two-contact frame becomes
    /// a real two-finger gesture on the device. Empty without a video size.
    public static func controlMessages(
        forContacts contacts: [TouchCommand],
        videoWidth: Int,
        videoHeight: Int
    ) -> [ScrcpyControlMessage] {
        guard videoWidth > 0, videoHeight > 0,
              videoWidth <= Int(UInt16.max), videoHeight <= Int(UInt16.max)
        else { return [] }

        return contacts.map { contact in
            let action: ScrcpyControlMessage.TouchAction
            switch contact.phase {
            case .down: action = .down
            case .move: action = .move
            case .up: action = .up
            }
            return .injectTouch(
                action: action,
                pointerID: pointerID(forContact: contact.id),
                position: ScrcpyPosition(
                    x: max(0, min(Int32(videoWidth - 1), contact.x)),
                    y: max(0, min(Int32(videoHeight - 1), contact.y)),
                    screenWidth: UInt16(videoWidth),
                    screenHeight: UInt16(videoHeight)
                ),
                pressure: contact.phase == .up ? 0 : 1
            )
        }
    }

    /// The control messages for one keyboard command.
    ///
    /// - Special keys become a key down and a key up.
    /// - Printable ASCII text is typed with INJECT_TEXT (split at the
    ///   300-byte message cap).
    /// - Any other text (Turkish ç ş ğ ı, emoji, a pasted newline) is set as
    ///   the device clipboard and pasted: the server types INJECT_TEXT through
    ///   the virtual key map, which silently drops characters it cannot map.
    ///   This replaces the device clipboard, like scrcpy's own paste. The
    ///   paste is built without a sequence; `PhysicalMirrorSession` sends it
    ///   with one and holds later input until the server acknowledges it.
    public static func controlMessages(forKeyboard command: KeyboardCommand) -> [ScrcpyControlMessage] {
        switch command {
        case .specialKey(let macKeyCode):
            guard let keycode = androidKeyCode(forMacKeyCode: macKeyCode) else { return [] }
            return [
                .injectKeycode(action: .down, keycode: Int32(keycode)),
                .injectKeycode(action: .up, keycode: Int32(keycode)),
            ]

        case .text(let text):
            let scalars = text.unicodeScalars
            let isPrintable: (Unicode.Scalar) -> Bool = { $0.value >= 0x20 && $0.value != 0x7F }
            guard scalars.contains(where: isPrintable) else { return [] }
            if scalars.allSatisfy({ $0.isASCII && isPrintable($0) }) {
                return ScrcpyControl.textChunks(text).map { .injectText($0) }
            }
            return [
                .setClipboard(sequence: ScrcpyControl.sequenceInvalid, paste: true, text: text)
            ]
        }
    }
}
