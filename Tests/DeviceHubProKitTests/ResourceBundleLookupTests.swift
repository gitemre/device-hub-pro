import Foundation
import XCTest
@testable import DeviceHubProKit

/// The packaged-app resource lookup: `Contents/Resources/<bundle>.bundle`
/// first, `Bundle.module` only without one (`Scripts/package-app.sh`,
/// docs/distribution.md).
final class ResourceBundleLookupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResourceBundleLookupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A `Contents/Resources` directory holding `<bundleName>.bundle`, laid
    /// out like the bundles SwiftPM builds on macOS.
    private func makeResourceDirectory(bundleName: String, files: [String: String]) throws -> URL {
        let resources = root.appendingPathComponent("Device Hub Pro.app/Contents/Resources", isDirectory: true)
        let bundleContents = resources.appendingPathComponent("\(bundleName).bundle/Contents", isDirectory: true)
        let bundleResources = bundleContents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleResources, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "io.github.gitemre.devicehubpro.tests.\(bundleName)",
            "CFBundlePackageType": "BNDL",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundleContents.appendingPathComponent("Info.plist"))
        for (name, contents) in files {
            try Data(contents.utf8).write(to: bundleResources.appendingPathComponent(name))
        }
        return resources
    }

    /// A stand-in for `Bundle.module` that records whether it was asked.
    private final class ModuleProbe {
        private(set) var calls = 0
        let bundle: Bundle

        init(bundle: Bundle) {
            self.bundle = bundle
        }

        func callAsFunction() -> Bundle {
            calls += 1
            return bundle
        }
    }

    func testThePackagedBundleWinsAndTheModuleAccessorIsNotAsked() throws {
        let resources = try makeResourceDirectory(
            bundleName: ResourceBundleLookup.kitBundleName,
            files: ["scrcpy-server": "packaged"]
        )
        let module = ModuleProbe(bundle: Bundle(for: Self.self))

        let url = ResourceBundleLookup.url(
            forResource: "scrcpy-server",
            withExtension: nil,
            bundleName: ResourceBundleLookup.kitBundleName,
            resourceDirectory: resources,
            module: module.callAsFunction
        )

        XCTAssertEqual(try url.map { try String(contentsOf: $0, encoding: .utf8) }, "packaged")
        XCTAssertEqual(url?.resolvingSymlinksInPath().path.hasPrefix(resources.resolvingSymlinksInPath().path), true)
        XCTAssertEqual(module.calls, 0, "Bundle.module can trap without a build directory")
    }

    func testWithoutAPackagedBundleTheModuleAccessorAnswers() throws {
        let module = ModuleProbe(bundle: Bundle(for: Self.self))
        let empty = root.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        let url = ResourceBundleLookup.url(
            forResource: "Info",
            withExtension: "plist",
            bundleName: ResourceBundleLookup.kitBundleName,
            resourceDirectory: empty,
            module: module.callAsFunction
        )

        XCTAssertEqual(module.calls, 1)
        XCTAssertEqual(url, module.bundle.url(forResource: "Info", withExtension: "plist"))
    }

    func testANilResourceDirectoryFallsBackToTheModuleAccessor() {
        let module = ModuleProbe(bundle: Bundle(for: Self.self))

        _ = ResourceBundleLookup.url(
            forResource: "scrcpy-server",
            withExtension: nil,
            bundleName: ResourceBundleLookup.kitBundleName,
            resourceDirectory: nil,
            module: module.callAsFunction
        )

        XCTAssertEqual(module.calls, 1)
    }

    /// A packaged bundle is authoritative: a resource missing from it is
    /// missing, not looked up through an accessor that may trap.
    func testAResourceMissingFromThePackagedBundleIsNotLookedUpElsewhere() throws {
        let resources = try makeResourceDirectory(
            bundleName: ResourceBundleLookup.kitBundleName,
            files: ["README.md": "only the readme"]
        )
        let module = ModuleProbe(bundle: Bundle(for: Self.self))

        let url = ResourceBundleLookup.url(
            forResource: "scrcpy-server",
            withExtension: nil,
            bundleName: ResourceBundleLookup.kitBundleName,
            resourceDirectory: resources,
            module: module.callAsFunction
        )

        XCTAssertNil(url)
        XCTAssertEqual(module.calls, 0)
    }

    func testAFileNamedLikeTheBundleIsNotABundle() throws {
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("not a bundle".utf8)
            .write(to: resources.appendingPathComponent("\(ResourceBundleLookup.kitBundleName).bundle"))

        XCTAssertNil(ResourceBundleLookup.packagedBundle(named: ResourceBundleLookup.kitBundleName, in: resources))
    }

    func testAnotherTargetsBundleIsNotPickedUp() throws {
        let resources = try makeResourceDirectory(
            bundleName: ResourceBundleLookup.appBundleName,
            files: ["scrcpy-server": "wrong bundle"]
        )

        XCTAssertNil(ResourceBundleLookup.packagedBundle(named: ResourceBundleLookup.kitBundleName, in: resources))
    }

    // MARK: - scrcpy server

    func testTheScrcpyServerIsReadFromThePackagedKitBundle() throws {
        let resources = try makeResourceDirectory(
            bundleName: ResourceBundleLookup.kitBundleName,
            files: ["scrcpy-server": "packaged server"]
        )
        let module = ModuleProbe(bundle: Bundle(for: Self.self))

        let url = try ScrcpyServer.bundledServerURL(resourceDirectory: resources, module: module.callAsFunction)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "packaged server")
        XCTAssertEqual(module.calls, 0)
    }

    func testAPackagedKitBundleWithoutTheServerReportsTheMissingAsset() throws {
        let resources = try makeResourceDirectory(
            bundleName: ResourceBundleLookup.kitBundleName,
            files: [:]
        )

        XCTAssertThrowsError(
            try ScrcpyServer.bundledServerURL(resourceDirectory: resources, module: { Bundle(for: Self.self) })
        ) { error in
            guard case ScrcpyServerError.assetMissing(let name) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(name, "scrcpy-server")
        }
    }

    /// The bundle name the lookup expects is the one SwiftPM builds
    /// (`<Package>_<Target>.bundle`): renaming the package or the target
    /// must update `ResourceBundleLookup`, or a packaged app misses it.
    func testTheKitBundleNameMatchesTheBuiltBundle() throws {
        let url = try ScrcpyServer.bundledServerURL()

        XCTAssertTrue(
            url.pathComponents.contains("\(ResourceBundleLookup.kitBundleName).bundle"),
            url.path
        )
    }
}
