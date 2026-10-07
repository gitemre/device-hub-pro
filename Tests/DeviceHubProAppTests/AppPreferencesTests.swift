import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// The persisted settings: their key strings, defaults and read semantics,
/// the saved locations' one-time merge, and a model reading and writing
/// them through the defaults it was built on. The keys are users' stored
/// settings, so the literals here are deliberate: a renamed key must fail
/// this suite, not silently reset someone's settings.
@MainActor
final class AppPreferencesTests: XCTestCase {
    // MARK: - Keys and defaults

    func testKeyStringsNeverChange() {
        XCTAssertEqual(AppPreferences.Keys.all, [
            "includeDeviceFrameInScreenshots",
            "autoRepairAvdDisplay",
            "keyboardForwardingEnabled",
            "emulatorBinaryPath",
            "emulatorAudioMode",
            "replayEnabled",
            "replayWindowSeconds",
            "replayHintShown",
            "clipboardAutoSync",
            "locationPresets",
            "locationDefaultsVersion",
            "shutDownStartedSimulatorsOnQuit",
            "simulatorDevicectlProbe",
            "simulatorTimeZones",
            "showPhysicalAppleDevices",
            "enabledPhysicalAppleDevices",
            "physicalLiveViewEnabled",
            "physicalAutoRefreshEnabled",
            "physicalControlTeamID",
            "physicalFastInput",
            "physicalNativeLiveView",
            "simulatorInfoVisible",
            "physicalInfoVisible",
            "zoomHintDismissed",
            "showNavigationButtons",
            "stayOnTopMain",
            "stayOnTopCompact",
            "settingsProfiles",
            "androidSDKPath",
            "androidSetupDismissed",
            "androidReadyCardDismissed",
            "localNetworkInUse",
            "xcodeHintDismissed",
            "captureFolderPath",
            "softKeyboardHintShown",
            "iosPlatformCardDismissed",
            "iphoneCardDismissed",
        ])
    }

