import AppKit
import SwiftUI
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// A simulator in its Apple chrome on the stage (device frame):
/// the chrome the resolver picks, its buttons' hotspots and what a press
/// sends, the compact window's gate and the framed screenshot.
///
/// The chrome's files are Apple's and never in the repository: the frames
/// here are built from the values the installed `phone11` chrome holds (its
/// `chrome.json` and PDF page sizes, Xcode 27.0 27A266a, as the Kit's
/// `AppleChromeTests` quotes them), with no artwork loaded, so nothing is
/// drawn; the drawing is the Kit tests'.
@MainActor
final class AppleChromeStageTests: XCTestCase {
    private static let udid = "00000000-0000-4000-8000-0000000C4A0E"
    private static let stage = CGSize(width: 600, height: 900)

    /// `phone11`'s buttons, as its `chrome.json` lists them.
    private static let phone11Inputs: [AppleChromeDescriptor.Input] = [
        .init(name: "action", title: "Action", usagePage: 11, usage: 45, image: "Mute BTN", imageDown: "Mute BTN Dn",
              anchor: .left, normal: CGPoint(x: 8, y: 160), rollover: CGPoint(x: 3, y: 160)),
        .init(name: "volume-up", title: "Volume Up", usagePage: 12, usage: 233, image: "Vol BTN", imageDown: "Vol BTN Dn",
              anchor: .left, normal: CGPoint(x: 8, y: 221), rollover: CGPoint(x: 3, y: 221)),
        .init(name: "volume-down", title: "Volume Down", usagePage: 12, usage: 234, image: "Vol BTN", imageDown: "Vol BTN Dn",
              anchor: .left, normal: CGPoint(x: 8, y: 300), rollover: CGPoint(x: 3, y: 300)),
        .init(name: "power", title: "Sleep/Wake", usagePage: 12, usage: 48, image: "X_Power BTN", imageDown: "X_Power BTN Dn",
              anchor: .right, normal: CGPoint(x: -8, y: 262), rollover: CGPoint(x: -3, y: 262)),
    ]

    /// `phone11`'s PDF page sizes, chrome points.
    private static let phone11Sizes: [String: CGSize] = [
        "Phone TL": CGSize(width: 110, height: 110), "Phone TR": CGSize(width: 110, height: 110),
        "Phone BL": CGSize(width: 110, height: 110), "Phone BR": CGSize(width: 110, height: 110),
        "Phone Top": CGSize(width: 1, height: 110), "Phone Base": CGSize(width: 1, height: 110),
        "Phone Left": CGSize(width: 110, height: 1), "Phone Right": CGSize(width: 110, height: 1),
        "Mute BTN": CGSize(width: 16, height: 34), "Vol BTN": CGSize(width: 16, height: 64),
        "X_Power BTN": CGSize(width: 16, height: 101),
    ]

    /// iPhone 17 Pro's frame in `phone11`, without artwork.
    static func iPhone17ProFrame() throws -> AppleChromeFrame {
        let descriptor = AppleChromeDescriptor(
            identifier: "com.apple.dt.devicekit.chrome.phone11",
            slices: .init(
                topLeft: "Phone TL", top: "Phone Top", topRight: "Phone TR", right: "Phone Right",
                bottomRight: "Phone BR", bottom: "Phone Base", bottomLeft: "Phone BL", left: "Phone Left"
            ),
            sizing: .init(top: 18, left: 18, bottom: 18, right: 18),
            devicePadding: .init(top: 0, left: 9, bottom: 0, right: 9),
            outerCornerRadius: 80,
            inputs: phone11Inputs
        )
        let art = AppleChromeArt(
            descriptor: descriptor,
            bundle: URL(fileURLWithPath: "/nonexistent/phone11.devicechrome"),
            maskURL: nil,
            documents: [:],
            maskDocument: nil
        )
        let layout = try XCTUnwrap(AppleChromeLayout.make(
            descriptor: descriptor,
            screenPoints: CGSize(width: 402, height: 874),
            imageSize: { phone11Sizes[$0] }
        ))
        return AppleChromeFrame(
            art: art,
            layout: layout,
            screenPixels: CGSize(width: 1206, height: 2622),
            scale: 3,
            cornerRadius: 62
        )
    }

