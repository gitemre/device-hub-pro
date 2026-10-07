import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// The routing matrix: which serial the stage and the inspector show, what a
/// stale selection becomes, and what counts as booting or startable.
final class SelectionRoutingTests: XCTestCase {
    private typealias Routing = SelectionRouting

    // MARK: - Fixtures

    private static func skin(_ name: String) -> ResolvedSkin {
        ResolvedSkin(
            name: name,
            directory: URL(fileURLWithPath: "/skins/\(name)"),
            source: .skinName,
            variants: []
        )
    }

    private static func card(
        _ name: String,
        skin: String? = nil,
        running: Bool = false,
        serial: String? = nil
    ) -> AvdCard {
        AvdCard(
            name: name,
            displayName: name,
            target: "android-35",
            skin: skin.map(Self.skin),
            isRunning: running,
            serial: serial
        )
    }

    private static func catalogEntry(_ name: String) -> SkinCatalogEntry {
        SkinCatalogEntry(
            name: name,
            displayName: name,
            category: .phone,
            directory: URL(fileURLWithPath: "/skins/\(name)"),
            variants: []
        )
    }

    private static func online(_ serial: String) -> AndroidDevice {
        AndroidDevice(serial: serial, state: "device")
    }

    private static func offline(_ serial: String) -> AndroidDevice {
        AndroidDevice(serial: serial, state: "offline")
    }

    /// A running Pixel 9 AVD online on emulator-5554, a stopped Pixel 8, a
    /// physical phone online, a ghost row for a phone that dropped off and
    /// an offline emulator row.
    private static let snapshot = Routing.Snapshot(
        devices: [
            online("emulator-5554"),
            online("R58M123"),
            // The synthetic ghost: a vanished phone's row, never online.
            AndroidDevice(serial: "GHOST01", state: "offline", model: "Pixel 7"),
            offline("emulator-5556"),
        ],
        avdCards: [
            card("Pixel_9", skin: "pixel_9", running: true, serial: "emulator-5554"),
            card("Pixel_8", skin: "pixel_8"),
            card("Offline_AVD", running: true, serial: "emulator-5556"),
        ],
        avds: ["Pixel_9", "Pixel_8", "Offline_AVD"],
        skinCatalog: [catalogEntry("pixel_9"), catalogEntry("pixel_8"), catalogEntry("pixel_fold")]
    )

    // MARK: - Live serial

    func testLiveSerialMatrix() {
        let cases: [(DeviceSelection?, String?, String)] = [
            (.avd("Pixel_9"), "emulator-5554", "an online AVD is live"),
            (.avd("Pixel_8"), nil, "a stopped AVD has no serial"),
            (.avd("Offline_AVD"), nil, "an AVD whose row is offline is not live"),
            (.avd("Gone"), nil, "an unknown AVD"),
            (.device("R58M123"), "R58M123", "an online phone is live"),
            (.device("GHOST01"), nil, "the ghost row is never live"),
            (.device("emulator-5556"), nil, "an offline row is not live"),
            (.device("NOPE"), nil, "a serial with no row"),
            (.pixel("pixel_9"), "emulator-5554", "a Pixel row routes through its AVD"),
            (.pixel("pixel_8"), nil, "a Pixel row whose AVD is stopped"),
            (.pixel("pixel_fold"), nil, "a Pixel row with no AVD"),
            (nil, nil, "no selection"),
        ]
        for (selection, expected, label) in cases {
            XCTAssertEqual(Routing.liveSelectionSerial(for: selection, in: Self.snapshot), expected, label)
        }
    }

    func testABootingAvdHidesItsLiveSerial() {
        // The hot-plug pass already knows the serial, but the in-app start
        // keeps its booting panel until its own session starts.
        var snapshot = Self.snapshot
        snapshot.startingAvdNames = ["Pixel_9"]
        XCTAssertNil(Routing.liveSelectionSerial(for: .avd("Pixel_9"), in: snapshot))
        XCTAssertNil(Routing.liveSelectionSerial(for: .pixel("pixel_9"), in: snapshot))
        // Another AVD's boot hides nothing else.
        XCTAssertEqual(Routing.liveSelectionSerial(for: .device("R58M123"), in: snapshot), "R58M123")
    }

