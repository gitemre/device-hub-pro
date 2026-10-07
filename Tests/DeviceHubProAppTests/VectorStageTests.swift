import XCTest
import SwiftUI
@testable import DeviceHubProKit
@testable import DeviceHubProApp

/// The live vector body (device frame, Tier 2) on the stage: the camera
/// cutout the host draws over the video (`MirrorMetalView`'s black
/// sublayer), placed upright on an emulator's frame and turned by the
/// display rotation on a phone's posed frame; the fold strip under a
/// skinless foldable; and the chrome the stage picks
/// (`DeviceChromeResolver`, `DHP_FORCE_VECTOR_CHROME`).
///
/// Device shapes are the API 37 Pixel 9 Pro Fold emulator's real `dumpsys
/// display` capture (`DeviceHubProKitTests/Fixtures/api37-emulator/adb-core/
/// shell-dumpsys-display.txt`): the inner panel 2076x2152 with a cutout of
/// radius 39.5 centred at (1987.5, 80), bounds (1948, 40.5, 79, 79) in
/// natural pixels. Hosted in offscreen windows at 1x and 2x
/// (`ScaledTestWindow`).
@MainActor
final class VectorStageTests: XCTestCase {
    private static let inner = CGSize(width: 2076, height: 2152)
    private static let stage = CGSize(width: 1300, height: 866)
    private static let scales: [CGFloat] = [1, 2]
    /// The inner panel's cutout bounds, natural pixels, top-left based.
    private static let innerCutout = CGRect(x: 1948, y: 40.5, width: 79, height: 79)

    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DeviceHubProKitTests/Fixtures/api37-emulator/adb-core/shell-dumpsys-display.txt")

    private static func foldShapes() throws -> [DisplayShape] {
        DisplayShape.parse(dumpsysDisplay: try String(contentsOf: fixture, encoding: .utf8))
    }

    // MARK: - The cutout sublayer

