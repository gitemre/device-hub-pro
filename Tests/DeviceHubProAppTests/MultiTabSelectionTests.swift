import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// A second tab: opening another device in a new
/// tab must not take or stop the first tab's mirror, a second tab's sidebar
/// gestures must write that tab's own selection (they wrote the model's
/// first workspace's, so the new tab's sidebar looked frozen and the first
/// tab's stage routed on the wrong selection), and a refused attach is said
/// aloud rather than dropped.
@MainActor
final class MultiTabSelectionTests: XCTestCase {
    private let emulator = AndroidDevice.online("emulator-5554", transport: "3", model: "sdk_gphone64_arm64")

    private func twoTabs() -> (model: AppModel, tabA: DeviceWorkspace, tabB: DeviceWorkspace, session: FakeMirrorSession) {
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        let tabA = model.workspace
        let tabB = DeviceWorkspace(services: model.services)
        model.registry.register(tabB)
        let session = FakeMirrorSession()
        tabA.beginMirrorSession(
            session, device: .android(emulator.serial), port: nil,
            avdName: "Pixel_10_Pro", capabilities: .android(emulatorGrpc: true)
        )
        tabA.deviceSelection = .device(emulator.serial)
        return (model, tabA, tabB, session)
    }

    /// The sidebar of a tab other than the model's first writes its own
    /// selection and leaves the first tab's alone.
    func testSecondTabSidebarGesturesWriteItsOwnSelection() {
        let (model, tabA, tabB, _) = twoTabs()
        let phone = DeviceSelection.physicalApple("00000000-0000-4000-8000-00000000F001")

        model.selectOnlyRow(phone, in: tabB)
        XCTAssertEqual(tabB.deviceSelection, phone)
        XCTAssertEqual(tabA.deviceSelection, .device(emulator.serial), "tab A's selection is untouched")

        model.toggleRow(.avd("Pixel_10_Pro"), in: tabB)
        XCTAssertEqual(tabB.deviceSelection, .avd("Pixel_10_Pro"))
        XCTAssertFalse(tabA.multiSelection.contains(.avd("Pixel_10_Pro")))

        model.selectAllRows([.avd("A"), .avd("B")], in: tabB)
        XCTAssertEqual(tabA.deviceSelection, .device(emulator.serial))
    }

    /// Opening the phone in a new tab, then closing that tab, leaves tab A's
    /// session, claim and ownership exactly as they were.
    func testNewTabOnAnotherDeviceNeverTakesOrStopsTheFirstTabsMirror() {
        let (model, tabA, tabB, session) = twoTabs()
        tabB.deviceSelection = .physicalApple("00000000-0000-4000-8000-00000000F001")
        XCTAssertTrue(tabA.mirror.session === session)
        XCTAssertEqual(session.stopCount, 0)
        XCTAssertTrue(model.registry.owner(of: .android(emulator.serial)) === tabA)

        tabB.closeForWindow()
        XCTAssertTrue(tabA.mirror.session === session)
        XCTAssertEqual(session.stopCount, 0)
        XCTAssertTrue(model.registry.owner(of: .android(emulator.serial)) === tabA)
    }

    /// Attaching a device another tab shows is refused, says who owns it, and
    /// leaves the owning workspace's session running.
    func testAttachingADeviceAnotherTabShowsReportsTheOwner() async {
        let (model, tabA, tabB, session) = twoTabs()
        let outcome = await tabB.mirror(device: emulator)
        XCTAssertEqual(outcome, .ownedElsewhere(tabA.id))
        XCTAssertTrue(tabA.mirror.session === session)
        XCTAssertNil(tabB.mirror.session)
        XCTAssertTrue(model.registry.owner(of: .android(emulator.serial)) === tabA)
    }

    /// Routing reads each workspace's own selection: tab B on the phone has
    /// no live Android serial whatever tab A shows.
    func testLiveSelectionSerialIsPerWorkspace() {
        let (_, tabA, tabB, _) = twoTabs()
        tabB.deviceSelection = .physicalApple("00000000-0000-4000-8000-00000000F001")
        XCTAssertNil(tabB.liveSelectionSerial)
        XCTAssertEqual(tabA.deviceSelection, .device(emulator.serial))
    }
}
