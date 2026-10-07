import Foundation

/// How the create sheet names, filters, orders and groups system images
/// (Device Hub style: "Android 17 (API 37.1)", newest first, a variant only
/// where two images would otherwise read the same).
extension SystemImage {
    /// The kind of device an image's tag is built for.
    public enum FormFactor: Sendable, Hashable {
        case handheld
        case wear
        case tv
        case automotive
        case desktop
        case xr
    }

    public var formFactor: FormFactor { Self.formFactor(tag: tag) }

    /// The device class an image tag (`google-tv`, `android-wear-signed`,
    /// `android-automotive`, ...) is built for.
    public static func formFactor(tag: String) -> FormFactor {
        if tag.hasPrefix("android-wear") { return .wear }
        if tag.hasPrefix("android-tv") || tag.hasPrefix("google-tv") { return .tv }
        if tag.hasPrefix("android-automotive") { return .automotive }
        if tag.hasPrefix("android-desktop") { return .desktop }
        if tag.hasPrefix("android-xr") { return .xr }
        return .handheld
    }

    /// Whether a device profile of `category` can run this image: phones,
    /// foldables and tablets take the handheld images, Wear OS, TV and
    /// automotive profiles their own. Desktop and XR images have no profile
    /// category yet and are never offered.
    public func isCompatible(with category: SkinCatalogEntry.Category) -> Bool {
        switch (category, formFactor) {
        case (.phone, .handheld), (.foldable, .handheld), (.tablet, .handheld), (.other, .handheld): true
        case (.wear, .wear), (.tv, .tv), (.automotive, .automotive): true
        default: false
        }
    }

    /// `37.1` of `android-37.1`; a preview codename stays as it is.
    public var apiLevel: String {
        api.hasPrefix("android-") ? String(api.dropFirst("android-".count)) : api
    }

    /// The API level without its extension build: `33` of `33-ext4`.
    public var baseLevel: String { Self.baseLevel(of: apiLevel) }

    static func baseLevel(of level: String) -> String {
        if let range = level.range(of: "-ext", options: .backwards), Int(level[range.upperBound...]) != nil {
            return String(level[..<range.lowerBound])
        }
        return level
    }

    /// The N of an `android-33-extN` image (the same release with a newer
    /// extension build); nil for the release's own image.
    public var extensionLevel: Int? {
        guard let range = apiLevel.range(of: "-ext", options: .backwards) else { return nil }
        return Int(apiLevel[range.upperBound...])
    }

    /// A preview build: a codename (`CANARY`, `canary-20260909`, `Baklava`)
    /// or a `-betaN` / `-rcN` / `-previewN` level. Stable images list first.
    public var isPreview: Bool {
        let level = baseLevel
        guard let first = level.first, first.isNumber else { return true }
        let lowered = level.lowercased()
        return lowered.contains("-beta") || lowered.contains("-rc") || lowered.contains("-preview")
    }

    /// The numeric parts of the base API level, for ordering (`37.2-beta1`
    /// orders as `[37, 2]`); a codename counts as newer than every numbered
    /// level among the previews.
    public var apiSortKey: [Int] {
        let level = baseLevel
        guard let first = level.first, first.isNumber else { return [Int.max] }
        let numeric = level.prefix { $0.isNumber || $0 == "." }
        let parts = numeric.split(separator: ".").compactMap { Int($0) }
        return parts.isEmpty ? [Int.max] : parts
    }

    /// The Android release an API level ships with, nil when unknown.
    public static func androidRelease(forAPILevel level: String) -> String? {
        switch level {
        case "24": "7.0"
        case "25": "7.1"
        case "26": "8.0"
        case "27": "8.1"
        case "28": "9"
        case "29": "10"
        case "30": "11"
        case "31": "12"
        case "32": "12L"
        case "33": "13"
        case "34": "14"
        case "35": "15"
        case "36", "36.1": "16"
        case "37", "37.0", "37.1", "37.2": "17"
        default: nil
        }
    }

    /// "Android 17 (API 37.1)"; "API 23" when the release is not known.
    public var versionTitle: String {
        let title = Self.androidRelease(forAPILevel: baseLevel).map { "Android \($0) (API \(baseLevel))" }
            ?? "API \(baseLevel)"
        return isPreview ? title + " \u{00B7} Preview" : title
    }

