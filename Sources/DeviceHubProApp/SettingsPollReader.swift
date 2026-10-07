import Foundation
import DeviceHubProKit

/// The Controls poll's settings reads: one reader per `settings list`
/// namespace or command, the values they bring back, and the poll's
/// whole read (`readSettingsPoll`). Each reader only asks the device and
/// decodes the answer; `DeviceControlsController` applies what it read
/// and records its probes. The write paths' reconciles use the same
/// readers, so a read-back never re-reads the whole panel.
extension DeviceControlsController {
    /// Reader for one `settings list` namespace or command; the write paths
    /// use the same readers so a reconcile never re-reads the whole panel.
    struct GlobalReadings {
        var airplaneModeEnabled: Bool?
        var wifiEnabled: Bool?
        var bluetoothEnabled: Bool?
        var mobileDataEnabled: Bool?
        var batterySaverEnabled: Bool?
        var reduceMotion: ReduceMotionReading?
        /// Show Borders, battery saver and the `readsDeviceEffect` toggles,
        /// read from their real mechanism rather than a settings key.
        var effects: DeviceEffects?
        var mobileDataAlwaysActive: SettingsToggleReading?
        var answered = false
    }

    struct SystemReadings {
        var fontScale: FontScaleReading?
        var showTaps: SettingsToggleReading?
        var answered = false
    }

    struct SecureReadings {
        var increaseContrast: SettingsToggleReading?
        var voiceOver: VoiceOverReading?
        var backgroundANRs: SettingsToggleReading?
        var answered = false
    }

    struct VolumeReadings {
        var volume: MediaVolumeReading?
        var answered = false
    }

    struct PackageReadings {
        var package: String?
        var answered = false
    }

    struct AppearanceReadings {
        var result: Result<AppearanceReading, Error>?
    }

    struct DataSaverReadings {
        var result: Result<DataSaverReading, Error>?
    }

    /// One poll's settings reads, applied together or not at all.
    struct SettingsPollReadings {
        var talkBackPackage: String?
        /// Whether the package list answered; nil when it was not read
        /// (known for this device already).
        var talkBackAnswered: Bool?
        var global: GlobalReadings
        var system: SystemReadings
        var secure: SecureReadings
        var volume: VolumeReadings
        var appearance: AppearanceReadings
        var dataSaver: DataSaverReadings
    }

    func readSettingsPoll(
        serial: String,
        knownTalkBackPackage: String?,
        includeSlowRows: Bool = true
    ) async -> SettingsPollReadings {
        var talkBackPackage = knownTalkBackPackage
        var talkBackAnswered: Bool?
        if talkBackPackageSerial != serial {
            // Within one device, keep the last installed-package answer when
            // the package read fails; a device switch starts from scratch.
            let packages = await readTalkBackPackage(serial: serial)
            talkBackPackage = packages.package ?? talkBackPackage
            talkBackAnswered = packages.answered
        }
        async let global = readGlobalSettings(serial: serial)
        async let system = readSystemSettings(serial: serial)
        let package = talkBackPackage
        async let secure = readSecureSettings(serial: serial, talkBackPackage: package)
        async let volume = readMediaVolume(serial: serial)
        // Slow-changing rows are read every `slowRowInterval`, not every
        // poll; a skipped read leaves the row's last value (nil result).
        async let appearance = includeSlowRows
            ? readAppearanceSetting(serial: serial) : AppearanceReadings(result: nil)
        async let dataSaver = includeSlowRows
            ? readDataSaverSetting(serial: serial) : DataSaverReadings(result: nil)
        let (globalRead, systemRead, secureRead, volumeRead, appearanceRead, dataSaverRead) =
            await (global, system, secure, volume, appearance, dataSaver)
        return SettingsPollReadings(
            talkBackPackage: talkBackPackage,
            talkBackAnswered: talkBackAnswered,
            global: globalRead,
            system: systemRead,
            secure: secureRead,
            volume: volumeRead,
            appearance: appearanceRead,
            dataSaver: dataSaverRead
        )
    }

    /// `wifi_on` is the persisted Wi-Fi setting, not a Bool: 1 = on,
    /// 2 = on with airplane mode's override (Wi-Fi turned back on in airplane
    /// mode), 0 = off, 3 = off because of airplane mode.
    static func wifiIsOn(settingValue value: String?) -> Bool {
        value == "1" || value == "2"
    }

    /// `bluetooth_on` is BluetoothManagerService's persisted state: 0 = off,
    /// 1 = on, 2 = it was on when airplane mode came on. 2 alone does not
    /// say whether the radio is on: airplane mode normally turns it off
    /// (and 2 brings it back once airplane mode ends), but Android 11+ keeps
    /// it on, still writing 2, while an audio or hearing-aid device is
    /// connected. So for 2 the adapter's own state decides; without that
    /// answer, 2 counts as on only outside airplane mode, where it is the
    /// moment before the manager turns the radio back on.
    static func bluetoothIsOn(
        settingValue value: String?,
        airplaneModeOn: Bool,
        adapterEnabled: Bool?
    ) -> Bool {
        switch value {
        case "1": return true
        case "2": return adapterEnabled ?? !airplaneModeOn
        default: return false
        }
    }

