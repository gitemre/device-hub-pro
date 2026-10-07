import AppKit
import Foundation
import DeviceHubProKit

/// What `AppModel` is built from: the Android tools, the Apple simulator
/// tools, the defaults store, the launch options and the AppKit seams.
///
/// `live()` is the only code that locates adb and the emulator, probes Xcode
/// for simctl and devicectl, names the user's simulator device set or reads
/// the process environment. A model built on any other environment has
/// exactly the tools it was given — nil means none — so a test can never
/// reach a real adb (and through it a real device), or a real simctl (and
/// through it the user's simulators), by leaving a parameter out.
///
/// `live()` is also the only environment whose emulators see every VM on
/// the Mac. Any other one sees only the VMs its own process started
/// (`EmulatorProcessScope.ownProcesses`), whatever emulator it is handed:
/// a test model can then never resolve a gRPC port to, attach to or signal
/// an emulator someone else runs — not through a stub adb that names no AVD
/// (the single-VM fallback), not by a port scan, not by an AVD name.
struct AppEnvironment {
    /// The adb client; nil when there is no adb (an adb action then reports
    /// `AdbError.adbNotFound`, while `refresh()` treats it as a soft state:
    /// no alert, the toolbar's adb warning and the guided setup). `live()`
    /// hands an unresolved client instead of nil on a Mac without adb, so the
    /// setup can bring adb in without a relaunch (`AdbClient.resolve`).
    var adbClient: AdbClient?
    /// Which VMs on the Mac this environment's emulators see. Every
    /// emulator it hands out — `emulatorManager` and each one
    /// `emulatorManagerForPath` returns — sees exactly these.
    let emulatorProcesses: EmulatorProcessScope
    /// The emulator the model starts with. `AppModel.emulatorManager` is the
    /// current one: Settings' custom binary path swaps it through
    /// `emulatorManagerForPath`.
    let emulatorManager: EmulatorManager?
    /// The emulator for a custom binary path ("" = the default emulator).
    let emulatorManagerForPath: @MainActor (_ path: String) -> EmulatorManager?
    /// The store the preferences persist in.
    var defaults: UserDefaults
    /// The `DHP_*` development hooks.
    var launch: LaunchOptions
    /// The Mac pasteboard behind the copy and clipboard-sync features.
    var pasteboard: any MacPasteboard
    /// Whether the app is frontmost; the Mac pasteboard poll reads the
    /// pasteboard only then. Tests keep the default (always active).
    var isAppActive: @MainActor () -> Bool = { true }
    /// Asks where a saved file goes.
    var picker: any FileDestinationPicker
    /// Where each AVD's last reported display shapes are kept; nil keeps
    /// them for the process only.
    var displayShapeStore: DisplayShapeStore?
    /// The Apple simulator tools: the Xcode probe that yields the simctl and
    /// devicectl clients and the tier, and the device set. Nil
    /// means none: no simulators, tier T0, and no simctl ever run.
    var apple: AppleTooling?
    /// The CoreMediaIO + AVFoundation capture of a connected iPhone's screen
    /// and the Camera permission. The inert provider
    /// unless the environment was given one: only `live()` reaches hardware.
    var screenCapture: any PhysicalScreenCaptureProviding
    /// The app's own Bonjour browse for adb's wireless services, behind the
    /// adb-server recovery. Nil (every environment but `live()`) means no
    /// browse and no automatic adb restart.
    var adbServiceBrowser: (any AdbServiceBrowsing)?
    /// Where the saved pushes, deep links and launch options are kept; nil
    /// (every environment but `live()`) keeps them for the process only.
    var libraryDirectory: URL?

