import Foundation

/// One device in the SDK's Pixel family, as shown in the sidebar's Pixel
/// section and its provisioning detail screen.
public struct PixelDevice: Sendable, Hashable, Identifiable {
    public let skinName: String
    public let displayName: String
    public let category: SkinCatalogEntry.Category
    public let skin: SkinCatalogEntry
    /// `avdmanager list device` id, nil when the skin has no profile.
    public let deviceProfileID: String?
    /// The lowest Android API the device profile supports (`nexus.xml`).
    public let minApi: String?
    /// Whether the profile enables the Play Store (tag hint for images).
    public let playstoreEnabled: Bool
    /// Installed AVDs whose config resolves to this skin, sorted.
    public let installedAvdNames: [String]

    public init(
        skinName: String,
        displayName: String,
        category: SkinCatalogEntry.Category,
        skin: SkinCatalogEntry,
        deviceProfileID: String?,
        minApi: String?,
        playstoreEnabled: Bool,
        installedAvdNames: [String]
    ) {
        self.skinName = skinName
        self.displayName = displayName
        self.category = category
        self.skin = skin
        self.deviceProfileID = deviceProfileID
        self.minApi = minApi
        self.playstoreEnabled = playstoreEnabled
        self.installedAvdNames = installedAvdNames
    }

    public var id: String { skinName }
}

/// Builds the Pixel device list from the SDK skin catalog.
public enum PixelCatalog {
    /// Pixel skins only; Nexus, TV, Wear and automotive stay out. The two
    /// legacy "silver" skins are aliases of `pixel`/`pixel_xl` and are kept
    /// as separate rows (their artwork differs), with the profile resolved
    /// through the alias.
    public static func devices(
        skins: [SkinCatalogEntry],
        installedAvdNames: [String],
        avdDevices: [AvdDevice],
        avdHome: URL? = nil
    ) -> [PixelDevice] {
        let candidates = skins.filter(isPixelSkin)
        let knownSkins = Set(skins.map(\.name))
        let installed = installedAvdNames.map { name in
            (name, resolvedSkinName(avdName: name, knownSkins: knownSkins, avdHome: avdHome))
        }
        return candidates.map { entry in
            let matching = installed
                .filter { $0.1 == entry.name }
                .map(\.0)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            return PixelDevice(
                skinName: entry.name,
                displayName: entry.displayName,
                category: entry.category,
                skin: entry,
                deviceProfileID: AvdmanagerClient.device(
                    forSkinName: entry.name,
                    devices: avdDevices
                )?.id,
                minApi: nil,
                playstoreEnabled: false,
                installedAvdNames: matching
            )
        }
        .sorted {
            SkinReleaseOrder.isOrderedBefore(
                skinName: $0.skinName, displayName: $0.displayName,
                skinName: $1.skinName, displayName: $1.displayName
            )
        }
    }

    /// Convenience: build the list, then fill each device's minimum API and
    /// Play Store flag from the table when it is available.
    public static func devices(
        skins: [SkinCatalogEntry],
        installedAvdNames: [String],
        avdDevices: [AvdDevice],
        minApiTable: PixelMinApiTable?,
        avdHome: URL? = nil
    ) -> [PixelDevice] {
        let base = devices(
            skins: skins,
            installedAvdNames: installedAvdNames,
            avdDevices: avdDevices,
            avdHome: avdHome
        )
        guard let minApiTable else { return base }
        return base.map { applying(minApiTable, to: $0) }
    }

    /// Fills a device's minimum API and Play Store flag from the table. The
    /// lookup uses the resolved profile id, then the skin name itself, then
    /// the legacy aliases — the sidebar shows the minimum API before any
    /// `avdmanager` run has supplied the profile list.
    public static func applying(_ table: PixelMinApiTable, to device: PixelDevice) -> PixelDevice {
        let keys = [device.deviceProfileID, device.skinName, profileAliases[device.skinName]]
            .compactMap { $0 }
        guard let entry = keys.lazy.compactMap({ table.entries[$0] }).first else {
            return device
        }
        return PixelDevice(
            skinName: device.skinName,
            displayName: device.displayName,
            category: device.category,
            skin: device.skin,
            deviceProfileID: device.deviceProfileID,
            minApi: entry.minApi,
            playstoreEnabled: entry.playstoreEnabled,
            installedAvdNames: device.installedAvdNames
        )
    }

    /// Skins whose name matches no device definition even normalized
    /// (mirrors `AvdmanagerClient.skinAliases`).
    public static let profileAliases = [
        "pixel_silver": "pixel",
        "pixel_xl_silver": "pixel_xl",
    ]

    public static func isPixelSkin(_ entry: SkinCatalogEntry) -> Bool {
        guard entry.category == .phone || entry.category == .foldable
            || entry.category == .tablet
        else {
            return false
        }
        return entry.name == "pixel" || entry.name.hasPrefix("pixel_")
    }

    /// The skin an AVD's config resolves to, using the same precedence as
    /// `SkinResolver.resolve` (skin.path → skin.name → hw.device.name). A
    /// `skin.name` that matches no known skin directory (like the real
    /// `2208x1840`) falls through to the hardware profile name.
    static func resolvedSkinName(
        avdName: String,
        knownSkins: Set<String>,
        avdHome: URL?
    ) -> String? {
        let values = AvdConfig.values(avdName: avdName, avdHome: avdHome)
        if let path = values["skin.path"], !path.isEmpty {
            let name = URL(fileURLWithPath: path).lastPathComponent
            if knownSkins.contains(name) { return name }
        }
        if let name = values["skin.name"], !name.isEmpty, knownSkins.contains(name) {
            return name
        }
        if let name = values["hw.device.name"], !name.isEmpty {
            return name
        }
        return nil
    }

    /// A unique AVD name for the device and image: `Pixel_9_Pro`, then
    /// `Pixel_9_Pro_API35`, then a numeric suffix. Names are compared
    /// ignoring case (`AvdHome`): `pixel_9_pro` on disk takes `Pixel_9_Pro`.
    public static func avdName(
        for device: PixelDevice,
        image: SystemImage,
        existing: [String]
    ) -> String {
        let base = AvdmanagerClient.sanitizedAvdName(device.displayName)
        let api = image.api.hasPrefix("android-")
            ? String(image.api.dropFirst("android-".count))
            : image.api
        return AvdmanagerClient.uniqueAvdName(
            candidates: [base, "\(base)_API\(api)"],
            existing: existing
        )
    }
}
