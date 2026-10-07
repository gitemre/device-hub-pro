import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// `controls-rows.json` (the repository root, schema 2) is the one list of
/// Controls rows the verifier apps mirror: one entry per `ControlsRow`, in
/// order, with a key per platform the row is offered on (`android`, `ios`).
/// `menuRows` lists what left the Controls panels for the Device menu on
/// 2026-09-29 (no `ControlsRow`, the same platform keys, and where it is now).
/// Its JUnit twin (ControlsRowsManifestTest, android/verifier) checks the
/// Android verifier against the `android` keys and IOSVerifierRegistryTests
/// (ios/verifier) the iOS verifier against the `ios` keys. This side keeps
/// the manifest in step with `ControlsRow` and the inspector's labels, so a
/// new or renamed row cannot slip past either verifier.
final class ControlsRowManifestTests: XCTestCase {
    private enum Platform: String, CaseIterable {
        case android
        case ios

        /// The keys a platform object may carry.
        var keys: Set<String> {
            switch self {
            case .android: return ["label", "verifier", "sameTitle", "why"]
            case .ios: return ["label", "verifier", "sameTitle", "why", "targets", "observes", "privateApi"]
            }
        }
    }

    private struct Manifest: Decodable {
        struct PlatformEntry: Decodable {
            let label: String?
            let verifier: [String]
            let sameTitle: Bool
            let why: String?
            let targets: [String]?
            let observes: String?
            let privateApi: Bool?
        }

        struct Entry: Decodable {
            let row: String
            let label: String?
            let surface: String?
            let android: PlatformEntry?
            let ios: PlatformEntry?

            func on(_ platform: Platform) -> PlatformEntry? {
                switch platform {
                case .android: return android
                case .ios: return ios
                }
            }

            /// The row's title on a platform: its override, else the shared label.
            func label(on platform: Platform) -> String? {
                on(platform)?.label ?? label
            }
        }

        let schema: Int
        let rows: [Entry]
        let menuRows: [Entry]
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var manifestURL: URL { repositoryRoot.appendingPathComponent("controls-rows.json") }

    private func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    }

