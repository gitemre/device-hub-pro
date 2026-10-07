import Foundation
import DeviceHubProKit

/// The two halves of the Browse Catalog.
enum CatalogPlatform: String, CaseIterable, Identifiable, Sendable {
    case android
    case apple

    var id: String { rawValue }

    var label: String {
        switch self {
        case .android: "Android"
        case .apple: "Apple"
        }
    }
}

/// A section of the catalog: a form factor on Android, a product family on
/// Apple. The order is the order of the sections and of the filter menu.
enum CatalogGroup: String, CaseIterable, Identifiable, Hashable, Sendable {
    case androidPhones
    case androidFoldables
    case androidTablets
    case wear
    case tv
    case automotive
    case xr
    case androidOther
    case iPhone
    case iPad
    case appleWatch
    case appleTV
    case appleVision

    var id: String { rawValue }

    var platform: CatalogPlatform {
        switch self {
        case .iPhone, .iPad, .appleWatch, .appleTV, .appleVision: .apple
        default: .android
        }
    }

    var label: String {
        switch self {
        case .androidPhones: "Phones"
        case .androidFoldables: "Foldables"
        case .androidTablets: "Tablets"
        case .wear: "Wear OS"
        case .tv: "TV"
        case .automotive: "Automotive"
        case .xr: "XR"
        case .androidOther: "Other"
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .appleWatch: "Apple Watch"
        case .appleTV: "Apple TV"
        case .appleVision: "Apple Vision"
        }
    }

    var symbol: String {
        switch self {
        case .androidPhones, .androidOther: "smartphone"
        case .androidFoldables: "flipphone"
        case .androidTablets: "ipad"
        case .wear: "applewatch.side.right"
        case .tv: "tv"
        case .automotive: "car"
        case .xr: "visionpro"
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .appleWatch: "applewatch"
        case .appleTV: "appletv"
        case .appleVision: "visionpro"
        }
    }

    static func groups(of platform: CatalogPlatform) -> [CatalogGroup] {
        allCases.filter { $0.platform == platform }
    }

    init(category: SkinCatalogEntry.Category) {
        switch category {
        case .phone: self = .androidPhones
        case .foldable: self = .androidFoldables
        case .tablet: self = .androidTablets
        case .tv: self = .tv
        case .automotive: self = .automotive
        case .wear: self = .wear
        case .xr: self = .xr
        case .other: self = .androidOther
        }
    }

    init?(family: SimulatorFamily) {
        switch family {
        case .iPhone: self = .iPhone
        case .iPad: self = .iPad
        case .appleWatch: self = .appleWatch
        case .appleTV: self = .appleTV
        case .appleVision: self = .appleVision
        }
    }

    /// How much of a card's preview box the device's picture may fill, so
    /// devices keep their real sizes against each other: a watch is a
    /// fraction of a phone, a wide TV or car screen is limited by the card's
    /// width instead of its height.
    var previewFill: CGFloat {
        switch self {
        case .wear, .appleWatch: 0.62
        case .androidTablets, .iPad: 0.92
        default: 1
        }
    }

    /// The Android form factor an AVD create sheet takes for this group;
    /// nil for an Apple group.
    var androidCategory: SkinCatalogEntry.Category? {
        switch self {
        case .androidPhones: .phone
        case .androidFoldables: .foldable
        case .androidTablets: .tablet
        case .wear: .wear
        case .tv: .tv
        case .automotive: .automotive
        case .xr: .xr
        case .androidOther: .other
        default: nil
        }
    }
}

/// One card of the Browse Catalog: an SDK skin (Android) or a simulator
/// device type (Apple).
struct CatalogItem: Identifiable, Equatable {
    enum Source: Equatable {
        case skin(SkinCatalogEntry)
        case simulator(SimulatorDeviceType, SimulatorFamily)
    }

    let source: Source
    let group: CatalogGroup
    let name: String
    /// Apple: an installed, usable runtime runs the device type, so a
    /// simulator of it can be created. Always true for an Android skin.
    let isCreatable: Bool
    /// Apple: the installed runtimes that run the device type, newest first.
    let runtimeNames: [String]

    var platform: CatalogPlatform { group.platform }

    var id: String {
        switch source {
        case .skin(let entry): "android:\(entry.name)"
        case .simulator(let type, _): "apple:\(type.identifier)"
        }
    }

    var skin: SkinCatalogEntry? {
        if case .skin(let entry) = source { return entry }
        return nil
    }

