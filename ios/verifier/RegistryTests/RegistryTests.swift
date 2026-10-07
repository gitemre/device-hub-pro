import Foundation
import XCTest

/// The iOS verifier's registry against `controls-rows.json`'s `ios` keys,
/// the twin of the Android verifier's ControlsRowsManifestTest (the Swift
/// ControlsRowManifestTests checks the same file against `ControlsRow` and
/// the inspector's labels). Every mapped verifier row exists; every row
/// here mirrors an iOS Controls row (or one that moved to the Device menu,
/// `menuRows`) or is listed, with the row it waits for, in
/// `Registry.awaitingControlsRow`; a mirrored row carries the iOS label
/// verbatim and observes what the manifest says.
final class RegistryTests: XCTestCase {
    private struct Manifest: Decodable {
        struct IOS: Decodable {
            let label: String?
            let verifier: [String]
            let sameTitle: Bool
            let targets: [String]
            let observes: String
            let privateApi: Bool?
            let why: String?
        }

        struct Entry: Decodable {
            let row: String
            let label: String?
            let ios: IOS?
        }

        let schema: Int
        let rows: [Entry]
        /// What left the Controls panel for the Device menu (2026-09-29): the
        /// same `ios` keys, so its verifier rows stay mapped.
        let menuRows: [Entry]
    }

    private struct IOSEntry {
        let row: String
        let label: String?
        let ios: Manifest.IOS
    }

    private static var manifestURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RegistryTests
            .deletingLastPathComponent() // verifier
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("controls-rows.json")
    }

    private func iosEntries() throws -> [IOSEntry] {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: Self.manifestURL))
        XCTAssertEqual(manifest.schema, 2)
        return (manifest.rows + manifest.menuRows).compactMap { entry in
            entry.ios.map { IOSEntry(row: entry.row, label: $0.label ?? entry.label, ios: $0) }
        }
    }

    func testRowIdsAreUniqueAndRowsComplete() {
        let rows = Registry.rows
        XCTAssertFalse(rows.isEmpty)
        XCTAssertEqual(rows.count, Set(rows.map(\.id)).count)
        XCTAssertEqual(Registry.sections.count, Set(Registry.sections.map(\.id)).count)
        for section in Registry.sections {
            XCTAssertFalse(section.title.isEmpty, section.id)
            XCTAssertFalse(section.rows.isEmpty, section.id)
            for row in section.rows {
                XCTAssertTrue(row.id.hasPrefix("\(section.id)."), "\(row.id) is not in \(section.id)")
                XCTAssertFalse(row.title.isEmpty, row.id)
                XCTAssertFalse(row.source.isEmpty, row.id)
                XCTAssertFalse(row.detail.isEmpty, row.id)
            }
        }
    }

    func testTheManifestHasIOSRows() throws {
        XCTAssertFalse(try iosEntries().isEmpty)
    }

    func testEveryMappedVerifierRowExists() throws {
        for entry in try iosEntries() {
            for id in entry.ios.verifier {
                XCTAssertNotNil(Registry.row(id), "\(entry.row) maps to missing iOS verifier row \(id)")
            }
        }
    }

    func testEveryVerifierRowMirrorsAnIOSControlsRowOrWaitsForOne() throws {
        let mapped = Set(try iosEntries().flatMap(\.ios.verifier))
        let awaiting = Set(Registry.awaitingControlsRow.keys)
        let stale = Set(Registry.rows.map(\.id)).subtracting(mapped).subtracting(awaiting)
        XCTAssertEqual(stale, [], "iOS verifier rows no iOS Controls row maps to")
        XCTAssertEqual(
            mapped.intersection(awaiting), [],
            "mapped in controls-rows.json: remove them from Registry.awaitingControlsRow"
        )
        for (id, controlsRow) in Registry.awaitingControlsRow {
            XCTAssertNotNil(Registry.row(id), "awaiting row \(id) is not a verifier row")
            XCTAssertFalse(controlsRow.isEmpty, id)
        }
    }

    func testMirroredRowsUseTheIOSLabelVerbatim() throws {
        for entry in try iosEntries() where entry.ios.sameTitle {
            XCTAssertEqual(entry.ios.verifier.count, 1, "\(entry.row) has one verifier row")
            guard let id = entry.ios.verifier.first, let row = Registry.row(id) else { continue }
            XCTAssertEqual(row.title, entry.label, "\(id) title")
        }
    }

    func testMirroredRowsObserveWhatTheManifestSays() throws {
        for entry in try iosEntries() {
            let observes = try XCTUnwrap(Observes(rawValue: entry.ios.observes), entry.row)
            for id in entry.ios.verifier {
                guard let row = Registry.row(id) else { continue }
                XCTAssertEqual(row.observes, observes, "\(entry.row) → \(id)")
            }
        }
    }

    func testReadingsDocumentRoundTrips() throws {
        let launched = try XCTUnwrap(ReadingsDocument.date("2026-09-26T14:02:11.123Z"))
        let document = ReadingsDocument(
            bundle: Registry.bundleIdentifier,
            system: "iOS 27.0 · iPhone18,1 simulator",
            launchedAt: launched,
            writtenAt: launched.addingTimeInterval(1.5),
            rows: [
                "display.appearance": .init(
                    title: "Appearance", observes: .effect, value: "Dark", raw: "dark",
                    changedAt: launched.addingTimeInterval(1), changes: 1
                ),
            ]
        )
        let data = try ReadingsDocument.encoder().encode(document)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"launchedAt\" : \"2026-09-26T14:02:11.123Z\""), text)
        XCTAssertTrue(text.contains("\"schema\" : 1"), text)
        XCTAssertEqual(try ReadingsDocument.decoder().decode(ReadingsDocument.self, from: data), document)
    }
}
