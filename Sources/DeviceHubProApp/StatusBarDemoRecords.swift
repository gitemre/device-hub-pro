import Foundation
import DeviceHubProKit

/// What the Status bar group keeps about one device until its put-back
/// succeeds (`StatusBarDemoController.records`).
struct StatusBarDemoRecord: Equatable, Codable {
    /// The keys as Device Hub Pro found them before its first write, and whether
    /// someone else's demo mode was on then.
    var original: StatusBarDemoOriginal
    /// Device Hub Pro's demo mode ended outside Device Hub Pro (Developer options,
    /// another tool's `exit`, the gate turned off): a demo mode seen since is
    /// someone else's. The put-back still puts the keys back and realigns
    /// the battery, but only once SystemUI is out of demo mode, and it never
    /// ends a demo mode at disconnect.
    var demoModeEnded = false

    init(_ original: StatusBarDemoOriginal, demoModeEnded: Bool = false) {
        self.original = original
        self.demoModeEnded = demoModeEnded
    }

    /// Someone else's demo mode was on when Device Hub Pro first wrote: nothing to
    /// put back.
    var isSomeoneElses: Bool { original.wasInDemoMode }
}

/// Where the Status bar's put-back records outlive the app: the keys sit on
/// the device's disk (an AVD's survive its emulator), so a relaunch after a
/// crash, a force quit or a quit cut off at its bound finishes the put-back
/// on the device's next session. One JSON value in `defaults`. A record kept
/// under an emulator's serial (its AVD name was unreadable) is not stored:
/// another AVD can take that serial.
///
/// every workspace's `DeviceConditionsController` builds its
/// own instance over the same `defaults` (one status bar group per window),
/// each keeping its own `records` dict (`StatusBarDemoController.records`).
/// A plain overwriting `save` would make the last writer win — one window's
/// save could resurrect a key another window deleted, or overwrite a key
/// another window just updated, neither of which this store ever learned
/// about. `save` instead diffs its caller's `records` against this store's
/// own last-known snapshot (from its last `load` or `save`) *per key*: only
/// a key whose value actually changed since then is written, and only a key
/// this store itself once knew about but no longer carries is deleted.
/// Every other key — one this store never saw, or has not touched since —
/// is left exactly as whichever store last wrote it, even though it still
/// sits, unread, in this store's own `records` dict. A class, so the
/// snapshot survives between calls.
final class StatusBarDemoRecordStore {
    static let key = "statusBarDemoRecords"

    let defaults: UserDefaults
    /// This store's own last-known picture of every key it has seen, from
    /// its last `load` or `save` — the base every `save` diffs against.
    private var lastKnown: [String: StatusBarDemoRecord] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> [String: StatusBarDemoRecord] {
        let records = readAll()
        lastKnown = records
        return records
    }

    /// Per-key diff against `lastKnown`: a key missing from `records` that
    /// this store once knew about is deleted (it removed that key itself);
    /// a key whose value differs from what this store last knew is written
    /// (it changed that key itself); every other key of `records` — carried
    /// along unchanged since this store's last `load`/`save` — is left
    /// alone, so a concurrent update to it by another store survives.
    func save(_ records: [String: StatusBarDemoRecord]) {
        var onDisk = readAll()
        for key in lastKnown.keys where records[key] == nil {
            onDisk[key] = nil
        }
        for (key, value) in records where lastKnown[key] != value {
            onDisk[key] = value
        }
        lastKnown = records
        writeAll(onDisk)
    }

    private func readAll() -> [String: StatusBarDemoRecord] {
        guard let data = defaults.data(forKey: Self.key),
              let records = try? JSONDecoder().decode([String: StatusBarDemoRecord].self, from: data)
        else { return [:] }
        return records.filter { !DeviceConditionsController.isEmulatorSerial($0.key) }
    }

    /// `records` is always already free of emulator-serial keys: `readAll`
    /// never returns one, and `save` only ever merges `readAll`'s result
    /// with values from its own (emulator-free, once loaded) `records`
    /// parameter — so this filter is only a defensive backstop.
    private func writeAll(_ records: [String: StatusBarDemoRecord]) {
        let kept = records.filter { !DeviceConditionsController.isEmulatorSerial($0.key) }
        guard !kept.isEmpty, let data = try? JSONEncoder().encode(kept) else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        defaults.set(data, forKey: Self.key)
    }
}
