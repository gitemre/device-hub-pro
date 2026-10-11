import XCTest
@testable import DeviceHubProKit

/// The checks made before an AVD starts.
///
/// `Fixtures/emulator-start/old-cmdline-tools-api37/` is a capture of
/// 2026-10-11 (a macOS 26.6 virtual machine): `avdmanager create avd -n
/// Pixel_8_Pro_old -k "system-images;android-37.0;google_apis;arm64-v8a" -d
/// pixel_8_pro` run with cmdline-tools 13.0 on an SDK where sdkmanager (23.0)
/// had installed that image: the AVD's `<name>.ini` and `config.ini` as
/// avdmanager wrote them, and the image's own `source.properties`. The
/// image's other files (gigabytes) are left out; the tests that need an
/// installed image write empty or one-byte stand-ins, which only the files'
/// presence is read from.
final class EmulatorPreflightTests: XCTestCase {
    private var root: URL!
    private var avdHome: URL { root.appendingPathComponent("avd", isDirectory: true) }
    private var sdk: URL { root.appendingPathComponent("sdk", isDirectory: true) }
    private var image: URL { sdk.appendingPathComponent("system-images/android-37.0/google_apis/arm64-v8a", isDirectory: true) }
    private let avd = "Pixel_8_Pro_old"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EmulatorPreflightTests-\(UUID().uuidString)")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/emulator-start/old-cmdline-tools-api37", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    private var pointer: URL { avdHome.appendingPathComponent("\(avd).ini") }
    private var config: URL { avdHome.appendingPathComponent("\(avd).avd/config.ini") }

    /// An old avdmanager wrote `target=android-0` for Android 17's image
    /// (API level 37.0) and no target in `config.ini`: both get the image's
    /// level, and every other byte stays.
    func testAnOldAvdmanagersTargetGetsTheImagesLevel() throws {
        let pointerBefore = try read(pointer)
        let configBefore = try read(config)
        XCTAssertTrue(pointerBefore.contains("target=android-0\n"))
        XCTAssertNil(AvdConfig.values(avdName: avd, avdHome: avdHome)["target"])

        let written = try EmulatorPreflight.repairTarget(avdName: avd, avdHome: avdHome, sdkRoots: [sdk])
        XCTAssertEqual(written, "android-37.0")
        XCTAssertEqual(try read(pointer), pointerBefore.replacingOccurrences(of: "target=android-0\n", with: "target=android-37.0\n"))
        XCTAssertEqual(try read(config), configBefore + "target=android-37.0\n")
        XCTAssertEqual(AvdConfig.target(avdName: avd, avdHome: avdHome), "android-37.0")

        // Done once: a second pass finds nothing to do.
        XCTAssertNil(try EmulatorPreflight.repairTarget(avdName: avd, avdHome: avdHome, sdkRoots: [sdk]))
    }

    /// A target an avdmanager could read is never touched, and without the
    /// image's own level nothing is guessed.
    func testOnlyABrokenTargetWithAKnownLevelIsRewritten() throws {
        try read(pointer).replacingOccurrences(of: "target=android-0", with: "target=android-36")
            .write(to: pointer, atomically: true, encoding: .utf8)
        let kept = try read(pointer)
        XCTAssertNil(try EmulatorPreflight.repairTarget(avdName: avd, avdHome: avdHome, sdkRoots: [sdk]))
        XCTAssertEqual(try read(pointer), kept)

        try kept.replacingOccurrences(of: "target=android-36", with: "target=android-0")
            .write(to: pointer, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: image.appendingPathComponent("source.properties"))
        XCTAssertNil(try EmulatorPreflight.repairTarget(avdName: avd, avdHome: avdHome, sdkRoots: [sdk]))
        XCTAssertTrue(try read(pointer).contains("target=android-0"))
        XCTAssertNil(try EmulatorPreflight.repairTarget(avdName: "NoSuchAvd", avdHome: avdHome, sdkRoots: [sdk]))
    }

