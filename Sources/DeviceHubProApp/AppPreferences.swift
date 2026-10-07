import Foundation
import Observation
import DeviceHubProKit

/// The persisted settings: the Settings window's options and the keyboard
/// forwarding toggle, on the defaults store the app was built with.
///
/// Each value is read once, when the preferences are built, with the read
/// semantics it always had. The setters persist and do nothing else: the
/// reactions to a change (in-app audio, the replay ring, clipboard sync, the
/// emulator binary) stay with `AppModel`'s setX methods, which write through
/// here.
@MainActor
@Observable
final class AppPreferences {
    /// The persisted key strings. Each one holds a user's stored setting, so
    /// renaming one silently resets that setting; `AppPreferencesTests` pins
    /// them.
    enum Keys {
        static let includeDeviceFrameInScreenshots = "includeDeviceFrameInScreenshots"
        static let autoRepairAvdDisplay = "autoRepairAvdDisplay"
        static let keyboardForwardingEnabled = "keyboardForwardingEnabled"
        static let emulatorBinaryPath = "emulatorBinaryPath"
        static let emulatorAudioMode = "emulatorAudioMode"
        static let replayEnabled = "replayEnabled"
        static let replayWindowSeconds = "replayWindowSeconds"
        static let replayHintShown = "replayHintShown"
        static let clipboardAutoSync = "clipboardAutoSync"
        static let locationPresets = "locationPresets"
        static let locationDefaultsVersion = "locationDefaultsVersion"
        static let shutDownStartedSimulatorsOnQuit = "shutDownStartedSimulatorsOnQuit"
        static let simulatorDevicectlProbe = "simulatorDevicectlProbe"
        static let simulatorTimeZones = "simulatorTimeZones"
        static let showPhysicalAppleDevices = "showPhysicalAppleDevices"
        static let enabledPhysicalAppleDevices = "enabledPhysicalAppleDevices"
        static let physicalLiveViewEnabled = "physicalLiveViewEnabled"
        static let physicalAutoRefreshEnabled = "physicalAutoRefreshEnabled"
        static let physicalControlTeamID = "physicalControlTeamID"
        static let physicalFastInput = "physicalFastInput"
        static let physicalNativeLiveView = "physicalNativeLiveView"
        static let simulatorInfoVisible = "simulatorInfoVisible"
        static let physicalInfoVisible = "physicalInfoVisible"
        static let zoomHintDismissed = "zoomHintDismissed"
        static let showNavigationButtons = "showNavigationButtons"
        static let stayOnTopMain = "stayOnTopMain"
        static let stayOnTopCompact = "stayOnTopCompact"
        static let settingsProfiles = "settingsProfiles"
        static let androidSDKPath = "androidSDKPath"
        static let androidSetupDismissed = "androidSetupDismissed"
        static let androidReadyCardDismissed = "androidReadyCardDismissed"
        static let localNetworkInUse = "localNetworkInUse"
        static let xcodeHintDismissed = "xcodeHintDismissed"
        static let captureFolderPath = "captureFolderPath"
        static let softKeyboardHintShown = "softKeyboardHintShown"
        static let iosPlatformCardDismissed = "iosPlatformCardDismissed"
        static let iphoneCardDismissed = "iphoneCardDismissed"

        /// Every key, in the order above.
        static let all = [
            includeDeviceFrameInScreenshots,
            autoRepairAvdDisplay,
            keyboardForwardingEnabled,
            emulatorBinaryPath,
            emulatorAudioMode,
            replayEnabled,
            replayWindowSeconds,
            replayHintShown,
            clipboardAutoSync,
            locationPresets,
            locationDefaultsVersion,
            shutDownStartedSimulatorsOnQuit,
            simulatorDevicectlProbe,
            simulatorTimeZones,
            showPhysicalAppleDevices,
            enabledPhysicalAppleDevices,
            physicalLiveViewEnabled,
            physicalAutoRefreshEnabled,
            physicalControlTeamID,
            physicalFastInput,
            physicalNativeLiveView,
            simulatorInfoVisible,
            physicalInfoVisible,
            zoomHintDismissed,
            showNavigationButtons,
            stayOnTopMain,
            stayOnTopCompact,
            settingsProfiles,
            androidSDKPath,
            androidSetupDismissed,
            androidReadyCardDismissed,
            localNetworkInUse,
            xcodeHintDismissed,
            captureFolderPath,
            softKeyboardHintShown,
            iosPlatformCardDismissed,
            iphoneCardDismissed,
        ]
    }

