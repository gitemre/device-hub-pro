import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The app data inspector and the sample data seeding against a real
/// simulator, behind `DHP_IOS_LIVE=1`:
///
///     DHP_IOS_LIVE=1 swift test --filter SimulatorAppDataLiveTests
///
/// It creates its own iPhone in a private device set (`LiveTestSimulators`),
/// boots it and deletes it afterwards with its set and log folders. It
/// seeds 10 sample contacts and 3 sample photos through
/// `SimulatorAppsController` and checks them on the device: the contacts in
/// the Address Book database, read through `SQLiteBrowser` (a copy), the
/// photos as files in the device's `Media/DCIM`. It then launches Safari,
/// checks the running-app reading (`SimctlClient.isAppRunning`), lists its
/// data container with `SimulatorAppDataController`, and saves and restores
/// the container's state around a change.
@MainActor
final class SimulatorAppDataLiveTests: XCTestCase {
    private static let bundle = "com.apple.mobilesafari"

    func testInspectorAndSeedingOnARealSimulator() async throws {
        let toolchain = try await LiveTestSimulators.toolchain()
        let simulators = try LiveTestSimulators.Session(toolchain: toolchain)
        do {
            try await exercise(simulators)
        } catch {
            let leftovers = await simulators.tearDown()
            XCTAssertEqual(leftovers, [])
            throw error
        }
        let leftovers = await simulators.tearDown()
        XCTAssertEqual(leftovers, [])
    }

    private func poll(_ seconds: Int, _ condition: () async throws -> Bool) async rethrows -> Bool {
        for _ in 0..<seconds {
            if try await condition() { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return try await condition()
    }

    // swiftlint:disable:next function_body_length
    private func exercise(_ simulators: LiveTestSimulators.Session) async throws {
        let device = try await simulators.createDevice(name: "DeviceHubPro-AppDataLive")
        let udid = device.udid
        let simctl = simulators.simctl
        print("APPDATA-LIVE created \(udid) in \(simulators.setDirectory.path)")
        try await simctl.bootStatus(udid: udid, bootIfNeeded: true)
        try await Task.sleep(for: .seconds(10))

        let inventory = SimulatorInventory(
            apple: AppleTooling(
                probe: { [toolchain = simulators.toolchain] in toolchain },
                deviceSet: simulators.setDirectory,
                devicesDirectory: simulators.setDirectory,
                logsDirectory: LiveTestSimulators.logsDirectory
            ),
            preferences: AppPreferences(defaults: .scratch())
        )
        await inventory.refresh()
        let status = StatusCenter()
        let apps = SimulatorAppsController(simulators: inventory, status: status, defaults: .scratch())
        apps.revealInFinder = { _ in }
        defer {
            apps.clear()
            inventory.stop()
        }
        let entry = try XCTUnwrap(inventory.entry(udid: udid))
        let dataDirectory = URL(fileURLWithPath: try XCTUnwrap(entry.dataPath), isDirectory: true)

        // Seeding, run after the inspector part below (the first Photos import
        // can take minutes on a loaded Mac and leaves the simulator slow).
        func seedAndVerify() async throws {
        await apps.addSampleContacts(count: 10, udid: udid)
        XCTAssertNil(status.errorMessage, "contacts")
        await apps.addSamplePhotos(count: 3, udid: udid)
        print("APPDATA-LIVE photos error tail: \(String((status.errorMessage ?? "none").suffix(400)))"); status.errorMessage = nil

        let dcim = dataDirectory.appendingPathComponent("Media/DCIM", isDirectory: true)
        let photosLanded = await poll(60) {
            let files = FileManager.default.enumerator(at: dcim, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            return files.filter { ["png", "jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) }.count >= 3
        }
        XCTAssertTrue(photosLanded, "3 pictures in Media/DCIM")

        let addressBook = dataDirectory.appendingPathComponent("Library/AddressBook/AddressBook.sqlitedb")
        let browser = SQLiteBrowser(source: addressBook)
        defer { browser.close() }
        let contactCount = await poll(60) {
            guard (try? browser.reload()) != nil,
                  let rows = try? await browser.rows(of: "ABPerson") else { return false }
            return rows.totalRows >= 10
        }
        XCTAssertTrue(contactCount, "10 contacts in the Address Book database")
        let people = try await browser.rows(of: "ABPerson")
        let firstIndex = try XCTUnwrap(people.columns.firstIndex(of: "First"))
        let lastIndex = try XCTUnwrap(people.columns.firstIndex(of: "Last"))
        let names = people.rows.map { "\($0[firstIndex]) \($0[lastIndex])" }
        XCTAssertTrue(names.contains("Sample Contact 01"), "\(names)")
        XCTAssertTrue(names.contains("Sample Contact 10"), "\(names)")
        }

        // Running-app reading and the container listing.
        try await simctl.checked(["launch", udid, Self.bundle], timeout: .seconds(180))
        try await Task.sleep(for: .seconds(4))
        let running = try await simctl.isAppRunning(udid: udid, bundleIdentifier: Self.bundle)
        XCTAssertTrue(running, "Safari runs after launch")

        let app = try await simctl.appInfo(udid: udid, bundleIdentifier: Self.bundle)
        let inspector = try XCTUnwrap(apps.makeDataInspector(for: app, udid: udid))
        defer { inspector.close() }
        await inspector.start()
        XCTAssertEqual(inspector.roots.first?.title, "Data Container")
        XCTAssertFalse(inspector.entries.isEmpty, "the data container lists its folders")
        print("APPDATA-LIVE container: \(inspector.roots.map(\.url.path))"); print("APPDATA-LIVE container top: \(inspector.entries.map(\.name))")
        print("APPDATA-LIVE databases: \(inspector.databases.map(\.lastPathComponent))")
        print("APPDATA-LIVE preferences: \(inspector.preferenceEntries.count) keys, problem: \(inspector.preferencesProblem ?? "none")")
        if let database = inspector.databases.first {
            await inspector.openDatabase(database)
            XCTAssertNil(inspector.databaseProblem, "a database copy opens read-only")
        }

        // Save, change, restore (the app is stopped by both).
        let container = try XCTUnwrap(inspector.roots.first?.url)
        let marker = container.appendingPathComponent("Documents/devicehubpro-state-marker.txt")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("before".utf8).write(to: marker)
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("devicehubpro-live-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        await apps.saveAppState(app, udid: udid, to: archive)
        XCTAssertNil(status.errorMessage, "save")
        let stopped = try await simctl.isAppRunning(udid: udid, bundleIdentifier: Self.bundle)
        XCTAssertFalse(stopped, "Save App State stops the app")
        try Data("after".utf8).write(to: marker)
        await apps.restoreAppState(app, udid: udid, from: archive)
        XCTAssertNil(status.errorMessage, "restore")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "before")

        try await seedAndVerify()
    }
}
