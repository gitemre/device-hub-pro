import Foundation

// MARK: - Options

/// Device Hub's color filters. Android draws
/// them with Color correction (Settings ▸ Accessibility ▸ Color correction).
public enum ColorFilterOption: String, CaseIterable, Identifiable, Sendable {
    case none
    case grayscale
    case protanopia
    case deuteranopia
    case tritanopia

    public var id: String { rawValue }

    /// Device Hub's labels.
    public var title: String {
        switch self {
        case .none: return "None"
        case .grayscale: return "Grayscale"
        case .protanopia: return "Red/Green (Protanopia)"
        case .deuteranopia: return "Green/Red (Deuteranopia)"
        case .tritanopia: return "Blue/Yellow (Tritanopia)"
        }
    }

    /// The shortened label Device Hub shows for the selection.
    public var shortTitle: String {
        switch self {
        case .none: return "None"
        case .grayscale: return "Grayscale"
        case .protanopia: return "Protanopia"
        case .deuteranopia: return "Deuteranopia"
        case .tritanopia: return "Tritanopia"
        }
    }
}

extension ColorFilterOption {
    /// Android: secure `accessibility_display_daltonizer`
    /// (AccessibilityManager: 0 monochromacy, 11/12/13 protanomaly,
    /// deuteranomaly and tritanomaly correction); nil for `.none`, which turns
    /// only the switch off. Kept in an extension so a later iOS row can reuse
    /// the platform-neutral enum.
    public var daltonizerMode: Int? {
        switch self {
        case .none: return nil
        case .grayscale: return 0
        case .protanopia: return 11
        case .deuteranopia: return 12
        case .tritanopia: return 13
        }
    }

    /// Developer options ▸ Simulate color space writes 1/2/3 (SettingsLib
    /// `simulate_color_space_values`).
    static func simulated(mode: Int) -> ColorFilterOption? {
        switch mode {
        case 1: return .protanopia
        case 2: return .deuteranopia
        case 3: return .tritanopia
        default: return nil
        }
    }
}

/// The secure keys the rows read and write (Settings.Secure, android-16.0.0_r1).
public enum ColorFilterSettingKey: String, CaseIterable, Sendable {
    /// 0/1; any non-zero integer is on. `@Readable`.
    case enabled = "accessibility_display_daltonizer_enabled"
    /// -1 disabled, 0 monochromacy, 1/2/3 simulation, 11/12/13 correction. `@Readable`.
    case mode = "accessibility_display_daltonizer"
    /// 0–10, Settings' Intensity (android-15.0.0_r36 and newer). Never written.
    case level = "accessibility_display_daltonizer_saturation_level"
    /// 0/1. Public.
    case inversion = "accessibility_display_inversion_enabled"
}

// MARK: - Setting

/// The two daltonizer keys as ColorDisplayService reads them
/// (`onAccessibilityDaltonizerChanged`, android-16.0.0_r1): the switch is on
/// when `getIntForUser(enabled, 0) != 0`, and the mode is
/// `getIntForUser(mode, 12)`, so an unset or unparseable mode is 12.
public enum DaltonizerSetting: Sendable, Equatable {
    /// Switch off (`.none`), or one of Settings' modes 0/11/12/13.
    case filter(ColorFilterOption)
    /// Modes 1/2/3 from Developer options ▸ Simulate color space.
    case simulation(ColorFilterOption)
    /// Any other mode with the switch on (-1, 10, 21, 99, …).
    case unmapped(Int)

    public init(enabledRaw: String, modeRaw: String) {
        guard (Self.settingInt(enabledRaw) ?? 0) != 0 else {
            self = .filter(.none)
            return
        }
        let mode = Self.settingInt(modeRaw) ?? 12
        if let option = ColorFilterOption.allCases.first(where: { $0.daltonizerMode == mode }) {
            self = .filter(option)
        } else if let option = ColorFilterOption.simulated(mode: mode) {
            self = .simulation(option)
        } else {
            self = .unmapped(mode)
        }
    }

    /// The mode ColorDisplayService hands on; nil while the switch is off.
    public var appliedMode: Int? {
        switch self {
        case .filter(let option): return option.daltonizerMode
        case .simulation(let option):
            switch option {
            case .protanopia: return 1
            case .deuteranopia: return 2
            case .tritanopia: return 3
            case .none, .grayscale: return nil
            }
        case .unmapped(let mode): return mode
        }
    }

