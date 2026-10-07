import XCTest
@testable import DeviceHubProKit

/// The app data inspector's Kit logic (`AppDataBrowser`, `PreferencesDocument`,
/// `SQLiteBrowser`, `AppDataStateArchive`) and the sample data
/// (`SimulatorSampleData`) on temporary folders. The folders and the SQLite
/// databases are made by the tests; the running-app check reads the real
/// `launchctl list` capture of the fixture device.
final class AppDataInspectorTests: XCTestCase {
    private func makeFolder(_ label: String = "data") throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDataInspectorTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Best effort: a leftover temporary folder must not fail the test.
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: Browser

    func testListingPutsFoldersFirstAndSumsTheirSize() throws {
        let root = try makeFolder()
        try write("12345", to: root.appendingPathComponent("Documents/a.txt"))
        try write("123", to: root.appendingPathComponent("Documents/sub/b.txt"))
        try write("1234567890", to: root.appendingPathComponent("z.txt"))
        try write("x", to: root.appendingPathComponent("a10.txt"))
        try write("x", to: root.appendingPathComponent("a2.txt"))

        let top = try AppDataBrowser.entries(in: root, root: root)
        XCTAssertEqual(top.map(\.name), ["Documents", "a2.txt", "a10.txt", "z.txt"])
        XCTAssertEqual(top.first?.isDirectory, true)
        XCTAssertEqual(top.first?.size, 8)
        XCTAssertEqual(top.last?.size, 10)
    }

    func testListingOutsideTheRootIsRefused() throws {
        let root = try makeFolder("root")
        let other = try makeFolder("other")
        XCTAssertThrowsError(try AppDataBrowser.entries(in: other, root: root)) { error in
            guard case AppDataBrowser.BrowserError.outsideRoot = error else { return XCTFail("\(error)") }
        }
        // A sibling whose name starts like the root's is not inside it.
        let sibling = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-2")
        XCTAssertFalse(AppDataBrowser.isInside(sibling, root: root))
    }

