import Foundation

/// A named set of device settings applied in one go (Device Hub Pro's addition
/// beyond Device Hub). Every field is optional: a nil field leaves that
/// setting as it is. Codable, and tolerant when read: a key it does not know
/// is ignored, and a field whose value it cannot read (a later version's
/// new choice) is dropped rather than losing the profile.
public struct SettingsProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String

    public var appearance: ProfileAppearance?
    public var textSize: BatchTextSize?
    public var reduceMotion: Bool?
    public var increaseContrast: Bool?
    /// Android's layout bounds, a simulator's Show Borders.
    public var showBorders: Bool?
    /// TalkBack / VoiceOver. A built-in profile never turns it on.
    public var screenReader: Bool?
    public var location: ProfileLocation?
    /// A BCP 47 tag ("tr-TR").
    public var language: String?
    public var timeFormat: ProfileTimeFormat?
    public var statusBar: ProfileStatusBar?

    public init(
        id: String = UUID().uuidString,
        name: String,
        appearance: ProfileAppearance? = nil,
        textSize: BatchTextSize? = nil,
        reduceMotion: Bool? = nil,
        increaseContrast: Bool? = nil,
        showBorders: Bool? = nil,
        screenReader: Bool? = nil,
        location: ProfileLocation? = nil,
        language: String? = nil,
        timeFormat: ProfileTimeFormat? = nil,
        statusBar: ProfileStatusBar? = nil
    ) {
        self.id = id
        self.name = name
        self.appearance = appearance
        self.textSize = textSize
        self.reduceMotion = reduceMotion
        self.increaseContrast = increaseContrast
        self.showBorders = showBorders
        self.screenReader = screenReader
        self.location = location
        self.language = language
        self.timeFormat = timeFormat
        self.statusBar = statusBar
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, appearance, textSize, reduceMotion, increaseContrast, showBorders
        case screenReader, location, language, timeFormat, statusBar
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        appearance = (try? c.decodeIfPresent(ProfileAppearance.self, forKey: .appearance)) ?? nil
        textSize = (try? c.decodeIfPresent(BatchTextSize.self, forKey: .textSize)) ?? nil
        reduceMotion = (try? c.decodeIfPresent(Bool.self, forKey: .reduceMotion)) ?? nil
        increaseContrast = (try? c.decodeIfPresent(Bool.self, forKey: .increaseContrast)) ?? nil
        showBorders = (try? c.decodeIfPresent(Bool.self, forKey: .showBorders)) ?? nil
        screenReader = (try? c.decodeIfPresent(Bool.self, forKey: .screenReader)) ?? nil
        location = (try? c.decodeIfPresent(ProfileLocation.self, forKey: .location)) ?? nil
        language = (try? c.decodeIfPresent(String.self, forKey: .language)) ?? nil
        timeFormat = (try? c.decodeIfPresent(ProfileTimeFormat.self, forKey: .timeFormat)) ?? nil
        statusBar = (try? c.decodeIfPresent(ProfileStatusBar.self, forKey: .statusBar)) ?? nil
    }

    /// Built-in profiles carry this id prefix; they cannot be renamed or
    /// deleted, only duplicated.
    public static let builtInPrefix = "builtin."

    public var isBuiltIn: Bool { id.hasPrefix(Self.builtInPrefix) }

    /// Whether the profile changes nothing.
    public var isEmpty: Bool { fields.isEmpty }

    /// The fields the profile sets, in the order they are applied, as
    /// (title, value) lines for the manager.
    public var fields: [(title: String, value: String)] {
        var lines: [(title: String, value: String)] = []
        if let appearance { lines.append(("Appearance", appearance.label)) }
        if let textSize { lines.append(("Text Size", textSize.label)) }
        if let reduceMotion { lines.append(("Reduce Motion", reduceMotion ? "On" : "Off")) }
        if let increaseContrast { lines.append(("Increase Contrast", increaseContrast ? "On" : "Off")) }
        if let showBorders { lines.append(("Show Borders", showBorders ? "On" : "Off")) }
        if let screenReader { lines.append(("Screen Reader", screenReader ? "On" : "Off")) }
        if let location { lines.append(("Location", location.label)) }
        if let language { lines.append(("Language", language)) }
        if let timeFormat { lines.append(("Time Format", timeFormat.label)) }
        if let statusBar { lines.append(("Status Bar", statusBar.label)) }
        return lines
    }

    /// A copy under a new identity (Duplicate).
    public func duplicated(named name: String) -> SettingsProfile {
        var copy = self
        copy.id = UUID().uuidString
        copy.name = name
        return copy
    }

    public static func == (lhs: SettingsProfile, rhs: SettingsProfile) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.appearance == rhs.appearance
            && lhs.textSize == rhs.textSize && lhs.reduceMotion == rhs.reduceMotion
            && lhs.increaseContrast == rhs.increaseContrast && lhs.showBorders == rhs.showBorders
            && lhs.screenReader == rhs.screenReader && lhs.location == rhs.location
            && lhs.language == rhs.language && lhs.timeFormat == rhs.timeFormat
            && lhs.statusBar == rhs.statusBar
    }
}

