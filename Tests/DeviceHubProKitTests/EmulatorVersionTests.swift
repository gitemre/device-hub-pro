import XCTest
@testable import DeviceHubProKit

final class EmulatorVersionTests: XCTestCase {
    func testSupportsMMAPForFixedVersions() {
        XCTAssertTrue(EmulatorVersion.supportsMMAP("37.2.8.0 (37.2.8-16259959)"))
        XCTAssertTrue(EmulatorVersion.supportsMMAP("37.2.3"))
        XCTAssertTrue(EmulatorVersion.supportsMMAP("37.3.0"))
        XCTAssertTrue(EmulatorVersion.supportsMMAP("38.0.0"))
    }

    func testVersionOrdering() {
        XCTAssertTrue(EmulatorVersion.isOlder("36.6.11", than: "37.2.3"))
        XCTAssertTrue(EmulatorVersion.isOlder("37.2.3", than: "37.2.12"))
        XCTAssertFalse(EmulatorVersion.isOlder("37.2.12", than: "37.2.3"))
        XCTAssertFalse(EmulatorVersion.isOlder("37.2.3", than: "37.2.3"))
        XCTAssertFalse(EmulatorVersion.isOlder("unknown", than: "37.2.3"))
        XCTAssertTrue(EmulatorVersion.isOlder("36.6.11.0 (36.6.11-15507667)", than: "37.2.12"))
    }

    func testInstalledVersionIsReadFromThePackageManifest() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmulatorVersionTests-\(UUID().uuidString)/emulator", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let binary = dir.appendingPathComponent("emulator")

        XCTAssertNil(EmulatorVersion.installedVersion(emulatorBinary: binary))

        // The revision element of an SDK emulator package.xml (measured: 36.6.11).
        try "<localPackage path=\"emulator\"><revision><major>36</major><minor>6</minor><micro>11</micro></revision></localPackage>"
            .write(to: dir.appendingPathComponent("package.xml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(EmulatorVersion.installedVersion(emulatorBinary: binary), "36.6.11")
    }

    func testDoesNotSupportMMAPForAffectedVersions() {
        XCTAssertFalse(EmulatorVersion.supportsMMAP("36.6.11.0 (36.6.11-15507667)"))
        XCTAssertFalse(EmulatorVersion.supportsMMAP("37.2.1"))
        XCTAssertFalse(EmulatorVersion.supportsMMAP("37.1.11"))
        XCTAssertFalse(EmulatorVersion.supportsMMAP(""))
        XCTAssertFalse(EmulatorVersion.supportsMMAP("unknown"))
    }
}
