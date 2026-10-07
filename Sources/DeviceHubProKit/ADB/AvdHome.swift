import Foundation

/// Where the Android tools keep AVDs, and the name checks AVD creation needs.
///
/// An AVD is a `<name>.ini` registry entry plus a `<name>.avd` folder in the
/// AVD home. macOS volumes are case-insensitive by default, so `Pixel_9` and
/// `pixel_9` are the same folder: every name comparison here ignores case.
public enum AvdHome {
    /// The AVD home, resolved the way the emulator (`emulator -list-avds`)
    /// and `avdmanager` resolve it:
    ///
    /// 1. `ANDROID_AVD_HOME`, when it names an existing directory (the
    ///    emulator ignores it otherwise);
    /// 2. `ANDROID_EMULATOR_HOME/avd`;
    /// 3. `ANDROID_USER_HOME/avd`;
    /// 4. `ANDROID_PREFS_ROOT/.android/avd`, then the deprecated
    ///    `ANDROID_SDK_HOME/.android/avd`;
    /// 5. `~/.android/avd`.
    public static func url(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        func value(_ key: String) -> String? {
            guard let value = environment[key], !value.isEmpty else { return nil }
            return value
        }
        if let avdHome = value("ANDROID_AVD_HOME") {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: avdHome, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return URL(fileURLWithPath: avdHome, isDirectory: true)
            }
        }
        for key in ["ANDROID_EMULATOR_HOME", "ANDROID_USER_HOME"] {
            if let root = value(key) {
                return URL(fileURLWithPath: root, isDirectory: true)
                    .appendingPathComponent("avd", isDirectory: true)
            }
        }
        for key in ["ANDROID_PREFS_ROOT", "ANDROID_SDK_HOME"] {
            if let root = value(key) {
                return URL(fileURLWithPath: root, isDirectory: true)
                    .appendingPathComponent(".android/avd", isDirectory: true)
            }
        }
        return homeDirectory.appendingPathComponent(".android/avd", isDirectory: true)
    }

    /// Every AVD name taken in `home`: registered `<name>.ini` entries and
    /// `<name>.avd` folders (an orphaned folder blocks the name too). Sorted,
    /// one entry per case-insensitive name.
    public static func avdNames(in home: URL) -> [String] {
        // Best effort: an unreadable or missing home holds no AVDs.
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        var seen = Set<String>()
        var names: [String] = []
        for entry in entries.sorted() {
            let path = entry as NSString
            guard ["ini", "avd"].contains(path.pathExtension.lowercased()) else { continue }
            let name = path.deletingPathExtension
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            names.append(name)
        }
        return names
    }

    /// Whether an AVD named `name` already exists in `home`, ignoring case.
    public static func containsAvd(named name: String, in home: URL) -> Bool {
        let wanted = name.lowercased()
        return avdNames(in: home).contains { $0.lowercased() == wanted }
    }
}

extension AvdmanagerClient {
    /// A name for a new AVD that collides with none of `existing`, compared
    /// case-insensitively (see `AvdHome`). The first free candidate wins; when
    /// every candidate is taken, the last one gets the first free numeric
    /// suffix (`_2`, `_3`, …). Candidates are used as given — sanitize them
    /// with `sanitizedAvdName` first.
    ///
    /// `PixelCatalog.avdName`'s `Pixel_9_Pro` → `Pixel_9_Pro_API35` →
    /// `Pixel_9_Pro_API35_2` ladder is `uniqueAvdName(candidates: [base,
    /// apiName], existing:)`.
    public static func uniqueAvdName(
        candidates: [String],
        existing: some Sequence<String>
    ) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        for candidate in candidates where !taken.contains(candidate.lowercased()) {
            return candidate
        }
        let last = candidates.last ?? "device"
        var index = 2
        while taken.contains("\(last)_\(index)".lowercased()) {
            index += 1
        }
        return "\(last)_\(index)"
    }

    /// `uniqueAvdName(candidates:existing:)` for one preferred name.
    public static func uniqueAvdName(_ name: String, existing: some Sequence<String>) -> String {
        uniqueAvdName(candidates: [name], existing: existing)
    }

    /// A name for a new AVD that is free in `avdHome` (default: the resolved
    /// `AvdHome.url()`), ignoring case.
    public static func uniqueAvdName(_ name: String, avdHome: URL? = nil) -> String {
        uniqueAvdName(name, existing: AvdHome.avdNames(in: avdHome ?? AvdHome.url()))
    }

    /// Whether an AVD named `name` already exists in `avdHome` (default: the
    /// resolved `AvdHome.url()`), ignoring case. `createAvd` refuses such a
    /// name; the create sheet can check it up front.
    public static func avdExists(named name: String, avdHome: URL? = nil) -> Bool {
        AvdHome.containsAvd(named: name, in: avdHome ?? AvdHome.url())
    }
}
