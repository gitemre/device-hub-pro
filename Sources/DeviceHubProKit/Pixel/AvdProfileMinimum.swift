import Foundation

/// A device profile's minimum Android API applied to system images, shared by
/// the create sheet and (through `PixelMinApiTable`) the Pixel catalog.
/// Everything is allowed when the table could not be read or the profile has
/// no minimum.
public enum AvdProfileMinimum {
    /// The minimum for the avdmanager profile `profileID`, nil when unknown.
    public static func minApi(profileID: String?, table: PixelMinApiTable?) -> String? {
        guard let profileID, let table else { return nil }
        return table.minApi(forProfile: profileID)
    }

    /// Whether `image` runs the profile: no minimum, or an API at least the
    /// minimum (`android-36-ext19` is API 36, below 36.1; a codename counts
    /// as 0, like the Pixel catalog).
    public static func meets(_ image: SystemImage, minApi: String?) -> Bool {
        guard let minApi else { return true }
        return PixelMinApiTable.compare(image.api, minApi) != .orderedAscending
    }

    /// " · Requires API 36.1+" suffix of a below-minimum picker row.
    public static func requiresSuffix(minApi: String) -> String {
        " \u{00B7} Requires API \(minApi)+"
    }

    /// The red line shown while a below-minimum image is selected.
    public static func explanation(deviceName: String, minApi: String) -> String {
        "\(deviceName) requires API \(minApi) or newer."
    }

    /// The default image: the newest installed image meeting the minimum;
    /// with none installed, the newest stable available image meeting it (to
    /// download, with or without a minimum); never one below the minimum.
    /// `installed` and
    /// `available` are filtered here to `category` and `hostAbi` (available
    /// only).
    public static func defaultImage(
        installed: [SystemImage],
        available: [SystemImage],
        minApi: String?,
        category: SkinCatalogEntry.Category,
        hostAbi: String
    ) -> SystemImage? {
        let installedSorted = SystemImageCatalog.compatible(installed, with: category)
        if let pick = installedSorted.first(where: { meets($0, minApi: minApi) }) { return pick }
        return downloadSuggestion(
            installed: installed,
            available: available,
            minApi: minApi,
            category: category,
            hostAbi: hostAbi
        )
    }

    /// The newest stable not-installed image meeting the minimum.
    public static func downloadSuggestion(
        installed: [SystemImage],
        available: [SystemImage],
        minApi: String?,
        category: SkinCatalogEntry.Category,
        hostAbi: String
    ) -> SystemImage? {
        let have = Set(installed.map(\.package))
        let usable = SystemImageCatalog.compatible(available, with: category).filter {
            !have.contains($0.package) && $0.abi == hostAbi && !$0.isPreview && meets($0, minApi: minApi)
        }
        return SystemImageCatalog.recommended(usable) ?? usable.first
    }
}
