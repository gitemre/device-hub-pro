import CoreGraphics
import XCTest
@testable import DeviceHubProKit

/// `DisplayShape` read from the real `dumpsys display` capture of the API 37
/// Pixel 9 Pro Fold emulator (`Fixtures/api37-emulator/adb-core/`, see
/// `AdbCoreFixtureTests` for the device): the unfolded fold lists its inner
/// panel (ON) and its cover panel (OFF), each with its rounded corners and
/// camera cutout. Expected values are spelled out here and cross-checked
/// against a second command where one exists, never computed by the parser
/// under test.
final class DisplayShapeTests: XCTestCase {
    private static let innerId = "local:4619827259835644672"
    private static let coverId = "local:4619827551948147201"

    private func fixture() throws -> String {
        try AdbCoreFixtureTests.text("shell-dumpsys-display.txt")
    }

    private func shapes() throws -> [DisplayShape] {
        DisplayShape.parse(dumpsysDisplay: try fixture())
    }

    private func shape(_ id: String) throws -> DisplayShape {
        try XCTUnwrap(shapes().first { $0.uniqueId == id })
    }

    /// The inner panel's `DisplayDeviceInfo{…}` line, byte-exact from the
    /// capture, for the tests that edit one field out of it.
    private func innerLine() throws -> String {
        try XCTUnwrap(
            fixture().split(separator: "\n").first { $0.contains("uniqueId=\"\(Self.innerId)\"") }
        ).description
    }

    // MARK: - The capture

    /// Both display devices, in dump order. Sizes agree with `wm size`
    /// (`shell-wm-size.txt`: 2076x2152) and with the cover the emulator was
    /// started with (`shell-getprop.txt`: `ro.boot.qemu.external.displays` =
    /// `1,1080,2424,390,0`); 390 dpi with `qemu.sf.lcd_density`.
    func testFixtureListsBothFoldPanels() throws {
        let shapes = try shapes()
        XCTAssertEqual(shapes.map(\.uniqueId), [Self.innerId, Self.coverId])

        let inner = shapes[0]
        XCTAssertEqual(inner.name, "Built-in Screen")
        XCTAssertEqual(inner.naturalSize, CGSize(width: 2076, height: 2152))
        XCTAssertEqual(inner.densityDpi, 390)
        XCTAssertEqual(inner.xDpi, 390)
        XCTAssertEqual(inner.yDpi, 390)
        XCTAssertEqual(inner.type, "INTERNAL")
        XCTAssertEqual(inner.state, "ON")
        XCTAssertTrue(inner.isOn)
        XCTAssertTrue(inner.isBuiltIn)

        let cover = shapes[1]
        XCTAssertEqual(cover.name, "Built-in Screen")
        XCTAssertEqual(cover.naturalSize, CGSize(width: 1080, height: 2424))
        XCTAssertEqual(cover.densityDpi, 390)
        XCTAssertEqual(cover.type, "INTERNAL")
        XCTAssertEqual(cover.state, "OFF")
        XCTAssertFalse(cover.isOn)
    }

    /// The radii match the framework config the emulator image ships
    /// (`cmd overlay lookup android android:array/
    /// config_roundedCornerTopRadiusArray`: `85.0px`, `115.0px`, in
    /// `config_displayUniqueIdArray` order; read by hand on the same VM, not
    /// committed as a fixture). The centers follow AOSP's
    /// `RoundedCorners.createRoundedCorner`: (r, r), (W − r, r),
    /// (W − r, H − r), (r, H − r) — inner 2076 − 85 = 1991, 2152 − 85 = 2067;
    /// cover 1080 − 115 = 965, 2424 − 115 = 2309.
    func testRoundedCornersCarryRadiusAndCenter() throws {
        let inner = try shape(Self.innerId)
        XCTAssertEqual(inner.topLeft, .init(radius: 85, centerX: 85, centerY: 85))
        XCTAssertEqual(inner.topRight, .init(radius: 85, centerX: 1991, centerY: 85))
        XCTAssertEqual(inner.bottomRight, .init(radius: 85, centerX: 1991, centerY: 2067))
        XCTAssertEqual(inner.bottomLeft, .init(radius: 85, centerX: 85, centerY: 2067))
        XCTAssertEqual(inner.maxCornerRadius, 85)

        let cover = try shape(Self.coverId)
        XCTAssertEqual(cover.topLeft, .init(radius: 115, centerX: 115, centerY: 115))
        XCTAssertEqual(cover.topRight, .init(radius: 115, centerX: 965, centerY: 115))
        XCTAssertEqual(cover.bottomRight, .init(radius: 115, centerX: 965, centerY: 2309))
        XCTAssertEqual(cover.bottomLeft, .init(radius: 115, centerX: 115, centerY: 2309))
        XCTAssertEqual(cover.maxCornerRadius, 115)
    }