public enum ProfileAppearance: String, Codable, Sendable, CaseIterable {
    case light
    case dark

    public var label: String { self == .dark ? "Dark" : "Light" }
    public var isDark: Bool { self == .dark }
}

public enum ProfileTimeFormat: String, Codable, Sendable, CaseIterable {
    /// The language's own.
    case automatic
    case twelveHour
    case twentyFourHour

    public var label: String {
        switch self {
        case .automatic: "Automatic"
        case .twelveHour: "12-hour"
        case .twentyFourHour: "24-hour"
        }
    }

    public var setting: TimeFormatSetting {
        switch self {
        case .automatic: .localeDefault
        case .twelveHour: .twelveHour
        case .twentyFourHour: .twentyFourHour
        }
    }

    public init(_ setting: TimeFormatSetting) {
        switch setting {
        case .localeDefault: self = .automatic
        case .twelveHour: self = .twelveHour
        case .twentyFourHour: self = .twentyFourHour
        }
    }
}

public enum ProfileStatusBar: String, Codable, Sendable, CaseIterable {
    /// 9:41, full battery, full Wi-Fi and cellular.
    case clean
    /// The device's own status bar again.
    case off

    public var label: String { self == .clean ? "Clean (9:41, full battery)" : "Off" }
    public var isClean: Bool { self == .clean }
}

/// A simulated location, or none (a simulator's cleared one).
public struct ProfileLocation: Codable, Sendable, Equatable {
    public var latitude: Double?
    public var longitude: Double?
    public var name: String?

    public init(latitude: Double, longitude: Double, name: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
    }

    /// No simulated location (not `.none`, which is a nil optional).
    public static let cleared = ProfileLocation()

    private init() {}

    public var coordinate: (latitude: Double, longitude: Double)? {
        guard let latitude, let longitude else { return nil }
        return (latitude, longitude)
    }

    public var label: String {
        guard let coordinate else { return "None" }
        if let name, !name.isEmpty { return name }
        return String(format: "%.4f, %.4f", locale: Locale(identifier: "en_US_POSIX"), coordinate.latitude, coordinate.longitude)
    }
}

extension BatchTextSize: Codable {}

extension BatchTextSize {
    /// The step whose scale is nearest `scale`.
    public static func nearest(toScale scale: Double) -> BatchTextSize {
        allCases.min { abs($0.scale - scale) < abs($1.scale - scale) } ?? .standard
    }
}

// MARK: - Built-ins and persistence

public enum SettingsProfiles {
    public static let screenshots = SettingsProfile(
        id: "builtin.screenshots", name: "Screenshots",
        textSize: .standard, statusBar: .clean
    )
    public static let darkMode = SettingsProfile(
        id: "builtin.dark-mode", name: "Dark Mode", appearance: .dark
    )
    public static let accessibilityStress = SettingsProfile(
        id: "builtin.accessibility-stress", name: "Accessibility Stress",
        textSize: .doubled, reduceMotion: true, increaseContrast: true
    )
    /// Everything back, as Reset to Defaults does on a simulator.
    public static let defaults = SettingsProfile(
        id: "builtin.defaults", name: "Defaults",
        appearance: .light, textSize: .standard, reduceMotion: false, increaseContrast: false,
        showBorders: false, screenReader: false, location: ProfileLocation.cleared,
        timeFormat: .automatic, statusBar: .off
    )

    public static let builtIns: [SettingsProfile] = [screenshots, darkMode, accessibilityStress, defaults]

    /// The stored user profiles, read tolerantly: an entry that cannot be
    /// read is skipped, a built-in id is never taken from storage.
    public static func decodeUserProfiles(_ data: Data?) -> [SettingsProfile] {
        readUserProfiles(data).profiles
    }

    /// The stored profiles and whether any stored bytes could not be read
    /// (the whole value, or single entries): the caller keeps the raw data
    /// before a later save replaces it.
    public static func readUserProfiles(_ data: Data?) -> (profiles: [SettingsProfile], lostData: Bool) {
        guard let data else { return ([], false) }
        guard let entries = try? JSONDecoder().decode([Lossy].self, from: data) else { return ([], true) }
        var seen = Set<String>()
        let profiles = entries.compactMap(\.profile).filter { profile in
            !profile.isBuiltIn && seen.insert(profile.id).inserted
        }
        return (profiles, entries.contains { $0.profile == nil })
    }

    public static func encodeUserProfiles(_ profiles: [SettingsProfile]) -> Data? {
        try? JSONEncoder().encode(profiles.filter { !$0.isBuiltIn })
    }

    private struct Lossy: Decodable {
        let profile: SettingsProfile?
        init(from decoder: Decoder) throws {
            profile = try? SettingsProfile(from: decoder)
        }
    }

    /// "Screenshots copy", "Screenshots copy 2": a name not in `taken`.
    public static func copyName(of name: String, avoiding taken: [String]) -> String {
        var candidate = "\(name) copy"
        var n = 2
        while taken.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "\(name) copy \(n)"
            n += 1
        }
        return candidate
    }
}