    func testTheManifestListsEveryControlsRowInOrder() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest.schema, 2)
        XCTAssertEqual(manifest.rows.map(\.row), ControlsRow.allCases.map { "\($0)" })
    }

    /// Unknown keys would be read by nobody: a typo (`sametitle`) or an iOS
    /// field on Android would pass silently.
    func testEntriesUseOnlyTheSchemasKeys() throws {
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        XCTAssertEqual(Set(root.keys), ["schema", "about", "rows", "menuRows"])
        let rows = try XCTUnwrap(root["rows"] as? [[String: Any]])
        let menuRows = try XCTUnwrap(root["menuRows"] as? [[String: Any]])
        let entryKeys = Set(["row", "label", "surface"] + Platform.allCases.map(\.rawValue))
        for row in rows + menuRows {
            let name = row["row"] as? String ?? "?"
            XCTAssertTrue(Set(row.keys).isSubset(of: entryKeys), "\(name): \(row.keys.sorted())")
            for platform in Platform.allCases {
                guard let object = row[platform.rawValue] else { continue }
                let keys = Set((object as? [String: Any])?.keys.map { $0 } ?? [])
                XCTAssertTrue(keys.isSubset(of: platform.keys), "\(name).\(platform): \(keys.sorted())")
                XCTAssertTrue(keys.isSuperset(of: ["verifier", "sameTitle"]), "\(name).\(platform): \(keys.sorted())")
            }
        }
    }

    /// A moved row says where it is now, is offered on a platform and is not a
    /// `ControlsRow` any more (the panel would have no view for it).
    func testMenuRowsSayWhereTheyAre() throws {
        let manifest = try manifest()
        XCTAssertFalse(manifest.menuRows.isEmpty)
        for entry in manifest.menuRows {
            XCTAssertFalse(entry.surface?.isEmpty ?? true, "\(entry.row): says nothing about where it is now")
            XCTAssertTrue(Platform.allCases.contains { entry.on($0) != nil }, "\(entry.row) is offered nowhere")
            XCTAssertFalse(entry.row.isEmpty)
        }
        let names = manifest.menuRows.map(\.row)
        XCTAssertEqual(names.count, Set(names).count, "a menu row is listed twice")
    }

    func testEveryRowIsOfferedOnAPlatform() throws {
        for entry in try manifest().rows {
            XCTAssertTrue(Platform.allCases.contains { entry.on($0) != nil }, "\(entry.row) is offered nowhere")
        }
    }

    func testIOSEntriesSayWhatTheyTargetAndObserve() throws {
        for entry in try manifest().rows {
            guard let ios = entry.ios else { continue }
            let targets = try XCTUnwrap(ios.targets, "\(entry.row): ios needs targets")
            XCTAssertFalse(targets.isEmpty, entry.row)
            XCTAssertEqual(targets.count, Set(targets).count, entry.row)
            XCTAssertTrue(Set(targets).isSubset(of: ["simulator", "device"]), "\(entry.row): \(targets)")
            let observes = try XCTUnwrap(ios.observes, "\(entry.row): ios needs observes")
            XCTAssertTrue(["effect", "key", "note"].contains(observes), "\(entry.row): \(observes)")
            if ios.verifier.isEmpty {
                XCTAssertNotNil(ios.why, "\(entry.row): an empty ios verifier list says why")
            }
        }
    }

    /// Physical availability is a target, not a platform key: an iOS entry
    /// lists `device` exactly for the rows a physical iPhone can offer
    /// (`ControlsRow.appleDeviceRows`, each gated on the phone's CoreDevice
    /// features). Every such row is also a simulator row but two: Clipboard
    /// (a simulator's Device Hub panel has none) and, on iOS 26 simulators,
    /// the colour filter.
    func testTheDeviceTargetIsTheRowsAPhysicalIPhoneCanOffer() throws {
        let rows = Dictionary(uniqueKeysWithValues: ControlsRow.allCases.map { ("\($0)", $0) })
        var withDevice: Set<ControlsRow> = []
        for entry in try manifest().rows {
            guard let ios = entry.ios else { continue }
            let row = try XCTUnwrap(rows[entry.row], entry.row)
            let targets = try XCTUnwrap(ios.targets, entry.row)
            if targets.contains("device") {
                withDevice.insert(row)
                XCTAssertTrue(targets.contains("simulator"), "\(entry.row): a device row is a simulator row too")
            }
        }
        // Plus the rows below the cards that only need the allowed `device process`
        // shapes (Links, Target app, Launch, Terminate), not a capability.
        XCTAssertEqual(withDevice, ControlsRow.appleDeviceRows.union(ControlsRow.applePhysicalExtraRows))
        XCTAssertTrue(ControlsRow.appleDeviceRows.isSubset(of: Set(ControlsRow.appleRows)))
        XCTAssertTrue(ControlsRow.applePhysicalExtraRows.isSubset(of: Set(ControlsRow.appleRows)))
    }

    func testManifestLabelsAreTheInspectorsLabels() throws {
        // ControlsView.swift and the row files it hands groups to
        // (`*ControlsRows.swift`, including the Apple ones under Apple/).
        let sources = repositoryRoot.appendingPathComponent("Sources/DeviceHubProApp")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let rowFiles = enumerator.compactMap { $0 as? URL }.filter {
            $0.lastPathComponent == "ControlsView.swift" || $0.lastPathComponent.hasSuffix("ControlsRows.swift")
        }
        XCTAssertFalse(rowFiles.isEmpty)
        let view = try rowFiles.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        let toggleLabels = Set(DeviceToggle.allCases.map(\.label))
        for entry in try manifest().rows {
            for platform in Platform.allCases where entry.on(platform) != nil {
                guard let label = entry.label(on: platform) else { continue }
                XCTAssertTrue(
                    view.contains("\"\(label)\"") || toggleLabels.contains(label),
                    "\(entry.row) (\(platform)): \"\(label)\" is not a title in the Controls inspector"
                )
            }
        }
    }

    /// `ControlsRow.platforms` (what the panels offer) is the manifest's
    /// platform keys, row by row.
    func testPlatformsAreTheManifestsKeys() throws {
        let entries = Dictionary(uniqueKeysWithValues: try manifest().rows.map { ($0.row, $0) })
        for row in ControlsRow.allCases {
            let entry = try XCTUnwrap(entries["\(row)"], "\(row)")
            var keys: Set<DevicePlatform> = []
            if entry.android != nil { keys.insert(.android) }
            if entry.ios != nil { keys.insert(.apple) }
            XCTAssertEqual(row.platforms, keys, "\(row)")
        }
    }

    func testTheDeveloperTogglesUseTheirKitLabels() throws {
        let entries = Dictionary(uniqueKeysWithValues: try manifest().rows.map { ($0.row, $0) })
        let rows: [(ControlsRow, DeviceToggle)] = [
            (.forceRTL, .forceRTL),
            (.showTaps, .showTaps),
            (.backgroundANRs, .showBackgroundANRs),
        ]
        for (row, toggle) in rows {
            XCTAssertEqual(entries["\(row)"]?.label(on: .android), toggle.label, "\(row)")
        }
    }

    func testMirroredRowsNameOneVerifierRow() throws {
        for entry in try manifest().rows {
            for platform in Platform.allCases {
                guard let object = entry.on(platform), object.sameTitle else { continue }
                XCTAssertNotNil(entry.label(on: platform), "\(entry.row) (\(platform))")
                XCTAssertEqual(object.verifier.count, 1, "\(entry.row) (\(platform))")
            }
        }
    }
}