    /// The spec is printed raw, marker included, exactly as the image's
    /// `config_displayCutoutPathArray` holds it (`cmd overlay lookup`), with
    /// the parser inputs beside it: density 2.4375 = 390 / 160.
    func testCutoutKeepsTheRawSpecAndItsParserInputs() throws {
        let inner = try shape(Self.innerId)
        XCTAssertEqual(inner.cutoutSpec, "m 2027,80 a 39.5,39.5 0 0 0 -79,0 39.5,39.5 0 0 0 79,0 z @left")
        XCTAssertEqual(inner.cutout, DisplayShape.Cutout(
            spec: "m 2027,80 a 39.5,39.5 0 0 0 -79,0 39.5,39.5 0 0 0 79,0 z @left",
            density: 2.4375,
            physicalWidth: 2076,
            physicalHeight: 2152,
            physicalPixelDisplaySizeRatio: 1,
            scale: 1
        ))

        let cover = try shape(Self.coverId)
        XCTAssertEqual(cover.cutout, DisplayShape.Cutout(
            spec: "m 581.5,86 a 41.5,41.5 0 0 0 -83,0 41.5,41.5 0 0 0 83,0 z @left",
            density: 2.4375,
            physicalWidth: 1080,
            physicalHeight: 2424
        ))
    }

    /// The cutout outlines, derived by hand from the spec text:
    ///
    /// Inner, `m 2027,80 a 39.5,39.5 0 0 0 -79,0 39.5,39.5 0 0 0 79,0 z
    /// @left`: `@left` puts the x origin at the left edge (no offset), there
    /// is no `@bottom`/`@center_vertical` (y origin at the top) and no `@dp`
    /// (pixels). The pen starts at (2027, 80); the first arc (r 39.5) ends 79
    /// to the left at (1948, 80) — a chord of 2r, so a half circle centred
    /// on its midpoint (1987.5, 80) — and the second arc returns to
    /// (2027, 80): a full circle, x 1987.5 ± 39.5 = 1948…2027, y 80 ± 39.5 =
    /// 40.5…119.5, a 79 × 79 box at (1948, 40.5).
    ///
    /// Cover, `m 581.5,86 a 41.5,41.5 0 0 0 -83,0 41.5,41.5 0 0 0 83,0 z
    /// @left`: the same circle shape, from (581.5, 86) to (498.5, 86) and
    /// back, centred at (540, 86) = the cover's horizontal centre (1080 / 2)
    /// with r 41.5: x 498.5…581.5, y 44.5…127.5, an 83 × 83 box at
    /// (498.5, 44.5).
    func testCutoutPathsAreTheReportedPunchHoles() throws {
        let inner = try XCTUnwrap(shape(Self.innerId).cutoutPath)
        assertRect(inner.boundingBoxOfPath, CGRect(x: 1948, y: 40.5, width: 79, height: 79))
        // A circle, not its box: the centre is inside, the box corner is not.
        XCTAssertTrue(inner.contains(CGPoint(x: 1987.5, y: 80)))
        XCTAssertFalse(inner.contains(CGPoint(x: 1950, y: 42.5)))

        let cover = try XCTUnwrap(shape(Self.coverId).cutoutPath)
        assertRect(cover.boundingBoxOfPath, CGRect(x: 498.5, y: 44.5, width: 83, height: 83))
        XCTAssertTrue(cover.contains(CGPoint(x: 540, y: 86)))
        XCTAssertFalse(cover.contains(CGPoint(x: 500.5, y: 46.5)))
    }

