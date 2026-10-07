import Foundation

// MARK: - Matrix

/// SurfaceFlinger's composed color matrix as `dumpsys SurfaceFlinger` prints it
/// (`OutputCompositionState::dump`, android-13.0.0_r1 and newer:
/// `colorTransformMatrix=[[r0][r1][r2][r3]]`, each value `%0.3f`, so `-0.000`
/// appears). Sixteen values, row-major as dumped: row i gives output channel i
/// (red, green, blue, alpha) from (r, g, b, 1), and column 3 holds the offsets.
public struct ColorTransformMatrix: Sendable, Equatable, CustomStringConvertible {
    /// Row-major, 16 values.
    public let values: [Double]

    public init?(values: [Double]) {
        guard values.count == 16 else { return nil }
        self.values = values
    }

    init(rows: [[Double]]) {
        precondition(rows.count == 4 && rows.allSatisfy { $0.count == 4 })
        values = rows.flatMap { $0 }
    }

    /// SurfaceFlinger's `mat4(a0 … a15)` lists columns; this transposes them
    /// into rows.
    init(columnMajor columns: [Double]) {
        precondition(columns.count == 16)
        values = (0..<16).map { index in columns[(index % 4) * 4 + index / 4] }
    }

    public static let identity = ColorTransformMatrix(rows: [
        [1, 0, 0, 0],
        [0, 1, 0, 0],
        [0, 0, 1, 0],
        [0, 0, 0, 1],
    ])

    public subscript(row: Int, column: Int) -> Double {
        values[row * 4 + column]
    }

    public static func * (lhs: ColorTransformMatrix, rhs: ColorTransformMatrix) -> ColorTransformMatrix {
        var product = [Double](repeating: 0, count: 16)
        for row in 0..<4 {
            for column in 0..<4 {
                var sum = 0.0
                for index in 0..<4 { sum += lhs[row, index] * rhs[index, column] }
                product[row * 4 + column] = sum
            }
        }
        return ColorTransformMatrix(values: product)!
    }

    static func + (lhs: ColorTransformMatrix, rhs: ColorTransformMatrix) -> ColorTransformMatrix {
        ColorTransformMatrix(values: zip(lhs.values, rhs.values).map(+))!
    }

    static func - (lhs: ColorTransformMatrix, rhs: ColorTransformMatrix) -> ColorTransformMatrix {
        ColorTransformMatrix(values: zip(lhs.values, rhs.values).map(-))!
    }

    /// Whether every value is within `tolerance`: the dump rounds float math
    /// to 3 decimals (the captures differ from the model by at most 0.0005).
    public func approximatelyEquals(_ other: ColorTransformMatrix, tolerance: Double = 0.002) -> Bool {
        zip(values, other.values).allSatisfy { abs($0 - $1) <= tolerance }
    }

    /// Reads one dump line: `colorTransformMatrix=[[a,b,c,d][e,f,g,h][i,j,k,l][m,n,o,p]]`,
    /// with the dump's leading indent and trailing space. nil for anything else.
    public static func parse(line: String) -> ColorTransformMatrix? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "colorTransformMatrix=["
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix("]") else { return nil }
        let body = trimmed.dropFirst(prefix.count).dropLast()
        guard body.hasPrefix("["), body.hasSuffix("]") else { return nil }
        let rows = body.dropFirst().dropLast().components(separatedBy: "][")
        guard rows.count == 4 else { return nil }
        var values: [Double] = []
        for row in rows {
            let fields = row.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 4 else { return nil }
            for field in fields {
                guard let value = Double(field), value.isFinite else { return nil }
                values.append(value)
            }
        }
        return ColorTransformMatrix(values: values)
    }

    /// The dump's own format (without `-0.000`).
    public var description: String {
        "[" + (0..<4).map { row in
            "[" + (0..<4).map { column -> String in
                let text = String(format: "%0.3f", self[row, column])
                return text == "-0.000" ? "0.000" : text
            }.joined(separator: ",") + "]"
        }.joined() + "]"
    }

    /// The inverse, by Gauss-Jordan elimination with partial pivoting; nil
    /// for a singular matrix.
    func inverse() -> ColorTransformMatrix? {
        var augmented = (0..<4).map { row in
            (0..<4).map { self[row, $0] } + (0..<4).map { $0 == row ? 1.0 : 0.0 }
        }
        for column in 0..<4 {
            guard let pivot = (column..<4).max(by: { abs(augmented[$0][column]) < abs(augmented[$1][column]) }),
                  abs(augmented[pivot][column]) > 1e-12
            else { return nil }
            augmented.swapAt(column, pivot)
            let divisor = augmented[column][column]
            augmented[column] = augmented[column].map { $0 / divisor }
            for row in 0..<4 where row != column {
                let factor = augmented[row][column]
                augmented[row] = zip(augmented[row], augmented[column]).map { $0 - factor * $1 }
            }
        }
        return ColorTransformMatrix(rows: augmented.map { Array($0[4...]) })
    }
}

