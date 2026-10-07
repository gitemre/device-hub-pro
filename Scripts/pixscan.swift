// pixscan.swift — tiny pixel scanner + parity-check evaluator for Device Hub Pro.
//
// Build (the harness does this automatically):
//   swiftc Scripts/pixscan.swift -o /tmp/pixscan
//
// Primitives (coordinates are PIXELS, origin = capture top-left):
//   pixscan size  <png>
//       -> "<width> <height>"
//   pixscan point <png> <x> <y>
//       -> "#rrggbb"
//   pixscan run   <png> row|col <fixed> <from> <to> <#rrggbb> [matchTol]
//       Longest contiguous run along the line whose channel-max distance from
//       the colour is <= matchTol (default 6).
//       -> "<start> <end> <width> #rrggbb"
//   pixscan edge  <png> row|col <fixed> <from> <to> [delta]
//       First pixel along from->to whose channel-max distance from the pixel at
//       <from> is >= delta (default 8). from > to scans backwards.
//       -> "<index> #bg>#found"
//   pixscan band  <png> col <fixed> <from> <to> [delta]
//       Contiguous run of pixels differing from the pixel at <from> by >= delta.
//       -> "<start> <end> <height>"
//
// Evaluator:
//   pixscan check <png> <reference.json> <scale>
//       <scale> is pixels per window point (1 on a 1x display, 2 on Retina).
//       Runs every check in the reference file, prints a PASS/FAIL/SKIP line per
//       check ("expected=… actual=… (Δ…)") plus a summary, and exits 1 if any
//       check fails. Checks whose "appearance" is not the capture's detected
//       appearance are reported as SKIP (never as failures).
//
// Reference JSON (Scripts/parity-reference.json) — one object:
//   { "window": {...informational...},
//     "checks": [ { "name", "description", "kind", "appearance", "expected",
//                   "tolerance", ... kind-specific fields ... } ] }
// Kind-specific fields (all coordinates in window POINTS):
//   pixel-color-at-point : x, y, color "#rrggbb", tolerance = channel-max
//   color-run-width      : axis "row"|"col", fixed, from, to, color,
//                          matchTolerance (default 6), tolerance = width
//   edge-x               : row, from, to, delta, expected = x,
//                          optional relativeTo "right"
//   edge-y               : col, from, to, delta, expected = y,
//                          optional relativeTo "bottom"
//   band-height          : col, from, to, delta, expected = height
//
// Only AppKit/Foundation are used. The capture must be an 8-bit RGBA/BGRA PNG
// as produced by `screencapture -x` / NSImage.

import AppKit
import Foundation

struct Pixels {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytesPerPixel: Int
    let data: CFData
    let pointer: UnsafePointer<UInt8>

    init?(path: String) {
        guard let image = NSImage(contentsOfFile: path),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let provider = cg.dataProvider,
              let cf = provider.data else { return nil }
        self.width = cg.width
        self.height = cg.height
        self.bytesPerRow = cg.bytesPerRow
        self.bytesPerPixel = cg.bitsPerPixel / 8
        self.data = cf
        self.pointer = CFDataGetBytePtr(cf)!
    }

    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = y * bytesPerRow + x * bytesPerPixel
        return (Int(pointer[i]), Int(pointer[i + 1]), Int(pointer[i + 2]))
    }

    func contains(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < width && y < height }
}

func channelDiff(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
    max(abs(a.0 - b.0), max(abs(a.1 - b.1), abs(a.2 - b.2)))
}

func luma(_ c: (Int, Int, Int)) -> Double {
    0.2126 * Double(c.0) + 0.7152 * Double(c.1) + 0.0722 * Double(c.2)
}

func hex(_ c: (Int, Int, Int)) -> String {
    String(format: "#%02x%02x%02x", c.0, c.1, c.2)
}