    /// The cutout grammar checked against the device's own arithmetic: the
    /// image's rect approximations (`cmd overlay lookup android
    /// android:array/config_displayCutoutApproximationRectArray`, one spec
    /// per display in `config_displayUniqueIdArray` order, captured from the
    /// same emulator) resolve to exactly the `boundingRect` Android computed
    /// from them and printed in `dumpsys display`: inner `Rect(1940, 0 -
    /// 2076, 136)` (an `@right` origin with `V`/`h`), cover `Rect(484, 20 -
    /// 596, 152)`.
    func testRectApproximationsResolveToTheDeviceBoundingRects() throws {
        let specs = try AdbCoreFixtureTests
            .text("shell-cmd-overlay-lookup-config_displayCutoutApproximationRectArray.txt")
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(specs, [
            "m 0,0 V 136 h -136 V 0 z @right",
            "m 484,20 h 112 v 132 h -112 z @left",
        ])

        let innerInfo = try XCTUnwrap(shape(Self.innerId).cutout)
        let inner = try XCTUnwrap(CutoutSpecification.path(
            spec: specs[0],
            density: CGFloat(innerInfo.density),
            physicalWidth: innerInfo.physicalWidth,
            physicalHeight: innerInfo.physicalHeight
        ))
        assertRect(inner.boundingBoxOfPath, CGRect(x: 1940, y: 0, width: 136, height: 136))

        let coverInfo = try XCTUnwrap(shape(Self.coverId).cutout)
        let cover = try XCTUnwrap(CutoutSpecification.path(
            spec: specs[1],
            density: CGFloat(coverInfo.density),
            physicalWidth: coverInfo.physicalWidth,
            physicalHeight: coverInfo.physicalHeight
        ))
        assertRect(cover.boundingBoxOfPath, CGRect(x: 484, y: 20, width: 112, height: 132))
    }

    /// Devices without adb's shell protocol end lines in `\r\n` (see
    /// `AdbCoreFixtureTests.testShellOutputThroughALegacyPtyParsesLikeTheOriginal`).
    func testCrLfOutputParsesLikeTheOriginal() throws {
        let translated = try fixture().replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(DisplayShape.parse(dumpsysDisplay: translated), try shapes())
    }

    // MARK: - Missing fields (SOURCE-DERIVED)

    /// SOURCE-DERIVED: `DisplayDeviceInfo.toString()` (AOSP
    /// `services/core/java/com/android/server/display/DisplayDeviceInfo.java`)
    /// appends `, roundedCorners …` only when the display has rounded-corner
    /// config, and before API 31 never. The real inner line with that field
    /// cut out must read with no corners and everything else intact.
    func testBlockWithoutRoundedCornersHasNoRadius() throws {
        let line = try innerLine()
        let field = try XCTUnwrap(line.range(of: ", roundedCorners RoundedCorners{["))
        let fieldEnd = try XCTUnwrap(line.range(of: "]}", range: field.upperBound..<line.endIndex))
        var trimmed = line
        trimmed.removeSubrange(field.lowerBound..<fieldEnd.upperBound)
        XCTAssertFalse(trimmed.contains("RoundedCorner"))

        let shapes = DisplayShape.parse(dumpsysDisplay: trimmed)
        XCTAssertEqual(shapes.count, 1)
        let shape = try XCTUnwrap(shapes.first)
        XCTAssertNil(shape.topLeft)
        XCTAssertNil(shape.topRight)
        XCTAssertNil(shape.bottomRight)
        XCTAssertNil(shape.bottomLeft)
        XCTAssertEqual(shape.maxCornerRadius, 0)
        XCTAssertEqual(shape.clipCornerRadius(scaledTo: CGSize(width: 1038, height: 1076)), 0)
        XCTAssertEqual(shape.naturalSize, CGSize(width: 2076, height: 2152))
        XCTAssertEqual(shape.state, "ON")
        XCTAssertEqual(shape.cutout?.spec, "m 2027,80 a 39.5,39.5 0 0 0 -79,0 39.5,39.5 0 0 0 79,0 z @left")
    }

