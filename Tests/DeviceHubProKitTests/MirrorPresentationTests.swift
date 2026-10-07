import XCTest
@testable import DeviceHubProKit

final class MirrorPresentationTests: XCTestCase {
    func testFitsAndCentersPreservingAspect() {
        let presentation = MirrorPresentation()
        let viewport = presentation.viewport(
            frameWidth: 2000,
            frameHeight: 1000,
            drawableWidth: 1000,
            drawableHeight: 1000
        )
        XCTAssertEqual(viewport?.width ?? 0, 960, accuracy: 0.001)
        XCTAssertEqual(viewport?.height ?? 0, 480, accuracy: 0.001)
        XCTAssertEqual(viewport?.x ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(viewport?.y ?? 0, 260, accuracy: 0.001)
    }

    func testRescalesWhenAvailableAreaChanges() {
        let presentation = MirrorPresentation()

        let small = presentation.viewport(
            frameWidth: 2000,
            frameHeight: 1000,
            drawableWidth: 600,
            drawableHeight: 400
        )
        XCTAssertEqual(small?.width ?? 0, 576, accuracy: 0.001)
        XCTAssertEqual(small?.height ?? 0, 288, accuracy: 0.001)

        let large = presentation.viewport(
            frameWidth: 2000,
            frameHeight: 1000,
            drawableWidth: 1600,
            drawableHeight: 400
        )
        XCTAssertEqual(large?.width ?? 0, 768, accuracy: 0.001)
        XCTAssertEqual(large?.height ?? 0, 384, accuracy: 0.001)
    }

    func testNeverUpscalesBeyondNativeSize() {
        let presentation = MirrorPresentation()
        let viewport = presentation.viewport(
            frameWidth: 1000,
            frameHeight: 500,
            drawableWidth: 4000,
            drawableHeight: 4000
        )
        XCTAssertEqual(viewport?.width ?? 0, 1000, accuracy: 0.001)
        XCTAssertEqual(viewport?.height ?? 0, 500, accuracy: 0.001)
        XCTAssertEqual(viewport?.x ?? 0, 1500, accuracy: 0.001)
        XCTAssertEqual(viewport?.y ?? 0, 1750, accuracy: 0.001)
    }

    func testMarginOneFillsMatchingAspectExactly() {
        let presentation = MirrorPresentation(margin: 1.0)
        let viewport = presentation.viewport(
            frameWidth: 1000,
            frameHeight: 500,
            drawableWidth: 800,
            drawableHeight: 400
        )
        XCTAssertEqual(viewport?.width ?? 0, 800, accuracy: 0.001)
        XCTAssertEqual(viewport?.height ?? 0, 400, accuracy: 0.001)
        XCTAssertEqual(viewport?.x ?? 0, 0, accuracy: 0.001)
        XCTAssertEqual(viewport?.y ?? 0, 0, accuracy: 0.001)
    }

    func testUpscalingFillsTheDrawableWhenRequested() {
        let presentation = MirrorPresentation(margin: 1.0, allowsUpscaling: true)
        let viewport = presentation.viewport(
            frameWidth: 1000,
            frameHeight: 500,
            drawableWidth: 4000,
            drawableHeight: 2000
        )
        XCTAssertEqual(viewport?.width ?? 0, 4000, accuracy: 0.001)
        XCTAssertEqual(viewport?.height ?? 0, 2000, accuracy: 0.001)
        XCTAssertEqual(viewport?.x ?? 0, 0, accuracy: 0.001)
        XCTAssertEqual(viewport?.y ?? 0, 0, accuracy: 0.001)
    }

    func testRejectsInvalidSizes() {
        let presentation = MirrorPresentation()
        XCTAssertNil(presentation.viewport(
            frameWidth: 0,
            frameHeight: 100,
            drawableWidth: 100,
            drawableHeight: 100
        ))
        XCTAssertNil(presentation.viewport(
            frameWidth: 100,
            frameHeight: 100,
            drawableWidth: 0,
            drawableHeight: 0
        ))
    }
}
