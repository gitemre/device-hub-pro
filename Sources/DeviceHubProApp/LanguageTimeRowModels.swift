import Foundation
import DeviceHubProKit

// What the Language & time rows show, as pure functions of their readings so
// the wording and the search are unit-tested without a device.

// MARK: - Language

/// The Language row's value: the primary language in its own words and its
/// region's code, plus how many more languages the list has (`Türkçe (TR) +2`).
func languageValueText(_ locales: [DeviceLocale]?) -> String {
    guard let locales, let primary = locales.first else { return "Unknown" }
    let base = shortLanguageName(primary)
    return locales.count > 1 ? "\(base) +\(locales.count - 1)" : base
}

/// The language in its own words with the region's code (`Türkçe (TR)`): the
/// row's value has about 100 pt, where the full name and tag ("English
/// (United States) · en-US") were cut off. The picker keeps the full names.
func shortLanguageName(_ locale: DeviceLocale) -> String {
    guard !locale.baseTag.hasSuffix("-XA"), !locale.baseTag.hasSuffix("-XB"),
          let language = Locale(identifier: locale.tag).localizedString(forLanguageCode: locale.language)
    else { return DeviceLocaleNames.nativeName(locale) }
    let name = language.prefix(1).uppercased() + language.dropFirst()
    return locale.region.map { "\(name) (\($0))" } ?? name
}

/// A language's detail in the picker: its English name and tag.
func languageDetail(_ locale: DeviceLocale) -> String {
    let english = DeviceLocaleNames.englishName(locale)
    let native = DeviceLocaleNames.nativeName(locale)
    return english == native ? locale.tag : "\(english) · \(locale.tag)"
}

/// Whether a language matches the picker's search: its native or English
/// name or its tag, ignoring case and accents.
func languageMatches(_ locale: DeviceLocale, query: String) -> Bool {
    LanguageSearchIndex.matches(key: LanguageSearchIndex.key(for: locale), query: query)
}

/// The language pickers' search keys: each language's native name, English
/// name and tag, folded (case and accents) once when the device's list is
/// read. A keystroke then compares plain strings instead of asking CLDR for
/// two names of each of the ~700 languages a device lists.
struct LanguageSearchIndex {
    private let keys: [DeviceLocale.ID: String]

    init(_ locales: [DeviceLocale]) {
        var keys: [DeviceLocale.ID: String] = [:]
        keys.reserveCapacity(locales.count)
        for locale in locales where keys[locale.id] == nil {
            keys[locale.id] = Self.key(for: locale)
        }
        self.keys = keys
    }

    /// How many languages are keyed.
    var count: Int { keys.count }

    /// Whether `locale` matches `query`; a language outside the list (a preset
    /// before the list is read) is keyed on the spot.
    func matches(_ locale: DeviceLocale, query: String) -> Bool {
        Self.matches(key: keys[locale.id] ?? Self.key(for: locale), query: query)
    }

    /// The three fields on separate lines, so a query never matches across two.
    static func key(for locale: DeviceLocale) -> String {
        fold([DeviceLocaleNames.nativeName(locale), DeviceLocaleNames.englishName(locale), locale.tag]
            .joined(separator: "\n"))
    }