    func testAPixelRowRoutesThroughItsFirstAvd() {
        var snapshot = Self.snapshot
        snapshot.avdCards.insert(Self.card("Pixel_9_Stopped", skin: "pixel_9"), at: 0)
        XCTAssertNil(
            Routing.liveSelectionSerial(for: .pixel("pixel_9"), in: snapshot),
            "the first AVD with the skin decides, even when a later one runs"
        )
    }

    // MARK: - Inspector serial

    func testInspectorSerialFallsBackToTheKnownSerial() {
        let cases: [(DeviceSelection?, String?, String)] = [
            (.avd("Pixel_9"), "emulator-5554", "live"),
            (.avd("Offline_AVD"), "emulator-5556", "an offline AVD's serial is still known"),
            (.avd("Pixel_8"), nil, "a stopped AVD has no serial"),
            (.device("GHOST01"), "GHOST01", "the ghost row's serial"),
            (.device("NOPE"), "NOPE", "a device selection names its serial"),
            (.pixel("pixel_9"), "emulator-5554", "a Pixel row's AVD"),
            (.pixel("pixel_fold"), nil, "a Pixel row with no AVD"),
            (nil, nil, "no selection"),
        ]
        for (selection, expected, label) in cases {
            XCTAssertEqual(Routing.inspectorSerial(for: selection, in: Self.snapshot), expected, label)
        }
    }

    func testInspectorSerialOfABootingAvdIsItsCardSerial() {
        var snapshot = Self.snapshot
        snapshot.startingAvdNames = ["Pixel_9"]
        XCTAssertEqual(Routing.inspectorSerial(for: .avd("Pixel_9"), in: snapshot), "emulator-5554")
    }

    // MARK: - Ensure selection

    func testAValidSelectionIsKept() {
        for selection: DeviceSelection in [
            .avd("Pixel_8"),
            .device("GHOST01"),
            .device("emulator-5556"),
            .pixel("pixel_fold"),
        ] {
            XCTAssertEqual(Routing.ensureTarget(for: selection, in: Self.snapshot), .keep, "\(selection)")
        }
    }

    /// Device Hub shows "No Selection" when the selected device disappears;
    /// it does not jump to another one.
    func testAStaleSelectionEndsInNoSelection() {
        XCTAssertEqual(Routing.ensureTarget(for: .avd("Gone"), in: Self.snapshot), .assign(nil))
        XCTAssertEqual(Routing.ensureTarget(for: .device("NOPE"), in: Self.snapshot), .assign(nil))
        XCTAssertEqual(Routing.ensureTarget(for: .pixel("nope"), in: Self.snapshot), .assign(nil))
    }

    func testNothingSelectedPicksTheFirstOnlineDeviceOnlyAtFirst() {
        // emulator-5554 is online and belongs to Pixel_9: its AVD row wins.
        XCTAssertEqual(Routing.ensureTarget(for: nil, in: Self.snapshot), .assign(.avd("Pixel_9")))
        // A window that lost its device keeps saying No Selection.
        XCTAssertEqual(Routing.ensureTarget(for: nil, in: Self.snapshot, autoSelect: false), .keep)
    }

    func testAnOnlineDeviceWithoutAnAvdIsSelectedAsADevice() {
        let snapshot = Routing.Snapshot(
            devices: [Self.offline("emulator-5556"), Self.online("R58M123")],
            avdCards: [Self.card("Pixel_8")],
            avds: ["Pixel_8"]
        )
        XCTAssertEqual(Routing.ensureTarget(for: nil, in: snapshot), .assign(.device("R58M123")))
    }

    func testWithNothingOnlineTheFirstAvdIsSelected() {
        let snapshot = Routing.Snapshot(
            devices: [Self.offline("emulator-5556")],
            avdCards: [Self.card("Pixel_8"), Self.card("Pixel_9")],
            avds: ["Pixel_8", "Pixel_9"]
        )
        XCTAssertEqual(Routing.ensureTarget(for: nil, in: snapshot), .assign(.avd("Pixel_8")))
    }

