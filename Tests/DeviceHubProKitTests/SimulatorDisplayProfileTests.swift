import XCTest
@testable import DeviceHubProKit

/// `SimulatorDisplayProfile`: a device type's main display from its
/// `capabilities.plist`, and the `DisplayShape` the vector body is planned
/// from.
///
/// The plist is Apple's and is never copied into the repository (design
/// §3.1), so no fixture holds it. The dictionaries below carry only the keys
/// the parser reads, with the values of the installed device types they are
/// named after, read on 2026-09-26 with `plutil -p` from
/// `/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone 17
/// Pro.simdevicetype/Contents/Resources/capabilities.plist` (Xcode 27.0
/// 27A266a). `testTheInstalledIPhone17ProReadsTheSame` reads the installed
/// file itself when the Mac has it.
final class SimulatorDisplayProfileTests: XCTestCase {
    /// iPhone 17 Pro: `displays[0]` is the integrated 1206×2622 @3x panel
    /// with 62 pt corners at 460 dpi; `displays[1]` a TVOut output.
    private static var iPhone17Pro: [String: Any] { [
        "DeviceCornerRadius": 62,
        "DeviceSupportsDynamicIsland": true,
        "displays": [
            [
                "chromeIdentifier": "com.apple.dt.devicekit.chrome.phone11",
                "cornerRadiusLL": 62,
                "cornerRadiusLR": 62,
                "cornerRadiusUL": 62,
                "cornerRadiusUR": 62,
                "displayType": "integrated",
                "framebufferMaskIdentifier": "4E5532ED-1470-47D1-BDF4-7AA90C26957A",
                "hdpi": 460,
                "height": 2622,
                "scale": 3,
                "vdpi": 460,
                "width": 1206,
            ],
            [
                "displayType": "tvOut",
                "hdpi": 72,
                "height": 480,
                "scale": 1,
                "vdpi": 72,
                "width": 720,
            ],
        ] as [[String: Any]],
    ] }

    func testTheIntegratedDisplayIsRead() throws {
        let profile = try XCTUnwrap(SimulatorDisplayProfile.parse(capabilities: Self.iPhone17Pro))
        XCTAssertEqual(profile.width, 1206)
        XCTAssertEqual(profile.height, 2622)
        XCTAssertEqual(profile.scale, 3)
        XCTAssertEqual(profile.topLeftRadius, 62)
        XCTAssertEqual(profile.bottomRightRadius, 62)
        XCTAssertEqual(profile.horizontalDpi, 460)
        XCTAssertEqual(profile.chromeIdentifier, "com.apple.dt.devicekit.chrome.phone11")
        XCTAssertEqual(profile.framebufferMaskIdentifier, "4E5532ED-1470-47D1-BDF4-7AA90C26957A")
        XCTAssertTrue(profile.hasDynamicIsland, "the device type's own capability key")
    }

    /// Without the key (or with it false, an iPhone 17e) there is no island.
    func testAnIslandIsOnlyWhereTheCapabilitySaysSo() throws {
        var capabilities = Self.iPhone17Pro
        capabilities["DeviceSupportsDynamicIsland"] = false
        XCTAssertFalse(try XCTUnwrap(SimulatorDisplayProfile.parse(capabilities: capabilities)).hasDynamicIsland)
        capabilities.removeValue(forKey: "DeviceSupportsDynamicIsland")
        XCTAssertFalse(try XCTUnwrap(SimulatorDisplayProfile.parse(capabilities: capabilities)).hasDynamicIsland)
    }

    /// The integrated panel is chosen wherever it is listed.
    func testTheIntegratedDisplayWinsOverAnOutputListedFirst() throws {
        var capabilities = Self.iPhone17Pro
        let displays = try XCTUnwrap(capabilities["displays"] as? [[String: Any]])
        capabilities["displays"] = Array(displays.reversed())
        let profile = try XCTUnwrap(SimulatorDisplayProfile.parse(capabilities: capabilities))
        XCTAssertEqual(profile.width, 1206)
    }

