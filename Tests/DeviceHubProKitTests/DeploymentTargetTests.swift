import Foundation
import XCTest

/// The minimum macOS is written three times, and all three must agree:
/// - `platforms` in Package.swift. Every module is compiled for it, so the
///   code treats that macOS's APIs as always there.
/// - The first number of the app's `-platform_version` linker flag. ld writes
///   it into LC_BUILD_VERSION (minos), which dyld checks, and it wins over
///   `platforms` at link time: with `platforms` raised alone, ld only warns
///   ("object file ... was built for newer 'macOS' version (26.4) than being
///   linked (26.0)").
/// - `LSMinimumSystemVersion` in packaging/Info.plist, which Finder checks
///   before it starts the app.
///
/// `Scripts/package-app.sh` checks the packaged executable the same way.
final class DeploymentTargetTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPlatformsTheLinkerFlagAndInfoPlistNameOneMinimum() throws {
        // All three are read from the files: a test bundle's own minos is no
        // witness, because the native build system links every test target
        // into one bundle together with the app module, which carries the
        // -platform_version flag, so its minos is the flag's.
        let platforms = try platformsMinimum()
        let flag = try linkerFlagMinimum()
        let infoPlist = try infoPlistMinimum()

        XCTAssertEqual(
            Self.normalized(flag), Self.normalized(platforms),
            "Package.swift links the app with -platform_version macos \(flag), but its platforms says macOS \(platforms)"
        )
        XCTAssertEqual(
            Self.normalized(infoPlist), Self.normalized(platforms),
            "packaging/Info.plist declares LSMinimumSystemVersion \(infoPlist), but Package.swift's platforms says macOS \(platforms)"
        )
    }

    /// The standing docs quote the flag as Package.swift spells it: AGENTS.md
    /// tells agents not to remove it, and CONTRIBUTING.md explains it.
    func testTheStandingDocsQuoteTheLinkerFlagAsPackageSwiftSpellsIt() throws {
        let arguments = try linkerFlagArguments()
        let flag = "-platform_version macos " + arguments.dropFirst().prefix(2).joined(separator: " ")
        for document in ["AGENTS.md", "CONTRIBUTING.md"] {
            let text = try String(contentsOf: repositoryRoot.appendingPathComponent(document), encoding: .utf8)
            let quoted = text.matches(of: /-platform_version macos [0-9.]+ [0-9.]+/).map { String($0.output) }
            XCTAssertFalse(quoted.isEmpty, "\(document) no longer quotes the flag")
            for quote in quoted {
                XCTAssertEqual(quote, flag, "\(document) quotes \(quote), but Package.swift links with \(flag)")
            }
        }
    }

    private func manifest() throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
    }

    /// The macOS version in Package.swift's `platforms` array.
    private func platformsMinimum() throws -> String {
        let match = try XCTUnwrap(
            try manifest().firstMatch(of: /platforms:\s*\[[^\]]*\.macOS\("([0-9.]+)"\)/),
            "Package.swift's platforms names no macOS(\"…\") version"
        )
        return String(match.output.1)
    }

    /// The first version after `"-platform_version", "macos"` in Package.swift.
    private func linkerFlagMinimum() throws -> String {
        let arguments = try linkerFlagArguments()
        XCTAssertEqual(arguments.first, "macos", "-platform_version's first argument")
        return try XCTUnwrap(arguments.dropFirst().first, "-platform_version names no minimum")
    }

    /// The string arguments after `"-platform_version"` in Package.swift,
    /// without the `-Xlinker`s: the platform, the minimum, the SDK, then
    /// whatever follows the flag.
    private func linkerFlagArguments() throws -> [String] {
        let text = try manifest()
        let flag = try XCTUnwrap(
            text.range(of: "\"-platform_version\""), "Package.swift has no -platform_version flag")
        return text[flag.upperBound...]
            .matches(of: /"([^"]*)"/)
            .map { String($0.output.1) }
            .filter { $0 != "-Xlinker" }
    }

    private func infoPlistMinimum() throws -> String {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("packaging/Info.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return try XCTUnwrap(
            plist["LSMinimumSystemVersion"] as? String, "packaging/Info.plist has no LSMinimumSystemVersion")
    }

    /// 26, 26.0 and 26.0.0 name the same version.
    private static func normalized(_ version: String) -> String {
        var parts = version.split(separator: ".").map(String.init)
        while parts.count > 1, parts.last.map({ Int($0) == 0 }) == true {
            parts.removeLast()
        }
        return parts.joined(separator: ".")
    }
}
