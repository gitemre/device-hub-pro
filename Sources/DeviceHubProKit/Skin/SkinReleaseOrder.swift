import Foundation

/// Newest-first ordering of the SDK's device skins, the order Device Hub
/// lists Apple devices in: Pixels by generation (Pixel 10 Pro Fold, Pixel 10
/// Pro XL, Pixel 10 Pro, Pixel 10, Pixel 9 ...), then names this rule does
/// not know, alphabetically, then the Nexus line (Nexus 6P ... Nexus One).
/// TV skins go by resolution, highest first. The rule reads the skin id, so
/// a skin the SDK adds later still lands sensibly: a new `pixel_<n>` joins
/// its generation and anything else goes among the unknown names.
public enum SkinReleaseOrder {
    /// Release year of the Nexus and legacy skins the SDK ships, by skin id.
    private static let nexusReleases: [String: Double] = [
        "nexus_one": 2010.0,
        "nexus_s": 2010.9,
        "galaxy_nexus": 2011.9,
        "nexus_4": 2012.8,
        "nexus_7": 2012.5,
        "nexus_10": 2012.9,
        "nexus_5": 2013.8,
        "nexus_7_2013": 2013.5,
        "nexus_6": 2014.8,
        "nexus_9": 2014.8,
        "nexus_5x": 2015.7,
        "nexus_6p": 2015.7,
    ]

    /// Pixels without a generation number in their skin id.
    private static let unnumberedPixelReleases: [String: Double] = [
        "pixel_silver": 2016.0,
        "pixel_xl_silver": 2016.0,
        "pixel_c": 2015.9,
        "pixel_fold": 2023.5,
        "pixel_tablet": 2023.5,
    ]

    private struct Key {
        /// 0 Pixel (or a sized TV), 1 unknown, 2 Nexus.
        var tier: Int
        /// Higher is newer and listed first.
        var release: Double
        /// Within a generation: larger models first.
        var variant: Int
    }

    private static func key(forSkinName name: String) -> Key {
        let id = name.lowercased()
        if let release = nexusReleases[id] { return Key(tier: 2, release: release, variant: 0) }
        if id.hasPrefix("nexus_") || id.hasPrefix("galaxy_nexus") {
            return Key(tier: 2, release: 0, variant: 0)
        }
        if let release = unnumberedPixelReleases[id] { return Key(tier: 0, release: release, variant: 0) }
        if id.hasPrefix("pixel_") {
            let parts = id.dropFirst("pixel_".count).split(separator: "_").map(String.init)
            if let first = parts.first {
                let digits = first.prefix(while: \.isNumber)
                if let generation = Int(digits) {
                    let tail = ([String(first.dropFirst(digits.count))] + parts.dropFirst())
                        .filter { !$0.isEmpty }
                        .joined(separator: "_")
                    return Key(tier: 0, release: 2015 + Double(generation), variant: variantRank(tail))
                }
            }
        }
        if id.hasPrefix("tv_"), let lines = tvResolution(String(id.dropFirst("tv_".count))) {
            return Key(tier: 0, release: Double(lines), variant: 0)
        }
        return Key(tier: 1, release: 0, variant: 0)
    }

    /// `4k` -> 2160, `1080p` -> 1080; nil for anything else.
    private static func tvResolution(_ token: String) -> Int? {
        if token.hasSuffix("k"), let k = Int(token.dropLast()) { return k * 540 }
        if token.hasSuffix("p"), let lines = Int(token.dropLast()) { return lines }
        return nil
    }

    /// Within one generation: folds, then Pro XL, Pro, XL, the plain model,
    /// then the `a` models; unknown suffixes last.
    private static func variantRank(_ suffix: String) -> Int {
        switch suffix {
        case "pro_fold": 0
        case "pro_xl": 1
        case "pro": 2
        case "xl": 3
        case "": 4
        case "a_xl": 5
        case "a": 6
        default: 7
        }
    }

    /// Whether `lhs` is listed before `rhs`; `displayName` breaks ties
    /// alphabetically.
    public static func isOrderedBefore(
        skinName lhs: String,
        displayName lhsDisplay: String,
        skinName rhs: String,
        displayName rhsDisplay: String
    ) -> Bool {
        let a = key(forSkinName: lhs)
        let b = key(forSkinName: rhs)
        if a.tier != b.tier { return a.tier < b.tier }
        if a.release != b.release { return a.release > b.release }
        if a.variant != b.variant { return a.variant < b.variant }
        return lhsDisplay.localizedCaseInsensitiveCompare(rhsDisplay) == .orderedAscending
    }

    /// `entries` newest first.
    public static func sorted(_ entries: [SkinCatalogEntry]) -> [SkinCatalogEntry] {
        entries.sorted {
            isOrderedBefore(
                skinName: $0.name, displayName: $0.displayName,
                skinName: $1.name, displayName: $1.displayName
            )
        }
    }

    /// `entries` newest first within each category, the categories staying
    /// in the order they first appear (the ranking means nothing across a
    /// phone and a watch).
    public static func sortedWithinCategories(_ entries: [SkinCatalogEntry]) -> [SkinCatalogEntry] {
        var order: [SkinCatalogEntry.Category] = []
        for entry in entries where !order.contains(entry.category) { order.append(entry.category) }
        return order.flatMap { category in sorted(entries.filter { $0.category == category }) }
    }
}
