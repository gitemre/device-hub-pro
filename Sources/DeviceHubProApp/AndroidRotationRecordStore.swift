import DeviceHubProKit
import Foundation

/// Where a phone's rotation settings, as they were before Device Hub Pro's first
/// Rotate, outlive the app: the two settings sit on the phone, so a crash or
/// a force quit with a pinned pose would otherwise leave the phone rotation
/// locked for good. The next session of that phone puts them back
/// (`MirrorController.restorePendingRotation`). One JSON value in
/// `defaults`, keyed by adb serial (a phone's serial is its own); every call
/// reads and writes the stored value whole, so several windows never clobber
/// each other's records.
struct AndroidRotationRecordStore {
    static let key = "androidRotationRecords"

    let defaults: UserDefaults

    func record(for serial: String) -> AndroidPhoneRotation.Saved? {
        readAll()[serial]
    }

    /// The stored keys that belong to the same phone as `serial`: the serial
    /// itself, its other adb transports (`aliases`: alias → row serial, as
    /// `DeviceInventory.serialAliases`), and any key naming the same
    /// `ro.serialno` (a USB serial is its serialno, an mDNS name carries it).
    /// A Rotate recorded over USB is found again once the phone is back
    /// over Wi-Fi, and a wireless port that changed does not orphan it.
    func keys(samePhoneAs serial: String, aliases: [String: String]) -> [String] {
        var group: Set<String> = [serial]
        if let row = aliases[serial] { group.insert(row) }
        let rows = group
        for (alias, row) in aliases where rows.contains(row) { group.insert(alias) }
        let serialnos = Set(group.compactMap(AndroidDeviceGrouping.selfDescribedSerialno(of:)))
        return readAll().keys.filter { key in
            group.contains(key)
                || AndroidDeviceGrouping.selfDescribedSerialno(of: key).map(serialnos.contains) == true
        }.sorted { a, b in a == serial || (b != serial && a < b) }
    }

    func set(_ saved: AndroidPhoneRotation.Saved, for serial: String) {
        var all = readAll()
        all[serial] = saved
        writeAll(all)
    }

    func remove(serial: String) {
        var all = readAll()
        guard all.removeValue(forKey: serial) != nil else { return }
        writeAll(all)
    }

    private func readAll() -> [String: AndroidPhoneRotation.Saved] {
        guard let data = defaults.data(forKey: Self.key),
              let all = try? JSONDecoder().decode([String: AndroidPhoneRotation.Saved].self, from: data)
        else { return [:] }
        return all
    }

    private func writeAll(_ all: [String: AndroidPhoneRotation.Saved]) {
        guard !all.isEmpty, let data = try? JSONEncoder().encode(all) else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        defaults.set(data, forKey: Self.key)
    }
}