    /// An environment on exactly these tools. Without `emulatorManagerForPath`
    /// a custom binary path that names no executable falls back to
    /// `emulatorManager`, never to a located emulator. The emulators see
    /// `emulatorProcesses`: only this process's own VMs unless the caller
    /// says otherwise, as `live()` does.
    init(
        adbClient: AdbClient?,
        emulatorManager: EmulatorManager?,
        emulatorManagerForPath: (@MainActor (_ path: String) -> EmulatorManager?)? = nil,
        emulatorProcesses: EmulatorProcessScope = .ownProcesses,
        defaults: UserDefaults,
        launch: LaunchOptions,
        pasteboard: any MacPasteboard,
        picker: any FileDestinationPicker,
        displayShapeStore: DisplayShapeStore? = nil,
        screenCapture: any PhysicalScreenCaptureProviding = InertScreenCaptureProvider(),
        adbServiceBrowser: (any AdbServiceBrowsing)? = nil,
        apple: AppleTooling? = nil,
        libraryDirectory: URL? = nil
    ) {
        self.adbClient = adbClient
        self.emulatorProcesses = emulatorProcesses
        let scopedManager = emulatorManager?.scoped(to: emulatorProcesses)
        self.emulatorManager = scopedManager
        let managerForPath = emulatorManagerForPath ?? { path in
            Self.resolveEmulatorManager(path: path, processScope: emulatorProcesses, fallback: { scopedManager })
        }
        self.emulatorManagerForPath = { path in
            managerForPath(path)?.scoped(to: emulatorProcesses)
        }
        self.defaults = defaults
        self.launch = launch
        self.pasteboard = pasteboard
        self.picker = picker
        self.displayShapeStore = displayShapeStore
        self.apple = apple
        self.screenCapture = screenCapture
        self.adbServiceBrowser = adbServiceBrowser
        self.libraryDirectory = libraryDirectory
    }

    /// The app's environment: the adb and emulator found on this Mac (the
    /// emulator seeing every VM), this Mac's Xcode and the user's default
    /// simulator set, the standard defaults, the launch options from the
    /// process environment, the general pasteboard, the save panel and the
    /// display shapes in the user's caches.
    @MainActor
    static func live() -> AppEnvironment {
        let defaults = UserDefaults.standard
        // Until the user needs wireless debugging every adb this app runs
        // starts without mDNS discovery, so macOS does not ask for Local
        // Network access at launch (`AdbMdnsPolicy`).
        AdbMdnsPolicy.applyLaunchPolicy(
            localNetworkWanted: defaults.bool(forKey: AppPreferences.Keys.localNetworkInUse)
        )
        // The SDK folder the user located earlier, before any locator runs.
        AndroidSDKLocation.applyPreferredRoot(defaults.string(forKey: AppPreferences.Keys.androidSDKPath))
        let emulatorManagerForPath: @MainActor (String) -> EmulatorManager? = { path in
            resolveEmulatorManager(
                path: path,
                processScope: .everyVM,
                fallback: { EmulatorManager.locate(processScope: .everyVM) }
            )
        }
        var environment = AppEnvironment(
            adbClient: AdbClient.locate() ?? AdbClient.unresolved(),
            emulatorManager: emulatorManagerForPath(
                defaults.string(forKey: AppPreferences.Keys.emulatorBinaryPath) ?? ""
            ),
            emulatorManagerForPath: emulatorManagerForPath,
            emulatorProcesses: .everyVM,
            defaults: defaults,
            launch: .live(),
            pasteboard: SystemPasteboard(),
            picker: SavePanelPicker(),
            displayShapeStore: DisplayShapeStore(),
            screenCapture: AVFoundationScreenCaptureProvider(),
            adbServiceBrowser: NWAdbServiceBrowser(),
            apple: AppleTooling(
                probe: { await AppleToolchain.probe() },
                deviceSet: nil,
                devicesDirectory: SimulatorWatcher.defaultDevicesDirectory,
                logsDirectory: AppleTooling.userLogsDirectory,
                diagnosticReportsDirectory: ProcessInfo.processInfo.environment["DHP_DIAGNOSTIC_REPORTS_DIR"]
                    .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? SimulatorCrashReportScanner.userDiagnosticReportsDirectory,
                makeBridge: { toolchain in
                    toolchain.developerDirectory.map { LiveSimulatorBridge(developerDir: $0.path) }
                },
                bridgeVerdict: {
                    BridgeCompatibility.verdict(coreSimulatorVersion: BridgeCompatibility.installedCoreSimulatorVersion())
                },
                bridgeIsStale: {
                    BridgeCompatibility.isStale(
                        loadedVersion: LiveSimulatorBridge.loadedCoreSimulatorVersion,
                        installedVersion: BridgeCompatibility.installedCoreSimulatorVersion()
                    )
                },
                deviceKit: AppleDeviceKit(
                    root: ProcessInfo.processInfo.environment["DHP_DEVICEKIT_ROOT"]
                        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                        ?? AppleDeviceKit.defaultRoot
                )
            ),
            libraryDirectory: LibraryFile.applicationSupportFolder
        )
        environment.isAppActive = { NSApplication.shared.isActive }
        return environment
    }

