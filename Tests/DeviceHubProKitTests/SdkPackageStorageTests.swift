import XCTest
@testable import DeviceHubProKit

final class SdkPackageStorageTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SdkPackageStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPackagePathsMapOntoTheSdkTree() {
        let sdk = URL(fileURLWithPath: "/sdk", isDirectory: true)

        XCTAssertEqual(
            SdkPackageStorage.directory(forPackage: "system-images;android-35;google_apis;arm64-v8a", sdkRoot: sdk)?.path,
            "/sdk/system-images/android-35/google_apis/arm64-v8a"
        )
        XCTAssertEqual(
            SdkPackageStorage.directory(forPackage: "platforms;android-35", sdkRoot: sdk)?.path,
            "/sdk/platforms/android-35"
        )
        XCTAssertNil(SdkPackageStorage.directory(forPackage: "system-images;..;..", sdkRoot: sdk))
        XCTAssertNil(SdkPackageStorage.directory(forPackage: "--licenses", sdkRoot: sdk))
        XCTAssertNil(SdkPackageStorage.directory(forPackage: "a/b", sdkRoot: sdk))
    }

    /// A directory left by a cancelled download has no `package.xml`: it is
    /// neither installed nor reported with a size.
    func testOnlyAPackageWithItsManifestIsInstalled() throws {
        let package = "system-images;android-35;google_apis;arm64-v8a"
        let directory = try XCTUnwrap(SdkPackageStorage.directory(forPackage: package, sdkRoot: root))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10_000).write(to: directory.appendingPathComponent("system.img"))

        XCTAssertFalse(SdkPackageStorage.isInstalled(package: package, sdkRoot: root))
        XCTAssertNil(SdkPackageStorage.installedSize(ofPackage: package, sdkRoot: root))

        try Data("<package/>".utf8).write(to: directory.appendingPathComponent("package.xml"))

        XCTAssertTrue(SdkPackageStorage.isInstalled(package: package, sdkRoot: root))
    }

    func testInstalledSizeSumsTheFilesOnDisk() async throws {
        let package = "system-images;android-35;google_apis;arm64-v8a"
        let directory = try XCTUnwrap(SdkPackageStorage.directory(forPackage: package, sdkRoot: root))
        let nested = directory.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("<package/>".utf8).write(to: directory.appendingPathComponent("package.xml"))
        try Data(repeating: 1, count: 1_000_000).write(to: directory.appendingPathComponent("system.img"))
        try Data(repeating: 2, count: 300_000).write(to: nested.appendingPathComponent("userdata.img"))

        let size = try XCTUnwrap(SdkPackageStorage.installedSize(ofPackage: package, sdkRoot: root))

        // Allocated sizes round each file up to whole blocks.
        XCTAssertGreaterThanOrEqual(size, 1_300_000)
        XCTAssertLessThan(size, 1_400_000)

        let sizes = await SdkPackageStorage.installedSizes(
            ofPackages: [package, "system-images;android-34;google_apis;arm64-v8a"],
            sdkRoot: root
        )
        XCTAssertEqual(sizes, [package: size])
    }

    /// Uninstalling an image breaks the AVDs built on it; the confirmation
    /// names them.
    func testAvdsUsingASystemImageAreListed() throws {
        let avdHome = root.appendingPathComponent("avd", isDirectory: true)
        for (name, sysdir) in [
            ("Pixel_9", "system-images/android-35/google_apis/arm64-v8a/"),
            ("Pixel_8", "system-images/android-35/google_apis/arm64-v8a"),
            ("Tablet", "system-images/android-34/google_apis/arm64-v8a/"),
        ] {
            let content = avdHome.appendingPathComponent("\(name).avd", isDirectory: true)
            try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
            try "image.sysdir.1=\(sysdir)\n".write(
                to: content.appendingPathComponent("config.ini"),
                atomically: true,
                encoding: .utf8
            )
            try "path=\(content.path)\n".write(
                to: avdHome.appendingPathComponent("\(name).ini"),
                atomically: true,
                encoding: .utf8
            )
        }

        XCTAssertEqual(
            AvdConfig.avdNames(
                usingSystemImage: "system-images;android-35;google_apis;arm64-v8a",
                avdHome: avdHome
            ),
            ["Pixel_8", "Pixel_9"]
        )
        XCTAssertEqual(
            AvdConfig.avdNames(usingSystemImage: "system-images;android-36;google_apis;arm64-v8a", avdHome: avdHome),
            []
        )
    }
}
