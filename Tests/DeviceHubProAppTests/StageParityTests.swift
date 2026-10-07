import XCTest
import AppKit
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The stage's Device Hub parity (audit 2026-09-29, "Stage2"): the direct
/// screenshot and its banner, the pill's Home, the booting and stopping
/// stages, the zoom hint and the ⌥⌘-drag pan, and the stopped hero's shadow.
@MainActor
final class StageParityTests: XCTestCase {
    // MARK: - Screenshot file

    /// Device Hub's name, measured: "Screenshot AQA probe stage-a 29.09.2026
    /// at 13.13.30.png" (Turkish locale), separators macOS names may hold.
    func testTheScreenshotFileNameIsDeviceHubs() throws {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 29
        components.hour = 13; components.minute = 13; components.second = 30
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let date = try XCTUnwrap(calendar.date(from: components))

        XCTAssertEqual(
            ScreenshotFile.name(device: "AQA probe stage-a", date: date, locale: Locale(identifier: "tr_TR"), timeZone: utc),
            "Screenshot AQA probe stage-a 29.09.2026 at 13.13.30.png"
        )
        let english = ScreenshotFile.name(device: nil, date: date, locale: Locale(identifier: "en_US"), timeZone: utc)
        XCTAssertFalse(english.contains("/"), english)
        XCTAssertFalse(english.contains(":"), english)
        XCTAssertTrue(english.hasPrefix("Screenshot "), english)
        XCTAssertTrue(english.hasSuffix(".png"), english)
        XCTAssertEqual(ScreenshotFile.sanitized("a/b: c"), "a.b. c", "no separators a file name cannot hold")
    }

