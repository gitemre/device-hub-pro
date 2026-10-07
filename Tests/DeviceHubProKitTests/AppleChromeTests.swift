import CoreGraphics
import ImageIO
import XCTest
@testable import DeviceHubProKit

/// The Apple chrome tier (device frame): `chrome.json`, the
/// frame built from the slices around a screen, the composition and its
/// drawing, and how the chrome turns.
///
/// DeviceKit's files are Apple's and are never copied into the repository,
/// so no fixture holds them. The JSON below carries only the
/// keys the parser reads, with the values of the installed `phone11` chrome
/// (`/Library/Developer/DeviceKit/Chrome/phone11.devicechrome/Contents/
/// Resources/chrome.json`, Xcode 27.0 27A266a, read 2026-09-26); the slice
/// and button sizes are that bundle's PDF page sizes. The tests at the end
/// read the installed files themselves and skip on a Mac without them.
final class AppleChromeTests: XCTestCase {
    /// `phone11`'s `chrome.json`, reduced to the keys the parser reads.
    static let phone11JSON = """
    {
      "identifier": "com.apple.dt.devicekit.chrome.phone11",
      "images": {
        "topLeft": "Phone TL", "top": "Phone Top", "topRight": "Phone TR", "right": "Phone Right",
        "bottomRight": "Phone BR", "bottom": "Phone Base", "bottomLeft": "Phone BL", "left": "Phone Left",
        "composite": "PhoneComposite",
        "sizing": { "leftWidth": 18, "rightWidth": 18, "topHeight": 18, "bottomHeight": 18 },
        "devicePadding": { "top": 0, "left": 9, "bottom": 0, "right": 9 }
      },
      "paths": { "simpleOutsideBorder": { "cornerRadiusX": 80, "cornerRadiusY": 80 } },
      "inputs": [
        { "name": "action", "accessibilityTitle": "Action", "type": "button", "usagePage": 11, "usage": 45,
          "image": "Mute BTN", "imageDown": "Mute BTN Dn", "imageDownDrawMode": "replace", "onTop": false,
          "anchor": "left", "align": "leading",
          "offsets": { "normal": { "x": 8, "y": 160 }, "rollover": { "x": 3, "y": 160 } } },
        { "name": "volume-up", "accessibilityTitle": "Volume Up", "type": "button", "usagePage": 12, "usage": 233,
          "image": "Vol BTN", "imageDown": "Vol BTN Dn", "imageDownDrawMode": "replace", "onTop": false,
          "anchor": "left", "align": "leading",
          "offsets": { "normal": { "x": 8, "y": 221 }, "rollover": { "x": 3, "y": 221 } } },
        { "name": "volume-down", "accessibilityTitle": "Volume Down", "type": "button", "usagePage": 12, "usage": 234,
          "image": "Vol BTN", "imageDown": "Vol BTN Dn", "imageDownDrawMode": "replace", "onTop": false,
          "anchor": "left", "align": "leading",
          "offsets": { "normal": { "x": 8, "y": 300 }, "rollover": { "x": 3, "y": 300 } } },
        { "name": "power", "accessibilityTitle": "Sleep/Wake", "type": "button", "usagePage": 12, "usage": 48,
          "image": "X_Power BTN", "imageDown": "X_Power BTN Dn", "imageDownDrawMode": "replace", "onTop": false,
          "anchor": "right", "align": "leading",
          "offsets": { "normal": { "x": -8, "y": 262 }, "rollover": { "x": -3, "y": 262 } } }
      ]
    }
    """

    /// `phone11`'s PDF page sizes, chrome points.
    static let phone11Sizes: [String: CGSize] = [
        "Phone TL": CGSize(width: 110, height: 110), "Phone TR": CGSize(width: 110, height: 110),
        "Phone BL": CGSize(width: 110, height: 110), "Phone BR": CGSize(width: 110, height: 110),
        "Phone Top": CGSize(width: 1, height: 110), "Phone Base": CGSize(width: 1, height: 110),
        "Phone Left": CGSize(width: 110, height: 1), "Phone Right": CGSize(width: 110, height: 1),
        "Mute BTN": CGSize(width: 16, height: 34), "Mute BTN Dn": CGSize(width: 16, height: 34),
        "Vol BTN": CGSize(width: 16, height: 64), "Vol BTN Dn": CGSize(width: 16, height: 63),
        "X_Power BTN": CGSize(width: 16, height: 101), "X_Power BTN Dn": CGSize(width: 16, height: 101),
    ]