// MARK: - Display section

/// Which display's matrix the read-back uses, from `dumpsys SurfaceFlinger
/// --comp-displays` (android-13.0.0_r1 and newer). Each display prints
/// `Display <id> (physical|virtual, "<name>")`, then its
/// `OutputCompositionState`, which starts with `isEnabled=<bool>` (the power
/// mode is not OFF: DisplayDevice `setCompositionEnabled`) and later holds
/// `colorTransformMatrix=`.
public enum DisplayTransformReading: Sendable, Equatable {
    /// The first physical display that is on (or prints no `isEnabled=`).
    case matrix(ColorTransformMatrix)
    /// Physical displays are listed but every one is off: SurfaceFlinger
    /// pushes the matrix only to outputs it composes, so it may be stale.
    case displayOff

    public var matrix: ColorTransformMatrix? {
        if case .matrix(let matrix) = self { return matrix }
        return nil
    }

    /// Reads the probe's section (the header, `isEnabled=` and matrix lines)
    /// or the whole `--comp-displays` dump. Virtual displays (screenrecord,
    /// scrcpy, casting) are skipped. nil when no physical display prints a
    /// matrix.
    public static func parse(section: String) -> DisplayTransformReading? {
        struct Record {
            let isPhysical: Bool
            var enabled: Bool?
            var matrix: ColorTransformMatrix?
        }
        var records: [Record] = []
        for rawLine in section.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if let isPhysical = headerKind(line) {
                records.append(Record(isPhysical: isPhysical))
                continue
            }
            guard !records.isEmpty else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("isEnabled=true") {
                records[records.count - 1].enabled = true
            } else if trimmed.hasPrefix("isEnabled=false") {
                records[records.count - 1].enabled = false
            } else if trimmed.hasPrefix("colorTransformMatrix="),
                      let matrix = ColorTransformMatrix.parse(line: trimmed) {
                records[records.count - 1].matrix = matrix
            }
        }
        let physical = records.filter { $0.isPhysical && $0.matrix != nil }
        if let shown = physical.first(where: { $0.enabled != false }), let matrix = shown.matrix {
            return .matrix(matrix)
        }
        return physical.isEmpty ? nil : .displayOff
    }

    /// `Display <id> (physical, …` → true, `(virtual, …` → false, else nil.
    private static func headerKind(_ line: String) -> Bool? {
        guard line.hasPrefix("Display ") else { return nil }
        let rest = line.dropFirst("Display ".count)
        guard let space = rest.firstIndex(of: " "), space > rest.startIndex else { return nil }
        let id = rest[..<space]
        guard !id.contains(where: \.isWhitespace) else { return nil }
        let kind = rest[rest.index(after: space)...]
        if kind.hasPrefix("(physical") { return true }
        if kind.hasPrefix("(virtual") { return false }
        return nil
    }
}

// MARK: - Model

/// The matrix Android composes for a color filter state: ColorDisplayService's
/// accessibility matrices through DisplayTransformManager, times
/// SurfaceFlinger's Daltonizer. Used to confirm the dumped matrix.
enum ColorTransformModel {
    /// ColorDisplayService `MATRIX_GRAYSCALE` (android-16.0.0_r1; a
    /// column-major `float[]`).
    static let grayscale = ColorTransformMatrix(columnMajor: [
        0.2126, 0.2126, 0.2126, 0,
        0.7152, 0.7152, 0.7152, 0,
        0.0722, 0.0722, 0.0722, 0,
        0, 0, 0, 1,
    ])

    /// ColorDisplayService `MATRIX_INVERT_COLOR` (android-16.0.0_r1).
    static let inversion = ColorTransformMatrix(columnMajor: [
        0.402, -0.598, -0.599, 0,
        -1.174, -0.174, -1.175, 0,
        -0.228, -0.228, 0.772, 0,
        1, 1, 1, 1,
    ])

