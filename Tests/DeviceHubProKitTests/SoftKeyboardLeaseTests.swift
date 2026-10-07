import XCTest
@testable import DeviceHubProKit

/// The argv sequence of `SoftKeyboardLease` against a fake adb. The setting
/// and its effect were measured live (docs/soft-keyboard.md).
final class SoftKeyboardLeaseTests: XCTestCase {
    private let get = "-s emulator-5600 shell settings get secure show_ime_with_hard_keyboard"
    private let put1 = "-s emulator-5600 shell settings put secure show_ime_with_hard_keyboard 1"
    private let put0 = "-s emulator-5600 shell settings put secure show_ime_with_hard_keyboard 0"
    private let delete = "-s emulator-5600 shell settings delete secure show_ime_with_hard_keyboard"

    /// The settings calls: the AVD-name reads that key the lease are not the point here.
    private func adbCalls(_ fake: FakeAdb) -> [String] {
        fake.calls.filter { !$0.contains("emu avd name") }
    }

    private func lease(reading: String) throws -> (SoftKeyboardLease, FakeAdb) {
        let fake = try FakeAdb([.init("settings get", output: reading + "\n")])
        return (SoftKeyboardLease(adb: fake.client), fake)
    }

    func testZeroIsWrittenToOneAndRestored() async throws {
        let (lease, fake) = try lease(reading: "0")
        await lease.showSoftKeyboard(serial: "emulator-5600")
        await lease.restore(serial: "emulator-5600")
        XCTAssertEqual(adbCalls(fake), [get, put1, put0])
    }

    func testMissingKeyIsDeletedAgain() async throws {
        let (lease, fake) = try lease(reading: "null")
        await lease.showSoftKeyboard(serial: "emulator-5600")
        await lease.restore(serial: "emulator-5600")
        XCTAssertEqual(adbCalls(fake), [get, put1, delete])
    }

    func testAlreadyOneIsNeverWritten() async throws {
        let (lease, fake) = try lease(reading: "1")
        await lease.showSoftKeyboard(serial: "emulator-5600")
        await lease.restore(serial: "emulator-5600")
        XCTAssertEqual(adbCalls(fake), [get])
    }

    func testRepeatedShowAndRestoreAreIdempotent() async throws {
        let (lease, fake) = try lease(reading: "0")
        await lease.showSoftKeyboard(serial: "emulator-5600")
        await lease.showSoftKeyboard(serial: "emulator-5600")
        await lease.restore(serial: "emulator-5600")
        await lease.restore(serial: "emulator-5600")
        // The fake never changes its reading, so the second show reads 0
        // again; the remembered original stays the first reading and is put
        // back exactly once.
        XCTAssertEqual(adbCalls(fake).filter { $0 == put0 }.count, 1)
        let leased = await lease.leasedSerials
        XCTAssertEqual(leased, [])
    }

    func testSyncRestoresTheOldTargetAndLeasesTheNew() async throws {
        let (lease, fake) = try lease(reading: "0")
        await lease.sync(target: "emulator-5600")
        await lease.sync(target: nil)
        await lease.sync(target: nil)
        XCTAssertEqual(adbCalls(fake), [get, put1, put0])
    }

    func testRestoreWithoutLeaseDoesNothing() async throws {
        let (lease, fake) = try lease(reading: "0")
        await lease.restoreAll()
        XCTAssertEqual(adbCalls(fake), [])
    }

    // MARK: - Persistence, AVD keys, serialized sync

    private func memoryStore() -> (SoftKeyboardLease.Store, () -> [String: SoftKeyboardLease.Store.Entry]) {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var entries: [String: SoftKeyboardLease.Store.Entry] = [:]
        }
        let box = Box()
        let store = SoftKeyboardLease.Store(
            load: { box.lock.withLock { box.entries } },
            save: { value in box.lock.withLock { box.entries = value } }
        )
        return (store, { box.lock.withLock { box.entries } })
    }

    /// A relaunch after a crash: the original left on disk is put back on the
    /// device's next contact, not the `1` the keyboard lease wrote.
    func testAnOriginalLeftByACrashIsRestoredOnNextContact() async throws {
        let (store, entries) = memoryStore()
        let fake = try FakeAdb([
            .init("emu avd name", output: "Pixel_9\r\nOK\r\n"),
            .init("settings get", output: "0\n"),
        ])
        let first = SoftKeyboardLease(adb: fake.client, store: store)
        await first.showSoftKeyboard(serial: "emulator-5600")
        XCTAssertEqual(entries()["Pixel_9"], .init(serial: "emulator-5600", original: "0"))

        // The app died: a fresh lease reads the `1` Device Hub Pro wrote.
        let second = SoftKeyboardLease(adb: fake.client, store: store)
        await second.repairStale(serial: "emulator-5600")
        XCTAssertTrue(adbCalls(fake).contains(put0), "the original, not the leftover 1")
        XCTAssertTrue(entries().isEmpty)
    }

    func testAnotherAvdOnTheSameSerialDoesNotInheritTheLease() async throws {
        let (store, entries) = memoryStore()
        let fake = try FakeAdb([
            .init("emu avd name", output: "Pixel_9\r\nOK\r\n"),
            .init("settings get", output: "0\n"),
        ])
        let lease = SoftKeyboardLease(adb: fake.client, store: store)
        await lease.showSoftKeyboard(serial: "emulator-5600")
        // A different AVD now answers on the serial.
        let other = try FakeAdb([
            .init("emu avd name", output: "Tablet\r\nOK\r\n"),
            .init("settings get", output: "null\n"),
        ])
        let reused = SoftKeyboardLease(adb: other.client, store: store)
        await reused.showSoftKeyboard(serial: "emulator-5600")
        await reused.restore(serial: "emulator-5600")
        XCTAssertTrue(adbCalls(other).contains(delete), "its own original (no key), not Pixel_9's 0")
        XCTAssertEqual(entries()["Pixel_9"]?.original, "0", "the other AVD's record waits for it")
    }

    /// A show still reading when the toggle flips back is restored once it
    /// has recorded its original: the syncs run one at a time.
    func testQuickTogglesNeverLeaveAnUnrecordedWrite() async throws {
        let (lease, fake) = try lease(reading: "0")
        async let first: Void = lease.sync(target: "emulator-5600")
        async let second: Void = lease.sync(target: nil)
        _ = await (first, second)
        let leased = await lease.leasedSerials
        XCTAssertEqual(leased, [])
        XCTAssertEqual(adbCalls(fake), [get, put1, put0])
    }
}
