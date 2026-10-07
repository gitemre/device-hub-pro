import CoreGraphics
import Foundation

/// Android's SVG path-data parser (`android.util.PathParser`), ported to
/// `CGPath` so a path string reads here exactly as the device reads it.
///
/// Ported from AOSP `frameworks/base`: the tokenizer from
/// `libs/hwui/PathParser.cpp` (`getPathDataFromAsciiString`) and the command
/// semantics from `libs/hwui/utils/VectorDrawableUtils.cpp`
/// (`PathResolver::addCommand`), which feed Skia. That parser is looser and
/// stricter than SVG in places, and a display-cutout spec is only as valid
/// as Android finds it, so its quirks are kept on purpose:
/// - Numbers are split on ' ', ',', a '-' that does not follow an exponent,
///   and a second '.'; any other character (a newline, a tab) stays in the
///   token and ends the number there, as `strtof` does.
/// - Every ASCII letter but 'e'/'E' starts a command; an unknown letter, or
///   a command whose value count is not a multiple of its arity, fails the
///   whole string (Android throws `IllegalArgumentException`).
/// - Arc flags are ordinary numbers (`!= 0`), so compact flags (`a1 1 0 01…`)
///   are not split, as on Android.
/// - A moveto followed by more pairs draws implicit linetos; `z` returns the
///   pen to the subpath's start.
///
/// Skia draws arcs as conics; `CGPath` has none, so each arc is split at the
/// ellipse's quarter points (segments of at most 90°) and drawn as cubics:
/// radial error under 0.03% of the radius, and exact at the segment ends, so
/// an unrotated arc's bounding box is exact. The pen moves Android emits
/// after `z` are only added when something is drawn from them: a lone move
/// draws nothing.
enum AndroidPathParser {
    /// One command letter and its values, as the tokenizer splits them.
    struct Command: Equatable {
        let verb: UInt8
        let values: [CGFloat]
    }

    /// The path `pathData` describes, or nil when Android would reject it.
    static func path(_ pathData: String) -> CGMutablePath? {
        guard let commands = commands(Array(pathData.utf8)) else { return nil }
        var resolver = Resolver()
        var previous = UInt8(ascii: "m")
        for command in commands {
            resolver.add(command, previous: previous)
            previous = command.verb
        }
        return resolver.path
    }

    // MARK: - Tokenizer (PathParser.cpp)

    /// `getPathDataFromAsciiString`: nil where it sets `failureOccurred`.
    static func commands(_ bytes: [UInt8]) -> [Command]? {
        let length = bytes.count
        var start = 0
        while start < length, isSpace(bytes[start]) {
            start += 1
        }
        guard start < length else { return nil }
        var end = start + 1
        var commands: [Command] = []

        while end < length {
            end = nextStart(bytes, from: end)
            guard let values = floats(bytes, start: start, end: end),
                  isValid(verb: bytes[start], count: values.count)
            else { return nil }
            commands.append(Command(verb: bytes[start], values: values))
            start = end
            end += 1
        }
        if end - start == 1, start < length {
            guard isValid(verb: bytes[start], count: 0) else { return nil }
            commands.append(Command(verb: bytes[start], values: []))
        }
        return commands.isEmpty ? nil : commands
    }

    /// The index of the next command letter at or after `index` (the end
    /// when there is none). 'e'/'E' belong to numbers.
    private static func nextStart(_ bytes: [UInt8], from index: Int) -> Int {
        var index = index
        while index < bytes.count {
            let c = bytes[index]
            let isLetter = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
            if isLetter, c != UInt8(ascii: "e"), c != UInt8(ascii: "E") {
                return index
            }
            index += 1
        }
        return index
    }

    /// `getFloats`: the numbers after the command letter at `start`, up to
    /// `end`; nil when one does not parse.
    private static func floats(_ bytes: [UInt8], start: Int, end: Int) -> [CGFloat]? {
        if bytes[start] == UInt8(ascii: "z") || bytes[start] == UInt8(ascii: "Z") {
            return []
        }
        var values: [CGFloat] = []
        var position = start + 1
        while position < end {
            let (tokenEnd, endsWithNegativeOrDot) = extract(bytes, start: position, end: end)
            if position < tokenEnd {
                guard let value = parseFloat(bytes, from: position) else { return nil }
                values.append(value)
            }
            // A '-' or second '.' separator begins the next number.
            position = endsWithNegativeOrDot ? tokenEnd : tokenEnd + 1
        }
        return values
    }

