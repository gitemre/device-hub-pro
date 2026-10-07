import Foundation

// MARK: - Language tags

/// One language of the device's language list, as a BCP 47 tag the way Android
/// writes it (`LocaleList.toLanguageTags()`): `tr-TR`, `zh-Hans-CN`,
/// `en-US-u-mu-celsius`. The tag is normalized so tags from every source compare:
/// the language in lower case with Java's legacy codes replaced (`iw` → `he`,
/// `in` → `id`, `ji` → `yi`: the framework's `supported_locales` resource still
/// lists `iw-IL`), the script in title case, the region in upper case and the
/// extensions (`-u-…`, `-x-…`) in lower case.
public struct DeviceLocale: Hashable, Sendable, Identifiable, CustomStringConvertible {
    /// The whole normalized tag, extensions included.
    public let tag: String
    public let language: String
    public let script: String?
    public let region: String?
    /// `-u-…` / `-x-…` and anything else after the region, lower case; empty
    /// when the tag has none.
    public let extensions: String

    public var id: String { tag }
    public var description: String { tag }

    /// The tag without its extensions. The configuration's resource qualifiers
    /// (`am get-config`) carry no extensions, so read-backs compare this.
    public var baseTag: String {
        [language, script, region].compactMap { $0 }.joined(separator: "-")
    }

    /// Android's pseudo-locales: accented English and bidi (mirrored) Arabic.
    public var isPseudo: Bool { baseTag == "en-XA" || baseTag == "ar-XB" }

    /// Legacy ISO 639 codes Java still uses and their current forms.
    static let legacyLanguages = ["iw": "he", "in": "id", "ji": "yi"]

    public init?(tag raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first,
              (2...8).contains(first.count),
              first.allSatisfy({ $0.isASCII && $0.isLetter })
        else { return nil }
        let lowered = first.lowercased()
        language = Self.legacyLanguages[lowered] ?? lowered

        var index = 1
        var script: String?
        var region: String?
        if index < parts.count, parts[index].count == 4, parts[index].allSatisfy({ $0.isASCII && $0.isLetter }) {
            script = parts[index].prefix(1).uppercased() + parts[index].dropFirst().lowercased()
            index += 1
        }
        if index < parts.count {
            let candidate = parts[index]
            let isAlphaRegion = candidate.count == 2 && candidate.allSatisfy { $0.isASCII && $0.isLetter }
            let isNumericRegion = candidate.count == 3 && candidate.allSatisfy { $0.isASCII && $0.isNumber }
            if isAlphaRegion || isNumericRegion {
                region = candidate.uppercased()
                index += 1
            }
        }
        let rest = parts[index...]
        guard rest.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }) else {
            return nil
        }
        self.script = script
        self.region = region
        extensions = rest.joined(separator: "-").lowercased()
        tag = extensions.isEmpty
            ? [language, script, region].compactMap { $0 }.joined(separator: "-")
            : [language, script, region].compactMap { $0 }.joined(separator: "-") + "-" + extensions
    }
}