    /// The emulator for Settings' custom binary path: that binary, seeing
    /// the VMs `processScope` names, when `path` names an executable;
    /// `fallback()` otherwise ("" = the default emulator).
    static func resolveEmulatorManager(
        path: String,
        processScope: EmulatorProcessScope,
        fallback: () -> EmulatorManager?
    ) -> EmulatorManager? {
        if !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return EmulatorManager(emulatorURL: url, processScope: processScope)
            }
        }
        return fallback()
    }
}

/// The `DHP_*` development hooks, parsed once at launch. The smoke-test
/// scripts and the parity harness set them; `none` turns every hook off.
struct LaunchOptions: Equatable, Sendable {
    /// Which devices `DHP_FORCE_PHYSICAL` routes through the scrcpy
    /// transport.
    enum ForcedPhysical: Equatable, Sendable {
        /// `DHP_FORCE_PHYSICAL=1`: every device.
        case everyDevice
        /// `DHP_FORCE_PHYSICAL=<serial>`: that device only.
        case serial(String)
    }

    /// `DHP_AUTOMIRROR=1`: `refresh()` mirrors the first online emulator.
    var autoMirror = false
    /// `DHP_MIRROR_SERIAL=<serial>`: the device auto-mirror takes
    /// instead, when it is online. Nil when unset or empty.
    var mirrorSerial: String?
    /// `DHP_FORCE_PHYSICAL=<serial|1>`: routes an emulator through the
    /// physical transport for live verification. Nil when unset, empty or
    /// whitespace.
    var forcePhysical: ForcedPhysical?
    /// `DHP_LOG_SERIAL=<serial>`: `refresh()` opens the logcat
    /// workspace on this device. Nil when unset or empty.
    var logSerial: String?
    /// `DHP_CONTROLS=1`: `refresh()` shows the Controls tab.
    var showControls = false
    /// `DHP_AUTOPAIR=1`: `refresh()` opens the Pair Device sheet.
    var autoPair = false
    /// `DHP_PIXEL_SKIN=<skin>`: `refresh()` opens the Pixel catalog
    /// screen for this skin. Nil when unset or empty.
    var pixelSkin: String?
    /// `DHP_CONTROLS_EXPAND_ALL=1`: every Controls group starts expanded.
    var expandAllControlsGroups = false
    /// `DHP_PERF_LOG=<path>`: where the mirror stats go for
    /// `Scripts/perf-check.sh`. Nil when unset or empty.
    var perfLogURL: URL?
    /// `DHP_APPEARANCE=dark`: forces the dark appearance.
    var forceDarkAppearance = false
    /// `DHP_FORCE_VECTOR_CHROME=1`: the live stage draws every Android
    /// device in the vector body, skinned AVDs included
    /// (`DeviceChromeResolver`), so the body can be checked live on any AVD.
    var forceVectorChrome = false
    /// `DHP_LAUNCH_INACTIVE=1`: the app does not activate itself at
    /// launch and puts its windows behind the active app's, for live checks
    /// driven through accessibility while someone uses the Mac.
    var launchInactive = false
    /// ⌘N/⌘T, the per-workspace `WindowGroup`, window tabbing and the
    /// sidebar's "Open in New Window"/"Open in New Tab". On
    /// by default (the row menus match Device Hub's); `DHP_MULTIWINDOW=0` turns it off, and the app
    /// is then the single window it was before step 8. `LaunchOptions.none`
    /// (the hermetic test options) keeps it off.
    var multiWindowEnabled = false
    /// `DHP_IPHONE_UDID=<hardware UDID>`: restricts the app's physical
    /// Apple devices to that one — it is the only one listed and it counts
    /// as enabled without the "Use This Device…" dialog, for agent-driven
    /// runs on a dedicated test iPhone. It does not turn "Show physical
    /// Apple devices" on: with that preference off the app still makes no
    /// `list devices` call. Nil when unset or blank; upper-cased.
    var iphoneUDID: String?

    /// Every hook off.
    static let none = LaunchOptions()

    /// Whether `DHP_FORCE_PHYSICAL` routes `serial` through the scrcpy
    /// transport.
    func forcesPhysicalTransport(serial: String) -> Bool {
        switch forcePhysical {
        case .everyDevice: true
        case .serial(let forced): forced == serial
        case nil: false
        }
    }
}