    func testWithNothingAtAllTheSelectionIsAssignedNil() {
        // Assigned even when it already is nil: the assignment runs the
        // selection's didSet, as `ensureDeviceSelection()` does today.
        XCTAssertEqual(Routing.ensureTarget(for: nil, in: Routing.Snapshot()), .assign(nil))
        XCTAssertEqual(Routing.ensureTarget(for: .avd("Gone"), in: Routing.Snapshot()), .assign(nil))
    }

    func testSelectingADeviceMergesItWithItsAvdCard() {
        XCTAssertEqual(Routing.selection(for: Self.online("emulator-5554"), in: Self.snapshot), .avd("Pixel_9"))
        XCTAssertEqual(Routing.selection(for: Self.online("R58M123"), in: Self.snapshot), .device("R58M123"))
    }

    // MARK: - Booting

    func testAvdIsBootingMatrix() {
        var snapshot = Self.snapshot
        snapshot.avdCards.append(Self.card("No_Serial_Yet", running: true))
        snapshot.startingAvdNames = ["Pixel_8"]
        XCTAssertTrue(Routing.avdIsBooting("Pixel_8", in: snapshot), "an in-app start")
        XCTAssertTrue(Routing.avdIsBooting("No_Serial_Yet", in: snapshot), "running with no adb serial yet")
        XCTAssertTrue(Routing.avdIsBooting("Offline_AVD", in: snapshot), "running with its adb row offline")
        XCTAssertFalse(Routing.avdIsBooting("Pixel_9", in: snapshot), "online")
        XCTAssertFalse(Routing.avdIsBooting("Gone", in: snapshot), "unknown")
    }

    func testARunningAvdWhoseSerialHasNoRowIsBooting() {
        let snapshot = Routing.Snapshot(avdCards: [Self.card("Pixel_9", running: true, serial: "emulator-5554")])
        XCTAssertTrue(Routing.avdIsBooting("Pixel_9", in: snapshot))
    }

    // MARK: - Sidebar Return

    func testReturnStartsOnlyAStoppedAvd() {
        XCTAssertEqual(Routing.sidebarStartTarget(for: .avd("Pixel_8"), isBusy: false, in: Self.snapshot), "Pixel_8")
        XCTAssertEqual(
            Routing.sidebarStartTarget(for: .pixel("pixel_8"), isBusy: false, in: Self.snapshot),
            "Pixel_8",
            "through its Pixel row"
        )
        XCTAssertNil(Routing.sidebarStartTarget(for: .avd("Pixel_9"), isBusy: false, in: Self.snapshot), "running")
        XCTAssertNil(Routing.sidebarStartTarget(for: .avd("Offline_AVD"), isBusy: false, in: Self.snapshot), "booting")
        XCTAssertNil(Routing.sidebarStartTarget(for: .avd("Gone"), isBusy: false, in: Self.snapshot), "not installed")
        XCTAssertNil(Routing.sidebarStartTarget(for: .pixel("pixel_fold"), isBusy: false, in: Self.snapshot), "no AVD")
        XCTAssertNil(Routing.sidebarStartTarget(for: .device("R58M123"), isBusy: false, in: Self.snapshot))
        XCTAssertNil(Routing.sidebarStartTarget(for: nil, isBusy: false, in: Self.snapshot))
    }

    func testReturnStartsNothingWhileBusyOrStarting() {
        XCTAssertNil(Routing.sidebarStartTarget(for: .avd("Pixel_8"), isBusy: true, in: Self.snapshot))
        var snapshot = Self.snapshot
        snapshot.startingAvdNames = ["Pixel_8"]
        XCTAssertNil(Routing.sidebarStartTarget(for: .avd("Pixel_8"), isBusy: false, in: snapshot))
    }

    func testReturnLeavesAStoppedCardWhoseSerialIsOnlineAlone() {
        // The gallery's `ps` pass has not flipped the card yet, but adb
        // already lists it online.
        let snapshot = Routing.Snapshot(
            devices: [Self.online("emulator-5554")],
            avdCards: [Self.card("Pixel_9", serial: "emulator-5554")]
        )
        XCTAssertNil(Routing.sidebarStartTarget(for: .avd("Pixel_9"), isBusy: false, in: snapshot))
    }