    private let defaults: UserDefaults

    /// Whether captures composite the active device's skin frame. Persisted;
    /// off by default.
    private(set) var includeDeviceFrameInScreenshots: Bool
    /// Repairs an AVD's hw.lcd size to its skin before boot (the original
    /// config is kept as `config.ini.devicehubpro-bak`). Persisted; on by default.
    private(set) var autoRepairAvdDisplay: Bool
    /// Whether Mac keyboard input is forwarded to the device (Device Hub's
    /// Keyboard Capture). Off until first turned on, as in Device Hub; a saved
    /// choice is kept.
    private(set) var keyboardForwardingEnabled: Bool
    /// Custom emulator binary chosen in Settings ("" = system emulator).
    private(set) var emulatorBinaryPath: String
    private(set) var emulatorAudioMode: EmulatorAudioMode = .enabled
    /// Whether the mirror feeds the in-memory replay ring. Persisted; on by
    /// default.
    private(set) var replayEnabled: Bool
    /// The ring's window. Persisted; validated on load against
    /// ``replayWindowOptions``, falling back to the 30 s default.
    private(set) var replayWindowSeconds: Double
    /// Whether the one-time "Missed a bug? Save the last 30 seconds." tip
    /// was shown. Persisted; never shown again once set.
    private(set) var replayHintShown: Bool
    private(set) var clipboardAutoSyncEnabled: Bool
    /// Quit's default for the simulators Device Hub Pro started (Device Hub's
    /// quit choice): shut them down (the default), or keep them running.
    /// The app menu's Option alternate does the other. Simulators Device Hub Pro
    /// did not start are never shut down. Persisted.
    private(set) var shutsDownStartedSimulatorsOnQuit: Bool
    /// devicectl's answer for a simulator, kept per CoreDevice version: T2
    /// without asking again until CoreDevice changes. Nil
    /// until a probe answered.
    private(set) var simulatorDevicectlProbe: CachedDevicectlProbe?
    /// The time zone the Controls chose per simulator (UDID → zone
    /// identifier): simctl has no time-zone command, so Device Hub Pro hands it to
    /// the boots it starts (`SIMCTL_CHILD_TZ`). A simulator without an entry
    /// boots with the Mac's zone.
    private(set) var simulatorTimeZones: [String: String]
    /// "Show physical Apple devices": whether the app looks for
    /// iPhones and iPads at all. Off by default; off means the app never
    /// runs `devicectl list devices`. Persisted.
    private(set) var showPhysicalAppleDevices: Bool
    /// The hardware UDIDs (upper-cased) of the physical Apple devices the
    /// user chose to use ("Use This Device…"). No command but the list
    /// reaches a device that is not in this set. Persisted, sorted.
    private(set) var enabledPhysicalAppleDevices: [String]
    /// "Live View": a USB-connected physical device's
    /// stage shows its screen live (the public CoreMediaIO capture, which
    /// needs the Camera permission). On by default; off falls back to the
    /// screenshot preview or the static panel. Persisted.
    private(set) var physicalLiveViewEnabled: Bool
    /// "Auto-refresh": a physical device's stage shows a self-refreshing
    /// screenshot preview (public `devicectl` screenshots) where the live
    /// capture cannot run (Wi-Fi, no capture device, no Camera permission),
    /// or when Live View is off. On by default; off shows the static panel.
    /// Persisted.
    private(set) var physicalAutoRefreshEnabled: Bool
    /// The Development Team ID the iPhone input runner is signed with
    /// ("Control this iPhone"): ten letters and digits,
    /// as Xcode shows it. Empty until the user types it; Control is
    /// unavailable without it. It is the only signing input kept, in the
    /// app's preferences; it is never logged or shown outside this field.
    private(set) var physicalControlTeamID: String
    /// "Fast input" (on by default since 2026-10-01):
    /// touches, keys and buttons reach a selected, enabled iPhone through the
    /// private CoreDevice HID helper (`fastinput/`) as soon as its live view
    /// shows; the public-XCTest runner stays the lazy fallback.
    /// `DHP_DISABLE_FAST_INPUT` overrides it. Persisted; a device that
    /// never had the choice made gets it on.
    private(set) var physicalFastInput: Bool
    /// The opt-in native live view of a physical iPhone (private Apple API, no
    /// Camera permission); on by default since 2026-10-01.
    private(set) var physicalNativeLiveView: Bool
    /// The simulator Info tab's visible properties (Device Hub's "Edit
    /// Visibility"; one choice for every device). Persisted; a fresh install
    /// lists Device Hub's defaults.
    private(set) var simulatorInfoVisible: Set<SimulatorInfoProperty>
    /// The physical iPhone Info tab's visible properties (the same "Edit
    /// Visibility", chosen apart from the simulators'). Persisted; a fresh
    /// install lists Device Hub's rows and hides Device Hub Pro's extra state rows.
    private(set) var physicalInfoVisible: Set<PhysicalInfoProperty>
    /// Device Hub's "Zoom Controls" hint was closed with its ×: it stays
    /// away from then on (measured on DH 27.0: closed once, it did not come
    /// back at any later zoom-in, nor after other devices were shown).
    private(set) var zoomHintDismissed: Bool
    /// View ▸ Show Navigation Buttons: the Back, Home and Recents bar under
    /// an Android handheld on the stage. On unless the user turned it off.
    private(set) var showNavigationButtons: Bool
    /// Window ▸ Stay on Top, as the user last set it for a main window and
    /// for the compact mirror: new windows start with it (each window then
    /// toggles on its own). Persisted; off on a fresh install.
    private(set) var stayOnTopMain: Bool
    private(set) var stayOnTopCompact: Bool
    /// The Android SDK folder the user chose with "Locate SDK…" ("" = none:
    /// `ANDROID_HOME`, Android Studio's default folder and the PATH are
    /// searched). The guided install sets it when it installs outside
    /// Android Studio's default folder. Persisted.
    private(set) var androidSDKPath: String
    /// The "Set up Android tools" card was closed with "Don't show again":
    /// the empty stage and the sidebar stop showing it (the toolbar's
    /// warning still opens the setup). Persisted.
    private(set) var androidSetupDismissed: Bool
    /// The "Android tools are ready" card (tools installed, no emulator or
    /// phone yet) was closed with "Don't show again". Persisted.
    private(set) var androidReadyCardDismissed: Bool
    /// The app has needed the local network before (the Pair Nearby Device
    /// sheet's Android tile, wireless debugging): from the next launch on adb
    /// starts with mDNS discovery and the Bonjour browse runs at once.
    /// Until then neither runs, so macOS does not ask for Local Network
    /// access on a first launch. Persisted.
    private(set) var localNetworkInUse: Bool
    /// The sidebar's iOS card ("iOS simulators and iPhones need Xcode.") was
    /// closed with "Don't show again". The Pair Nearby Device sheet and the
    /// `+` menu keep saying it. Persisted.
    private(set) var xcodeHintDismissed: Bool
    /// The sidebar's "Download the iOS platform in Xcode" card was closed.
    /// Its own flag: closing it must not also hide the Xcode card, which
    /// says something else. Persisted.
    private(set) var iosPlatformCardDismissed: Bool
    /// The sidebar's "Show iPhones connected to this Mac" card was closed.
    /// Persisted.
    private(set) var iphoneCardDismissed: Bool
    /// The folder screenshots and recordings are saved in, chosen in
    /// Settings; empty means the default (the Mac's screenshot folder, else
    /// the Desktop). Persisted.
    private(set) var captureFolderPath: String
    /// Whether the one-time keyboard tip was shown. Persisted.
    private(set) var softKeyboardHintShown: Bool

