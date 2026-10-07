import XCTest
import AppKit
import ImageIO
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// `CaptureController` without an `AppModel`: screenshots read the mirrored
/// device from the context, the annotation editor and the diagnostics
/// bundle ask the injected picker, copies land on the injected pasteboard,
/// and the diagnostics bundle follows the live selection rather than the
/// mirrored device. Every adb here is a stub script; no test reaches a
/// real adb.
@MainActor
final class CaptureControllerTests: XCTestCase {
    /// The controller on its own foundation objects, each one readable.
    @MainActor
    private struct Harness {
        let status = StatusCenter()
        let preferences = AppPreferences(defaults: .scratch())
        let context = ActiveDeviceContext()
        let pasteboard = TestPasteboard()
        let picker = TestPicker()
        let capture: CaptureController

        init(adb: AdbClient?) {
            capture = CaptureController(
                adbClient: adb,
                status: status,
                preferences: preferences,
                context: context,
                pasteboard: pasteboard,
                picker: picker
            )
        }
    }

    /// What the stub's `screencap -p` prints: a PNG signature and a body.
    private static let shotPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data("shot".utf8)

    /// A stub adb that answers `screencap -p` on `emulator-5554` with
    /// `shotPNG`; every other call fails.
    private func makeScreencapAdb() throws -> StubAdb {
        try makeStubAdb(arms: #"""
          "-s emulator-5554 exec-out screencap -p")
            printf '\211PNG\r\n\032\nshot' ;;
        """#)
    }

    /// A stub adb whose `screencap -p` on `emulator-5554` prints `capture`
    /// and whose `dumpsys display` prints `dumpsysDisplay` (when given);
    /// every other call fails.
    private func makeScreencapAdb(capture: Data, dumpsysDisplay: String? = nil) throws -> StubAdb {
        let directory = try Self.temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let shot = directory.appendingPathComponent("capture.png")
        try capture.write(to: shot)
        var arms = """
          "-s emulator-5554 exec-out screencap -p")
            cat '\(shot.path)' ;;
        """
        if let dumpsysDisplay {
            let dump = directory.appendingPathComponent("dumpsys-display.txt")
            try Data(dumpsysDisplay.utf8).write(to: dump)
            arms += """

