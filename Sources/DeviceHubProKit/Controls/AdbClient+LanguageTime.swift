import Foundation

/// The Language & time rows' commands. Every write is read back from where
/// Android applies it before it returns — several of these commands answer
/// success for a change they ignored (`cmd alarm set-timezone` with an unknown
/// zone, `cmd alarm set-time`'s injector) — and throws `LanguageTimeError.notApplied`
/// when the device does not show it.
extension AdbClient {
    /// The bound for a helper run: a push plus `app_process` start-up plus the
    /// settle pause.
    static let localeHelperTimeout: Duration = .seconds(30)

    // MARK: - Reads

    /// What this device's Language & time rows can do, in one round trip.
    public func languageTimeSupport(serial: String) async throws -> LanguageTimeSupport {
        let output = try await shell(serial: serial, [LanguageTimeSupport.probeScript()])
        let support = LanguageTimeSupport.parse(output)
        guard support.apiLevel != nil else {
            throw AdbError.commandFailed(
                arguments: ["-s", serial, "shell", "getprop", "ro.build.version.sdk"],
                exitCode: 0,
                message: "unreadable API level"
            )
        }
        return support
    }

    /// The rows' readings, in one round trip.
    public func languageTimeReadings(
        serial: String,
        support: LanguageTimeSupport
    ) async throws -> LanguageTimeReadings {
        let output = try await shell(serial: serial, [LanguageTimeReadings.probeScript(support: support)])
        return LanguageTimeReadings.parse(output)
    }

    /// The languages the device offers: `cmd locale list-device-locales`
    /// where the image has it (already in `support`), else the framework's
    /// `supported_locales` through the helper.
    public func supportedDeviceLocales(
        serial: String,
        support: LanguageTimeSupport
    ) async throws -> [DeviceLocale] {
        if !support.deviceLocales.isEmpty { return support.deviceLocales }
        guard support.localeHelper else { return [] }
        let output = try await runLocaleHelper(serial: serial, arguments: ["supported"])
        return DeviceLocaleNames.sorted(
            output.components(separatedBy: .newlines).compactMap(DeviceLocale.init(tag:))
        )
    }

    // MARK: - Language

    /// Replaces the system language list with `target` (see
    /// `DeviceLocaleWritePlan` for the route) and reads the configuration back.
    public func setDeviceLocales(
        serial: String,
        _ target: [DeviceLocale],
        support: LanguageTimeSupport
    ) async throws -> DeviceLocaleWriteOutcome {
        let before = try await languageTimeReadings(serial: serial, support: support)
        let planned = try DeviceLocaleWritePlan.plan(target: target, current: before.locales, support: support)
        var usedCommand = false
        var settled = false
        switch planned.plan.route {
        case .command(let locale):
            try await setDeviceLocaleCommand(serial: serial, locale)
            usedCommand = true
        case .helper(let lists):
            do {
                _ = try await runLocaleHelper(serial: serial, arguments: LocaleHelper.setArguments(lists))
                settled = lists.count > 1
            } catch {
                guard case .command(let locale)? = planned.fallback?.route else { throw error }
                try await setDeviceLocaleCommand(serial: serial, locale)
                usedCommand = true
            }
        }
        let applied = try await configurationLocales(serial: serial)
        guard DeviceLocaleList.sameLanguages(applied, target) else {
            throw LanguageTimeError.notApplied("the language \(DeviceLocaleList.tags(target))")
        }
        return DeviceLocaleWriteOutcome(applied: applied, settled: settled, usedCommand: usedCommand)
    }

    /// Pushes the current language list again so the configuration recomputes
    /// its layout direction from `debug.force_rtl` (what Developer options does
    /// after writing it). The helper keeps the whole list; without it, `cmd
    /// locale set-device-locale` can re-push a single listed language.
    func repushDeviceLocales(serial: String) async throws {
        let support = try await languageTimeSupport(serial: serial)
        if support.localeHelper {
            do {
                _ = try await runLocaleHelper(serial: serial, arguments: ["repush"])
                return
            } catch {
                guard support.setDeviceLocaleCommand else { throw error }
            }
        }
        let current = try await configurationLocales(serial: serial)
        guard support.setDeviceLocaleCommand, current.count == 1, let only = current.first,
              DeviceLocaleWritePlan.isListed(only, in: support.deviceLocales)
        else { throw LanguageTimeError.languageListUnsupported }
        try await setDeviceLocaleCommand(serial: serial, only)
    }

