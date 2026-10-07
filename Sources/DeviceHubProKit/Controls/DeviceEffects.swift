import Foundation

// MARK: - Toggle effects

/// How a Controls toggle takes effect on this device.
public enum ToggleSupport: Sendable, Equatable {
    /// Applied at once; the reading is what the device does right now.
    case live
    /// Stored now and applied by Android at the next restart: the shell
    /// cannot push the configuration change Developer Options pushes.
    case afterRestart
    /// This device cannot change it from adb; the reason says why.
    case unsupported(String)
}

/// A Controls toggle whose effect is not a plain settings key, read from the
/// mechanism that actually drives it (a SurfaceFlinger transaction, a system
/// property, the Wi-Fi service, the battery saver state machine) instead of
/// the key the old code wrote.
public struct ToggleEffect: Sendable, Equatable {
    /// What the row's switch shows. For a live toggle this is the effect in
    /// place; for an after-restart toggle it is the stored request — what
    /// Developer Options' own switch shows.
    public var reading: SettingsToggleReading
    public var support: ToggleSupport
    /// True while the device does not do what `reading` says yet (a restart
    /// is pending).
    public var isPending: Bool
    /// A user-facing explanation when the effect is pending or refused.
    public var note: String?

    public init(
        reading: SettingsToggleReading,
        support: ToggleSupport,
        isPending: Bool = false,
        note: String? = nil
    ) {
        self.reading = reading
        self.support = support
        self.isPending = isPending
        self.note = note
    }

    public var isSupported: Bool {
        if case .unsupported = support { return false }
        return true
    }
}

/// What a toggle write did.
public enum ToggleWriteOutcome: Sendable, Equatable {
    case applied
    /// Stored; Android applies it when the device restarts.
    case appliesAfterRestart

    /// The status line for the write.
    public func statusMessage(label: String, enabled: Bool) -> String {
        let base = "\(label) turned \(enabled ? "on" : "off")"
        switch self {
        case .applied: return base
        case .appliesAfterRestart: return "\(base) — applies after the device restarts"
        }
    }
}

/// Why a toggle write was refused.
public enum DeviceSettingsError: Error, Equatable, CustomStringConvertible {
    /// The device cannot change this toggle from adb.
    case unsupported(toggle: String, reason: String)
    /// Android refuses battery saver while a charger is connected.
    case batterySaverRefusedWhileCharging
    /// The write went through but the device did not take it.
    case notApplied(toggle: String)

    public var description: String {
        switch self {
        case .unsupported(let toggle, let reason):
            return "\(toggle) can't be changed on this device: \(reason)"
        case .batterySaverRefusedWhileCharging:
            return "Battery saver can't turn on while the device is charging. Turn Charging off first."
        case .notApplied(let toggle):
            return "The device did not apply \(toggle)."
        }
    }
}

// MARK: - Device effects snapshot

/// The effective state of the Controls rows whose Android setting is not a
/// plain settings key, read in one `adb shell` round trip
/// (`AdbClient.deviceEffects(serial:)`). The Controls panel polls it every
/// two seconds, so every source it reads on each poll is a property, a
/// settings key or a short command; the one expensive source (the Wi-Fi
/// service dump, Android 11 and older) is cached (`DeviceEffectsCache`).
public struct DeviceEffects: Sendable, Equatable {
    public var apiLevel: Int?
    /// Show layout bounds: the `debug.layout` system property.
    public var showBorders: ToggleEffect?
    public var forceRTL: ToggleEffect?
    public var wifiVerboseLogging: ToggleEffect?
    /// Battery saver as it is in effect: never on while a charger is
    /// connected, whatever `low_power` says.
    public var batterySaver: ToggleEffect?
    /// Whether the device reports a charger (battery saver refuses to turn
    /// on then), from the battery service.
    public var isPowered: Bool?

    public init() {}

    /// The effect behind a `DeviceToggle` row whose mechanism is not a plain
    /// settings key (`DeviceToggle.readsDeviceEffect`); nil for the others.
    public func effect(for toggle: DeviceToggle) -> ToggleEffect? {
        switch toggle {
        case .forceRTL: return forceRTL
        case .wifiVerboseLogging: return wifiVerboseLogging
        case .showTaps, .showBackgroundANRs, .mobileDataAlwaysActive: return nil
        }
    }

