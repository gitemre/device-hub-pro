import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

final class AvdRunningStateTests: XCTestCase {
    private let runningCard = AvdCard(
        name: "Pixel_API_35",
        displayName: "Pixel",
        target: "android-35",
        skin: nil,
        isRunning: true,
        serial: "emulator-5554"
    )

    func testRunningStateFollowsTheParsedEmulatorList() {
        XCTAssertTrue(runningCard.withRunningState(runningAVDNames: ["Pixel_API_35"]).isRunning)
        XCTAssertFalse(runningCard.withRunningState(runningAVDNames: []).isRunning)
        XCTAssertFalse(runningCard.withRunningState(runningAVDNames: ["Other_API_35"]).isRunning)
    }

    func testRunningStatePassChangesNothingElse() {
        let updated = runningCard.withRunningState(runningAVDNames: [])
        XCTAssertEqual(updated.name, runningCard.name)
        XCTAssertEqual(updated.displayName, runningCard.displayName)
        XCTAssertEqual(updated.target, runningCard.target)
        XCTAssertEqual(updated.skin, runningCard.skin)
        XCTAssertEqual(updated.serial, runningCard.serial)
    }
}

/// The hot-plug pass reconciles serials, not only the running flag: an
/// emulator serial is reused by whichever VM boots next (F3).
@MainActor
final class AvdSerialReconciliationTests: XCTestCase {
    private func card(_ name: String, running: Bool, serial: String?) -> AvdCard {
        AvdCard(name: name, displayName: name, target: nil, skin: nil, isRunning: running, serial: serial)
    }

    /// A VM stopped outside the app gives up its serial: otherwise the next
    /// VM on emulator-5554 would be mirrored under this AVD's name and skin.
    func testStoppedAvdLosesItsSerial() {
        let cards = AvdCatalogController.reconcileAvdCards(
            [card("Pixel_A", running: true, serial: "emulator-5554")],
            runningAVDNames: [],
            serialsByAvd: [:]
        )
        XCTAssertFalse(cards[0].isRunning)
        XCTAssertNil(cards[0].serial)
    }

    /// A VM started outside the app gets the serial its console answered
    /// for, instead of staying "Booting" until a manual refresh.
    func testExternallyStartedAvdGetsItsSerial() {
        let cards = AvdCatalogController.reconcileAvdCards(
            [card("Pixel_B", running: false, serial: nil)],
            runningAVDNames: ["Pixel_B"],
            serialsByAvd: ["Pixel_B": "emulator-5554"]
        )
        XCTAssertTrue(cards[0].isRunning)
        XCTAssertEqual(cards[0].serial, "emulator-5554")
    }

    /// A running card keeps its serial while its console is merely silent,
    /// but not once another AVD's console claims that serial.
    func testRunningAvdKeepsItsSerialUntilAnotherClaimsIt() {
        let silent = AvdCatalogController.reconcileAvdCards(
            [card("Pixel_A", running: true, serial: "emulator-5554")],
            runningAVDNames: ["Pixel_A"],
            serialsByAvd: [:]
        )
        XCTAssertEqual(silent[0].serial, "emulator-5554")

        let claimed = AvdCatalogController.reconcileAvdCards(
            [card("Pixel_A", running: true, serial: "emulator-5554"), card("Pixel_B", running: true, serial: nil)],
            runningAVDNames: ["Pixel_A", "Pixel_B"],
            serialsByAvd: ["Pixel_B": "emulator-5554"]
        )
        XCTAssertNil(claimed[0].serial)
        XCTAssertEqual(claimed[1].serial, "emulator-5554")
    }

    /// Consoles are asked once per adb transport: a snapshot repeat costs no
    /// adb call, a new VM on the reused serial is asked again.
    func testConsoleAnswersAreCachedPerTransport() async throws {
        let adb = try makeStubAdb(arms: """
          "-s emulator-5554 emu avd name")
            printf 'Pixel_A\\r\\nOK\\r\\n' ;;
        """)
        let model = AppModel.testing(adb: adb.client)
        let first = AndroidDevice.online("emulator-5554", transport: "3")

        let answer = await model.inventory.resolveAvdSerials(among: [first])
        XCTAssertEqual(answer, ["Pixel_A": "emulator-5554"])
        _ = await model.inventory.resolveAvdSerials(among: [first])
        XCTAssertEqual(adb.calls(containing: "emu avd name").count, 1)

        let reused = AndroidDevice.online("emulator-5554", transport: "9")
        _ = await model.inventory.resolveAvdSerials(among: [reused])
        XCTAssertEqual(adb.calls(containing: "emu avd name").count, 2, "a new transport is a new VM")
    }
}

/// Device Info is keyed to the adb transport it was read from (F4).
@MainActor
final class DeviceInfoStalenessTests: XCTestCase {
    private func info(_ serial: String, version: String) -> DeviceInfo {
        DeviceInfo(
            serial: serial,
            model: "sdk_gphone64_arm64",
            manufacturer: "Google",
            androidVersion: version,
            apiLevel: version == "14" ? "34" : "36",
            abi: "arm64-v8a",
            isEmulator: true
        )
    }

    /// Stopping AVD A and starting AVD B reuses emulator-5554 on a new
    /// transport: A's Android version must not show for B.
    func testReusedSerialOnANewTransportDropsTheOldInfo() {
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        let vmA = AndroidDevice.online("emulator-5554", transport: "3")
        model.inventory.applyWatcherSnapshot([vmA], degraded: false)
        model.inventory.storeDeviceInfo(info("emulator-5554", version: "14"), for: vmA)
        XCTAssertEqual(model.inventory.deviceInfos["emulator-5554"]?.androidVersion, "14")

        model.inventory.applyWatcherSnapshot([vmA], degraded: false)
        XCTAssertNotNil(model.inventory.deviceInfos["emulator-5554"], "the same transport keeps its Info")

        let vmB = AndroidDevice.online("emulator-5554", transport: "7")
        model.inventory.applyWatcherSnapshot([vmB], degraded: false)
        XCTAssertNil(model.inventory.deviceInfos["emulator-5554"], "a new VM on the serial reads its own Info")
    }

    /// A device that left adb takes its Info with it.
    func testVanishedDeviceDropsItsInfo() {
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        let vm = AndroidDevice.online("emulator-5554", transport: "3")
        model.inventory.applyWatcherSnapshot([vm], degraded: false)
        model.inventory.storeDeviceInfo(info("emulator-5554", version: "14"), for: vm)

        model.inventory.applyWatcherSnapshot([], degraded: false)

        XCTAssertNil(model.inventory.deviceInfos["emulator-5554"])
    }

    /// A read that answers after its device was replaced on the serial is
    /// dropped instead of labelling the new device.
    func testLateInfoForAReplacedDeviceIsDropped() {
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        let vmA = AndroidDevice.online("emulator-5554", transport: "3")
        let vmB = AndroidDevice.online("emulator-5554", transport: "7")
        model.inventory.applyWatcherSnapshot([vmB], degraded: false)

        model.inventory.storeDeviceInfo(info("emulator-5554", version: "14"), for: vmA)

        XCTAssertNil(model.inventory.deviceInfos["emulator-5554"])
    }
}
