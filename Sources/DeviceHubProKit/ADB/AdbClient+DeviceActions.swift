import Foundation

/// The phone row's right-click actions beside Device Hub's physical-device
/// menu: Restart, Collect Bug Report… (the
/// Android side of "Collect sysdiagnose…") and Disconnect… (the side of
/// "Unpair…" for a wireless device).
extension AdbClient {
    /// A bug report takes minutes.
    public static let bugReportTimeout: Duration = .seconds(600)

    /// `adb -s <serial> reboot`.
    public func reboot(serial: String) async throws {
        try await run(["-s", serial, "reboot"])
    }

    /// `adb -s <serial> bugreport <folder>`: writes the bug report's zip into
    /// `folder` (adb names it itself).
    public func bugReport(serial: String, into folder: URL) async throws {
        try await run(["-s", serial, "bugreport", folder.path], timeout: Self.bugReportTimeout)
    }

    /// Whether `serial` is a wireless device: adb names those `host:port`
    /// (or by their `_adb-tls-connect._tcp` mDNS service). Only those can be
    /// disconnected.
    public static func isWirelessSerial(_ serial: String) -> Bool {
        serial.contains(":") || serial.contains("._adb-tls-connect._tcp")
    }

    /// `adb disconnect <serial>`: drops a wireless device's connection.
    public func disconnect(serial: String) async throws {
        try await run(["disconnect", serial])
    }
}
