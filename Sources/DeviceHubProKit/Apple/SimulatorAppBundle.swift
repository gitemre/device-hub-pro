import Foundation
import ImageIO

/// What an app bundle's `Info.plist` says about it, read on the host without
/// running anything: its identity, the platform it was built for (a
/// simulator build or a device build) and the icon files it ships.
///
/// Xcode writes `CFBundleSupportedPlatforms` (`iPhoneSimulator`,
/// `iPhoneOS`, `AppleTVSimulator`, …) and `DTPlatformName`
/// (`iphonesimulator`, `iphoneos`, …) into every app it builds; an App Store
/// or ad hoc `.ipa` carries the device names. simctl installs only a
/// simulator build: a device build fails after the copy, with an error in
/// the Mac's language (IXUserPresentableErrorDomain 4), so Device Hub Pro checks
/// first and says why.
///
/// Icons: `actool` (and Xcode) lists the loose icon files an asset catalog
/// leaves in the bundle under `CFBundleIcons` → `CFBundlePrimaryIcon` →
/// `CFBundleIconFiles` (`AppIcon60x60` for `AppIcon60x60@2x.png`), with an
/// iPad variant under `CFBundleIcons~ipad`. The simulator runtime's own apps
/// do the same (Safari: `AppIconUpdated60x60@2x.png`). Older bundles use the
/// top-level `CFBundleIconFiles` or `CFBundleIconFile`.
public struct SimulatorAppBundle: Sendable, Equatable {
    /// The platform family a bundle was built for.
    public enum Platform: String, Sendable, Equatable {
        case iOS
        case tvOS
        case watchOS
        case visionOS
        case macOS
    }

    /// The build's platform and whether it is a simulator build.
    public struct Build: Sendable, Equatable {
        public let platform: Platform
        public let isSimulator: Bool
    }

    public let bundleIdentifier: String?
    public let displayName: String?
    public let bundleName: String?
    public let shortVersion: String?
    public let version: String?
    /// `CFBundleSupportedPlatforms`, verbatim.
    public let supportedPlatforms: [String]
    /// `DTPlatformName`, verbatim.
    public let platformName: String?
    /// The icon base names, in the order they are tried: the iPhone
    /// primary icon's files, the iPad variant's, then the legacy keys.
    public let iconNames: [String]
    /// `LSApplicationLaunchProhibited`: an app the system itself never
    /// launches from the home screen (the iMessage app hosts, say). `simctl
    /// listapps` leaves such apps out, Device Hub lists them.
    public let launchProhibited: Bool
    /// Whether the plist declares anything an app shows on launch: a launch
    /// screen or storyboard, or a main storyboard.
    public let declaresLaunchScreen: Bool
    /// Whether the plist has any icon key at all, even one naming no file
    /// (AssistiveTouch names its icon in the asset catalog only).
    public let declaresIcon: Bool

    /// Whether Device Hub draws the app's tile as the icon template (a white
    /// tile with the icon grid) instead of the App Store "A": an app that
    /// cannot be launched (`launchProhibited`), or one that names no icon and
    /// declares no launch screen either (the system's headless apps). Read
    /// from the rows of Device Hub 27.0's Apps list on iOS 26.5: the message
    /// and business hosts and FullKeyboardAccess have the template, Emoji,
    /// Kaleidoscope (a launch screen), Escrow and AssistiveTouch (an icon
    /// file) the "A".
    public var usesIconTemplateTile: Bool {
        launchProhibited || (!declaresIcon && !declaresLaunchScreen)
    }

    /// The name SpringBoard shows.
    public var title: String? { displayName ?? bundleName }

    /// The build the plist declares; nil when it names no platform.
    public var build: Build? {
        for name in supportedPlatforms {
            if let build = Self.build(forSupportedPlatform: name) { return build }
        }
        return platformName.flatMap(Self.build(forPlatformName:))
    }

