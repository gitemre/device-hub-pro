import CoreGraphics
import XCTest
@testable import DeviceHubProKit

/// `DisplayShapeStore` in a temporary directory, removed after each test.
/// The shapes are the real fold panels (`DisplayShapeTests`' capture).
final class DisplayShapeStoreTests: XCTestCase {
    private var directory: URL!
    private var store: DisplayShapeStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayShapeStoreTests-\(UUID().uuidString)", isDirectory: true)
        // Not created: the first record must create it.
        store = DisplayShapeStore(directory: directory.appendingPathComponent("shapes", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func foldShapes() throws -> [DisplayShape] {
        let shapes = DisplayShape.parse(
            dumpsysDisplay: try AdbCoreFixtureTests.text("shell-dumpsys-display.txt")
        )
        XCTAssertEqual(shapes.count, 2)
        return shapes
    }

    /// A stopped AVD reads back every panel it last reported, cutout path
    /// included (the spec and its inputs survive the round trip).
    func testRecordedShapesReadBackForTheAvd() throws {
        let shapes = try foldShapes()
        try store.record(shapes, forAvd: "Pixel_9_Pro_Fold")

        let read = store.shapes(forAvd: "Pixel_9_Pro_Fold")
        XCTAssertEqual(read, shapes)
        XCTAssertEqual(read.map(\.maxCornerRadius), [85, 115])
        XCTAssertEqual(read.first?.cutoutPath?.boundingBoxOfPath.minX ?? 0, 1948, accuracy: 1e-6)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.directory.appendingPathComponent("Pixel_9_Pro_Fold.json").path
        ))
        XCTAssertEqual(store.shapes(forAvd: "Pixel_10_Pro"), [])
    }

