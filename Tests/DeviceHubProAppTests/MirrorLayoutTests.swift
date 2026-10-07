import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// Hit-testing and rendering share `MirrorLayout`. These pin that a click
/// lands on the frame pixel the renderer drew under it, on Retina backing
/// scales, in flat and framed modes, in every rotation and at every zoom.
final class MirrorLayoutTests: XCTestCase {
    /// EMC-01's scenario: flat mirror (device frame off), landscape stream,
    /// a 1400×900 pt stage on a 2x display. The renderer used to fit in
    /// drawable pixels (capped at 1 frame pixel per drawable pixel) while
    /// input fitted in points (capped at 1 per point), so the edges of the
    /// visible image mapped to x = 171 and 2229.
    func testFlatLandscapeEdgesMapToTheFrameEdgesOnRetina() throws {
        let layout = try XCTUnwrap(flat(posed: (2400, 1080), view: CGSize(width: 1400, height: 900), scale: 2))

        let viewport = layout.drawableViewport
        XCTAssertEqual(viewport.width, 2800, accuracy: 0.001)
        XCTAssertEqual(viewport.height, 1260, accuracy: 0.001)

        let midY = 900 - (layout.imageRect.midY)
        XCTAssertEqual(layout.framePoint(atViewPoint: CGPoint(x: 0, y: midY), isFlipped: false)?.x, 0)
        XCTAssertEqual(layout.framePoint(atViewPoint: CGPoint(x: 1399.9, y: midY), isFlipped: false)?.x, 2399)
        XCTAssertEqual(layout.framePoint(atViewPoint: CGPoint(x: 700, y: 450), isFlipped: false)?.x, 1200)
        XCTAssertEqual(layout.framePoint(atViewPoint: CGPoint(x: 700, y: 450), isFlipped: false)?.y, 540)
    }

    /// MR-01's scenario: Physical Size zoom (one device pixel per Mac point)
    /// with the frame off. The renderer drew the image at half that size on
    /// a 2x display; now both sides show and map 1 frame pixel per point.
    func testPhysicalSizeShowsOneFramePixelPerPointOnRetina() throws {
        let view = CGSize(width: 1125, height: 2500)
        let layout = try XCTUnwrap(flat(posed: (1080, 2400), view: view, scale: 2))

        XCTAssertEqual(layout.imageRect.width, 1080, accuracy: 0.001)
        XCTAssertEqual(layout.imageRect.height, 2400, accuracy: 0.001)
        XCTAssertEqual(layout.drawableViewport.width, 2160, accuracy: 0.001, "2 drawable pixels per frame pixel at 2x")
        XCTAssertEqual(layout.drawableViewport.height, 4800, accuracy: 0.001)
        XCTAssertEqual(layout.pointsPerFramePixel, 1, accuracy: 0.0001)

        // 300 pt above the centre is 300 frame pixels above it (it used to
        // land 300 pixels above the centre of an image drawn at half size).
        let center = CGPoint(x: view.width / 2, y: view.height / 2)
        let above = try XCTUnwrap(layout.framePoint(
            atViewPoint: CGPoint(x: center.x, y: center.y + 300),
            isFlipped: false
        ))
        XCTAssertEqual(above.x, 540)
        XCTAssertEqual(above.y, 1200 - 300)
    }

    /// A small stream (Wear 384×384) in a larger flat stage is shown at one
    /// frame pixel per point, not at half that on Retina.
    func testASmallStreamIsNotHalvedOnRetina() throws {
        let layout = try XCTUnwrap(flat(posed: (384, 384), view: CGSize(width: 600, height: 600), scale: 2))
        XCTAssertEqual(layout.imageRect.width, 384, accuracy: 0.001)
        XCTAssertEqual(layout.imageRect.minX, 108, accuracy: 0.001)
    }

    func testAPointOutsideTheImageMapsToNothing() throws {
        let layout = try XCTUnwrap(flat(posed: (2400, 1080), view: CGSize(width: 1400, height: 900), scale: 2))
        // Letterbox above the image.
        XCTAssertNil(layout.framePoint(atViewPoint: CGPoint(x: 700, y: 880), isFlipped: false))
        XCTAssertNil(layout.framePoint(atViewPoint: CGPoint(x: -1, y: 450), isFlipped: false))
    }