    public init(
        bundleIdentifier: String?,
        displayName: String?,
        bundleName: String?,
        shortVersion: String?,
        version: String?,
        supportedPlatforms: [String],
        platformName: String?,
        iconNames: [String],
        launchProhibited: Bool = false,
        declaresLaunchScreen: Bool = false,
        declaresIcon: Bool? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.bundleName = bundleName
        self.shortVersion = shortVersion
        self.version = version
        self.supportedPlatforms = supportedPlatforms
        self.platformName = platformName
        self.iconNames = iconNames
        self.launchProhibited = launchProhibited
        self.declaresLaunchScreen = declaresLaunchScreen
        self.declaresIcon = declaresIcon ?? !iconNames.isEmpty
    }

    // MARK: Reading

    /// The bundle at `app` (a `.app` folder), read from its `Info.plist`; nil
    /// when there is none or it is not a dictionary.
    public static func read(app: URL) -> SimulatorAppBundle? {
        guard let data = FileManager.default.contents(atPath: app.appendingPathComponent("Info.plist").path) else {
            return nil
        }
        return parse(infoPlist: data)
    }

    /// An `Info.plist` (XML or binary).
    public static func parse(infoPlist data: Data) -> SimulatorAppBundle? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any]
        else { return nil }
        func string(_ key: String) -> String? {
            switch dictionary[key] {
            case let value as String: value
            case let value as NSNumber: value.stringValue
            default: nil
            }
        }
        return SimulatorAppBundle(
            bundleIdentifier: string("CFBundleIdentifier"),
            displayName: string("CFBundleDisplayName"),
            bundleName: string("CFBundleName"),
            shortVersion: string("CFBundleShortVersionString"),
            version: string("CFBundleVersion"),
            supportedPlatforms: dictionary["CFBundleSupportedPlatforms"] as? [String] ?? [],
            platformName: string("DTPlatformName"),
            iconNames: iconNames(in: dictionary),
            launchProhibited: (dictionary["LSApplicationLaunchProhibited"] as? Bool) ?? false,
            declaresLaunchScreen: ["UILaunchStoryboardName", "UILaunchScreen", "UILaunchScreens", "UIMainStoryboardFile"]
                .contains { dictionary[$0] != nil },
            declaresIcon: ["CFBundleIcons", "CFBundleIcons~ipad", "CFBundleIconFile", "CFBundleIconFiles", "CFBundleIconName"]
                .contains { dictionary[$0] != nil }
        )
    }

    /// The icon base names a plist dictionary lists, deduplicated in order.
    static func iconNames(in dictionary: [String: Any]) -> [String] {
        var names: [String] = []
        func add(_ name: String) {
            let trimmed = name.hasSuffix(".png") ? String(name.dropLast(4)) : name
            if !trimmed.isEmpty, !names.contains(trimmed) { names.append(trimmed) }
        }
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = dictionary[key] as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any]
            else { continue }
            (primary["CFBundleIconFiles"] as? [String] ?? []).forEach(add)
        }
        (dictionary["CFBundleIconFiles"] as? [String] ?? []).forEach(add)
        if let file = dictionary["CFBundleIconFile"] as? String { add(file) }
        return names
    }

    // MARK: Icons

    /// The icon file to show for this bundle among `fileNames` (the bundle
    /// folder's top-level entries): for each icon name, `<name>.png`,
    /// `<name>@2x.png`, `<name>@3x.png` and their `~ipad` / `~iphone`
    /// variants; the one with the most pixels wins (`pixelWidth` answers per
    /// file name, nil for an unreadable file, which is skipped).
    public func iconFileName(among fileNames: [String], pixelWidth: (String) -> Int?) -> String? {
        var best: (name: String, width: Int)?
        for fileName in fileNames where Self.isIcon(fileName, forNames: iconNames) {
            guard let width = pixelWidth(fileName) else { continue }
            if best == nil || width > best!.width {
                best = (fileName, width)
            }
        }
        return best?.name
    }

    /// The icon file of the bundle at `app`, or nil when it ships none that
    /// ImageIO can read.
    public func iconFile(in app: URL) -> URL? {
        guard let fileNames = try? FileManager.default.contentsOfDirectory(atPath: app.path) else { return nil }
        let name = iconFileName(among: fileNames.sorted()) { fileName in
            Self.pixelWidth(of: app.appendingPathComponent(fileName))
        }
        return name.map { app.appendingPathComponent($0) }
    }

    /// Whether `fileName` is `<name>[@Nx][~ipad|~iphone].png` for one of `names`.
    static func isIcon(_ fileName: String, forNames names: [String]) -> Bool {
        guard fileName.lowercased().hasSuffix(".png") else { return false }
        var stem = String(fileName.dropLast(4))
        for idiom in ["~ipad", "~iphone"] where stem.hasSuffix(idiom) {
            stem = String(stem.dropLast(idiom.count))
        }
        if let at = stem.lastIndex(of: "@") {
            let scale = stem[stem.index(after: at)...]
            guard scale.count == 2, scale.last == "x", scale.first?.isNumber == true else { return false }
            stem = String(stem[..<at])
        }
        return names.contains(stem)
    }

    /// The pixel width of an image file, read from its header without
    /// decoding it.
    public static func pixelWidth(of file: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
    }

    // MARK: Platforms

    /// `CFBundleSupportedPlatforms` entries Xcode writes.
    static func build(forSupportedPlatform name: String) -> Build? {
        switch name {
        case "iPhoneSimulator": Build(platform: .iOS, isSimulator: true)
        case "iPhoneOS": Build(platform: .iOS, isSimulator: false)
        case "AppleTVSimulator": Build(platform: .tvOS, isSimulator: true)
        case "AppleTVOS": Build(platform: .tvOS, isSimulator: false)
        case "WatchSimulator": Build(platform: .watchOS, isSimulator: true)
        case "WatchOS": Build(platform: .watchOS, isSimulator: false)
        case "XRSimulator": Build(platform: .visionOS, isSimulator: true)
        case "XROS": Build(platform: .visionOS, isSimulator: false)
        case "MacOSX": Build(platform: .macOS, isSimulator: false)
        default: nil
        }
    }

    /// `DTPlatformName` values.
    static func build(forPlatformName name: String) -> Build? {
        switch name.lowercased() {
        case "iphonesimulator": Build(platform: .iOS, isSimulator: true)
        case "iphoneos": Build(platform: .iOS, isSimulator: false)
        case "appletvsimulator": Build(platform: .tvOS, isSimulator: true)
        case "appletvos": Build(platform: .tvOS, isSimulator: false)
        case "watchsimulator": Build(platform: .watchOS, isSimulator: true)
        case "watchos": Build(platform: .watchOS, isSimulator: false)
        case "xrsimulator": Build(platform: .visionOS, isSimulator: true)
        case "xros": Build(platform: .visionOS, isSimulator: false)
        case "macosx": Build(platform: .macOS, isSimulator: false)
        default: nil
        }
    }

    /// The platform family of a simulator runtime's platform name ("iOS",
    /// "tvOS", "watchOS", "xrOS"/"visionOS").
    public static func platform(ofRuntimePlatform name: String?) -> Platform? {
        switch name {
        case "iOS": .iOS
        case "tvOS": .tvOS
        case "watchOS": .watchOS
        case "xrOS", "visionOS": .visionOS
        default: nil
        }
    }

    /// Why this bundle cannot be installed on a simulator of
    /// `runtimePlatform` ("iOS", "tvOS", …), or nil when it can (or when the
    /// plist names no platform, which simctl then decides). An iOS simulator
    /// build also goes to a visionOS simulator: Xcode's "Apple Vision Pro
    /// (Designed for iPad)" destination installs exactly that build there
    /// (Apple's documented destination; not captured here, so simctl has
    /// the last word).
    public func installProblem(runtimePlatform: String?) -> String? {
        guard let build else { return nil }
        let name = title ?? bundleIdentifier ?? "This app"
        guard build.isSimulator else {
            let devices = switch build.platform {
            case .iOS: "iPhone and iPad devices"
            case .tvOS: "Apple TV devices"
            case .watchOS: "Apple Watch devices"
            case .visionOS: "Apple Vision Pro devices"
            case .macOS: "the Mac"
            }
            return "“\(name)” is built for \(devices), not for a simulator. Build it for the simulator in Xcode (an iOS Simulator run destination) and drop that .app."
        }
        if let target = Self.platform(ofRuntimePlatform: runtimePlatform), target != build.platform,
           !(build.platform == .iOS && target == .visionOS) {
            return "“\(name)” is built for \(build.platform.rawValue) simulators, not \(target.rawValue)."
        }
        return nil
    }
}
