import AppKit
import Foundation
import Observation
import DeviceHubProKit

/// The data inspector of one simulator app (App Container ▸ Inspect Data…):
/// the data container and the app group containers as a browsable tree with
/// sizes, Quick Look, export and delete; the app's UserDefaults plist with
/// key/value editing; and a read-only SQLite browser over a copy of a
/// database. Its reads and writes are `DeviceHubProKit`'s (`AppDataBrowser`,
/// `PreferencesDocument`, `SQLiteBrowser`); this class holds the state a
/// sheet shows and asks the simulator whether the app runs.
///
/// The plist is written back only while the app is not running: a running app
/// (and the simulator's preferences daemon) keeps its own copy of the values
/// and would overwrite the edit. `savePreferences` reports `.appRunning`
/// first, and the sheet offers to terminate the app and save.
@MainActor
@Observable
final class SimulatorAppDataController {
    /// A folder the inspector browses: the data container or an app group's.
    struct Root: Identifiable, Hashable {
        let title: String
        let url: URL
        var id: String { url.path }
    }

    enum SaveOutcome: Equatable {
        case saved
        case appRunning
        case failed
    }

    let app: SimulatorApp
    let udid: String

    // Files
    private(set) var roots: [Root] = []
    private(set) var root: Root?
    private(set) var directory: URL?
    private(set) var entries: [AppDataEntry] = []
    private(set) var isLoading = false
    private(set) var problem: String?
    var selection: AppDataEntry.ID?

    // Preferences
    private(set) var preferences: PreferencesDocument?
    private(set) var preferenceEntries: [PreferenceEntry] = []
    private(set) var preferencesProblem: String?
    private(set) var preferencesDirty = false
    private(set) var preferencesFileExists = false

    // Databases
    private(set) var databases: [URL] = []
    private(set) var openDatabase: URL?
    private(set) var tables: [SQLiteTable] = []
    private(set) var rows: SQLiteRows?
    private(set) var selectedTable: String?
    private(set) var databaseProblem: String?

    @ObservationIgnored private let simctl: SimctlClient
    @ObservationIgnored private let status: StatusCenter
    @ObservationIgnored private let temporaryDirectory: URL
    @ObservationIgnored private var browser: SQLiteBrowser?
    @ObservationIgnored private var generation = 0

    init(app: SimulatorApp, udid: String, simctl: SimctlClient, status: StatusCenter, temporaryDirectory: URL) {
        self.app = app
        self.udid = udid
        self.simctl = simctl
        self.status = status
        self.temporaryDirectory = temporaryDirectory
    }

    // MARK: - Roots

    /// Finds the containers (the data container, then each app group) and
    /// opens the data container's top folder.
    func start() async {
        isLoading = true
        defer { isLoading = false }
        var found: [Root] = []
        if let container = app.dataContainer, container.isFileURL {
            found.append(Root(title: "Data Container", url: container))
        } else if let path = try? await simctl.appContainerPath(
            udid: udid, bundleIdentifier: app.bundleIdentifier, container: .data
        ), !path.isEmpty {
            found.append(Root(title: "Data Container", url: URL(fileURLWithPath: path, isDirectory: true)))
        }
        if let groups = try? await simctl.groupContainers(udid: udid, bundleIdentifier: app.bundleIdentifier) {
            for group in groups.sorted(by: { $0.identifier < $1.identifier }) {
                found.append(Root(title: group.identifier, url: URL(fileURLWithPath: group.path, isDirectory: true)))
            }
        }
        roots = found
        guard let first = found.first else {
            problem = "\(app.title) has no data container. Launch it once, then try again."
            return
        }
        await select(root: first)
        await loadPreferences()
        await findDatabases()
    }

    func select(root: Root) async {
        self.root = root
        await show(directory: root.url)
    }

    // MARK: - Files

    func show(directory url: URL) async {
        guard let root else { return }
        generation += 1
        let mine = generation
        isLoading = true
        defer { isLoading = false }
        do {
            let listed = try await Task.detached(priority: .userInitiated) {
                try AppDataBrowser.entries(in: url, root: root.url)
            }.value
            guard mine == generation else { return }
            directory = url
            entries = listed
            problem = nil
            selection = nil
        } catch {
            guard mine == generation else { return }
            problem = "Could not read the folder: \(error)"
        }
    }

    /// The folders from the root to the shown folder, for the path bar.
    var breadcrumb: [URL] {
        guard let root, let directory else { return [] }
        var chain: [URL] = [directory]
        var current = directory
        while AppDataBrowser.resolvedPath(current) != AppDataBrowser.resolvedPath(root.url) {
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            chain.append(parent)
            current = parent
        }
        return chain.reversed()
    }

    var canGoUp: Bool {
        guard let root, let directory else { return false }
        return AppDataBrowser.resolvedPath(directory) != AppDataBrowser.resolvedPath(root.url)
    }

    func goUp() async {
        guard canGoUp, let directory else { return }
        await show(directory: directory.deletingLastPathComponent())
    }

    func open(_ entry: AppDataEntry) async {
        if entry.isDirectory {
            await show(directory: entry.url)
        } else if AppDataBrowser.isSQLiteDatabase(entry.url) {
            await openDatabase(entry.url)
        }
    }

    var selectedEntry: AppDataEntry? {
        guard let selection else { return nil }
        return entries.first { $0.id == selection }
    }

