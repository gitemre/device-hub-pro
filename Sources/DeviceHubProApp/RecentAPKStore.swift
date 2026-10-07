import Foundation
import Observation

/// One successful APK install, as the Apps tab's install popover lists it.
struct RecentAPKEntry: Codable, Equatable, Identifiable {
    /// Absolute path of the installed APK file — the entry's identity.
    var path: String
    var package: String?
    var version: String?
    /// The badging label, when the install could parse one.
    var name: String?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }

    /// The badging label when there is one; the APK's filename otherwise.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return url.deletingPathExtension().lastPathComponent
    }

    /// The row's second line: the package id when known.
    var subtitle: String? {
        guard let package, !package.isEmpty else { return nil }
        return package
    }
}

/// The install popover's recents (spec §7.2): the last few successfully
/// installed APKs, newest first, persisted in `UserDefaults`.
///
/// Entries are absolute paths plus the badging identity the install parsed, so
/// the popover renders without re-reading the APKs. Loading prunes files that
/// have since been deleted and caps the list; `record` moves a path to the
/// front, dedupes and caps. Recording is the caller's job and must happen only
/// after a successful install.
@MainActor
@Observable
final class RecentAPKStore {
    static let defaultKey = "recentAPKPaths"
    static let defaultLimit = 5

    private(set) var entries: [RecentAPKEntry] = []

    private let defaults: UserDefaults
    private let key: String
    private let limit: Int
    private let fileExists: (String) -> Bool

    /// A store persisting in `defaults`, which the caller always names (the
    /// model's environment store): a `.standard` default would let a test
    /// write the xctest runner's own preferences.
    init(
        defaults: UserDefaults,
        key: String = RecentAPKStore.defaultKey,
        limit: Int = RecentAPKStore.defaultLimit,
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.defaults = defaults
        self.key = key
        self.limit = limit
        self.fileExists = fileExists
        load()
    }

    /// Moves `url` to the front, deduping by canonical path — symlinks
    /// resolved, so the same APK reached as `/tmp/x.apk` and
    /// `/private/tmp/x.apk` is one entry — and capping at the limit. Call
    /// this only after the install reported success.
    func record(url: URL, package: String?, version: String?, name: String? = nil) {
        let canonical = Self.canonicalPath(url)
        var updated = entries
        updated.removeAll { $0.path == canonical }
        updated.insert(
            RecentAPKEntry(
                path: canonical,
                package: package,
                version: version,
                name: name
            ),
            at: 0
        )
        if updated.count > limit {
            updated.removeLast(updated.count - limit)
        }
        entries = updated
        persist()
    }

    /// Drops entries whose file no longer exists, in place. The popover calls
    /// this on open; `init` already pruned at launch.
    func pruneMissingFiles() {
        let pruned = entries.filter { fileExists($0.path) }
        guard pruned != entries else { return }
        entries = pruned
        persist()
    }

    // MARK: - Persistence

    private func load() {
        let stored: [RecentAPKEntry]
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([RecentAPKEntry].self, from: data) {
            stored = decoded
        } else {
            stored = []
        }

        var seen = Set<String>()
        var normalized: [RecentAPKEntry] = []
        for entry in stored {
            var canonical = entry
            canonical.path = Self.canonicalPath(entry.url)
            guard fileExists(canonical.path), seen.insert(canonical.path).inserted else { continue }
            normalized.append(canonical)
        }
        if normalized.count > limit {
            normalized.removeLast(normalized.count - limit)
        }
        entries = normalized
        if normalized != stored {
            persist()
        }
    }

    /// The filesystem identity of an APK path: symlinks resolved and `..`
    /// collapsed, so the same file reached two ways is one entry.
    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