    func testClosingTheXcodeCardIsRemembered() {
        let defaults = UserDefaults.scratch()
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.xcodeHintDismissed)
        preferences.setXcodeHintDismissed(true)
        XCTAssertTrue(AppPreferences(defaults: defaults).xcodeHintDismissed)
    }

    func testClosingTheReadyCardIsRemembered() {
        let defaults = UserDefaults.scratch()
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.androidReadyCardDismissed)
        preferences.setAndroidReadyCardDismissed(true)
        XCTAssertTrue(AppPreferences(defaults: defaults).androidReadyCardDismissed)
    }

    func testNeedingTheLocalNetworkOnceIsRemembered() {
        let defaults = UserDefaults.scratch()
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.localNetworkInUse, "a fresh install has not needed it")
        preferences.setLocalNetworkInUse(true)
        XCTAssertTrue(AppPreferences(defaults: defaults).localNetworkInUse)
    }

    func testTheAndroidSDKFolderAndTheSetupCardChoicePersist() {
        let defaults = UserDefaults.scratch()
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.androidSDKPath, "")
        XCTAssertFalse(preferences.androidSetupDismissed)
        preferences.setAndroidSDKPath("/Volumes/Tools/android-sdk")
        preferences.setAndroidSetupDismissed(true)
        let reread = AppPreferences(defaults: defaults)
        XCTAssertEqual(reread.androidSDKPath, "/Volumes/Tools/android-sdk")
        XCTAssertTrue(reread.androidSetupDismissed)
        preferences.setAndroidSDKPath("")
        XCTAssertNil(defaults.object(forKey: "androidSDKPath"), "forgotten, not stored as an empty string")
    }

    /// Fast input is on by default (2026-10-01): on for a fresh install or one that never chose, and the choice persists.
    func testFastInputIsOnByDefaultAndPersists() {
        let defaults = UserDefaults.scratch()
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.physicalFastInput)
        XCTAssertNil(defaults.object(forKey: "physicalFastInput"))
        preferences.setPhysicalFastInput(false)
        XCTAssertEqual(defaults.object(forKey: "physicalFastInput") as? Bool, false)
        XCTAssertFalse(AppPreferences(defaults: defaults).physicalFastInput)
        preferences.setPhysicalFastInput(true)
        XCTAssertTrue(AppPreferences(defaults: defaults).physicalFastInput)
    }

    /// The native live view is on by default (2026-10-01), and the choice persists.
    func testNativeLiveViewIsOnByDefaultAndPersists() {
        let defaults = UserDefaults.scratch()
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.physicalNativeLiveView)
        XCTAssertNil(defaults.object(forKey: "physicalNativeLiveView"))
        preferences.setPhysicalNativeLiveView(false)
        XCTAssertEqual(defaults.object(forKey: "physicalNativeLiveView") as? Bool, false)
        XCTAssertFalse(AppPreferences(defaults: defaults).physicalNativeLiveView)
        preferences.setPhysicalNativeLiveView(true)
        XCTAssertTrue(AppPreferences(defaults: defaults).physicalNativeLiveView)
    }

    func testFreshInstallDefaults() {
        let preferences = AppPreferences(defaults: .scratch())

        XCTAssertFalse(preferences.includeDeviceFrameInScreenshots)
        XCTAssertTrue(preferences.autoRepairAvdDisplay)
        XCTAssertFalse(preferences.keyboardForwardingEnabled, "Keyboard Capture starts off, as in Device Hub")
        XCTAssertEqual(preferences.emulatorBinaryPath, "")
        XCTAssertEqual(preferences.emulatorAudioMode, .enabled)
        XCTAssertTrue(preferences.replayEnabled)
        XCTAssertEqual(preferences.replayWindowSeconds, 30)
        XCTAssertFalse(preferences.clipboardAutoSyncEnabled)
        XCTAssertTrue(preferences.shutsDownStartedSimulatorsOnQuit)
    }

    /// Quit's default for the simulators Device Hub Pro started: shut down unless
    /// the user keeps them; a stored false is kept.
    func testTheSimulatorQuitDefaultPersists() {
        let defaults = UserDefaults.scratch()
        let preferences = AppPreferences(defaults: defaults)
        preferences.setShutsDownStartedSimulatorsOnQuit(false)
        XCTAssertEqual(defaults.object(forKey: "shutDownStartedSimulatorsOnQuit") as? Bool, false)
        XCTAssertFalse(AppPreferences(defaults: defaults).shutsDownStartedSimulatorsOnQuit)
        preferences.setShutsDownStartedSimulatorsOnQuit(true)
        XCTAssertTrue(AppPreferences(defaults: defaults).shutsDownStartedSimulatorsOnQuit)
    }

    /// The default-true flags are read as `object(forKey:) as? Bool`, so a
    /// stored false is kept rather than mistaken for a missing value.
    func testStoredValuesOverrideTheDefaults() {
        let defaults = UserDefaults.scratch()
        defaults.set(true, forKey: "includeDeviceFrameInScreenshots")
        defaults.set(false, forKey: "autoRepairAvdDisplay")
        defaults.set(false, forKey: "keyboardForwardingEnabled")
        defaults.set("/opt/android/emulator/emulator", forKey: "emulatorBinaryPath")
        defaults.set("inApp", forKey: "emulatorAudioMode")
        defaults.set(false, forKey: "replayEnabled")
        defaults.set(60.0, forKey: "replayWindowSeconds")
        defaults.set(true, forKey: "clipboardAutoSync")

        let preferences = AppPreferences(defaults: defaults)

        XCTAssertTrue(preferences.includeDeviceFrameInScreenshots)
        XCTAssertFalse(preferences.autoRepairAvdDisplay)
        XCTAssertFalse(preferences.keyboardForwardingEnabled)
        XCTAssertEqual(preferences.emulatorBinaryPath, "/opt/android/emulator/emulator")
        XCTAssertEqual(preferences.emulatorAudioMode, .inApp)
        XCTAssertFalse(preferences.replayEnabled)
        XCTAssertEqual(preferences.replayWindowSeconds, 60)
        XCTAssertTrue(preferences.clipboardAutoSyncEnabled)
    }

    /// Only `clipboardAutoSync` is read with `bool(forKey:)`, which also
    /// takes the string "YES"; the other flags take only a stored Bool and
    /// otherwise keep their default.
    func testEachFlagKeepsItsReadSemantics() {
        let defaults = UserDefaults.scratch()
        defaults.set("YES", forKey: "clipboardAutoSync")
        defaults.set("YES", forKey: "includeDeviceFrameInScreenshots")
        defaults.set("NO", forKey: "autoRepairAvdDisplay")
        defaults.set("NO", forKey: "keyboardForwardingEnabled")
        defaults.set("NO", forKey: "replayEnabled")

        let preferences = AppPreferences(defaults: defaults)

        XCTAssertTrue(preferences.clipboardAutoSyncEnabled)
        XCTAssertFalse(preferences.includeDeviceFrameInScreenshots)
        XCTAssertTrue(preferences.autoRepairAvdDisplay)
        XCTAssertFalse(preferences.keyboardForwardingEnabled)
        XCTAssertTrue(preferences.replayEnabled)
    }

    /// A window outside the offered 15/30/60 s, missing or not stored as a
    /// number, falls back to 30 s.
    func testReplayWindowFallsBackToThirtySeconds() {
        let outsideTheOptions: [Any] = [45.0, 0.0, -30.0, "60"]
        for stored in outsideTheOptions {
            let defaults = UserDefaults.scratch()
            defaults.set(stored, forKey: "replayWindowSeconds")
            XCTAssertEqual(
                AppPreferences(defaults: defaults).replayWindowSeconds,
                30,
                "\(stored) must fall back to 30"
            )
        }
        XCTAssertEqual(AppPreferences(defaults: .scratch()).replayWindowSeconds, 30)
    }

    func testUnknownAudioModeFallsBackToTheEmulator() {
        let defaults = UserDefaults.scratch()
        defaults.set("loud", forKey: "emulatorAudioMode")

        XCTAssertEqual(AppPreferences(defaults: defaults).emulatorAudioMode, .enabled)
    }

    /// Each setter stores its value under its key with the type the app
    /// always wrote, so an older or newer build reads it back.
    func testSettersPersistUnderTheSameKeysAndTypes() {
        let defaults = UserDefaults.scratch()
        let preferences = AppPreferences(defaults: defaults)

        preferences.setIncludeDeviceFrameInScreenshots(true)
        preferences.setAutoRepairAvdDisplay(false)
        preferences.setKeyboardForwarding(false)
        preferences.setEmulatorBinaryPath("/opt/android/emulator/emulator")
        preferences.setEmulatorAudioMode(.disabled)
        preferences.setReplayEnabled(false)
        preferences.setReplayWindowSeconds(15)
        preferences.setClipboardAutoSync(true)

        XCTAssertEqual(defaults.object(forKey: "includeDeviceFrameInScreenshots") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "autoRepairAvdDisplay") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "keyboardForwardingEnabled") as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: "emulatorBinaryPath"), "/opt/android/emulator/emulator")
        XCTAssertEqual(defaults.string(forKey: "emulatorAudioMode"), "disabled")
        XCTAssertEqual(defaults.object(forKey: "replayEnabled") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "replayWindowSeconds") as? Double, 15)
        XCTAssertEqual(defaults.object(forKey: "clipboardAutoSync") as? Bool, true)
        XCTAssertEqual(preferences.emulatorAudioMode, .disabled)
        XCTAssertEqual(preferences.replayWindowSeconds, 15)
    }

    // MARK: - Saved locations

    func testFreshInstallGetsTheReadyLocations() throws {
        let defaults = UserDefaults.scratch()

        let presets = LocationPresetStore(defaults: defaults).load()

        XCTAssertEqual(presets, SavedLocation.defaults)
        XCTAssertEqual(defaults.integer(forKey: "locationDefaultsVersion"), 2)
        XCTAssertEqual(try persistedLocations(in: defaults), SavedLocation.defaults)
    }

    /// An install from before version 2 keeps its own locations and gets the
    /// ready ones it lacks, once.
    func testLocationMergeAppendsTheMissingReadyLocationsOnce() throws {
        let defaults = UserDefaults.scratch()
        let home = SavedLocation(name: "Home", latitude: 41.0, longitude: 29.0)
        let ankara = SavedLocation(name: "Ankara", latitude: 39.9334, longitude: 32.8597)
        defaults.set(try JSONEncoder().encode([home, ankara]), forKey: "locationPresets")
        defaults.set(1, forKey: "locationDefaultsVersion")
        let store = LocationPresetStore(defaults: defaults)

        let merged = store.load()

        XCTAssertEqual(merged.map(\.name), ["Home", "Ankara", "İstanbul", "İzmir", "Paris", "New York"])
        XCTAssertEqual(merged.prefix(2).map(\.id), [home.id, ankara.id])
        XCTAssertEqual(defaults.integer(forKey: "locationDefaultsVersion"), 2)
        XCTAssertEqual(try persistedLocations(in: defaults), merged)
        XCTAssertEqual(store.load(), merged, "the merge runs once")
    }

    func testLocationMergeNeverRestoresADeletedReadyLocation() {
        let defaults = UserDefaults.scratch()
        let store = LocationPresetStore(defaults: defaults)
        var presets = store.load()
        presets.removeAll { $0.name == "Paris" }
        store.persist(presets)

        let relaunched = LocationPresetStore(defaults: defaults).load()

        XCTAssertEqual(relaunched.map(\.name), ["Ankara", "İstanbul", "İzmir", "New York"])
    }

    // MARK: - A model on its defaults

    func testModelReadsItsSettingsFromItsDefaults() throws {
        let defaults = UserDefaults.scratch()
        defaults.set("inApp", forKey: "emulatorAudioMode")
        defaults.set("/opt/android/emulator/emulator", forKey: "emulatorBinaryPath")
        let home = SavedLocation(name: "Home", latitude: 41.0, longitude: 29.0)
        defaults.set(try JSONEncoder().encode([home]), forKey: "locationPresets")
        defaults.set(2, forKey: "locationDefaultsVersion")

        let model = AppModel.testing(defaults: defaults)

        XCTAssertEqual(model.preferences.emulatorAudioMode, .inApp)
        XCTAssertEqual(model.preferences.emulatorBinaryPath, "/opt/android/emulator/emulator")
        XCTAssertEqual(model.workspace.location.locationPresets, [home])
        XCTAssertEqual(model.workspace.location.selectedLocationID, home.id)
    }

    func testModelReadsItsRecentAPKsFromItsDefaults() throws {
        let apk = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPreferencesTests-\(UUID().uuidString).apk")
        try Data("apk".utf8).write(to: apk)
        addTeardownBlock { try? FileManager.default.removeItem(at: apk) }
        let defaults = UserDefaults.scratch()
        let entry = RecentAPKEntry(path: apk.path, package: "com.example.app", version: "1", name: nil)
        defaults.set(try JSONEncoder().encode([entry]), forKey: "recentAPKPaths")

        let model = AppModel.testing(defaults: defaults)

        XCTAssertEqual(model.workspace.apps.recentAPKs.entries.map(\.package), ["com.example.app"])
    }

    /// A model's writes land in its own defaults and nowhere else: the
    /// write notifies its suite and never the standard defaults.
    func testModelWritesOnlyToItsDefaults() {
        let defaults = UserDefaults.scratch()
        let model = AppModel.testing(defaults: defaults)
        let suiteWrite = expectation(forNotification: UserDefaults.didChangeNotification, object: defaults)
        let standardWrite = expectation(
            forNotification: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
        standardWrite.isInverted = true

        model.workspace.media.setReplayEnabled(false)

        wait(for: [suiteWrite, standardWrite], timeout: 0.5)
        XCTAssertEqual(defaults.object(forKey: "replayEnabled") as? Bool, false)
    }

    /// Settings changed through the model survive a relaunch: a second model
    /// on the same defaults starts with every value the first one set.
    func testSettingsSurviveARelaunchOnTheSameDefaults() {
        let defaults = UserDefaults.scratch()
        let first = AppModel.testing(defaults: defaults)
        first.preferences.setIncludeDeviceFrameInScreenshots(true)
        first.preferences.setAutoRepairAvdDisplay(false)
        first.preferences.setKeyboardForwarding(false)
        first.setEmulatorBinaryPath("/opt/android/emulator/emulator")
        first.setEmulatorAudioMode(.disabled)
        first.workspace.media.setReplayEnabled(false)
        first.workspace.media.setReplayWindowSeconds(60)
        first.workspace.clipboard.setAutoSync(true, physical: first.workspace.mirror.activePhysicalSession)

        let relaunched = AppModel.testing(defaults: defaults)

        XCTAssertTrue(relaunched.preferences.includeDeviceFrameInScreenshots)
        XCTAssertFalse(relaunched.preferences.autoRepairAvdDisplay)
        XCTAssertFalse(relaunched.preferences.keyboardForwardingEnabled)
        XCTAssertEqual(relaunched.preferences.emulatorBinaryPath, "/opt/android/emulator/emulator")
        XCTAssertEqual(relaunched.preferences.emulatorAudioMode, .disabled)
        XCTAssertFalse(relaunched.preferences.replayEnabled)
        XCTAssertEqual(relaunched.preferences.replayWindowSeconds, 60)
        XCTAssertTrue(relaunched.preferences.clipboardAutoSyncEnabled)
    }

    /// The model only accepts an offered replay window; anything else is
    /// neither applied nor persisted.
    func testModelIgnoresAReplayWindowOutsideTheOptions() {
        let defaults = UserDefaults.scratch()
        let model = AppModel.testing(defaults: defaults)

        model.workspace.media.setReplayWindowSeconds(45)

        XCTAssertEqual(model.preferences.replayWindowSeconds, 30)
        XCTAssertNil(defaults.object(forKey: "replayWindowSeconds"))
    }

    // MARK: - Harness

    private func persistedLocations(in defaults: UserDefaults) throws -> [SavedLocation] {
        let data = try XCTUnwrap(defaults.data(forKey: "locationPresets"))
        return try JSONDecoder().decode([SavedLocation].self, from: data)
    }
}