    /// The value as `Integer.parseInt` reads it: Settings' getIntForUser
    /// parses the stored string untrimmed and falls back to its default on a
    /// NumberFormatException (`parseIntSettingWithDefault`, Settings.java
    /// android-16.0.0_r1). An optional `+` or `-`, then one or more decimal
    /// digits (`Character.digit`: any Unicode decimal digit that is one UTF-16
    /// unit), within Java's 32-bit `int`. nil for `null`, empty, surrounding
    /// whitespace, garbage and overflow.
    static func settingInt(_ raw: String) -> Int? {
        var digits = raw.unicodeScalars[...]
        var isNegative = false
        if let sign = digits.first, sign == "-" || sign == "+" {
            isNegative = sign == "-"
            digits = digits.dropFirst()
        }
        guard !digits.isEmpty else { return nil }
        let limit = Int(Int32.max) + (isNegative ? 1 : 0)
        var value = 0
        for scalar in digits {
            guard scalar.value <= 0xFFFF,
                  scalar.properties.numericType == .decimal,
                  let digit = scalar.properties.numericValue.map({ Int($0) })
            else { return nil }
            value = value * 10 + digit
            guard value <= limit else { return nil }
        }
        return isNegative ? -value : value
    }
}

// MARK: - Support

/// What the rows can read on this device, from its API level.
public struct ColorFilterSupport: Sendable, Equatable {
    public let apiLevel: Int

    public init(apiLevel: Int) {
        self.apiLevel = apiLevel
    }

    /// The oldest API the rows are offered on: Android 7.0. Android applies
    /// the foreground user's keys (AccessibilityManagerService through
    /// DisplayAdjustmentUtils from android-6.0.1_r81, ColorDisplayService
    /// later), and `settings` names that user from Android 7.0 (`--user
    /// current`, SettingsCmd android-7.0.0_r1). Android 6.0's `settings` takes
    /// only a number and its `am` has no `get-current-user` (SettingsCmd and
    /// Am android-6.0.1_r81), so a write could land on user 0 while a
    /// secondary user or Guest has the screen.
    public static let minimumAPI = 24

    /// Whether the rows are offered on this device.
    public var offersRows: Bool { apiLevel >= Self.minimumAPI }

    /// The `settings` command for the foreground user's keys. API 24–28 name
    /// it (`--user current`): an unspecified user is user 0 there
    /// (`if (mUser < 0) mUser = USER_SYSTEM`, SettingsCmd android-7.0.0_r1 and
    /// android-7.1.2_r39, SettingsService android-8.1.0_r81 and
    /// android-9.0.0_r61). From API 29 an unspecified user is the current one
    /// (SettingsService android-10.0.0_r1: `USER_NULL || USER_CURRENT` →
    /// `getCurrentUser()`), so the command stays plain.
    public var settingsCommand: [String] {
        apiLevel < 29 ? ["settings", "--user", "current"] : ["settings"]
    }

    /// `dumpsys SurfaceFlinger --comp-displays` with `Display <id>
    /// (physical|virtual, …)` headers (android-13.0.0_r1). API 30–32 print the
    /// matrix only in the full dump, with no display kind, so the keys are the
    /// read-back there.
    public var readsDisplayMatrix: Bool { apiLevel >= 33 }

    /// `accessibility_display_daltonizer_saturation_level` (android-15.0.0_r36,
    /// flag `enable_color_correction_saturation`).
    public var intensityKey: Bool { apiLevel >= 35 }

    /// Whether the inversion key's integer turns Color inversion on. Through
    /// API 36 any non-zero value does (`getIntForUser(…, 0) != 0`:
    /// DisplayAdjustmentUtils android-7.1.2_r39 and android-9.0.0_r61,
    /// ColorDisplayService android-10.0.0_r47 and android-16.0.0_r1). The API
    /// 37 emulator (sdk_full 37.1) inverts for 1 only: 2, 3 and -1 leave
    /// SurfaceFlinger's matrix at identity while 01 and +1 invert
    /// (`readings-probe-inversion-2`).
    public func invertsColors(_ value: Int) -> Bool {
        apiLevel >= 37 ? value == 1 : value != 0
    }
}

