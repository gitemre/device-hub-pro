import XCTest
import AppKit
import SwiftUI
@testable import DeviceHubProKit
@testable import DeviceHubProApp

/// The device illustrations of the stage's no-mirror panels:
/// - the live stage once nothing attaches (`ConnectingView`, after Stop
///   Mirror or a failed attach) draws the device above its status: a running
///   AVD as its stopped page draws it, a phone from the displays its model
///   last reported, nothing for an Apple device;
/// - the booting panel (`AvdBootingView`) draws a skinless AVD's body;
/// - a skinless AVD's hero (`AvdHero`) never flashes the grey "nothing
///   known" card while its `config.ini` is read, and draws an AVD whose
///   config it has read on the first frame.
///
/// Fixtures:
/// - Configs: the real `Pixel_9_Pro_Fold` (2076x2152, 390 dpi, one hinge)
///   and `Pixel_9_Pro` (1280x2856, 480 dpi, no skin keys) AVDs'
///   (`Fixtures/api37-emulator/logcat-sdk-apk/avd/`), copied into a
///   temporary AVD home. Their `skin.*` keys are not read: the cards the
///   tests build say whether there is a skin.
/// - Shapes: the same emulator's `dumpsys display`
///   (`adb-core/shell-dumpsys-display.txt`): the inner panel 2076x2152 lit,
///   radius 85, its hole at (1987.5, 80); the cover 1080x2424 off, radius
///   115. They stand in for a phone model's stored shapes; no real phone's
///   capture exists (plan §8 question 3). The numbers are
///   `ChromeGeometryTests`': the inner body 2208.047 x 2284.047 with outer
///   radius 151.024, the cover's 1181.339 x 2525.339 with 165.669.
///
/// Hosted checks read pixels at the hosting window's own backing scale, at
/// 1x and 2x, in the light appearance over a white stage. `SkinHero.height`
/// is 200 pt (DH's measured stopped-page hero, not the
/// panel's old fixed 400), and every body shows its placeholder screen's
/// plain light-blue wallpaper. The panel's whole group — hero, name,
/// subtitle, Start — is centred vertically in the stage, not pinned to a
/// fixed offset from the top follow-up, 2026-09-28: DH centres it
/// too), so a hero's own top edge moves with the group's total height
/// (which a status line below it, wrapped over 1 or 2 lines, can change).
/// Checks below scan the centre column (x=300, where every hero is
/// horizontally centred) for the hero's own colour instead of reading one
/// hardcoded point.
@MainActor
final class StageIllustrationTests: XCTestCase {
    private static let kitFixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DeviceHubProKitTests/Fixtures/api37-emulator", isDirectory: true)

    private static let stageSize = CGSize(width: 600, height: 720)
    /// Every hero (a skin, a vector body or the placeholder card) and the
    /// panel's whole DH-matched group are horizontally centred here.
    private static let centerX: CGFloat = 300
    /// Fixed points still valid for an "is anything drawn here" check: with
    /// nothing to show, `ConnectingView`'s bare `status` (a
    /// `ContentUnavailableView`) centres itself in the *whole* stage
    /// (around y=360 for a 720 pt one), well below every point here, so
    /// these stay white regardless of the DH-matched group's own
    /// (content-height-dependent) vertical position.
    private static let statusRow = CGPoint(x: centerX, y: 28 + 30)
    private static let upperHero = CGPoint(x: centerX, y: 28 + 80)
    private static let heroMiddle = CGPoint(x: centerX, y: 28 + 200)

    private static func foldShapes() throws -> [DisplayShape] {
        let dump = kitFixtures.appendingPathComponent("adb-core/shell-dumpsys-display.txt")
        return DisplayShape.parse(dumpsysDisplay: try String(contentsOf: dump, encoding: .utf8))
    }

