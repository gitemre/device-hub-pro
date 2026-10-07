import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// The annotation editor's geometry and save path: one scale for both axes
/// (F15), and a failed save reported to the editor sheet rather than to the
/// window alert hidden behind it (F9).
@MainActor
final class AnnotationEditorTests: XCTestCase {
    // MARK: - Geometry (F15)

    func testFittedSizeKeepsOneScaleForBothAxes() {
        let pixels = CGSize(width: 1080, height: 2400)
        let fitted = AnnotationEditorView.fittedSize(pixelSize: pixels, in: CGSize(width: 600, height: 523))

        XCTAssertEqual(fitted.height, 523, accuracy: 1e-9)
        // Rounding each side down gave 235×523: x scale 4.596, y scale 4.589,
        // so the renderer's single (width) scale put annotations near the
        // bottom ~4 px too low.
        XCTAssertEqual(
            pixels.width / fitted.width,
            pixels.height / fitted.height,
            accuracy: 1e-9
        )
    }

    func testFittedSizeUsesTheTighterSide() {
        let fitted = AnnotationEditorView.fittedSize(
            pixelSize: CGSize(width: 2400, height: 1080),
            in: CGSize(width: 600, height: 523)
        )
        XCTAssertEqual(fitted.width, 600, accuracy: 1e-9)
        XCTAssertEqual(fitted.height, 270, accuracy: 1e-9)
    }

    func testFittedSizeOfAnEmptyImageIsZero() {
        XCTAssertEqual(
            AnnotationEditorView.fittedSize(pixelSize: .zero, in: CGSize(width: 600, height: 523)),
            .zero
        )
    }

    // MARK: - Saving (F9)

    func testFailedWriteKeepsTheEditorOpenAndReportsToIt() throws {
        let model = AppModel.testing()
        model.workspace.capture.annotationEditRequest = AnnotationEditRequest(png: Data([0x89]))
        let unwritable = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationEditorTests-missing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("shot.png")

        let outcome = model.workspace.capture.writeAnnotatedScreenshot(Data([1, 2, 3]), to: unwritable)

        guard case .failed(let message) = outcome else {
            return XCTFail("expected a failure, got \(outcome)")
        }
        XCTAssertTrue(message.hasPrefix("Could not save the screenshot"))
        XCTAssertNotNil(model.workspace.capture.annotationEditRequest, "the annotations must survive a failed save")
        XCTAssertNil(model.workspace.status.errorMessage, "the window alert sits behind the editor sheet")
    }

    func testSuccessfulWriteClosesTheEditor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationEditorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel.testing()
        model.workspace.capture.annotationEditRequest = AnnotationEditRequest(png: Data([0x89]))
        let url = directory.appendingPathComponent("shot.png")

        XCTAssertEqual(model.workspace.capture.writeAnnotatedScreenshot(Data([1, 2, 3]), to: url), .saved)
        XCTAssertNil(model.workspace.capture.annotationEditRequest)
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
    }

    func testWriteWithoutAnOpenEditorDoesNothing() {
        let model = AppModel.testing()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationEditorTests-none-\(UUID().uuidString).png")

        XCTAssertEqual(model.workspace.capture.writeAnnotatedScreenshot(Data([1]), to: url), .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