    private func phone11() throws -> AppleChromeDescriptor {
        try XCTUnwrap(AppleChromeDescriptor.parse(chromeJSON: Data(Self.phone11JSON.utf8)))
    }

    /// iPhone 17 Pro's screen: 1206 × 2622 px at 3x.
    private func iPhone17ProLayout() throws -> AppleChromeLayout {
        try XCTUnwrap(AppleChromeLayout.make(
            descriptor: phone11(),
            screenPoints: CGSize(width: 402, height: 874),
            imageSize: { Self.phone11Sizes[$0] }
        ))
    }

    // MARK: - chrome.json

    func testTheDescriptorReadsSlicesSizingAndButtons() throws {
        let chrome = try phone11()
        XCTAssertEqual(chrome.identifier, "com.apple.dt.devicekit.chrome.phone11")
        XCTAssertEqual(chrome.slices.topLeft, "Phone TL")
        XCTAssertEqual(chrome.slices.bottom, "Phone Base")
        XCTAssertEqual(chrome.composite, "PhoneComposite")
        XCTAssertEqual(chrome.sizing, .init(top: 18, left: 18, bottom: 18, right: 18))
        XCTAssertEqual(chrome.devicePadding, .init(top: 0, left: 9, bottom: 0, right: 9))
        XCTAssertEqual(chrome.outerCornerRadius, 80)
        XCTAssertEqual(chrome.inputs.map(\.name), ["action", "volume-up", "volume-down", "power"])
        let action = chrome.inputs[0]
        XCTAssertEqual(action.title, "Action")
        XCTAssertEqual(action.usagePage, 11)
        XCTAssertEqual(action.usage, 45)
        XCTAssertEqual(action.image, "Mute BTN")
        XCTAssertEqual(action.imageDown, "Mute BTN Dn")
        XCTAssertEqual(action.downDrawMode, .replace)
        XCTAssertFalse(action.onTop)
        XCTAssertEqual(action.anchor, .left)
        XCTAssertEqual(action.align, .leading)
        XCTAssertEqual(action.normal, CGPoint(x: 8, y: 160))
        XCTAssertEqual(action.rollover, CGPoint(x: 3, y: 160))
        XCTAssertEqual(chrome.inputs[3].title, "Sleep/Wake")
        XCTAssertEqual(chrome.inputs[3].anchor, .right)
        XCTAssertEqual(chrome.inputs[3].normal, CGPoint(x: -8, y: 262))
    }