/// Comma-separated language lists and the configuration's locale qualifiers.
public enum DeviceLocaleList {
    /// Parses `tr-TR,de-DE,en-US` (`LocaleList.toLanguageTags()`, the
    /// `system_locales` setting, `get-app-locales`). `null`, blank and
    /// malformed entries are dropped.
    public static func parse(_ text: String) -> [DeviceLocale] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else { return [] }
        return trimmed.split(separator: ",").compactMap { DeviceLocale(tag: String($0)) }
    }

    /// The list in the form every writer takes: tags joined by commas.
    public static func tags(_ list: [DeviceLocale]) -> String {
        list.map(\.tag).joined(separator: ",")
    }

    /// Whether two lists name the same languages in the same order, ignoring
    /// extensions (the configuration drops them).
    public static func sameLanguages(_ lhs: [DeviceLocale], _ rhs: [DeviceLocale]) -> Bool {
        lhs.map(\.baseTag) == rhs.map(\.baseTag)
    }

    /// The global configuration's language list from `am get-config`
    /// (`config: mcc310-mnc260-tr-rTR,de-rDE,en-rUS-ldrtl-…`): where Android
    /// applies the language, so every Language read-back comes from here. The
    /// qualifiers write a locale as `tr-rTR`, or `b+zh+Hans+CN` when it has a
    /// script, and join a list with commas (Configuration.resourceQualifierString).
    /// nil when there is no `config:` line or it names no language.
    public static func fromConfiguration(_ output: String) -> [DeviceLocale]? {
        guard let line = output.components(separatedBy: .newlines)
            .first(where: { $0.hasPrefix("config:") })
        else { return nil }
        var qualifiers = line.dropFirst("config:".count).trimmingCharacters(in: .whitespaces)
        for prefix in ["mcc", "mnc"] {
            if qualifiers.hasPrefix(prefix),
               let dash = qualifiers.firstIndex(of: "-"),
               qualifiers[qualifiers.index(qualifiers.startIndex, offsetBy: 3)..<dash].allSatisfy(\.isNumber) {
                qualifiers = String(qualifiers[qualifiers.index(after: dash)...])
            }
        }
        let pattern = #"^((?:b\+[A-Za-z0-9+]+|[a-z]{2,3}(?:-r[A-Z0-9]{2,3})?)(?:,(?:b\+[A-Za-z0-9+]+|[a-z]{2,3}(?:-r[A-Z0-9]{2,3})?))*)(?:-|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: qualifiers, range: NSRange(qualifiers.startIndex..., in: qualifiers)),
              let range = Range(match.range(at: 1), in: qualifiers)
        else { return nil }
        let locales = qualifiers[range].split(separator: ",").compactMap { qualifier -> DeviceLocale? in
            if qualifier.hasPrefix("b+") {
                return DeviceLocale(tag: qualifier.dropFirst(2).replacingOccurrences(of: "+", with: "-"))
            }
            return DeviceLocale(tag: qualifier.replacingOccurrences(of: "-r", with: "-"))
        }
        return locales.isEmpty ? nil : locales
    }

    /// The list to restore later: the persisted `system_locales` copy when it
    /// names the languages the configuration runs (it keeps the `-u-`
    /// regional preferences the configuration drops), else the configuration's
    /// own list. A stale persisted copy (written without a configuration
    /// change) is never trusted: Android would apply it at the next boot.
    public static func restorable(configuration: [DeviceLocale], persisted: [DeviceLocale]?) -> [DeviceLocale] {
        if let persisted, !persisted.isEmpty, sameLanguages(persisted, configuration) {
            return persisted
        }
        return configuration
    }

    /// Whether `locale` lays text out right to left (Arabic, Hebrew, Persian, Urdu,
    /// the bidi pseudo-locale, …).
    public static func isRightToLeft(_ locale: DeviceLocale) -> Bool {
        if locale.baseTag == "ar-XB" { return true }
        if locale.baseTag == "en-XA" { return false }
        return Locale.Language(identifier: locale.baseTag).characterDirection == .rightToLeft
    }
}

// MARK: - Language presets and names

/// The Language row's pinned languages: the locales QA passes reach for
/// (long strings, plurals, the dotted/dotless I, right-to-left scripts,
/// Devanagari, CJK) and the two pseudo-locales.
public enum DeviceLocalePresets {
    public static let tags = [
        "en-US", "en-GB", "de-DE", "fr-FR", "es-ES", "pt-BR", "ru-RU", "tr-TR",
        "ar-EG", "he-IL", "ja-JP", "zh-CN", "hi-IN", "en-XA", "ar-XB",
    ]

    /// The presets this device can run. With the device's list known, each
    /// preset resolves to the listed tag with its language and region
    /// (`zh-CN` → `zh-Hans-CN`) and the unlisted ones drop out; without a list,
    /// every preset but the pseudo-locales (only some images ship them) stays.
    public static func resolved(against supported: [DeviceLocale]?) -> [DeviceLocale] {
        let presets = tags.compactMap(DeviceLocale.init(tag:))
        guard let supported, !supported.isEmpty else {
            return presets.filter { !$0.isPseudo }
        }
        var seen = Set<String>()
        return presets.compactMap { preset -> DeviceLocale? in
            let plain = supported.filter { $0.extensions.isEmpty }
            let match = plain.first { $0.baseTag == preset.baseTag }
                ?? plain.first { $0.language == preset.language && $0.region == preset.region }
            guard let match, seen.insert(match.tag).inserted else { return nil }
            return match
        }
    }
}

