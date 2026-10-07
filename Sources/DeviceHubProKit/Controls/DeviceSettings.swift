import Foundation

// MARK: - Text size (font scale)

/// The stock Android text-size steps (Settings ▸ Display ▸ Text size):
/// `settings get system font_scale` values 0.85 / 1.0 / 1.15 / 1.30, and
/// from Android 14 (API 34, non-linear font scaling) also 1.5 / 1.8 / 2.0
/// (SettingsLib `entryvalues_font_size`).
public enum FontScaleStep: Double, CaseIterable, Identifiable, Sendable {
    case small = 0.85
    case standard = 1.0
    case large = 1.15
    case largest = 1.3
    case percent150 = 1.5
    case percent180 = 1.8
    case percent200 = 2.0

    /// First API level with the 150–200 % steps.
    public static let nonLinearScalingMinimumAPI = 34

    /// The steps up to Android 13.
    public static let classicSteps: [FontScaleStep] = [.small, .standard, .large, .largest]

    public var id: Double { rawValue }

    public var label: String {
        switch self {
        case .small: return "Small"
        case .standard: return "Default"
        case .large: return "Large"
        case .largest: return "Largest"
        case .percent150: return "150%"
        case .percent180: return "180%"
        case .percent200: return "200%"
        }
    }

    /// The steps the device's own Settings offers: all seven from API 34,
    /// the four classic ones before (and when the level is unknown).
    public static func steps(apiLevel: Int?) -> [FontScaleStep] {
        guard let apiLevel, apiLevel >= nonLinearScalingMinimumAPI else { return classicSteps }
        return allCases
    }

    /// The step nearest `value` among `steps`; a tie (within a hair of the
    /// midpoint) snaps to the smaller step so a size the device set outside
    /// the stock steps is never rounded up. The tolerance keeps the
    /// midpoint's binary representation from deciding the tie.
    public static func nearest(to value: Double, in steps: [FontScaleStep] = classicSteps) -> FontScaleStep {
        var best = steps.first ?? .standard
        var bestDistance = Double.infinity
        for step in steps.sorted(by: { $0.rawValue < $1.rawValue }) {
            let distance = abs(step.rawValue - value)
            if distance < bestDistance - 1e-9 {
                best = step
                bestDistance = distance
            }
        }
        return best
    }
}

/// What `settings get system font_scale` answered. `null` (never written),
/// empty output and non-numbers are `unreadable` — only a positive number is
/// a scale the row can show.
public enum FontScaleReading: Sendable, Equatable {
    case value(Double)
    case unreadable

    /// The scale to show in the Controls slider, if the device answered one.
    public var value: Double? {
        if case .value(let value) = self { return value }
        return nil
    }

    public static func parse(_ output: String) -> FontScaleReading {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null",
              let value = Double(trimmed), value.isFinite, value > 0
        else {
            return .unreadable
        }
        return .value(value)
    }
}

// MARK: - Reduce Motion

/// The device's Reduce Motion state, folded from the three animation scales:
/// `window_animation_scale`, `transition_animation_scale` and
/// `animator_duration_scale` (all 0 = animations off = Reduce Motion on).
/// A `null` scale is unset, which the framework runs at its 1.0 default, so
/// it reads as animations on.
public enum ReduceMotionReading: Sendable, Equatable {
    case enabled
    case disabled
    case unreadable

    public var isEnabled: Bool? {
        switch self {
        case .enabled: return true
        case .disabled: return false
        case .unreadable: return nil
        }
    }

    public static func parse(
        window: String,
        transition: String,
        animator: String
    ) -> ReduceMotionReading {
        guard let windowScale = scale(from: window),
              let transitionScale = scale(from: transition),
              let animatorScale = scale(from: animator)
        else {
            return .unreadable
        }
        let allZero = windowScale == 0 && transitionScale == 0 && animatorScale == 0
        return allZero ? .enabled : .disabled
    }

    /// One animation scale; `null` is the 1.0 default, anything that is not a
    /// finite non-negative number is unreadable.
    private static func scale(from output: String) -> Double? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.lowercased() == "null" { return 1.0 }
        guard let value = Double(trimmed), value.isFinite, value >= 0 else { return nil }
        return value
    }
}

