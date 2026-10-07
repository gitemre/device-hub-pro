import Foundation

/// The Color Filter and Color inversion rows' commands: Android's accessibility
/// Color correction and Color inversion keys, which ColorDisplayService turns
/// into DisplayTransformManager levels and SurfaceFlinger composes into one
/// color matrix. Every write is read back — from that matrix on Android 13 and
/// newer, from the keys before — and throws `ColorFilterError.notKept` when the
/// keys do not hold it. Reads and writes address the foreground user's keys,
/// the ones Android applies (`ColorFilterSupport.settingsCommand`). The
/// Intensity key is never written.
extension AdbClient {
    // MARK: - Reads

    /// The API level, which decides what the read-back can see.
    public func colorFilterSupport(serial: String) async throws -> ColorFilterSupport {
        ColorFilterSupport(apiLevel: try await apiLevel(serial: serial))
    }

    /// The rows' readings, in one round trip.
    public func colorFilterReadings(serial: String, support: ColorFilterSupport) async throws -> ColorFilterReadings {
        let output = try await shell(serial: serial, [ColorFilterReadings.probeScript(support: support)])
        return ColorFilterReadings.parse(output, apiLevel: support.apiLevel)
    }

    // MARK: - Writes

    /// A filter writes its mode, then turns the switch on, in one shell line
    /// (the observer never draws the old mode, and `&&` stops at a failed first
    /// put); None turns only the switch off and keeps the mode, as the Settings
    /// switch does.
    @discardableResult
    public func setColorFilter(
        serial: String,
        _ option: ColorFilterOption,
        support: ColorFilterSupport,
        attempts: Int = 6,
        delay: Duration = .milliseconds(100)
    ) async throws -> ColorFilterWriteOutcome {
        _ = try await shell(serial: serial, Self.colorFilterArguments(option, support: support))
        return try await ColorFilterReadBack.settle(
            target: .filter(option),
            apiLevel: support.apiLevel,
            attempts: attempts,
            delay: delay
        ) {
            try await self.colorFilterReadings(serial: serial, support: support)
        }
    }

    /// `settings put secure accessibility_display_inversion_enabled 1|0`.
    @discardableResult
    public func setColorInversion(
        serial: String,
        enabled: Bool,
        support: ColorFilterSupport,
        attempts: Int = 6,
        delay: Duration = .milliseconds(100)
    ) async throws -> ColorFilterWriteOutcome {
        _ = try await shell(serial: serial, Self.colorInversionArguments(enabled: enabled, support: support))
        return try await ColorFilterReadBack.settle(
            target: .inversion(enabled),
            apiLevel: support.apiLevel,
            attempts: attempts,
            delay: delay
        ) {
            try await self.colorFilterReadings(serial: serial, support: support)
        }
    }

    /// Every value comes from the enum, so nothing needs quoting.
    static func colorFilterArguments(_ option: ColorFilterOption, support: ColorFilterSupport) -> [String] {
        let enabled = ColorFilterSettingKey.enabled.rawValue
        guard let mode = option.daltonizerMode else {
            return support.settingsCommand + ["put", "secure", enabled, "0"]
        }
        let put = (support.settingsCommand + ["put", "secure"]).joined(separator: " ")
        return ["\(put) \(ColorFilterSettingKey.mode.rawValue) \(mode) && \(put) \(enabled) 1"]
    }

    static func colorInversionArguments(enabled: Bool, support: ColorFilterSupport) -> [String] {
        support.settingsCommand + ["put", "secure", ColorFilterSettingKey.inversion.rawValue, enabled ? "1" : "0"]
    }
}
