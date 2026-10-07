import Foundation
import Observation
import DeviceHubProKit

/// The Links group's Recent popup: the last links opened from this Mac,
/// newest first, persisted in `UserDefaults` (the `RecentAPKStore` pattern).
///
/// Stored per Mac, not per device, and never logged or bundled: links can
/// carry tokens, so Clear Recents removes the key. Ten one-line entries fit
/// a DHPopupRow popover; deep-link testing cycles through more URLs than
/// APK installs, which keep five.
@MainActor
@Observable
final class RecentLinkStore {
    static let defaultKey = "recentLinks"
    static let defaultLimit = 10

    private(set) var links: [String] = []

    private let defaults: UserDefaults
    private let key: String
    private let limit: Int

    /// A store persisting in `defaults`, which the caller always names (the
    /// model's environment store): a `.standard` default would let a test
    /// write the xctest runner's own preferences.
    init(
        defaults: UserDefaults,
        key: String = RecentLinkStore.defaultKey,
        limit: Int = RecentLinkStore.defaultLimit
    ) {
        self.defaults = defaults
        self.key = key
        self.limit = limit
        load()
    }

    /// Moves `uri` to the front and caps the list. Entries dedupe with
    /// Swift's `==` (canonical equivalence), keeping the newest entry's exact
    /// scalars: two canonically equal links would otherwise share one
    /// `Identifiable` id in the popover. The bytes sent are always the
    /// draft's own.
    func record(_ uri: String) {
        var updated = links
        updated.removeAll { $0 == uri }
        updated.insert(uri, at: 0)
        if updated.count > limit {
            updated.removeLast(updated.count - limit)
        }
        links = updated
        defaults.set(updated, forKey: key)
    }

    /// Clear Recents: empties the list and removes the key.
    func clear() {
        links = []
        defaults.removeObject(forKey: key)
    }

    /// Drops what `LinkRequest` refuses (validated with the larger, API 24+
    /// limit: the device's own limit applies when Open is pressed), dedupes,
    /// caps, and writes back only when that changed anything.
    private func load() {
        let stored = defaults.stringArray(forKey: key) ?? []
        var normalized: [String] = []
        for entry in stored {
            guard let request = try? LinkRequest(entry, apiLevel: LinkCommands.previewMinimumAPI),
                  !normalized.contains(request.uri)
            else { continue }
            normalized.append(request.uri)
        }
        if normalized.count > limit {
            normalized.removeLast(normalized.count - limit)
        }
        links = normalized
        let unchanged = normalized.count == stored.count
            && zip(normalized, stored).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
        if !unchanged {
            defaults.set(normalized, forKey: key)
        }
    }
}