    var deviceType: SimulatorDeviceType? {
        if case .simulator(let type, _) = source { return type }
        return nil
    }
}

/// Builds and filters the catalog's items; pure, so the tests cover it
/// without a window.
enum DeviceCatalog {
    /// Every Android skin, then every Apple device type of the five
    /// families, each with whether a usable runtime runs it. A device type
    /// of another family (HomePod, CarPlay) is left out: the New Simulator
    /// sheet has no family for it.
    static func items(
        skins: [SkinCatalogEntry],
        deviceTypes: [SimulatorDeviceType],
        runtimes: [SimulatorRuntime]
    ) -> [CatalogItem] {
        var items = SkinReleaseOrder.sortedWithinCategories(skins).map { entry in
            CatalogItem(
                source: .skin(entry),
                group: CatalogGroup(category: entry.category),
                name: entry.displayName,
                isCreatable: true,
                runtimeNames: []
            )
        }
        let families = Dictionary(
            uniqueKeysWithValues: SimulatorFamily.allCases.map { ($0.productFamily, $0) }
        )
        let usable = runtimes
            .filter { $0.isAvailable }
            .filter { !SimulatorOSSupport.isTooOld(platform: $0.platform, version: $0.version) }
            .sorted { SimulatorOSSupport.isNewer($0.version, than: $1.version) }
        for type in deviceTypes {
            guard let family = type.productFamily.flatMap({ families[$0] }),
                  let group = CatalogGroup(family: family)
            else { continue }
            let running = usable.filter {
                $0.platform == family.runtimePlatform
                    && $0.supportedDeviceTypeIdentifiers.contains(type.identifier)
            }
            items.append(CatalogItem(
                source: .simulator(type, family),
                group: group,
                name: type.name,
                isCreatable: !running.isEmpty,
                runtimeNames: running.map(\.name)
            ))
        }
        return items
    }

    /// `items` for `platform`, narrowed to `group` when one is given, to the
    /// ones a simulator can be created for when `onlyCreatable`, and to the
    /// ones matching every word of `search`. Android skins keep
    /// `items`' order (newest first within a section, `SkinReleaseOrder`),
    /// Apple device types simctl's.
    static func filter(
        _ items: [CatalogItem],
        platform: CatalogPlatform,
        group: CatalogGroup?,
        search: String,
        onlyCreatable: Bool
    ) -> [CatalogItem] {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        return items.filter { item in
            guard item.platform == platform else { return false }
            if let group, item.group != group { return false }
            if onlyCreatable, !item.isCreatable { return false }
            return words.allSatisfy { matches(item, word: $0) }
        }
    }

    /// The items of each group, in group order, empty groups left out.
    static func sections(_ items: [CatalogItem]) -> [(group: CatalogGroup, items: [CatalogItem])] {
        CatalogGroup.allCases.compactMap { group in
            let inGroup = items.filter { $0.group == group }
            return inGroup.isEmpty ? nil : (group, inGroup)
        }
    }

    /// The groups that have at least one item on `platform`, in group order.
    static func groups(in items: [CatalogItem], platform: CatalogPlatform) -> [CatalogGroup] {
        let present = Set(items.filter { $0.platform == platform }.map(\.group))
        return CatalogGroup.groups(of: platform).filter(present.contains)
    }

    private static func matches(_ item: CatalogItem, word: String) -> Bool {
        if item.name.localizedCaseInsensitiveContains(word) { return true }
        if item.group.label.localizedCaseInsensitiveContains(word) { return true }
        switch item.source {
        case .skin(let entry):
            return entry.name.localizedCaseInsensitiveContains(word)
        case .simulator(let type, _):
            return type.modelIdentifier?.localizedCaseInsensitiveContains(word) == true
        }
    }
}

/// The catalog card's and detail pane's facts about a device's screen.
enum CatalogScreenText {
    /// "1206 × 2622 px" for a screen `size` in pixels, portrait first for an
    /// Apple display (its profile is portrait), as declared for a skin.
    static func resolution(_ size: CGSize) -> String? {
        guard size.width > 0, size.height > 0 else { return nil }
        return "\(Int(size.width.rounded())) \u{00D7} \(Int(size.height.rounded())) px"
    }

    /// "@3x" for a display scale; nil for a scale of 1 or less.
    static func scale(_ scale: CGFloat) -> String? {
        guard scale > 1 else { return nil }
        let text = scale == scale.rounded() ? "\(Int(scale))" : String(format: "%.1f", Double(scale))
        return "@\(text)x"
    }
}