// MARK: - Readings

/// The Color Filter and Color inversion rows' readings, from one shell round
/// trip: the four secure keys, and on Android 13 and newer SurfaceFlinger's
/// composed matrix, where Android applies them.
public struct ColorFilterReadings: Sendable, Equatable {
    /// The `settings get` answers as printed, untrimmed (Android parses the
    /// stored string as it is): `null` when unset, empty for an empty value.
    /// nil when the section is missing or its `settings get` exited non-zero.
    public var enabledRaw: String?
    public var modeRaw: String?
    public var levelRaw: String?
    public var inversionRaw: String?
    /// nil when not read (API < 33) or no physical display printed a matrix.
    public var display: DisplayTransformReading?
    /// The device's API level, which decides how the inversion key reads
    /// (`ColorFilterSupport.invertsColors`); nil reads it as through API 36.
    public var apiLevel: Int?

    public init(apiLevel: Int? = nil) {
        self.apiLevel = apiLevel
    }

    /// nil while either daltonizer key is unreadable.
    public var setting: DaltonizerSetting? {
        guard let enabledRaw, let modeRaw else { return nil }
        return DaltonizerSetting(enabledRaw: enabledRaw, modeRaw: modeRaw)
    }

    /// Color inversion (`getIntForUser(…, 0)`, then
    /// `ColorFilterSupport.invertsColors`); nil while unreadable.
    public var inversion: Bool? {
        guard let inversionRaw else { return nil }
        let value = DaltonizerSetting.settingInt(inversionRaw) ?? 0
        return apiLevel.map { ColorFilterSupport(apiLevel: $0).invertsColors(value) } ?? (value != 0)
    }

    /// The Intensity key when it holds 0–10.
    public var intensity: Int? {
        guard let value = levelRaw.flatMap(DaltonizerSetting.settingInt), (0...10).contains(value) else { return nil }
        return value
    }

    /// Whether any color transform is asked for: a filter, a simulation or an
    /// unmapped mode, or inversion.
    public var hasTransformSet: Bool {
        (setting.map { $0 != .filter(.none) } ?? false) || inversion == true
    }

    /// The readings a write of `option` leads to (the mode goes with the
    /// switch; None turns only the switch off and keeps the mode). The
    /// display is forgotten until the read-back.
    public func writing(_ option: ColorFilterOption) -> ColorFilterReadings {
        var next = self
        if let mode = option.daltonizerMode {
            next.enabledRaw = "1"
            next.modeRaw = String(mode)
        } else {
            next.enabledRaw = "0"
        }
        next.display = nil
        return next
    }

    public func writingInversion(_ enabled: Bool) -> ColorFilterReadings {
        var next = self
        next.inversionRaw = enabled ? "1" : "0"
        next.display = nil
        return next
    }

    enum Section: String, CaseIterable {
        case enabled
        case mode
        case level
        case inversion
        case display

        var marker: String { "@@devicehubpro-cf:\(rawValue)" }
        /// Printed after the section's `settings get` when it exits non-zero.
        var failureMarker: String { "@@devicehubpro-cf:\(rawValue)-failed" }

        /// The key a section reads; nil for the display.
        var key: ColorFilterSettingKey? {
            switch self {
            case .enabled: return .enabled
            case .mode: return .mode
            case .level: return .level
            case .inversion: return .inversion
            case .display: return nil
            }
        }
    }

    /// One shell line (passed as one `shell` argument). Each `settings get`
    /// that answers prints its value with `println` (`null` when unset, an
    /// empty line for an empty value). A failed read prints no line: from
    /// API 26 `cmd settings` also exits non-zero, so its section's failure
    /// marker follows; on API 24–25 SettingsCmd writes the error to standard
    /// error and exits 0 (android-7.0.0_r1), so only the missing line tells.
    /// The level key is read on every API (it answers `null` below 35). The
    /// display section reads `--comp-displays`, which takes SurfaceFlinger's
    /// state lock rather than its main thread (13–16 ms on the API 37
    /// emulator).
    public static func probeScript(support: ColorFilterSupport) -> String {
        let settings = support.settingsCommand.joined(separator: " ")
        var lines: [String] = []
        for section in Section.allCases {
            guard let key = section.key else { continue }
            lines += [
                "echo \(section.marker)",
                "\(settings) get secure \(key.rawValue) || echo \(section.failureMarker)",
            ]
        }
        if support.readsDisplayMatrix {
            lines += [
                "echo \(Section.display.marker)",
                "dumpsys SurfaceFlinger --comp-displays 2>/dev/null | grep -E '^Display |isEnabled=|colorTransformMatrix='",
            ]
        }
        lines.append("true")
        return lines.joined(separator: "; ")
    }