// MARK: - Planning

/// What one device gets from a profile: the operations its platform can run,
/// and the fields it cannot take with the reason (the "Not applied" line).
public struct ProfilePlan: Sendable, Equatable {
    public var profileName: String
    public var operations: [BatchOperation]
    public var skipped: [ProfileSkip]

    public init(profileName: String, operations: [BatchOperation], skipped: [ProfileSkip]) {
        self.profileName = profileName
        self.operations = operations
        self.skipped = skipped
    }
}

public struct ProfileSkip: Sendable, Equatable {
    public let field: String
    public let reason: String
    /// False for a setting the device's platform never offers: it is left
    /// out silently, as the app hides a control the device cannot have.
    public let isReportable: Bool

    public init(field: String, reason: String, isReportable: Bool = true) {
        self.field = field
        self.reason = reason
        self.isReportable = isReportable
    }

    public var text: String { "\(field) (\(reason))" }

    /// Whether a planner's reason says the platform never offers the
    /// setting (rather than this device or this value not taking it).
    static func platformNeverOffers(_ reason: String) -> Bool {
        reason.hasPrefix("Controls are offered for")
            || reason.hasPrefix("A phone reports its own location")
            || reason.hasPrefix("an emulator has no way")
    }

    /// "Not applied on iPhone 17: Show Borders (…), …"; nil for none.
    public static func summary(_ skips: [ProfileSkip], on device: String) -> String? {
        let shown = skips.filter(\.isReportable)
        guard !shown.isEmpty else { return nil }
        return "Not applied on \(device): " + shown.map(\.text).joined(separator: ", ")
    }
}

public enum ProfilePlanner {
    public static func plan(_ profile: SettingsProfile, for target: BatchTarget) -> ProfilePlan {
        var operations: [BatchOperation] = []
        var skipped: [ProfileSkip] = []

        /// Runs an existing action's per-platform step for `field`.
        func viaAction(_ field: String, _ action: BatchAction) {
            switch BatchPlanner.step(action, for: target) {
            case .run(let operation): operations.append(operation)
            case .skip(let reason):
                skipped.append(ProfileSkip(field: field, reason: reason, isReportable: !ProfileSkip.platformNeverOffers(reason)))
            }
        }

        let isIOS = target.platform == .apple && (target.osName == nil || target.osName == "iOS")
        func direct(_ field: String, _ operation: BatchOperation) {
            if target.platform == .apple, !isIOS {
                skipped.append(ProfileSkip(field: field, reason: BatchPlanner.controlsOnlyOnIOS(target.osName), isReportable: false))
            } else {
                operations.append(operation)
            }
        }

        if let appearance = profile.appearance { viaAction("Appearance", .appearance(dark: appearance.isDark)) }
        if let size = profile.textSize { viaAction("Text Size", .textSize(size)) }
        if let value = profile.reduceMotion { direct("Reduce Motion", .reduceMotion(value)) }
        if let value = profile.increaseContrast { direct("Increase Contrast", .increaseContrast(value)) }
        if let value = profile.showBorders { direct("Show Borders", .showBorders(value)) }
        if let value = profile.screenReader { direct("Screen Reader", .screenReader(value)) }
        if let location = profile.location {
            if let coordinate = location.coordinate {
                viaAction("Location", .location(BatchPlace(name: location.name, latitude: coordinate.latitude, longitude: coordinate.longitude)))
            } else if target.platform == .android {
                skipped.append(ProfileSkip(field: "Location", reason: "an emulator has no way to clear its simulated location", isReportable: false))
            } else {
                direct("Location", .clearLocation)
            }
        }
        if let tag = profile.language {
            if let locale = DeviceLocale(tag: tag) {
                viaAction("Language", .language(locale))
            } else {
                skipped.append(ProfileSkip(field: "Language", reason: "“\(tag)” is not a language tag"))
            }
        }
        if let format = profile.timeFormat { direct("Time Format", .timeFormat(format.setting)) }
        if let bar = profile.statusBar { viaAction("Status Bar", .statusBar(clean: bar.isClean)) }

        return ProfilePlan(profileName: profile.name, operations: operations, skipped: skipped)
    }
}

extension BatchOperation {
    /// The setting an operation of a profile changes, for result lines.
    public var profileField: String {
        switch self {
        case .appearance: "Appearance"
        case .androidTextSize, .simulatorTextSize: "Text Size"
        case .reduceMotion: "Reduce Motion"
        case .increaseContrast: "Increase Contrast"
        case .showBorders: "Show Borders"
        case .screenReader: "Screen Reader"
        case .location, .clearLocation: "Location"
        case .language: "Language"
        case .timeFormat: "Time Format"
        case .statusBar: "Status Bar"
        case .profile: "Profile"
        case .openAndroidLink, .openSimulatorURL: "Open URL"
        case .install: "Install"
        case .screenshot: "Screenshot"
        }
    }
}