    /// The image's flavour in plain words. The tag's own qualifiers are
    /// kept so two packages of one release read differently: "(16 KB)" for a
    /// `ps16k` image, "(Tablet)" for a tablet image.
    public var variantTitle: String {
        let pages = tag.contains("ps16k") ? " (16 KB)" : ""
        let tablet = tag.hasSuffix("_tablet") ? " (Tablet)" : ""
        let extra = extensionLevel.map { " (extension \($0))" } ?? ""
        let base: String
        switch tag {
        case _ where tag.hasPrefix("google_apis_playstore"): base = "Google Play"
        case _ where tag.hasPrefix("google_apis"): base = "Google APIs"
        case "google_atd", "google_atd_ps16k": base = "Google APIs Automated Test Device"
        case "aosp_atd": base = "AOSP Automated Test Device"
        case "aosp", "default": base = "AOSP"
        case _ where tag.hasPrefix("android-wear"): base = "Wear OS"
        case _ where tag.hasPrefix("android-tv"): base = "Android TV"
        case _ where tag.hasPrefix("google-tv"): base = "Google TV"
        case _ where tag.hasPrefix("android-automotive-playstore"): base = "Automotive with Google Play"
        case _ where tag.hasPrefix("android-automotive"): base = "Automotive"
        case _ where tag.hasPrefix("android-desktop"): base = "Desktop"
        case _ where tag.hasPrefix("android-xr"): base = "XR"
        default: return tag.replacingOccurrences(of: "_", with: " ") + extra
        }
        return base + pages + tablet + extra
    }

    /// The processor in plain words ("arm64").
    public var architectureTitle: String {
        switch abi {
        case "arm64-v8a": "arm64"
        case "armeabi-v7a": "arm"
        default: abi
        }
    }

    /// Rank of the variant among one release's images: Play first.
    fileprivate var variantRank: Int {
        if tag.hasPrefix("google_apis_playstore") { return 0 }
        if tag.hasPrefix("google_apis") { return 1 }
        if tag == "aosp" || tag == "default" { return 2 }
        return 3
    }
}

/// One entry of the OS Version popup.
public struct SystemImageOption: Sendable, Hashable, Identifiable {
    public let image: SystemImage
    /// "Android 17 (API 37.1)".
    public let title: String
    /// The variant (and processor) when the title alone would not tell this
    /// image from another of the list.
    public let detail: String?

    public var id: String { image.id }

    /// The popup's line: title and detail.
    public var menuTitle: String { detail.map { "\(title) \u{00B7} \($0)" } ?? title }
}

/// The downloadable images of one Android release.
public struct SystemImageGroup: Sendable, Hashable, Identifiable {
    /// "Android 17 (API 37.1)".
    public let title: String
    public let images: [SystemImage]
    public var id: String { title }

    /// The release's own images and the extension builds of it
    /// (`android-33-ext4`), which the download sheet folds away.
    public var baseImages: [SystemImage] { images.filter { $0.extensionLevel == nil } }
    public var extensionImages: [SystemImage] { images.filter { $0.extensionLevel != nil } }

    /// The variant line of `image`'s row, made distinct from every other
    /// row of this release that has the same processor (see
    /// `SystemImageCatalog.variantTitles`).
    public func variantTitle(for image: SystemImage) -> String {
        SystemImageCatalog.variantTitles(images)[image.id] ?? image.variantTitle
    }
}

public enum SystemImageCatalog {
    /// Stable releases newest first, then the previews; within a release its
    /// own images before the extension builds (newest extension first), then
    /// Play, APIs, AOSP and the rest, then by processor name.
    public static func sorted(_ images: [SystemImage]) -> [SystemImage] {
        images.sorted { lhs, rhs in
            if lhs.isPreview != rhs.isPreview { return !lhs.isPreview }
            if lhs.apiSortKey != rhs.apiSortKey {
                return rhs.apiSortKey.lexicographicallyPrecedes(lhs.apiSortKey)
            }
            if lhs.baseLevel != rhs.baseLevel { return lhs.baseLevel > rhs.baseLevel }
            if lhs.extensionLevel != rhs.extensionLevel {
                return (lhs.extensionLevel ?? Int.max) > (rhs.extensionLevel ?? Int.max)
            }
            if lhs.variantRank != rhs.variantRank { return lhs.variantRank < rhs.variantRank }
            if lhs.tag != rhs.tag { return lhs.tag < rhs.tag }
            return lhs.abi < rhs.abi
        }
    }

