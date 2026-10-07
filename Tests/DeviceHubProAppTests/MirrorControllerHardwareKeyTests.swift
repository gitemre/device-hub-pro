import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The frame buttons' key state on the controller: one key-down per press,
/// one key-up per release, nothing left held when the session goes, and
/// nothing at all for a session without hardware keys. The sessions are
/// fakes that record what they were sent; no emulator is involved.
@MainActor
final class MirrorControllerHardwareKeyTests: XCTestCase {
    private static let powerDown = HardwareKeyEvent(key: .power, isDown: true)
    private static let powerUp = HardwareKeyEvent(key: .power, isDown: false)
    private static let volumeUpDown = HardwareKeyEvent(key: .volumeUp, isDown: true)
    private static let volumeUpUp = HardwareKeyEvent(key: .volumeUp, isDown: false)
    private static let volumeDownDown = HardwareKeyEvent(key: .volumeDown, isDown: true)
    private static let volumeDownUp = HardwareKeyEvent(key: .volumeDown, isDown: false)

    private func controller(session: (any MirrorSessionProtocol)? = nil) -> MirrorController {
        let mirror = MirrorController(
            adbClient: nil,
            context: ActiveDeviceContext(),
            status: StatusCenter(),
            perfLog: nil
        )
        mirror.session = session
        return mirror
    }

    func testAPressIsOneKeyDownAndItsReleaseOneKeyUp() {
        let session = FakeMirrorSession()
        let mirror = controller(session: session)
        XCTAssertTrue(mirror.supportsHardwareKeys)

        mirror.pressHardwareKey(.power)
        XCTAssertEqual(session.hardwareKeyEvents, [Self.powerDown])

        mirror.pressHardwareKey(.power)
        XCTAssertEqual(session.hardwareKeyEvents, [Self.powerDown], "a held key is not pressed again")

        mirror.releaseHardwareKey(.power)
        XCTAssertEqual(session.hardwareKeyEvents, [Self.powerDown, Self.powerUp])

        mirror.releaseHardwareKey(.power)
        mirror.releaseHardwareKey(.volumeDown)
        XCTAssertEqual(session.hardwareKeyEvents, [Self.powerDown, Self.powerUp], "a key that is not held is not released")
    }

    func testReleasingAllSendsAKeyUpForEveryHeldKey() {
        let session = FakeMirrorSession()
        let mirror = controller(session: session)

        mirror.pressHardwareKey(.volumeDown)
        mirror.pressHardwareKey(.power)
        mirror.pressHardwareKey(.volumeUp)
        mirror.releaseHardwareKey(.volumeUp)
        mirror.releaseAllHardwareKeys()

        XCTAssertEqual(session.hardwareKeyEvents, [
            Self.volumeDownDown, Self.powerDown, Self.volumeUpDown, Self.volumeUpUp,
            Self.powerUp, Self.volumeDownUp,
        ])

        mirror.releaseAllHardwareKeys()
        XCTAssertEqual(session.hardwareKeyEvents.count, 6, "nothing is held any more")
    }

    /// The controller's own teardown step releases held keys before it
    /// stops the transport (the model's order is pinned in
    /// `MirrorTeardownOrderTests`).
    func testStoppingTheSessionReleasesHeldKeys() {
        let session = FakeMirrorSession()
        let mirror = controller(session: session)
        mirror.pressHardwareKey(.volumeUp)

        mirror.stopSession(cause: .userStop)

        XCTAssertEqual(session.hardwareKeyEvents, [Self.volumeUpDown, Self.volumeUpUp])
        XCTAssertEqual(session.stopCount, 1)
    }

    /// A key held on a session that was replaced is not released on the new
    /// one (it was never pressed there) and does not block pressing it.
    func testAReplacedSessionStartsWithNoKeyHeld() {
        let old = FakeMirrorSession()
        let mirror = controller(session: old)
        mirror.pressHardwareKey(.power)

        let new = FakeMirrorSession()
        mirror.session = new
        mirror.releaseHardwareKey(.power)
        mirror.releaseAllHardwareKeys()
        XCTAssertEqual(new.hardwareKeyEvents, [])
        XCTAssertEqual(old.hardwareKeyEvents, [Self.powerDown])

        mirror.pressHardwareKey(.power)
        XCTAssertEqual(new.hardwareKeyEvents, [Self.powerDown])
    }

    /// Setting the same session again is no change: the key stays held.
    func testReassigningTheSameSessionKeepsItsKeysHeld() {
        let session = FakeMirrorSession()
        let mirror = controller(session: session)
        mirror.pressHardwareKey(.volumeDown)

        mirror.session = session
        mirror.releaseHardwareKey(.volumeDown)

        XCTAssertEqual(session.hardwareKeyEvents, [Self.volumeDownDown, Self.volumeDownUp])
    }

    func testClearingTheSessionForgetsHeldKeys() {
        let session = FakeMirrorSession()
        let mirror = controller(session: session)
        mirror.pressHardwareKey(.power)

        mirror.session = nil
        XCTAssertFalse(mirror.supportsHardwareKeys)
        mirror.releaseAllHardwareKeys()
        mirror.pressHardwareKey(.power)

        XCTAssertEqual(session.hardwareKeyEvents, [Self.powerDown])
    }

    /// Physical sessions have no hardware-key path in Tier 2, and a session
    /// that says it has none is sent nothing.
    func testSessionsWithoutHardwareKeysAreSentNone() {
        let physical = FakePhysicalSession(serial: "HT4CWJT01234")
        XCTAssertFalse(physical.supportsHardwareKeys)
        XCTAssertFalse(controller(session: physical).supportsHardwareKeys)

        let session = FakeMirrorSession()
        session.supportsHardwareKeys = false
        let mirror = controller(session: session)
        XCTAssertFalse(mirror.supportsHardwareKeys)
        mirror.pressHardwareKey(.power)
        mirror.releaseHardwareKey(.power)
        mirror.releaseAllHardwareKeys()
        XCTAssertEqual(session.hardwareKeyEvents, [])

        XCTAssertFalse(controller().supportsHardwareKeys, "no session")
    }

    /// The emulator session the controller builds falls back to adb, on the
    /// emulator's own serial, for an AVD without a hardware keyboard (its
    /// keys then go through `adb shell input`); without adb it keeps every
    /// key on the emulator. Nothing is started: building a session runs no
    /// adb and dials nothing.
    func testTheEmulatorSessionFallsBackToAdbOnItsSerial() throws {
        let adb = try makeStubAdb(arms: "")
        let mirror = MirrorController(
            adbClient: adb.client,
            context: ActiveDeviceContext(),
            status: StatusCenter(),
            perfLog: nil
        )

        let session = try XCTUnwrap(mirror.makeEmulatorSession(serial: "emulator-5558", port: 8580) as? MirrorSession)
        XCTAssertEqual(session.port, 8580)
        XCTAssertEqual(session.adbFallback?.serial, "emulator-5558")
        XCTAssertTrue(session.adbFallback?.adb === adb.client)
        XCTAssertTrue(session.supportsHardwareKeys)
        XCTAssertEqual(adb.calls, [], "the guest is asked when a run starts, not when the session is built")

        let withoutAdb = try XCTUnwrap(controller().makeEmulatorSession(serial: "emulator-5558", port: 8580) as? MirrorSession)
        XCTAssertNil(withoutAdb.adbFallback)
    }
}