// MARK: - Time format

/// The 24-hour switch: `settings system time_12_24` (`12`, `24`, or unset for
/// the language's own format), the key DateFormat.is24HourFormat reads.
public enum TimeFormatSetting: String, CaseIterable, Identifiable, Sendable {
    case localeDefault
    case twelveHour
    case twentyFourHour

    public var id: String { rawValue }

    /// The value written, nil for the locale default (the key is deleted).
    public var settingsValue: String? {
        switch self {
        case .localeDefault: return nil
        case .twelveHour: return "12"
        case .twentyFourHour: return "24"
        }
    }

    /// `12`, `24` or `null`; anything else is unreadable (nil).
    public static func parse(_ output: String) -> TimeFormatSetting? {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "12": return .twelveHour
        case "24": return .twentyFourHour
        case "null", "": return .localeDefault
        default: return nil
        }
    }

    /// Whether `locale` uses the 24-hour clock by default, the way
    /// DateFormat.is24HourLocale decides it: its long time pattern has an `H`.
    /// Computed from the Mac's CLDR data, which Android's ICU shares.
    public static func localeUses24Hour(_ locale: DeviceLocale) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale.baseTag)
        formatter.dateStyle = .none
        formatter.timeStyle = .long
        let pattern = formatter.dateFormat ?? ""
        var inQuote = false
        for character in pattern {
            if character == "'" { inQuote.toggle(); continue }
            if !inQuote, character == "H" { return true }
        }
        return false
    }
}

// MARK: - Time zones

public enum TimeZonePresets {
    /// The Time zone row's pinned zones: UTC, the big markets, half- and
    /// quarter-hour offsets, a southern-hemisphere DST zone and both ends of
    /// the offset range.
    public static let identifiers = [
        "Etc/UTC", "Europe/London", "Europe/Berlin", "Europe/Istanbul",
        "America/New_York", "America/Los_Angeles", "America/Sao_Paulo", "America/St_Johns",
        "Asia/Dubai", "Asia/Tehran", "Asia/Kolkata", "Asia/Kathmandu", "Asia/Tokyo",
        "Australia/Sydney", "Australia/Lord_Howe", "Pacific/Auckland", "Pacific/Chatham",
        "Pacific/Kiritimati", "Pacific/Pago_Pago",
    ]

    /// `+0900` / `-0330` (`date +%z`) in seconds east of UTC.
    public static func offsetSeconds(fromNumericZone text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 5, let sign = trimmed.first, sign == "+" || sign == "-",
              let hours = Int(trimmed.dropFirst().prefix(2)),
              let minutes = Int(trimmed.suffix(2)),
              minutes < 60
        else { return nil }
        let seconds = hours * 3600 + minutes * 60
        return sign == "-" ? -seconds : seconds
    }

    /// `GMT+09:00`, `GMT-03:30`, `GMT` for zero.
    public static func gmtLabel(offsetSeconds: Int) -> String {
        guard offsetSeconds != 0 else { return "GMT" }
        let sign = offsetSeconds < 0 ? "-" : "+"
        let magnitude = abs(offsetSeconds)
        return String(format: "GMT%@%02d:%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
    }
}

/// `cmd time_zone_detector get_time_zone_state` (API 34+):
/// `TimeZoneState{mZoneId=Europe/Istanbul, mUserShouldConfirmId=true}`.
public struct TimeZoneDetectorState: Sendable, Equatable {
    public let zoneID: String
    public let userShouldConfirmID: Bool

    public init(zoneID: String, userShouldConfirmID: Bool) {
        self.zoneID = zoneID
        self.userShouldConfirmID = userShouldConfirmID
    }

    public static func parse(_ output: String) -> TimeZoneDetectorState? {
        guard let zone = value(of: "mZoneId", in: output),
              let confirm = value(of: "mUserShouldConfirmId", in: output).flatMap(Bool.init)
        else { return nil }
        return TimeZoneDetectorState(zoneID: zone, userShouldConfirmID: confirm)
    }

