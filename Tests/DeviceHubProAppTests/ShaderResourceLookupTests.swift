import Foundation
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// Where the mirror shader is read from: the app bundle packaged in
/// `Contents/Resources` first, `Bundle.module` only without one
/// (`ResourceBundleLookup`, `Scripts/package-app.sh`).
final class ShaderResourceLookupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShaderResourceLookupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testThePackagedShaderWinsOverTheModuleBundle() throws {
        let resources = root.appendingPathComponent("Device Hub Pro.app/Contents/Resources", isDirectory: true)
        let bundleResources = resources
            .appendingPathComponent("\(ResourceBundleLookup.appBundleName).bundle/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleResources, withIntermediateDirectories: true)
        try Data("// packaged".utf8).write(to: bundleResources.appendingPathComponent("Shaders.metal"))
        var moduleCalls = 0

        let url = MirrorRenderPipeline.bundledShaderURL(resourceDirectory: resources) {
            moduleCalls += 1
            return Bundle(for: Self.self)
        }

        XCTAssertEqual(try url.map { try String(contentsOf: $0, encoding: .utf8) }, "// packaged")
        XCTAssertEqual(moduleCalls, 0)
    }

    func testWithoutAPackagedBundleTheModuleBundleIsUsed() throws {
        let module = Bundle(for: Self.self)
        var moduleCalls = 0

        let url = MirrorRenderPipeline.bundledShaderURL(resourceDirectory: root) {
            moduleCalls += 1
            return module
        }

        XCTAssertEqual(moduleCalls, 1)
        XCTAssertEqual(url, module.url(forResource: "Shaders", withExtension: "metal"))
    }

    /// The default accessor (`Bundle.module`) finds the real shader when no
    /// packaged bundle is there, as in `swift test` and `swift run`.
    func testWithoutAPackagedBundleTheRealShaderIsFound() throws {
        let url = MirrorRenderPipeline.bundledShaderURL(resourceDirectory: root)

        XCTAssertEqual(url?.lastPathComponent, "Shaders.metal")
    }

    /// The bundle name the lookup expects is the one SwiftPM builds for the
    /// app target: a rename must update `ResourceBundleLookup.appBundleName`.
    func testTheAppBundleNameMatchesTheBuiltBundle() throws {
        let url = try XCTUnwrap(MirrorRenderPipeline.bundledShaderURL())

        XCTAssertTrue(
            url.pathComponents.contains("\(ResourceBundleLookup.appBundleName).bundle"),
            url.path
        )
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("mirror_fragment"))
    }
}
