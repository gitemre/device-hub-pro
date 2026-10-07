import Foundation
import XCTest
@testable import DeviceHubProKit

/// Source scans for fast input (AGENTS.md "Private APIs and kill
/// switches"): the private service words live only in the vendored
/// helper and the Kit's `FastInput` folder, the helper is launched from one
/// place, and the physical `devicectl` client still refuses the lease's command.
final class FastInputSourceGuardTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let fastFolder = "Sources/DeviceHubProKit/Apple/FastInput/"
    private static let thisFile = "Tests/DeviceHubProKitTests/FastInputSourceGuardTests.swift"

    private struct File {
        let path: String
        let text: String
    }

    /// Every text file of the source, test, script and iOS folders.
    private static func files(under folders: [String]) throws -> [File] {
        var result: [File] = []
        let fileManager = FileManager.default
        for folder in folders {
            let base = root.appendingPathComponent(folder, isDirectory: true)
            guard let enumerator = fileManager.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, (values.fileSize ?? 0) < 1_000_000 else { continue }
                guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { continue }
                result.append(File(path: String(url.path.dropFirst(root.path.count + 1)), text: text))
            }
        }
        return result
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\"", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
    }

    private func allowedHome(_ path: String) -> Bool {
        path.hasPrefix(Self.fastFolder) || path == Self.thisFile
            || path.hasPrefix("Tests/DeviceHubProKitTests/FastInput")
            // The native live view's vendored stream code names the same service (NativeMirrorTests pins it).
            || path.hasPrefix("Sources/DeviceHubProNativeMirror/")
    }

    func testThePrivateServiceWordsLiveOnlyInTheHelperAndTheFastInputFolder() throws {
        let files = try Self.files(under: ["Sources", "Tests", "Scripts", "ios", "android"])
        XCTAssertTrue(files.contains { $0.path.hasPrefix(Self.fastFolder) }, "the scan sees the fast input folder")
        var offenders: [String] = []
        // The fixtures are real devicectl captures, which list the capability names.
        for file in files where !allowedHome(file.path) && !file.path.contains("/Fixtures/") {
            let lowered = file.text.lowercased()
            if lowered.contains("createservicesocket") || lowered.contains("universalhidservice") {
                offenders.append(file.path)
            }
            for line in file.text.split(whereSeparator: \.isNewline) where Self.normalized(String(line)).contains("notification observe") {
                offenders.append(file.path)
            }
        }
        XCTAssertEqual(offenders, [])
    }

    func testTheHelpersOwnSourcesNameTheServices() throws {
        let helper = try String(contentsOf: Self.root.appendingPathComponent("fastinput/Sources/fastinput_main.m"), encoding: .utf8).lowercased()
        XCTAssertTrue(helper.contains("createservicesocket"))
        XCTAssertTrue(helper.contains("universalhidservice"))
    }

    /// The real launcher is made in one place, the helper's file name is
    /// spelled in one place, and only the session starts children.
    func testTheHelperIsLaunchedFromTheSessionOnly() throws {
        let files = try Self.files(under: ["Sources"])
        func code(_ file: File) -> [String] {
            file.text.split(whereSeparator: \.isNewline).map(String.init).filter {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return !(trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*"))
            }
        }
        let launcherMakers = files.filter { code($0).contains { $0.contains("ProcessFastInputChildLauncher(") } }.map(\.path)
        // The native live view's lease is the one other maker (`PhysicalNativeMirrorSession.swift`).
        XCTAssertEqual(Set(launcherMakers), [
            Self.fastFolder + "FastInputSession.swift",
            "Sources/DeviceHubProKit/Apple/Live/PhysicalNativeMirrorSession.swift",
        ])
        let helperName = files.filter { code($0).contains { $0.contains("FastInputBuilder.helperName") || $0.contains("\"fastinput-helper\"") } }.map(\.path)
        XCTAssertEqual(Set(helperName), [Self.fastFolder + "FastInputBuilder.swift"])
        let processes = files.filter { $0.path.hasPrefix(Self.fastFolder) && code($0).contains { $0.contains("Process()") } }.map(\.path)
        XCTAssertEqual(processes, [Self.fastFolder + "FastInputChild.swift"])
        // The app reaches fast input through the session, never the pieces.
        let app = files.filter { $0.path.hasPrefix("Sources/DeviceHubProApp/") }
            .filter { code($0).contains { $0.contains("TunnelLeaseKeeper") || $0.contains("ProcessFastInputChild") || $0.contains("FastInputBuilder") } }
        XCTAssertEqual(app.map(\.path), [])
    }

    func testThePhysicalClientStillRefusesTheLeaseCommand() {
        for command in [["device", "notification", "observe"], ["device", "notification", "post"]] {
            XCTAssertThrowsError(try DevicectlPhysicalClient.validate(command), command.joined(separator: " "))
        }
        XCTAssertFalse(DevicectlPhysicalClient.allowedCommandWords.contains { $0.contains("notification") })
    }

    /// The vendored sources carry their provenance and licence, and none of the
    /// upstream pieces that were left out.
    func testTheVendoredFolderCarriesProvenanceAndOmitsTheRest() throws {
        let fastinput = Self.root.appendingPathComponent("fastinput")
        let provenance = try String(contentsOf: fastinput.appendingPathComponent("PROVENANCE.md"), encoding: .utf8)
        XCTAssertTrue(provenance.contains("f2e85a6d60c45f18e6f9f2a306f709ffb9710392"))
        XCTAssertTrue(provenance.contains("github.com/ipbtools/ipb"))
        XCTAssertTrue(provenance.contains("2026-09-30"))
        let license = try String(contentsOf: fastinput.appendingPathComponent("LICENSE"), encoding: .utf8)
        XCTAssertTrue(license.hasPrefix("MIT License"))
        let names = try FileManager.default.subpathsOfDirectory(atPath: fastinput.path)
        for forbidden in ["ipb", "mirror", "video_stream", "Experiments", "Formula", "action_sender"] {
            XCTAssertFalse(names.contains { $0.contains(forbidden) && !$0.hasSuffix(".md") }, forbidden)
        }
    }
}
