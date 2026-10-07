import Foundation

/// One renderable state of a skin: foldables carry `default` (open) and
/// `closed` (cover) variants, every other skin a single `default`.
public struct SkinVariant: Sendable, Hashable {
    public let id: String
    public let directory: URL
    public let layout: SkinLayoutFile?

    public init(id: String, directory: URL, layout: SkinLayoutFile?) {
        self.id = id
        self.directory = directory
        self.layout = layout
    }
}

/// Which `config.ini` key produced the match.
public enum SkinSource: String, Sendable {
    case skinPath
    case skinName
    case deviceName
}

/// An AVD's skin artwork as found on disk.
public struct ResolvedSkin: Sendable, Hashable {
    public let name: String
    public let directory: URL
    public let source: SkinSource
    public let variants: [SkinVariant]

    public init(name: String, directory: URL, source: SkinSource, variants: [SkinVariant]) {
        self.name = name
        self.directory = directory
        self.source = source
        self.variants = variants
    }

    public var isFoldable: Bool { variants.count > 1 }

    public var preferredVariant: SkinVariant? {
        variants.first(where: { $0.id == "default" }) ?? variants.first
    }

    /// Picks the variant whose display size best matches a live frame (used
    /// for foldables: the open display and the cover have different sizes).
    /// The frame is compared in both orientations so a rotated open fold
    /// still matches the open variant. Falls back to the preferred variant
    /// when nothing has a layout.
    public func variant(matching frameSize: CGSize) -> SkinVariant? {
        let poses = [
            frameSize,
            CGSize(width: frameSize.height, height: frameSize.width),
        ]
        let scored = variants.compactMap { variant -> (SkinVariant, CGFloat)? in
            guard let display = variant.layout?.preferred else { return nil }
            let size = display.displaySize
            guard size.width > 0, size.height > 0 else { return nil }
            let aspect = size.width / size.height
            let best = poses.map { pose in
                abs(aspect - pose.width / max(pose.height, 1))
            }.min() ?? .greatestFiniteMagnitude
            return (variant, best)
        }
        return scored.min(by: { $0.1 < $1.1 })?.0 ?? preferredVariant
    }
}

/// One entry of the SDK skin catalog.
public struct SkinCatalogEntry: Sendable, Hashable, Identifiable {
    public enum Category: String, Sendable, CaseIterable, Identifiable {
        case phone
        case foldable
        case tablet
        case tv
        case automotive
        case wear
        case xr
        case other

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .phone: return "Phones"
            case .foldable: return "Foldables"
            case .tablet: return "Tablets"
            case .tv: return "TV"
            case .automotive: return "Automotive"
            case .wear: return "Wear OS"
            case .xr: return "XR"
            case .other: return "Other"
            }
        }
    }

    public let name: String
    public let displayName: String
    public let category: Category
    public let directory: URL
    public let variants: [SkinVariant]

    public init(
        name: String,
        displayName: String,
        category: Category,
        directory: URL,
        variants: [SkinVariant]
    ) {
        self.name = name
        self.displayName = displayName
        self.category = category
        self.directory = directory
        self.variants = variants
    }

    public var id: String { name }

    public var preferredVariant: SkinVariant? {
        variants.first(where: { $0.id == "default" }) ?? variants.first
    }
}

/// Maps AVDs to their SDK skin artwork and lists the catalog of skins.
public enum SkinResolver {
    /// Resolves the skin for an AVD: `skin.path` first, then
    /// `skins/<skin.name>`, then `skins/<hw.device.name>`. The fallbacks
    /// matter: AVDs created without a skin carry no `skin.*` keys at all, and
    /// some carry a generic `skin.name` (like `2208x1840`) with no directory.
    public static func resolve(
        avdName: String,
        skinsDirectory: URL?,
        avdHome: URL? = nil
    ) -> ResolvedSkin? {
        let values = AvdConfig.values(avdName: avdName, avdHome: avdHome)

        if let path = values["skin.path"], !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if isSkinDirectory(url) {
                return ResolvedSkin(
                    name: url.lastPathComponent,
                    directory: url,
                    source: .skinPath,
                    variants: variants(in: url)
                )
            }
        }