    private static func value(of field: String, in output: String) -> String? {
        guard let start = output.range(of: field + "=") else { return nil }
        let rest = output[start.upperBound...]
        let end = rest.firstIndex { $0 == "," || $0 == "}" || $0.isNewline } ?? rest.endIndex
        let value = rest[..<end].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

// MARK: - Support probe

/// What the Language & time rows can do on this device, probed once per device
/// in one round trip. Each verb is detected from its service's help text, not
/// from the API level: `cmd locale set-device-locale` arrived in Android 16
/// QPR2 (API 36.1), which `ro.build.version.sdk` cannot tell from 36.0.
public struct LanguageTimeSupport: Sendable, Equatable {
    public var apiLevel: Int?
    /// `cmd locale set-device-locale` (API 36.1+): one listed language.
    public var setDeviceLocaleCommand = false
    public var listDeviceLocalesCommand = false
    /// `cmd alarm set-time` / `set-timezone`: the shell holds SET_TIME and
    /// SET_TIME_ZONE from Android 9 (API 28).
    public var alarmSetTime = false
    public var alarmSetTimeZone = false
    /// `cmd time_zone_detector` / `cmd time_detector` `is_auto_detection_enabled`
    /// (API 31+): where the automatic switches take effect.
    public var timeZoneDetector = false
    public var timeDetector = false
    /// `cmd time_zone_detector set_time_zone_state_for_tests` (API 34+).
    public var timeZoneStateForTests = false
    /// `cmd locale list-device-locales`, when the image has it.
    public var deviceLocales: [DeviceLocale] = []

    public init() {}

    /// The first API level whose shell user may push a configuration
    /// (IActivityManager.updatePersistentConfiguration checks CHANGE_CONFIGURATION
    /// and WRITE_SETTINGS; `ActivityManager.getService()` exists from 8.0).
    public static let localeHelperMinimumAPI = 26
    /// SET_TIME / SET_TIME_ZONE in the Shell manifest.
    public static let alarmCommandsMinimumAPI = 28

    /// Whether the app_process language helper can run.
    public var localeHelper: Bool { (apiLevel ?? 0) >= Self.localeHelperMinimumAPI }

    /// Whether the Language row can change the system language at all.
    public var canSetDeviceLanguage: Bool { setDeviceLocaleCommand || localeHelper }

    enum Section: String, CaseIterable {
        case sdk
        case localeHelp = "locale-help"
        case localeList = "locale-list"
        case alarmHelp = "alarm-help"
        case timeZoneDetectorHelp = "tzd-help"
        case timeDetectorHelp = "td-help"

        var marker: String { "@@devicehubpro-lt:\(rawValue)" }
    }

    /// One shell line. `cmd … help` exits 255 on current images, so each
    /// section is printed whatever its status and the line ends with `true`.
    public static func probeScript() -> String {
        func mark(_ section: Section) -> String { "echo \(section.marker)" }
        return [
            mark(.sdk), "getprop ro.build.version.sdk",
            "help=$(cmd locale help 2>&1)",
            mark(.localeHelp), "echo \"$help\"",
            mark(.localeList),
            "case \"$help\" in *list-device-locales*) cmd locale list-device-locales 2>/dev/null;; esac",
            mark(.alarmHelp), "cmd alarm help 2>&1 | grep -E '^ +set-time'",
            mark(.timeZoneDetectorHelp),
            "cmd time_zone_detector help 2>&1 | grep -E '^ +(is_auto_detection_enabled|set_auto_detection_enabled|set_time_zone_state_for_tests)'",
            mark(.timeDetectorHelp), "cmd time_detector help 2>&1 | grep -E '^ +is_auto_detection_enabled'",
            "true",
        ].joined(separator: "; ")
    }

    public static func parse(_ output: String) -> LanguageTimeSupport {
        let sections = LanguageTimeSections.split(output, markers: Section.allCases.map(\.marker))
        func text(_ section: Section) -> String { sections[section.marker] ?? "" }
        func hasVerb(_ verb: String, in section: Section) -> Bool {
            text(section).components(separatedBy: .newlines).contains { line in
                line.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) == verb
            }
        }

        var support = LanguageTimeSupport()
        support.apiLevel = Int(text(.sdk))
        support.setDeviceLocaleCommand = hasVerb("set-device-locale", in: .localeHelp)
        support.listDeviceLocalesCommand = hasVerb("list-device-locales", in: .localeHelp)
        let alarmsAllowed = (support.apiLevel ?? 0) >= alarmCommandsMinimumAPI
        support.alarmSetTime = alarmsAllowed && hasVerb("set-time", in: .alarmHelp)
        support.alarmSetTimeZone = alarmsAllowed && hasVerb("set-timezone", in: .alarmHelp)
        support.timeZoneDetector = hasVerb("is_auto_detection_enabled", in: .timeZoneDetectorHelp)
            && hasVerb("set_auto_detection_enabled", in: .timeZoneDetectorHelp)
        support.timeZoneStateForTests = hasVerb("set_time_zone_state_for_tests", in: .timeZoneDetectorHelp)
        support.timeDetector = hasVerb("is_auto_detection_enabled", in: .timeDetectorHelp)
        if support.listDeviceLocalesCommand {
            support.deviceLocales = DeviceLocaleNames.sorted(
                text(.localeList).components(separatedBy: .newlines).compactMap(DeviceLocale.init(tag:))
            )
        }
        return support
    }
}

// MARK: - Poll readings

/// The Language & time rows' readings, from one shell round trip every poll.
/// Each value comes from where Android applies it: the language list from the
/// global configuration, the zone from `persist.sys.timezone` (SystemTimeZone
/// writes it), the automatic switches from the detectors on API 31+, the
/// clock from `date`.
public struct LanguageTimeReadings: Sendable, Equatable {
    /// The configuration's languages (`am get-config`).
    public var locales: [DeviceLocale]?
    /// The persisted `system_locales` copy (it keeps `-u-` extensions).
    public var persistedLocales: [DeviceLocale]?
    public var timeZoneID: String?
    /// Seconds east of UTC in the device's zone right now (`date +%z`).
    public var utcOffsetSeconds: Int?
    /// The effective automatic time zone switch: the detector's answer on API
    /// 31+, the Global key before.
    public var autoTimeZone: Bool?
    public var autoTime: Bool?
    public var timeFormat: TimeFormatSetting?
    /// The device's clock as seconds since 1970 (`$EPOCHREALTIME`, microseconds
    /// where mksh has it).
    public var deviceEpochSeconds: Double?

