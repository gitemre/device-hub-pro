import XCTest
@testable import DeviceHubProKit

/// `EmulationOverlay` against `Fixtures/api35-emulator/cmd-overlay-list.txt`:
/// the byte-exact `adb shell cmd overlay list` of a Pixel 10 Pro Fold AVD
/// (API 35 Google APIs, emulator 36.6.11), no emulation overlay enabled.
final class EmulationOverlayTests: XCTestCase {
    private func fixtureText() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/api35-emulator/cmd-overlay-list.txt")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheImageOffersNoPixel10OverlayAndNoneIsEnabled() throws {
        let entries = EmulationOverlay.parse(overlayList: try fixtureText())
        let devices = EmulationOverlay.devices(in: entries)
        XCTAssertTrue(devices.contains("pixel_9_pro"))
        XCTAssertTrue(devices.contains("pixel_9_pro_fold"))
        XCTAssertFalse(devices.contains { $0.hasPrefix("pixel_10") })
        XCTAssertFalse(entries.contains { $0.isEnabled && $0.package.contains(".emulation.pixel_") })
    }

    func testAPixel10TakesTheSameSizePixel9() throws {
        let available = EmulationOverlay.devices(in: EmulationOverlay.parse(overlayList: try fixtureText()))
        func pick(_ name: String, _ width: Int, _ height: Int) -> String? {
            EmulationOverlay.device(forDeviceName: name, lcdWidth: width, lcdHeight: height, available: available)
        }
        XCTAssertEqual(pick("pixel_10", 1080, 2424), "pixel_9")
        XCTAssertEqual(pick("pixel_10_pro", 1280, 2856), "pixel_9_pro")
        XCTAssertEqual(pick("pixel_10_pro_xl", 1344, 2992), "pixel_9_pro_xl", "newest of the two 1344x2992 devices")
        XCTAssertEqual(pick("pixel_10_pro_fold", 2076, 2152), "pixel_9_pro_fold")
        // Its own overlay wins over a size match.
        XCTAssertEqual(pick("pixel_8_pro", 1344, 2992), "pixel_8_pro")
        // None: an "a" model, a size nothing matches, a device that is no Pixel.
        XCTAssertNil(pick("pixel_9a", 1080, 2424))
        XCTAssertNil(pick("pixel_tablet", 2560, 1600))
        XCTAssertNil(pick("tv_1080p", 1920, 1080))
    }

    func testBothPackagesAreEnabledOnceAndNothingAfterwards() async throws {
        var listing = try fixtureText()
        var ran: [[String]] = []
        let shell: ([String]) async throws -> String = { arguments in
            ran.append(arguments)
            if arguments == ["cmd", "overlay", "list"] { return listing }
            // The real device flips `[ ]` to `[x]` for what was enabled.
            let package = arguments.last ?? ""
            listing = listing.replacingOccurrences(of: "[ ] \(package)", with: "[x] \(package)")
            return "Success\n"
        }

        let first = await EmulationOverlay.apply(
            deviceName: "pixel_10_pro", lcdWidth: 1280, lcdHeight: 2856, shell: shell
        )
        XCTAssertEqual(first, [
            "com.android.internal.emulation.pixel_9_pro",
            "com.android.systemui.emulation.pixel_9_pro",
        ])
        let second = await EmulationOverlay.apply(
            deviceName: "pixel_10_pro", lcdWidth: 1280, lcdHeight: 2856, shell: shell
        )
        XCTAssertEqual(second, [])
        XCTAssertEqual(ran.filter { $0.contains("enable") }.count, 2)
    }

    /// An overlay somebody else enabled (the emulator, Android Studio, the
    /// user) stays: a second one would stack on it.
    func testAnotherEnabledEmulationOverlayIsLeftAlone() async throws {
        let listing = try fixtureText()
            .replacingOccurrences(
                of: "[ ] com.android.internal.emulation.pixel_8_pro",
                with: "[x] com.android.internal.emulation.pixel_8_pro"
            )
        let entries = EmulationOverlay.parse(overlayList: listing)
        XCTAssertEqual(EmulationOverlay.packagesToEnable(device: "pixel_9_pro", entries: entries), [])
    }

    func testAFailedListEnablesNothing() async {
        struct Failure: Error {}
        let enabled = await EmulationOverlay.apply(
            deviceName: "pixel_10_pro", lcdWidth: 1280, lcdHeight: 2856
        ) { _ in throw Failure() }
        XCTAssertEqual(enabled, [])
    }
}