    /// Not a chrome: no JSON, no identifier, a missing slice or sizing. An
    /// input without an image, an anchor or a usage, or of another type, is
    /// left out; the rest of the chrome stands.
    func testMalformedChromesAndInputs() throws {
        XCTAssertNil(AppleChromeDescriptor.parse(chromeJSON: Data("not json".utf8)))
        XCTAssertNil(AppleChromeDescriptor.parse(chromeJSON: Data("{}".utf8)))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.phone11JSON.utf8)) as? [String: Any])
        func parse(_ root: [String: Any]) throws -> AppleChromeDescriptor? {
            AppleChromeDescriptor.parse(chromeJSON: try JSONSerialization.data(withJSONObject: root))
        }
        var images = try XCTUnwrap(root["images"] as? [String: Any])
        images["left"] = nil
        var noSlice = root
        noSlice["images"] = images
        XCTAssertNil(try parse(noSlice))
        images = try XCTUnwrap(root["images"] as? [String: Any])
        images["sizing"] = ["leftWidth": 18]
        var noSizing = root
        noSizing["images"] = images
        XCTAssertNil(try parse(noSizing))

        var inputs = try XCTUnwrap(root["inputs"] as? [[String: Any]])
        inputs[0]["image"] = nil
        inputs[1]["anchor"] = "middle"
        inputs[2]["usage"] = nil
        var crown = inputs[3]
        crown["name"] = "crown"
        crown["type"] = "crown"
        root["inputs"] = inputs + [crown]
        let pruned = try XCTUnwrap(try parse(root))
        XCTAssertEqual(pruned.inputs.map(\.name), ["power"])
    }

    // MARK: - Geometry

    /// The frame around iPhone 17 Pro's 402 × 874 pt screen, measured against
    /// Device Hub (SIM-17): the box is the screen plus 18 pt a side (438 ×
    /// 910), the canvas the box plus 9 pt left and right for the buttons.
    func testTheFrameIsBuiltAroundTheScreen() throws {
        let layout = try iPhone17ProLayout()
        XCTAssertEqual(layout.canvasSize, CGSize(width: 456, height: 910))
        XCTAssertEqual(layout.box, CGRect(x: 9, y: 0, width: 438, height: 910))
        XCTAssertEqual(layout.screen, CGRect(x: 27, y: 18, width: 402, height: 874))
        XCTAssertEqual(layout.outerCornerRadius, 80)
        let slices = Dictionary(uniqueKeysWithValues: layout.slices.map { ($0.image, $0.rect) })
        XCTAssertEqual(slices["Phone TL"], CGRect(x: 9, y: 0, width: 110, height: 110))
        XCTAssertEqual(slices["Phone TR"], CGRect(x: 337, y: 0, width: 110, height: 110))
        XCTAssertEqual(slices["Phone BR"], CGRect(x: 337, y: 800, width: 110, height: 110))
        XCTAssertEqual(slices["Phone BL"], CGRect(x: 9, y: 800, width: 110, height: 110))
        XCTAssertEqual(slices["Phone Top"], CGRect(x: 119, y: 0, width: 218, height: 110))
        XCTAssertEqual(slices["Phone Base"], CGRect(x: 119, y: 800, width: 218, height: 110))
        XCTAssertEqual(slices["Phone Left"], CGRect(x: 9, y: 110, width: 110, height: 690))
        XCTAssertEqual(slices["Phone Right"], CGRect(x: 337, y: 110, width: 110, height: 690))
    }

    /// Side buttons stand 3 pt past the box at rest (offset 8) and 8 pt
    /// rolled out (offset 3); along the edge they are placed from the box's
    /// top (Device Hub: 160.5, 221.8, 300.8 and 262.0 pt, SIM-17).
    func testSideButtonsStandPastTheBox() throws {
        let layout = try iPhone17ProLayout()
        let buttons = Dictionary(uniqueKeysWithValues: layout.buttons.map { ($0.input.name, $0) })
        let action = try XCTUnwrap(buttons["action"])
        XCTAssertEqual(action.rest, CGRect(x: 6, y: 160, width: 16, height: 34))
        XCTAssertEqual(action.rollover, CGRect(x: 1, y: 160, width: 16, height: 34))
        XCTAssertEqual(buttons["volume-up"]?.rest, CGRect(x: 6, y: 221, width: 16, height: 64))
        XCTAssertEqual(buttons["volume-down"]?.rest, CGRect(x: 6, y: 300, width: 16, height: 64))
        let power = try XCTUnwrap(buttons["power"])
        XCTAssertEqual(power.rest, CGRect(x: 434, y: 262, width: 16, height: 101))
        XCTAssertEqual(power.rollover, CGRect(x: 439, y: 262, width: 16, height: 101))
        XCTAssertEqual(layout.box.minX - action.rest.minX, 3)
        XCTAssertEqual(power.rest.maxX - layout.box.maxX, 3)
        XCTAssertEqual(buttons.values.map(\.index).sorted(), [0, 1, 2, 3])
    }

    /// A top button placed from the box's trailing edge (`tablet5`'s power:
    /// x −74, y 8) and a button that would roll out past the padding widen
    /// the canvas on that side only.
    func testTopTrailingButtonsAndCanvasGrowth() {
        let power = AppleChromeDescriptor.Input(
            name: "power", title: "Sleep/Wake", usagePage: 12, usage: 48,
            image: "P", imageDown: nil, anchor: .top, align: .trailing,
            normal: CGPoint(x: -74, y: 8), rollover: CGPoint(x: -74, y: -4)
        )
        let chrome = AppleChromeDescriptor(
            identifier: "t",
            slices: .init(topLeft: "C", top: "H", topRight: "C", right: "V", bottomRight: "C", bottom: "H", bottomLeft: "C", left: "V"),
            sizing: .init(top: 46, left: 46, bottom: 46, right: 46),
            devicePadding: .init(top: 9, left: 0, bottom: 0, right: 10),
            inputs: [power]
        )
        let sizes: [String: CGSize] = [
            "C": CGSize(width: 96, height: 96), "H": CGSize(width: 2, height: 96), "V": CGSize(width: 96, height: 2),
            "P": CGSize(width: 63, height: 16),
        ]
        let layout = AppleChromeLayout.make(descriptor: chrome, screenPoints: CGSize(width: 834, height: 1210)) { sizes[$0] }
        // The box is 926 × 1302; the rolled-out power reaches 15 pt above
        // it, past the 9 pt padding, so the canvas grows 6 pt at the top.
        XCTAssertEqual(layout?.box, CGRect(x: 0, y: 15, width: 926, height: 1302))
        XCTAssertEqual(layout?.canvasSize, CGSize(width: 936, height: 1317))
        XCTAssertEqual(layout?.buttons.first?.rest, CGRect(x: 789, y: 12, width: 63, height: 16))
        XCTAssertEqual(layout?.buttons.first?.rest.maxX, 926 - 74)
    }

    /// A Home button drawn over the body sits its offset in from the box's
    /// bottom edge, centred (`phone`'s: y −90).
    func testAHomeButtonSitsInTheBottomBezel() {
        let home = AppleChromeDescriptor.Input(
            name: "home", title: "Home", usagePage: 12, usage: 64,
            image: "Home", imageDown: "Home Dn", downDrawMode: .compositeUnder, onTop: true,
            anchor: .bottom, align: .center, normal: CGPoint(x: 0, y: -90), rollover: CGPoint(x: 0, y: -90)
        )
        let rect = AppleChromeLayout.buttonRect(home, offset: home.normal, size: CGSize(width: 66, height: 66), box: CGRect(x: 0, y: 0, width: 431, height: 889))
        XCTAssertEqual(rect, CGRect(x: 182.5, y: 799, width: 66, height: 66))
    }

    func testAScreenOrSliceWithoutASizeIsNoFrame() throws {
        XCTAssertNil(AppleChromeLayout.make(descriptor: try phone11(), screenPoints: .zero) { Self.phone11Sizes[$0] })
        XCTAssertNil(AppleChromeLayout.make(descriptor: try phone11(), screenPoints: CGSize(width: 402, height: 874)) { $0 == "Phone BR" ? nil : Self.phone11Sizes[$0] })
    }

    /// The turn counts counter-clockwise from the native canvas: landscape
    /// left (1) puts the top edge on the left, as `CutoutPlacement` turns.
    func testTheTurnMapsTheNativeCanvas() {
        let size = CGSize(width: 10, height: 20)
        func map(_ point: CGPoint, _ turns: Int) -> CGPoint {
            point.applying(AppleChromeLayout.turn(canvas: size, quarterTurns: turns))
        }
        // The native top-left corner and top-right corner.
        XCTAssertEqual(map(.zero, 0), .zero)
        XCTAssertEqual(map(.zero, 1), CGPoint(x: 0, y: 10))
        XCTAssertEqual(map(CGPoint(x: 10, y: 0), 1), .zero)
        XCTAssertEqual(map(.zero, 2), CGPoint(x: 10, y: 20))
        XCTAssertEqual(map(.zero, 3), CGPoint(x: 20, y: 0))
        XCTAssertEqual(map(.zero, -1), map(.zero, 3))
        XCTAssertEqual(map(.zero, 5), map(.zero, 1))
    }

    /// The composition is in the screen's pixels (points × 3) and turns
    /// with the device: landscape left swaps the canvas and puts the screen
    /// where the turn takes it.
    func testThePlanIsInScreenPixelsAndTurns() throws {
        let frame = AppleChromeFrame(
            art: try Self.stubArt(),
            layout: try iPhone17ProLayout(),
            screenPixels: CGSize(width: 1206, height: 2622),
            scale: 3,
            cornerRadius: 62
        )
        let upright = DeviceCompositionPlanner.appleChrome(frame)
        XCTAssertEqual(upright.layoutSize, CGSize(width: 1368, height: 2730))
        XCTAssertEqual(upright.screenRect, CGRect(x: 81, y: 54, width: 1206, height: 2622))
        XCTAssertEqual(upright.screenCorner, ScreenCorner(radius: 186, source: .device))
        XCTAssertNil(upright.cutout)
        let left = DeviceCompositionPlanner.appleChrome(frame, quarterTurns: 1)
        XCTAssertEqual(left.layoutSize, CGSize(width: 2730, height: 1368))
        XCTAssertEqual(left.screenRect, CGRect(x: 54, y: 81, width: 2622, height: 1206))
        let right = DeviceCompositionPlanner.appleChrome(frame, quarterTurns: -1)
        guard case let .appleChrome(body) = right.body else { return XCTFail("an Apple chrome body") }
        XCTAssertEqual(body.quarterTurns, 3)
        // Placed, the whole canvas is the artwork frame.
        let placed = upright.placed(pointsPerUnit: 0.25, pixelScale: 2)
        XCTAssertEqual(placed.artworkFrame, CGRect(x: 0, y: 0, width: 342, height: 682.5))
        XCTAssertEqual(placed.screen, CGRect(x: 20.25, y: 13.5, width: 301.5, height: 655.5))
        XCTAssertTrue(placed.bands.isEmpty)
    }

    // MARK: - Pose

    func testOrientationAndRotationTurns() {
        XCTAssertEqual(SimulatorOrientation.allCases.map(AppleChromePose.turns(for:)), [0, 2, 1, 3])
        XCTAssertEqual(AppleChromePose.turns(for: .upright), 0)
        XCTAssertEqual(AppleChromePose.turns(for: .counterClockwise), 1)
        XCTAssertEqual(AppleChromePose.turns(for: .upsideDown), 2)
        XCTAssertEqual(AppleChromePose.turns(for: .clockwise), 3)
    }

    /// A frame's turn: what the session reported when it fits the frame's
    /// shape; a landscape frame otherwise follows a landscape device, else
    /// landscape left; a portrait frame is upright.
    func testTheContentTurnOfAFrame() {
        let native = CGSize(width: 1206, height: 2622)
        let portrait = native
        let landscape = CGSize(width: 2622, height: 1206)
        func turns(_ frame: CGSize, _ reported: SimulatorFrameRotation?, _ device: Int) -> Int {
            AppleChromePose.contentTurns(frame: frame, native: native, reported: reported, deviceTurns: device)
        }
        // The home screen stays portrait in a landscape device.
        XCTAssertEqual(turns(portrait, .upright, 1), 0)
        XCTAssertEqual(turns(portrait, nil, 1), 0)
        // An app that turned with the device.
        XCTAssertEqual(turns(landscape, .counterClockwise, 1), 1)
        XCTAssertEqual(turns(landscape, .clockwise, 3), 3)
        XCTAssertEqual(turns(landscape, nil, 3), 3)
        XCTAssertEqual(turns(landscape, nil, 0), 1)
        // A report that lags the frame's shape is not believed.
        XCTAssertEqual(turns(landscape, .upright, 3), 3)
        XCTAssertEqual(turns(portrait, .clockwise, 0), 0)
        // An iPad upside down.
        XCTAssertEqual(turns(portrait, .upsideDown, 2), 2)
        // A square frame never swaps.
        XCTAssertEqual(AppleChromePose.contentTurns(frame: CGSize(width: 5, height: 5), native: native, reported: nil, deviceTurns: 1), 0)
    }

    // MARK: - Turned screenshots

    /// A 2 × 1 image, red then green, turned once counter-clockwise, is 1 × 2
    /// with green on top (its right end turns up).
    func testAScreenshotTurns() throws {
        let image = try XCTUnwrap(Self.image(width: 2, height: 1) { x, _ in x == 0 ? (255, 0, 0) : (0, 255, 0) })
        let turned = try XCTUnwrap(DeviceFrameRenderer.turned(image, quarterTurns: 1))
        XCTAssertEqual(turned.width, 1)
        XCTAssertEqual(turned.height, 2)
        let pixels = try Self.pixels(turned)
        XCTAssertEqual(pixels.rgb(0, 0), [0, 255, 0])
        XCTAssertEqual(pixels.rgb(0, 1), [255, 0, 0])
        let back = try XCTUnwrap(DeviceFrameRenderer.turned(turned, quarterTurns: 3))
        XCTAssertEqual(try Self.pixels(back).rgb(0, 0), [255, 0, 0])
        XCTAssertTrue(DeviceFrameRenderer.turned(image, quarterTurns: 4) === image)
    }

    // MARK: - The installed chromes

    private static let deviceTypes = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Profiles/DeviceTypes", isDirectory: true)

    private func installedFrame(_ deviceType: String) throws -> AppleChromeFrame {
        let bundle = Self.deviceTypes.appendingPathComponent("\(deviceType).simdevicetype", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundle.path),
              FileManager.default.fileExists(atPath: AppleDeviceKit.defaultRoot.path)
        else { throw XCTSkip("no \(deviceType) device type or DeviceKit on this Mac") }
        let display = try XCTUnwrap(SimulatorDisplayProfile.read(deviceTypeBundle: bundle))
        return try XCTUnwrap(AppleChromeFrameProvider().frame(deviceTypeBundle: bundle, display: display))
    }

    /// iPhone 17 Pro names `phone11` and its screen outline; the installed
    /// chrome reads as the reduced JSON above and builds the same frame.
    func testTheInstalledIPhone17ProChrome() throws {
        let frame = try installedFrame("iPhone 17 Pro")
        XCTAssertEqual(frame.chromeName, "phone11")
        XCTAssertTrue(frame.art.hasMask)
        XCTAssertEqual(frame.art.maskURL?.lastPathComponent, "4E5532ED-1470-47D1-BDF4-7AA90C26957A.pdf")
        XCTAssertEqual(frame.art.descriptor, try phone11())
        XCTAssertEqual(frame.layout, try iPhone17ProLayout())
        XCTAssertEqual(frame.scale, 3)
        XCTAssertEqual(frame.cornerRadius, 62)
        XCTAssertEqual(frame.screenPixels, CGSize(width: 1206, height: 2622))
    }

    /// iPad Pro 11-inch (M5) names `tablet5`: a 46 pt box, the volume on the
    /// right and the power on top (Device Hub: 45 pt of bezel, SIM-17).
    func testTheInstalledIPadChrome() throws {
        let frame = try installedFrame("iPad Pro 11-inch (M5)")
        XCTAssertEqual(frame.chromeName, "tablet5")
        XCTAssertTrue(frame.art.hasMask)
        XCTAssertEqual(frame.layout.screen.size, CGSize(width: 834, height: 1210))
        XCTAssertEqual(frame.layout.screen.minX - frame.layout.box.minX, 46)
        XCTAssertEqual(frame.layout.box.size, CGSize(width: 926, height: 1302))
        XCTAssertEqual(Set(frame.layout.buttons.map(\.input.anchor)), [.right, .top])
    }

    /// Apple TV device types name no chrome: the stage keeps the vector body.
    func testTheInstalledAppleTVHasNoChrome() throws {
        let bundle = Self.deviceTypes.appendingPathComponent("Apple TV 4K (3rd generation).simdevicetype", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundle.path) else { throw XCTSkip("no Apple TV device type on this Mac") }
        let display = try XCTUnwrap(SimulatorDisplayProfile.read(deviceTypeBundle: bundle))
        XCTAssertNil(AppleChromeFrameProvider().frame(deviceTypeBundle: bundle, display: display))
    }

    /// Without DeviceKit (a missing folder) there is no chrome.
    func testAMissingDeviceKitIsNoChrome() throws {
        let bundle = Self.deviceTypes.appendingPathComponent("iPhone 17 Pro.simdevicetype", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundle.path) else { throw XCTSkip("no iPhone 17 Pro device type on this Mac") }
        let display = try XCTUnwrap(SimulatorDisplayProfile.read(deviceTypeBundle: bundle))
        let missing = AppleDeviceKit(root: FileManager.default.temporaryDirectory.appendingPathComponent("no-devicekit-\(UUID().uuidString)"))
        XCTAssertNil(AppleChromeFrameProvider(deviceKit: missing).frame(deviceTypeBundle: bundle, display: display))
        XCTAssertNil(missing.chromeBundle(identifier: "com.apple.dt.devicekit.chrome.phone11"))
        XCTAssertNil(AppleDeviceKit().framebufferMask(identifier: "../FramebufferMasks/x"))
    }

    /// The installed `phone11` drawn at 1 px per unit (3 px a point): the
    /// body's bands at the box's edge as Device Hub draws them (a clear
    /// point, the rim, the #7E7E7E highlight, #2C2C2C for 5 pt, then black),
    /// the screen from 18 pt in, its corner black outside the outline, and
    /// the side buttons standing 3 pt past the box.
    func testTheInstalledChromeDraws() throws {
        let frame = try installedFrame("iPhone 17 Pro")
        let plan = DeviceCompositionPlanner.appleChrome(frame)
        let image = try XCTUnwrap(DeviceCompositionRenderer.render(plan, pixelsPerUnit: 1) { context, rect in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(rect)
        })
        XCTAssertEqual(image.width, 1368)
        XCTAssertEqual(image.height, 2730)
        let pixels = try Self.pixels(image)
        let row = 1365 // the middle, clear of every button
        // Box at x 27 px (9 pt).
        XCTAssertEqual(pixels.alpha(28, row), 0)
        XCTAssertEqual(pixels.alpha(31, row), 38, accuracy: 2)
        XCTAssertEqual(pixels.rgb(34, row), [126, 126, 126])
        XCTAssertEqual(pixels.rgb(40, row), [44, 44, 44])
        XCTAssertEqual(pixels.rgb(60, row), [0, 0, 0])
        XCTAssertEqual(pixels.rgb(80, row), [0, 0, 0])
        XCTAssertEqual(pixels.rgb(81, row), [255, 0, 0])
        XCTAssertEqual(pixels.rgb(1286, row), [255, 0, 0])
        XCTAssertEqual(pixels.rgb(1287, row), [0, 0, 0])
        // The screen's top-left corner is outside its outline.
        XCTAssertEqual(pixels.rgb(82, 55), [0, 0, 0])
        XCTAssertEqual(pixels.rgb(684, 55), [255, 0, 0])
        // The volume-up button (221 pt down) stands left of the box.
        XCTAssertGreaterThan(pixels.alpha(22, 221 * 3 + 90), 200)
        XCTAssertEqual(pixels.alpha(22, row), 0)
    }

    /// At a scale where the slices meet inside pixels (0.37 px a unit) the
    /// body shows no seam: down the grey band, across the top-left corner's
    /// edge and the left slice, every pixel is opaque.
    func testTheSlicesMeetWithoutASeam() throws {
        let frame = try installedFrame("iPhone 17 Pro")
        let scale: CGFloat = 0.37
        let image = try XCTUnwrap(DeviceCompositionRenderer.render(DeviceCompositionPlanner.appleChrome(frame), pixelsPerUnit: scale) { _, _ in })
        let pixels = try Self.pixels(image)
        // The grey band's middle: 9 + 1 + 1 + 1 + 2.5 pt in.
        let x = Int((14.5 * 3 * scale).rounded(.down))
        let from = Int((80 * 3 * scale).rounded(.up))
        let to = Int((840 * 3 * scale).rounded(.down))
        let translucent = (from...to).filter { pixels.alpha(x, $0) < 255 }
        XCTAssertEqual(translucent, [], "column \(x)")
    }

    // MARK: - Helpers

    /// A chrome art without files: enough for planning (its sizes are the
    /// layout's own), never drawn.
    static func stubArt() throws -> AppleChromeArt {
        AppleChromeArt(
            descriptor: try XCTUnwrap(AppleChromeDescriptor.parse(chromeJSON: Data(phone11JSON.utf8))),
            bundle: URL(fileURLWithPath: "/nonexistent/phone11.devicechrome"),
            maskURL: nil,
            documents: [:],
            maskDocument: nil
        )
    }

    struct Pixels {
        let width: Int
        let bytes: [UInt8]

        func alpha(_ x: Int, _ y: Int) -> Int { Int(bytes[(y * width + x) * 4 + 3]) }

        /// Straight RGB.
        func rgb(_ x: Int, _ y: Int) -> [Int] {
            let offset = (y * width + x) * 4
            let alpha = Int(bytes[offset + 3])
            guard alpha > 0 else { return [0, 0, 0] }
            return (0..<3).map { min(255, Int((Double(bytes[offset + $0]) * 255 / Double(alpha)).rounded())) }
        }
    }

    static func pixels(_ image: CGImage) throws -> Pixels {
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
        return Pixels(width: image.width, bytes: bytes)
    }

    static func image(width: Int, height: Int, color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let offset = (y * width + x) * 4
                bytes[offset] = r
                bytes[offset + 1] = g
                bytes[offset + 2] = b
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