    /// SOURCE-DERIVED: API 31–32 print `CutoutPathParserInfo{displayWidth=…
    /// displayHeight=… density={…} cutoutSpec={…} rotation={…} scale={…}}`
    /// with no physical size and no ratio (AOSP `android12-release`
    /// `DisplayCutout.java`), and their parser positions the spec in the
    /// display size. The real line with those keys cut out must resolve the
    /// same outline.
    func testApi31CutoutInfoFallsBackToTheDisplaySize() throws {
        var line = try innerLine()
        for key in ["physicalDisplayWidth=2076 ", "physicalDisplayHeight=2152 ", " physicalPixelDisplaySizeRatio={1.0}"] {
            let range = try XCTUnwrap(line.range(of: key), key)
            line.removeSubrange(range)
        }
        XCTAssertTrue(line.contains("displayHeight=2152 density={2.4375} cutoutSpec={"))
        XCTAssertTrue(line.contains("rotation={0} scale={1.0}}}"))

        let cutout = try XCTUnwrap(DisplayShape.parse(dumpsysDisplay: line).first?.cutout)
        XCTAssertEqual(cutout.physicalWidth, 2076)
        XCTAssertEqual(cutout.physicalHeight, 2152)
        XCTAssertEqual(cutout.physicalPixelDisplaySizeRatio, 1)
        let path = try XCTUnwrap(cutout.path)
        assertRect(path.boundingBoxOfPath, CGRect(x: 1948, y: 40.5, width: 79, height: 79))
    }

    func testEmptyOrGarbageInputHasNoShapes() {
        XCTAssertEqual(DisplayShape.parse(dumpsysDisplay: ""), [])
        XCTAssertEqual(DisplayShape.parse(dumpsysDisplay: "Can't find service: display\n"), [])
        XCTAssertEqual(DisplayShape.parse(dumpsysDisplay: "DisplayDeviceInfo{\n  DisplayDeviceInfo{\"x\""), [])
        // A block whose size does not read is skipped, not guessed.
        XCTAssertEqual(
            DisplayShape.parse(dumpsysDisplay: "  DisplayDeviceInfo{\"Built-in Screen\": uniqueId=\"local:0\", wide x tall, modeId 1}"),
            []
        )
    }

    /// A spec Android would reject (here an unknown command letter) gives no
    /// outline instead of a wrong one; the raw spec is still kept.
    func testUnparsableSpecHasNoPath() throws {
        var cutout = try XCTUnwrap(shape(Self.innerId).cutout)
        cutout.spec = "m 2027,80 x 39.5 z @left"
        XCTAssertNil(cutout.path)
    }

    // MARK: - Matching a frame

    /// The live frame picks the panel: the inner one in either orientation,
    /// the cover at its size (either orientation) and as scrcpy's downscaled
    /// 1080x2416 (sides rounded to multiples of 8; aspect 2.237 against
    /// 2.244).
    func testFrameSizeSelectsTheFoldPanel() throws {
        let shapes = try shapes()
        func pick(_ width: CGFloat, _ height: CGFloat) -> String? {
            DisplayShape.matching(frame: CGSize(width: width, height: height), in: shapes)?.uniqueId
        }
        XCTAssertEqual(pick(2076, 2152), Self.innerId)
        XCTAssertEqual(pick(2152, 2076), Self.innerId)
        XCTAssertEqual(pick(1038, 1076), Self.innerId)
        XCTAssertEqual(pick(1080, 2424), Self.coverId)
        XCTAssertEqual(pick(2424, 1080), Self.coverId)
        XCTAssertEqual(pick(1080, 2416), Self.coverId)
        // Square is 3.5% off the inner panel's 1.037: another display.
        XCTAssertNil(pick(1000, 1000))
        XCTAssertNil(pick(0, 0))
        XCTAssertNil(DisplayShape.matching(frame: CGSize(width: 1080, height: 2424), in: []))
    }

    /// A virtual display (a screen recorder's, or scrcpy's on some versions)
    /// sized like the stream has no corners: built-in panels come first even
    /// when the virtual one matches exactly.
    func testBuiltInPanelWinsOverAVirtualDisplayOfTheFrameSize() throws {
        var shapes = try shapes()
        shapes.insert(
            DisplayShape(uniqueId: "virtual:recorder", name: "recorder", width: 1080, height: 2416, type: "VIRTUAL", state: "ON"),
            at: 0
        )
        let picked = DisplayShape.matching(frame: CGSize(width: 1080, height: 2416), in: shapes)
        XCTAssertEqual(picked?.uniqueId, Self.coverId)
        // With no built-in panel of that shape, the virtual one is all there is.
        let other = DisplayShape.matching(frame: CGSize(width: 1080, height: 2416), in: [shapes[0]])
        XCTAssertEqual(other?.uniqueId, "virtual:recorder")
    }