    // MARK: - Resolver

    func testASimulatorWithAChromeGetsIt() throws {
        let frame = try Self.iPhone17ProFrame()
        let shape = SimulatorDisplayProfile(width: 1206, height: 2622, scale: 3).displayShape(id: "x")
        let apple = DeviceRef.apple(Self.udid)
        XCTAssertEqual(
            DeviceChromeResolver.chrome(device: apple, avdCards: [], forceVector: false, appleDisplayShapes: [shape], appleChrome: frame),
            .appleChrome(frame)
        )
        XCTAssertEqual(
            DeviceChromeResolver.chrome(device: apple, avdCards: [], forceVector: false, appleDisplayShapes: [shape]),
            .vector,
            "no chrome: the vector body around the display"
        )
        XCTAssertEqual(DeviceChromeResolver.chrome(device: apple, avdCards: [], forceVector: false), .thinBezel)
        // An Android device never takes a chrome.
        XCTAssertEqual(
            DeviceChromeResolver.chrome(device: .android("emulator-5554"), avdCards: [], forceVector: false, appleChrome: frame),
            .vector
        )
    }

    // MARK: - Compact window

    func testTheCompactWindowOpensForASimulatorsSession() {
        XCTAssertTrue(compactMirrorIsLive(activeSerial: "emulator-5554", device: .android("emulator-5554"), hasSession: true))
        XCTAssertTrue(compactMirrorIsLive(activeSerial: nil, device: .apple(Self.udid), hasSession: true))
        XCTAssertFalse(compactMirrorIsLive(activeSerial: nil, device: .apple(Self.udid), hasSession: false))
        XCTAssertFalse(compactMirrorIsLive(activeSerial: nil, device: nil, hasSession: true))
    }

    // MARK: - Button presses

    /// A press holds the button's usage down until its release; a second
    /// press of a held button sends nothing; releasing all lets go in the
    /// order they went down; the teardown releases what is still held.
    func testChromeButtonsHoldTheirUsageDown() {
        let model = AppModel.testing()
        let session = FakeButtonSession()
        model.mirror.session = session
        XCTAssertTrue(model.mirror.supportsChromeButtons)

        let action = SimulatorHardwareButton(usagePage: 0x0B, usage: 0x2D)
        model.mirror.pressChromeButton(action)
        model.mirror.pressChromeButton(action)
        model.mirror.pressChromeButton(.volumeUp)
        model.mirror.releaseChromeButton(.side)
        XCTAssertEqual(session.events, [.init(action, true), .init(.volumeUp, true)])

        model.mirror.releaseAllChromeButtons()
        XCTAssertEqual(session.events.suffix(2), [.init(action, false), .init(.volumeUp, false)])

        model.mirror.pressChromeButton(.side)
        model.mirror.stopSession(cause: .userStop)
        XCTAssertEqual(session.events.suffix(2), [.init(.side, true), .init(.side, false)])
    }

    /// A session that takes no buttons (the view-only canvas, an emulator)
    /// is sent nothing.
    func testASessionWithoutButtonsIsSentNothing() {
        let model = AppModel.testing()
        let session = FakeMirrorSession()
        model.mirror.session = session
        XCTAssertFalse(model.mirror.supportsChromeButtons)
        model.mirror.pressChromeButton(.volumeUp)
        model.mirror.releaseChromeButton(.volumeUp)
        XCTAssertTrue(session.hardwareKeyEvents.isEmpty)
    }

