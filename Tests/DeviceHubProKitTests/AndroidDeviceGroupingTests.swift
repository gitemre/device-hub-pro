import XCTest
@testable import DeviceHubProKit

/// One physical phone listed by adb several times (USB, `ip:port`, mDNS name)
/// is one row. The `devices -l` lines are a Xiaomi phone's real capture
/// (`Fixtures/physical-xiaomi/devices-l-wireless-twice.txt`, scrubbed with
/// same-length placeholders; see its README). The USB line is SOURCE-DERIVED:
/// the phone was unplugged when the capture was taken, so it is the shape adb
/// prints for a USB entry (the serial is the phone's `ro.serialno`, here the
/// same `aqaserial001` placeholder) with the transport id of the moment.
final class AndroidDeviceGroupingTests: XCTestCase {
    private static let ip = "198.51.100.11:41473"
    private static let mdns = "adb-aqaserial001-xMmJsj._adb-tls-connect._tcp"
    private static let usb = "aqaserial001"

    private func captured() throws -> [AndroidDevice] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/physical-xiaomi/devices-l-wireless-twice.txt")
        return AdbParsing.devices(from: try String(contentsOf: url, encoding: .utf8))
    }

    private func usbLine(_ state: String) -> AndroidDevice {
        AdbParsing.devices(
            from: "\(Self.usb)          \(state) usb:1-1 product:sweet_global2 model:2209116AG device:sweet transport_id:4\n"
        )[0]
    }

    func testTheTwoWirelessEntriesOfTheCaptureAreOneRowOnTheIpTransport() throws {
        let result = AndroidDeviceGrouping.group(
            try captured(),
            serialnos: [Self.ip: "aqaserial001"]
        )
        XCTAssertEqual(result.devices.map(\.serial), [Self.ip, "emulator-5554"])
        let phone = result.devices[0]
        XCTAssertEqual(phone.hardwareSerial, "aqaserial001")
        XCTAssertEqual(phone.alternateSerials, [Self.mdns])
        XCTAssertEqual(phone.model, "2209116AG")
        XCTAssertEqual(result.aliases, [Self.mdns: Self.ip])
    }

    /// Before the IP entry's serialno is read it is its own row, never a
    /// wrong merge.
    func testAnIpEntryWhoseSerialnoIsUnknownStaysItsOwnRow() throws {
        let result = AndroidDeviceGrouping.group(try captured())
        XCTAssertEqual(result.devices.map(\.serial), [Self.ip, Self.mdns, "emulator-5554"])
        XCTAssertTrue(result.aliases.isEmpty)
    }

    /// USB beats IP beats mDNS when all are online.
    func testUsbThenIpThenMdnsWhenAllAreOnline() throws {
        let all = [usbLine("device")] + (try captured())
        let result = AndroidDeviceGrouping.group(all, serialnos: [Self.ip: Self.usb])
        XCTAssertEqual(result.devices.filter { $0.hardwareSerial != nil }.map(\.serial), [Self.usb])
        XCTAssertEqual(result.aliases, [Self.ip: Self.usb, Self.mdns: Self.usb])
    }

    /// The morning's bug: the USB entry stays listed offline while the phone
    /// is reachable over Wi-Fi. One row, on the live transport, not offline.
    func testAnOfflineUsbEntryDoesNotHideTheLiveWirelessTransport() throws {
        let all = [usbLine("offline")] + (try captured())
        let result = AndroidDeviceGrouping.group(all, serialnos: [Self.ip: Self.usb])
        let phones = result.devices.filter { $0.hardwareSerial != nil }
        XCTAssertEqual(phones.map(\.serial), [Self.ip])
        XCTAssertTrue(phones[0].isOnline)
        XCTAssertEqual(Set(phones[0].alternateSerials), [Self.usb, Self.mdns])
        XCTAssertEqual(result.aliases[Self.usb], Self.ip)
    }

    /// A phone that is offline everywhere is one offline row, on its best
    /// transport.
    func testAPhoneOfflineEverywhereIsOneOfflineRow() {
        let result = AndroidDeviceGrouping.group([
            AndroidDevice(serial: Self.mdns, state: "offline"),
            usbLine("offline"),
        ])
        XCTAssertEqual(result.devices.map(\.serial), [Self.usb])
        XCTAssertFalse(result.devices[0].isOnline)
    }

    /// The cable is pulled: the USB serial leaves adb, the row moves to the
    /// wireless transport and the old serial is an alias of it.
    func testThePreviousTransportThatLeftAdbBecomesAnAlias() throws {
        let first = AndroidDeviceGrouping.group(
            [usbLine("device")] + (try captured()),
            serialnos: [Self.ip: Self.usb]
        )
        let second = AndroidDeviceGrouping.group(
            try captured(),
            serialnos: [Self.ip: Self.usb],
            previousChosen: first.chosenByGroup
        )
        XCTAssertEqual(second.devices.first?.serial, Self.ip)
        XCTAssertEqual(second.aliases[Self.usb], Self.ip)
        XCTAssertEqual(second.devices.first?.hardwareSerial, Self.usb)
    }

    /// Pairing wireless debugging can drop USB a snapshot before the Wi-Fi
    /// transport is listed (seen on a Redmi Note 12 Pro): the grouper keeps
    /// the phone's last row through the empty snapshot, so the next one still
    /// aliases the vanished USB serial to the new transport.
    func testAnEmptySnapshotBetweenTransportsKeepsTheAlias() async throws {
        let grouper = AndroidDeviceGrouper(adb: nil)
        let mdns = AndroidDevice(serial: "adb-\(Self.usb)-xMmJsj._adb-tls-connect._tcp", state: "device")
        _ = await grouper.group([usbLine("device")])
        _ = await grouper.group([])
        let moved = await grouper.group([mdns])
        XCTAssertEqual(moved.devices.first?.serial, mdns.serial)
        XCTAssertEqual(moved.aliases[Self.usb], mdns.serial)
    }

    /// A transport that is still online stays the row: plugging the cable
    /// in later does not move a working mirror.
    func testAnOnlineRowIsNotMovedByABetterTransportAppearing() throws {
        let wireless = AndroidDeviceGrouping.group(try captured(), serialnos: [Self.ip: Self.usb])
        let withUsb = AndroidDeviceGrouping.group(
            [usbLine("device")] + (try captured()),
            serialnos: [Self.ip: Self.usb],
            previousChosen: wireless.chosenByGroup
        )
        XCTAssertEqual(withUsb.devices.first { $0.hardwareSerial != nil }?.serial, Self.ip)
        XCTAssertEqual(withUsb.aliases[Self.usb], Self.ip)
    }

    func testTwoDifferentPhonesAreTwoRows() {
        let other = AndroidDevice(serial: "adb-otherphone01-AbCdEf._adb-tls-connect._tcp", state: "device")
        let result = AndroidDeviceGrouping.group([usbLine("device"), other])
        XCTAssertEqual(result.devices.count, 2)
        XCTAssertTrue(result.aliases.isEmpty)
    }

    func testSerialParsing() {
        XCTAssertEqual(AndroidDeviceGrouping.serialno(fromMdnsName: Self.mdns), "aqaserial001")
        XCTAssertEqual(AndroidDeviceGrouping.serialno(fromMdnsInstance: "adb-aqaserial001-xMmJsj"), "aqaserial001")
        XCTAssertEqual(AndroidDeviceGrouping.serialno(fromMdnsName: "adb-AB-12-xMmJsj._adb-tls-connect._tcp"), "AB-12")
        XCTAssertNil(AndroidDeviceGrouping.selfDescribedSerialno(of: Self.ip))
        XCTAssertNil(AndroidDeviceGrouping.selfDescribedSerialno(of: "emulator-5554"))
        XCTAssertEqual(AndroidDeviceGrouping.selfDescribedSerialno(of: Self.usb), Self.usb)
        XCTAssertTrue(AndroidDeviceGrouping.isIPPort("[fe80::1]:5555"))
        XCTAssertFalse(AndroidDeviceGrouping.isIPPort("emulator-5554"))
    }

    // MARK: - The grouper reads ro.serialno once per serial (fake adb)

    func testTheGrouperReadsRoSerialnoOncePerIpSerialAndCachesIt() async throws {
        let fake = try FakeAdb([.init("-s \(Self.ip) shell getprop ro.serialno", output: "aqaserial001\n")])
        let grouper = AndroidDeviceGrouper(adb: fake.client)
        let raw = try captured()

        let first = await grouper.group(raw)
        let second = await grouper.group(raw)

        XCTAssertEqual(first.devices.map(\.serial), [Self.ip, "emulator-5554"])
        XCTAssertEqual(second, first)
        let reads = fake.calls.filter { $0.contains("getprop ro.serialno") }
        XCTAssertEqual(reads, ["-s \(Self.ip) shell getprop ro.serialno"])
    }

    /// An uncommitted read (Refresh) does not swallow the move the watcher's
    /// lifecycle has to hear.
    func testAnUncommittedGroupingLeavesTheMoveForTheWatcher() async throws {
        let fake = try FakeAdb([.init("getprop ro.serialno", output: "aqaserial001\n")])
        let grouper = AndroidDeviceGrouper(adb: fake.client)
        let raw = try captured()
        _ = await grouper.group([usbLine("device")] + raw)

        let peek = await grouper.group(raw, commit: false)
        XCTAssertEqual(peek.aliases[Self.usb], Self.ip)
        let watcher = await grouper.group(raw)
        XCTAssertEqual(watcher.aliases[Self.usb], Self.ip)
    }
}