    public init() {}

    enum Section: String, CaseIterable {
        case clock
        case offset
        case config
        case systemLocales = "system-locales"
        case timeZone = "timezone"
        case autoTimeZoneKey = "auto-time-zone"
        case autoTimeKey = "auto-time"
        case timeFormat = "time-12-24"
        case timeZoneDetector = "tz-detector"
        case timeDetector = "time-detector"

        var marker: String { "@@devicehubpro-lt:\(rawValue)" }
    }

    /// The poll's shell line; the detector reads only where `support` found
    /// them (a missing service prints an error the parser would not use).
    public static func probeScript(support: LanguageTimeSupport) -> String {
        func mark(_ section: Section) -> String { "echo \(section.marker)" }
        var lines = [
            mark(.clock), "echo ${EPOCHREALTIME:-$(date +%s)}",
            mark(.offset), "date +%z",
            mark(.config), "am get-config 2>/dev/null | grep '^config:'",
            mark(.systemLocales), "settings get system system_locales",
            mark(.timeZone), "getprop persist.sys.timezone",
            mark(.autoTimeZoneKey), "settings get global auto_time_zone",
            mark(.autoTimeKey), "settings get global auto_time",
            mark(.timeFormat), "settings get system time_12_24",
        ]
        if support.timeZoneDetector {
            lines += [mark(.timeZoneDetector), "cmd time_zone_detector is_auto_detection_enabled 2>/dev/null"]
        }
        if support.timeDetector {
            lines += [mark(.timeDetector), "cmd time_detector is_auto_detection_enabled 2>/dev/null"]
        }
        lines.append("true")
        return lines.joined(separator: "; ")
    }