    // Daltonizer.cpp (frameworks/native services/surfaceflinger/Effects, main):
    // the constants of `Daltonizer::update()`, which do not depend on the level.
    private static let rgb2xyz = ColorTransformMatrix(columnMajor: [
        0.4124, 0.2126, 0.0193, 0,
        0.3576, 0.7152, 0.1192, 0,
        0.1805, 0.0722, 0.9505, 0,
        0, 0, 0, 1,
    ])
    private static let xyz2lms = ColorTransformMatrix(columnMajor: [
        0.7328, -0.7036, 0.0030, 0,
        0.4296, 1.6975, 0.0136, 0,
        -0.1624, 0.0061, 0.9834, 0,
        0, 0, 0, 1,
    ])
    private static let rgb2lms = xyz2lms * rgb2xyz
    private static let lms2rgb = rgb2lms.inverse()!

    /// `cross(lms_w, lms_b)` (protanopia/deuteranopia) and `cross(lms_w, lms_r)`
    /// (tritanopia), with `lms_r` / `lms_b` the first and third columns of
    /// rgb2lms and `lms_w = (rgb2lms * vec4(1)).rgb`.
    private static let planes: (p0: [Double], p1: [Double]) = {
        let red = (0..<3).map { rgb2lms[$0, 0] }
        let blue = (0..<3).map { rgb2lms[$0, 2] }
        let white = (0..<3).map { row in (0..<4).reduce(0.0) { $0 + rgb2lms[row, $1] } }
        func cross(_ a: [Double], _ b: [Double]) -> [Double] {
            [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
        }
        return (cross(white, blue), cross(white, red))
    }()

    /// A port of `Daltonizer::update()`: SurfaceFlinger's 1014 transaction
    /// takes `mode % 10` (1 protan, 2 deutan, 3 tritan, anything else none;
    /// Swift and C++ agree on negative remainders) and corrects when
    /// `mode >= 10`, else simulates. `level` is the error spread (0.0–1.0).
    static func daltonizer(mode: Int, level: Double) -> ColorTransformMatrix {
        let (p0, p1) = planes
        let simulation: ColorTransformMatrix
        let correctionMatrix: ColorTransformMatrix
        switch mode % 10 {
        case 1:
            simulation = ColorTransformMatrix(columnMajor: [
                0, 0, 0, 0,
                -p0[1] / p0[0], 1, 0, 0,
                -p0[2] / p0[0], 0, 1, 0,
                0, 0, 0, 1,
            ])
            correctionMatrix = ColorTransformMatrix(columnMajor: [
                1, level, level, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1,
            ])
        case 2:
            simulation = ColorTransformMatrix(columnMajor: [
                1, -p0[0] / p0[1], 0, 0,
                0, 0, 0, 0,
                0, -p0[2] / p0[1], 1, 0,
                0, 0, 0, 1,
            ])
            correctionMatrix = ColorTransformMatrix(columnMajor: [
                1, 0, 0, 0,
                level, 1, level, 0,
                0, 0, 1, 0,
                0, 0, 0, 1,
            ])
        case 3:
            simulation = ColorTransformMatrix(columnMajor: [
                1, 0, -p1[0] / p1[2], 0,
                0, 1, -p1[1] / p1[2], 0,
                0, 0, 0, 0,
                0, 0, 0, 1,
            ])
            correctionMatrix = ColorTransformMatrix(columnMajor: [
                1, 0, 0, 0,
                0, 1, 0, 0,
                level, level, 1, 0,
                0, 0, 0, 1,
            ])
        default:
            return .identity
        }
        let correction = mode >= 10 ? correctionMatrix : ColorTransformMatrix(values: Array(repeating: 0, count: 16))!
        let simulated = simulation * rgb2lms
        return lms2rgb * (simulated + correction * (rgb2lms - simulated))
    }

    /// The matrix the device should show for `readings` at `level`:
    /// ColorDisplayService puts grayscale (mode 0) at DisplayTransformManager
    /// level 200 and sends SurfaceFlinger -1, sends any other mode unchanged,
    /// and puts inversion at level 300; DisplayTransformManager multiplies its
    /// levels in ascending order and SurfaceFlinger multiplies the result by
    /// its Daltonizer. nil while a key is unreadable.
    static func expected(_ readings: ColorFilterReadings, level: Double) -> ColorTransformMatrix? {
        guard let setting = readings.setting, let inverted = readings.inversion else { return nil }
        let mode = setting.appliedMode
        let isGrayscale = mode == 0
        let surfaceFlingerMode = mode.flatMap { $0 == 0 ? nil : $0 } ?? -1
        let client = (isGrayscale ? grayscale : .identity) * (inverted ? inversion : .identity)
        return client * daltonizer(mode: surfaceFlingerMode, level: level)
    }
}