    /// The toggles this device cannot change from adb.
    public var unsupportedToggles: Set<DeviceToggle> {
        Set(DeviceToggle.allCases.filter { effect(for: $0).map { !$0.isSupported } ?? false })
    }
}

// MARK: - Probe script and parsing

extension DeviceEffects {
    /// Android 11 moved Wi-Fi verbose logging and scan throttling into the
    /// Wi-Fi module's WifiSettingsConfigStore; the Global keys are only
    /// migrated once.
    static let wifiModuleMinimumAPI = 30
    /// `cmd wifi is-verbose-logging` exists from Android 12.
    static let wifiVerboseQueryMinimumAPI = 31

    /// Section markers of the probe script's output.
    enum Section: String, CaseIterable {
        case sdk
        case layout
        case rtlKey = "rtl-key"
        case rtlProperty = "rtl-prop"
        case config
        case wifiVerbose = "wifi-verbose"
        /// Slow source: only in `probeScript(includingSlowSources: true)`.
        case wifiVerboseDump = "wifi-verbose-dump"
        case wifiVerboseKey = "wifi-verbose-key"
        case lowPower = "low-power"
        case battery

        var marker: String { "@@devicehubpro:\(rawValue)" }
    }

    /// One shell line that prints every source under its marker. The API
    /// gates run on the device.
    ///
    /// Everything but the slow sources is cheap enough for the two-second
    /// poll. The slow source is the Wi-Fi service dump, the only place
    /// Android 11 and older report verbose logging: `head` does not stop
    /// dumpsys from producing the whole multi-hundred-KB dump, and on
    /// Android 11 the dump also polls link-layer stats and RSSI through the
    /// Wi-Fi HAL. Battery saver needs no dump at all: its `low_power` key is
    /// what the state machine keeps, and the battery service's short dump
    /// tells whether a charger vetoes it.
    static func probeScript(includingSlowSources: Bool) -> String {
        func mark(_ section: Section) -> String { "echo \(section.marker)" }
        var lines = [
            "sdk=$(getprop ro.build.version.sdk)",
            mark(.sdk), "echo $sdk",
            mark(.layout), "getprop debug.layout",
            mark(.rtlKey), "settings get global debug.force_rtl",
            mark(.rtlProperty), "getprop debug.force_rtl",
            mark(.config), "am get-config 2>/dev/null | grep '^config:'",
            mark(.wifiVerbose),
            "if [ \"$sdk\" -ge \(wifiVerboseQueryMinimumAPI) ]; then cmd wifi is-verbose-logging 2>&1; fi",
        ]
        if includingSlowSources {
            lines += [
                mark(.wifiVerboseDump),
                "if [ \"$sdk\" -lt \(wifiVerboseQueryMinimumAPI) ]; then "
                    + "dumpsys wifi 2>/dev/null | grep 'Verbose logging is' | head -n 1; fi",
            ]
        }
        lines += [
            mark(.wifiVerboseKey), "settings get global wifi_verbose_logging_enabled",
            mark(.lowPower), "settings get global low_power",
            mark(.battery), "dumpsys battery 2>/dev/null | grep 'powered: '",
            "true",
        ]
        return lines.joined(separator: "; ")
    }

    /// Splits the probe output into its sections.
    static func sections(from output: String) -> [Section: String] {
        var result: [Section: [String]] = [:]
        var current: Section?
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let section = Section.allCases.first(where: { $0.marker == line }) {
                current = section
                result[section] = []
                continue
            }
            guard let current else { continue }
            result[current, default: []].append(rawLine)
        }
        return result.mapValues {
            $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Builds the snapshot from the probe script's output.
    public static func parse(_ output: String) -> DeviceEffects {
        parse(sections: sections(from: output))
    }

    /// Builds the snapshot from the probe's sections (a slow source may come
    /// from `DeviceEffectsCache` instead of this probe).
    static func parse(sections: [Section: String]) -> DeviceEffects {
        var effects = DeviceEffects()
        let api = sections[.sdk].flatMap { Int($0) }
        effects.apiLevel = api

        if let layout = sections[.layout] {
            effects.showBorders = ToggleEffect(reading: propertyReading(layout), support: .live)
        }

        effects.forceRTL = forceRTL(
            key: sections[.rtlKey],
            property: sections[.rtlProperty],
            config: sections[.config],
            api: api
        )
        // `cmd wifi` answers on API 31+, the dump before; the other
        // section is empty then.
        effects.wifiVerboseLogging = wifiVerboseLogging(
            api: api,
            state: [sections[.wifiVerbose], sections[.wifiVerboseDump]]
                .compactMap { $0 }
                .first { !$0.isEmpty },
            key: sections[.wifiVerboseKey]
        )

        effects.isPowered = sections[.battery].flatMap(isPowered(fromBatteryDump:))
        effects.batterySaver = batterySaver(key: sections[.lowPower], isPowered: effects.isPowered)
        return effects
    }

    // MARK: Parsers

    /// A boolean system property: `true`/`1` on, `false`/`0`/empty (unset) off.
    static func propertyReading(_ value: String) -> SettingsToggleReading {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1": return .on
        case "false", "0", "": return .off
        default: return .unreadable
        }
    }