    func reload() async {
        if let directory { await show(directory: directory) }
    }

    func export(_ entry: AppDataEntry, to folder: URL) async {
        guard let root else { return }
        do {
            let copy = try await Task.detached(priority: .userInitiated) {
                try AppDataBrowser.export(entry.url, root: root.url, to: folder)
            }.value
            status.flash("Exported \(entry.name)")
            NSWorkspace.shared.activateFileViewerSelecting([copy])
        } catch {
            status.errorMessage = "Unable to Export \(entry.name): \(error)"
        }
    }

    /// Deletes after the user confirmed.
    func delete(_ entry: AppDataEntry) async {
        guard let root else { return }
        do {
            try await Task.detached(priority: .userInitiated) {
                try AppDataBrowser.delete(entry.url, root: root.url)
            }.value
            status.flash("Deleted \(entry.name)")
        } catch {
            status.errorMessage = "Unable to Delete \(entry.name): \(error)"
        }
        await reload()
        await findDatabases()
        await loadPreferences()
    }

    // MARK: - Preferences

    var preferencesURL: URL? {
        guard let container = roots.first?.url else { return nil }
        return AppDataBrowser.preferencesURL(dataContainer: container, bundleIdentifier: app.bundleIdentifier)
    }

    func loadPreferences() async {
        guard let url = preferencesURL else { return }
        preferencesDirty = false
        preferencesFileExists = FileManager.default.fileExists(atPath: url.path)
        guard preferencesFileExists else {
            preferences = nil
            preferenceEntries = []
            preferencesProblem = "\(app.title) has no preferences file yet (it writes one when it first saves a setting)."
            return
        }
        do {
            let document = try PreferencesDocument(contentsOf: url)
            preferences = document
            preferenceEntries = document.entries
            preferencesProblem = nil
        } catch {
            preferences = nil
            preferenceEntries = []
            preferencesProblem = "Could not read the preferences: \(error)"
        }
    }

    /// Changes one key in the open document (nothing reaches the file until `savePreferences`).
    func setPreference(key: String, kind: PreferenceKind, text: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            status.errorMessage = "A key cannot be empty."
            return false
        }
        var document = preferences ?? PreferencesDocument()
        do {
            try document.set(key: key, kind: kind, text: text)
        } catch {
            status.errorMessage = "Unable to Change \(key): \(error)"
            return false
        }
        preferences = document
        preferenceEntries = document.entries
        preferencesDirty = true
        return true
    }

    func removePreference(key: String) {
        guard var document = preferences else { return }
        do {
            try document.remove(key: key)
        } catch {
            status.errorMessage = "Unable to Delete \(key): \(error)"
            return
        }
        preferences = document
        preferenceEntries = document.entries
        preferencesDirty = true
    }

    func discardPreferenceChanges() async {
        await loadPreferences()
    }

    /// Writes the plist back, only while the app is not running. With the app
    /// running and `terminatingIfRunning` false nothing is written and the
    /// result is `.appRunning`, so the sheet can ask; with it true the app is
    /// terminated first.
    func savePreferences(terminatingIfRunning: Bool) async -> SaveOutcome {
        guard let document = preferences, let url = preferencesURL else { return .failed }
        do {
            if try await simctl.isAppRunning(udid: udid, bundleIdentifier: app.bundleIdentifier) {
                guard terminatingIfRunning else { return .appRunning }
                try await simctl.terminate(udid: udid, bundleIdentifier: app.bundleIdentifier)
            }
        } catch let failure as SimctlFailure where failure.kind == .notFound {
            // Not running after all.
        } catch {
            status.errorMessage = "Unable to Save Preferences: \(error)"
            return .failed
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try document.write(to: url)
            status.flash("Saved the preferences of \(app.title)")
            await loadPreferences()
            return .saved
        } catch {
            status.errorMessage = "Unable to Save Preferences: \(error)"
            return .failed
        }
    }

    // MARK: - Databases

    /// The SQLite files under the data container (checked by their header).
    func findDatabases() async {
        guard let container = roots.first?.url else { return }
        databases = await Task.detached(priority: .userInitiated) {
            AppDataBrowser.sqliteDatabases(under: container)
        }.value
    }

    /// Opens a copy of `url` read-only and lists its tables.
    func openDatabase(_ url: URL) async {
        browser?.close()
        let next = SQLiteBrowser(source: url, temporaryDirectory: temporaryDirectory)
        browser = next
        openDatabase = url
        tables = []
        rows = nil
        selectedTable = nil
        databaseProblem = nil
        do {
            try next.reload()
            tables = try await next.tables()
            if let first = tables.first { await showTable(first.name) }
        } catch {
            databaseProblem = "Could not open \(url.lastPathComponent): \(error)"
        }
    }

    /// Takes a new copy of the open database (the app may have written since).
    func refreshDatabase() async {
        guard let url = openDatabase else { return }
        let table = selectedTable
        await openDatabase(url)
        if let table, tables.contains(where: { $0.name == table }) { await showTable(table) }
    }

    func showTable(_ name: String) async {
        guard let browser else { return }
        selectedTable = name
        do {
            rows = try await browser.rows(of: name)
            databaseProblem = nil
        } catch {
            rows = nil
            databaseProblem = "Could not read \(name): \(error)"
        }
    }

    /// Removes the database copy; the sheet calls it when it closes.
    func close() {
        browser?.close()
        browser = nil
    }
}