    /// The chosen capture folder when it names a folder that exists now, else
    /// nil (the default applies: a folder that was removed or an unmounted
    /// volume never makes a capture fail).
    var captureFolder: URL? {
        ScreenshotFile.existingDirectory(path: captureFolderPath)
    }

    /// Reads every setting from `defaults`, which the setters then write to.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        includeDeviceFrameInScreenshots =
            defaults.object(forKey: Keys.includeDeviceFrameInScreenshots) as? Bool ?? false
        captureFolderPath = defaults.string(forKey: Keys.captureFolderPath) ?? ""
        softKeyboardHintShown = defaults.object(forKey: Keys.softKeyboardHintShown) as? Bool ?? false
        autoRepairAvdDisplay =
            defaults.object(forKey: Keys.autoRepairAvdDisplay) as? Bool ?? true
        keyboardForwardingEnabled =
            defaults.object(forKey: Keys.keyboardForwardingEnabled) as? Bool ?? false
        emulatorBinaryPath = defaults.string(forKey: Keys.emulatorBinaryPath) ?? ""
        replayEnabled =
            defaults.object(forKey: Keys.replayEnabled) as? Bool ?? true
        replayHintShown = defaults.object(forKey: Keys.replayHintShown) as? Bool ?? false
        replayWindowSeconds = Self.validReplayWindow(
            defaults.object(forKey: Keys.replayWindowSeconds) as? Double
        )
        clipboardAutoSyncEnabled = defaults.bool(forKey: Keys.clipboardAutoSync)
        shutsDownStartedSimulatorsOnQuit =
            defaults.object(forKey: Keys.shutDownStartedSimulatorsOnQuit) as? Bool ?? true
        simulatorDevicectlProbe = defaults.data(forKey: Keys.simulatorDevicectlProbe)
            .flatMap { try? JSONDecoder().decode(CachedDevicectlProbe.self, from: $0) }
        simulatorTimeZones = (defaults.dictionary(forKey: Keys.simulatorTimeZones) as? [String: String]) ?? [:]
        showPhysicalAppleDevices = defaults.bool(forKey: Keys.showPhysicalAppleDevices)
        enabledPhysicalAppleDevices = Self.normalizedUDIDs(
            (defaults.array(forKey: Keys.enabledPhysicalAppleDevices) as? [String]) ?? []
        )

