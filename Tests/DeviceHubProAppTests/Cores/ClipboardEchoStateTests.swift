import XCTest
@testable import DeviceHubProApp

/// The clipboard sync's echo suppression, in both directions.
final class ClipboardEchoStateTests: XCTestCase {
    /// Two clipboards and one auto-sync tick, written against the core the
    /// way the emulator loop (`syncClipboardOnce`) runs today: device → Mac,
    /// then Mac → device.
    private struct Sync {
        var echo = ClipboardEchoState()
        var mac: String?
        var device: String?
        var macWrites: [String] = []
        var deviceWrites: [String] = []

        /// Sync is switched on: both sides are recorded as they are.
        mutating func start() {
            echo.seedMac(mac)
            echo.seedDevice(device)
        }

        mutating func tick() {
            if let deviceText = device, echo.acceptDeviceText(deviceText), echo.macNeeds(deviceText) {
                mac = deviceText
                macWrites.append(deviceText)
                echo.noteMacWritten(deviceText)
            }
            if let macText = mac, echo.acceptMacText(macText), echo.deviceNeeds(macText) {
                device = macText
                deviceWrites.append(macText)
                echo.noteDeviceWritten(macText)
            }
        }
    }

    func testEnablingSyncOverwritesNeitherSide() {
        var sync = Sync(mac: "on the Mac", device: "on the device")
        sync.start()
        sync.tick()
        XCTAssertEqual(sync.macWrites, [])
        XCTAssertEqual(sync.deviceWrites, [])
    }

    func testADeviceCopyCrossesOnceAndIsNotSentBack() {
        var sync = Sync(mac: "old", device: "old")
        sync.start()
        sync.device = "copied on the device"
        sync.tick()
        sync.tick()
        sync.tick()
        XCTAssertEqual(sync.macWrites, ["copied on the device"])
        XCTAssertEqual(sync.deviceWrites, [], "the Mac poll must not echo it back")
    }

    func testAMacCopyCrossesOnceAndIsNotCopiedBack() {
        var sync = Sync(mac: "old", device: "old")
        sync.start()
        sync.mac = "copied on the Mac"
        sync.tick()
        sync.tick()
        sync.tick()
        XCTAssertEqual(sync.deviceWrites, ["copied on the Mac"])
        XCTAssertEqual(sync.macWrites, [], "the device read must not echo it back")
    }

    func testAlternatingCopiesEachCrossOnce() {
        var sync = Sync(mac: "old", device: "old")
        sync.start()
        sync.mac = "one"
        sync.tick()
        sync.device = "two"
        sync.tick()
        sync.mac = "three"
        sync.tick()
        sync.tick()
        XCTAssertEqual(sync.deviceWrites, ["one", "three"])
        XCTAssertEqual(sync.macWrites, ["two"])
    }

    func testAManualSendOrPullIsNotEchoed() {
        var sync = Sync(mac: "old", device: "old")
        sync.start()
        // Send (or Pull) put the same text on both sides outside the loop.
        sync.mac = "sent"
        sync.device = "sent"
        sync.echo.noteSynced("sent")
        sync.tick()
        XCTAssertEqual(sync.macWrites, [])
        XCTAssertEqual(sync.deviceWrites, [])
    }

    func testAPhysicalPushWithAutoSyncOffIsRecordedButNotCopied() {
        // `receiveDeviceClipboard`: the device side is always recorded, the
        // Mac is written only with auto-sync on.
        var echo = ClipboardEchoState()
        echo.seedMac("on the Mac")
        XCTAssertTrue(echo.acceptDeviceText("pushed"))
        XCTAssertEqual(echo.lastDeviceText, "pushed")
        XCTAssertEqual(echo.lastMacText, "on the Mac")
        XCTAssertFalse(echo.acceptDeviceText("pushed"), "the same push again is a repeat")
        XCTAssertFalse(echo.acceptMacText("on the Mac"), "the untouched Mac side is not sent")
    }

    func testTheDeviceSideIsRecordedOnlyOnceTheWriteLands() {
        // The emulator loop awaits `setClipboard` between deciding to send a
        // Mac text and recording it on the device side.
        var echo = ClipboardEchoState()
        echo.seedMac("old")
        echo.seedDevice("old")
        XCTAssertTrue(echo.acceptMacText("new"))
        XCTAssertTrue(echo.deviceNeeds("new"))
        XCTAssertEqual(echo.lastDeviceText, "old", "not recorded before the write")
        echo.noteDeviceWritten("new")
        XCTAssertFalse(echo.acceptDeviceText("new"), "its read-back is the echo")
    }

    func testAMacTextTheDeviceAlreadyHoldsIsNotWritten() {
        var echo = ClipboardEchoState()
        echo.seedMac("old")
        echo.seedDevice("same")
        XCTAssertTrue(echo.acceptMacText("same"))
        XCTAssertFalse(echo.deviceNeeds("same"))
    }

    func testANilSideSeedsAsUnknown() {
        var echo = ClipboardEchoState()
        echo.seedMac(nil)
        echo.seedDevice(nil)
        XCTAssertTrue(echo.acceptMacText(""), "an empty text differs from an unread side")
        XCTAssertTrue(echo.acceptDeviceText(""))
    }
}