    /// The pointer state: a press shows the button pressed and presses the
    /// usage; the release lets it go; hover rolls a button out except under
    /// Reduce Motion; releasing all clears everything at once.
    func testTheButtonsState() {
        let model = AppModel.testing()
        let session = FakeButtonSession()
        model.mirror.session = session
        let state = AppleChromeButtonsState()

        state.enter(1, reduceMotion: true)
        XCTAssertTrue(state.rolledOut.isEmpty, "nothing rolls out under Reduce Motion")
        state.enter(1, reduceMotion: false)
        XCTAssertEqual(state.rolledOut, [1])
        state.press(1, button: .volumeUp, on: model.mirror, reduceMotion: false)
        XCTAssertEqual(state.pressed, [1])
        state.release(1, button: .volumeUp, on: model.mirror, reduceMotion: false)
        XCTAssertTrue(state.pressed.isEmpty)
        XCTAssertEqual(session.events, [.init(.volumeUp, true), .init(.volumeUp, false)])

        state.press(3, button: .side, on: model.mirror, reduceMotion: false)
        state.releaseAll(on: model.mirror)
        XCTAssertTrue(state.pressed.isEmpty)
        XCTAssertTrue(state.rolledOut.isEmpty)
        XCTAssertEqual(session.events.last, .init(.side, false))
    }

    // MARK: - Hotspots

    /// A side button takes clicks from 6 pt past where it rolls out to 4 pt
    /// into the body; the side button alone has a long press.
    func testHotspotsCoverTheButtonsReach() throws {
        let frame = try Self.iPhone17ProFrame()
        let buttons = Dictionary(uniqueKeysWithValues: frame.layout.buttons.map { ($0.input.name, $0) })
        let action = try XCTUnwrap(buttons["action"])
        // At 1 view point per chrome point: rolled out to x 1, the box at 9.
        XCTAssertEqual(
            AppleChromeButtonHotspotLayout.hotspot(action, layout: frame.layout, perPoint: 1),
            CGRect(x: 0, y: 160, width: 13, height: 34),
            "clipped to the canvas on the left"
        )
        let power = try XCTUnwrap(buttons["power"])
        XCTAssertEqual(
            AppleChromeButtonHotspotLayout.hotspot(power, layout: frame.layout, perPoint: 2),
            CGRect(x: 890, y: 524, width: 22, height: 202),
            "4 pt into the body, clipped to the canvas on the right"
        )
        XCTAssertEqual(
            AppleChromeButtonHotspotLayout.description(for: power.input),
            .init(label: "Sleep/Wake button", toolTip: "Sleep/Wake: click to press; hold to keep it down", longPressName: "Long-press Sleep/Wake")
        )
        XCTAssertNil(AppleChromeButtonHotspotLayout.description(for: action.input).longPressName)
        XCTAssertEqual(AppleChromeButtonHotspotLayout.description(for: action.input).label, "Action button")
    }

    /// On the main stage with the live canvas, each chrome button is an
    /// accessible hotspot that presses its usage (Volume Up: 0x0C/0xE9);
    /// the compact window, or a session without buttons, offers none.
    func testTheStageOffersTheButtons() async throws {
        let frame = try Self.iPhone17ProFrame()
        let hosted = host(frame: frame, session: FakeButtonSession(), showsButtons: true)
        defer { hosted.window.close() }
        let views = try await hotspots(in: hosted.host, count: 4)
        XCTAssertEqual(
            Set(views.map { $0.accessibilityLabel() ?? "" }),
            ["Action button", "Volume Up button", "Volume Down button", "Sleep/Wake button"]
        )
        let volumeUp = try XCTUnwrap(views.first { $0.accessibilityLabel() == "Volume Up button" })
        XCTAssertFalse(volumeUp.acceptsFirstResponder, "the keyboard stays with the video")
        XCTAssertTrue(volumeUp.accessibilityPerformPress())
        let session = try XCTUnwrap(hosted.model.mirror.session as? FakeButtonSession)
        await waitUntil("the press came up") { session.events.count == 2 }
        XCTAssertEqual(session.events, [.init(.volumeUp, true), .init(.volumeUp, false)])

        let compact = host(frame: frame, session: FakeButtonSession(), showsButtons: false)
        defer { compact.window.close() }
        compact.host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(hotspotViews(in: compact.host).isEmpty, "the compact window offers none")

        let viewOnly = host(frame: frame, session: FakeMirrorSession(), showsButtons: true)
        defer { viewOnly.window.close() }
        viewOnly.host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(hotspotViews(in: viewOnly.host).isEmpty, "a session without buttons gets none")
    }

