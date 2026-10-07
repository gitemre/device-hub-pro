import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// What the stage does for a TV, a watch and a car: no Rotate, a pose that
/// stays natural, a remote for a TV, and a glyph that says what the device is.
@MainActor
final class TVWearStageTests: XCTestCase {
    func testOnlyHandheldsAndAppleHandheldsRotate() {
        for family in ControlsFamily.allCases {
            switch family {
            case .androidHandheld, .iPhone, .iPad, .physicalApple:
                XCTAssertTrue(family.rotates, "\(family)")
            default:
                XCTAssertFalse(family.rotates, "\(family) keeps its orientation")
            }
        }
        XCTAssertEqual(ControlsFamily.android(.tv), .androidTV)
        XCTAssertFalse(ControlsFamily.android(.tv).rotates)
        XCTAssertFalse(ControlsFamily.android(.wear).rotates)
        XCTAssertFalse(ControlsFamily.android(.automotive).rotates)
        XCTAssertTrue(ControlsFamily.android(nil).rotates, "unread: offered as before")
    }

    func testOnlyTVsHaveARemote() {
        let withRemote = ControlsFamily.allCases.filter(\.hasRemote)
        XCTAssertEqual(Set(withRemote), [.androidTV, .appleTV])
    }

    /// The Google TV emulator's physical model reported `rotation` -90 with
    /// its AVD saying `hw.initialOrientation=portrait` for a 1920x1080 LCD
    /// (measured over gRPC, 2026-10-01); the stage turned the TV into a
    /// portrait phone. A TV, a watch or a car keeps its natural pose.
    func testAnEmulatorTVKeepsItsNaturalPoseWhateverTheModelReports() {
        XCTAssertEqual(MirrorController.emulatorPoseTurns(degrees: -90, formFactor: .tv), 0)
        XCTAssertEqual(MirrorController.emulatorPoseTurns(degrees: 90, formFactor: .wear), 0)
        XCTAssertEqual(MirrorController.emulatorPoseTurns(degrees: 180, formFactor: .automotive), 0)
        XCTAssertEqual(MirrorController.emulatorPoseTurns(degrees: -90, formFactor: .handheld), 3)
        XCTAssertEqual(MirrorController.emulatorPoseTurns(degrees: 0, formFactor: .handheld), 0)
    }

    func testAnAvdWithNoSkinStillGetsItsClassGlyph() {
        XCTAssertEqual(DeviceSidebarView.symbol(forSkin: nil, formFactor: .automotive), "car")
        XCTAssertEqual(DeviceSidebarView.symbol(forSkin: nil, formFactor: .tv), "tv")
        XCTAssertEqual(DeviceSidebarView.symbol(forSkin: nil, formFactor: .wear), "applewatch.side.right")
        XCTAssertEqual(DeviceSidebarView.symbol(forSkin: nil, formFactor: .handheld), "smartphone")
        XCTAssertEqual(DeviceSidebarView.symbol(forSkin: nil), "smartphone")
    }

    /// An Apple TV simulator's groups hold only rows the family offers, and
    /// no group is left without one (a header over nothing).
    func testAnAppleTVPanelHasNoEmptyGroup() {
        for devicectl in [false, true] {
            let groups = appleSimulatorGroups(
                route: { AppleControlsRouting.route($0, available: AppleControlsRouting.available(devicectl: devicectl)) },
                supportsBiometrics: nil,
                family: .appleTV
            )
            XCTAssertFalse(groups.isEmpty)
            for group in groups {
                XCTAssertFalse(group.rows.isEmpty, "\(group.id)")
                for row in group.rows {
                    XCTAssertTrue(row.availability(on: .appleTV).isVisible, "\(row)")
                }
            }
        }
    }

    func testTheMacKeysACustomRemoteTakes() {
        XCTAssertNotNil(RemoteKey.up.appleTVKeyUsage)
        XCTAssertEqual(RemoteKey.select.appleTVKeyUsage, 0x28, "Return")
        XCTAssertEqual(RemoteKey.back.appleTVKeyUsage, 0x29, "Escape")
        XCTAssertNil(RemoteKey.home.appleTVKeyUsage)
        XCTAssertNil(RemoteKey.playPause.appleTVKeyUsage)
        XCTAssertEqual(RemoteKey.appleTVKeys.compactMap(\.appleTVKeyUsage).count, RemoteKey.appleTVKeys.count)
    }
}