    func testASymbolicLinkOutOfTheRootIsNotFollowed() throws {
        let root = try makeFolder("root")
        let outside = try makeFolder("outside")
        try write("secret", to: outside.appendingPathComponent("secret.txt"))
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let listed = try AppDataBrowser.entries(in: root, root: root)
        XCTAssertEqual(listed.map(\.name), ["escape"])
        XCTAssertEqual(listed.first?.isSymbolicLink, true)
        XCTAssertEqual(listed.first?.isDirectory, false)
        // Listing or deleting through the link leaves the root.
        XCTAssertThrowsError(try AppDataBrowser.entries(in: link, root: root))
        XCTAssertThrowsError(try AppDataBrowser.delete(link.appendingPathComponent("secret.txt"), root: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("secret.txt").path))
        // Deleting the link itself removes the link only.
        try AppDataBrowser.delete(link, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("secret.txt").path))
    }

    func testDeleteRemovesAFileAndRefusesTheRootAndTraversal() throws {
        let root = try makeFolder()
        let file = root.appendingPathComponent("Documents/a.txt")
        try write("a", to: file)
        try AppDataBrowser.delete(file, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertThrowsError(try AppDataBrowser.delete(root, root: root)) { error in
            XCTAssertEqual(error as? AppDataBrowser.BrowserError, .isRoot)
        }
        let escape = root.appendingPathComponent("Documents/../../elsewhere")
        XCTAssertThrowsError(try AppDataBrowser.delete(escape, root: root))
        XCTAssertThrowsError(try AppDataBrowser.delete(root.appendingPathComponent(AppDataBrowser.metadataFileName), root: root))
    }

    func testExportCopiesOutAndNumbersATakenName() throws {
        let root = try makeFolder("root")
        let out = try makeFolder("out")
        let file = root.appendingPathComponent("Documents/report.txt")
        try write("one", to: file)
        let first = try AppDataBrowser.export(file, root: root, to: out)
        let second = try AppDataBrowser.export(file, root: root, to: out)
        XCTAssertEqual(first.lastPathComponent, "report.txt")
        XCTAssertEqual(second.lastPathComponent, "report 2.txt")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "one")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "export copies, it does not move")
    }

    func testFileKindDetection() throws {
        let root = try makeFolder()
        let plist = root.appendingPathComponent("a.plist")
        XCTAssertTrue(AppDataBrowser.isPropertyList(plist))
        let notDatabase = root.appendingPathComponent("fake.db")
        try write("not sqlite at all, just text", to: notDatabase)
        XCTAssertFalse(AppDataBrowser.isSQLiteDatabase(notDatabase))
        XCTAssertEqual(
            AppDataBrowser.preferencesURL(dataContainer: root, bundleIdentifier: "com.example.app").path,
            root.path + "/Library/Preferences/com.example.app.plist"
        )
    }

    func testRunningAppsAreReadFromTheCapturedLaunchctlList() throws {
        let text = try SimctlFixtureTests.text("simctl-core", "simctl-spawn-launchctl-list.ready.stdout.txt")
        let jobs = SimctlParsing.launchdJobs(fromLaunchctlList: text)
        XCTAssertTrue(SimctlClient.isAppRunning(bundleIdentifier: "com.apple.family", in: jobs))
        XCTAssertFalse(SimctlClient.isAppRunning(bundleIdentifier: "com.apple.fam", in: jobs), "a prefix is not the app")
        XCTAssertFalse(SimctlClient.isAppRunning(bundleIdentifier: "dev.example.none", in: jobs))
    }

    // MARK: Preferences

    private func makePlist(format: PropertyListSerialization.PropertyListFormat) throws -> URL {
        let url = try makeFolder("plist").appendingPathComponent("com.example.app.plist")
        let values: [String: Any] = [
            "name": "Ayşe",
            "launches": 7,
            "ratio": 0.25,
            "onboarded": true,
            "lastSeen": Date(timeIntervalSince1970: 0),
            "blob": Data([1, 2, 3]),
            "tags": ["a", "b"],
            "nested": ["k": "v"],
        ]
        try PropertyListSerialization.data(fromPropertyList: values, format: format, options: 0).write(to: url)
        return url
    }

    func testPreferencesAreShownWithTheirTypes() throws {
        let document = try PreferencesDocument(contentsOf: makePlist(format: .binary))
        let byKey = Dictionary(uniqueKeysWithValues: document.entries.map { ($0.key, $0) })
        XCTAssertEqual(byKey["name"]?.kind, .string)
        XCTAssertEqual(byKey["name"]?.text, "Ayşe")
        XCTAssertEqual(byKey["launches"]?.kind, .integer)
        XCTAssertEqual(byKey["ratio"]?.kind, .real)
        XCTAssertEqual(byKey["onboarded"]?.kind, .bool, "a boolean is not shown as the number 1")
        XCTAssertEqual(byKey["onboarded"]?.text, "true")
        XCTAssertEqual(byKey["lastSeen"]?.text, "1970-01-01T00:00:00Z")
        XCTAssertEqual(byKey["blob"]?.text, "3 bytes")
        XCTAssertEqual(byKey["tags"]?.text, "2 items")
        XCTAssertEqual(byKey["nested"]?.text, "1 item")
        XCTAssertEqual(document.entries.map(\.key), document.entries.map(\.key).sorted())
    }

    func testPreferencesEditsKeepTypesAndFormat() throws {
        for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            let url = try makePlist(format: format)
            var document = try PreferencesDocument(contentsOf: url)
            try document.set(key: "name", kind: .string, text: "Mehmet")
            try document.set(key: "launches", kind: .integer, text: " 12 ")
            try document.set(key: "ratio", kind: .real, text: "1.5")
            try document.set(key: "onboarded", kind: .bool, text: "false")
            try document.set(key: "brandNew", kind: .string, text: "x")
            try document.remove(key: "tags")
            try document.write(to: url)

            let head = try Data(contentsOf: url).prefix(6)
            XCTAssertEqual(head, format == .binary ? Data("bplist".utf8) : Data("<?xml ".utf8))
            let reread = try PreferencesDocument(contentsOf: url)
            let byKey = Dictionary(uniqueKeysWithValues: reread.entries.map { ($0.key, $0) })
            XCTAssertEqual(byKey["name"]?.text, "Mehmet")
            XCTAssertEqual(byKey["launches"]?.kind, .integer)
            XCTAssertEqual(byKey["launches"]?.text, "12")
            XCTAssertEqual(byKey["ratio"]?.text, "1.5")
            XCTAssertEqual(byKey["onboarded"]?.kind, .bool)
            XCTAssertEqual(byKey["onboarded"]?.text, "false")
            XCTAssertEqual(byKey["brandNew"]?.text, "x")
            XCTAssertNil(byKey["tags"])
            XCTAssertEqual(byKey["blob"]?.text, "3 bytes", "untouched values survive")
            XCTAssertEqual(byKey["nested"]?.text, "1 item")
        }
    }

    func testPreferencesRefuseBadValuesAndUneditableKeys() throws {
        var document = try PreferencesDocument(contentsOf: makePlist(format: .xml))
        XCTAssertThrowsError(try document.set(key: "launches", kind: .integer, text: "twelve"))
        XCTAssertThrowsError(try document.set(key: "ratio", kind: .real, text: "nan"))
        XCTAssertThrowsError(try document.set(key: "onboarded", kind: .bool, text: "maybe"))
        XCTAssertThrowsError(try document.set(key: "tags", kind: .string, text: "x")) { error in
            XCTAssertEqual(error as? PreferencesDocument.PreferencesError, .notEditable("tags"))
        }
        XCTAssertThrowsError(try document.remove(key: "missing"))
    }

    func testAPlistWithAnArrayRootIsRefused() throws {
        let url = try makeFolder("plist").appendingPathComponent("array.plist")
        try PropertyListSerialization.data(fromPropertyList: [1, 2], format: .xml, options: 0).write(to: url)
        XCTAssertThrowsError(try PreferencesDocument(contentsOf: url)) { error in
            XCTAssertEqual(error as? PreferencesDocument.PreferencesError, .notADictionary)
        }
    }

    // MARK: SQLite

    private func makeDatabase() async throws -> URL {
        let url = try makeFolder("db").appendingPathComponent("app.sqlite")
        let sql = #"""
        CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT, body BLOB, score REAL);
        INSERT INTO notes VALUES (1, 'first', x'0102030405', 1.5), (2, NULL, NULL, 2);
        CREATE TABLE "odd ""name""" (a, b);
        INSERT INTO "odd ""name""" VALUES ('x', 'y');
        CREATE VIEW titles AS SELECT title FROM notes;
        CREATE TABLE big (n INTEGER);
        WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 650) INSERT INTO big SELECT x FROM c;
        """#
        let result = try await ProcessRunner.run(
            executable: SQLiteBrowser.defaultExecutable, arguments: [url.path, sql], timeout: .seconds(20)
        )
        XCTAssertEqual(result.exitCode, 0, result.standardErrorText)
        return url
    }

    func testSQLiteListsTablesAndRowsFromACopy() async throws {
        let database = try await makeDatabase()
        let before = try Data(contentsOf: database)
        let browser = SQLiteBrowser(source: database, temporaryDirectory: try makeFolder("tmp"))
        try browser.reload()
        defer { browser.close() }

        let tables = try await browser.tables()
        XCTAssertEqual(tables.map(\.name), ["big", "notes", "odd \"name\"", "titles"])
        XCTAssertEqual(tables.first { $0.name == "titles" }?.isView, true)

        let notes = try await browser.rows(of: "notes")
        XCTAssertEqual(notes.columns, ["id", "title", "body", "score"], "the table's own column order")
        XCTAssertEqual(notes.rows, [["1", "first", "<blob 5 bytes>", "1.5"], ["2", "NULL", "NULL", "2"]])
        XCTAssertEqual(notes.totalRows, 2)
        XCTAssertFalse(notes.isTruncated)

        let odd = try await browser.rows(of: "odd \"name\"")
        XCTAssertEqual(odd.rows, [["x", "y"]])

        let big = try await browser.rows(of: "big")
        XCTAssertEqual(big.rows.count, 500)
        XCTAssertEqual(big.totalRows, 650)
        XCTAssertTrue(big.isTruncated)

        XCTAssertEqual(try Data(contentsOf: database), before, "the original is never written")
    }

    func testSQLiteRefusesAnUnlistedTableAndInjection() async throws {
        let database = try await makeDatabase()
        let browser = SQLiteBrowser(source: database, temporaryDirectory: try makeFolder("tmp"))
        try browser.reload()
        defer { browser.close() }
        do {
            _ = try await browser.rows(of: "notes; DROP TABLE notes")
            XCTFail("an unlisted name must be refused")
        } catch let error as SQLiteBrowser.SQLiteError {
            XCTAssertEqual(error, .noSuchTable("notes; DROP TABLE notes"))
        }
        let notes = try await browser.rows(of: "notes")
        XCTAssertEqual(notes.totalRows, 2)
    }

    func testSQLiteCloseRemovesTheCopyAndTheBrowserIsReadOnly() async throws {
        let database = try await makeDatabase()
        let scratch = try makeFolder("tmp")
        let browser = SQLiteBrowser(source: database, temporaryDirectory: scratch)
        try browser.reload()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path).count, 1)
        browser.close()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
        do {
            _ = try await browser.tables()
            XCTFail("a closed browser has no database")
        } catch {}
    }

    func testSQLiteDetectionByHeader() async throws {
        let database = try await makeDatabase()
        XCTAssertTrue(AppDataBrowser.isSQLiteDatabase(database))
    }

    // MARK: State archive

    func testSaveAndRestoreRoundTripsAContainer() async throws {
        let container = try makeFolder("container")
        let metadata = container.appendingPathComponent(AppDataBrowser.metadataFileName)
        try write("meta", to: metadata)
        try write("kept", to: container.appendingPathComponent("Documents/keep.txt"))
        try write("deep", to: container.appendingPathComponent("Library/Caches/deep/x.bin"))
        let archive = try makeFolder("zip").appendingPathComponent("state.zip")
        try await AppDataStateArchive.save(container: container, to: archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))

        // Change the container, then restore.
        try write("changed", to: container.appendingPathComponent("Documents/keep.txt"))
        try write("new", to: container.appendingPathComponent("Documents/added.txt"))
        try await AppDataStateArchive.restore(archive: archive, into: container, stagingDirectory: try makeFolder("stage"))

        XCTAssertEqual(try String(contentsOf: container.appendingPathComponent("Documents/keep.txt"), encoding: .utf8), "kept")
        XCTAssertEqual(try String(contentsOf: container.appendingPathComponent("Library/Caches/deep/x.bin"), encoding: .utf8), "deep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.appendingPathComponent("Documents/added.txt").path))
        XCTAssertEqual(try String(contentsOf: metadata, encoding: .utf8), "meta", "the container manager's file is left alone")
    }

    func testRestoreOfABadArchiveLeavesTheContainerAsItWas() async throws {
        let container = try makeFolder("container")
        try write("kept", to: container.appendingPathComponent("Documents/keep.txt"))
        let bad = try makeFolder("zip").appendingPathComponent("bad.zip")
        try write("this is not a zip", to: bad)
        do {
            try await AppDataStateArchive.restore(archive: bad, into: container, stagingDirectory: try makeFolder("stage"))
            XCTFail("a bad archive must fail")
        } catch {}
        XCTAssertEqual(try String(contentsOf: container.appendingPathComponent("Documents/keep.txt"), encoding: .utf8), "kept")

        let notZip = try makeFolder("zip").appendingPathComponent("state.txt")
        try write("x", to: notZip)
        do {
            try await AppDataStateArchive.restore(archive: notZip, into: container)
            XCTFail("only a .zip is restored")
        } catch let error as AppDataStateArchive.ArchiveError {
            XCTAssertEqual(error, .notAnArchive("state.txt"))
        }
    }

    func testSuggestedArchiveName() {
        let name = AppDataStateArchive.suggestedName(bundleIdentifier: "com.example.app", date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(name.hasPrefix("com.example.app 19"), name)
        XCTAssertTrue(name.hasSuffix(".zip"))
        XCTAssertFalse(name.contains(":"), "a colon is not a good file name on the Mac")
    }

    // MARK: Sample data

    func testContactsAreDeterministicAndClearlyFake() throws {
        let first = try SimulatorSampleData.contactsVCard(count: 12)
        XCTAssertEqual(first, try SimulatorSampleData.contactsVCard(count: 12))
        XCTAssertEqual(first.components(separatedBy: "BEGIN:VCARD").count - 1, 12)
        XCTAssertEqual(first.components(separatedBy: "END:VCARD").count - 1, 12)
        XCTAssertTrue(first.contains("FN:Sample Contact 01\r\n"))
        XCTAssertTrue(first.contains("FN:Sample Contact 12\r\n"))
        XCTAssertTrue(first.contains("EMAIL;TYPE=INTERNET:sample.contact07@example.com"))
        XCTAssertTrue(first.contains("TEL;TYPE=CELL:+1 555 0105"))
        XCTAssertEqual(SimulatorSampleData.contactName(7, of: 120), "Sample Contact 007")
        XCTAssertThrowsError(try SimulatorSampleData.contactsVCard(count: 0))
        XCTAssertThrowsError(try SimulatorSampleData.contactsVCard(count: SimulatorSampleData.maximumContacts + 1))
    }

    func testPhotosAreDeterministicNumberedPNGs() throws {
        let one = try SimulatorSampleData.photoPNG(number: 3, of: 6, width: 120, height: 90)
        XCTAssertEqual(one, try SimulatorSampleData.photoPNG(number: 3, of: 6, width: 120, height: 90))
        XCTAssertEqual(one.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        XCTAssertNotEqual(one, try SimulatorSampleData.photoPNG(number: 4, of: 6, width: 120, height: 90))

        let folder = try makeFolder("photos")
        let files = try SimulatorSampleData.writePhotos(count: 3, to: folder)
        XCTAssertEqual(files.map(\.lastPathComponent), ["Sample Photo 01.png", "Sample Photo 02.png", "Sample Photo 03.png"])
        XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertThrowsError(try SimulatorSampleData.writePhotos(count: 0, to: folder))
        let contacts = try SimulatorSampleData.writeContacts(count: 5, to: folder)
        XCTAssertEqual(contacts.lastPathComponent, "Sample Contacts 5.vcf")
    }

    func testPhotoColoursDifferBetweenNeighbours() {
        let colors = (1...8).map { SimulatorSampleData.photoColor($0) }
        for pair in zip(colors, colors.dropFirst()) {
            XCTAssertFalse(pair.0 == pair.1)
        }
    }
}