    private func setDeviceLocaleCommand(serial: String, _ locale: DeviceLocale) async throws {
        _ = try await shell(serial: serial, ["cmd", "locale", "set-device-locale", Self.shellQuoted(locale.tag)])
    }

    private func configurationLocales(serial: String) async throws -> [DeviceLocale] {
        let config = try await shell(serial: serial, ["am", "get-config"])
        guard let locales = DeviceLocaleList.fromConfiguration(config) else {
            throw LanguageTimeError.notApplied("a readable language (am get-config)")
        }
        return locales
    }

    /// Pushes the helper under a fresh name, runs it and deletes it in the same
    /// shell command; returns its standard output.
    func runLocaleHelper(serial: String, arguments: [String]) async throws -> String {
        let dex = try LocaleHelper.bundledDexURL()
        let devicePath = LocaleHelper.devicePath()
        try await run(["-s", serial, "push", dex.path, devicePath], timeout: Self.localeHelperTimeout)
        do {
            return try await shell(
                serial: serial,
                [LocaleHelper.runCommand(devicePath: devicePath, arguments: arguments)],
                timeout: Self.localeHelperTimeout
            )
        } catch {
            // The run's own `rm` did not happen if adb failed before the shell ran.
            _ = try? await shell(serial: serial, ["rm", "-f", devicePath])
            throw error
        }
    }

    static func validatePackageName(_ package: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._")
        guard !package.isEmpty, package.unicodeScalars.allSatisfy(allowed.contains) else {
            throw LanguageTimeError.invalidArgument("The package name \"\(package)\"")
        }
    }

    // MARK: - Automatic switches

    /// How an automatic switch was written.
    public enum AutomaticSettingOutcome: Sendable, Equatable {
        /// The Global key, confirmed by the detector where there is one.
        case applied
        /// The detector disagreed with the key (a server flag overrides an
        /// unset `…_explicit` key), so its own command set it; that leaves
        /// `auto_time_zone_explicit` = 1, as the Settings switch does.
        case appliedThroughDetector
    }

    /// Automatic time zone: `settings put global auto_time_zone`, confirmed by
    /// `cmd time_zone_detector is_auto_detection_enabled` on API 31+.
    @discardableResult
    public func setAutomaticTimeZone(
        serial: String,
        enabled: Bool,
        support: LanguageTimeSupport
    ) async throws -> AutomaticSettingOutcome {
        try await setAutomaticSetting(
            serial: serial,
            key: "auto_time_zone",
            detector: support.timeZoneDetector ? "time_zone_detector" : nil,
            enabled: enabled,
            label: "Automatic time zone"
        )
    }

    /// Automatic date & time: `settings put global auto_time`, confirmed by
    /// `cmd time_detector is_auto_detection_enabled` on API 31+.
    @discardableResult
    public func setAutomaticTime(
        serial: String,
        enabled: Bool,
        support: LanguageTimeSupport
    ) async throws -> AutomaticSettingOutcome {
        try await setAutomaticSetting(
            serial: serial,
            key: "auto_time",
            detector: support.timeDetector ? "time_detector" : nil,
            enabled: enabled,
            label: "Automatic date & time"
        )
    }