    func testFlippedAndUnflippedViewsMapTheSamePixel() throws {
        let layout = try XCTUnwrap(flat(posed: (1080, 2400), view: CGSize(width: 500, height: 800), scale: 2))
        let unflipped = layout.framePoint(atViewPoint: CGPoint(x: 250, y: 700), isFlipped: false)
        let flipped = layout.framePoint(atViewPoint: CGPoint(x: 250, y: 100), isFlipped: true)
        XCTAssertEqual(unflipped?.x, flipped?.x)
        XCTAssertEqual(unflipped?.y, flipped?.y)
    }

    /// The renderer's drawable viewport and the input mapping come from one
    /// fit: every frame pixel's centre, drawn where the renderer puts it, is
    /// mapped back to that very pixel — flat and framed/thin-bezel modes,
    /// all four rotations, 1x/2x/3x backing and the stage's zoom levels.
    func testEveryDrawnPixelMapsBackToItselfAcrossModesScalesRotationsAndZoom() throws {
        struct Mode {
            let margin: Double
            let allowsUpscaling: Bool
            let uprights: Bool
        }
        let modes = [
            Mode(margin: 1.0, allowsUpscaling: false, uprights: false),   // flat stage
            Mode(margin: 0.96, allowsUpscaling: false, uprights: false),  // artwork-missing fallback
            Mode(margin: 1.0, allowsUpscaling: true, uprights: true),     // framed / thin bezel
        ]
        let posedSizes = [(1080, 2400), (2400, 1080), (2208, 1840), (384, 384)]
        let stage = CGSize(width: 700, height: 820)
        let zoomLevels = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

        for mode in modes {
            for posed in posedSizes {
                for rotation in 0..<4 {
                    for scale in [1.0, 2.0, 3.0] {
                        for zoom in zoomLevels {
                            let view = CGSize(width: stage.width * zoom, height: stage.height * zoom)
                            let layout = try XCTUnwrap(MirrorLayout(
                                posedWidth: posed.0,
                                posedHeight: posed.1,
                                rotation: mode.uprights ? rotation : 0,
                                margin: mode.margin,
                                allowsUpscaling: mode.allowsUpscaling,
                                viewSize: view,
                                drawableSize: CGSize(width: view.width * scale, height: view.height * scale)
                            ))
                            assertDrawnPixelsMapBack(layout, scale: scale)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func flat(posed: (Int, Int), view: CGSize, scale: CGFloat) -> MirrorLayout? {
        MirrorLayout(
            posedWidth: posed.0,
            posedHeight: posed.1,
            rotation: 0,
            margin: 1.0,
            allowsUpscaling: false,
            viewSize: view,
            drawableSize: CGSize(width: view.width * scale, height: view.height * scale)
        )
    }

    /// Takes a few upright pixels (corners and centre), finds where the
    /// renderer draws their centres in drawable pixels, converts that to an
    /// AppKit (unflipped) view point and maps it back.
    private func assertDrawnPixelsMapBack(
        _ layout: MirrorLayout,
        scale: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let upright = layout.uprightSize
        let viewport = layout.drawableViewport
        let samples = [
            (0, 0), (upright.width - 1, 0), (0, upright.height - 1),
            (upright.width - 1, upright.height - 1), (upright.width / 2, upright.height / 2),
        ]
        for (ux, uy) in samples {
            let drawableX = viewport.x + (Double(ux) + 0.5) / Double(upright.width) * viewport.width
            let drawableY = viewport.y + (Double(uy) + 0.5) / Double(upright.height) * viewport.height
            let viewPoint = CGPoint(
                x: drawableX / scale,
                y: layout.viewSize.height - drawableY / scale
            )
            let expected = TextureRotation.posedPoint(
                x: ux,
                y: uy,
                posedWidth: layout.posedWidth,
                posedHeight: layout.posedHeight,
                rotation: layout.rotation
            )
            let mapped = layout.framePoint(atViewPoint: viewPoint, isFlipped: false)
            XCTAssertEqual(mapped?.x, Int32(expected.x), "\(layout) upright (\(ux), \(uy))", file: file, line: line)
            XCTAssertEqual(mapped?.y, Int32(expected.y), "\(layout) upright (\(ux), \(uy))", file: file, line: line)
        }
    }
}
