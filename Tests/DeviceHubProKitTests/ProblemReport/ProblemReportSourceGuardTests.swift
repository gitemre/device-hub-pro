import XCTest

/// The problem report must change nothing and send nothing: no adb recovery, no
/// simulator tool, no file write outside the problem log, no emulator launch.
/// A scan of its sources and the CLI's, like `AppleSourceGuardTests`.
///
/// Two refinements of the plain word list, for the places that name a thing
/// without running it: the report's model has `simctl` and `devicectl` fields
/// (what the Xcode probe found), the analyzer's advice to the user says
/// `adb kill-server`, and the inputs hold an `appLogDirectory` (a folder that is
/// listed, never made). So the words are checked as the calls they would be:
/// quoted as arguments, or as the helpers that run or create.
final class ProblemReportSourceGuardTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func sources(_ folder: String) throws -> [(name: String, text: String)] {
        let url = root.appendingPathComponent(folder, isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertFalse(names.isEmpty, folder)
        return try names.map { ($0, try String(contentsOf: url.appendingPathComponent($0), encoding: .utf8)) }
    }

    private var all: [(name: String, text: String)] {
        get throws {
            try sources("Sources/DeviceHubProKit/Diagnostics/ProblemReport") + sources("Sources/DeviceHubProReport")
        }
    }

    /// The source without its comment lines (a comment may name what the code does not do).
    private func code(of text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testNothingRecoversStartsOrWrites() throws {
        let forbidden = [
            "repairTarget", "AvdDisplayRepair", "AvdFileOperations", "EmulatorManager.appLogDirectory",
            ".logTail(", "logFileURL(", "EmulatorDiscovery", "emulatorDiscovery(", "AdbClient", "launchDetached",
            "removeItem", "setValue(", "xcrun", "\"booted\"", "\"simctl\"", "\"devicectl\"",
            "SimctlClient", "DevicectlClient", "DevicectlPhysicalClient", "ApplePhysicalInventory",
        ]
        for file in try all {
            for word in forbidden {
                XCTAssertFalse(file.text.contains(word), "\(file.name) contains \(word)")
            }
        }
    }

    /// The files that run adb or tools never spell the server's recovery.
    func testTheRunnersNeverSpellTheServersRecovery() throws {
        for file in try all where !["ProblemReportAnalyzer.swift"].contains(file.name) {
            for word in ["kill-server", "start-server"] {
                XCTAssertFalse(file.text.contains(word), "\(file.name) contains \(word)")
            }
        }
    }

    func testOnlyTheProblemLogMakesAFolder() throws {
        for file in try all where file.name != "RecentProblemStore.swift" {
            XCTAssertFalse(file.text.contains("createDirectory"), file.name)
            XCTAssertFalse(file.text.contains("createFile"), file.name)
            XCTAssertFalse(file.text.contains(".write(to"), file.name)
        }
    }

    /// Only the collector's adb helper, the process list and the issue reader run a process.
    func testOnlyTheKnownFilesRunAProcess() throws {
        let allowed: Set<String> = ["ProblemReportCollector+Emulators.swift", "ProblemReportInputs.swift", "IssueTextFetcher.swift"]
        for file in try all where code(of: file.text).contains("ProcessRunner") || code(of: file.text).contains("Process(") {
            XCTAssertTrue(allowed.contains(file.name), "\(file.name) runs a process")
        }
    }

    /// A string enum added to the report's model must be listed in `ProblemReport.enumRawValues`, or a name
    /// equal to one of its values would make the scrubbed report unreadable.
    func testEveryStringEnumOfTheModelIsListedAsASchemaWord() throws {
        let model = try String(
            contentsOf: root.appendingPathComponent("Sources/DeviceHubProKit/Diagnostics/ProblemReport/ProblemReport.swift"),
            encoding: .utf8
        )
        let declared = try NSRegularExpression(pattern: "enum (\\w+): String, Codable")
            .matches(in: model, range: NSRange(model.startIndex..., in: model))
            .map { String(model[Range($0.range(at: 1), in: model)!]) }
        XCTAssertGreaterThanOrEqual(declared.count, 8)
        let listing = try XCTUnwrap(model.range(of: "public static let enumRawValues")).lowerBound
        let list = String(model[listing...].prefix(900))
        for name in declared {
            XCTAssertTrue(list.contains("\(name).allCases"), "\(name) is not in ProblemReport.enumRawValues")
        }
    }
}