    private func setAutomaticSetting(
        serial: String,
        key: String,
        detector: String?,
        enabled: Bool,
        label: String
    ) async throws -> AutomaticSettingOutcome {
        _ = try await shell(serial: serial, ["settings", "put", "global", key, enabled ? "1" : "0"])
        guard let detector else {
            let value = try await shell(serial: serial, ["settings", "get", "global", key])
            guard LanguageTimeReadings.autoSetting(value) == enabled else {
                throw LanguageTimeError.notApplied(label)
            }
            return .applied
        }
        if try await detectorAgrees(serial: serial, detector: detector, enabled: enabled) {
            return .applied
        }
        _ = try await shell(
            serial: serial,
            ["cmd", detector, "set_auto_detection_enabled", enabled ? "true" : "false"]
        )
        guard try await detectorAgrees(serial: serial, detector: detector, enabled: enabled) else {
            throw LanguageTimeError.notApplied(label)
        }
        return .appliedThroughDetector
    }

    /// The detector's content observer applies the key asynchronously; a few
    /// short reads cover it.
    private func detectorAgrees(serial: String, detector: String, enabled: Bool) async throws -> Bool {
        for attempt in 0..<5 {
            let answer = try await shell(serial: serial, ["cmd", detector, "is_auto_detection_enabled"])
            if LanguageTimeReadings.detectorBoolean(answer) == enabled { return true }
            if attempt < 4 { try await Task.sleep(for: .milliseconds(100)) }
        }
        return false
    }

    // MARK: - Time zone

