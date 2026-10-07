import Foundation

/// Keeps an emulator's own on-screen keyboard available while Keyboard
/// Capture is off.
///
/// An AVD made with `hw.keyboard=yes` (what Keyboard Capture needs) tells
/// Android a physical keyboard is attached, and Android then hides the soft
/// keyboard when the secure setting `show_ime_with_hard_keyboard` (Settings
/// ▸ System ▸ Keyboard ▸ Physical keyboard ▸ "Use on-screen keyboard") is 0.
/// Writing that one setting works live, with no restart (measured
/// 2026-10-05 on an API 35 google_apis image with the stock Google keyboard; see
/// `docs/soft-keyboard.md`). Capture off writes 1; capture on, deselecting
/// the device and quitting put the reading taken before Device Hub Pro's first
/// write back (a key that did not exist is deleted again).
public actor SoftKeyboardLease {
    static let key = "show_ime_with_hard_keyboard"

    /// What Device Hub Pro read before its first write on one emulator: the
    /// AVD it was (a serial is reused by the next AVD), and the original
    /// value; nil is "no such key".
    struct Lease: Equatable {
        var avd: String?
        var original: String?
    }

    /// The originals outlive the app, keyed by AVD name: the setting sits
    /// on the AVD's disk, so a crash, a force quit or a quit cut off at its
    /// bound would otherwise leave Device Hub Pro's `1` there for good.
    public struct Store: Sendable {
        public struct Entry: Codable, Equatable, Sendable {
            public var serial: String
            public var original: String?
        }

        let load: @Sendable () -> [String: Entry]
        let save: @Sendable ([String: Entry]) -> Void

        public init(load: @escaping @Sendable () -> [String: Entry], save: @escaping @Sendable ([String: Entry]) -> Void) {
            self.load = load
            self.save = save
        }

        /// One JSON value in `defaults`.
        public static func userDefaults(_ defaults: UserDefaults, key: String = "softKeyboardOriginals") -> Store {
            nonisolated(unsafe) let defaults = defaults
            return Store(
                load: {
                    guard let data = defaults.data(forKey: key),
                          let entries = try? JSONDecoder().decode([String: Entry].self, from: data)
                    else { return [:] }
                    return entries
                },
                save: { entries in
                    guard !entries.isEmpty, let data = try? JSONEncoder().encode(entries) else {
                        defaults.removeObject(forKey: key)
                        return
                    }
                    defaults.set(data, forKey: key)
                }
            )
        }
    }

    private let adb: AdbClient
    private let store: Store?
    /// The reading before the first write, per serial. A serial is present
    /// only while a write is outstanding.
    private var leases: [String: Lease] = [:]
    /// The last `sync`: the next one starts when it ends, so a quick toggle
    /// cannot restore while a show is still reading (and so leave the `1`
    /// it then writes unrecorded).
    private var syncTail: Task<Void, Never>?

    public init(adb: AdbClient, store: Store? = nil) {
        self.adb = adb
        self.store = store
    }

    /// Serials whose setting Device Hub Pro read and has not put back.
    public var leasedSerials: [String] { leases.keys.sorted() }

    /// Makes the soft keyboard show for `serial` (idempotent: reads first,
    /// writes only when the value is not 1, remembers the original once).
    public func showSoftKeyboard(serial: String) async {
        let avd = (try? await adb.avdName(serial: serial)) ?? nil
        guard let reading = try? await adb.shell(serial: serial, ["settings", "get", "secure", Self.key]) else {
            return
        }
        let current = Self.parse(reading)
        // Another AVD took the serial: the old lease is that VM's, which
        // is gone (its persisted record waits for its own AVD).
        if let held = leases[serial], held.avd != avd { leases[serial] = nil }
        if leases[serial] == nil {
            // A record of this AVD from an earlier run that never put it
            // back: its original is the truth, not the `1` read now.
            let stale = avd.flatMap { persisted()[$0] }
            leases[serial] = Lease(avd: avd, original: stale.map(\.original) ?? current)
            remember(serial: serial)
        }
        guard current != "1" else { return }
        _ = try? await adb.shell(serial: serial, ["settings", "put", "secure", Self.key, "1"])
    }

    /// Puts the original value back for `serial`; nothing when Device Hub Pro
    /// never read it (idempotent).
    public func restore(serial: String) async {
        guard let lease = leases[serial] else { return }
        leases[serial] = nil
        await putBack(lease.original, serial: serial)
        forget(avd: lease.avd)
    }

    /// Puts back what an earlier run left on the AVD behind `serial`, when
    /// this run holds no lease on it (a stage that shows the emulator
    /// without the soft keyboard being wanted).
    public func repairStale(serial: String) async {
        guard leases[serial] == nil,
              let avd = (try? await adb.avdName(serial: serial)) ?? nil,
              let stale = persisted()[avd]
        else { return }
        await putBack(stale.original, serial: serial)
        forget(avd: avd)
    }

    public func restoreAll() async {
        await syncTail?.value
        for serial in leases.keys.sorted() {
            await restore(serial: serial)
        }
    }

    /// Brings the leases to the wanted state: the soft keyboard shows on
    /// `target` (nil: nowhere), every other leased serial is restored, and
    /// `contact` (the emulator on the stage, when capture hides the soft
    /// keyboard) is repaired of an earlier run's leftover. Calls queue.
    public func sync(target: String?, contact: String? = nil) async {
        let previous = syncTail
        let task = Task { [self] in
            await previous?.value
            await performSync(target: target, contact: contact)
        }
        syncTail = task
        await task.value
    }

    private func performSync(target: String?, contact: String?) async {
        for serial in leases.keys.sorted() where serial != target {
            await restore(serial: serial)
        }
        if let target {
            await showSoftKeyboard(serial: target)
        } else if let contact {
            await repairStale(serial: contact)
        }
    }

    private func putBack(_ original: String?, serial: String) async {
        if let value = original {
            // Writing back what was there also leaves an already-1 value alone.
            guard value != "1" else { return }
            _ = try? await adb.shell(serial: serial, ["settings", "put", "secure", Self.key, value])
        } else {
            _ = try? await adb.shell(serial: serial, ["settings", "delete", "secure", Self.key])
        }
    }

    private func persisted() -> [String: Store.Entry] { store?.load() ?? [:] }

    private func remember(serial: String) {
        guard let store, let lease = leases[serial], let avd = lease.avd else { return }
        var entries = store.load()
        entries[avd] = Store.Entry(serial: serial, original: lease.original)
        store.save(entries)
    }

    private func forget(avd: String?) {
        guard let store, let avd else { return }
        var entries = store.load()
        guard entries.removeValue(forKey: avd) != nil else { return }
        store.save(entries)
    }

    /// `settings get` prints `null` for a missing key.
    static func parse(_ output: String) -> String? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "null" ? nil : value
    }
}