        physicalLiveViewEnabled =
            defaults.object(forKey: Keys.physicalLiveViewEnabled) as? Bool ?? true
        physicalAutoRefreshEnabled =
            defaults.object(forKey: Keys.physicalAutoRefreshEnabled) as? Bool ?? true
        physicalControlTeamID = Self.normalizedTeamID(defaults.string(forKey: Keys.physicalControlTeamID) ?? "")
        physicalFastInput = defaults.object(forKey: Keys.physicalFastInput) as? Bool ?? true
        physicalNativeLiveView = defaults.object(forKey: Keys.physicalNativeLiveView) as? Bool ?? true
        simulatorInfoVisible = SimulatorInfoProperty.decode(defaults.array(forKey: Keys.simulatorInfoVisible) as? [String])
        physicalInfoVisible = PhysicalInfoProperty.decode(defaults.array(forKey: Keys.physicalInfoVisible) as? [String])
        zoomHintDismissed = defaults.bool(forKey: Keys.zoomHintDismissed)
        showNavigationButtons = defaults.object(forKey: Keys.showNavigationButtons) as? Bool ?? true
        stayOnTopMain = defaults.bool(forKey: Keys.stayOnTopMain)
        stayOnTopCompact = defaults.bool(forKey: Keys.stayOnTopCompact)
        androidSDKPath = defaults.string(forKey: Keys.androidSDKPath) ?? ""
        androidSetupDismissed = defaults.bool(forKey: Keys.androidSetupDismissed)
        androidReadyCardDismissed = defaults.bool(forKey: Keys.androidReadyCardDismissed)
        localNetworkInUse = defaults.bool(forKey: Keys.localNetworkInUse)
        xcodeHintDismissed = defaults.bool(forKey: Keys.xcodeHintDismissed)
        iosPlatformCardDismissed = defaults.bool(forKey: Keys.iosPlatformCardDismissed)
        iphoneCardDismissed = defaults.bool(forKey: Keys.iphoneCardDismissed)