    /// The global configuration's layout direction from `am get-config`
    /// (`config: …-en-rUS-ldrtl-…`): true for RTL, nil when absent.
    static func configurationIsRTL(_ config: String) -> Bool? {
        guard let line = config.components(separatedBy: .newlines).first(where: { $0.hasPrefix("config:") }) else {
            return nil
        }
        let qualifiers = line.dropFirst("config:".count)
            .trimmingCharacters(in: .whitespaces)
            .split(separator: "-")
        if qualifiers.contains("ldrtl") { return true }
        if qualifiers.contains("ldltr") { return false }
        return nil
    }

    /// Force RTL. Developer Options writes the `debug.force_rtl` Global key
    /// and system property, then pushes a locale update so the configuration
    /// recomputes its layout direction (RtlLayoutPreferenceController →
    /// LocalePicker.updateLocales). From API 26 the shell pushes that update
    /// through the language helper (`AdbClient.applyForceRTL`), so the row is
    /// live there; before, a change lands when the device restarts
    /// (ActivityTaskManagerService copies the key into the property at boot).
    /// The switch shows the stored request, like Developer Options;
    /// `isPending` tells whether the configuration's layout direction does not
    /// follow it yet, in either direction, which on a live device means the
    /// push failed (or the key and the property disagree) and the change
    /// waits for a restart.
    static func forceRTL(key: String?, property: String?, config: String?, api: Int?) -> ToggleEffect? {
        guard let key else { return nil }
        let requested = SettingsToggleReading.parse(key)
        let appliesLive = (api ?? 0) >= LanguageTimeSupport.localeHelperMinimumAPI
        guard let isRequested = requested.isOn else {
            return ToggleEffect(reading: .unreadable, support: appliesLive ? .live : .afterRestart)
        }
        let isRTL = config.flatMap(configurationIsRTL)
        // The direction the request leads to, as `applyForceRTL` checks it:
        // right to left when Force RTL is on or the primary language is RTL
        // (forcing LTR back cannot flip an RTL language).
        let rightToLeftLanguage = config.flatMap(DeviceLocaleList.fromConfiguration)?.first
            .map(DeviceLocaleList.isRightToLeft) ?? false
        let expectsRTL = isRequested || rightToLeftLanguage
        let pending = isRTL.map { $0 != expectsRTL } ?? false
        if appliesLive && !pending {
            return ToggleEffect(reading: requested, support: .live)
        }
        let note: String? = switch (pending, expectsRTL, appliesLive) {
        case (false, _, _): nil
        case (true, true, true): "Force RTL did not apply live; it applies after the device restarts."
        case (true, true, false): "Force RTL applies after the device restarts."
        case (true, false, _): "The device stays right to left until it restarts."
        }
        return ToggleEffect(reading: requested, support: .afterRestart, isPending: pending, note: note)
    }

    /// Wi-Fi verbose logging. API 30+: the Wi-Fi service's own state
    /// (`cmd wifi is-verbose-logging`, or its cached dump on API 30), changed
    /// live with `cmd wifi set-verbose-logging`. Older images read the Global
    /// key only when the Wi-Fi service starts, so a change applies after a
    /// restart there; the cached dump only tells whether one is pending.
    static func wifiVerboseLogging(api: Int?, state: String?, key: String?) -> ToggleEffect? {
        let effective = state.flatMap(wifiVerboseState)
        if let api, api >= wifiModuleMinimumAPI {
            guard let effective else {
                return ToggleEffect(reading: .unreadable, support: .live)
            }
            return ToggleEffect(reading: effective ? .on : .off, support: .live)
        }
        guard let key else { return nil }
        let requested = SettingsToggleReading.parse(key)
        let pending = requested.isOn.map { requestedOn in
            effective.map { $0 != requestedOn } ?? false
        } ?? false
        return ToggleEffect(
            reading: requested,
            support: .afterRestart,
            isPending: pending,
            note: pending ? "Wi-Fi verbose logging applies after the device restarts." : nil
        )
    }

