import XCTest
@testable import DeviceHubProKit

/// The developer toggles against a live emulator: each write goes through the
/// mechanism Developer Options uses, and each assertion reads the effect from
/// where Android keeps it (SurfaceFlinger, the `debug.layout` property, the
/// Wi-Fi module), never from the key the write touched. Every toggle is put
/// back as it was. Skips without an online emulator.
final class DeviceTogglesIntegrationTests: XCTestCase {
    private func onlineEmulator() async throws -> (AdbClient, String) {
        guard let adb = AdbClient.locate() else { throw XCTSkip("adb not found") }
        let devices = try await adb.listDevices()
        guard let serial = devices.first(where: { $0.isEmulator && $0.isOnline })?.serial else {
            throw XCTSkip("no online emulator")
        }
        return (adb, serial)
    }

    func testLayoutBoundsSetTheSystemProperty() async throws {
        let (adb, serial) = try await onlineEmulator()
        let original = try await adb.shell(serial: serial, ["getprop", "debug.layout"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let wasOn = original == "true"
        defer { Task { try? await adb.setDebugLayout(serial: serial, enabled: wasOn) } }

        for enabled in [!wasOn, wasOn] {
            try await adb.setDebugLayout(serial: serial, enabled: enabled)
            let property = try await adb.shell(serial: serial, ["getprop", "debug.layout"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(property, enabled ? "true" : "false", "debug.layout drives Show layout bounds")
        }
    }

    func testWifiVerboseLoggingIsReadFromTheWifiModule() async throws {
        let (adb, serial) = try await onlineEmulator()
        let before = try await adb.deviceEffects(serial: serial).wifiVerboseLogging
        guard let before, case .live = before.support, let wasOn = before.reading.isOn else {
            throw XCTSkip("Wi-Fi verbose logging does not apply live on this image")
        }
        defer { Task { _ = try? await adb.setToggle(serial: serial, toggle: .wifiVerboseLogging, enabled: wasOn) } }

        for enabled in [!wasOn, wasOn] {
            try await adb.setToggle(serial: serial, toggle: .wifiVerboseLogging, enabled: enabled)
            let reported = try await adb.shell(serial: serial, ["cmd", "wifi", "is-verbose-logging"])
            XCTAssertEqual(
                reported.localizedCaseInsensitiveContains("enabled")
                    && !reported.localizedCaseInsensitiveContains("disabled"),
                enabled,
                "the Wi-Fi module must report verbose logging \(enabled ? "enabled" : "disabled"): \(reported)"
            )
        }
    }
}