    /// A temporary AVD home holding both AVDs' real `config.ini`s as
    /// `<name>.avd/config.ini` (no `.ini` pointer: the emulator's default).
    private func avdHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("StageIllustrationTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        for name in ["Pixel_9_Pro_Fold", "Pixel_9_Pro"] {
            let content = home.appendingPathComponent("\(name).avd", isDirectory: true)
            try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: Self.kitFixtures.appendingPathComponent("logcat-sdk-apk/avd/\(name).avd/config.ini"),
                to: content.appendingPathComponent("config.ini")
            )
        }
        return home
    }

    private static func card(_ name: String, skin: ResolvedSkin? = nil, serial: String? = nil) -> AvdCard {
        AvdCard(name: name, displayName: name, target: nil, skin: skin, isRunning: serial != nil, serial: serial)
    }

    /// A skin whose artwork does not exist (generated input, not an SDK
    /// skin): its preview never renders, so its hero is the placeholder
    /// card, which is enough to show that a hero is drawn.
    private static let missingSkin: ResolvedSkin = {
        let directory = URL(fileURLWithPath: "/nonexistent/StageIllustrationTests/pixel_test", isDirectory: true)
        return ResolvedSkin(
            name: "pixel_test",
            directory: directory,
            source: .skinName,
            variants: [SkinVariant(id: "default", directory: directory, layout: nil)]
        )
    }()

    private static let phoneSerial = "0A1B2C3D4E5F"
    private static let phoneModel = "Pixel_9_Pro_Fold"

    private static func phone(model: String? = phoneModel) -> AndroidDevice {
        AndroidDevice(serial: phoneSerial, state: "device", model: model)
    }

    private struct NotAVectorBody: Error {}

    private func vectorBody(_ plan: DeviceComposition) throws -> DeviceComposition.VectorBody {
        guard case let .vector(body) = plan.body else { throw NotAVectorBody() }
        return body
    }

    // MARK: - What the live stage draws once nothing attaches

    /// A running AVD (its card holds the serial) is drawn as its stopped
    /// page draws it: a skinned one with its skin's preferred variant, a
    /// skinless one with its body planned from its config and the shapes
    /// it last reported.
    func testARunningAvdIsDrawnAsItsStoppedPageDrawsIt() throws {
        let skinned = Self.card("Pixel_Test", skin: Self.missingSkin, serial: "emulator-5554")
        let skinless = Self.card("Pixel_9_Pro_Fold", serial: "emulator-5582")
        let cards = [skinned, skinless]
        let devices = [
            AndroidDevice(serial: "emulator-5554", state: "device"),
            AndroidDevice(serial: "emulator-5582", state: "device"),
        ]
        func illustration(_ serial: String) -> ConnectingView.Illustration? {
            ConnectingView.illustration(
                for: .android(serial),
                isAttaching: false,
                avdCards: cards,
                devices: devices,
                phoneShapes: { _ in XCTFail("an AVD never reads a model's shapes"); return [] }
            )
        }
        XCTAssertEqual(illustration("emulator-5554"), .avd(skinned))
        XCTAssertEqual(illustration("emulator-5582"), .avd(skinless))

        XCTAssertEqual(
            AvdHero.content(hasSkin: true, variant: Self.missingSkin.preferredVariant, screen: .unread, shapes: []),
            .skin(Self.missingSkin.preferredVariant)
        )
        let home = try avdHome()
        let config = try XCTUnwrap(AvdScreenConfig.read(avdName: "Pixel_9_Pro_Fold", avdHome: home))
        let shapes = try Self.foldShapes()
        let content = AvdHero.content(hasSkin: false, variant: nil, screen: .screen(config), shapes: shapes)
        XCTAssertEqual(content, .body(AvdDetailView.vectorPlan(avdName: "Pixel_9_Pro_Fold", avdHome: home, shapes: shapes)))
        guard case let .body(plan?) = content else { return XCTFail("the body: \(content)") }
        XCTAssertEqual(plan.screenCorner, ScreenCorner(radius: 85, source: .device))
        XCTAssertEqual(try vectorBody(plan).outerRadius, 151.024, accuracy: 0.01)
    }

    /// A phone is drawn from the displays phones of its model last
    /// reported: the lit built-in panel (here the fold's inner screen),
    /// upright, with its corner and its hole, as a foldable's inner body.
    func testAPhoneIsDrawnFromTheDisplaysItsModelLastReported() throws {
        let shapes = try Self.foldShapes()
        var asked: [String] = []
        let illustration = ConnectingView.illustration(
            for: .android(Self.phoneSerial),
            isAttaching: false,
            avdCards: [Self.card("Pixel_9_Pro_Fold", serial: "emulator-5554")],
            devices: [Self.phone()],
            phoneShapes: { model in
                asked.append(model)
                return shapes
            }
        )
        XCTAssertEqual(asked, [Self.phoneModel])
        guard case let .phone(plan) = illustration else { return XCTFail("a phone's body: \(String(describing: illustration))") }
        XCTAssertEqual(plan.screenRect.size, CGSize(width: 2076, height: 2152))
        XCTAssertEqual(try vectorBody(plan).family, .foldableInner)
        XCTAssertEqual(plan.layoutSize.width, 2208.047, accuracy: 0.01)
        XCTAssertEqual(plan.layoutSize.height, 2284.047, accuracy: 0.01)
        XCTAssertEqual(plan.screenCorner, ScreenCorner(radius: 85, source: .device))
        XCTAssertEqual(try vectorBody(plan).outerRadius, 151.024, accuracy: 0.01)
        XCTAssertEqual(plan.cutout?.quarterTurns, 0)
        XCTAssertEqual(plan.cutout?.naturalSize, CGSize(width: 2076, height: 2152))
    }

    /// A phone whose last read found it folded (the cover lit, the inner
    /// screen off) is drawn as its cover: a phone body round the 1080x2424
    /// panel. The states are swapped in code from the real capture
    /// (generated input, not device output). With no panel lit, the first
    /// built-in one is drawn.
    func testAFoldedPhoneIsDrawnAsItsLitCoverScreen() throws {
        let folded = try Self.foldShapes().map { shape -> DisplayShape in
            var shape = shape
            if shape.isBuiltIn { shape.state = shape.width == 1080 ? "ON" : "OFF" }
            return shape
        }
        let cover = try XCTUnwrap(ConnectingView.phonePlan(shapes: folded))
        XCTAssertEqual(cover.screenRect.size, CGSize(width: 1080, height: 2424))
        XCTAssertEqual(try vectorBody(cover).family, .phone)
        XCTAssertEqual(cover.layoutSize.width, 1181.339, accuracy: 0.01)
        XCTAssertEqual(cover.layoutSize.height, 2525.339, accuracy: 0.01)
        XCTAssertEqual(try vectorBody(cover).outerRadius, 165.669, accuracy: 0.01)
        XCTAssertEqual(cover.cutout?.naturalSize, CGSize(width: 1080, height: 2424))

        let dark = try Self.foldShapes().map { shape -> DisplayShape in
            var shape = shape
            shape.state = "OFF"
            return shape
        }
        XCTAssertEqual(ConnectingView.phonePlan(shapes: dark)?.screenRect.size, CGSize(width: 2076, height: 2152))
    }

    /// No illustration for a phone without stored shapes (a model never
    /// mirrored), one whose model adb does not name, or one whose shapes
    /// hold no built-in panel (generated: the fixture's panels retyped as
    /// virtual displays).
    func testAPhoneWithNothingStoredHasNoIllustration() throws {
        func illustration(_ device: AndroidDevice, shapes: [DisplayShape]) -> ConnectingView.Illustration? {
            ConnectingView.illustration(
                for: .android(device.serial),
                isAttaching: false,
                avdCards: [],
                devices: [device],
                phoneShapes: { _ in shapes }
            )
        }
        XCTAssertNil(illustration(Self.phone(), shapes: []))
        XCTAssertNil(illustration(Self.phone(model: nil), shapes: try Self.foldShapes()))
        XCTAssertNil(illustration(Self.phone(model: ""), shapes: try Self.foldShapes()))
        let virtual = try Self.foldShapes().map { shape -> DisplayShape in
            var shape = shape
            shape.type = "VIRTUAL"
            return shape
        }
        XCTAssertNil(illustration(Self.phone(), shapes: virtual))
        XCTAssertNil(ConnectingView.phonePlan(shapes: virtual))
    }

    /// An emulator the AVD cards do not name (a foreign emulator, or one
    /// forced through the phone transport whose card is not known) gets no
    /// illustration: it never borrows its model's shapes, which every AVD
    /// of its system image shares (`MirrorController.liveDisplayShapes`).
    func testAnEmulatorWithoutACardNeverBorrowsAModelsShapes() throws {
        let shapes = try Self.foldShapes()
        let illustration = ConnectingView.illustration(
            for: .android("emulator-5554"),
            isAttaching: false,
            avdCards: [Self.card("Pixel_9_Pro_Fold")],
            devices: [AndroidDevice(serial: "emulator-5554", state: "device", model: "sdk_gphone64_arm64")],
            phoneShapes: { _ in shapes }
        )
        XCTAssertNil(illustration)
    }

    /// Nothing is drawn while the device attaches, whatever it is.
    func testNothingIsDrawnWhileTheDeviceAttaches() throws {
        let shapes = try Self.foldShapes()
        let cards = [Self.card("Pixel_9_Pro_Fold", serial: "emulator-5554")]
        let devices = [AndroidDevice(serial: "emulator-5554", state: "device"), Self.phone()]
        for serial in ["emulator-5554", Self.phoneSerial] {
            XCTAssertNotNil(ConnectingView.illustration(
                for: .android(serial), isAttaching: false, avdCards: cards, devices: devices, phoneShapes: { _ in shapes }
            ), serial)
            XCTAssertNil(ConnectingView.illustration(
                for: .android(serial), isAttaching: true, avdCards: cards, devices: devices, phoneShapes: { _ in shapes }
            ), serial)
        }
    }

    /// An Apple device keeps the status alone, even when an AVD card or an
    /// adb row carries its identifier.
    func testAnAppleDeviceKeepsTheStatusAlone() throws {
        let shapes = try Self.foldShapes()
        let udid = "5A4F1E2D-0000-4000-8000-00000000A0B1"
        let illustration = ConnectingView.illustration(
            for: .apple(udid),
            isAttaching: false,
            avdCards: [Self.card("Pixel_9_Pro_Fold", serial: udid)],
            devices: [AndroidDevice(serial: udid, state: "device", model: Self.phoneModel)],
            phoneShapes: { _ in shapes }
        )
        XCTAssertNil(illustration)
    }

    // MARK: - The live stage, hosted

    /// After Stop Mirror a skinless AVD's stage draws its body above the
    /// status.
    func testTheStageWithoutAMirrorDrawsASkinlessAvdAboveTheStatus() async throws {
        let home = try avdHome()
        let model = AppModel.testing()
        model.catalog.avdCards = [Self.card("Pixel_9_Pro_Fold", serial: "emulator-5554")]
        model.inventory.devices = [AndroidDevice(serial: "emulator-5554", state: "device")]
        model.mirror.displayShapes.record(try Self.foldShapes(), forAvd: "Pixel_9_Pro_Fold")

        for scale: CGFloat in [1, 2] {
            let stage = hostStage(
                ConnectingView(device: .android("emulator-5554"), isAttachPending: false, avdHome: home),
                model: model,
                scale: scale
            )
            defer { stage.window.close() }
            let row = try await waitForColumnMatch(stage.host, Self.isWallpaper)
            XCTAssertNotNil(row, "the body's status row at \(scale)x")
            try assertStatusDrawnBelowTheHero(in: stage.host, "\(scale)x")
        }
    }

    /// A phone's stage draws the body its model's stored shapes plan; a
    /// phone of a model with nothing stored keeps the status alone.
    func testTheStageWithoutAMirrorDrawsAPhonesBodyFromItsModelsShapes() async throws {
        let model = AppModel.testing()
        model.inventory.devices = [Self.phone(), AndroidDevice(serial: "9Z8Y7X6W", state: "device", model: "Never_Mirrored")]
        model.mirror.displayShapes.record(try Self.foldShapes(), forPhysicalModel: Self.phoneModel)

        for scale: CGFloat in [1, 2] {
            let stage = hostStage(
                ConnectingView(device: .android(Self.phoneSerial), isAttachPending: false),
                model: model,
                scale: scale
            )
            defer { stage.window.close() }
            let row = try await waitForColumnMatch(stage.host, Self.isWallpaper)
            XCTAssertNotNil(row, "the phone's body at \(scale)x")

            let bare = hostStage(
                ConnectingView(device: .android("9Z8Y7X6W"), isAttachPending: false),
                model: model,
                scale: scale
            )
            defer { bare.window.close() }
            try assertNothingDrawn(in: bare.host, "a model never mirrored at \(scale)x")
        }
    }

    /// While the device attaches (the stage's attach task not run yet, or
    /// the attach under way) nothing is drawn; once the attach fails the
    /// device is drawn above the reason and Retry.
    func testNothingIsDrawnWhileAttachingAndTheDeviceIsOnceTheAttachFails() async throws {
        let home = try avdHome()
        let model = AppModel.testing()
        model.catalog.avdCards = [Self.card("Pixel_9_Pro", serial: "emulator-5554")]
        model.inventory.devices = [AndroidDevice(serial: "emulator-5554", state: "device")]

        for scale: CGFloat in [1, 2] {
            let pending = hostStage(
                ConnectingView(device: .android("emulator-5554"), isAttachPending: true, avdHome: home),
                model: model,
                scale: scale
            )
            defer { pending.window.close() }
            try assertNothingDrawn(in: pending.host, "the attach task not run yet at \(scale)x")

            model.mirror.showAttaching(serial: "emulator-5554")
            let attaching = hostStage(
                ConnectingView(device: .android("emulator-5554"), isAttachPending: false, avdHome: home),
                model: model,
                scale: scale
            )
            defer { attaching.window.close() }
            try assertNothingDrawn(in: attaching.host, "attaching at \(scale)x")

            model.mirror.failAttach(serial: "emulator-5554", "The emulator's gRPC port did not answer.")
            let row = try await waitForColumnMatch(attaching.host, Self.isWallpaper)
            XCTAssertNotNil(row, "the device over the failure at \(scale)x")
            try assertStatusDrawnBelowTheHero(in: attaching.host, "the failure at \(scale)x")
            model.mirror.clearAttach()
        }
    }

    /// A skinned AVD's stage draws its skin's hero: here the placeholder
    /// card of a skin whose artwork is missing (generated input), where the
    /// status alone would leave the stage white.
    func testTheStageWithoutAMirrorDrawsASkinnedAvdsHero() async throws {
        let model = AppModel.testing()
        model.catalog.avdCards = [Self.card("Pixel_Test", skin: Self.missingSkin, serial: "emulator-5554")]
        model.inventory.devices = [AndroidDevice(serial: "emulator-5554", state: "device")]

        for scale: CGFloat in [1, 2] {
            let stage = hostStage(
                ConnectingView(device: .android("emulator-5554"), isAttachPending: false),
                model: model,
                scale: scale
            )
            defer { stage.window.close() }
            let card = try await waitForColumnMatch(stage.host, Self.isGreyCard)
            XCTAssertNotNil(card, "the skin's hero at \(scale)x")
        }
    }

    /// An Apple device's stage is the status alone: nothing illustrated
    /// above it. (Its copy and its Show Live View button are the simulator
    /// canvas's, so its pixels no longer equal an Android device's with no
    /// Mirror button; the simulator's stopped and booting pages draw its
    /// body, `SimulatorStageView`.)
    func testAnAppleDevicesStageIsTheStatusAlone() throws {
        let model = AppModel.testing()
        for scale: CGFloat in [1, 2] {
            let apple = hostStage(
                ConnectingView(device: .apple("5A4F1E2D-0000-4000-8000-00000000A0B1"), isAttachPending: false),
                model: model,
                scale: scale
            )
            defer { apple.window.close() }
            try assertNothingDrawn(in: apple.host, "Apple at \(scale)x")
        }
    }

    // MARK: - The booting panel, hosted

    /// A booting AVD shows Device Hub's booting stage: a spinner alone, no
    /// device and no name, and no grey card either.
    func testABootingAvdShowsOnlyASpinner() async throws {
        let home = try avdHome()
        let model = AppModel.testing()
        model.catalog.avdCards = [Self.card("Pixel_9_Pro")]

        for scale: CGFloat in [1, 2] {
            let stage = hostStage(
                AvdBootingView(avdName: "Pixel_9_Pro", label: "Starting…", avdHome: home),
                model: model,
                scale: scale
            )
            defer { stage.window.close() }
            try await Task.sleep(for: .milliseconds(200))
            let row = try Self.firstMatch(in: stage.host, x: Self.centerX, matching: Self.isWallpaper)
            XCTAssertNil(row, "no device body at \(scale)x")
        }
    }

    // MARK: - No grey card before a skinless body

    /// The hero draws nothing while a skinless AVD's config is read, its
    /// body once it is, and the placeholder card only for a config that
    /// declares no screen.
    func testASkinlessHeroDrawsNothingUntilItsConfigIsRead() throws {
        let home = try avdHome()
        let config = try XCTUnwrap(AvdScreenConfig.read(avdName: "Pixel_9_Pro", avdHome: home))
        XCTAssertEqual(config, AvdScreenConfig(lcdSize: CGSize(width: 1280, height: 2856), lcdDensity: 480, hingeCount: 0))
        XCTAssertNil(AvdScreenConfig.read(avdName: "No_Such_Avd", avdHome: home))

        XCTAssertEqual(AvdHero.content(hasSkin: false, variant: nil, screen: .unread, shapes: []), .reading)
        XCTAssertEqual(AvdHero.content(hasSkin: false, variant: nil, screen: .undeclared, shapes: []), .body(nil))
        XCTAssertEqual(
            AvdHero.content(hasSkin: false, variant: nil, screen: .screen(config), shapes: []),
            .body(AvdDetailView.vectorPlan(avdName: "Pixel_9_Pro", avdHome: home, shapes: []))
        )
    }

    /// A config is read into the screens once it is loaded, and a read of
    /// the same config again changes nothing a hero observes.
    func testTheScreensKeepEachConfigAndAnUnchangedReadIsNoChange() async throws {
        let home = try avdHome()
        let screens = SkinlessAvdScreens()
        let phone = SkinlessAvdScreens.Key(avdName: "Pixel_9_Pro", avdHome: home)
        let missing = SkinlessAvdScreens.Key(avdName: "No_Such_Avd", avdHome: home)
        XCTAssertEqual(screens.lookup(phone), .unread)

        await screens.load(phone)
        await screens.load(missing)
        XCTAssertEqual(
            screens.lookup(phone),
            .screen(AvdScreenConfig(lcdSize: CGSize(width: 1280, height: 2856), lcdDensity: 480, hingeCount: 0))
        )
        XCTAssertEqual(screens.lookup(missing), .undeclared)
        XCTAssertEqual(screens.lookup(.init(avdName: "Pixel_9_Pro", avdHome: nil)), .unread, "another AVD home")

        let changed = ChangeFlag()
        withObservationTracking {
            _ = screens.lookup(phone)
        } onChange: {
            changed.set()
        }
        await screens.load(phone)
        await screens.load(missing)
        XCTAssertFalse(changed.isSet, "an unchanged read redraws nothing")
    }

    /// The stopped page of a skinless AVD never shows the grey card: not on
    /// its first frame, drawn before its config is read, nor at any sample
    /// until its body lands.
    func testTheStoppedPageNeverShowsTheGreyCardBeforeTheBody() async throws {
        for scale: CGFloat in [1, 2] {
            let home = try avdHome()
            let model = AppModel.testing()
            model.catalog.avdCards = [Self.card("Pixel_9_Pro")]
            let stage = hostStage(AvdDetailView(avdName: "Pixel_9_Pro", avdHome: home), model: model, scale: scale)
            defer { stage.window.close() }

            try assertNothingDrawn(in: stage.host, "the first frame at \(scale)x")
            let row = try await waitForColumnMatch(stage.host, Self.isWallpaper) { host in
                if let grey = try Self.firstMatch(in: host, x: Self.centerX, matching: Self.isGreyCard) {
                    XCTFail("no grey card before the body at \(scale)x: \(grey.pixel) at y=\(grey.y)")
                }
            }
            XCTAssertNotNil(row, "the body at \(scale)x")
        }
    }

    /// A skinless AVD whose config declares no screen shows the grey card
    /// once the read says so ("nothing known"), and not before.
    func testTheGreyCardIsOnlyForASkinlessAvdWithNothingKnown() async throws {
        let model = AppModel.testing()
        model.catalog.avdCards = [Self.card("No_Such_Avd")]
        for scale: CGFloat in [1, 2] {
            let home = try avdHome()
            let stage = hostStage(AvdDetailView(avdName: "No_Such_Avd", avdHome: home), model: model, scale: scale)
            defer { stage.window.close() }
            try assertNothingDrawn(in: stage.host, "before the read at \(scale)x")
            let card = try await waitForColumnMatch(stage.host, Self.isGreyCard)
            XCTAssertNotNil(card, "nothing known at \(scale)x")
        }
    }

    /// Switching the stopped page from one skinless AVD to another whose
    /// config was read before draws the new body on the first frame, with
    /// no grey card and no empty frame between; a switch to one not read
    /// yet shows nothing until it is.
    func testASwitchToAKnownSkinlessAvdDrawsItsBodyOnTheFirstFrame() async throws {
        let home = try avdHome()
        let model = AppModel.testing()
        model.catalog.avdCards = [Self.card("Pixel_9_Pro"), Self.card("Pixel_9_Pro_Fold"), Self.card("Unread_1x"), Self.card("Unread_2x")]
        for name in ["Pixel_9_Pro", "Pixel_9_Pro_Fold"] {
            await SkinlessAvdScreens.shared.load(.init(avdName: name, avdHome: home))
            let plan = try XCTUnwrap(AvdDetailView.vectorPlan(avdName: name, avdHome: home, shapes: []))
            _ = await SkinThumbnailCache.shared.renderedVectorImage(for: plan, height: SkinHero.deviceHeight)
        }
        for scale: CGFloat in [1, 2] {
            let stage = hostStage(AvdDetailView(avdName: "Pixel_9_Pro", avdHome: home), model: model, scale: scale)
            defer { stage.window.close() }
            guard let phoneHit = try Self.firstMatch(in: stage.host, x: Self.centerX, matching: Self.isWallpaper) else {
                return XCTFail("a read AVD draws on its first frame at \(scale)x")
            }
            // 80 pt right of the middle, 30 pt below the top of the
            // wallpaper run just found (clear of the screen's rounded top
            // corner, as the old fixed "30 pt into the hero" was): past the
            // phone's body and its contact shadow (about 46 pt half-width
            // plus the shadow's 8 pt overhang at `SkinHero.deviceHeight`),
            // inside the fold's body (about 93.8 pt half-width, clear of
            // its own frame edge at ≈92). The DH-matched group's vertical
            // position depends on its total height, which the fold's
            // differently-worded subtitle could in principle shift by a
            // fraction of a point, but both cards share the same
            // composition (name, subtitle, Start), so the row found for the
            // phone stays inside the fold's body too.
            let foldOnly = CGPoint(x: Self.centerX + 80, y: phoneHit.y + 30)
            XCTAssertTrue(Self.isBackground(try Self.pixel(stage.host, at: foldOnly)), "the phone's narrow body at \(scale)x")

            stage.host.rootView = Self.stage(AvdDetailView(avdName: "Pixel_9_Pro_Fold", avdHome: home), model: model)
            stage.host.layoutSubtreeIfNeeded()
            let fold = try Self.pixel(stage.host, at: foldOnly)
            XCTAssertTrue(Self.isWallpaper(fold), "the fold's body on the switch's first frame at \(scale)x: \(fold)")

            // No config for it in the home: once read, "nothing known".
            stage.host.rootView = Self.stage(AvdDetailView(avdName: "Unread_\(Int(scale))x", avdHome: home), model: model)
            stage.host.layoutSubtreeIfNeeded()
            try assertNothingDrawn(in: stage.host, "a switch to an AVD not read yet at \(scale)x")
        }
    }

    // MARK: - Hosting and pixels

    private struct Stage<Content: View> {
        let host: NSHostingView<StageRoot<Content>>
        let window: ScaledTestWindow
    }

    /// The panel as the stage shows it: over the stage's white, in the
    /// light appearance.
    private static func stage<Content: View>(_ content: Content, model: AppModel) -> StageRoot<Content> {
        StageRoot(content: content, model: model)
    }

    /// `content` hosted in an offscreen window at `scale`, laid out once
    /// (its tasks have not run: the caller has not yielded).
    private func hostStage<Content: View>(
        _ content: Content,
        model: AppModel,
        scale: CGFloat
    ) -> Stage<Content> {
        let host = NSHostingView(rootView: Self.stage(content, model: model))
        host.appearance = NSAppearance(named: .aqua)
        let window = ScaledTestWindow.hosting(host, size: Self.stageSize, scale: scale)
        window.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        return Stage(host: host, window: window)
    }

    /// The status (its symbol, title and text) under the hero: dark pixels
    /// down the middle between the hero's own bottom (found by scanning,
    /// since the DH-matched group's position depends on its total height)
    /// and the stage's.
    private func assertStatusDrawnBelowTheHero(in host: NSView, _ message: String) throws {
        let image = try Self.bitmap(host)
        let scale = CGFloat(image.width) / host.bounds.width
        let x = Int(Self.centerX * scale)
        guard let heroBottom = Self.firstRunBottomRow(
            in: image, x: x, scale: scale,
            matching: { Self.isWallpaper($0) || Self.isGreyCard($0) }
        ) else {
            return XCTFail("the hero itself, \(message)")
        }
        let height = image.bytes.count / image.bytesPerRow
        let rows = (heroBottom + Int(14 * scale))..<height
        let dark = rows.filter { y in
            let offset = y * image.bytesPerRow + x * 4
            return image.bytes[offset] < 200 && image.bytes[offset + 3] == 255
        }
        XCTAssertGreaterThan(dark.count, Int(10 * scale), "the status under the hero, \(message)")
    }

    /// No hero: the stage is white where one would be.
    private func assertNothingDrawn(in host: NSView, _ message: String) throws {
        host.layoutSubtreeIfNeeded()
        for point in [Self.statusRow, Self.upperHero, Self.heroMiddle] {
            let pixel = try Self.pixel(host, at: point)
            XCTAssertTrue(Self.isBackground(pixel), "\(message): \(pixel) at \(point)")
        }
    }

    /// Scans the centre column top-to-bottom for a pixel matching `done`
    /// (the DH-matched group's vertical position depends on its own total
    /// height, so a hero is found by its colour, not a fixed offset from
    /// the stage's top), retrying for 5 s; `each` runs on every attempt, so
    /// a caller can also assert something never appears before the match.
    /// Returns the matching pixel, or nil once the deadline passes.
    private func waitForColumnMatch(
        _ host: NSView,
        _ done: ([UInt8]) -> Bool,
        each: (NSView) throws -> Void = { _ in }
    ) async throws -> [UInt8]? {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            try each(host)
            if let hit = try Self.firstMatch(in: host, x: Self.centerX, matching: done) { return hit.pixel }
            try? await Task.sleep(for: .milliseconds(30))
        } while ContinuousClock.now < deadline
        return nil
    }

    /// The first pixel (top-down) at `x` belonging to a run of `matching`
    /// pixels at least `minRun` points long, and its row in points; nil if
    /// no run reaches it. The run length tells an actual hero/placeholder
    /// fill (`SkinHero.height` 200 pt) apart from a stray pixel elsewhere in
    /// the column that happens to match — a status icon's stroke, or
    /// anti-aliased text — which a single-pixel scan cannot.
    private static func firstMatch(
        in host: NSView,
        x: CGFloat,
        matching: ([UInt8]) -> Bool,
        minRun: CGFloat = 40
    ) throws -> (y: CGFloat, pixel: [UInt8])? {
        let image = try bitmap(host)
        let scale = CGFloat(image.width) / host.bounds.width
        let px = Int(x * scale)
        guard let run = thickRuns(in: image, x: px, scale: scale, matching: matching, minRun: minRun).first
        else { return nil }
        return (CGFloat(run.start) / scale, run.pixel)
    }

    /// The bottom row (top-down, in the bitmap's own pixel space) of the
    /// first run of `matching` pixels at least `minRun` points long at `x`;
    /// nil if none reaches it. Used to find a hero's own bottom edge once it
    /// (and whatever is below it) is already rendered, without mistaking a
    /// status icon or dark text further down for the hero itself.
    private static func firstRunBottomRow(
        in image: (width: Int, bytesPerRow: Int, bytes: [UInt8]),
        x: Int,
        scale: CGFloat,
        matching: ([UInt8]) -> Bool,
        minRun: CGFloat = 40
    ) -> Int? {
        thickRuns(in: image, x: x, scale: scale, matching: matching, minRun: minRun).first?.end
    }

    /// Contiguous runs (top-down, in the bitmap's own pixel space) at `x`
    /// whose length reaches `minRun` points, each with its last matching
    /// pixel's colour.
    private static func thickRuns(
        in image: (width: Int, bytesPerRow: Int, bytes: [UInt8]),
        x: Int,
        scale: CGFloat,
        matching: ([UInt8]) -> Bool,
        minRun: CGFloat
    ) -> [(start: Int, end: Int, pixel: [UInt8])] {
        let height = image.bytes.count / image.bytesPerRow
        var runs: [(start: Int, end: Int, pixel: [UInt8])] = []
        var runStart = -1
        var lastPixel: [UInt8] = []
        func closeRun(at endExclusive: Int) {
            guard runStart >= 0 else { return }
            if CGFloat(endExclusive - runStart) / scale >= minRun {
                runs.append((runStart, endExclusive - 1, lastPixel))
            }
            runStart = -1
        }
        for y in 0..<height {
            let offset = y * image.bytesPerRow + x * 4
            let p = Array(image.bytes[offset..<offset + 4])
            if matching(p) {
                if runStart < 0 { runStart = y }
                lastPixel = p
            } else {
                closeRun(at: y)
            }
        }
        closeRun(at: height)
        return runs
    }

    /// The stage's white.
    private static func isBackground(_ p: [UInt8]) -> Bool {
        p[0] >= 250 && p[1] >= 250 && p[2] >= 250
    }

    /// The placeholder card's grey gradient (system grey to dark grey).
    private static func isGreyCard(_ p: [UInt8]) -> Bool {
        let (r, g, b) = (Int(p[0]), Int(p[1]), Int(p[2]))
        return abs(r - g) <= 6 && abs(g - b) <= 12 && (60...170).contains(r)
    }

    /// The placeholder screen's plain light-blue wallpaper,
    /// 2026-09-28: DH's stopped device, no app-icon grid), sampled near the
    /// hero's top where the gradient reads darkest.
    private static func isWallpaper(_ p: [UInt8]) -> Bool {
        p[0] < 110 && Int(p[2]) > Int(p[0]) + 10
    }

    /// `view`'s pixel at `point` (points from its top-left), drawn at its
    /// window's backing scale, as sRGB RGBA.
    private static func pixel(_ view: NSView, at point: CGPoint) throws -> [UInt8] {
        let image = try bitmap(view)
        let scale = CGFloat(image.width) / view.bounds.width
        let x = Int(point.x * scale)
        let y = Int(point.y * scale)
        let offset = y * image.bytesPerRow + x * 4
        return Array(image.bytes[offset..<offset + 4])
    }

    /// `view` drawn at its window's backing scale, as premultiplied sRGB
    /// RGBA rows from its top-left.
    private static func bitmap(_ view: NSView) throws -> (width: Int, bytesPerRow: Int, bytes: [UInt8]) {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage)
        let bytesPerRow = image.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress,
                      width: image.width,
                      height: image.height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn)
        return (image.width, bytesPerRow, bytes)
    }
}

/// A panel over the stage's white, with the model in its environment.
private struct StageRoot<Content: View>: View {
    let content: Content
    let model: AppModel

    var body: some View {
        content
            .environment(model).environment(model.workspace)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
    }
}

/// Set once an observed read changes.
private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