        guard let skinsDirectory else { return nil }

        if let skinName = values["skin.name"], !skinName.isEmpty {
            let url = skinsDirectory.appendingPathComponent(skinName, isDirectory: true)
            if isSkinDirectory(url) {
                return ResolvedSkin(
                    name: skinName,
                    directory: url,
                    source: .skinName,
                    variants: variants(in: url)
                )
            }
        }

        if let deviceName = values["hw.device.name"], !deviceName.isEmpty {
            let url = skinsDirectory.appendingPathComponent(deviceName, isDirectory: true)
            if isSkinDirectory(url) {
                return ResolvedSkin(
                    name: deviceName,
                    directory: url,
                    source: .deviceName,
                    variants: variants(in: url)
                )
            }
        }

        return nil
    }

    /// Every skin in the SDK directory, sorted by display name.
    public static func catalog(skinsDirectory: URL) -> [SkinCatalogEntry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: skinsDirectory.path)) ?? []
        return names
            .sorted()
            .compactMap { name in
                let url = skinsDirectory.appendingPathComponent(name, isDirectory: true)
                guard isSkinDirectory(url) else { return nil }
                return SkinCatalogEntry(
                    name: name,
                    displayName: displayName(forSkinName: name),
                    category: category(forSkinName: name),
                    directory: url,
                    variants: variants(in: url)
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public static func category(forSkinName name: String) -> SkinCatalogEntry.Category {
        if name.contains("fold") { return .foldable }
        if name.hasPrefix("tv_") { return .tv }
        if name.hasPrefix("automotive_") { return .automotive }
        if name.hasPrefix("wearos_") || name.hasPrefix("wear_") { return .wear }
        if name.hasPrefix("xr_") || name.hasPrefix("androidxr_") { return .xr }
        switch name {
        case "pixel_tablet", "pixel_c", "nexus_7", "nexus_7_2013", "nexus_9", "nexus_10":
            return .tablet
        default:
            return .phone
        }
    }

    /// `pixel_9_pro` → `Pixel 9 Pro`.
    public static func displayName(forSkinName name: String) -> String {
        name.split(separator: "_")
            .map { word in
                switch word.lowercased() {
                case "xl": return "XL"
                case "tv": return "TV"
                case "wearos": return "Wear OS"
                case "xr": return "XR"
                default: return word.prefix(1).uppercased() + word.dropFirst()
                }
            }
            .joined(separator: " ")
    }

    private static func isSkinDirectory(_ url: URL) -> Bool {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.appendingPathComponent("layout").path) {
            return true
        }
        return manager.fileExists(atPath: url.appendingPathComponent("default/layout").path)
    }

    private static func variants(in url: URL) -> [SkinVariant] {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.appendingPathComponent("layout").path) {
            return [
                SkinVariant(
                    id: "default",
                    directory: url,
                    layout: SkinLayout.parseFile(at: url.appendingPathComponent("layout"))
                )
            ]
        }
        let subdirectories =
            ((try? manager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? [])
            .filter { ($0.lastPathComponent != ".") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { left, right in
                // The open state first, then the rest alphabetically.
                if left.lastPathComponent == "default" { return true }
                if right.lastPathComponent == "default" { return false }
                return left.lastPathComponent < right.lastPathComponent
            }
        return subdirectories.compactMap { subdir in
            let layoutURL = subdir.appendingPathComponent("layout")
            guard manager.fileExists(atPath: layoutURL.path) else { return nil }
            return SkinVariant(
                id: subdir.lastPathComponent,
                directory: subdir,
                layout: SkinLayout.parseFile(at: layoutURL)
            )
        }
    }
}
