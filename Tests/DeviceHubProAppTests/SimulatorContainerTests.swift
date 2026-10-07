import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// App Container ▸ Download… and Replace… (Device Hub's, measured on Device
/// Hub 27.0: Download saves the data container as a folder named by the bundle
/// identifier; Replace takes a folder or an `.xcappdata` bundle), the sorting of
/// the list and Device Hub's Location places.
final class SimulatorContainerTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceHubPro-container-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testDownloadCopiesTheContainerUnderTheBundleIdentifier() throws {
        let container = try folder()
        try write("data", "Documents/readings.json", in: container)
        try write("meta", ".com.apple.mobile_container_manager.metadata.plist", in: container)
        let destination = try folder()

        let first = try SimulatorAppsController.copyContainer(container, to: destination, named: "com.devicehubpro.verifier")
        XCTAssertEqual(first.lastPathComponent, "com.devicehubpro.verifier")
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("Documents/readings.json"), encoding: .utf8), "data")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist").path))

        // A name that is taken gets a number.
        let second = try SimulatorAppsController.copyContainer(container, to: destination, named: "com.devicehubpro.verifier")
        XCTAssertEqual(second.lastPathComponent, "com.devicehubpro.verifier 2")
    }

    func testReplaceEmptiesTheContainerAndKeepsItsMetadata() throws {
        let container = try folder()
        try write("old", "Documents/old.txt", in: container)
        try write("meta", ".com.apple.mobile_container_manager.metadata.plist", in: container)

        let source = try folder()
        try write("new", "Documents/new.txt", in: source)
        try SimulatorAppsController.replaceContainerContents(container, with: source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.appendingPathComponent("Documents/old.txt").path))
        XCTAssertEqual(try String(contentsOf: container.appendingPathComponent("Documents/new.txt"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: container.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist"), encoding: .utf8), "meta")
    }

    func testReplaceTakesAnXcappdataBundlesAppData() throws {
        let container = try folder()
        try write("old", "tmp/old", in: container)
        let bundle = try folder().appendingPathComponent("Backup.xcappdata", isDirectory: true)
        try write("kept", "AppData/Documents/kept.txt", in: bundle)
        try write("props", "AppDataProperties.plist", in: bundle)

        try SimulatorAppsController.replaceContainerContents(container, with: bundle)
        XCTAssertEqual(try String(contentsOf: container.appendingPathComponent("Documents/kept.txt"), encoding: .utf8), "kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.appendingPathComponent("AppDataProperties.plist").path))
    }

    func testTheListIsInDeviceHubsLiteralOrder() throws {
        func app(_ id: String, _ name: String) throws -> SimulatorApp {
            try SimctlParsing.app(fromAppInfo: "{ CFBundleIdentifier = \"\(id)\"; CFBundleDisplayName = \"\(name)\"; }")
        }
        let apps = try [app("b", "ActivityMessagesApp"), app("a", "AQA Verifier"), app("c", "Astronomy")]
        let sorted = apps.sorted { SimulatorAppsController.isOrdered($0, before: $1) }
        XCTAssertEqual(sorted.map(\.title), ["AQA Verifier", "ActivityMessagesApp", "Astronomy"])
    }

    func testDeviceHubsLocationMenuHasFourteenPlaces() {
        XCTAssertEqual(AppleLocationPlaces.all.count, 14)
        XCTAssertEqual(AppleLocationPlaces.all.first?.name, "Berlin, Germany")
        XCTAssertEqual(AppleLocationPlaces.all.last?.name, "Warsaw, Poland")
        XCTAssertEqual(
            AppleLocationPlaces.all[0].choice,
            .coordinate(name: "Berlin, Germany", latitude: 52.52, longitude: 13.405)
        )
    }
}