    // MARK: - Parity with today's AppModel members

    /// Pins the core to the `AppModel` members it replaces until S22 routes
    /// them through it (`startingAvdNames` cannot be set from a test, so the
    /// booting cases are covered above).
    @MainActor
    func testTheCoreAnswersLikeTheModel() {
        let model = AppModel.testing()
        model.inventory.devices = Self.snapshot.devices
        model.catalog.avdCards = Self.snapshot.avdCards
        model.catalog.avds = Self.snapshot.avds
        model.catalog.skinCatalog = Self.snapshot.skinCatalog
        let selections: [DeviceSelection?] = [
            .avd("Pixel_9"), .avd("Pixel_8"), .avd("Offline_AVD"), .avd("Gone"),
            .device("R58M123"), .device("GHOST01"), .device("emulator-5556"), .device("NOPE"),
            .pixel("pixel_9"), .pixel("pixel_8"), .pixel("pixel_fold"), .pixel("nope"),
            nil,
        ]
        for selection in selections {
            model.workspace.window.selectionWasLost = false
            model.deviceSelection = selection
            let label = String(describing: selection)
            XCTAssertEqual(model.liveSelectionSerial, Routing.liveSelectionSerial(for: selection, in: Self.snapshot), label)
            XCTAssertEqual(model.inspectorSerial, Routing.inspectorSerial(for: selection, in: Self.snapshot), label)
            XCTAssertEqual(
                model.sidebarStartTarget(for: selection),
                Routing.sidebarStartTarget(for: selection, isBusy: false, in: Self.snapshot),
                label
            )

            model.ensureDeviceSelection()
            switch Routing.ensureTarget(for: selection, in: Self.snapshot) {
            case .keep:
                XCTAssertEqual(model.deviceSelection, selection, label)
            case .assign(let target):
                XCTAssertEqual(model.deviceSelection, target, label)
            }
        }
        for name in ["Pixel_9", "Pixel_8", "Offline_AVD", "Gone"] {
            XCTAssertEqual(model.avdIsBooting(name), Routing.avdIsBooting(name, in: Self.snapshot), name)
        }
    }

    func testUnavailableCaptionFollowsTheDeviceState() {
        func caption(_ sel: DeviceSelection?, _ snap: SelectionRouting.Snapshot) -> String {
            Routing.unavailableCaption(for: sel, in: snap, stopped: "STOPPED")
        }
        let card = AvdCard(name: "A", displayName: "A", target: nil, skin: nil, isRunning: true, serial: "emulator-5554")
        let stoppedCard = AvdCard(name: "S", displayName: "S", target: nil, skin: nil, isRunning: false, serial: nil)
        func snap(state: String, starting: Set<String> = []) -> SelectionRouting.Snapshot {
            SelectionRouting.Snapshot(
                devices: [AndroidDevice(serial: "emulator-5554", state: state), AndroidDevice(serial: "R58", state: state)],
                avdCards: [card, stoppedCard],
                startingAvdNames: starting
            )
        }
        XCTAssertEqual(caption(.avd("S"), snap(state: "device")), "STOPPED")
        XCTAssertEqual(caption(nil, snap(state: "device")), "STOPPED")
        XCTAssertEqual(caption(.avd("A"), snap(state: "device", starting: ["A"])), "Connecting\u{2026}")
        XCTAssertEqual(caption(.avd("A"), snap(state: "connecting")), "Connecting\u{2026}")
        XCTAssertEqual(caption(.device("R58"), snap(state: "unauthorized")), "Unlock the phone and allow USB debugging.")
        XCTAssertEqual(caption(.device("R58"), snap(state: "offline")), "The device is offline.")
        XCTAssertEqual(caption(.avd("A"), snap(state: "offline")), "The device is offline.")
        XCTAssertEqual(caption(.simulator("X"), snap(state: "device")), "STOPPED")
        // Online but its mirror stopped: the stage offers Mirror.
        XCTAssertEqual(caption(.avd("A"), snap(state: "device")), "Mirror the device to use its controls.")
        XCTAssertEqual(caption(.device("R58"), snap(state: "device")), "Mirror the device to use its controls.")
    }
}
