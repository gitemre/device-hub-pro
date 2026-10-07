import Foundation

/// The Controls toggles whose Android mechanism is not a plain settings key.
/// Each write drives the mechanism Developer Options itself uses, and each
/// read comes from where the effect lives (`DeviceEffects`), never from a key
/// the app wrote itself.
extension AdbClient {
    /// `IBinder.SYSPROPS_TRANSACTION` ('_SPR'): ActivityManagerService
    /// forwards it to every app process, which re-reads its debug system
    /// properties — what SettingsLib's SystemPropPoker sends.
    static let sysPropsTransaction = "1599295570"

    /// The effective state of the non-key toggles, in one round trip. Cheap
    /// enough for the Controls poll: the Wi-Fi service dump is read only when
    /// `DeviceEffectsCache` says it is due and taken from the cache otherwise.
    public func deviceEffects(serial: String) async throws -> DeviceEffects {
        try await deviceEffects(serial: serial, now: .now)
    }

    func deviceEffects(serial: String, now: ContinuousClock.Instant) async throws -> DeviceEffects {
        let cache = DeviceEffectsCache.shared
        let device = effectsCacheKey(serial: serial)
        let readsSlowSources = cache.needsSlowSources(for: device, at: now)
        let output = try await shell(
            serial: serial,
            [DeviceEffects.probeScript(includingSlowSources: readsSlowSources)]
        )
        var sections = DeviceEffects.sections(from: output)
        if readsSlowSources {
            cache.store(wifiVerboseDump: sections[.wifiVerboseDump], for: device, at: now)
        } else {
            sections[.wifiVerboseDump] = cache.wifiVerboseDump(for: device)
        }
        return DeviceEffects.parse(sections: sections)
    }

    /// One cache entry per adb and device.
    private func effectsCacheKey(serial: String) -> String {
        adbURL.path + "\u{0}" + serial
    }

    /// The device's API level (`ro.build.version.sdk`).
    func apiLevel(serial: String) async throws -> Int {
        let output = try await shell(serial: serial, ["getprop", "ro.build.version.sdk"])
        guard let level = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AdbError.commandFailed(
                arguments: ["-s", serial, "shell", "getprop", "ro.build.version.sdk"],
                exitCode: 0,
                message: "unreadable API level: \(output)"
            )
        }
        return level
    }

    // MARK: - Show layout bounds

    /// Show layout bounds, as ShowLayoutBoundsPreferenceController does it:
    /// the `debug.layout` system property, then a SYSPROPS_TRANSACTION poke
    /// so running apps re-read it and redraw.
    func applyDebugLayout(serial: String, enabled: Bool) async throws {
        _ = try await shell(serial: serial, ["setprop", "debug.layout", enabled ? "true" : "false"])
        _ = try await shell(serial: serial, ["service", "call", "activity", Self.sysPropsTransaction])
    }

    // MARK: - Force RTL

    /// Force RTL, as RtlLayoutPreferenceController writes it: the Global key
    /// (what ActivityTaskManagerService applies at boot) and the
    /// `debug.force_rtl` property (what TextUtils reads whenever a layout
    /// direction is computed), then the current languages pushed again
    /// (LocalePicker.updateLocales): Configuration.setLocales recomputes the
    /// layout direction from the property. The shell pushes them through the
    /// language helper on API 26+ (`repushDeviceLocales`), so the change
    /// applies at once there; where that fails, or before API 26, it applies
    /// after a restart. The configuration read back decides which: an RTL
    /// language stays right to left with Force RTL off.
    func applyForceRTL(serial: String, enabled: Bool) async throws -> ToggleWriteOutcome {
        _ = try await shell(serial: serial, ["settings", "put", "global", "debug.force_rtl", enabled ? "1" : "0"])
        _ = try await shell(serial: serial, ["setprop", "debug.force_rtl", enabled ? "true" : "false"])
        if let api = try? await apiLevel(serial: serial), api >= LanguageTimeSupport.localeHelperMinimumAPI {
            // Best effort: without the push the read-back reports a restart.
            try? await repushDeviceLocales(serial: serial)
        }
        let config = (try? await shell(serial: serial, ["am", "get-config"])) ?? ""
        let rightToLeftLanguage = DeviceLocaleList.fromConfiguration(config)?.first
            .map(DeviceLocaleList.isRightToLeft) ?? false
        let expectsRTL = enabled || rightToLeftLanguage
        return DeviceEffects.configurationIsRTL(config) == expectsRTL ? .applied : .appliesAfterRestart
    }

    // MARK: - Wi-Fi

    /// Wi-Fi verbose logging: `cmd wifi set-verbose-logging` on API 30+,
    /// where the Wi-Fi module no longer reads the Global key; older images
    /// read the key when the Wi-Fi service starts.
    func applyWifiVerboseLogging(serial: String, enabled: Bool) async throws -> ToggleWriteOutcome {
        let api = try await apiLevel(serial: serial)
        // The cached Wi-Fi dump is the row's reading before API 31.
        defer { DeviceEffectsCache.shared.invalidate(effectsCacheKey(serial: serial)) }
        if api >= DeviceEffects.wifiModuleMinimumAPI {
            _ = try await shell(
                serial: serial,
                ["cmd", "wifi", "set-verbose-logging", enabled ? "enabled" : "disabled"]
            )
            return .applied
        }
        _ = try await shell(
            serial: serial,
            ["settings", "put", "global", "wifi_verbose_logging_enabled", enabled ? "1" : "0"]
        )
        return .appliesAfterRestart
    }

    // MARK: - Battery saver

    /// Battery saver through PowerManager (`cmd power set-mode`), the way the
    /// Settings switch does it. BatterySaverStateMachine refuses to enable it
    /// while the device is powered ("Can't enable: isPowered"), so enabling
    /// on a charger is refused up front instead of reporting a switch that
    /// never took — and the `low_power` fallback is never left at 1 on a
    /// charger. Images without `cmd power` fall back to the `low_power` key.
    func applyBatterySaver(serial: String, enabled: Bool) async throws {
        if enabled {
            let battery = (try? await shell(serial: serial, ["dumpsys", "battery"])) ?? ""
            if DeviceEffects.isPowered(fromBatteryDump: battery) == true {
                throw DeviceSettingsError.batterySaverRefusedWhileCharging
            }
        }
        do {
            _ = try await shell(serial: serial, ["cmd", "power", "set-mode", enabled ? "1" : "0"])
        } catch {
            _ = try await shell(serial: serial, ["settings", "put", "global", "low_power", enabled ? "1" : "0"])
        }
    }
}