    /// An empty list is a failed read: the last known shapes stay.
    func testEmptyRecordKeepsTheLastKnownShapes() throws {
        let shapes = try foldShapes()
        try store.record(shapes, forAvd: "Pixel_9_Pro_Fold")
        try store.record([], forAvd: "Pixel_9_Pro_Fold")
        XCTAssertEqual(store.shapes(forAvd: "Pixel_9_Pro_Fold"), shapes)

        try store.record([], forAvd: "Pixel_10_Pro")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(forAvd: "Pixel_10_Pro").path))
    }

    /// Recording what is already stored does not rewrite the file; a change
    /// (the fold's cover now lit) does.
    func testUnchangedShapesAreNotRewritten() throws {
        var shapes = try foldShapes()
        try store.record(shapes, forAvd: "Pixel_9_Pro_Fold")
        let file = store.fileURL(forAvd: "Pixel_9_Pro_Fold")
        let past = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)

        try store.record(shapes, forAvd: "Pixel_9_Pro_Fold")
        XCTAssertEqual(try modificationDate(file), past)

        shapes[0].state = "OFF"
        shapes[1].state = "ON"
        try store.record(shapes, forAvd: "Pixel_9_Pro_Fold")
        XCTAssertNotEqual(try modificationDate(file), past)
        XCTAssertEqual(store.shapes(forAvd: "Pixel_9_Pro_Fold").map(\.state), ["OFF", "ON"])
    }

    /// A damaged file or one from another format version reads as nothing,
    /// and the next record replaces it.
    func testUnreadableOrOtherVersionFilesReadAsEmpty() throws {
        let shapes = try foldShapes()
        try store.record(shapes, forAvd: "Pixel_9_Pro_Fold")
        let file = store.fileURL(forAvd: "Pixel_9_Pro_Fold")

        try Data("{not json".utf8).write(to: file)
        XCTAssertEqual(store.shapes(forAvd: "Pixel_9_Pro_Fold"), [])

        let stored = try JSONEncoder().encode(shapes)
        let future = "{\"version\":\(DisplayShapeStore.formatVersion + 1),\"displays\":\(String(decoding: stored, as: UTF8.self))}"
        try Data(future.utf8).write(to: file)
        XCTAssertEqual(store.shapes(forAvd: "Pixel_9_Pro_Fold"), [])

        try store.record(shapes, forAvd: "Pixel_9_Pro_Fold")
        XCTAssertEqual(store.shapes(forAvd: "Pixel_9_Pro_Fold"), shapes)
    }

    func testRemoveForgetsTheAvd() throws {
        try store.record(try foldShapes(), forAvd: "Pixel_9_Pro_Fold")
        store.removeShapes(forAvd: "Pixel_9_Pro_Fold")
        XCTAssertEqual(store.shapes(forAvd: "Pixel_9_Pro_Fold"), [])
        // Removing what is not there is fine.
        store.removeShapes(forAvd: "Pixel_9_Pro_Fold")
    }

    /// A renamed AVD takes its shapes along; the old name keeps none.
    func testMoveTakesTheShapesToTheNewName() throws {
        let shapes = try foldShapes()
        try store.record(shapes, forAvd: "Pixel_9_Pro_Fold")

        try store.moveShapes(fromAvd: "Pixel_9_Pro_Fold", toAvd: "Fold_Renamed")

        XCTAssertEqual(store.shapes(forAvd: "Fold_Renamed"), shapes)
        XCTAssertEqual(store.shapes(forAvd: "Pixel_9_Pro_Fold"), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), ["Fold_Renamed.json"])
    }

    /// What the new name held belonged to a deleted AVD: it goes even when
    /// the renamed AVD has nothing to bring.
    func testMoveDropsWhatTheNewNameHeld() throws {
        try store.record(try foldShapes(), forAvd: "Deleted_Fold")

        try store.moveShapes(fromAvd: "Never_Mirrored", toAvd: "Deleted_Fold")

        XCTAssertEqual(store.shapes(forAvd: "Deleted_Fold"), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [])
    }

    /// A rename that only changes case is one file on a case-insensitive
    /// volume (the default on macOS): the shapes survive it.
    func testMoveThatOnlyChangesCaseKeepsTheShapes() throws {
        let shapes = try foldShapes()
        try store.record(shapes, forAvd: "Fold")

        try store.moveShapes(fromAvd: "Fold", toAvd: "FOLD")

        XCTAssertEqual(store.shapes(forAvd: "FOLD"), shapes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), ["FOLD.json"])
    }

    /// Names are file names inside the directory whatever they hold.
    func testAvdNamesCannotLeaveTheDirectory() throws {
        for name in ["../escape", "a/b", "Pixel 9 Pro", "..", "~"] {
            let url = store.fileURL(forAvd: name)
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, store.directory.standardizedFileURL, name)
        }
        XCTAssertEqual(store.fileURL(forAvd: "Pixel_9_Pro_Fold").lastPathComponent, "Pixel_9_Pro_Fold.json")
        XCTAssertEqual(store.fileURL(forAvd: "a/b").lastPathComponent, "a%2Fb.json")

        try store.record(try foldShapes(), forAvd: "../escape")
        XCTAssertEqual(store.shapes(forAvd: "../escape").count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), ["..%2Fescape.json"])
    }

    // MARK: - Physical models

    /// A phone's shapes are kept under its model (`ro.product.model`); the
    /// capture's device reports `sdk_gphone16k_arm64` (`shell-getprop.txt`).
    func testPhysicalModelShapesReadBack() throws {
        let shapes = try foldShapes()
        try store.record(shapes, forPhysicalModel: "sdk_gphone16k_arm64")

        XCTAssertEqual(store.shapes(forPhysicalModel: "sdk_gphone16k_arm64"), shapes)
        XCTAssertEqual(store.shapes(forPhysicalModel: "2209116AG"), [])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.directory.appendingPathComponent("physical/sdk_gphone16k_arm64.json").path
        ))
        // Nothing is keyed by AVD.
        XCTAssertEqual(store.shapes(forAvd: "sdk_gphone16k_arm64"), [])
    }

    /// A model named like an AVD is another file: neither overwrites nor
    /// reads the other.
    func testAModelNamedLikeAnAvdDoesNotCollide() throws {
        let shapes = try foldShapes()
        try store.record(shapes, forAvd: "Pixel_9_Pro_Fold")
        try store.record([shapes[1]], forPhysicalModel: "Pixel_9_Pro_Fold")

        XCTAssertEqual(store.shapes(forAvd: "Pixel_9_Pro_Fold"), shapes)
        XCTAssertEqual(store.shapes(forPhysicalModel: "Pixel_9_Pro_Fold"), [shapes[1]])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted(),
            ["Pixel_9_Pro_Fold.json", "physical"]
        )

        // Nor does an AVD named after the folder.
        try store.record([shapes[0]], forAvd: "physical")
        XCTAssertEqual(store.shapes(forAvd: "physical"), [shapes[0]])
        XCTAssertEqual(store.shapes(forPhysicalModel: "Pixel_9_Pro_Fold"), [shapes[1]])

        // Removing the AVD leaves the model.
        store.removeShapes(forAvd: "Pixel_9_Pro_Fold")
        XCTAssertEqual(store.shapes(forPhysicalModel: "Pixel_9_Pro_Fold"), [shapes[1]])
    }

    /// As for an AVD, an empty list is a failed read and keeps what is
    /// stored; an unchanged list is not rewritten.
    func testAnEmptyRecordKeepsTheModelsShapes() throws {
        let shapes = try foldShapes()
        try store.record(shapes, forPhysicalModel: "sdk_gphone16k_arm64")
        try store.record([], forPhysicalModel: "sdk_gphone16k_arm64")
        XCTAssertEqual(store.shapes(forPhysicalModel: "sdk_gphone16k_arm64"), shapes)

        let file = try XCTUnwrap(store.fileURL(forPhysicalModel: "sdk_gphone16k_arm64"))
        let past = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)
        try store.record(shapes, forPhysicalModel: "sdk_gphone16k_arm64")
        XCTAssertEqual(try modificationDate(file), past)

        try store.record([], forPhysicalModel: "2209116AG")
        let never = try XCTUnwrap(store.fileURL(forPhysicalModel: "2209116AG"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: never.path))
    }

    /// Model names are file names inside `physical/` whatever they hold
    /// (marketing names carry spaces); an empty one names no phone.
    func testModelNamesStayInThePhysicalFolder() throws {
        let physical = store.directory.appendingPathComponent("physical", isDirectory: true).standardizedFileURL
        for model in ["../escape", "a/b", "Pixel 9 Pro", "..", "~"] {
            let url = try XCTUnwrap(store.fileURL(forPhysicalModel: model), model)
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, physical, model)
        }
        XCTAssertEqual(store.fileURL(forPhysicalModel: "Pixel 9 Pro")?.lastPathComponent, "Pixel%209%20Pro.json")

        XCTAssertNil(store.fileURL(forPhysicalModel: ""))
        try store.record(try foldShapes(), forPhysicalModel: "")
        XCTAssertEqual(store.shapes(forPhysicalModel: ""), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }

    /// Beside `AppIconStore`'s icons in the user's caches.
    func testDefaultDirectoryIsInTheAppCaches() throws {
        let caches = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        XCTAssertEqual(
            DisplayShapeStore.defaultDirectory(),
            caches.appendingPathComponent("DeviceHubPro/displayshapes", isDirectory: true)
        )
    }

    private func modificationDate(_ url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