// MARK: - Boolean setting rows

/// A boolean row reading: a `settings get` value (Increase Contrast, the
/// key-driven developer toggles) or an effect from `DeviceEffects`.
public enum SettingsToggleReading: Sendable, Equatable {
    case on
    case off
    case unreadable

    public var isOn: Bool? {
        switch self {
        case .on: return true
        case .off: return false
        case .unreadable: return nil
        }
    }

    /// Parses `1`/`true`/`0`/`false`. `null` is an unset key and takes the
    /// caller's default (off for both of these settings); empty or garbage
    /// output is unreadable.
    public static func parse(
        _ output: String,
        whenUnset: SettingsToggleReading = .off
    ) -> SettingsToggleReading {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true": return .on
        case "0", "false": return .off
        case "null": return whenUnset
        default: return .unreadable
        }
    }
}

// MARK: - Developer toggles

/// One developer toggle row in the Controls inspector and its user-facing
/// label. Four rows are plain settings keys the platform observes (read from
/// the namespace dumps, written with `settings put`). The other four
/// (`readsDeviceEffect`) are driven by another mechanism — a SurfaceFlinger
/// transaction, a system property, the Wi-Fi module — and read from
/// `DeviceEffects`; their `namespace`/`key` is only the Global/System key
/// Android keeps next to that mechanism, if any.
public enum DeviceToggle: String, CaseIterable, Identifiable, Sendable {
    case showTaps
    case forceRTL
    case showBackgroundANRs
    case wifiVerboseLogging
    case mobileDataAlwaysActive

    public var id: String { rawValue }

    /// True when the row's state comes from `DeviceEffects` (its effect is
    /// not a settings key), so it is read back from there after a write.
    public var readsDeviceEffect: Bool {
        switch self {
        case .forceRTL, .wifiVerboseLogging:
            return true
        case .showTaps, .showBackgroundANRs, .mobileDataAlwaysActive:
            return false
        }
    }

    public var namespace: String {
        switch self {
        case .showTaps:
            return "system"
        case .showBackgroundANRs:
            return "secure"
        case .forceRTL, .wifiVerboseLogging, .mobileDataAlwaysActive:
            return "global"
        }
    }

    public var key: String {
        switch self {
        case .showTaps: return "show_touches"
        case .forceRTL: return "debug.force_rtl"
        case .showBackgroundANRs: return "anr_show_background"
        case .wifiVerboseLogging: return "wifi_verbose_logging_enabled"
        case .mobileDataAlwaysActive: return "mobile_data_always_on"
        }
    }

    public var label: String {
        switch self {
        case .showTaps: return "Show taps"
        case .forceRTL: return "Force RTL"
        case .showBackgroundANRs: return "Show background ANRs"
        case .wifiVerboseLogging: return "Wi-Fi verbose logging"
        case .mobileDataAlwaysActive: return "Mobile data always active"
        }
    }
}

// MARK: - Data Saver

/// What `cmd netpolicy get restrict-background` answered (API 24+). A
/// non-zero exit is a command failure (the caller's probe hides the row);
/// answered output that carries no boolean is `unreadable`.
public enum DataSaverReading: Sendable, Equatable {
    case on
    case off
    case unreadable

    public var isOn: Bool? {
        switch self {
        case .on: return true
        case .off: return false
        case .unreadable: return nil
        }
    }

    /// Parses the answer, `Restrict background status: enabled|disabled` —
    /// the wording NetworkPolicyManagerShellCommand has printed since API
    /// 24 (byte-exact API 37 output in the Controls fixtures). The
    /// `Restrict background: true|false` wording of `dumpsys netpolicy` is
    /// read too.
    public static func parse(_ output: String) -> DataSaverReading {
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.lowercased()
            guard let marker = line.range(of: "restrict background") else { continue }
            let value = line[marker.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t:"))
            switch value {
            case "true", "1", "status: enabled", "enabled": return .on
            case "false", "0", "status: disabled", "disabled": return .off
            default: return .unreadable
            }
        }
        return .unreadable
    }
}