    /// `enabled`/`disabled` (cmd wifi) or `Verbose logging is on|off` (dump).
    static func wifiVerboseState(_ text: String) -> Bool? {
        let lower = text.lowercased()
        if lower.contains("verbose logging is on") { return true }
        if lower.contains("verbose logging is off") { return false }
        switch lower.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "enabled": return true
        case "disabled": return false
        default: return nil
        }
    }

    /// Battery saver as it is in effect. The battery saver state machine
    /// (and PowerManagerService before it, API 26-27) writes `low_power`
    /// whenever it enables or disables saver, turns saver off when a charger
    /// is plugged in, and refuses to enable it on a charger ("Can't enable:
    /// isPowered") — but a key written straight to 1 there stays 1. So saver
    /// is on when the key is 1 and no charger is connected. The one case
    /// this misreads is a key some other tool wrote to 1 on a charger, after
    /// the charger is unplugged; Device Hub Pro's own write never leaves the key
    /// that way (`AdbClient.applyBatterySaver`).
    static func batterySaver(key: String?, isPowered: Bool?) -> ToggleEffect? {
        guard let key else { return nil }
        let requested = SettingsToggleReading.parse(key)
        guard let isRequested = requested.isOn else {
            return ToggleEffect(reading: .unreadable, support: .live)
        }
        let isOn = isRequested && isPowered != true
        return ToggleEffect(
            reading: isOn ? .on : .off,
            support: .live,
            note: !isOn && isPowered == true ? "Battery saver can't turn on while the device is charging." : nil
        )
    }

    /// Whether any charger is connected, from the battery service's dump
    /// (`  AC powered: true`, USB, Wireless and, from API 33, Dock): the
    /// same flags PowerManagerService's `mIsPowered` is computed from. nil
    /// when no line parses.
    static func isPowered(fromBatteryDump dump: String) -> Bool? {
        var flags: [Bool] = []
        for rawLine in dump.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let range = line.range(of: " powered: ") else { continue }
            guard let flag = Bool(line[range.upperBound...].trimmingCharacters(in: .whitespaces)) else { continue }
            flags.append(flag)
        }
        return flags.isEmpty ? nil : flags.contains(true)
    }
}

// MARK: - Slow-source cache

/// The last Wi-Fi service dump per device, so the two-second Controls poll
/// dumps Wi-Fi once per `lifetime` instead of every poll. On Android 11 the
/// dump is the verbose-logging row's live reading, and a change made on the
/// device shows up within `lifetime`; before Android 11 it only tells
/// whether a stored change still waits for a restart. A write through
/// `AdbClient` refreshes it: for `refreshWindow` after the write every probe
/// reads the dump again, so the reconcile's retries see the new state.
final class DeviceEffectsCache: @unchecked Sendable {
    static let shared = DeviceEffectsCache()
    static let lifetime: Duration = .seconds(60)
    static let refreshWindow: Duration = .seconds(3)

    private struct Entry {
        var wifiVerboseDump: String?
        var readAt: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var refreshUntil: [String: ContinuousClock.Instant] = [:]

    /// Whether the probe for `device` must read the slow sources itself.
    func needsSlowSources(for device: String, at now: ContinuousClock.Instant) -> Bool {
        lock.withLock {
            if let until = refreshUntil[device], now < until { return true }
            guard let entry = entries[device] else { return true }
            return now - entry.readAt >= Self.lifetime
        }
    }

    func store(wifiVerboseDump: String?, for device: String, at now: ContinuousClock.Instant) {
        lock.withLock {
            entries[device] = Entry(wifiVerboseDump: wifiVerboseDump, readAt: now)
        }
    }

    func wifiVerboseDump(for device: String) -> String? {
        lock.withLock { entries[device]?.wifiVerboseDump }
    }

    /// A write may have changed a slow source: re-read it for the next
    /// `refreshWindow`.
    func invalidate(_ device: String, at now: ContinuousClock.Instant = .now) {
        lock.withLock {
            refreshUntil[device] = now + Self.refreshWindow
        }
    }
}