final class SessionLifecycleTransportMoveTests: XCTestCase {
    private let usb = "aqaserial001"
    private let ip = "198.51.100.11:41473"

    /// A mirror on the USB serial whose phone is now on Wi-Fi restarts on the
    /// live transport, with no ghost and no waiting panel.
    func testAMirrorFollowsTheLiveTransport() {
        var lifecycle = SessionLifecycle()
        lifecycle.handle(.mirrorStarted(serial: usb))

        let moved = lifecycle.handle(.transportsMoved(aliases: [usb: ip]))
        XCTAssertEqual(moved, [.teardown(.disconnected), .setGhost(nil), .resume(serial: ip)])
        XCTAssertEqual(lifecycle.state, .mirroring(serial: ip))

        let snapshot = lifecycle.handle(.devicesChanged([AndroidDevice(serial: ip, state: "device")]))
        XCTAssertTrue(snapshot.isEmpty, "the grouped snapshot has the live row: no teardown, no ghost")
    }

    /// An episode waiting on the unplugged USB serial (the "Reconnecting
    /// (attempt 1)" panel of the bug) is re-armed on the live transport, with
    /// the stale ghost dropped.
    func testAWaitingEpisodeForAnOfflineEntryMovesToTheLiveTransport() {
        var lifecycle = SessionLifecycle()
        lifecycle.handle(.mirrorStarted(serial: usb))
        lifecycle.handle(.devicesChanged([]))
        XCTAssertEqual(lifecycle.state, .recovering(serial: usb, nextAttempt: 1, deviceBack: false))

        let moved = lifecycle.handle(.transportsMoved(aliases: [usb: ip]))
        XCTAssertEqual(moved, [.setGhost(nil), .scheduleResume(serial: ip, after: .milliseconds(500), attempt: 1)])
        XCTAssertEqual(lifecycle.state, .recovering(serial: ip, nextAttempt: 2, deviceBack: true))
    }

    func testAMoveOfAnUnrelatedSerialChangesNothing() {
        var lifecycle = SessionLifecycle()
        lifecycle.handle(.mirrorStarted(serial: "HT4CWJT01234"))
        XCTAssertTrue(lifecycle.handle(.transportsMoved(aliases: [usb: ip])).isEmpty)
        XCTAssertEqual(lifecycle.state, .mirroring(serial: "HT4CWJT01234"))
    }
}