    /// The image is found under whichever SDK root has it.
    func testTheImageIsLookedForUnderEveryRoot() {
        let elsewhere = root.appendingPathComponent("other-sdk", isDirectory: true)
        XCTAssertEqual(
            EmulatorPreflight.systemImageDirectory(avdName: avd, avdHome: avdHome, sdkRoots: [elsewhere, sdk])?.standardizedFileURL,
            image.standardizedFileURL
        )
        XCTAssertEqual(EmulatorPreflight.apiLevel(ofImage: image), "37.0")
    }

    private func installImageFiles(_ names: [String]) throws {
        for name in names {
            try Data("x".utf8).write(to: image.appendingPathComponent(name))
        }
    }

    /// A start is refused, with the reason, when the image is not on the Mac
    /// or a download did not finish; a whole image passes.
    func testAMissingOrIncompleteImageIsCaughtBeforeTheStart() throws {
        // Only `source.properties`: the download stopped.
        XCTAssertEqual(
            EmulatorPreflight.problem(avdName: avd, avdHome: avdHome, sdkRoots: [sdk], hostIsAppleSilicon: true),
            EmulatorStartFailure.missingSystemImage
        )
        try installImageFiles(["system.img", "kernel-ranchu"])
        XCTAssertEqual(
            EmulatorPreflight.problem(avdName: avd, avdHome: avdHome, sdkRoots: [sdk], hostIsAppleSilicon: true),
            EmulatorStartFailure.missingSystemImage,
            "no ramdisk.img"
        )
        try installImageFiles(["ramdisk.img"])
        XCTAssertNil(EmulatorPreflight.problem(avdName: avd, avdHome: avdHome, sdkRoots: [sdk], hostIsAppleSilicon: true))

        // An empty system.img is a download cut short too.
        try Data().write(to: image.appendingPathComponent("system.img"))
        XCTAssertEqual(
            EmulatorPreflight.problem(avdName: avd, avdHome: avdHome, sdkRoots: [sdk], hostIsAppleSilicon: true),
            EmulatorStartFailure.missingSystemImage
        )

        try FileManager.default.removeItem(at: image)
        XCTAssertEqual(
            EmulatorPreflight.problem(avdName: avd, avdHome: avdHome, sdkRoots: [sdk], hostIsAppleSilicon: true),
            EmulatorStartFailure.missingSystemImage
        )
        // An AVD whose config cannot be read is left to the emulator.
        XCTAssertNil(EmulatorPreflight.problem(avdName: "NoSuchAvd", avdHome: avdHome, sdkRoots: [sdk]))
    }

    /// An Intel image cannot run on Apple silicon; on an Intel Mac it can.
    func testAnIntelImageIsRefusedOnAppleSilicon() throws {
        try installImageFiles(["system.img", "kernel-ranchu", "ramdisk.img"])
        try AvdConfig.setValue("x86_64", forKey: "abi.type", avdName: avd, avdHome: avdHome)
        let refusal = try XCTUnwrap(
            EmulatorPreflight.problem(avdName: avd, avdHome: avdHome, sdkRoots: [sdk], hostIsAppleSilicon: true)
        )
        XCTAssertTrue(refusal.contains("x86_64"))
        XCTAssertTrue(refusal.contains("ARM 64"))
        XCTAssertNil(EmulatorPreflight.problem(avdName: avd, avdHome: avdHome, sdkRoots: [sdk], hostIsAppleSilicon: false))
    }

    /// The emulator's own SDK comes first, found through a symlink too.
    func testTheEmulatorsOwnSdkComesFirst() throws {
        let binary = sdk.appendingPathComponent("emulator/emulator")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: binary)
        let link = root.appendingPathComponent("bin/emulator")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        let roots = EmulatorPreflight.sdkRoots(emulatorURL: link, environment: [:])
        XCTAssertEqual(roots.first?.resolvingSymlinksInPath().path, sdk.resolvingSymlinksInPath().path)
    }
}