extension LaunchOptions {
    /// Parses the hooks from `environment` (the process environment in the
    /// app).
    init(environment: [String: String]) {
        func nonEmpty(_ key: String) -> String? {
            environment[key].flatMap { $0.isEmpty ? nil : $0 }
        }

        autoMirror = environment["DHP_AUTOMIRROR"] == "1"
        mirrorSerial = nonEmpty("DHP_MIRROR_SERIAL")
        let force = environment["DHP_FORCE_PHYSICAL"]?
            .trimmingCharacters(in: .whitespaces)
        if let force, !force.isEmpty {
            forcePhysical = force == "1" ? .everyDevice : .serial(force)
        }
        logSerial = nonEmpty("DHP_LOG_SERIAL")
        showControls = environment["DHP_CONTROLS"] == "1"
        autoPair = environment["DHP_AUTOPAIR"] == "1"
        pixelSkin = nonEmpty("DHP_PIXEL_SKIN")
        expandAllControlsGroups = environment["DHP_CONTROLS_EXPAND_ALL"] == "1"
        perfLogURL = nonEmpty("DHP_PERF_LOG").map { URL(fileURLWithPath: $0) }
        forceDarkAppearance = environment["DHP_APPEARANCE"] == "dark"
        forceVectorChrome = environment["DHP_FORCE_VECTOR_CHROME"] == "1"
        launchInactive = environment["DHP_LAUNCH_INACTIVE"] == "1"
        multiWindowEnabled = environment["DHP_MULTIWINDOW"] != "0"
        iphoneUDID = environment["DHP_IPHONE_UDID"]
            .map(PhysicalDeviceOptIn.normalize)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The hooks this process was launched with.
    static func live() -> LaunchOptions {
        LaunchOptions(environment: ProcessInfo.processInfo.environment)
    }
}

/// The Mac pasteboard as the app uses it: plain text both ways and a PNG
/// out. Main-actor because AppKit's pasteboard is used from the UI.
@MainActor
protocol MacPasteboard: AnyObject {
    /// The pasteboard's plain text, if it holds any.
    func string() -> String?
    /// Replaces the pasteboard's contents with `text`.
    func setString(_ text: String)
    /// Replaces the pasteboard's contents with a PNG image.
    func setPNG(_ png: Data)
}

/// `NSPasteboard.general`.
@MainActor
final class SystemPasteboard: MacPasteboard {
    func string() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func setString(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func setPNG(_ png: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }
}

/// Asks the user where a file goes.
@MainActor
protocol FileDestinationPicker {
    /// Where a file goes when nobody can be asked — a recording that ended
    /// without the user (a disconnect, a fatal stream error, quit) — unless
    /// its owner names a directory of its own; nil keeps it where it is.
    var autoSaveDirectory: URL? { get }

    /// The destination chosen for a file named `suggestedName`, starting in
    /// `directory` when there is one; nil when the user cancelled.
    func chooseDestination(suggestedName: String, directory: URL?) -> URL?

    /// A folder chosen to save a bundle of files in (a sysdiagnose, a bug
    /// report), starting in `directory` when there is one; nil when the user
    /// cancelled or nobody can be asked.
    func chooseFolder(message: String, directory: URL?) -> URL?

    /// The same with the panel's button titled `prompt` (Device Hub's
    /// sysdiagnose panel says "Select").
    func chooseFolder(message: String, prompt: String, directory: URL?) -> URL?

    /// The folder the pill's screenshot button saves in without asking
    /// (Device Hub's way): the Mac's screenshot folder, else the Desktop.
    /// Where nobody can be asked (`autoSaveDirectory` nil, as in tests) the
    /// temporary directory, never the user's Desktop.
    var screenshotDirectory: URL { get }
}

extension FileDestinationPicker {
    func chooseFolder(message: String, directory: URL?) -> URL? {
        chooseFolder(message: message, prompt: "Choose", directory: directory)
    }

    func chooseFolder(message: String, prompt: String, directory: URL?) -> URL? { nil }

    var screenshotDirectory: URL {
        autoSaveDirectory ?? FileManager.default.temporaryDirectory
    }
}

/// The modal save panel.
@MainActor
struct SavePanelPicker: FileDestinationPicker {
    /// The Desktop, where the save panel starts too.
    var autoSaveDirectory: URL? {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    }

    var screenshotDirectory: URL { ScreenshotFile.defaultDirectory() }

    func chooseFolder(message: String, prompt: String, directory: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let directory {
            panel.directoryURL = directory
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func chooseDestination(suggestedName: String, directory: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        if let directory {
            panel.directoryURL = directory
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