        if let raw = defaults.string(forKey: Keys.emulatorAudioMode),
           let mode = EmulatorAudioMode(rawValue: raw) {
            emulatorAudioMode = mode
        }
    }

    // MARK: - Replay window

    /// The windows Settings offers; the default is 30 s.
    static let replayWindowOptions: [Double] = [15, 30, 60]

    /// A persisted window is accepted only when it is one of the offered
    /// options; a missing, stale or hand-edited value falls back to 30 s.
    static func validReplayWindow(_ persisted: Double?) -> Double {
        guard let persisted, replayWindowOptions.contains(persisted) else { return 30 }
        return persisted
    }

    // MARK: - Setters

    func setSimulatorInfoVisible(_ visible: Set<SimulatorInfoProperty>) {
        simulatorInfoVisible = visible
        defaults.set(SimulatorInfoProperty.encode(visible), forKey: Keys.simulatorInfoVisible)
    }

    func setPhysicalInfoVisible(_ visible: Set<PhysicalInfoProperty>) {
        physicalInfoVisible = visible
        defaults.set(PhysicalInfoProperty.encode(visible), forKey: Keys.physicalInfoVisible)
    }

    func setAndroidSDKPath(_ path: String) {
        androidSDKPath = path
        if path.isEmpty {
            defaults.removeObject(forKey: Keys.androidSDKPath)
        } else {
            defaults.set(path, forKey: Keys.androidSDKPath)
        }
    }

    func setXcodeHintDismissed(_ dismissed: Bool) {
        xcodeHintDismissed = dismissed
        defaults.set(dismissed, forKey: Keys.xcodeHintDismissed)
    }

    func setIOSPlatformCardDismissed(_ dismissed: Bool) {
        iosPlatformCardDismissed = dismissed
        defaults.set(dismissed, forKey: Keys.iosPlatformCardDismissed)
    }

    func setIPhoneCardDismissed(_ dismissed: Bool) {
        iphoneCardDismissed = dismissed
        defaults.set(dismissed, forKey: Keys.iphoneCardDismissed)
    }

    func setLocalNetworkInUse(_ inUse: Bool) {
        localNetworkInUse = inUse
        defaults.set(inUse, forKey: Keys.localNetworkInUse)
    }

    func setAndroidSetupDismissed(_ dismissed: Bool) {
        androidSetupDismissed = dismissed
        defaults.set(dismissed, forKey: Keys.androidSetupDismissed)
    }

    func setAndroidReadyCardDismissed(_ dismissed: Bool) {
        androidReadyCardDismissed = dismissed
        defaults.set(dismissed, forKey: Keys.androidReadyCardDismissed)
    }

    func setShowNavigationButtons(_ shown: Bool) {
        showNavigationButtons = shown
        defaults.set(shown, forKey: Keys.showNavigationButtons)
    }

    func setStayOnTop(_ on: Bool, compact: Bool) {
        if compact {
            stayOnTopCompact = on
            defaults.set(on, forKey: Keys.stayOnTopCompact)
        } else {
            stayOnTopMain = on
            defaults.set(on, forKey: Keys.stayOnTopMain)
        }
    }

    func setZoomHintDismissed(_ dismissed: Bool) {
        zoomHintDismissed = dismissed
        defaults.set(dismissed, forKey: Keys.zoomHintDismissed)
    }

    /// Sets the capture folder; nil goes back to the default.
    func setCaptureFolder(_ url: URL?) {
        captureFolderPath = url?.path ?? ""
        if captureFolderPath.isEmpty {
            defaults.removeObject(forKey: Keys.captureFolderPath)
        } else {
            defaults.set(captureFolderPath, forKey: Keys.captureFolderPath)
        }
    }

    func setIncludeDeviceFrameInScreenshots(_ enabled: Bool) {
        includeDeviceFrameInScreenshots = enabled
        defaults.set(enabled, forKey: Keys.includeDeviceFrameInScreenshots)
    }

    func setAutoRepairAvdDisplay(_ enabled: Bool) {
        autoRepairAvdDisplay = enabled
        defaults.set(enabled, forKey: Keys.autoRepairAvdDisplay)
    }

    func setKeyboardForwarding(_ enabled: Bool) {
        keyboardForwardingEnabled = enabled
        defaults.set(enabled, forKey: Keys.keyboardForwardingEnabled)
    }

    func setEmulatorBinaryPath(_ path: String) {
        emulatorBinaryPath = path
        defaults.set(path, forKey: Keys.emulatorBinaryPath)
    }

    func setEmulatorAudioMode(_ mode: EmulatorAudioMode) {
        emulatorAudioMode = mode
        defaults.set(mode.rawValue, forKey: Keys.emulatorAudioMode)
    }

    func markSoftKeyboardHintShown() {
        softKeyboardHintShown = true
        defaults.set(true, forKey: Keys.softKeyboardHintShown)
    }

    func markReplayHintShown() {
        replayHintShown = true
        defaults.set(true, forKey: Keys.replayHintShown)
    }

    func setReplayEnabled(_ enabled: Bool) {
        replayEnabled = enabled
        defaults.set(enabled, forKey: Keys.replayEnabled)
    }

    /// Persists `seconds` as given; `AppModel.setReplayWindowSeconds` accepts
    /// only the ``replayWindowOptions``.
    func setReplayWindowSeconds(_ seconds: Double) {
        replayWindowSeconds = seconds
        defaults.set(seconds, forKey: Keys.replayWindowSeconds)
    }

    func setClipboardAutoSync(_ enabled: Bool) {
        clipboardAutoSyncEnabled = enabled
        defaults.set(enabled, forKey: Keys.clipboardAutoSync)
    }

    func setShutsDownStartedSimulatorsOnQuit(_ shutsDown: Bool) {
        shutsDownStartedSimulatorsOnQuit = shutsDown
        defaults.set(shutsDown, forKey: Keys.shutDownStartedSimulatorsOnQuit)
    }

    /// Sets (or, with nil, forgets) a simulator's boot time zone.
    func setSimulatorTimeZone(_ zone: String?, udid: String) {
        simulatorTimeZones[udid] = zone
        defaults.set(simulatorTimeZones, forKey: Keys.simulatorTimeZones)
    }

    func setShowPhysicalAppleDevices(_ show: Bool) {
        showPhysicalAppleDevices = show
        defaults.set(show, forKey: Keys.showPhysicalAppleDevices)
    }

    func setPhysicalLiveViewEnabled(_ enabled: Bool) {
        physicalLiveViewEnabled = enabled
        defaults.set(enabled, forKey: Keys.physicalLiveViewEnabled)
    }

    func setPhysicalAutoRefreshEnabled(_ enabled: Bool) {
        physicalAutoRefreshEnabled = enabled
        defaults.set(enabled, forKey: Keys.physicalAutoRefreshEnabled)
    }

    func setPhysicalNativeLiveView(_ enabled: Bool) {
        physicalNativeLiveView = enabled
        defaults.set(enabled, forKey: Keys.physicalNativeLiveView)
    }

    func setPhysicalFastInput(_ enabled: Bool) {
        physicalFastInput = enabled
        defaults.set(enabled, forKey: Keys.physicalFastInput)
    }

    /// Sets the Development Team ID (trimmed, upper-cased).
    func setPhysicalControlTeamID(_ text: String) {
        physicalControlTeamID = Self.normalizedTeamID(text)
        defaults.set(physicalControlTeamID, forKey: Keys.physicalControlTeamID)
    }

    /// The team the input runner may be signed with: exactly ten letters
    /// and digits, else nil (Control is then unavailable).
    var validPhysicalControlTeamID: String? {
        Self.isValidTeamID(physicalControlTeamID) ? physicalControlTeamID : nil
    }

    static func normalizedTeamID(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func isValidTeamID(_ text: String) -> Bool {
        text.count == 10 && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) }
    }

    /// Adds (or removes) a physical Apple device to the ones the user chose
    /// to use, by hardware UDID.
    func setPhysicalAppleDevice(_ hardwareUDID: String, enabled: Bool) {
        var udids = Set(enabledPhysicalAppleDevices)
        let udid = PhysicalDeviceOptIn.normalize(hardwareUDID)
        guard !udid.isEmpty else { return }
        if enabled { udids.insert(udid) } else { udids.remove(udid) }
        enabledPhysicalAppleDevices = udids.sorted()
        defaults.set(enabledPhysicalAppleDevices, forKey: Keys.enabledPhysicalAppleDevices)
    }

    func isPhysicalAppleDeviceEnabled(_ hardwareUDID: String) -> Bool {
        enabledPhysicalAppleDevices.contains(PhysicalDeviceOptIn.normalize(hardwareUDID))
    }

    private static func normalizedUDIDs(_ udids: [String]) -> [String] {
        Set(udids.map(PhysicalDeviceOptIn.normalize).filter { !$0.isEmpty }).sorted()
    }

    func setSimulatorDevicectlProbe(_ probe: CachedDevicectlProbe?) {
        simulatorDevicectlProbe = probe
        if let probe, let data = try? JSONEncoder().encode(probe) {
            defaults.set(data, forKey: Keys.simulatorDevicectlProbe)
        } else {
            defaults.removeObject(forKey: Keys.simulatorDevicectlProbe)
        }
    }
}

