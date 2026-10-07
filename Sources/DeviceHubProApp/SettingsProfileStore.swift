import Foundation
import Observation
import DeviceHubProKit

/// The settings profiles (Device Hub Pro's addition beyond Device Hub): the four
/// built-ins, which cannot be renamed or deleted, and the user's own, kept as
/// JSON in the app's defaults (`AppPreferences.Keys.settingsProfiles`). A
/// stored entry that cannot be read is dropped; a key it does not know is
/// ignored (`SettingsProfile`'s tolerant decoding).
@MainActor
@Observable
final class SettingsProfileStore {
    private(set) var userProfiles: [SettingsProfile]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let stored = defaults.data(forKey: AppPreferences.Keys.settingsProfiles)
        let read = SettingsProfiles.readUserProfiles(stored)
        userProfiles = read.profiles
        // Whatever could not be read stays recoverable: the next save
        // replaces the stored value, so the raw bytes go aside first (the
        // first backup is kept, never overwritten).
        if read.lostData, let stored,
           defaults.data(forKey: Self.backupKey) == nil {
            defaults.set(stored, forKey: Self.backupKey)
        }
    }

    /// Where unreadable stored profiles are kept.
    static let backupKey = AppPreferences.Keys.settingsProfiles + ".unreadableBackup"

    /// True once a save could not be encoded; the profiles stay in memory.
    private(set) var saveFailed = false

    /// Built-ins first, then the user's, in the order they were made.
    var profiles: [SettingsProfile] { SettingsProfiles.builtIns + userProfiles }

    func profile(id: String) -> SettingsProfile? { profiles.first { $0.id == id } }

    /// Whether `name` can name a profile other than `id`: not empty, not
    /// another profile's.
    func isNameAvailable(_ name: String, excluding id: String? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !profiles.contains { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Adds `profile` (never as a built-in); nil when it cannot be added.
    @discardableResult
    func add(_ profile: SettingsProfile) -> SettingsProfile? {
        var profile = profile
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.isBuiltIn, isNameAvailable(profile.name), !profiles.contains(where: { $0.id == profile.id }) else { return nil }
        userProfiles.append(profile)
        persist()
        return profile
    }

    @discardableResult
    func rename(id: String, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = userProfiles.firstIndex(where: { $0.id == id }),
              isNameAvailable(trimmed, excluding: id)
        else { return false }
        userProfiles[index].name = trimmed
        persist()
        return true
    }

    /// A copy under a free name, always a user profile (a built-in can be
    /// duplicated, which is how it is changed).
    @discardableResult
    func duplicate(id: String) -> SettingsProfile? {
        guard let original = profile(id: id) else { return nil }
        let name = SettingsProfiles.copyName(of: original.name, avoiding: profiles.map(\.name))
        let copy = original.duplicated(named: name)
        userProfiles.append(copy)
        persist()
        return copy
    }

    @discardableResult
    func delete(id: String) -> Bool {
        guard let index = userProfiles.firstIndex(where: { $0.id == id }) else { return false }
        userProfiles.remove(at: index)
        persist()
        return true
    }

    private func persist() {
        if let data = SettingsProfiles.encodeUserProfiles(userProfiles) {
            defaults.set(data, forKey: AppPreferences.Keys.settingsProfiles)
            saveFailed = false
        } else {
            saveFailed = true
            NSLog("Device Hub Pro: settings profiles could not be encoded; the stored copy is unchanged")
        }
    }
}