              "-s emulator-5554 shell dumpsys display")
                cat '\(dump.path)' ;;
            """
        }
        return try makeStubAdb(arms: arms)
    }

    // MARK: - Fixture data

    /// The API 37 Pixel 9 Pro Fold emulator's real `dumpsys display`
    /// (inner panel 2076x2152, radius 85; cover 1080x2424, radius 115, its
    /// punch hole centred at (540, 86), r 41.5; `mCurrentOrientation=0`).
    private static func foldDumpsys() throws -> String {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DeviceHubProKitTests/Fixtures/api37-emulator/adb-core/shell-dumpsys-display.txt")
        return try String(contentsOf: fixture, encoding: .utf8)
    }

    private static func foldShapes() throws -> [DisplayShape] {
        DisplayShape.parse(dumpsysDisplay: try foldDumpsys())
    }

    private static let red: [UInt8] = [255, 0, 0, 255]

    /// A solid red PNG (generated input, not device output).
    private static func solidPNG(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    /// An image's pixels as sRGB RGBA bytes, top row first.
    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let offset = (y * width + x) * 4
            return Array(bytes[offset..<offset + 4])
        }
    }

    private static func pixels(_ png: Data) throws -> Pixels {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn)
        return Pixels(width: image.width, height: image.height, bytes: bytes)
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Annotation editor

    func testCancelledSavePanelKeepsTheEditorOpen() throws {
        let harness = Harness(adb: nil)
        harness.capture.annotationEditRequest = AnnotationEditRequest(png: Data([0x89]))

        XCTAssertEqual(harness.capture.saveAnnotatedScreenshot(Data([1, 2, 3])), .cancelled)

        XCTAssertNotNil(harness.capture.annotationEditRequest, "the annotations must survive a cancelled panel")
        XCTAssertEqual(harness.picker.suggestedNames.count, 1)
        let name = try XCTUnwrap(harness.picker.suggestedNames.first)
        XCTAssertTrue(name.hasPrefix("devicehubpro-") && name.hasSuffix(".png"), "suggested \(name)")
        XCTAssertNil(harness.status.errorMessage)
    }

    func testChosenDestinationSavesAndClosesTheEditor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let harness = Harness(adb: nil)
        harness.picker.destination = directory.appendingPathComponent("shot.png")
        harness.capture.annotationEditRequest = AnnotationEditRequest(png: Data([0x89]))

        XCTAssertEqual(harness.capture.saveAnnotatedScreenshot(Data([1, 2, 3])), .saved)

        XCTAssertNil(harness.capture.annotationEditRequest)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("shot.png")), Data([1, 2, 3]))
    }

    func testSaveWithoutAnOpenEditorAsksNothing() {
        let harness = Harness(adb: nil)

        XCTAssertEqual(harness.capture.saveAnnotatedScreenshot(Data([1])), .cancelled)
        XCTAssertTrue(harness.picker.suggestedNames.isEmpty)
    }

    func testCancelClosesTheEditor() {
        let harness = Harness(adb: nil)
        harness.capture.annotationEditRequest = AnnotationEditRequest(png: Data([0x89]))

        harness.capture.cancelAnnotationEditing()

        XCTAssertNil(harness.capture.annotationEditRequest)
    }

    // MARK: - Screenshots

    func testScreenshotOpensTheEditorOnTheRawShot() async throws {
        let adb = try makeScreencapAdb()
        let harness = Harness(adb: adb.client)
        harness.context.serial = "emulator-5554"

        await harness.capture.annotateScreenshot()

        XCTAssertEqual(harness.capture.annotationEditRequest?.png, Self.shotPNG)
        XCTAssertEqual(adb.calls, ["-s emulator-5554 exec-out screencap -p"])
        XCTAssertNil(harness.status.errorMessage)
    }

    func testCopyWritesTheShotToThePasteboard() async throws {
        let adb = try makeScreencapAdb()
        let harness = Harness(adb: adb.client)
        harness.context.serial = "emulator-5554"

        await harness.capture.copyScreenshotToClipboard()

        XCTAssertEqual(harness.pasteboard.png, Self.shotPNG)
        XCTAssertNil(harness.capture.annotationEditRequest, "a copy opens no editor")
        XCTAssertNil(harness.status.errorMessage)
    }

    /// A shot that does not decode cannot be framed: the raw shot is kept
    /// and the flash says why.
    func testAnUndecodableShotFallsBackToTheRawShotWithAFlash() async throws {
        let adb = try makeScreencapAdb()
        let harness = Harness(adb: adb.client)
        harness.preferences.setIncludeDeviceFrameInScreenshots(true)
        harness.capture.displayShapesProvider = { (try? Self.foldShapes()) ?? [] }
        harness.context.serial = "emulator-5554"

        await harness.capture.annotateScreenshot()

        XCTAssertEqual(harness.capture.annotationEditRequest?.png, Self.shotPNG)
        XCTAssertEqual(
            harness.status.statusMessage,
            "Device frame unavailable — continuing without it: The screenshot could not be decoded as an image."
        )
        XCTAssertEqual(harness.status.statusKind, .outcome)
        XCTAssertNil(harness.status.errorMessage)
        XCTAssertEqual(adb.calls, ["-s emulator-5554 exec-out screencap -p"], "nothing else is read for it")
    }

    // MARK: - Framing without a skin

    /// A device without a skin (here no AVD at all, as for a phone) is
    /// framed in the vector body its reported displays plan. The capture is
    /// generated input (a solid red 1080x2424 image, the fold cover's size);
    /// the shapes are the fold's real `dumpsys display`: the cover gives a
    /// 3.3 mm (50.669 px) phone body, 1181.339 x 2525.339, the corner 115
    /// and the hole centred at (540, 86) of the screen. In the panel's own
    /// orientation nothing but the capture is read from adb.
    func testASkinlessDeviceWithShapesIsFramedInItsBody() async throws {
        let adb = try makeScreencapAdb(capture: try Self.solidPNG(width: 1080, height: 2424))
        let harness = Harness(adb: adb.client)
        harness.preferences.setIncludeDeviceFrameInScreenshots(true)
        harness.capture.displayShapesProvider = { (try? Self.foldShapes()) ?? [] }
        harness.context.serial = "emulator-5554"

        await harness.capture.annotateScreenshot()

        XCTAssertNil(harness.status.statusMessage, "framed without a fallback")
        let image = try Self.pixels(XCTUnwrap(harness.capture.annotationEditRequest?.png))
        XCTAssertEqual(image.width, 1182)
        XCTAssertEqual(image.height, 2526)
        XCTAssertEqual(image.pixel(50 + 540, 50 + 86), [0, 0, 0, 255], "the hole's centre")
        XCTAssertEqual(image.pixel(50 + 540, 50 + 1200), Self.red, "the capture")
        XCTAssertEqual(image.pixel(0, 0)[3], 0, "outside the body")
        XCTAssertEqual(image.pixel(30, 1263), [1, 1, 1, 255], "the glass")
        XCTAssertEqual(adb.calls, ["-s emulator-5554 exec-out screencap -p"])
    }

    /// A landscape capture of the portrait cover reads the rotation once
    /// and turns the hole with it: at `ROTATION_90` the cover's (540, 86)
    /// is (86, 540) of the 2424x1080 screen. The `dumpsys display` is the
    /// fold's real capture with `mCurrentOrientation` edited to 1
    /// (generated input, not device output); unedited (0, which contradicts
    /// a landscape capture) the hole is left out rather than misplaced.
    func testALandscapeCaptureTurnsTheHoleByTheReadRotation() async throws {
        let turned = try Self.foldDumpsys().replacingOccurrences(
            of: "mCurrentOrientation=0",
            with: "mCurrentOrientation=1"
        )
        for (dumpsys, expectsHole) in [(turned, true), (try Self.foldDumpsys(), false)] {
            let adb = try makeScreencapAdb(
                capture: try Self.solidPNG(width: 2424, height: 1080),
                dumpsysDisplay: dumpsys
            )
            let harness = Harness(adb: adb.client)
            harness.preferences.setIncludeDeviceFrameInScreenshots(true)
            harness.capture.displayShapesProvider = { (try? Self.foldShapes()) ?? [] }
            harness.context.serial = "emulator-5554"

            await harness.capture.annotateScreenshot()

            XCTAssertNil(harness.status.statusMessage)
            let image = try Self.pixels(XCTUnwrap(harness.capture.annotationEditRequest?.png))
            XCTAssertEqual(image.width, 2526)
            XCTAssertEqual(image.height, 1182)
            XCTAssertEqual(
                image.pixel(50 + 86, 50 + 540),
                expectsHole ? [0, 0, 0, 255] : Self.red,
                expectsHole ? "the turned hole" : "no hole at a contradicting rotation"
            )
            XCTAssertEqual(image.pixel(50 + 540, 50 + 86), Self.red, "not where the upright hole would be")
            XCTAssertEqual(adb.calls(containing: "dumpsys display").count, 1, "one rotation read")
        }
    }

    /// A simulator with an Apple chrome is framed in it, as the stage draws
    /// it: at 1 px per unit, iPhone 17 Pro's `phone11` frame is 1368 x 2730
    /// with the 1206 x 2622 screen from (81, 54), its corner clipped (the
    /// frame here has no artwork: the display's radius stands in for the
    /// outline). Turned with the device (landscape left) the frame is
    /// 2730 x 1368, and a capture the interface kept portrait (the home
    /// screen) is turned into it. The capture is generated input.
    func testASimulatorIsFramedInItsAppleChrome() async throws {
        let frame = try AppleChromeStageTests.iPhone17ProFrame()
        for (capture, deviceTurns, size) in [
            (CGSize(width: 1206, height: 2622), 0, CGSize(width: 1368, height: 2730)),
            (CGSize(width: 1206, height: 2622), 1, CGSize(width: 2730, height: 1368)),
            (CGSize(width: 2622, height: 1206), 1, CGSize(width: 2730, height: 1368)),
        ] {
            let harness = Harness(adb: nil)
            harness.preferences.setIncludeDeviceFrameInScreenshots(true)
            harness.context.device = .apple("00000000-0000-4000-8000-0000000C4A0E")
            let png = try Self.solidPNG(width: Int(capture.width), height: Int(capture.height))
            harness.capture.simulatorScreenshot = { png }
            harness.capture.appleChromeCapture = {
                CaptureController.AppleChromeCapture(frame: frame, deviceTurns: deviceTurns, reported: nil)
            }

            await harness.capture.annotateScreenshot()

            let context = "\(capture) at \(deviceTurns)"
            XCTAssertNil(harness.status.statusMessage, context)
            let image = try Self.pixels(XCTUnwrap(harness.capture.annotationEditRequest?.png))
            XCTAssertEqual(CGSize(width: image.width, height: image.height), size, context)
            XCTAssertEqual(image.pixel(image.width / 2, image.height / 2), Self.red, "\(context): the screen")
            XCTAssertEqual(image.pixel(0, 0)[3], 0, "\(context): outside the body")
            let cornerX: Int = deviceTurns == 0 ? 83 : 56
            let cornerY: Int = deviceTurns == 0 ? 56 : 83
            XCTAssertNotEqual(image.pixel(cornerX, cornerY), Self.red, "\(context): the screen's corner is clipped")
        }
    }

    /// A device that reported no displays is framed in a square-cornered
    /// body (by design: no invented corner), without a hole, at the
    /// default 420 dpi's 3.3 mm (54.567 px).
    func testADeviceWithoutShapesIsFramedWithASquareScreen() async throws {
        let adb = try makeScreencapAdb(capture: try Self.solidPNG(width: 1080, height: 2400))
        let harness = Harness(adb: adb.client)
        harness.preferences.setIncludeDeviceFrameInScreenshots(true)
        harness.context.serial = "emulator-5554"

        await harness.capture.annotateScreenshot()

        XCTAssertNil(harness.status.statusMessage)
        let image = try Self.pixels(XCTUnwrap(harness.capture.annotationEditRequest?.png))
        XCTAssertEqual(image.width, 1190)
        XCTAssertEqual(image.height, 2510)
        XCTAssertEqual(image.pixel(55 + 1, 55 + 1), Self.red, "the screen's corner is square")
        XCTAssertEqual(image.pixel(55 + 540, 55 + 86), Self.red, "no hole")
        XCTAssertEqual(image.pixel(0, 0)[3], 0, "the body's own corner is round")
    }

    /// A skinned AVD's framed shot gains the device's camera hole: the fold
    /// cover's (540, 86), r 41.5, on the `pixel_9_pro_fold/closed` display.
    /// Reads the installed SDK skin and skips without it; the capture is
    /// generated input.
    func testASkinnedShotGainsTheDevicesHole() async throws {
        guard let skins = SkinLocator.skinsDirectory(),
              let entry = SkinResolver.catalog(skinsDirectory: skins).first(where: { $0.name == "pixel_9_pro_fold" })
        else {
            throw XCTSkip("pixel_9_pro_fold is not installed")
        }
        let closed = try XCTUnwrap(entry.variants.first(where: { $0.id == "closed" }))
        let display = try XCTUnwrap(DeviceFrameRenderer.spec(for: closed, display: XCTUnwrap(closed.layout?.preferred))).displayRect
        let root = try Self.temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let avdDirectory = root.appendingPathComponent("avd/CaptureFold.avd", isDirectory: true)
        try FileManager.default.createDirectory(at: avdDirectory, withIntermediateDirectories: true)
        try Data("skin.path=\(entry.directory.path)\n".utf8).write(to: avdDirectory.appendingPathComponent("config.ini"))
        let adb = try makeScreencapAdb(capture: try Self.solidPNG(width: 1080, height: 2424))
        let status = StatusCenter()
        let preferences = AppPreferences(defaults: .scratch())
        preferences.setIncludeDeviceFrameInScreenshots(true)
        let context = ActiveDeviceContext(avdHome: root.appendingPathComponent("avd", isDirectory: true))
        context.serial = "emulator-5554"
        context.avdName = "CaptureFold"
        let capture = CaptureController(
            adbClient: adb.client,
            status: status,
            preferences: preferences,
            context: context,
            pasteboard: TestPasteboard(),
            picker: TestPicker()
        )
        capture.displayShapesProvider = { (try? Self.foldShapes()) ?? [] }

        await capture.annotateScreenshot()

        XCTAssertNil(status.statusMessage, "framed in the skin")
        let image = try Self.pixels(XCTUnwrap(capture.annotationEditRequest?.png))
        let scale = display.width / 1080
        let centre = (x: Int(display.minX + 540 * scale), y: Int(display.minY + 86 * scale))
        XCTAssertEqual(image.pixel(centre.x, centre.y), [0, 0, 0, 255], "the hole")
        XCTAssertEqual(image.pixel(centre.x, centre.y + Int(60 * scale)), Self.red, "below it")
        XCTAssertEqual(adb.calls, ["-s emulator-5554 exec-out screencap -p"])
    }

    /// Tier 2 live check 4, bug 2: the open fold at ROTATION_90 (a
    /// 2152x2076 capture) is framed in its skin turned counter-clockwise,
    /// as the stage shows it (2274x2204, transparent outside the body), the
    /// inner panel's hole (1987.5, 80) turned with the capture to (80,
    /// 88.5) of the display at (62, 66), after one rotation read. When the
    /// rotation cannot be read it is framed in the vector body instead of
    /// being saved raw. Reads the installed SDK skin and skips without it;
    /// the capture is generated input, the `dumpsys display` the fold's
    /// real capture with `mCurrentOrientation` edited to 1 (generated).
    func testALandscapeOpenFoldIsFramedInItsTurnedSkin() async throws {
        guard let skins = SkinLocator.skinsDirectory(),
              let entry = SkinResolver.catalog(skinsDirectory: skins).first(where: { $0.name == "pixel_9_pro_fold" })
        else {
            throw XCTSkip("pixel_9_pro_fold is not installed")
        }
        let turned = try Self.foldDumpsys().replacingOccurrences(
            of: "mCurrentOrientation=0",
            with: "mCurrentOrientation=1"
        )
        for dumpsys in [turned, nil] {
            let root = try Self.temporaryDirectory()
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let avdDirectory = root.appendingPathComponent("avd/CaptureFold.avd", isDirectory: true)
            try FileManager.default.createDirectory(at: avdDirectory, withIntermediateDirectories: true)
            try Data("skin.path=\(entry.directory.path)\n".utf8).write(to: avdDirectory.appendingPathComponent("config.ini"))
            let adb = try makeScreencapAdb(capture: try Self.solidPNG(width: 2152, height: 2076), dumpsysDisplay: dumpsys)
            let status = StatusCenter()
            let preferences = AppPreferences(defaults: .scratch())
            preferences.setIncludeDeviceFrameInScreenshots(true)
            let context = ActiveDeviceContext(avdHome: root.appendingPathComponent("avd", isDirectory: true))
            context.serial = "emulator-5554"
            context.avdName = "CaptureFold"
            let capture = CaptureController(
                adbClient: adb.client,
                status: status,
                preferences: preferences,
                context: context,
                pasteboard: TestPasteboard(),
                picker: TestPicker()
            )
            capture.displayShapesProvider = { (try? Self.foldShapes()) ?? [] }

            await capture.annotateScreenshot()

            let label = dumpsys == nil ? "rotation unread" : "ROTATION_90"
            XCTAssertNil(status.statusMessage, label)
            let image = try Self.pixels(XCTUnwrap(capture.annotationEditRequest?.png))
            XCTAssertEqual(image.pixel(0, 0)[3], 0, "\(label): framed, transparent outside the body")
            XCTAssertEqual(adb.calls(containing: "dumpsys display").count, 1, "\(label): one rotation read")
            if dumpsys != nil {
                XCTAssertEqual(image.width, 2274, label)
                XCTAssertEqual(image.height, 2204, label)
                XCTAssertEqual(image.pixel(62 + 80, 66 + 88), [0, 0, 0, 255], "the turned hole")
                XCTAssertEqual(image.pixel(62 + 80, 66 + 88 + 60), Self.red, "below it")
                XCTAssertEqual(image.pixel(1137, 1102), Self.red, "the screen")
            } else {
                // The vector body of the 2152x2076 capture (a 66.024 px
                // foldable bezel), without a hole: the turn is unknown.
                XCTAssertEqual(image.width, 2285, label)
                XCTAssertEqual(image.height, 2209, label)
                XCTAssertEqual(image.pixel(66 + 80, 66 + 88), Self.red, "\(label): no hole")
            }
        }
    }

    func testScreenshotFailureSetsTheErrorAndOpensNoEditor() async throws {
        let adb = try makeStubAdb(arms: "")
        let harness = Harness(adb: adb.client)
        harness.context.serial = "emulator-5554"

        await harness.capture.annotateScreenshot()

        XCTAssertNil(harness.capture.annotationEditRequest)
        XCTAssertNotNil(harness.status.errorMessage)
    }

    func testCopyFailureSetsTheErrorAndLeavesThePasteboard() async throws {
        let adb = try makeStubAdb(arms: "")
        let harness = Harness(adb: adb.client)
        harness.context.serial = "emulator-5554"
        harness.pasteboard.setString("kept")

        await harness.capture.copyScreenshotToClipboard()

        XCTAssertEqual(harness.pasteboard.text, "kept")
        XCTAssertNil(harness.pasteboard.png)
        XCTAssertNotNil(harness.status.errorMessage)
    }

    func testNothingIsCapturedWithoutAMirroredDevice() async throws {
        let adb = try makeScreencapAdb()
        let harness = Harness(adb: adb.client)

        await harness.capture.annotateScreenshot()
        await harness.capture.copyScreenshotToClipboard()

        XCTAssertTrue(adb.calls.isEmpty)
        XCTAssertNil(harness.capture.annotationEditRequest)
        XCTAssertNil(harness.pasteboard.png)
    }

    // MARK: - Diagnostics bundle

    func testCancelledDiagnosticsPanelCollectsNothing() async throws {
        let adb = try makeStubAdb(arms: "")
        let harness = Harness(adb: adb.client)
        harness.capture.liveSelectionSerialProvider = { "emulator-5554" }

        await harness.capture.downloadDiagnosticsBundle()

        XCTAssertEqual(harness.picker.suggestedNames.count, 1)
        XCTAssertTrue(adb.calls.isEmpty, "a cancelled panel must not collect: \(adb.calls)")
        XCTAssertFalse(harness.capture.isCollectingDiagnostics)
        XCTAssertNil(harness.status.errorMessage)
        XCTAssertNil(harness.status.statusMessage)
    }

    func testDiagnosticsFollowTheLiveSelectionNotTheMirroredDevice() async throws {
        let adb = try makeStubAdb(arms: "")
        let harness = Harness(adb: adb.client)
        harness.context.serial = "emulator-5554"
        harness.capture.liveSelectionSerialProvider = { "emulator-5556" }

        await harness.capture.downloadDiagnosticsBundle()

        let name = try XCTUnwrap(harness.picker.suggestedNames.first)
        XCTAssertTrue(name.hasPrefix("emulator-5556-diagnostics-"), "suggested \(name)")
    }

    func testDiagnosticsWithoutALiveSelectionAskNothing() async throws {
        let adb = try makeStubAdb(arms: "")
        let harness = Harness(adb: adb.client)
        // Mirrored, but the stage shows no live device.
        harness.context.serial = "emulator-5554"

        await harness.capture.downloadDiagnosticsBundle()

        XCTAssertTrue(harness.picker.suggestedNames.isEmpty)
        XCTAssertTrue(adb.calls.isEmpty)
    }

    // MARK: - AppModel wiring

    func testModelCollectsDiagnosticsFromItsLiveSelection() async throws {
        let adb = try makeStubAdb(arms: "")
        let environment = AppEnvironment.testing(adb: adb.client)
        let picker = try XCTUnwrap(environment.picker as? TestPicker)
        let model = AppModel(environment: environment)
        model.inventory.devices = [.online("emulator-5554"), .online("emulator-5556")]
        model.context.serial = "emulator-5554"
        model.deviceSelection = .device("emulator-5556")

        await model.workspace.capture.downloadDiagnosticsBundle()

        let name = try XCTUnwrap(picker.suggestedNames.first)
        XCTAssertTrue(name.hasPrefix("emulator-5556-diagnostics-"), "suggested \(name)")
        XCTAssertTrue(adb.calls.isEmpty)
    }

    func testModelCopiesOntoItsEnvironmentPasteboard() async throws {
        let adb = try makeScreencapAdb()
        let environment = AppEnvironment.testing(adb: adb.client)
        let pasteboard = try XCTUnwrap(environment.pasteboard as? TestPasteboard)
        let model = AppModel(environment: environment)
        model.context.serial = "emulator-5554"

        await model.workspace.capture.copyScreenshotToClipboard()

        XCTAssertEqual(pasteboard.png, Self.shotPNG)
    }
}