    /// `extract`: where the number starting at `start` ends, and whether the
    /// separator found there ('-' or a second '.') belongs to the next one.
    private static func extract(_ bytes: [UInt8], start: Int, end: Int) -> (Int, Bool) {
        var index = start
        var endsWithNegativeOrDot = false
        var sawDot = false
        var isExponential = false
        while index < end {
            let wasExponential = isExponential
            isExponential = false
            var foundSeparator = false
            switch bytes[index] {
            case UInt8(ascii: " "), UInt8(ascii: ","):
                foundSeparator = true
            case UInt8(ascii: "-"):
                // A sign after 'e'/'E' is the exponent's, not a separator.
                if index != start, !wasExponential {
                    foundSeparator = true
                    endsWithNegativeOrDot = true
                }
            case UInt8(ascii: "."):
                if sawDot {
                    foundSeparator = true
                    endsWithNegativeOrDot = true
                } else {
                    sawDot = true
                }
            case UInt8(ascii: "e"), UInt8(ascii: "E"):
                isExponential = true
            default:
                break
            }
            if foundSeparator { break }
            index += 1
        }
        return (index, endsWithNegativeOrDot)
    }

    /// `parseFloat` (`strtof`): the longest decimal number at `index`, after
    /// leading white space. Nil when there is none or it overflows a float,
    /// the two failures Android reports.
    private static func parseFloat(_ bytes: [UInt8], from index: Int) -> CGFloat? {
        var index = index
        while index < bytes.count, isSpace(bytes[index]) {
            index += 1
        }
        let numberStart = index
        func isDigit(_ i: Int) -> Bool {
            i < bytes.count && bytes[i] >= UInt8(ascii: "0") && bytes[i] <= UInt8(ascii: "9")
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
            index += 1
        }
        var digits = 0
        while isDigit(index) {
            index += 1
            digits += 1
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            while isDigit(index) {
                index += 1
                digits += 1
            }
        }
        guard digits > 0 else { return nil }
        // An exponent only counts when digits follow it ("1e" reads as 1).
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            var exponent = index + 1
            if exponent < bytes.count, bytes[exponent] == UInt8(ascii: "+") || bytes[exponent] == UInt8(ascii: "-") {
                exponent += 1
            }
            if isDigit(exponent) {
                index = exponent
                while isDigit(index) {
                    index += 1
                }
            }
        }
        guard let text = String(bytes: bytes[numberStart..<index], encoding: .ascii),
              let value = Float(text), value.isFinite
        else { return nil }
        return CGFloat(value)
    }

    /// `validateVerbAndPoints`: a known command letter with a multiple of its
    /// arity (zero values included) — `z` with none.
    private static func isValid(verb: UInt8, count: Int) -> Bool {
        guard let arity = arity(verb) else { return false }
        if arity == 0 { return count == 0 }
        return count % arity == 0
    }

    private static func arity(_ verb: UInt8) -> Int? {
        switch verb {
        case UInt8(ascii: "z"), UInt8(ascii: "Z"): return 0
        case UInt8(ascii: "m"), UInt8(ascii: "M"), UInt8(ascii: "l"), UInt8(ascii: "L"),
             UInt8(ascii: "t"), UInt8(ascii: "T"): return 2
        case UInt8(ascii: "h"), UInt8(ascii: "H"), UInt8(ascii: "v"), UInt8(ascii: "V"): return 1
        case UInt8(ascii: "c"), UInt8(ascii: "C"): return 6
        case UInt8(ascii: "s"), UInt8(ascii: "S"), UInt8(ascii: "q"), UInt8(ascii: "Q"): return 4
        case UInt8(ascii: "a"), UInt8(ascii: "A"): return 7
        default: return nil
        }
    }

    /// C's `isspace` in the "C" locale.
    private static func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || (c >= 0x09 && c <= 0x0D)
    }

    // MARK: - Resolver (VectorDrawableUtils.cpp)

    /// `PathResolver`: the pen and the last control point, in absolute
    /// coordinates, drawing into `path`.
    private struct Resolver {
        let path = CGMutablePath()
        var current = CGPoint.zero
        var control = CGPoint.zero
        var subpathStart = CGPoint.zero
        /// Whether `path` has a current point to draw from: false before the
        /// first move and after a close (Android then moves to the subpath's
        /// start, which is added lazily — see the type's note).
        var hasCurrentPoint = false

        /// Starts a subpath at the pen when a drawing command has none, as
        /// Skia's `injectMoveToIfNeeded` does.
        mutating func ensureCurrentPoint() {
            guard !hasCurrentPoint else { return }
            path.move(to: current)
            hasCurrentPoint = true
        }

        mutating func add(_ command: Command, previous: UInt8) {
            let v = command.values
            let verb = command.verb
            if verb == UInt8(ascii: "z") || verb == UInt8(ascii: "Z") {
                if hasCurrentPoint { path.closeSubpath() }
                hasCurrentPoint = false
                current = subpathStart
                control = subpathStart
                return
            }
            guard let arity = arity(verb), arity > 0 else { return }
            var previous = previous
            var k = 0
            while k + arity <= v.count {
                switch verb {
                case UInt8(ascii: "m"), UInt8(ascii: "M"):
                    let point = verb == UInt8(ascii: "m")
                        ? CGPoint(x: current.x + v[k], y: current.y + v[k + 1])
                        : CGPoint(x: v[k], y: v[k + 1])
                    if k > 0 {
                        // Extra moveto pairs are implicit linetos.
                        ensureCurrentPoint()
                        path.addLine(to: point)
                    } else {
                        path.move(to: point)
                        hasCurrentPoint = true
                        subpathStart = point
                    }
                    current = point
                case UInt8(ascii: "l"), UInt8(ascii: "L"):
                    let point = verb == UInt8(ascii: "l")
                        ? CGPoint(x: current.x + v[k], y: current.y + v[k + 1])
                        : CGPoint(x: v[k], y: v[k + 1])
                    ensureCurrentPoint()
                    path.addLine(to: point)
                    current = point
                case UInt8(ascii: "h"), UInt8(ascii: "H"):
                    let x = verb == UInt8(ascii: "h") ? current.x + v[k] : v[k]
                    ensureCurrentPoint()
                    path.addLine(to: CGPoint(x: x, y: current.y))
                    current.x = x
                case UInt8(ascii: "v"), UInt8(ascii: "V"):
                    let y = verb == UInt8(ascii: "v") ? current.y + v[k] : v[k]
                    ensureCurrentPoint()
                    path.addLine(to: CGPoint(x: current.x, y: y))
                    current.y = y
                case UInt8(ascii: "c"), UInt8(ascii: "C"):
                    let base = verb == UInt8(ascii: "c") ? current : .zero
                    let c1 = CGPoint(x: base.x + v[k], y: base.y + v[k + 1])
                    let c2 = CGPoint(x: base.x + v[k + 2], y: base.y + v[k + 3])
                    let end = CGPoint(x: base.x + v[k + 4], y: base.y + v[k + 5])
                    ensureCurrentPoint()
                    path.addCurve(to: end, control1: c1, control2: c2)
                    control = c2
                    current = end
                case UInt8(ascii: "s"), UInt8(ascii: "S"):
                    // The first control point mirrors the last cubic's second
                    // one; after anything else it is the pen.
                    let followsCubic = [UInt8(ascii: "c"), UInt8(ascii: "s"), UInt8(ascii: "C"), UInt8(ascii: "S")]
                        .contains(previous)
                    let c1 = followsCubic
                        ? CGPoint(x: 2 * current.x - control.x, y: 2 * current.y - control.y)
                        : current
                    let base = verb == UInt8(ascii: "s") ? current : .zero
                    let c2 = CGPoint(x: base.x + v[k], y: base.y + v[k + 1])
                    let end = CGPoint(x: base.x + v[k + 2], y: base.y + v[k + 3])
                    ensureCurrentPoint()
                    path.addCurve(to: end, control1: c1, control2: c2)
                    control = c2
                    current = end
                case UInt8(ascii: "q"), UInt8(ascii: "Q"):
                    let base = verb == UInt8(ascii: "q") ? current : .zero
                    let c = CGPoint(x: base.x + v[k], y: base.y + v[k + 1])
                    let end = CGPoint(x: base.x + v[k + 2], y: base.y + v[k + 3])
                    ensureCurrentPoint()
                    path.addQuadCurve(to: end, control: c)
                    control = c
                    current = end
                case UInt8(ascii: "t"), UInt8(ascii: "T"):
                    let followsQuad = [UInt8(ascii: "q"), UInt8(ascii: "t"), UInt8(ascii: "Q"), UInt8(ascii: "T")]
                        .contains(previous)
                    let c = followsQuad
                        ? CGPoint(x: 2 * current.x - control.x, y: 2 * current.y - control.y)
                        : current
                    let end = verb == UInt8(ascii: "t")
                        ? CGPoint(x: current.x + v[k], y: current.y + v[k + 1])
                        : CGPoint(x: v[k], y: v[k + 1])
                    ensureCurrentPoint()
                    path.addQuadCurve(to: end, control: c)
                    control = c
                    current = end
                case UInt8(ascii: "a"), UInt8(ascii: "A"):
                    let end = verb == UInt8(ascii: "a")
                        ? CGPoint(x: current.x + v[k + 5], y: current.y + v[k + 6])
                        : CGPoint(x: v[k + 5], y: v[k + 6])
                    ensureCurrentPoint()
                    AndroidPathParser.addArc(
                        to: path,
                        from: current,
                        radii: CGSize(width: v[k], height: v[k + 1]),
                        xAxisRotation: v[k + 2],
                        largeArc: v[k + 3] != 0,
                        sweep: v[k + 4] != 0,
                        end: end
                    )
                    current = end
                    control = end
                default:
                    return
                }
                previous = verb
                k += arity
            }
        }
    }

    // MARK: - Arcs (SkPath::arcTo)

    /// SVG's elliptical arc from `start` to `end` (SVG 1.1 F.6.5, with the
    /// out-of-range radii scaled up per F.6.6), as Skia's `arcTo` resolves
    /// it: a zero radius or a zero-length arc is a straight line. `sweep` is
    /// SVG's sweep flag: true runs toward increasing angles, which is
    /// clockwise on a y-down display.
    static func addArc(
        to path: CGMutablePath,
        from start: CGPoint,
        radii: CGSize,
        xAxisRotation degrees: CGFloat,
        largeArc: Bool,
        sweep: Bool,
        end: CGPoint
    ) {
        var rx = abs(radii.width)
        var ry = abs(radii.height)
        guard rx > 0, ry > 0, start != end else {
            path.addLine(to: end)
            return
        }
        let phi = degrees * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        // The half chord, in the ellipse's own axes.
        let halfX = (start.x - end.x) / 2
        let halfY = (start.y - end.y) / 2
        let x1 = cosPhi * halfX + sinPhi * halfY
        let y1 = -sinPhi * halfX + cosPhi * halfY

        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }

        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coefficient = denominator > 0 ? max(numerator / denominator, 0).squareRoot() : 0
        if largeArc == sweep { coefficient = -coefficient }
        let centerX1 = coefficient * rx * y1 / ry
        let centerY1 = -coefficient * ry * x1 / rx
        let center = CGPoint(
            x: cosPhi * centerX1 - sinPhi * centerY1 + (start.x + end.x) / 2,
            y: sinPhi * centerX1 + cosPhi * centerY1 + (start.y + end.y) / 2
        )

        let startAngle = atan2((y1 - centerY1) / ry, (x1 - centerX1) / rx)
        let endAngle = atan2((-y1 - centerY1) / ry, (-x1 - centerX1) / rx)
        var sweepAngle = endAngle - startAngle
        if sweep, sweepAngle < 0 {
            sweepAngle += 2 * .pi
        } else if !sweep, sweepAngle > 0 {
            sweepAngle -= 2 * .pi
        }
        // Skia's guard against degenerate sweeps (skbug.com/9272).
        guard abs(sweepAngle) >= .pi / 1_000_000 else {
            path.addLine(to: end)
            return
        }

        func point(_ unitX: CGFloat, _ unitY: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + rx * unitX * cosPhi - ry * unitY * sinPhi,
                y: center.y + rx * unitX * sinPhi + ry * unitY * cosPhi
            )
        }

        // Segments break at every quarter point of the ellipse the arc
        // crosses, so none spans more than 90° and, on an unrotated ellipse,
        // every extreme is a segment end: the bounding box is exact.
        let quarter = CGFloat.pi / 2
        let direction: CGFloat = sweepAngle > 0 ? 1 : -1
        let finalAngle = startAngle + sweepAngle
        var angles = [startAngle]
        var step = direction > 0
            ? (startAngle / quarter).rounded(.down) + 1
            : (startAngle / quarter).rounded(.up) - 1
        while true {
            let angle = step * quarter
            guard direction > 0 ? angle < finalAngle - 1e-9 : angle > finalAngle + 1e-9 else { break }
            if abs(angle - startAngle) > 1e-9 { angles.append(angle) }
            step += direction
        }
        angles.append(finalAngle)

        for index in 1..<angles.count {
            let a0 = angles[index - 1]
            let a1 = angles[index]
            let handle = 4 / 3 * tan((a1 - a0) / 4)
            let (cos0, sin0) = (cos(a0), sin(a0))
            let (cos1, sin1) = (cos(a1), sin(a1))
            // The last segment lands exactly on `end`, not on rounded trig.
            let target = index == angles.count - 1 ? end : point(cos1, sin1)
            path.addCurve(
                to: target,
                control1: point(cos0 - handle * sin0, sin0 + handle * cos0),
                control2: point(cos1 + handle * sin1, sin1 - handle * cos1)
            )
        }
    }
}