    public static func parse(_ output: String, apiLevel: Int) -> ColorFilterReadings {
        let markers = Section.allCases.map(\.marker) + Section.allCases.compactMap { $0.key == nil ? nil : $0.failureMarker }
        let sections = Self.sections(output, markers: markers)
        // A key reads as its section's lines only when it printed at least
        // one and no failure marker followed.
        func raw(_ section: Section) -> String? {
            guard sections[section.failureMarker] == nil, let lines = sections[section.marker], !lines.isEmpty else {
                return nil
            }
            return lines.joined(separator: "\n")
        }
        var readings = ColorFilterReadings(apiLevel: apiLevel)
        readings.enabledRaw = raw(.enabled)
        readings.modeRaw = raw(.mode)
        readings.levelRaw = raw(.level)
        readings.inversionRaw = raw(.inversion)
        readings.display = sections[Section.display.marker].flatMap {
            DisplayTransformReading.parse(section: $0.joined(separator: "\n"))
        }
        return readings
    }

    /// Each marker's section: the lines up to the next marker, kept as
    /// printed. The newline `settings get` ends a value with is the separator
    /// before the next marker, so an empty value is one empty line, a read
    /// that printed nothing is no line, and ` 11` keeps its space. Only a
    /// trailing `\r` per line goes (a pty's line ending).
    static func sections(_ output: String, markers: [String]) -> [String: [String]] {
        let known = Set(markers)
        var lines = output.components(separatedBy: "\n")
        if output.hasSuffix("\n") { lines.removeLast() }
        var result: [String: [String]] = [:]
        var current: String?
        for rawLine in lines {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if known.contains(trimmed) {
                current = trimmed
                result[trimmed] = []
                continue
            }
            guard let current else { continue }
            result[current, default: []].append(line)
        }
        return result
    }

    // MARK: Check

    /// Whether SurfaceFlinger's matrix is the one these keys ask for.
    public func check(apiLevel: Int) -> ColorTransformCheck {
        guard let setting, inversion != nil, let display else { return .unavailable }
        guard case .matrix(let dumped) = display else { return .displayOff }
        let reportsLevel: Bool
        switch setting {
        case .filter(.protanopia), .filter(.deuteranopia), .filter(.tritanopia): reportsLevel = true
        default: reportsLevel = false
        }
        for level in Self.candidateLevels(apiLevel: apiLevel, intensity: intensity) {
            guard let expected = ColorTransformModel.expected(self, level: level) else { break }
            if expected.approximatelyEquals(dumped) {
                return .applied(level: reportsLevel ? level : nil)
            }
        }
        return dumped.approximatelyEquals(.identity) ? .notApplied : .combined
    }

    /// The error-spread levels SurfaceFlinger may run at. Below API 35 it is
    /// always 0.7 (Daltonizer's default). From API 35 ColorDisplayService also
    /// sends the Intensity key (-1 when unset), and SurfaceFlinger ignores
    /// values outside 0–10 and keeps its last level, so the key's level comes
    /// first, then 0.7, then every step 0.1–1.0. 0.0 only when the key says 0.
    static func candidateLevels(apiLevel: Int, intensity: Int?) -> [Double] {
        guard apiLevel >= 35 else { return [0.7] }
        var levels: [Double] = []
        func add(_ tenths: Int) {
            let level = Double(tenths) / 10
            if !levels.contains(level) { levels.append(level) }
        }
        if let intensity { add(intensity) }
        add(7)
        for tenths in 1...10 { add(tenths) }
        return levels
    }
}

/// How SurfaceFlinger's matrix compares with the one the keys ask for.
public enum ColorTransformCheck: Sendable, Equatable {
    /// The matrix is the expected one; the level only for the three
    /// correction filters.
    case applied(level: Double?)
    /// Identity while something else is expected: the device ignores the keys.
    case notApplied
    /// Neither: another transform is in the product (Night Light, Extra dim,
    /// Bedtime mode's grayscale, a boosted color mode), or a stale matrix.
    case combined
    /// Every physical display is off, so the matrix may be stale.
    case displayOff
    /// No display section (API < 33, dumpsys failed) or an unreadable key.
    case unavailable
}