    /// The Metal view holds a black shape sublayer only while it is given a
    /// cutout: filling its bounds, the outline flipped into the unflipped
    /// view's y-up layer, rasterized at the backing scale, and gone again
    /// when the cutout is.
    func testTheCutoutSublayerIsThereOnlyWithACutout() throws {
        for scale in Self.scales {
            let context = "\(scale)x"
            let view = MirrorMetalView(frame: .zero, device: MirrorRenderPipeline.systemDevice)
            let window = ScaledTestWindow.hosting(view, size: CGSize(width: 300, height: 600), scale: scale)
            defer { window.close() }
            let layer = try XCTUnwrap(view.layer, context)
            XCTAssertFalse(view.isFlipped, "\(context): an unflipped view, so its layer's y grows up")
            XCTAssertNil(view.cutoutLayer, context)

            // A 40 pt hole 20 pt from the top, at the view's horizontal centre.
            let hole = CGRect(x: 130, y: 20, width: 40, height: 40)
            view.cutout = CGPath(ellipseIn: hole, transform: nil)
            let shape = try XCTUnwrap(view.cutoutLayer, context)
            XCTAssertTrue(shape.superlayer === layer, "\(context): a sublayer of the video's own layer")
            XCTAssertEqual(shape.frame, layer.bounds, context)
            XCTAssertEqual(shape.contentsScale, scale, "\(context): rasterized at the backing scale")
            XCTAssertEqual(shape.fillColor, CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), context)
            let drawn = try XCTUnwrap(shape.path, context).boundingBoxOfPath
            assertRect(drawn, CGRect(x: 130, y: 600 - 60, width: 40, height: 40), accuracy: 1e-9, "\(context): flipped")

            // A new size flips the outline about the new height.
            view.setFrameSize(CGSize(width: 300, height: 500))
            assertRect(
                try XCTUnwrap(shape.path, context).boundingBoxOfPath,
                CGRect(x: 130, y: 500 - 60, width: 40, height: 40),
                accuracy: 1e-9,
                "\(context): resized"
            )
            XCTAssertEqual(shape.frame, layer.bounds, "\(context): resized")

            view.cutout = nil
            XCTAssertNil(view.cutoutLayer, context)
            XCTAssertNil(shape.superlayer, "\(context): removed")
        }
    }

    /// A skinless emulator's inner screen, upright: the body draws the
    /// panel's own hole over the video, where the device reports it, scaled
    /// to the laid-out video. It stays at the same place on the panel as the
    /// device turns: the wrapper turns the whole body, and the view's
    /// outline is the natural one, only at the new rest pose's scale.
    func testTheVectorStageDrawsAnEmulatorsCutoutOnItsPanel() async throws {
        let shapes = try Self.foldShapes()
        for scale in Self.scales {
            let hosted = try host(chrome: .vector, scale: scale)
            defer { hosted.window.close() }
            await hosted.model.workspace.mirror.mirrorViewState.loadDisplayShapes { shapes }
            for rotation in [0, 1] {
                let context = "\(scale)x, rotation \(rotation)"
                stream(hosted, natural: Self.inner, rotation: rotation)
                let view = try await settledVideo(hosted, context)
                let shape = try XCTUnwrap(view.cutoutLayer, "\(context): the inner panel reports a cutout")
                XCTAssertEqual(shape.contentsScale, scale, context)
                let expected = flipped(
                    scaled(Self.innerCutout, by: view.bounds.width / Self.inner.width),
                    height: view.bounds.height
                )
                let drawn = try XCTUnwrap(shape.path, context).boundingBoxOfPath
                assertRect(drawn, expected, accuracy: 1 / scale, context)
            }
        }
    }

    /// No device data, no hole.
    func testTheVectorStageDrawsNoCutoutWithoutDeviceShapes() async throws {
        let hosted = try host(chrome: .vector, scale: 2)
        defer { hosted.window.close() }
        stream(hosted, natural: Self.inner, rotation: 0)
        let view = try await settledVideo(hosted, "no shapes")
        XCTAssertNil(view.cutoutLayer)
    }

    /// The framed stage draws its skin's artwork, whose screen the stream
    /// fills; it never takes a host-drawn cutout.
    func testTheFramedStageDrawsNoCutout() async throws {
        let shapes = try Self.foldShapes()
        let hosted = try host(chrome: .skin(sdkSkin(named: "pixel_9_pro_fold")), scale: 2)
        defer { hosted.window.close() }
        await hosted.model.workspace.mirror.mirrorViewState.loadDisplayShapes { shapes }
        stream(hosted, natural: Self.inner, rotation: 0)
        let view = try await settledVideo(hosted, "framed")
        XCTAssertNil(view.cutoutLayer)
        XCTAssertFalse(view.layer?.isOpaque ?? true, "the framed video's transparent surface")
    }

    /// A phone's scrcpy frame arrives posed (rotation 0) in landscape. Until
    /// the display rotation is read, the hole's side is unknown and none is
    /// drawn; read as ROTATION_90, the inner panel's hole is turned with the
    /// screen: (x, y) → (y, W − x) of the 2076 px panel, bounds (40.5, 49,
    /// 79, 79) in the posed 2152x2076 frame.
    func testAPhonesCutoutWaitsForTheDisplayRotationAndTurnsWithIt() async throws {
        let shapes = try Self.foldShapes()
        let landscape = CGSize(width: Self.inner.height, height: Self.inner.width)
        for scale in Self.scales {
            let context = "\(scale)x"
            let session = FakePhysicalSession(serial: "VectorStageTests_Phone")
            let hosted = try host(chrome: .vector, scale: scale, session: session)
            defer { hosted.window.close() }
            await hosted.model.workspace.mirror.mirrorViewState.loadDisplayShapes { shapes }
            stream(hosted, natural: landscape, rotation: 0)

            var view = try await settledVideo(hosted, context)
            XCTAssertEqual(view.bounds.width / view.bounds.height, landscape.width / landscape.height, accuracy: 0.01, "\(context): posed, not uprighted")
            XCTAssertNil(hosted.model.workspace.mirror.mirrorViewState.displayRotation, context)
            XCTAssertNil(view.cutoutLayer, "\(context): the side is not known yet")

            await hosted.model.workspace.mirror.mirrorViewState.loadDisplayRotation { 1 }
            view = try await settledVideo(hosted, context)
            let shape = try XCTUnwrap(view.cutoutLayer, "\(context): ROTATION_90 places it")
            let turned = CGRect(x: 40.5, y: Self.inner.width - Self.innerCutout.maxX, width: 79, height: 79)
            let expected = flipped(scaled(turned, by: view.bounds.width / landscape.width), height: view.bounds.height)
            assertRect(try XCTUnwrap(shape.path, context).boundingBoxOfPath, expected, accuracy: 1 / scale, context)
        }
    }

    /// The vector body watches a phone's display rotation while it is shown
    /// (`MirrorController.watchDisplayRotation`), for a 180° turn the stream
    /// does not show: read as it appears and again at every interval, the
    /// inner panel reporting a cutout, and no longer once the body is gone.
    /// The flat stage showing the same phone reads none: the body is the
    /// rotation's only reader, so the watch lives on it, not on every
    /// `MirrorView`. The stub adb answers with the fixture; the shapes are
    /// already known, so no other `dumpsys display` runs.
    func testTheVectorBodyWatchesAPhonesRotationOnlyWhileShown() async throws {
        let shapes = try Self.foldShapes()
        // Stands in for a phone's adb serial: a placeholder, no device's.
        let serial = "0A1B2C3D4E5F"
        let adb = try makeStubAdb(arms: """
          "-s \(serial) shell dumpsys display")
            cat '\(Self.fixture.path)' ;;
        """)
        func reads() -> Int { adb.calls(containing: "dumpsys display").count }
        let model = AppModel.testing(adb: adb.client)
        model.workspace.window.showDeviceFrame = false
        let session = FakePhysicalSession(serial: serial)
        model.mirror.session = session
        model.context.device = .android(serial)
        model.mirror.displayRotationRefreshInterval = .milliseconds(20)
        await model.workspace.mirror.mirrorViewState.loadDisplayShapes { shapes }
        let content = MirrorStageContent(session: session, chrome: .vector, available: Self.stage)
        let host = NSHostingView(rootView: content.environment(model).environment(model.workspace).transaction { $0.animation = nil })
        let window = ScaledTestWindow.hosting(host, size: Self.stage, scale: 2)
        defer { window.close() }
        let hosted = Hosted(window: window, host: host, model: model, session: session)
        stream(hosted, natural: Self.inner, rotation: 0)

        _ = try await settledVideo(hosted, "flat")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reads(), 0, "the flat stage: ten intervals, no read")

        model.workspace.window.showDeviceFrame = true
        await waitUntil("the body's watch reads again at every interval") { reads() >= 4 }
        XCTAssertEqual(model.workspace.mirror.mirrorViewState.displayRotation, 0, "the fixture's mCurrentOrientation")
        let body = try await settledVideo(hosted, "vector")
        XCTAssertNotNil(body.cutoutLayer, "upright: ROTATION_0 places the hole")

        model.workspace.window.showDeviceFrame = false
        _ = try await settledVideo(hosted, "flat again")
        try await Task.sleep(for: .milliseconds(100))
        let stopped = reads()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reads(), stopped, "the watch ended with the body")
    }

    /// Without a reported display that fits the frame, the body is planned
    /// at `wm density`'s dpi, else the 420 default; the density arrives
    /// after the first frame, and the body is planned again with it (a
    /// narrower bezel at 160 dpi, so a larger screen in the same stage). The
    /// laid-out video follows the plan within a backing pixel both times.
    /// The metrics are generated input, not device output.
    func testTheVectorBodyFollowsTheDensityWhenItArrives() async throws {
        for scale in Self.scales {
            let context = "\(scale)x"
            let hosted = try host(chrome: .vector, scale: scale)
            defer { hosted.window.close() }
            stream(hosted, natural: Self.inner, rotation: 0)
            func expectedWidth() -> CGFloat {
                let plan = VectorDeviceView.composition(workspace: hosted.model.workspace, session: hosted.session, screen: Self.inner)
                let fit = PoseFit.scale(
                    angle: 0,
                    nativeSize: plan.layoutSize,
                    box: CGSize(width: Self.stage.width - 16, height: Self.stage.height - 16)
                )
                return Self.inner.width * fit
            }

            let before = try await settledVideo(hosted, context).bounds.width
            XCTAssertNil(hosted.model.workspace.mirror.mirrorViewState.displayDensityDpi, context)
            XCTAssertEqual(before, expectedWidth(), accuracy: 1 / scale, "\(context): at the default density")

            await hosted.model.workspace.mirror.mirrorViewState.loadDisplayMetrics {
                MirrorDisplayMetrics(width: 2076, height: 2152, dpi: 160)
            }
            XCTAssertEqual(hosted.model.workspace.mirror.mirrorViewState.displayDensityDpi, 160, context)
            let after = try await settledVideo(hosted, context).bounds.width
            XCTAssertEqual(after, expectedWidth(), accuracy: 1 / scale, "\(context): at wm density's 160 dpi")
            XCTAssertGreaterThan(after - before, 10, "\(context): the body was planned again")
        }
    }

    // MARK: - The fold strip

    /// A skinless foldable on the main stage is fitted above the fold
    /// control strip, as a skinned one is: the body's centre is the centre
    /// of the stage less the strip. The compact window's stage has no strip
    /// (spec §13): the body is centred in the whole stage.
    func testASkinlessFoldableShowsTheStripAndTheCompactWindowDoesNot() async throws {
        for scale in Self.scales {
            let pixel = 1 / scale
            let main = try host(chrome: .vector, scale: scale, foldControls: true)
            defer { main.window.close() }
            stream(main, natural: Self.inner, rotation: 0)
            let mainVideo = try await settledVideo(main, "\(scale)x, main stage")
            let fitted = Self.stage.height - FoldControlStrip.estimatedHeight - FoldControlStrip.stageBottomPadding
            // Window coordinates grow up: the fitted area is the stage's top.
            let mainRect = mainVideo.convert(mainVideo.bounds, to: nil)
            XCTAssertEqual(mainRect.midY, Self.stage.height - fitted / 2, accuracy: pixel, "\(scale)x: above the strip")
            XCTAssertEqual(mainRect.midX, Self.stage.width / 2, accuracy: pixel, "\(scale)x")

            let session = FakeMirrorSession()
            let compactContent = CompactMirrorView.stageContent(session: session, chrome: .vector, available: Self.stage)
            XCTAssertFalse(compactContent.showsFoldControls, "the compact window's stage")
            let compact = try host(content: compactContent, session: session, scale: scale)
            defer { compact.window.close() }
            stream(compact, natural: Self.inner, rotation: 0)
            let compactVideo = try await settledVideo(compact, "\(scale)x, compact")
            let compactRect = compactVideo.convert(compactVideo.bounds, to: nil)
            XCTAssertEqual(compactRect.midY, Self.stage.height / 2, accuracy: pixel, "\(scale)x: the whole stage")
        }
    }

    // MARK: - The chrome the stage picks

    /// `DHP_FORCE_VECTOR_CHROME=1` (exactly) turns the switch on.
    func testTheForceVectorChromeSwitchParses() {
        XCTAssertTrue(LaunchOptions(environment: ["DHP_FORCE_VECTOR_CHROME": "1"]).forceVectorChrome)
        for value in ["", "0", "true", "yes"] {
            XCTAssertFalse(LaunchOptions(environment: ["DHP_FORCE_VECTOR_CHROME": value]).forceVectorChrome, value)
        }
        XCTAssertFalse(LaunchOptions.none.forceVectorChrome)
    }

    /// A skinned AVD gets its skin and anything else Android the vector
    /// body, unless the switch forces the body on every Android device; an
    /// Apple device keeps the thin bezel either way.
    func testTheResolverPicksTheChrome() {
        let skin = ResolvedSkin(name: "pixel_9_pro_fold", directory: URL(fileURLWithPath: "/nonexistent"), source: .skinName, variants: [])
        let cards = [
            AvdCard(name: "Skinned", displayName: "Skinned", target: nil, skin: skin, isRunning: true, serial: "emulator-5554"),
            AvdCard(name: "Skinless", displayName: "Skinless", target: nil, skin: nil, isRunning: true, serial: "emulator-5556"),
        ]
        let apple = DeviceRef.apple("00000000-0000-4000-8000-00000000A001")
        func chrome(_ device: DeviceRef, force: Bool) -> DeviceChrome {
            DeviceChromeResolver.chrome(device: device, avdCards: cards, forceVector: force)
        }
        XCTAssertEqual(chrome(.android("emulator-5554"), force: false), .skin(skin))
        XCTAssertEqual(chrome(.android("emulator-5556"), force: false), .vector, "a skinless AVD")
        XCTAssertEqual(chrome(.android("0123456789AB"), force: false), .vector, "a phone")
        XCTAssertEqual(chrome(.android("emulator-5554"), force: true), .vector, "forced, even with a skin")
        XCTAssertEqual(chrome(apple, force: false), .thinBezel)
        XCTAssertEqual(chrome(apple, force: true), .thinBezel, "the switch is Android's")
    }

    /// The live stage reads the switch: a running skinned AVD shows its
    /// skin (the framed video's transparent surface), and under
    /// `DHP_FORCE_VECTOR_CHROME` the vector body (an opaque video, with
    /// the panel's hole drawn over it).
    func testTheLiveStageFollowsTheForceVectorSwitch() async throws {
        let skin = try sdkSkin(named: "pixel_9_pro_fold")
        let shapes = try Self.foldShapes()
        for force in [false, true] {
            let context = force ? "forced" : "not forced"
            let model = AppModel.testing(launch: LaunchOptions(forceVectorChrome: force))
            model.workspace.window.showDeviceFrame = true
            model.catalog.avdCards = [
                AvdCard(name: "Fold", displayName: "Fold", target: nil, skin: skin, isRunning: true, serial: "emulator-5554"),
            ]
            let session = FakeMirrorSession()
            model.mirror.session = session
            model.context.device = .android("emulator-5554")
            await model.workspace.mirror.mirrorViewState.loadDisplayShapes { shapes }
            let host = NSHostingView(rootView: LiveDetailView(device: .android("emulator-5554"))
                .environment(model).environment(model.workspace)
                .transaction { $0.animation = nil })
            let window = ScaledTestWindow.hosting(host, size: CGSize(width: 1300, height: 900), scale: 2)
            defer { window.close() }
            let hosted = Hosted(window: window, host: host, model: model, session: session)
            stream(hosted, natural: Self.inner, rotation: 0)
            let view = try await settledVideo(hosted, context)
            XCTAssertEqual(view.layer?.isOpaque, force, "\(context): the vector body's video is opaque, the framed one's not")
            XCTAssertEqual(view.cutoutLayer != nil, force, "\(context): only the vector body draws the hole")
        }
    }

    // MARK: - Hosting

    private struct Hosted {
        let window: NSWindow
        let host: NSView
        let model: AppModel
        let session: any MirrorSessionProtocol
    }

    /// `MirrorStageContent` in `chrome` in an offscreen window of the stage's
    /// size at `scale`, showing `session` (an emulator's by default).
    private func host(
        chrome: DeviceChrome,
        scale: CGFloat,
        session: any MirrorSessionProtocol = FakeMirrorSession(),
        foldControls: Bool = false
    ) throws -> Hosted {
        try host(
            content: MirrorStageContent(
                session: session,
                chrome: chrome,
                available: Self.stage,
                showsFoldControls: foldControls
            ),
            session: session,
            scale: scale
        )
    }

    private func host(content: MirrorStageContent, session: any MirrorSessionProtocol, scale: CGFloat) throws -> Hosted {
        let model = AppModel.testing()
        model.workspace.window.showDeviceFrame = true
        let host = NSHostingView(rootView: content.environment(model).environment(model.workspace).transaction { $0.animation = nil })
        let window = ScaledTestWindow.hosting(host, size: Self.stage, scale: scale)
        return Hosted(window: window, host: host, model: model, session: session)
    }

    /// Streams a frame of `natural` turned `rotation` quarter turns and
    /// settles the stage on it (as `MirrorMetalView.draw` does).
    private func stream(_ hosted: Hosted, natural: CGSize, rotation: Int) {
        let posed = rotation % 2 == 1 ? CGSize(width: natural.height, height: natural.width) : natural
        hosted.session.frames.put(Frame(
            data: Data(count: Int(posed.width * posed.height) * 4),
            width: Int(posed.width),
            height: Int(posed.height),
            seq: 0,
            rotation: rotation
        ))
        hosted.model.workspace.mirror.mirrorViewState.devicePixelSize = posed
        hosted.model.workspace.mirror.mirrorViewState.deviceRotation = rotation
        hosted.model.workspace.mirror.stagePose.settle(rotation: rotation)
    }

    /// The hosted video once SwiftUI has applied the latest change.
    private func settledVideo(_ hosted: Hosted, _ context: String) async throws -> MirrorMetalView {
        // Best effort: the sleep fails only on cancellation. SwiftUI applies
        // an observed change on its next update.
        try? await Task.sleep(for: .milliseconds(50))
        hosted.host.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(mirrorView(in: hosted.host), context)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.bounds.width, 10, context)
        return view
    }

    private func mirrorView(in view: NSView) -> MirrorMetalView? {
        if let mirror = view as? MirrorMetalView { return mirror }
        for subview in view.subviews {
            if let mirror = mirrorView(in: subview) { return mirror }
        }
        return nil
    }

    private func sdkSkin(named name: String) throws -> ResolvedSkin {
        guard let skins = SkinLocator.skinsDirectory() else {
            throw XCTSkip("no Android SDK skins directory")
        }
        let entry = try XCTUnwrap(
            SkinResolver.catalog(skinsDirectory: skins).first(where: { $0.name == name }),
            "missing skin \(name)"
        )
        return ResolvedSkin(name: entry.name, directory: entry.directory, source: .skinName, variants: entry.variants)
    }

    private func scaled(_ rect: CGRect, by scale: CGFloat) -> CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }

    /// A top-left based rect in a y-up space of `height`.
    private func flipped(_ rect: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func assertRect(
        _ rect: CGRect,
        _ expected: CGRect,
        accuracy: CGFloat,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(rect.minX, expected.minX, accuracy: accuracy, "\(context): x of \(rect) vs \(expected)", file: file, line: line)
        XCTAssertEqual(rect.minY, expected.minY, accuracy: accuracy, "\(context): y of \(rect) vs \(expected)", file: file, line: line)
        XCTAssertEqual(rect.width, expected.width, accuracy: accuracy, "\(context): width of \(rect) vs \(expected)", file: file, line: line)
        XCTAssertEqual(rect.height, expected.height, accuracy: accuracy, "\(context): height of \(rect) vs \(expected)", file: file, line: line)
    }
}
