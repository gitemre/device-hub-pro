import Foundation

/// One selectable system image for a Pixel device.
public struct PixelImageCandidate: Sendable, Hashable, Identifiable {
    public let image: SystemImage
    public let isInstalled: Bool
    /// False when the image's API is below the device's minimum.
    public let meetsMinimum: Bool

    public init(image: SystemImage, isInstalled: Bool, meetsMinimum: Bool) {
        self.image = image
        self.isInstalled = isInstalled
        self.meetsMinimum = meetsMinimum
    }

    public var id: String { image.package }
}

/// Picks the system images offered for a Pixel device and the default one.
public enum PixelImageSuggestion {
    /// Candidates for `device`, host-ABI only, ATD excluded, `ps16k`
    /// superseding its plain sibling. Installed first (highest API), then
    /// downloadable (highest API); the tag preference only orders images of
    /// the same API.
    public static func candidates(
        device: PixelDevice,
        installed: [SystemImage],
        available: [SystemImage],
        hostAbi: String
    ) -> [PixelImageCandidate] {
        var seenPackages = Set<String>()
        var merged: [(SystemImage, Bool)] = []
        for image in installed where isOffered(image, hostAbi: hostAbi) {
            if seenPackages.insert(image.package).inserted { merged.append((image, true)) }
        }
        for image in available where isOffered(image, hostAbi: hostAbi) {
            if seenPackages.insert(image.package).inserted { merged.append((image, false)) }
        }

        // Collapse each API+ABI+tag-family group to one image: an installed
        // member wins (never recommend a download over an installed
        // equivalent), else the ps16k variant (16 KB pages), else the plain.
        struct FamilyKey: Hashable {
            let api: String
            let abi: String
            let family: String
        }
        var best: [FamilyKey: (SystemImage, Bool)] = [:]
        for (image, isInstalled) in merged {
            let family = image.tag.replacingOccurrences(of: "_ps16k", with: "")
            let key = FamilyKey(api: image.api, abi: image.abi, family: family)
            guard let current = best[key] else {
                best[key] = (image, isInstalled)
                continue
            }
            let currentIsPs16k = current.0.tag.hasSuffix("_ps16k")
            let imageIsPs16k = image.tag.hasSuffix("_ps16k")
            if isInstalled != current.1 {
                if isInstalled { best[key] = (image, isInstalled) }
            } else if imageIsPs16k, !currentIsPs16k {
                best[key] = (image, isInstalled)
            }
        }
        merged = Array(best.values)

        let prefersPlaystore = device.playstoreEnabled
        let isPreferredTag: (String) -> Bool = { tag in
            if prefersPlaystore { return tag.hasPrefix("google_apis_playstore") }
            return tag.hasPrefix("google_apis") && !tag.hasPrefix("google_apis_playstore")
        }

        let sorted = merged.sorted { left, right in
            if left.1 != right.1 { return left.1 }
            let apiOrder = PixelMinApiTable.compare(left.0.api, right.0.api)
            if apiOrder != .orderedSame { return apiOrder == .orderedDescending }
            let leftPreferred = isPreferredTag(left.0.tag)
            let rightPreferred = isPreferredTag(right.0.tag)
            if leftPreferred != rightPreferred { return leftPreferred }
            if left.0.tag != right.0.tag { return left.0.tag < right.0.tag }
            // Same API number and tag: an SDK-extension image
            // (`android-36-ext19`) and its plain sibling (`android-36`).
            // The newer extension level first, so the order never depends on
            // the dictionary the candidates were collapsed in.
            return left.0.api.compare(right.0.api, options: .numeric) == .orderedDescending
        }

        return sorted.map { image, isInstalled in
            PixelImageCandidate(
                image: image,
                isInstalled: isInstalled,
                meetsMinimum: meetsMinimum(device: device, image: image)
            )
        }
    }

    private static func meetsMinimum(device: PixelDevice, image: SystemImage) -> Bool {
        guard let minApi = device.minApi else { return true }
        return PixelMinApiTable.compare(image.api, minApi) != .orderedAscending
    }

    /// Whether an image belongs in a Pixel device's picker at all: the given
    /// host ABI, a stable release channel, and a tag a Pixel can actually
    /// boot. ATD test images, wear/automotive/desktop/TV/XR images and
    /// preview or beta releases stay out (the create sheet remains the place
    /// for those). `sdkmanager --list` spells the canary channel both ways:
    /// the rolling `android-CANARY` and dated `android-canary-20260909`.
    static func isOffered(_ image: SystemImage, hostAbi: String) -> Bool {
        guard image.abi == hostAbi else { return false }
        let api = image.api.lowercased()
        guard !api.contains("canary"), !api.contains("beta") else { return false }
        if image.tag.hasPrefix("google_atd") || image.tag.hasPrefix("aosp_atd") {
            return false
        }
        if image.tag.hasPrefix("android-wear") || image.tag.hasPrefix("android-automotive") {
            return false
        }
        if image.tag.hasPrefix("android-desktop") || image.tag.hasPrefix("android-xr") {
            return false
        }
        if image.tag.hasPrefix("android-tv") || image.tag.hasPrefix("google-tv") {
            return false
        }
        if image.tag.hasPrefix("google-xr") { return false }
        return true
    }

    /// The default pick: the highest installed candidate meeting the
    /// minimum, else the newest available candidate meeting it.
    public static func preferred(in candidates: [PixelImageCandidate]) -> PixelImageCandidate? {
        let usable = candidates.filter(\.meetsMinimum)
        return usable.first(where: \.isInstalled) ?? usable.first
    }
}