public struct ColorFilterWriteOutcome: Sendable, Equatable {
    public let readings: ColorFilterReadings
    public let check: ColorTransformCheck

    public init(readings: ColorFilterReadings, check: ColorTransformCheck) {
        self.readings = readings
        self.check = check
    }
}

public enum ColorFilterError: Error, Equatable, CustomStringConvertible {
    /// The keys read back differ from the write (`notKept("the color filter:
    /// secure … reads 0")`).
    case notKept(String)

    public var description: String {
        switch self {
        case .notKept(let what):
            return "The device did not keep \(what)."
        }
    }
}

// MARK: - Read-back

/// Reads a write back until the keys hold it and SurfaceFlinger's matrix
/// follows.
enum ColorFilterReadBack {
    enum Target: Sendable, Equatable {
        case filter(ColorFilterOption)
        case inversion(Bool)

        func isKept(by readings: ColorFilterReadings) -> Bool {
            switch self {
            case .filter(let option): return readings.setting == .filter(option)
            case .inversion(let enabled): return readings.inversion == enabled
            }
        }

        /// What the device shows instead, for `ColorFilterError.notKept`.
        func notKept(by readings: ColorFilterReadings) -> ColorFilterError {
            func reads(_ key: ColorFilterSettingKey, _ raw: String?) -> String {
                "secure \(key.rawValue) \(raw.map { "reads \(Self.shown($0))" } ?? "can't be read")"
            }
            switch self {
            case .filter(let option):
                let wantsOn = option.daltonizerMode != nil
                let isOn = readings.enabledRaw.flatMap(DaltonizerSetting.settingInt).map { $0 != 0 } ?? false
                if readings.enabledRaw == nil || wantsOn != isOn {
                    return .notKept("the color filter: \(reads(.enabled, readings.enabledRaw))")
                }
                return .notKept("the color filter: \(reads(.mode, readings.modeRaw))")
            case .inversion:
                return .notKept("color inversion: \(reads(.inversion, readings.inversionRaw))")
            }
        }

        /// A raw value as the error names it: quoted when it is empty or has
        /// surrounding whitespace.
        static func shown(_ raw: String) -> String {
            raw.isEmpty || raw.trimmingCharacters(in: .whitespacesAndNewlines) != raw ? "\"\(raw)\"" : raw
        }
    }

    /// Up to `attempts` reads, `delay` apart; a read that throws counts. A
    /// read settles when its keys hold `target` and its check is applied,
    /// display-off or unavailable. Not-applied and combined keep reading: after
    /// a switch between two filters a stale matrix reads as combined for a
    /// frame. After the last attempt: every read failed → the last error; the
    /// last read's keys differ → `ColorFilterError.notKept`; else that read.
    static func settle(
        target: Target,
        apiLevel: Int,
        attempts: Int,
        delay: Duration,
        read: () async throws -> ColorFilterReadings
    ) async throws -> ColorFilterWriteOutcome {
        var lastError: (any Error)?
        var lastRead: ColorFilterReadings?
        for attempt in 0..<max(attempts, 1) {
            if attempt > 0, delay > .zero { try await Task.sleep(for: delay) }
            do {
                let readings = try await read()
                lastRead = readings
                let check = readings.check(apiLevel: apiLevel)
                if target.isKept(by: readings), check.settlesReadBack {
                    return ColorFilterWriteOutcome(readings: readings, check: check)
                }
            } catch {
                lastError = error
            }
        }
        guard let lastRead else {
            throw lastError ?? ColorFilterError.notKept("the color filter")
        }
        guard target.isKept(by: lastRead) else { throw target.notKept(by: lastRead) }
        return ColorFilterWriteOutcome(readings: lastRead, check: lastRead.check(apiLevel: apiLevel))
    }
}

extension ColorTransformCheck {
    /// A check the read-back stops at.
    var settlesReadBack: Bool {
        switch self {
        case .applied, .displayOff, .unavailable: return true
        case .notApplied, .combined: return false
        }
    }
}