    public static func parse(_ output: String) -> LanguageTimeReadings {
        let sections = LanguageTimeSections.split(output, markers: Section.allCases.map(\.marker))
        func text(_ section: Section) -> String? { sections[section.marker] }

        var readings = LanguageTimeReadings()
        readings.deviceEpochSeconds = text(.clock).flatMap { Double($0) }
        readings.utcOffsetSeconds = text(.offset).flatMap(TimeZonePresets.offsetSeconds(fromNumericZone:))
        readings.locales = text(.config).flatMap(DeviceLocaleList.fromConfiguration)
        readings.persistedLocales = text(.systemLocales).map(DeviceLocaleList.parse)
        readings.timeZoneID = text(.timeZone).flatMap { $0.isEmpty ? nil : $0 }
        let autoZoneKey = text(.autoTimeZoneKey).flatMap(autoSetting)
        let autoTimeKey = text(.autoTimeKey).flatMap(autoSetting)
        readings.autoTimeZone = text(.timeZoneDetector).flatMap(detectorBoolean) ?? autoZoneKey
        readings.autoTime = text(.timeDetector).flatMap(detectorBoolean) ?? autoTimeKey
        readings.timeFormat = text(.timeFormat).flatMap(TimeFormatSetting.parse)
        return readings
    }

    /// `auto_time` / `auto_time_zone`: 1/0; unset means on (both default on).
    static func autoSetting(_ text: String) -> Bool? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1": return true
        case "0": return false
        case "null": return true
        default: return nil
        }
    }

    static func detectorBoolean(_ text: String) -> Bool? {
        Bool(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// The language list to restore later (`DeviceLocaleList.restorable`).
    public var restorableLocales: [DeviceLocale]? {
        locales.map { DeviceLocaleList.restorable(configuration: $0, persisted: persistedLocales) }
    }
}

/// Splits a probe's output at its marker lines.
enum LanguageTimeSections {
    static func split(_ output: String, markers: [String]) -> [String: String] {
        let known = Set(markers)
        var result: [String: [String]] = [:]
        var current: String?
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if known.contains(line) {
                current = line
                result[line] = []
                continue
            }
            guard let current else { continue }
            result[current, default: []].append(rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
        }
        return result.mapValues {
            $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

// MARK: - Display names

/// Names for the language pickers, from the Mac's CLDR data.
public enum DeviceLocaleNames {
    /// The language in its own words (`Türkçe (Türkiye)`), with the
    /// pseudo-locales spelled out.
    public static func nativeName(_ locale: DeviceLocale) -> String {
        switch locale.baseTag {
        case "en-XA": return "Pseudo (accented English)"
        case "ar-XB": return "Pseudo (bidi Arabic)"
        default: break
        }
        // The whole tag names regional preferences too ("Numbers=Western
        // Digits"); a tag Foundation cannot name falls back to its base.
        let name = [locale.tag, locale.baseTag].lazy.compactMap { identifier in
            Locale(identifier: identifier).localizedString(forIdentifier: identifier)
        }.first
        return name.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? locale.tag
    }

    /// The language in English (`Turkish (Türkiye)`), for search and sorting.
    public static func englishName(_ locale: DeviceLocale) -> String {
        switch locale.baseTag {
        case "en-XA": return "Pseudo (accented English)"
        case "ar-XB": return "Pseudo (bidi Arabic)"
        default:
            let english = Locale(identifier: "en_US")
            return english.localizedString(forIdentifier: locale.tag)
                ?? english.localizedString(forIdentifier: locale.baseTag)
                ?? locale.tag
        }
    }

    /// Sorted by English name, then tag; duplicates removed.
    public static func sorted(_ locales: [DeviceLocale]) -> [DeviceLocale] {
        var seen = Set<String>()
        let unique = locales.filter { seen.insert($0.tag).inserted }
        return unique
            .map { (locale: $0, name: englishName($0)) }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return order == .orderedSame ? lhs.locale.tag < rhs.locale.tag : order == .orderedAscending
            }
            .map(\.locale)
    }
}