func parseHex(_ text: String) -> (Int, Int, Int)? {
    var s = text
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
    return ((value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff)
}

func number(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue
}

func number(_ value: Any?, default fallback: Double) -> Double {
    number(value) ?? fallback
}

func format(_ value: Double) -> String {
    if abs(value - value.rounded()) < 0.005 { return String(Int(value.rounded())) }
    return String(format: "%.2f", value)
}

// MARK: - primitives

func runPrimitives(_ args: [String]) {
    guard args.count >= 2 else { usage() }
    let command = args[1]
    guard let pixels = Pixels(path: args.count > 2 ? args[2] : "") else {
        fail("cannot read image \(args.count > 2 ? args[2] : "<missing>")")
    }

    switch command {
    case "size":
        print("\(pixels.width) \(pixels.height)")

    case "point":
        guard args.count == 5, let x = Int(args[3]), let y = Int(args[4]), pixels.contains(x, y) else { usage() }
        print(hex(pixels.rgb(x, y)))

    case "run":
        guard args.count >= 8,
              let fixed = Int(args[4]), let from = Int(args[5]), let to = Int(args[6]),
              let color = parseHex(args[7]) else { usage() }
        let matchTolerance = args.count > 8 ? (Double(args[8]) ?? 6) : 6
        var bestStart = -1, bestEnd = -1, bestLength = 0
        var start = -1
        let step = from <= to ? 1 : -1
        var index = from
        while true {
            let x = args[3] == "row" ? index : fixed
            let y = args[3] == "row" ? fixed : index
            let matches = pixels.contains(x, y) && Double(channelDiff(pixels.rgb(x, y), color)) <= matchTolerance
            if matches {
                if start < 0 { start = index }
                let length = abs(index - start) + 1
                if length > bestLength { bestLength = length; bestStart = start; bestEnd = index }
            } else {
                start = -1
            }
            if index == to { break }
            index += step
        }
        if bestStart < 0 { print("none - 0 \(hex(color))") }
        else { print("\(bestStart) \(bestEnd) \(bestLength) \(hex(color))") }

    case "edge":
        guard args.count >= 7,
              let fixed = Int(args[4]), let from = Int(args[5]), let to = Int(args[6]) else { usage() }
        let delta = args.count > 7 ? (Double(args[7]) ?? 8) : 8
        let background = pixelAt(pixels, axis: args[3], fixed: fixed, index: from)
        let step = from <= to ? 1 : -1
        var index = from
        while true {
            if index != from {
                let color = pixelAt(pixels, axis: args[3], fixed: fixed, index: index)
                if let bg = background, let c = color, Double(channelDiff(bg, c)) >= delta {
                    print("\(index) \(hex(bg))>\(hex(c))")
                    return
                }
            }
            if index == to { break }
            index += step
        }
        print("none \(background.map(hex) ?? "#??????")>-")

    case "band":
        guard args.count >= 7, args[3] == "col",
              let x = Int(args[4]), let from = Int(args[5]), let to = Int(args[6]) else { usage() }
        let delta = args.count > 7 ? (Double(args[7]) ?? 8) : 8
        guard let bg = pixelAt(pixels, axis: "col", fixed: x, index: from) else {
            fail("band: start pixel (\(x),\(from)) outside image")
        }
        let step = from <= to ? 1 : -1
        var start = -1, end = -1
        var index = from
        while true {
            let color = pixelAt(pixels, axis: "col", fixed: x, index: index)
            let differs = color.map { Double(channelDiff(bg, $0)) >= delta } ?? false
            if differs {
                if start < 0 { start = index }
                end = index
            } else if start >= 0 {
                break
            }
            if index == to { break }
            index += step
        }
        if start < 0 { print("none - 0") }
        else { print("\(start) \(end) \(abs(end - start) + 1)") }

    default:
        usage()
    }
}

func pixelAt(_ pixels: Pixels, axis: String, fixed: Int, index: Int) -> (Int, Int, Int)? {
    let x = axis == "row" ? index : fixed
    let y = axis == "row" ? fixed : index
    guard pixels.contains(x, y) else { return nil }
    return pixels.rgb(x, y)
}

// MARK: - evaluator

struct CheckResult {
    let line: String
    let passed: Bool
    let skipped: Bool
}

func evaluate(_ pixels: Pixels, referencePath: String, scale: Double) -> [CheckResult] {
    guard let data = FileManager.default.contents(atPath: referencePath),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let checks = root["checks"] as? [[String: Any]] else {
        fail("cannot parse reference file \(referencePath)")
    }

    let appearance = detectAppearance(pixels, scale: scale)
    print("appearance: \(appearance)   capture: \(pixels.width)x\(pixels.height)px @ \(format(scale)) px/pt")

    if let window = root["window"] as? [String: Any],
       let expectedWidth = number(window["width"]),
       let expectedHeight = number(window["height"]) {
        let actualWidth = Double(pixels.width) / scale
        let actualHeight = Double(pixels.height) / scale
        if abs(actualWidth - expectedWidth) > 1 || abs(actualHeight - expectedHeight) > 1 {
            print("note: live window is \(format(actualWidth))x\(format(actualHeight))pt, reference assumes \(format(expectedWidth))x\(format(expectedHeight))pt — geometry checks may fail")
        }
    }

    var results: [CheckResult] = []
    for raw in checks {
        let name = raw["name"] as? String ?? "unnamed"
        let kind = raw["kind"] as? String ?? "?"
        let wanted = raw["appearance"] as? String ?? "any"
        let expected = number(raw["expected"]) ?? 0
        let tolerance = number(raw["tolerance"]) ?? 0
        let label = name.padding(toLength: 34, withPad: " ", startingAt: 0)

        if wanted != "any" && wanted != appearance {
            results.append(CheckResult(
                line: "SKIP \(label) (appearance=\(wanted); the running app renders \(appearance))",
                passed: true, skipped: true))
            continue
        }

        let outcome = runCheck(kind: kind, raw: raw, pixels: pixels, scale: scale, expected: expected, tolerance: tolerance)
        switch outcome {
        case .pass(let actual, let detail):
            results.append(CheckResult(line: "PASS \(label) expected=\(actual.expected) actual=\(actual.actual) (Δ\(actual.delta))\(detail.isEmpty ? "" : "  \(detail)")", passed: true, skipped: false))
        case .fail(let actual, let detail):
            results.append(CheckResult(line: "FAIL \(label) expected=\(actual.expected) actual=\(actual.actual) (Δ\(actual.delta))\(detail.isEmpty ? "" : "  \(detail)")", passed: false, skipped: false))
        case .error(let message):
            results.append(CheckResult(line: "FAIL \(label) \(message)", passed: false, skipped: false))
        }
    }
    return results
}

struct Measured {
    let expected: String
    let actual: String
    let delta: String
}

enum Outcome {
    case pass(Measured, String)
    case fail(Measured, String)
    case error(String)
}

func runCheck(kind: String, raw: [String: Any], pixels: Pixels, scale: Double, expected: Double, tolerance: Double) -> Outcome {
    func point(_ value: Double) -> Int { Int((value * scale).rounded()) }
    func points(_ value: Double) -> Double { value / scale }

    switch kind {
    case "pixel-color-at-point":
        guard let x = number(raw["x"]), let y = number(raw["y"]),
              let wanted = raw["color"] as? String, let color = parseHex(wanted) else {
            return .error("malformed pixel-color-at-point check")
        }
        let px = point(x), py = point(y)
        guard pixels.contains(px, py) else { return .error("point (\(x),\(y)) outside capture") }
        let actual = pixels.rgb(px, py)
        let delta = channelDiff(actual, color)
        let measured = Measured(expected: wanted, actual: hex(actual), delta: "\(delta)")
        let detail = "at (\(format(x)),\(format(y)))"
        return Double(delta) <= tolerance ? .pass(measured, detail) : .fail(measured, detail)

    case "color-run-width":
        guard let axis = raw["axis"] as? String, let fixed = number(raw["fixed"]),
              let from = number(raw["from"]), let to = number(raw["to"]),
              let wanted = raw["color"] as? String, let color = parseHex(wanted) else {
            return .error("malformed color-run-width check")
        }
        let matchTolerance = number(raw["matchTolerance"]) ?? 6
        var bestLength = 0, bestStart = -1, bestEnd = -1
        var start = -1
        let first = point(from), last = point(to), step = first <= last ? 1 : -1
        var index = first
        while true {
            let match = pixelAt(pixels, axis: axis, fixed: point(fixed), index: index)
                .map { Double(channelDiff($0, color)) <= matchTolerance } ?? false
            if match {
                if start < 0 { start = index }
                let length = abs(index - start) + 1
                if length > bestLength { bestLength = length; bestStart = start; bestEnd = index }
            } else {
                start = -1
            }
            if index == last { break }
            index += step
        }
        guard bestStart >= 0 else {
            return .fail(Measured(expected: format(expected), actual: "none", delta: "—"), "no \(wanted) run on \(axis) \(format(fixed))")
        }
        let width = points(Double(bestLength))
        let delta = abs(width - expected)
        let measured = Measured(expected: format(expected), actual: format(width), delta: format(delta))
        let detail = "\(axis) \(format(fixed)): \(format(points(Double(bestStart))))–\(format(points(Double(bestEnd))))"
        return delta <= tolerance ? .pass(measured, detail) : .fail(measured, detail)

    case "edge-x", "edge-y":
        let horizontal = kind == "edge-x"
        guard let fixed = number(raw[horizontal ? "row" : "col"]),
              let from = number(raw["from"]), let to = number(raw["to"]) else {
            return .error("malformed \(kind) check")
        }
        let delta = number(raw["delta"]) ?? 8
        let axis = horizontal ? "row" : "col"
        guard let background = pixelAt(pixels, axis: axis, fixed: point(fixed), index: point(from)) else {
            return .error("start pixel outside capture")
        }
        let first = point(from), last = point(to), step = first <= last ? 1 : -1
        var index = first
        var found: Int? = nil
        var foundColor = background
        while true {
            if index != first,
               let color = pixelAt(pixels, axis: axis, fixed: point(fixed), index: index),
               Double(channelDiff(background, color)) >= delta {
                found = index
                foundColor = color
                break
            }
            if index == last { break }
            index += step
        }
        guard let hit = found else {
            return .fail(Measured(expected: format(expected), actual: "no edge", delta: "—"),
                         "scan \(format(from))→\(format(to)) from \(hex(background))")
        }
        let actual = (raw["relativeTo"] as? String) == (horizontal ? "right" : "bottom")
            ? points(Double((horizontal ? pixels.width : pixels.height) - hit))
            : points(Double(hit))
        let difference = abs(actual - expected)
        let measured = Measured(expected: format(expected), actual: format(actual), delta: format(difference))
        let coordinate = horizontal ? "x" : "y"
        let detail = "\(coordinate)=\(format(actual)) \(hex(background))→\(hex(foundColor))"
        return difference <= tolerance ? .pass(measured, detail) : .fail(measured, detail)

    case "band-height":
        guard let x = number(raw["col"]), let from = number(raw["from"]), let to = number(raw["to"]) else {
            return .error("malformed band-height check")
        }
        let delta = number(raw["delta"]) ?? 8
        guard let background = pixelAt(pixels, axis: "col", fixed: point(x), index: point(from)) else {
            return .error("start pixel outside capture")
        }
        let first = point(from), last = point(to), step = first <= last ? 1 : -1
        var index = first
        var start = -1, end = -1
        while true {
            if let color = pixelAt(pixels, axis: "col", fixed: point(x), index: index),
               Double(channelDiff(background, color)) >= delta {
                if start < 0 { start = index }
                end = index
            } else if start >= 0 {
                break
            }
            if index == last { break }
            index += step
        }
        guard start >= 0 else {
            return .fail(Measured(expected: format(expected), actual: "none", delta: "—"), "no band at x=\(format(x))")
        }
        let height = points(Double(abs(end - start) + 1))
        let difference = abs(height - expected)
        let measured = Measured(expected: format(expected), actual: format(height), delta: format(difference))
        let detail = "x=\(format(x)): y \(format(points(Double(start))))–\(format(points(Double(end))))"
        return difference <= tolerance ? .pass(measured, detail) : .fail(measured, detail)

    default:
        return .error("unknown kind '\(kind)'")
    }
}

func detectAppearance(_ pixels: Pixels, scale: Double) -> String {
    let samples: [(Double, Double)] = [(700, 5), (400, 450), (5, 450)]
    var values: [Double] = []
    for (x, y) in samples {
        let px = Int((x * scale).rounded()), py = Int((y * scale).rounded())
        guard pixels.contains(px, py) else { continue }
        values.append(luma(pixels.rgb(px, py)))
    }
    guard !values.isEmpty else { return "unknown" }
    let average = values.reduce(0, +) / Double(values.count)
    return average >= 128 ? "light" : "dark"
}

// MARK: - entry point

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: pixscan size <png>
           pixscan point <png> <x> <y>
           pixscan run <png> row|col <fixed> <from> <to> <#rrggbb> [matchTol]
           pixscan edge <png> row|col <fixed> <from> <to> [delta]
           pixscan band <png> col <fixed> <from> <to> [delta]
           pixscan check <png> <reference.json> <scale>

    """.utf8))
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("pixscan: \(message)\n".utf8))
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { usage() }

if arguments[1] == "check" {
    guard arguments.count == 5, let scale = Double(arguments[4]), scale > 0 else { usage() }
    guard let pixels = Pixels(path: arguments[2]) else { fail("cannot read image \(arguments[2])") }
    let results = evaluate(pixels, referencePath: arguments[3], scale: scale)
    print(String(repeating: "-", count: 78))
    for result in results { print(result.line) }
    print(String(repeating: "-", count: 78))
    let passed = results.filter { $0.passed && !$0.skipped }.count
    let skipped = results.filter { $0.skipped }.count
    let failed = results.filter { !$0.passed }.count
    print("summary: \(passed) passed, \(failed) failed, \(skipped) skipped")
    exit(failed == 0 ? 0 : 1)
} else {
    runPrimitives(arguments)
}