/// The saved locations' persistence: the Location sheet's list as JSON, and
/// the one-time merge that brings new ready locations to an existing install.
@MainActor
struct LocationPresetStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func persist(_ locationPresets: [SavedLocation]) {
        if let data = try? JSONEncoder().encode(locationPresets) {
            defaults.set(data, forKey: AppPreferences.Keys.locationPresets)
        }
    }

    /// Bumped when the ready-location set changes so an existing install gets
    /// the new entries once (a deleted ready location never comes back).
    private static let locationDefaultsVersion = 2

    /// The saved locations; the ready ones on a fresh install. The first load
    /// after ``locationDefaultsVersion`` changed appends the missing ready
    /// locations and persists the result.
    func load() -> [SavedLocation] {
        var presets: [SavedLocation]
        if let data = defaults.data(forKey: AppPreferences.Keys.locationPresets),
           let decoded = try? JSONDecoder().decode([SavedLocation].self, from: data) {
            presets = decoded
        } else {
            presets = SavedLocation.defaults
        }
        if defaults.integer(forKey: AppPreferences.Keys.locationDefaultsVersion) < Self.locationDefaultsVersion {
            for ready in SavedLocation.defaults where !presets.contains(where: { $0.name == ready.name }) {
                presets.append(ready)
            }
            defaults.set(
                Self.locationDefaultsVersion,
                forKey: AppPreferences.Keys.locationDefaultsVersion
            )
            if let data = try? JSONEncoder().encode(presets) {
                defaults.set(data, forKey: AppPreferences.Keys.locationPresets)
            }
        }
        return presets
    }
}

/// A devicectl answer for a simulator (`device info details`'s `info` block)
/// and the CoreDevice version it was asked on: T2 holds while that version
/// is installed ("probed and cached per CoreDevice version").
struct CachedDevicectlProbe: Codable, Equatable, Sendable {
    /// The installed CoreDevice framework's `CFBundleVersion` ("642.16").
    var coreDeviceVersion: String
    var info: DevicectlInfo
}
