import XCTest
@testable import DeviceHubProApp

/// The install popover's recents are path-keyed; the same file reached through
/// a symlink (e.g. `/tmp` vs `/private/tmp`) must not list twice.
@MainActor
final class RecentAPKStoreTests: XCTestCase {
    func testRecordDedupesTheSameFileReachedThroughASymlink() throws {
        let (real, link) = try makeSymlinkedAPK()
        let store = makeStore()

        store.record(url: real, package: "com.example.app", version: "1", name: "Example")
        store.record(url: link, package: "com.example.app", version: "1", name: "Example")

        XCTAssertEqual(store.entries.count, 1, "one file is one recent entry")
    }

    func testLoadDedupesPersistedSymlinkedPaths() throws {
        let (real, link) = try makeSymlinkedAPK()
        // A store of the test's own under the temporary directory: a plain
        // suite name would be a domain (and a plist) in ~/Library/Preferences.
        let defaults = UserDefaults.scratch()
        let persisted = [
            RecentAPKEntry(path: real.path, package: "com.example.app", version: "1", name: nil),
            RecentAPKEntry(path: link.path, package: "com.example.app", version: "1", name: nil),
        ]
        defaults.set(try JSONEncoder().encode(persisted), forKey: "recent")

        let store = RecentAPKStore(
            defaults: defaults,
            key: "recent",
            limit: 5,
            fileExists: { _ in true }
        )

        XCTAssertEqual(store.entries.count, 1, "persisted duplicates from a symlink must collapse")
    }

    // MARK: - Harness

    private func makeSymlinkedAPK() throws -> (real: URL, link: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentAPKStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appendingPathComponent("app.apk")
        try Data("apk".utf8).write(to: real)
        let link = directory.appendingPathComponent("alias.apk")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        return (real, link)
    }

    private func makeStore() -> RecentAPKStore {
        RecentAPKStore(
            defaults: UserDefaults.scratch(),
            key: "recent",
            limit: 5,
            fileExists: { _ in true }
        )
    }
}
