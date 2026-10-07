import Foundation

/// The Bluetooth adapter's real state, for when the persisted `bluetooth_on`
/// setting cannot tell (see `bluetoothAdapterEnabled(serial:)`).
extension AdbClient {
    /// The status block's state line, matched case-insensitively (`grep -iE`).
    /// Every version opens `dumpsys bluetooth_manager` with one, in one of
    /// four forms:
    /// - API 23 and older (BluetoothManagerService.dump): `  enabled: <mEnable>`
    ///   (the requested state, not the radio's) and `  state: 12`, the raw
    ///   BluetoothAdapter constant;
    /// - API 24-25 (the manager hands the dump to AdapterService):
    ///   `  enabled: true` and `  state: STATE_ON`;
    /// - API 26-36: `  enabled: true` and `  state: ON` (nameForState);
    /// - API 37 (the Bluetooth module): `Bluetooth Status:` /
    ///   `  State:         ON` (capitalized, padded, no `enabled:` line).
    /// From API 24 `enabled:` is `state == ON`, and on older images it is
    /// only the request, so the state line alone decides.
    static let bluetoothStatePattern = "^ *state: "

    /// The first state line of `dumpsys bluetooth_manager`, which is the
    /// manager's status block at the top of the dump; grep stops after it,
    /// so the rest of the dump (profile state, the snoop-log summary on
    /// older images) is never produced or transferred.
    static let bluetoothStatusCommand =
        "dumpsys bluetooth_manager | grep -m 1 -iE '\(bluetoothStatePattern)'"

    /// Whether the Bluetooth adapter is on, from BluetoothManagerService's
    /// own status (`state: ON`). nil when the dump names no known state (no
    /// Bluetooth service on the image, or a state this build does not name).
    ///
    /// `bluetooth_on` 2 ("was on when airplane mode came on") is ambiguous:
    /// the manager normally turns the radio off, but Android 11+ keeps it on,
    /// and still writes 2, while an audio or hearing-aid device is connected.
    public func bluetoothAdapterEnabled(serial: String) async throws -> Bool? {
        let output = try await shell(serial: serial, [Self.bluetoothStatusCommand])
        return Self.bluetoothAdapterEnabled(fromManagerStatus: output)
    }

    /// Decodes the first state line, in any case and with any padding after
    /// the colon (the one `grep -m 1` keeps): `ON`, `STATE_ON` or `12` is on;
    /// the other BluetoothAdapter states (off, turning on or off, BLE-only)
    /// are off; anything else (`?!?!? (n)`, `UNKNOWN STATE: n`) is nil, so
    /// the caller's airplane-mode rule decides.
    static func bluetoothAdapterEnabled(fromManagerStatus output: String) -> Bool? {
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.lowercased().hasPrefix("state:") else { continue }
            return adapterIsOn(state: text.dropFirst("state:".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// BluetoothAdapter's `STATE_*` constants, by value and by the names
    /// `nameForState` (API 26+) and AdapterService (`STATE_` prefix, API
    /// 24-25) print; only `STATE_ON` (12) is on.
    private static let adapterStates: [(value: Int, name: String)] = [
        (10, "OFF"), (11, "TURNING_ON"), (12, "ON"), (13, "TURNING_OFF"),
        (14, "BLE_TURNING_ON"), (15, "BLE_ON"), (16, "BLE_TURNING_OFF"),
    ]

    private static func adapterIsOn(state: String) -> Bool? {
        var name = state.uppercased()
        if name.hasPrefix("STATE_") { name.removeFirst("STATE_".count) }
        let match = adapterStates.first { Int(name) == $0.value || name == $0.name }
        return match.map { $0.value == 12 }
    }
}
