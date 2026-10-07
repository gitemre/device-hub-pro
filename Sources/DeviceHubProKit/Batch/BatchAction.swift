import Foundation

/// One of Apply to Selected's actions: what the user
/// asked every selected device to do, before it is planned per device
/// (`BatchPlanner`). The actions are the cross-platform subset both
/// platforms' existing mechanisms reach: the Android Controls writes and the
/// simulator's `AppleControlsBackend`, simctl and adb.
public enum BatchAction: Sendable, Equatable {
    case appearance(dark: Bool)
    case textSize(BatchTextSize)
    /// The device's only language, with the region that goes with it.
    case language(DeviceLocale)
    case location(BatchPlace)
    /// A link as the user typed it; each platform reads it its own way
    /// (`LinkRequest` for adb, `SimctlClient.readLink` for simctl).
    case openURL(String)
    /// The builds chosen, at most one per platform: each device gets the
    /// one it can run (`BatchBuild.platform`).
    case install([BatchBuild])
    /// A clean status bar for screenshots (true: Android's SystemUI demo
    /// mode, a simulator's `status_bar override`), or the device's own one
    /// again (false: demo mode ended, the override cleared).
    case statusBar(clean: Bool)
    case screenshot
    /// A settings profile (`SettingsProfile`): planned per device, setting by
    /// setting, by `ProfilePlanner`.
    case profile(SettingsProfile)

    /// The action's name in progress and result lines.
    public var title: String {
        switch self {
        case .appearance(let dark): dark ? "Dark Appearance" : "Light Appearance"
        case .textSize(let size): "Text Size \(size.label)"
        case .language(let locale): "Language \(locale.tag)"
        case .location(let place): "Location \(place.title)"
        case .openURL: "Open URL"
        case .install: "Install Build"
        case .statusBar(let clean): clean ? "Clean Status Bar" : "Clear Status Bar"
        case .screenshot: "Screenshot"
        case .profile(let profile): "Profile “\(profile.name)”"
        }
    }
}

/// A text size both platforms have, named by Android's stock steps
/// (Settings ▸ Display ▸ Text size): the Android `font_scale` is the step
/// itself, and a simulator takes the content size category whose Body text
/// is nearest that scale (`SimulatorContentSize.nearest(toScale:)`).
public enum BatchTextSize: String, CaseIterable, Sendable, Identifiable {
    case small
    case standard
    case large
    case largest
    /// 200 %: Android 14's largest step (non-linear font scaling), an
    /// accessibility size on a simulator.
    case doubled

    public var id: String { rawValue }

    /// The Android step.
    public var androidStep: FontScaleStep {
        switch self {
        case .small: .small
        case .standard: .standard
        case .large: .large
        case .largest: .largest
        case .doubled: .percent200
        }
    }

    /// The scale against the default size (1.0).
    public var scale: Double { androidStep.rawValue }

    /// The simulator's content size category for this scale.
    public var simulatorSize: SimulatorContentSize { .nearest(toScale: scale) }

    public var label: String { androidStep.label }
}

extension SimulatorContentSize {
    /// The Body text style's size in points at this category, from Apple's
    /// Human Interface Guidelines (Typography ▸ Specifications ▸ Dynamic Type
    /// sizes, iOS and iPadOS, Body): 17 pt at Large, the default. Nil for the
    /// read-only answers.
    public var bodyPointSize: Double? {
        switch self {
        case .extraSmall: 14
        case .small: 15
        case .medium: 16
        case .large: 17
        case .extraLarge: 19
        case .extraExtraLarge: 21
        case .extraExtraExtraLarge: 23
        case .accessibilityMedium: 28
        case .accessibilityLarge: 33
        case .accessibilityExtraLarge: 40
        case .accessibilityExtraExtraLarge: 47
        case .accessibilityExtraExtraExtraLarge: 53
        case .unknown, .unsupported: nil
        }
    }

    /// The settable category whose Body size over the default's is nearest
    /// `scale`; a tie goes to the smaller category.
    public static func nearest(toScale scale: Double) -> SimulatorContentSize {
        let base = SimulatorContentSize.large.bodyPointSize ?? 17
        var best = SimulatorContentSize.large
        var bestDistance = Double.infinity
        for size in settable {
            guard let points = size.bodyPointSize else { continue }
            let distance = abs(points / base - scale)
            if distance < bestDistance - 1e-9 {
                best = size
                bestDistance = distance
            }
        }
        return best
    }
}

/// A place to put every selected device at: a saved place or a typed
/// coordinate.
public struct BatchPlace: Sendable, Equatable {
    public let name: String?
    public let latitude: Double
    public let longitude: Double

    public init(name: String? = nil, latitude: Double, longitude: Double) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }

    public var title: String {
        if let name, !name.isEmpty { return name }
        return String(format: "%.4f, %.4f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
    }
}

/// One build Install Build was given, and the platform that runs it.
public struct BatchBuild: Sendable, Hashable {
    public let url: URL
    public let platform: DevicePlatform

    public init(url: URL, platform: DevicePlatform) {
        self.url = url
        self.platform = platform
    }

    /// What a file or folder is, by its name: an `.apk`, a bundletool
    /// `.apks` set or a folder of split APKs is Android's (adb checks the
    /// folder's contents); a `.app` bundle, an `.ipa` or a `.zip` holding
    /// one is a simulator's (the bundle is checked as it installs). Nil for
    /// anything else.
    public static func classify(_ url: URL, isDirectory: Bool) -> BatchBuild? {
        switch url.pathExtension.lowercased() {
        case "apk", "apks":
            return BatchBuild(url: url, platform: .android)
        case "app", "ipa", "zip":
            return BatchBuild(url: url, platform: .apple)
        default:
            return isDirectory ? BatchBuild(url: url, platform: .android) : nil
        }
    }
}

/// The languages Apply to Selected offers: the common ones both platforms
/// ship, one region each, plus two right-to-left ones.
public enum BatchLocales {
    public static let common: [DeviceLocale] = [
        "en-US", "en-GB", "de-DE", "fr-FR", "es-ES", "it-IT", "pt-BR", "nl-NL",
        "sv-SE", "pl-PL", "ru-RU", "tr-TR", "ar-EG", "he-IL", "hi-IN", "ja-JP",
        "ko-KR", "zh-Hans-CN", "zh-Hant-TW",
    ].compactMap(DeviceLocale.init(tag:))
}