    /// The image the download sheet recommends: the newest stable release
    /// with a plain (no extension, 16 KB, tablet or test-device) image of the
    /// form factor. A phone prefers Google APIs over Play Store: a Play Store
    /// image cannot be rooted, so the Controls that need root (network
    /// shaping, …) are hidden on it. `images` are already compatible with
    /// the sheet's profile and this Mac.
    public static func recommended(_ images: [SystemImage]) -> SystemImage? {
        let stable = sorted(images).filter { !$0.isPreview && $0.extensionLevel == nil }
        func penalty(_ image: SystemImage) -> Int {
            let tag = image.tag
            if tag.contains("ps16k") || tag.contains("tablet") || tag.contains("atd") || tag.hasSuffix("-cn") {
                return 10
            }
            switch tag {
            case "google_apis", "google-tv", "android-automotive-playstore": return 0
            case _ where tag.hasPrefix("android-wear"): return 0
            case "google_apis_playstore", "android-tv": return 1
            default: return 2
            }
        }
        for group in groups(stable) {
            if let best = group.images.min(by: { penalty($0) < penalty($1) }), penalty(best) < 10 {
                return best
            }
        }
        return stable.first
    }

    /// The images a device profile of `category` can run, newest first.
    public static func compatible(_ images: [SystemImage], with category: SkinCatalogEntry.Category) -> [SystemImage] {
        sorted(images.filter { $0.isCompatible(with: category) })
    }

    /// The variant title of each image (by package id), where two images
    /// that share a release and a processor never read the same: an image
    /// whose `variantTitle` collides with another's gets its raw tag in words
    /// ("Wear OS (android wear signed)"), so a qualifier the plain title
    /// does not know still tells the packages apart.
    public static func variantTitles(_ images: [SystemImage]) -> [String: String] {
        var titles: [String: String] = [:]
        for image in images {
            let clash = images.contains {
                $0.id != image.id && $0.versionTitle == image.versionTitle
                    && $0.abi == image.abi && $0.variantTitle == image.variantTitle
            }
            titles[image.id] = clash
                ? "\(image.variantTitle) (\(image.tag.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")))"
                : image.variantTitle
        }
        return titles
    }

    /// Popup entries for `images` (already filtered), newest first. A variant
    /// shows only beside another image of the same release; the processor
    /// only beside another image of the same release and variant.
    public static func options(_ images: [SystemImage]) -> [SystemImageOption] {
        let images = sorted(images)
        let titles = variantTitles(images)
        return images.map { image in
            let sameVersion = images.filter { $0.versionTitle == image.versionTitle }
            guard sameVersion.count > 1 else {
                return SystemImageOption(image: image, title: image.versionTitle, detail: nil)
            }
            let variant = titles[image.id] ?? image.variantTitle
            let sameVariant = sameVersion.filter { (titles[$0.id] ?? $0.variantTitle) == variant }
            let detail = sameVariant.count > 1
                ? "\(variant) \u{00B7} \(image.architectureTitle)"
                : variant
            return SystemImageOption(image: image, title: image.versionTitle, detail: detail)
        }
    }

    /// `images` grouped by release, newest first, each group in `sorted` order.
    public static func groups(_ images: [SystemImage]) -> [SystemImageGroup] {
        var groups: [SystemImageGroup] = []
        for image in sorted(images) {
            if let index = groups.firstIndex(where: { $0.title == image.versionTitle }) {
                groups[index] = SystemImageGroup(title: groups[index].title, images: groups[index].images + [image])
            } else {
                groups.append(SystemImageGroup(title: image.versionTitle, images: [image]))
            }
        }
        return groups
    }
}