    /// The shape: corners in pixels (62 pt × 3 = 186 px) centred a radius
    /// in from each corner, the physical dpi, a logical 480 dpi (160 × 3:
    /// one point per dp), a built-in panel that is on, no cutout.
    func testTheShapeHasThePixelCorners() throws {
        let shape = try XCTUnwrap(SimulatorDisplayProfile.parse(capabilities: Self.iPhone17Pro))
            .displayShape(id: "simulator:com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")
        XCTAssertEqual(shape.width, 1206)
        XCTAssertEqual(shape.height, 2622)
        XCTAssertEqual(shape.maxCornerRadius, 186)
        XCTAssertEqual(shape.topLeft, DisplayShape.RoundedCorner(radius: 186, centerX: 186, centerY: 186))
        XCTAssertEqual(shape.topRight, DisplayShape.RoundedCorner(radius: 186, centerX: 1020, centerY: 186))
        XCTAssertEqual(shape.bottomRight, DisplayShape.RoundedCorner(radius: 186, centerX: 1020, centerY: 2436))
        XCTAssertEqual(shape.bottomLeft, DisplayShape.RoundedCorner(radius: 186, centerX: 186, centerY: 2436))
        XCTAssertEqual(shape.densityDpi, 480)
        XCTAssertEqual(shape.xDpi, 460)
        XCTAssertTrue(shape.isBuiltIn)
        XCTAssertTrue(shape.isOn)
        XCTAssertNil(shape.cutout)
    }

    /// The planner makes the iPhone a phone body with the device's own
    /// corner, in either orientation of the frame.
    func testThePlannerDrawsAPhoneWithTheDeviceCorner() throws {
        let shape = try XCTUnwrap(SimulatorDisplayProfile.parse(capabilities: Self.iPhone17Pro))
            .displayShape(id: "iPhone-17-Pro")
        for screen in [CGSize(width: 1206, height: 2622), CGSize(width: 2622, height: 1206)] {
            let plan = DeviceCompositionPlanner.vector(
                screen: screen,
                displays: [shape],
                fallbackDensityDpi: nil,
                quarterTurns: 0
            )
            XCTAssertEqual(plan.screenCorner.source, .device, "\(screen)")
            XCTAssertEqual(plan.screenCorner.radius, 186, accuracy: 0.001, "\(screen)")
            guard case let .vector(body) = plan.body else { return XCTFail("a vector body") }
            XCTAssertEqual(body.family, .phone)
        }
    }

    /// A display without corner keys takes the device's corner; without that
    /// too, square corners. A display without a size is no profile.
    func testCornerFallbacksAndMissingSizes() throws {
        let bare: [String: Any] = ["displays": [["width": 750, "height": 1334, "scale": 2, "displayType": "integrated"]]]
        let square = try XCTUnwrap(SimulatorDisplayProfile.parse(capabilities: bare))
        XCTAssertEqual(square.displayShape(id: "x").maxCornerRadius, 0)
        XCTAssertNil(square.displayShape(id: "x").topLeft)

        var withDeviceCorner = bare
        withDeviceCorner["DeviceCornerRadius"] = 39
        let rounded = try XCTUnwrap(SimulatorDisplayProfile.parse(capabilities: withDeviceCorner))
        XCTAssertEqual(rounded.displayShape(id: "x").maxCornerRadius, 78)

        XCTAssertNil(SimulatorDisplayProfile.parse(capabilities: ["displays": [["scale": 2]]]))
        XCTAssertNil(SimulatorDisplayProfile.parse(capabilities: [:]))
        XCTAssertNil(SimulatorDisplayProfile.parse(capabilitiesPlist: Data("not a plist".utf8)))
    }

    /// The installed iPhone 17 Pro device type, read at runtime as the app
    /// reads it; skipped on a Mac without it.
    func testTheInstalledIPhone17ProReadsTheSame() throws {
        let bundle = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone 17 Pro.simdevicetype")
        guard FileManager.default.fileExists(atPath: bundle.path) else {
            throw XCTSkip("no iPhone 17 Pro device type on this Mac")
        }
        let installed = try XCTUnwrap(SimulatorDisplayProfile.read(deviceTypeBundle: bundle))
        XCTAssertEqual(installed, SimulatorDisplayProfile.parse(capabilities: Self.iPhone17Pro))
    }
}