// MARK: - Media volume

/// The media stream's volume and the device's range for it
/// (`media volume --stream 3 --get` or its `cmd media_session` successor).
public struct MediaVolumeReading: Sendable, Equatable {
    public let index: Int
    public let minimum: Int
    public let maximum: Int

    public init(index: Int, minimum: Int, maximum: Int) {
        self.index = index
        self.minimum = minimum
        self.maximum = maximum
    }
}

// MARK: - TalkBack

public enum TalkBack {
    /// The GMS TalkBack package.
    public static let gmsPackageID = "com.google.android.marvin.talkback"

    /// The accessibility-service component of a TalkBack package — the entry
    /// written to `enabled_accessibility_services`.
    public static func serviceComponent(for packageID: String) -> String {
        "\(packageID)/\(packageID).TalkBackService"
    }
}

/// What `accessibility_enabled` + `enabled_accessibility_services` answer for
/// the TalkBack toggle. The flag alone is not enough — another accessibility
/// service may be the one enabled — so the TalkBack component must also be in
/// the service list. `null` is an unset key (off).
public enum VoiceOverReading: Sendable, Equatable {
    case on
    case off
    case unreadable

    public var isOn: Bool? {
        switch self {
        case .on: return true
        case .off: return false
        case .unreadable: return nil
        }
    }

    public static func parse(
        enabled: String,
        services: String,
        talkBackComponent: String
    ) -> VoiceOverReading {
        guard let enabled = SettingsToggleReading.parse(enabled).isOn else {
            return .unreadable
        }
        let isListed = AccessibilityServices.parse(services).contains(talkBackComponent)
        return enabled && isListed ? .on : .off
    }
}

/// The colon-separated `enabled_accessibility_services` list. Edits preserve
/// the other services: turning TalkBack on must not disable a separately
/// configured accessibility service (and vice versa).
public enum AccessibilityServices {
    public static func parse(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else { return [] }
        return trimmed
            .split(separator: ":")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func adding(_ component: String, to raw: String) -> String {
        var services = parse(raw)
        if !services.contains(component) {
            services.append(component)
        }
        return services.joined(separator: ":")
    }

    public static func removing(_ component: String, from raw: String) -> String {
        parse(raw)
            .filter { $0 != component }
            .joined(separator: ":")
    }
}

// MARK: - Parsing

public enum DeviceSettingsParsing {
    /// Parses `media volume --stream 3 --get` and `cmd media_session volume
    /// --stream 3 --get` output (`Volume is 5 in range [0..15]`, the newer
    /// form prefixed with `[V] `). Garbage or empty output has no reading.
    public static func mediaVolume(from output: String) -> MediaVolumeReading? {
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.lowercased()
            guard let marker = line.range(of: "volume is") else { continue }
            let remainder = line[marker.upperBound...]
                .trimmingCharacters(in: .whitespaces)
            let tokens = remainder
                .split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            guard tokens.count >= 4,
                  tokens[1] == "in", tokens[2] == "range",
                  let index = Int(tokens[0])
            else { continue }
            let bounds = tokens[3]
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .components(separatedBy: "..")
            guard bounds.count == 2,
                  let minimum = Int(bounds[0]),
                  let maximum = Int(bounds[1])
            else { continue }
            return MediaVolumeReading(index: index, minimum: minimum, maximum: maximum)
        }
        return nil
    }

    /// The TalkBack package in a parsed `pm list packages` list: the GMS
    /// package, else an OEM build whose id ends in `.talkback`. The
    /// `…talkbackoverlay` companion package does not count.
    public static func talkBackPackage(fromPackages packages: [String]) -> String? {
        if packages.contains(TalkBack.gmsPackageID) { return TalkBack.gmsPackageID }
        return packages.first { $0.hasSuffix(".talkback") }
    }
}

// MARK: - Availability probe

