import Foundation

/// The device-emulation overlays of the Google system images: resource
/// overlays that give Android the display shape (the rounded-corner radius,
/// the camera cutout and the status-bar insets) of one real Pixel.
///
/// An API 35 image carries them for pixel_3a ... pixel_9_pro_fold only, as
/// `com.android.internal.emulation.<device>` (framework: corners, cutout) and
/// `com.android.systemui.emulation.<device>` (system UI) for the newer ones.
/// Without one enabled Android knows no corner radius and no cutout (measured
/// on a Pixel 10 Pro AVD, API 35: `RoundedCorner` radius 0, no cutout), so the
/// status bar's clock sits under the frame's rounded corners. With
/// `pixel_9_pro` enabled the same AVD reports radius 157 and a cutout, and the
/// status bar moves inside the corners.
///
/// Who enables them: the emulator itself, at boot completion. Established
/// against emulator 36.6.11: its boot code enables overlay packages whose name
/// ends in the AVD's device name (`hw.device.name`) and ships the framework and
/// the system UI overlay of each Pixel 10 model as a pair
/// (`EmulationPixel10ProOverlay.apk` with `SystemUIEmulationPixel10ProOverlay.apk`),
/// which is why both packages are enabled together here. An API 35 image has no
/// overlay named after a Pixel 10 model, so the emulator enables none for those
/// AVDs; this type picks the overlay of the same-size Pixel instead.
public enum EmulationOverlay {
    public static let internalPrefix = "com.android.internal.emulation."
    public static let systemUIPrefix = "com.android.systemui.emulation."

    /// One line of `cmd overlay list`: `[x] <package>` (enabled),
    /// `[ ] <package>` (disabled) or `--- <package>` (not available).
    public struct Entry: Equatable, Sendable {
        public let package: String
        public let isEnabled: Bool
    }

    public static func parse(overlayList text: String) -> [Entry] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[x] ") { return Entry(package: String(trimmed.dropFirst(4)), isEnabled: true) }
            if trimmed.hasPrefix("[ ] ") { return Entry(package: String(trimmed.dropFirst(4)), isEnabled: false) }
            return nil
        }
    }

    /// The emulation devices the list offers: the names behind
    /// `com.android.internal.emulation.<name>`.
    public static func devices(in entries: [Entry]) -> [String] {
        entries.compactMap { entry in
            entry.package.hasPrefix(internalPrefix) ? String(entry.package.dropFirst(internalPrefix.count)) : nil
        }
    }

    /// The screen sizes (pixels) of the devices with an emulation overlay, from
    /// the SDK's own skins (`skins/<name>/layout`, display part).
    static let sizes: [String: (width: Int, height: Int)] = [
        "pixel_2_xl": (1440, 2880), "pixel_3": (1080, 2160), "pixel_3_xl": (1440, 2960),
        "pixel_3a": (1080, 2220), "pixel_3a_xl": (1080, 2160), "pixel_4": (1080, 2280),
        "pixel_4_xl": (1440, 3040), "pixel_4a": (1080, 2340), "pixel_5": (1080, 2340),
        "pixel_6": (1080, 2400), "pixel_6_pro": (1440, 3120), "pixel_6a": (1080, 2400),
        "pixel_7": (1080, 2400), "pixel_7_pro": (1440, 3120), "pixel_7a": (1080, 2400),
        "pixel_8": (1080, 2400), "pixel_8_pro": (1344, 2992), "pixel_8a": (1080, 2400),
        "pixel_9": (1080, 2424), "pixel_9_pro": (1280, 2856), "pixel_9_pro_xl": (1344, 2992),
        "pixel_9_pro_fold": (2076, 2152), "pixel_fold": (2208, 1840),
    ]

    /// The emulation device to enable for an AVD, or nil when none fits.
    ///
    /// `hw.device.name` itself when the list has an overlay for it. Otherwise
    /// the overlay of the newest Pixel with exactly the AVD's screen size
    /// (Pixel 10 → 9, 10 Pro → 9 Pro, 10 Pro XL → 9 Pro XL, 10 Pro Fold → 9 Pro
    /// Fold: identical panels), never for an "a" model (its corners differ from
    /// the same-size flagship's) and nil for a size nothing matches.
    public static func device(
        forDeviceName name: String?,
        lcdWidth: Int?,
        lcdHeight: Int?,
        available: [String]
    ) -> String? {
        if let name, available.contains(name) { return name }
        guard let name, name.hasPrefix("pixel_"), let lcdWidth, let lcdHeight else { return nil }
        let parts = name.split(separator: "_")
        if let model = parts.dropFirst().first, model.hasSuffix("a") { return nil }
        let matches = available.filter { candidate in
            guard let size = sizes[candidate] else { return false }
            return size.width == lcdWidth && size.height == lcdHeight
        }
        return matches.max { generation($0) < generation($1) }
    }

    private static func generation(_ device: String) -> Int {
        Int(device.split(separator: "_").dropFirst().first.map(String.init) ?? "") ?? 0
    }

    /// The packages to enable for `device`: the framework overlay and, when the
    /// image has it, the system UI one; none that is enabled already, and none
    /// at all while another emulation overlay is on (the emulator, Android
    /// Studio or the user chose one: it stays).
    public static func packagesToEnable(device: String, entries: [Entry]) -> [String] {
        let isEmulation: (Entry) -> Bool = {
            $0.package.hasPrefix(internalPrefix) || $0.package.hasPrefix(systemUIPrefix)
        }
        if entries.contains(where: { isEmulation($0) && $0.isEnabled }) { return [] }
        let wanted = [internalPrefix + device, systemUIPrefix + device]
        return wanted.filter { package in entries.contains { $0.package == package && !$0.isEnabled } }
    }

    /// Runs `shell` (the `adb -s <serial> shell` of a booted emulator) to list
    /// the overlays and enable the ones `packagesToEnable` names. Idempotent: a
    /// second run finds them enabled and runs only the list. Returns the
    /// packages it enabled. Best effort: a failed list or enable is ignored.
    @discardableResult
    public static func apply(
        deviceName: String?,
        lcdWidth: Int?,
        lcdHeight: Int?,
        isolation: isolated (any Actor)? = #isolation,
        shell: ([String]) async throws -> String
    ) async -> [String] {
        guard let listing = try? await shell(["cmd", "overlay", "list"]) else { return [] }
        let entries = parse(overlayList: listing)
        guard let device = device(
            forDeviceName: deviceName,
            lcdWidth: lcdWidth,
            lcdHeight: lcdHeight,
            available: devices(in: entries)
        ) else { return [] }
        var enabled: [String] = []
        for package in packagesToEnable(device: device, entries: entries) {
            if (try? await shell(["cmd", "overlay", "enable", package])) != nil {
                enabled.append(package)
            }
        }
        return enabled
    }
}