    /// Sets the zone the way Settings does: Automatic time zone off first (or
    /// the next network suggestion undoes it), then `cmd alarm set-timezone`
    /// (API 28+). The command ignores an unknown zone and still succeeds, so the
    /// zone is read back from `persist.sys.timezone`.
    public func setTimeZone(serial: String, identifier: String, support: LanguageTimeSupport) async throws {
        guard support.alarmSetTimeZone else { throw LanguageTimeError.unsupported("The time zone") }
        try Self.validateTimeZoneIdentifier(identifier)
        try await setAutomaticTimeZone(serial: serial, enabled: false, support: support)
        _ = try await shell(serial: serial, ["cmd", "alarm", "set-timezone", identifier])
        let applied = try await shell(serial: serial, ["getprop", "persist.sys.timezone"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard applied == identifier else {
            throw LanguageTimeError.notApplied("the time zone \(identifier)")
        }
    }

    static func validateTimeZoneIdentifier(_ identifier: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_+-")
        guard !identifier.isEmpty, identifier.unicodeScalars.allSatisfy(allowed.contains) else {
            throw LanguageTimeError.invalidArgument("The time zone \"\(identifier)\"")
        }
    }

    /// `cmd time_zone_detector get_time_zone_state` (API 34+).
    public func timeZoneDetectorState(serial: String) async throws -> TimeZoneDetectorState? {
        TimeZoneDetectorState.parse(
            try await shell(serial: serial, ["cmd", "time_zone_detector", "get_time_zone_state"])
        )
    }

    /// Puts the detector's zone and confidence back (`set_time_zone_state_for_tests`,
    /// API 34+): a manual zone leaves the confidence high, and on API 37 a later
    /// automatic change from a high confidence posts "Your time zone changed".
    public func restoreTimeZoneDetectorState(serial: String, _ state: TimeZoneDetectorState) async throws {
        try Self.validateTimeZoneIdentifier(state.zoneID)
        _ = try await shell(serial: serial, [
            "cmd", "time_zone_detector", "set_time_zone_state_for_tests",
            "--zone_id", state.zoneID,
            "--user_should_confirm_id", state.userShouldConfirmID ? "true" : "false",
        ])
    }

    /// Clears the system's "Your time zone changed" notification (API 37 posts
    /// it for an automatic change away from a confidently set zone — turning
    /// Automatic time zone back on after picking one), the way it clears itself
    /// when the user turns those notifications off: `time_zone_notifications` 0,
    /// then the previous value back. The notifier posts shortly after the zone
    /// changes, so after a change the caller waits up to `wait` for it (API 37
    /// posted it about a second after `persist.sys.timezone` moved). Returns
    /// whether one was posted.
    @discardableResult
    public func clearTimeZoneChangeNotification(
        serial: String,
        waitingUpTo wait: Duration = .zero
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + wait
        while true {
            let posted = try await shell(serial: serial, ["cmd", "notification", "list"])
            if TimeZoneChangeNotification.isPosted(in: posted) { break }
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(250))
        }
        let original = try await shell(serial: serial, ["settings", "get", "global", "time_zone_notifications"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await shell(serial: serial, ["settings", "put", "global", "time_zone_notifications", "0"])
        for attempt in 0..<10 {
            let list = try await shell(serial: serial, ["cmd", "notification", "list"])
            if !TimeZoneChangeNotification.isPosted(in: list) { break }
            if attempt < 9 { try await Task.sleep(for: .milliseconds(200)) }
        }
        if original == "null" || original.isEmpty {
            _ = try await shell(serial: serial, ["settings", "delete", "global", "time_zone_notifications"])
        } else {
            _ = try await shell(
                serial: serial,
                ["settings", "put", "global", "time_zone_notifications", Self.shellQuoted(original)]
            )
        }
        return true
    }

    // MARK: - Clock

    /// Sets the device clock: Automatic date & time off first (the next network
    /// suggestion would undo it), then `cmd alarm set-time` (API 28+) with the
    /// milliseconds computed here — the device shell's arithmetic is 32-bit.
    /// The command reports success even when it did nothing, so the clock is
    /// read back.
    public func setDeviceClock(
        serial: String,
        epochMilliseconds: Int64,
        support: LanguageTimeSupport
    ) async throws {
        guard support.alarmSetTime else { throw LanguageTimeError.unsupported("The date and time") }
        guard epochMilliseconds > 0 else { throw LanguageTimeError.invalidArgument("The date") }
        try await setAutomaticTime(serial: serial, enabled: false, support: support)
        let sent = ContinuousClock.now
        _ = try await shell(serial: serial, Self.setTimeArguments(epochMilliseconds: epochMilliseconds))
        let reply = try await shell(serial: serial, ["echo", "${EPOCHREALTIME:-$(date +%s)}"])
        let elapsed = ContinuousClock.now - sent
        guard let device = Double(reply.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LanguageTimeError.notApplied("the date and time")
        }
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let expected = Double(epochMilliseconds) / 1000 + elapsedSeconds
        guard abs(device - expected) <= Self.clockTolerance else {
            throw LanguageTimeError.notApplied("the date and time")
        }
    }

    /// How far the read-back may differ from the requested time (the device
    /// reports whole seconds without `$EPOCHREALTIME`, plus adb latency).
    static let clockTolerance: Double = 5

    static func setTimeArguments(epochMilliseconds: Int64) -> [String] {
        ["cmd", "alarm", "set-time", String(epochMilliseconds)]
    }

    // MARK: - 24-hour time

    /// `settings put system time_12_24 12|24`, or delete it for the language's
    /// own format; read back.
    public func setTimeFormat(serial: String, _ setting: TimeFormatSetting) async throws {
        _ = try await shell(serial: serial, Self.timeFormatArguments(setting))
        let value = try await shell(serial: serial, ["settings", "get", "system", "time_12_24"])
        guard TimeFormatSetting.parse(value) == setting else {
            throw LanguageTimeError.notApplied("the 24-hour time setting")
        }
    }

    static func timeFormatArguments(_ setting: TimeFormatSetting) -> [String] {
        if let value = setting.settingsValue {
            return ["settings", "put", "system", "time_12_24", value]
        }
        return ["settings", "delete", "system", "time_12_24"]
    }
}

/// The time zone detector's notification in `cmd notification list`
/// (`userId|package|id|tag|uid`): `0|android|1001|TimeZoneDetector|1000`.
public enum TimeZoneChangeNotification {
    public static func isPosted(in list: String) -> Bool {
        list.components(separatedBy: .newlines).contains { line in
            let fields = line.trimmingCharacters(in: .whitespaces).split(separator: "|", omittingEmptySubsequences: false)
            return fields.count >= 4 && fields[1] == "android" && fields[3] == "TimeZoneDetector"
        }
    }
}