    /// Two panels of one size: the lit one is on screen.
    func testLitPanelWinsATie() throws {
        let inner = try shape(Self.innerId)
        var dark = inner
        dark.uniqueId = "local:dark"
        dark.state = "OFF"
        XCTAssertEqual(DisplayShape.matching(frame: inner.naturalSize, in: [dark, inner])?.uniqueId, Self.innerId)
        let scaled = CGSize(width: 1038, height: 1076)
        XCTAssertEqual(DisplayShape.matching(frame: scaled, in: [dark, inner])?.uniqueId, Self.innerId)
    }

    /// The clip radius follows the frame's scale, in either orientation:
    /// half size halves 85 → 42.5; scrcpy's 1080x2416 cover frame is
    /// min(1080 / 1080, 2416 / 2424) = 0.9967 of the panel, 115 → 114.62.
    func testClipCornerRadiusScalesToTheFrame() throws {
        let inner = try shape(Self.innerId)
        XCTAssertEqual(inner.clipCornerRadius(scaledTo: CGSize(width: 2076, height: 2152)), 85)
        XCTAssertEqual(inner.clipCornerRadius(scaledTo: CGSize(width: 1038, height: 1076)), 42.5)
        XCTAssertEqual(inner.clipCornerRadius(scaledTo: CGSize(width: 1076, height: 1038)), 42.5)
        XCTAssertEqual(inner.clipCornerRadius(scaledTo: .zero), 0)

        let cover = try shape(Self.coverId)
        XCTAssertEqual(
            Double(cover.clipCornerRadius(scaledTo: CGSize(width: 1080, height: 2416))),
            115.0 * 2416 / 2424,
            accuracy: 1e-9
        )
    }

    /// Android sizes the top and bottom pairs separately; one clip radius
    /// takes the larger so every corner of the glass is rounded.
    func testClipRadiusIsTheLargestCorner() {
        let shape = DisplayShape(
            uniqueId: "local:0", name: "Built-in Screen", width: 1080, height: 2400,
            topLeft: .init(radius: 120, centerX: 120, centerY: 120),
            topRight: .init(radius: 120, centerX: 960, centerY: 120),
            bottomRight: .init(radius: 90, centerX: 990, centerY: 2310),
            bottomLeft: .init(radius: 90, centerX: 90, centerY: 2310)
        )
        XCTAssertEqual(shape.maxCornerRadius, 120)
        XCTAssertEqual(shape.clipCornerRadius(scaledTo: CGSize(width: 540, height: 1200)), 60)
    }

    // MARK: - AdbClient

    /// One read-only `dumpsys display`, parsed.
    func testAdbClientReadsShapesInOneDumpsys() async throws {
        let adb = try FakeAdb([.init("dumpsys display", output: try fixture())])
        let shapes = await adb.client.displayShapes(serial: "emulator-5554")
        XCTAssertEqual(shapes, try self.shapes())
        XCTAssertEqual(adb.calls, ["-s emulator-5554 shell dumpsys display"])
    }

    func testAdbClientFailureReadsAsNoShapes() async throws {
        let adb = try FakeAdb([.init("dumpsys display", output: "", exitCode: 1)])
        let shapes = await adb.client.displayShapes(serial: "emulator-5554")
        XCTAssertEqual(shapes, [])
    }

    // MARK: - Helpers

    private func assertRect(
        _ actual: CGRect,
        _ expected: CGRect,
        accuracy: CGFloat = 1e-6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, "minX", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, "minY", file: file, line: line)
        XCTAssertEqual(actual.maxX, expected.maxX, accuracy: accuracy, "maxX", file: file, line: line)
        XCTAssertEqual(actual.maxY, expected.maxY, accuracy: accuracy, "maxY", file: file, line: line)
    }
}
