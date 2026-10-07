import Foundation
import Observation
import DeviceHubProKit

/// What the user keeps between launches, in Application Support as JSON:
/// saved push payloads (and the last push sent, for Resend Last), named deep
/// links, and the last Launch with Options per bundle id. With no directory
/// (every test model) nothing is read or written.
@MainActor
@Observable
final class SavedLibraries {
    struct LaunchOptionsEntry: Codable, Equatable {
        var bundleIdentifier: String
        var options: SimulatorLaunchOptions
    }

    private(set) var pushes: NamedLibrary<SavedPush>
    private(set) var links: NamedLibrary<SavedLink>
    private(set) var lastPush: SentPush?
    private(set) var launchOptions: [String: SimulatorLaunchOptions]

    @ObservationIgnored private let directory: URL?

    init(directory: URL?) {
        self.directory = directory
        pushes = NamedLibrary(items: Self.file("push-library.json", in: directory)?.load(SavedPush.self) ?? [])
        links = NamedLibrary(items: Self.file("deep-links.json", in: directory)?.load(SavedLink.self) ?? [])
        lastPush = Self.file("last-push.json", in: directory)?.load(SentPush.self).first
        let entries = Self.file("launch-options.json", in: directory)?.load(LaunchOptionsEntry.self) ?? []
        launchOptions = Dictionary(entries.map { ($0.bundleIdentifier, $0.options) }) { _, last in last }
    }

    private static func file(_ name: String, in directory: URL?) -> LibraryFile? {
        directory.map { LibraryFile(url: $0.appendingPathComponent(name)) }
    }

    private func save<T: Codable>(_ items: [T], as name: String) {
        Self.file(name, in: directory)?.save(items)
    }

    // MARK: Pushes

    @discardableResult
    func savePush(name: String, bundleIdentifier: String, payload: String) -> SavedPush {
        let saved = pushes.add(SavedPush(name: name, bundleIdentifier: bundleIdentifier, payload: payload))
        save(pushes.items, as: "push-library.json")
        return saved
    }

    @discardableResult
    func updatePush(_ push: SavedPush) -> Bool {
        let changed = pushes.update(push)
        if changed { save(pushes.items, as: "push-library.json") }
        return changed
    }

    @discardableResult
    func renamePush(id: UUID, to name: String) -> Bool {
        let changed = pushes.rename(id: id, to: name)
        if changed { save(pushes.items, as: "push-library.json") }
        return changed
    }

    @discardableResult
    func duplicatePush(id: UUID) -> SavedPush? {
        let copy = pushes.duplicate(id: id)
        if copy != nil { save(pushes.items, as: "push-library.json") }
        return copy
    }

    func deletePush(id: UUID) {
        if pushes.delete(id: id) { save(pushes.items, as: "push-library.json") }
    }

    func recordSentPush(bundleIdentifier: String, payload: String) {
        let sent = SentPush(bundleIdentifier: bundleIdentifier, payload: payload)
        lastPush = sent
        save([sent], as: "last-push.json")
    }

    // MARK: Deep links

    @discardableResult
    func saveLink(name: String, url: String, group: String?) -> SavedLink {
        let trimmed = group?.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = links.add(SavedLink(name: name, url: url, group: trimmed?.isEmpty == false ? trimmed : nil))
        save(links.items, as: "deep-links.json")
        return saved
    }

    @discardableResult
    func updateLink(_ link: SavedLink) -> Bool {
        let changed = links.update(link)
        if changed { save(links.items, as: "deep-links.json") }
        return changed
    }

    @discardableResult
    func duplicateLink(id: UUID) -> SavedLink? {
        let copy = links.duplicate(id: id)
        if copy != nil { save(links.items, as: "deep-links.json") }
        return copy
    }

    func deleteLink(id: UUID) {
        if links.delete(id: id) { save(links.items, as: "deep-links.json") }
    }

    // MARK: Launch options

    func options(for bundleIdentifier: String) -> SimulatorLaunchOptions {
        launchOptions[bundleIdentifier] ?? SimulatorLaunchOptions()
    }

    func remember(_ options: SimulatorLaunchOptions, for bundleIdentifier: String) {
        launchOptions[bundleIdentifier] = options
        let entries = launchOptions.keys.sorted().map { LaunchOptionsEntry(bundleIdentifier: $0, options: launchOptions[$0]!) }
        save(entries, as: "launch-options.json")
    }
}
