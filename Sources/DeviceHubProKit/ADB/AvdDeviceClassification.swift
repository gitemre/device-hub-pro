import Foundation

/// Which hardware profiles a create sheet offers, and in what order.
///
/// `avdmanager list device` gives an id, a name, an OEM and, for the
/// non-handheld profiles only, a `Tag :`. A fresh SDK has no skins folder to
/// classify by, so the form factor comes from the definition itself: the tag
/// when there is one, else the id and name (tablets, foldables) and the
/// diagonal the generic `5.4in FWVGA` ids spell out.
extension AvdDevice {
    public var formFactor: SkinCatalogEntry.Category {
        if let tag {
            if tag.hasPrefix("android-wear") { return .wear }
            if tag.hasPrefix("android-tv") || tag.hasPrefix("google-tv") { return .tv }
            if tag.hasPrefix("android-automotive") { return .automotive }
            if tag.hasPrefix("android-xr") || tag.hasPrefix("xr") { return .xr }
            return .other  // android-desktop, ai-glasses, ...
        }
        let key = id.lowercased()
        let label = name.lowercased()
        if key.hasPrefix("wearos_") || key.hasPrefix("wear_") { return .wear }
        if key.hasPrefix("tv_") { return .tv }
        if key.hasPrefix("automotive_") { return .automotive }
        if key.hasPrefix("xr_") { return .xr }
        if key.hasPrefix("desktop_") || key.hasPrefix("ai_glasses") || key == "resizable" {
            return .other
        }
        if key.contains("fold") || key.contains("rollable") || label.contains("fold") || label.contains("rollable") {
            return .foldable
        }
        if key.contains("tablet") || label.contains("tablet") { return .tablet }
        switch key {
        case "pixel_c", "nexus 7", "nexus 7 2013", "nexus 9", "nexus 10": return .tablet
        default: break
        }
        if let diagonal = Self.diagonalInches(inID: id) {
            return diagonal >= 7 ? .tablet : .phone
        }
        return .phone
    }

    /// `5.4in FWVGA` -> 5.4, `3.7 FWVGA slider` -> 3.7; nil for named ids.
    static func diagonalInches(inID id: String) -> Double? {
        guard let first = id.split(separator: " ").first else { return nil }
        let digits = first.hasSuffix("in") ? String(first.dropLast(2)) : String(first)
        return Double(digits)
    }

    /// Newest-first rank among the Pixels: (generation, position in it).
    /// Pro before the XL, the plain model, then the "a".
    fileprivate var pixelRank: (generation: Double, position: Int)? {
        switch id {
        case "pixel": return (1, 2)
        case "pixel_xl": return (1, 3)
        case "pixel_fold": return (7.5, 0)
        case "pixel_tablet": return (7.5, 1)
        case "pixel_c": return (0.5, 0)
        default: break
        }
        guard id.hasPrefix("pixel_") else { return nil }
        let rest = id.dropFirst("pixel_".count)
        let digits = rest.prefix(while: \.isNumber)
        guard let generation = Double(digits) else { return nil }
        let suffix = String(rest.dropFirst(digits.count))
        let position: Int = switch suffix {
        case "_pro_fold", "_pro": 0
        case "_pro_xl": 1
        case "": 2
        case "_xl": 3
        case "a": 4
        default: 5
        }
        return (generation, position)
    }
}

public enum AvdDeviceCatalog {
    /// The profiles a create sheet of this form factor lists: only that
    /// form factor, the current Pixels first (newest generation first),
    /// then the generic Medium/Small profiles, the older Nexus line and the
    /// rest by name. The first entry is the sheet's default model.
    public static func models(
        for formFactor: SkinCatalogEntry.Category,
        in devices: [AvdDevice]
    ) -> [AvdDevice] {
        devices.filter { $0.formFactor == formFactor }.sorted { left, right in
            let l = sortKey(left), r = sortKey(right)
            if l.group != r.group { return l.group < r.group }
            if l.generation != r.generation { return l.generation > r.generation }
            if l.position != r.position { return l.position < r.position }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    private static func sortKey(_ device: AvdDevice) -> (group: Int, generation: Double, position: Int) {
        if let rank = device.pixelRank { return (0, rank.generation, rank.position) }
        let key = device.id.lowercased()
        if key.hasPrefix("medium_") { return (1, 0, 0) }
        if key.hasPrefix("small_") { return (1, 0, 1) }
        if key.hasPrefix("nexus") { return (2, 0, 0) }
        if device.tag != nil { return (3, 0, 0) }
        return (4, 0, 0)
    }
}