    // MARK: - Hero and framed screenshots

    /// The stopped page draws the chrome when the device type has one.
    func testTheHeroDrawsTheChrome() throws {
        let frame = try Self.iPhone17ProFrame()
        let shape = SimulatorDisplayProfile(width: 1206, height: 2622, scale: 3).displayShape(id: "x")
        guard case .appleChrome? = SimulatorHero.plan(shape, chrome: frame)?.body else {
            return XCTFail("the Apple chrome")
        }
        guard case .vector? = SimulatorHero.plan(shape)?.body else { return XCTFail("the vector body") }
    }

    // MARK: - Helpers

    private struct Hosted {
        let window: NSWindow
        let host: NSView
        let model: AppModel
    }

    private func host(frame: AppleChromeFrame, session: any MirrorSessionProtocol, showsButtons: Bool) -> Hosted {
        let model = AppModel.testing()
        model.mirror.session = session
        let content = MirrorStageContent(session: session, chrome: .appleChrome(frame), available: Self.stage)
            .environment(\.showsHardwareButtons, showsButtons)
            .environment(model).environment(model.workspace)
            .transaction { $0.animation = nil }
        let host = NSHostingView(rootView: content)
        let window = ScaledTestWindow.hosting(host, size: Self.stage, scale: 2)
        return Hosted(window: window, host: host, model: model)
    }

    private func hotspots(in view: NSView, count: Int) async throws -> [HardwareButtonHotspotView] {
        await waitUntil(timeout: 10, "the hotspots appeared") {
            view.layoutSubtreeIfNeeded()
            return self.hotspotViews(in: view).count == count
        }
        return hotspotViews(in: view)
    }

    private func hotspotViews(in view: NSView) -> [HardwareButtonHotspotView] {
        if let hotspot = view as? HardwareButtonHotspotView { return [hotspot] }
        return view.subviews.flatMap { hotspotViews(in: $0) }
    }
}

/// A live simulator session as the stage sees it: it takes hardware buttons
/// by HID usage (`SimulatorButtonSending`) and records them.
final class FakeButtonSession: MirrorSessionProtocol, SimulatorButtonSending, @unchecked Sendable {
    struct Event: Equatable {
        var button: SimulatorHardwareButton
        var isDown: Bool

        init(_ button: SimulatorHardwareButton, _ isDown: Bool) {
            self.button = button
            self.isDown = isDown
        }
    }

    let frames = FrameStore()
    let transport: MirrorTransport = .simulatorSurface
    private let lock = NSLock()
    private var _events: [Event] = []
    private var _isRunning = true

    var events: [Event] { lock.withLock { _events } }
    var lastError: String? { nil }
    var isRunning: Bool { lock.withLock { _isRunning } }

    func send(button: SimulatorHardwareButton, isDown: Bool) {
        lock.withLock { _events.append(Event(button, isDown)) }
    }

    func start() { lock.withLock { _isRunning = true } }
    func stop() { lock.withLock { _isRunning = false } }
    func resync() async {}
    func stats() async -> MirrorStats { MirrorStats(fps: 0, totalFrames: 0, dropped: 0, averageLatencyMs: 0) }
    func send(_ command: TouchCommand) {}
    func send(contacts: [TouchCommand]) {}
    func send(_ command: KeyboardCommand) {}
}