    static func matches(key: String, query: String) -> Bool {
        key.range(of: fold(query)) != nil
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// When a Language change lands: the row's help.
let languageApplyNote = "Applies live; open apps restart their screens."

/// The caption under the Language row: what picking a language replaces when
/// the list has more than one language or carries regional preferences
/// (nil otherwise; when a change lands is in the row's help).
func languageCaption(current: [DeviceLocale]?) -> String? {
    guard let current, current.count > 1 || current.contains(where: { !$0.extensions.isEmpty }) else {
        return nil
    }
    return "Choosing a language replaces the list (\(DeviceLocaleList.tags(current))) and its regional preferences; Restore puts them back."
}

// MARK: - App language

/// The App language row's value: `System default` for an app that follows the
/// system, else its first language.

// MARK: - Time zone

/// The Time zone row's value from the device (`Asia/Tokyo · GMT+09:00`).
/// The Time zone row's value: the zone's city, as the Mac's Date & Time
/// settings name it ("Europe/Istanbul" → "Istanbul"); the full identifier and
/// the offset are in `timeZoneHelpText` (the full pair was cut off).
func timeZoneValueText(identifier: String?) -> String {
    guard let identifier else { return "Unknown" }
    return identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? identifier
}

/// The zone the device reports, in full, for the Time zone row's help.
func timeZoneHelpText(identifier: String?, offsetSeconds: Int?) -> String? {
    guard let identifier else { return nil }
    guard let offsetSeconds else { return "The device reports \(identifier)." }
    return "The device reports \(identifier) (\(TimeZonePresets.gmtLabel(offsetSeconds: offsetSeconds)))."
}

/// A zone's detail in the picker: its offset right now, from the Mac's zone data.
func timeZoneDetail(_ identifier: String, at date: Date = Date()) -> String? {
    TimeZone(identifier: identifier).map { TimeZonePresets.gmtLabel(offsetSeconds: $0.secondsFromGMT(for: date)) }
}

func timeZoneMatches(_ identifier: String, query: String) -> Bool {
    let normalized = query.replacingOccurrences(of: " ", with: "_")
    return identifier.range(of: normalized, options: [.caseInsensitive, .diacriticInsensitive]) != nil
}

/// Every zone the Mac knows, for the full list (the device ignores one its own
/// data lacks, which the write's read-back reports).
func allTimeZoneIdentifiers() -> [String] {
    TimeZone.knownTimeZoneIdentifiers.sorted()
}

/// A time zone as a picker option.
struct TimeZoneOption: Identifiable, Hashable {
    let id: String
}

// MARK: - Clock

/// The device's clock in its own zone (`25 Sep at 13:38` in en_GB): no weekday, so it
/// fits the row beside its button.
func deviceClockText(
    deviceEpochSeconds: Double?,
    zoneIdentifier: String?,
    offsetSeconds: Int?,
    locale: Locale = .current
) -> String {
    guard let deviceEpochSeconds else { return "Unknown" }
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = zoneIdentifier.flatMap(TimeZone.init(identifier:))
        ?? offsetSeconds.flatMap(TimeZone.init(secondsFromGMT:))
        ?? TimeZone(secondsFromGMT: 0)
    formatter.setLocalizedDateFormatFromTemplate("dMMMHHmm")
    return formatter.string(from: Date(timeIntervalSince1970: deviceEpochSeconds))
}

/// How far the device clock is from the Mac's (`in step with the Mac`,
/// `1 h 5 min ahead of the Mac`, `3 days behind the Mac`). Within a few
/// seconds counts as in step: the read carries adb latency and whole seconds.
func clockOffsetText(seconds: Double) -> String {
    let magnitude = abs(seconds)
    guard magnitude >= 3 else { return "In step with the Mac" }
    let direction = seconds > 0 ? "ahead of" : "behind"
    let total = Int(magnitude.rounded())
    let days = total / 86_400
    let hours = (total % 86_400) / 3600
    let minutes = (total % 3600) / 60
    let secondsPart = total % 60
    var parts: [String] = []
    if days > 0 { parts.append(days == 1 ? "1 day" : "\(days) days") }
    if hours > 0 { parts.append("\(hours) h") }
    if minutes > 0, days == 0 { parts.append("\(minutes) min") }
    if parts.isEmpty { parts.append("\(secondsPart) s") }
    return "\(parts.joined(separator: " ")) \(direction) the Mac"
}

/// The device clock's offset from the Mac, from one poll's reading.
func clockOffsetSeconds(deviceEpochSeconds: Double?, hostDate: Date?) -> Double? {
    guard let deviceEpochSeconds, let hostDate else { return nil }
    return deviceEpochSeconds - hostDate.timeIntervalSince1970
}

/// The clock popover's quick steps, applied to the device's current time.
enum ClockStep: String, CaseIterable, Identifiable {
    case plusHour
    case plusDay
    case plusWeek

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plusHour: return "+1 hour"
        case .plusDay: return "+1 day"
        case .plusWeek: return "+7 days"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .plusHour: return 3600
        case .plusDay: return 86_400
        case .plusWeek: return 7 * 86_400
        }
    }
}

// MARK: - 24-hour time

/// A 24-hour option's title; the locale default says which format the
/// device's language uses (`Locale default (12-hour)`).
/// The 24-hour time row's value: "Automatic" for the locale default (the
/// popup keeps `timeFormatTitle`'s full title, which was cut off here).
func timeFormatValueTitle(_ setting: TimeFormatSetting) -> String {
    setting == .localeDefault ? "Automatic" : setting == .twelveHour ? "12-hour" : "24-hour"
}

func timeFormatTitle(_ setting: TimeFormatSetting, locales: [DeviceLocale]?) -> String {
    switch setting {
    case .twelveHour:
        return "12-hour"
    case .twentyFourHour:
        return "24-hour"
    case .localeDefault:
        guard let primary = locales?.first else { return "Locale default" }
        return TimeFormatSetting.localeUses24Hour(primary)
            ? "Locale default (24-hour)"
            : "Locale default (12-hour)"
    }
}