/// Availability gate for the Controls settings rows, like `AppearanceProbe`:
/// only a *failing command* counts toward hiding the row (after 3 consecutive
/// failures), and any answered read clears the streak. A read the row cannot
/// represent (an unreadable value) still proves the command exists.
public struct SettingsProbe: Sendable, Equatable {
    /// Consecutive command failures tolerated before the row is hidden.
    public static let failureLimit = 3

    public private(set) var consecutiveFailures = 0

    public init() {}

    /// Whether the row is shown: hidden only when its command keeps failing.
    public var isAvailable: Bool { consecutiveFailures < Self.failureLimit }

    /// Records one availability read: `true` when the command answered
    /// (whatever the answer), `false` when it failed.
    public mutating func record(answered: Bool) {
        if answered {
            consecutiveFailures = 0
        } else {
            consecutiveFailures += 1
        }
    }

    /// Starts over — used when the Controls panel moves to another device.
    public mutating func reset() { consecutiveFailures = 0 }
}

// MARK: - State

/// A snapshot of the Controls tab's settings rows. Every reading is nil until
/// the device answers (unreachable device, or the last poll's command failed).
public struct DeviceSettingsState: Sendable {
    public var fontScale: FontScaleReading?
    public var reduceMotion: ReduceMotionReading?
    public var increaseContrast: SettingsToggleReading?
    public var showBorders: SettingsToggleReading?
    /// The installed TalkBack package, when there is one; the TalkBack row is
    /// hidden while this is nil, and kept from the previous answer when the
    /// package list command fails (so one failure cannot hide the row).
    public var talkBackPackage: String?
    public var voiceOver: VoiceOverReading?
    public var mediaVolume: MediaVolumeReading?
    public var forceRTL: SettingsToggleReading?
    public var wifiVerboseLogging: SettingsToggleReading?
    public var mobileDataAlwaysActive: SettingsToggleReading?
    public var showTaps: SettingsToggleReading?
    public var backgroundANRs: SettingsToggleReading?
    /// Toggles this device cannot change from adb (`DeviceEffects`); their
    /// rows are hidden.
    public var unsupportedToggles: Set<DeviceToggle> = []
    /// The last effective-state snapshot `apply(_:)` took, so the rows can
    /// show how each effect lands (live, after a restart, pending) and the
    /// Battery saver row can tell a charger is connected. nil until the
    /// device answers.
    public private(set) var effects: DeviceEffects?

    public init() {}

    /// Takes the non-key rows (Show Borders and the `readsDeviceEffect`
    /// toggles) from the device's effective state. A missing effect leaves
    /// the row unknown rather than falling back to a key nothing reads.
    public mutating func apply(_ effects: DeviceEffects?) {
        self.effects = effects
        showBorders = effects?.showBorders?.reading
        for toggle in DeviceToggle.allCases where toggle.readsDeviceEffect {
            setReading(effects?.effect(for: toggle)?.reading, for: toggle)
        }
        unsupportedToggles = effects?.unsupportedToggles ?? []
    }

    /// How a `readsDeviceEffect` toggle takes effect on this device (support,
    /// pending state and note); nil for the key-driven toggles and before the
    /// device answers.
    public func effect(for toggle: DeviceToggle) -> ToggleEffect? {
        effects?.effect(for: toggle)
    }

    /// The reading behind a `DeviceToggle` row.
    public func reading(for toggle: DeviceToggle) -> SettingsToggleReading? {
        switch toggle {
        case .showTaps: return showTaps
        case .forceRTL: return forceRTL
        case .showBackgroundANRs: return backgroundANRs
        case .wifiVerboseLogging: return wifiVerboseLogging
        case .mobileDataAlwaysActive: return mobileDataAlwaysActive
        }
    }

    /// Sets the reading behind a `DeviceToggle` row.
    public mutating func setReading(_ reading: SettingsToggleReading?, for toggle: DeviceToggle) {
        switch toggle {
        case .showTaps: showTaps = reading
        case .forceRTL: forceRTL = reading
        case .showBackgroundANRs: backgroundANRs = reading
        case .wifiVerboseLogging: wifiVerboseLogging = reading
        case .mobileDataAlwaysActive: mobileDataAlwaysActive = reading
        }
    }
}