    // MARK: - Settings reads

    func readGlobalSettings(serial: String) async -> GlobalReadings {
        guard let adbClient else { return GlobalReadings() }
        async let effects = try? adbClient.deviceEffects(serial: serial)
        guard let settings = try? await adbClient.globalSettings(serial: serial) else {
            return GlobalReadings()
        }

        var readings = GlobalReadings()
        readings.answered = true
        let airplaneModeOn = settings["airplane_mode_on"] == "1"
        readings.airplaneModeEnabled = airplaneModeOn
        readings.wifiEnabled = Self.wifiIsOn(settingValue: settings["wifi_on"])
        let bluetoothSetting = settings["bluetooth_on"]
        var adapterEnabled: Bool?
        if bluetoothSetting == "2" {
            // Only this state needs the adapter's answer (one more round trip).
            // Best effort: without it, the airplane-mode rule decides.
            adapterEnabled = try? await adbClient.bluetoothAdapterEnabled(serial: serial)
        }
        readings.bluetoothEnabled = Self.bluetoothIsOn(
            settingValue: bluetoothSetting,
            airplaneModeOn: airplaneModeOn,
            adapterEnabled: adapterEnabled
        )
        readings.mobileDataEnabled = settings["mobile_data"] == "1"
        readings.reduceMotion = ReduceMotionReading.parse(
            window: settings["window_animation_scale"] ?? "null",
            transition: settings["transition_animation_scale"] ?? "null",
            animator: settings["animator_duration_scale"] ?? "null"
        )
        readings.effects = await effects
        readings.batterySaverEnabled = readings.effects?.batterySaver?.reading.isOn
        readings.mobileDataAlwaysActive = SettingsToggleReading.parse(
            settings["mobile_data_always_on"] ?? "null"
        )
        return readings
    }

    func readSystemSettings(serial: String) async -> SystemReadings {
        guard let adbClient,
              let system = try? await adbClient.settingsList(serial: serial, namespace: "system")
        else { return SystemReadings() }
        return SystemReadings(
            fontScale: FontScaleReading.parse(system["font_scale"] ?? "null"),
            showTaps: SettingsToggleReading.parse(system["show_touches"] ?? "null"),
            answered: true
        )
    }

    func readSecureSettings(
        serial: String,
        talkBackPackage: String?
    ) async -> SecureReadings {
        guard let adbClient,
              let secure = try? await adbClient.settingsList(serial: serial, namespace: "secure")
        else { return SecureReadings() }

        let component = TalkBack.serviceComponent(
            for: talkBackPackage ?? TalkBack.gmsPackageID
        )
        return SecureReadings(
            increaseContrast: SettingsToggleReading.parse(
                secure["high_text_contrast_enabled"] ?? "null"
            ),
            voiceOver: VoiceOverReading.parse(
                enabled: secure["accessibility_enabled"] ?? "null",
                services: secure["enabled_accessibility_services"] ?? "null",
                talkBackComponent: component
            ),
            backgroundANRs: SettingsToggleReading.parse(
                secure["anr_show_background"] ?? "null"
            ),
            answered: true
        )
    }

    func readMediaVolume(serial: String) async -> VolumeReadings {
        guard let adbClient,
              let volume = try? await adbClient.mediaVolumeReading(serial: serial)
        else { return VolumeReadings() }
        return VolumeReadings(volume: volume, answered: true)
    }

    private func readTalkBackPackage(serial: String) async -> PackageReadings {
        guard let adbClient,
              let packages = try? await adbClient.listPackages(serial: serial, thirdPartyOnly: false)
        else { return PackageReadings() }
        return PackageReadings(
            package: DeviceSettingsParsing.talkBackPackage(fromPackages: packages),
            answered: true
        )
    }

    func readAppearanceSetting(serial: String) async -> AppearanceReadings {
        guard let adbClient else { return AppearanceReadings() }
        do {
            return AppearanceReadings(result: .success(try await adbClient.appearanceReading(serial: serial)))
        } catch {
            // Only the command failing counts toward hiding the row; an
            // answered but unrepresentable mode did not throw.
            return AppearanceReadings(result: .failure(error))
        }
    }

    func readDataSaverSetting(serial: String) async -> DataSaverReadings {
        guard let adbClient else { return DataSaverReadings() }
        do {
            return DataSaverReadings(
                result: .success(try await adbClient.dataSaverReading(serial: serial))
            )
        } catch {
            return DataSaverReadings(result: .failure(error))
        }
    }
}
