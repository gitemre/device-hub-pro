import XCTest
@testable import DeviceHubProKit
@testable import DeviceHubProApp

@MainActor
final class SavedLibrariesTests: XCTestCase {
    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedLibrariesTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testEverythingSurvivesARelaunch() throws {
        let directory = folder()
        let libraries = SavedLibraries(directory: directory)
        let push = libraries.savePush(name: "Alert", bundleIdentifier: "com.example", payload: "{\"aps\":{}}")
        libraries.duplicatePush(id: push.id)
        libraries.renamePush(id: push.id, to: "Renamed")
        libraries.saveLink(name: "Home", url: "myapp://home", group: " myapp ")
        libraries.recordSentPush(bundleIdentifier: "com.example", payload: "{\"aps\":{\"badge\":1}}")
        let options = SimulatorLaunchOptions(arguments: ["-x"], environment: [.init(key: "K", value: "v")], waitForDebugger: true)
        libraries.remember(options, for: "com.example")

        let again = SavedLibraries(directory: directory)
        XCTAssertEqual(again.pushes.items.map(\.name), ["Renamed", "Alert copy"])
        XCTAssertEqual(again.links.items.map(\.group), ["myapp"])
        XCTAssertEqual(again.lastPush, SentPush(bundleIdentifier: "com.example", payload: "{\"aps\":{\"badge\":1}}"))
        XCTAssertEqual(again.options(for: "com.example"), options)
        XCTAssertEqual(again.options(for: "other"), SimulatorLaunchOptions())

        let id = try XCTUnwrap(again.pushes.items.first?.id)
        again.deletePush(id: id)
        XCTAssertEqual(SavedLibraries(directory: directory).pushes.items.count, 1)
    }

    func testWithoutADirectoryNothingIsWritten() {
        let libraries = SavedLibraries(directory: nil)
        libraries.saveLink(name: "A", url: "x://a", group: nil)
        XCTAssertEqual(libraries.links.items.count, 1)
        XCTAssertEqual(SavedLibraries(directory: nil).links.items.count, 0)
    }
}