    func testAScreenshotNeverOverwritesAnother() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StageParityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = ScreenshotFile.uniqueURL(named: "Screenshot x.png", in: directory)
        XCTAssertEqual(first.lastPathComponent, "Screenshot x.png")
        try Data("1".utf8).write(to: first)
        let second = ScreenshotFile.uniqueURL(named: "Screenshot x.png", in: directory)
        XCTAssertEqual(second.lastPathComponent, "Screenshot x 2.png")
        try Data("2".utf8).write(to: second)
        XCTAssertEqual(ScreenshotFile.uniqueURL(named: "Screenshot x.png", in: directory).lastPathComponent, "Screenshot x 3.png")
    }

    /// The macOS screenshot folder when it exists, else the Desktop.
    func testTheScreenshotFolderIsTheMacsOrTheDesktop() throws {
        let directory = FileManager.default.temporaryDirectory
        XCTAssertEqual(
            ScreenshotFile.defaultDirectory(configured: directory.path).standardizedFileURL.path,
            directory.standardizedFileURL.path
        )
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        XCTAssertEqual(ScreenshotFile.defaultDirectory(configured: "/no/such/folder"), desktop)
        XCTAssertEqual(ScreenshotFile.defaultDirectory(configured: nil), desktop)
        XCTAssertEqual(ScreenshotFile.defaultDirectory(configured: ""), desktop)
    }

    // MARK: - The capture button saves at once

    private final class Recorder {
        var revealed: [URL] = []
    }

    private func makeCapture() -> (capture: CaptureController, directory: URL, context: ActiveDeviceContext, recorder: Recorder) {
        let picker = TestPicker()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StageParityTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        picker.autoSaveDirectory = directory
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let context = ActiveDeviceContext()
        let capture = CaptureController(
            adbClient: nil,
            status: StatusCenter(),
            preferences: AppPreferences(defaults: .scratch()),
            context: context,
            pasteboard: TestPasteboard(),
            picker: picker
        )
        let recorder = Recorder()
        capture.revealInFinder = { recorder.revealed.append($0) }
        capture.displayName = { _ in "AQA probe stage-a" }
        return (capture, directory, context, recorder)
    }

    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data("shot".utf8)

    /// One click on the capture button writes the file and raises the
    /// banner; the editor stays closed.
    func testTheCaptureButtonSavesAtOnceAndRaisesTheBanner() async throws {
        let (capture, directory, context, _) = makeCapture()
        context.device = .apple("00000000-0000-4000-8000-000000000001")
        capture.simulatorScreenshot = { Self.png }

        await capture.takeScreenshot()

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, 1)
        let name = try XCTUnwrap(files.first)
        XCTAssertTrue(name.hasPrefix("Screenshot AQA probe stage-a "), name)
        XCTAssertTrue(name.hasSuffix(".png"), name)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), Self.png, "the raw shot, byte for byte")
        XCTAssertEqual(capture.savedScreenshot?.url.lastPathComponent, name)
        XCTAssertNil(capture.annotationEditRequest, "no editor on the default path")
    }

    /// Annotate is the button's right-click item: the editor opens and
    /// nothing is written until it saves.
    func testAnnotateOpensTheEditorAndWritesNothing() async throws {
        let (capture, directory, context, _) = makeCapture()
        context.device = .apple("00000000-0000-4000-8000-000000000001")
        capture.simulatorScreenshot = { Self.png }

        await capture.annotateScreenshot()

        XCTAssertEqual(capture.annotationEditRequest?.png, Self.png)
        XCTAssertNil(capture.savedScreenshot)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    /// The banner stays for its time (Device Hub's: about three seconds),
    /// and Open in Finder selects the file and takes it down.
    func testTheBannerTimesOutAndOpensFinder() async throws {
        let (capture, _, context, recorder) = makeCapture()
        context.device = .apple("00000000-0000-4000-8000-000000000001")
        capture.simulatorScreenshot = { Self.png }
        capture.bannerDuration = .milliseconds(150)

        await capture.takeScreenshot()
        XCTAssertNotNil(capture.savedScreenshot)
        await waitUntil(timeout: 3, "the banner leaves") { capture.savedScreenshot == nil }

        await capture.takeScreenshot()
        let url = try XCTUnwrap(capture.savedScreenshot?.url)
        capture.revealSavedScreenshot()
        XCTAssertEqual(recorder.revealed, [url])
        XCTAssertNil(capture.savedScreenshot)
    }

    /// A second shot replaces the first's banner and restarts its time.
    func testASecondShotReplacesTheBanner() async throws {
        let (capture, directory, context, _) = makeCapture()
        context.device = .apple("00000000-0000-4000-8000-000000000001")
        capture.simulatorScreenshot = { Self.png }

        await capture.takeScreenshot()
        let first = try XCTUnwrap(capture.savedScreenshot)
        await capture.takeScreenshot()
        let second = try XCTUnwrap(capture.savedScreenshot)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.url, second.url, "no overwrite")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    /// A folder that cannot be written is an error alert, and no banner.
    func testAnUnwritableFolderIsAnError() async throws {
        let picker = TestPicker()
        picker.autoSaveDirectory = URL(fileURLWithPath: "/no/such/folder/for/screenshots", isDirectory: true)
        let status = StatusCenter()
        let context = ActiveDeviceContext()
        let capture = CaptureController(
            adbClient: nil,
            status: status,
            preferences: AppPreferences(defaults: .scratch()),
            context: context,
            pasteboard: TestPasteboard(),
            picker: picker
        )
        context.device = .apple("00000000-0000-4000-8000-000000000001")
        capture.simulatorScreenshot = { Self.png }

        await capture.takeScreenshot()

        XCTAssertNil(capture.savedScreenshot)
        XCTAssertTrue(status.errorMessage?.hasPrefix("Could not save the screenshot") == true, status.errorMessage ?? "nil")
    }

    /// A physical iPhone's screenshot, which arrives as bytes from
    /// devicectl, is saved and announced like the others.
    func testAScreenshotAnotherToolTookIsSavedToo() throws {
        let (capture, directory, context, _) = makeCapture()
        context.device = .apple("00000000-0000-4000-8000-000000000002")

        capture.editScreenshot(Self.png)

        XCTAssertNotNil(capture.savedScreenshot)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        XCTAssertNil(capture.annotationEditRequest)
    }

    // MARK: - The pill's Home

    func testHomeIsAvailableWhereTheDeviceHasOne() {
        typealias Pill = DeviceControlPill
        let android = DeviceRef.android("emulator-5554")
        let simulator = DeviceRef.apple("00000000-0000-4000-8000-000000000001")
        XCTAssertFalse(Pill.homeAvailable(device: nil, isPhysicalView: false, capabilities: [], physicalControlReady: true))
        XCTAssertTrue(Pill.homeAvailable(device: android, isPhysicalView: false, capabilities: [], physicalControlReady: false))
        XCTAssertTrue(Pill.homeAvailable(device: simulator, isPhysicalView: false, capabilities: [.hardwareButtons], physicalControlReady: false))
        XCTAssertFalse(Pill.homeAvailable(device: simulator, isPhysicalView: false, capabilities: [.mirror], physicalControlReady: false), "a view-only simulator has no buttons")
        XCTAssertTrue(Pill.homeAvailable(device: simulator, isPhysicalView: true, capabilities: [], physicalControlReady: true))
        XCTAssertFalse(Pill.homeAvailable(device: simulator, isPhysicalView: true, capabilities: [.hardwareButtons], physicalControlReady: false), "a physical iPhone needs Control")
    }

    // MARK: - Booting, stopping

    /// Device Hub shows a bare spinner for the boot and a caption once the
    /// display is being connected: only that phase has one.
    func testTheBootingStageCaptionsOnlyTheDisplayConnection() {
        typealias Phase = SimulatorStagePhase
        XCTAssertEqual(Phase.connectingDisplayLabel, "Connecting display…")
        XCTAssertNil(Phase.booting("Starting…").bootCaption)
        XCTAssertNil(Phase.booting("Migrating data…").bootCaption)
        XCTAssertEqual(Phase.booting(Phase.label(for: .waitingOnHomeScreen, platform: "iOS")).bootCaption, "Connecting display…")
        XCTAssertNil(Phase.stopping.bootCaption)
        XCTAssertNil(Phase.live.bootCaption)
    }

    /// A stop the app started leaves the live view at once: the listing
    /// says Booted for a moment more, which showed a "not running" panel.
    func testAStopInFlightLeavesTheLiveStageAtOnce() {
        typealias Phase = SimulatorStagePhase
        func phase(_ operation: SimulatorLifecycleController.Operation?) -> Phase {
            Phase.resolve(isAvailable: true, availabilityError: nil, runState: .ready, operation: operation, platform: "iOS")
        }
        XCTAssertEqual(phase(nil), .live)
        XCTAssertEqual(phase(.stopping), .stopping)
        XCTAssertEqual(phase(.restarting), .booting("Starting…"))
    }

    /// The stopped subtitle carries no state suffix while it stops either
    /// (Device Hub goes straight to the stopped page).
    func testTheStoppingSubtitleIsTheStoppedOne() {
        XCTAssertEqual(SimulatorDetailView.subtitle(osLabel: "iOS 26.5", phase: .stopping), "iOS 26.5 Simulator")
        XCTAssertEqual(SimulatorDetailView.subtitle(osLabel: "iOS 26.5", phase: .stopped(activity: nil)), "iOS 26.5 Simulator")
        XCTAssertEqual(SimulatorDetailView.subtitle(osLabel: "iOS 26.5", phase: .unresponsive), "iOS 26.5 Simulator · Not Responding")
    }

    /// An iPad is "iPadOS 26.5" in Device Hub.
    func testAnIpadIsIpadOS() throws {
        let booted = try XCTUnwrap(
            try SimulatorFixtures.devices("simctl-list-j-devices.booted-after-rename.json")
                .first { $0.udid == SimulatorFixtures.udid }
        )
        let runtimes = try SimctlParsing.runtimes(fromListJSON: Data(contentsOf: SimulatorFixtures.url("simctl-list-j-runtimes.json")))
        let typeIdentifier = try XCTUnwrap(booted.deviceTypeIdentifier)
        let phone = SimulatorEntry(
            device: booted,
            runtimes: runtimes,
            deviceTypes: [SimulatorDeviceType(identifier: typeIdentifier, name: "iPhone", productFamily: "iPhone")],
            defaultDeviceUDIDs: []
        )
        let pad = SimulatorEntry(
            device: booted,
            runtimes: runtimes,
            deviceTypes: [SimulatorDeviceType(identifier: typeIdentifier, name: "iPad (A16)", productFamily: "iPad")],
            defaultDeviceUDIDs: []
        )
        XCTAssertTrue(try XCTUnwrap(phone.osLabel).hasPrefix("iOS "))
        XCTAssertTrue(try XCTUnwrap(pad.osLabel).hasPrefix("iPadOS "))
    }

    // MARK: - The stopped device's picture

    /// The picture is macOS's own for the model, cropped to what it draws:
    /// a phone is tall, a tablet nearly square, an Apple TV a flat wide box;
    /// an unknown model has none (the Apple chrome stands in).
    func testTheStoppedPictureIsTheSystemsDeviceIcon() throws {
        let phone = try XCTUnwrap(SystemDeviceIcon.image(forModelIdentifier: "iPhone18,3"))
        // The crop keeps the whole faint contact shadow (alpha > 0), which is
        // wider than the phone: Device Hub's picture is 183.5 x 200 pt.
        XCTAssertLessThan(phone.size.width / phone.size.height, 1.0, "a phone is taller than wide")
        XCTAssertGreaterThan(phone.size.width / phone.size.height, 0.85)
        let pad = try XCTUnwrap(SystemDeviceIcon.image(forModelIdentifier: "iPad15,7"))
        XCTAssertGreaterThan(pad.size.width / pad.size.height, 0.7)
        XCTAssertLessThan(pad.size.width / pad.size.height, 1.3)
        let tv = try XCTUnwrap(SystemDeviceIcon.image(forModelIdentifier: "AppleTV5,3"))
        XCTAssertGreaterThan(tv.size.width / tv.size.height, 1.6, "a set-top box is wide")
        XCTAssertNil(SystemDeviceIcon.image(forModelIdentifier: "NoSuchModel99,9"))
        XCTAssertNil(SystemDeviceIcon.image(forModelIdentifier: nil))
        XCTAssertNil(SystemDeviceIcon.image(forModelIdentifier: ""))
    }

    func testTheIconsContentIsFoundByItsAlpha() throws {
        let width = 40, height = 30
        var data = [UInt8](repeating: 0, count: width * height * 4)
        // An opaque block at columns 10...19, rows 5...11 from the top.
        for y in 5...11 { for x in 10...19 { data[(y * width + x) * 4 + 3] = 255 } }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try data.withUnsafeMutableBytes { raw -> CGImage in
            let context = try XCTUnwrap(CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            return try XCTUnwrap(context.makeImage())
        }
        let bounds = try XCTUnwrap(SystemDeviceIcon.contentBounds(of: image))
        XCTAssertEqual(bounds.width, 10)
        XCTAssertEqual(bounds.height, 7)
        XCTAssertEqual(bounds.minX, 10)
        XCTAssertNotNil(image.cropping(to: bounds))
    }

    // MARK: - Zoom: hint and pan

    func testTheZoomHintFollowsTheZoomAndTheRememberedClose() {
        let window = WindowState()
        XCTAssertFalse(window.showsZoomHint(dismissed: false), "fit")
        window.stageZoom = 1.0
        XCTAssertFalse(window.showsZoomHint(dismissed: false))
        window.stageZoom = 2.0
        XCTAssertTrue(window.showsZoomHint(dismissed: false))
        XCTAssertFalse(window.showsZoomHint(dismissed: true), "closed once, never again")
        window.stageZoom = nil
        window.stageZoom = 2.0
        XCTAssertFalse(window.showsZoomHint(dismissed: true), "still closed after the stage was at fit")
    }

    @MainActor
    func testTheClosedZoomHintIsPersisted() {
        let defaults = UserDefaults.scratch()
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.zoomHintDismissed)
        preferences.setZoomHintDismissed(true)
        XCTAssertTrue(AppPreferences(defaults: defaults).zoomHintDismissed)
    }

    func testOptionCommandDragPans() {
        typealias Support = StageScrollSupport
        XCTAssertTrue(Support.isPanGesture([.option, .command]))
        XCTAssertFalse(Support.isPanGesture([.command]))
        XCTAssertFalse(Support.isPanGesture([.option]))
        XCTAssertFalse(Support.isPanGesture([.option, .command, .control]), "control is a right click")
        XCTAssertTrue(Support.isPanGesture([.option, .command, .capsLock]))

        // The picture follows the pointer: dragging right and down moves
        // the visible rect left and up (flipped: y grows downward).
        let origin = Support.pannedOrigin(
            from: CGPoint(x: 100, y: 100), dx: 30, dy: 20, isFlipped: true,
            visible: CGSize(width: 400, height: 300), document: CGSize(width: 1000, height: 800)
        )
        XCTAssertEqual(origin, CGPoint(x: 70, y: 80))
        // Not flipped: y grows upward, so the same drag raises the origin.
        XCTAssertEqual(
            Support.pannedOrigin(
                from: CGPoint(x: 100, y: 100), dx: 30, dy: 20, isFlipped: false,
                visible: CGSize(width: 400, height: 300), document: CGSize(width: 1000, height: 800)
            ),
            CGPoint(x: 70, y: 120)
        )
        // Held inside the document.
        XCTAssertEqual(
            Support.pannedOrigin(
                from: CGPoint(x: 10, y: 10), dx: 500, dy: 500, isFlipped: true,
                visible: CGSize(width: 400, height: 300), document: CGSize(width: 1000, height: 800)
            ),
            CGPoint(x: 0, y: 0)
        )
        XCTAssertEqual(
            Support.pannedOrigin(
                from: CGPoint(x: 590, y: 490), dx: -500, dy: -500, isFlipped: true,
                visible: CGSize(width: 400, height: 300), document: CGSize(width: 1000, height: 800)
            ),
            CGPoint(x: 600, y: 500)
        )
    }

    // MARK: - The stopped hero

    /// Device Hub's hero is 200 pt with the device 194 pt of it, over a
    /// contact shadow a few points tall, not the old halo.
    func testTheHeroIsTheDeviceOverAContactShadow() {
        XCTAssertEqual(SkinHero.height, 200)
        XCTAssertEqual(SkinHero.deviceHeight, 194)
        XCTAssertLessThanOrEqual(ParityMetrics.contactShadowHeight, 12)
        XCTAssertGreaterThan(SkinHero.height - SkinHero.deviceHeight, 0)
    }

    /// The pill sits where DH's does relative to the stage: the main stage
    /// keeps 41 pt under the device (DH centres it at y 497 of 983).
    func testTheMainStageCentresTheDeviceLikeDeviceHub() {
        let window: CGFloat = 983, toolbar: CGFloat = 52
        let centre = (toolbar + (window - ParityMetrics.mainStagePillBand)) / 2
        XCTAssertEqual(centre, 497, accuracy: 0.6)
        // The banner floats 7 pt above the pill (DH: card bottom 932, pill top 939).
        XCTAssertEqual(window - ParityMetrics.stageBannerBottomInset, 932, accuracy: 0.5)
    }

    /// A Dynamic-Island device type says so in its own capabilities, and its
    /// hero draws the island: a black capsule at the top of the placeholder
    /// screen (measured against DH's stopped iPhone 17).
    func testTheIslandIsDrawnOnAPlaceholderScreen() async throws {
        let bundle = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone 17.simdevicetype")
        let deviceKit = AppleDeviceKit()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: bundle.path)
                && FileManager.default.fileExists(atPath: deviceKit.root.path),
            "needs Xcode's iPhone 17 device type and DeviceKit"
        )
        let profile = try XCTUnwrap(SimulatorDisplayProfile.read(deviceTypeBundle: bundle))
        XCTAssertTrue(profile.hasDynamicIsland)
        let frame = try XCTUnwrap(AppleChromeFrameProvider(deviceKit: deviceKit).frame(deviceTypeBundle: bundle, display: profile))
        XCTAssertTrue(frame.hasDynamicIsland)

        let plan = DeviceCompositionPlanner.appleChrome(frame)
        let cache = SkinThumbnailCache()
        let rendered = await cache.renderedVectorImage(for: plan, height: SkinHero.deviceHeight)
        let image = try XCTUnwrap(rendered)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        // The screen's top centre is the island (black), a little lower the
        // placeholder's blue.
        let scale = CGFloat(cg.height) / image.size.height
        let centreX = cg.width / 2
        let island = try Self.pixel(cg, x: centreX, y: Int(9 * scale))
        let below = try Self.pixel(cg, x: centreX, y: Int(80 * scale))
        XCTAssertLessThan(Int(island[0]) + Int(island[1]) + Int(island[2]), 60, "the island: \(island)")
        XCTAssertGreaterThan(Int(below[2]), Int(below[0]) + 30, "the wallpaper: \(below)")
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return data
    }
}
