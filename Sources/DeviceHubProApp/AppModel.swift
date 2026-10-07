import Accelerate
import AppKit
import CoreMedia
import CoreVideo
import Darwin
import Observation
import SwiftUI
import UniformTypeIdentifiers
import DeviceHubProKit

/// How emulator audio reaches the user.
///
/// `enabled` lets the emulator play through the host (audio can sound distorted
/// on some macOS output devices). `inApp` streams the emulator audio over gRPC
/// and plays it in Device Hub Pro; emulators started by the app are launched muted so
/// the sound does not double up.
enum EmulatorAudioMode: String, CaseIterable, Identifiable {
    case enabled
    case inApp
    case disabled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .enabled: return "Emulator"
        case .inApp: return "In-app"
        case .disabled: return "Disabled"
        }
    }

    /// Whether the emulator itself should keep its host audio on.
    var emulatorAudioEnabled: Bool { self == .enabled }
}

/// Direction of a 90° display rotation, like Device Manager's two rotate
/// buttons.
enum RotationDirection {
    case left
    case right
}

@MainActor
@Observable
final class AppModel {
    let adbClient: AdbClient?
    /// Keeps the selected emulator's own soft keyboard showing while Keyboard
    /// Capture is off (`AppModel+SoftKeyboard.swift`); nil without adb.
    @ObservationIgnored let softKeyboard: SoftKeyboardLease?
    /// Whether the one-time keyboard tip shows on the Capture Keyboard toggle.
    var softKeyboardHintVisible = false
    private(set) var emulatorManager: EmulatorManager?
    /// Resolves Settings' custom emulator binary path (`setEmulatorBinaryPath`).
    private let emulatorManagerForPath: @MainActor (_ path: String) -> EmulatorManager?
    /// The `DHP_*` development hooks the model was built with.
    let launchOptions: LaunchOptions

    /// The adb rows with the ghost, Device Info, the consoles' AVD names and
    /// the hot-plug lifecycle. Called directly (no forwarders).
    let inventory: DeviceInventory
    /// The installed AVDs, the skin catalog, AVD creation and the AVD file
    /// actions. Called directly (no forwarders).
    let catalog: AvdCatalogController
    /// The emulators being created in the background (their system image
    /// downloads included), shown in the sidebar and the activity popover.
    let avdCreation = AvdCreationQueue()
    /// The simulators of the user's default set, the Apple tooling tier and
    /// the Show Unused filter. Called directly (no forwarders).
    let simulators: SimulatorInventory
    /// Running simulators' and emulators' memory for the sidebar rows.
    let deviceMemory = DeviceMemoryMonitor()
    /// The physical iPhones and iPads behind "Show physical Apple devices":
    /// off by default and, off, never a `devicectl list devices` call; each
    /// device stays "Not enabled" until the user chooses it.
    /// Called directly (no forwarders).
    let physicalInventory: ApplePhysicalInventory
    /// An enabled physical device's Info card, screenshot and recording.
    /// Called directly (no forwarders).
    let physicalDevices: ApplePhysicalController
    /// The physical rows' right-click actions (Restart, Rename…, sysdiagnose, Unpair…).
    let physicalActions: PhysicalDeviceActions
    /// Boot, Shut Down, Restart, Erase, Rename, Delete and Clone for
    /// simulators, their ready signal and the operations in flight. Called
    /// directly (no forwarders).
    let simulatorLifecycle: SimulatorLifecycleController
    /// A simulator's live stage: its canvas (the bridge or view-only), the
    /// fallback between them, and its Home, Lock, rotation and shake.
    /// Called directly (no forwarders).
    var simulatorCanvas: SimulatorCanvasController { workspace.simulatorCanvas }
    /// A simulator's apps in the inspector and what is dropped on its stage
    /// (installs, media, root certificates, links). Called directly (no
    /// forwarders).
    var simulatorApps: SimulatorAppsController { workspace.simulatorApps }
    /// The crash reports of the simulator the Diagnostics tab shows. Called
    /// directly (no forwarders).
    var simulatorCrashReports: SimulatorCrashReportsController { workspace.simulatorCrashReports }
    /// A simulator's Controls panel: its settings through devicectl and
    /// simctl, and what Device Hub Pro keeps for it (location, status bar, boot
    /// time zone). Called directly (no forwarders).
    var appleControls: AppleControlsController { workspace.appleControls }
    /// What Device Hub Pro keeps per simulator (location, status bar, respring,
    /// changes in flight, boot zone), shared by every Controls panel.
    let appleDeviceMemory: AppleDeviceMemory
    /// What the simulator canvas learned per simulator in its boot (the
    /// live canvas's failure, the dtuhidd flag, the orientation), shared by
    /// every stage.
    let simulatorCanvasMemory: SimulatorCanvasMemory
    /// Each AVD's and phone model's last reported display shapes, shared by
    /// every mirror and the AVD catalog.
    let displayShapes: DisplayShapeLibrary
    /// The inspector, sidebar, sheet, toggle and zoom state (the
    /// workspace's; the views and menus read it there).
    var window: WindowState { workspace.window }
    /// The device shown in the center stage (`DeviceWorkspace`, which
    /// cancels a stale attach and keeps the multi-selection following it).
    var deviceSelection: DeviceSelection? {
        get { workspace.deviceSelection }
        set { workspace.deviceSelection = newValue }
    }
    /// The sidebar's multi-selection: the rows ⌘-click,
    /// ⇧-click and Select All gathered, `deviceSelection` among them as the
    /// primary the stage shows. Apply to Selected and Screenshot All
    /// Selected act on its rows (`multiDevice`).
    var multiSelection: SidebarMultiSelection {
        get { workspace.multiSelection }
        set { workspace.multiSelection = newValue }
    }
    /// The window's device, its session and the per-device features (one
    /// today); the per-device properties above and below read it.
    let workspace: DeviceWorkspace
    /// The app-global tools and lists the workspace reads.
    let services: AppServices
    /// The app's workspaces (one today, `workspace`): routes the app-wide
    /// actions that concern a device to the workspace that owns it.
    let registry: WorkspaceRegistry
    /// Apply to Selected and Screenshot All Selected over the multi-selection.
    let multiDevice: MultiDeviceController
    /// The settings profiles: the built-ins and the user's own.
    let settingsProfiles: SettingsProfileStore
    /// The saved pushes, deep links and launch options (Application Support).
    let libraries: SavedLibraries

    /// Hooks every workspace shares, wired for the first one at init and for
    /// each later window's workspace as it is created: a push sent from any
    /// window lands in the one push history.
    func wireSharedHooks(_ workspace: DeviceWorkspace) {
        workspace.appleControls.onPushSent = { [libraries] sent in
            libraries.recordSentPush(bundleIdentifier: sent.bundleIdentifier, payload: sent.payload)
        }
    }
    /// The AVD behind the active mirror; nil for a physical device, before
    /// the lookup answers, and once the mirror is torn down.
    private(set) var activeAvdName: String? {
        get { context.avdName }
        set { context.avdName = newValue }
    }

    /// The session, its attach state, the stats poll with the stream's
    /// health, the stage's view state and in-app audio (the workspace's; the
    /// views and menus read it there). The session hubs call it in their
    /// fixed order.
    var mirror: MirrorController { workspace.mirror }
    /// The app-global status line, error alert and busy count. A flow that
    /// acts on a device's own workspace (`startAndMirror`, `stopEmulator`,
    /// `powerOnDevice`) writes through `deviceStatus()` instead, never
    /// through this one. Called directly (no forwarders); `isBusy` below
    /// also covers every workspace's own count.
    let status = StatusCenter()
    /// The Pair Device sheet's `adb pair`/`adb connect`. Called directly
    /// (no forwarders).
    let pairing: WirelessPairingController
    /// Restarts the adb server from this app when it was started without the
    /// Local Network permission (`AdbServerRecovery`). Called directly.
    let adbRecovery: AdbServerRecovery

    /// The Apps tab and APK install (the workspace's; the views read it
    /// there).
    var apps: AppsController { workspace.apps }

    /// The persisted settings, on the environment's defaults. The views read
    /// them here directly; the setX methods with side effects write through
    /// them.
    let preferences: AppPreferences
    /// The guided "Set up Android tools" flow (install or locate the SDK).
    let androidSetup: AndroidSetupModel
    /// The Location row: presets, the sheet and its draft (`DeviceWorkspace`;
    /// the views read it there).
    var location: LocationController { workspace.location }

    /// The emulators' gRPC ports: the recorded ones and the resolution of a
    /// port not recorded yet.
    let grpcPorts: GrpcPortService
    /// `grpcPorts` under the cache's old name, so the call sites that record
    /// and forget ports keep their text.
    private var grpcCache: GrpcPortService { grpcPorts }
    private var lifecycleGeneration: Int { context.sessionGeneration }
    /// The mirrored device: serial, emulator port, AVD and the session
    /// generations. The per-device features share this one instance; only
    /// this model writes it.
    var context: ActiveDeviceContext { workspace.context }
    /// The mirrored device's adb serial; nil for an Apple device.
    private var activeSerial: String? { context.serial }
    /// Screenshots, the annotation editor and the diagnostics bundle (the
    /// workspace's; the views and menus read it there).
    var capture: CaptureController { workspace.capture }

    /// Dev hook: `DHP_CONTROLS_EXPAND_ALL=1` starts every Controls group
    /// expanded so the parity harness can measure rows without driving each
    /// disclosure. `DHGroup` persists the harness state under a separate key.
    let expandAllControlsGroups: Bool

    /// Builds the model on `environment`: the app passes
    /// `AppEnvironment.live()`, tests a hermetic one.
    init(environment: AppEnvironment) {
        self.adbClient = environment.adbClient
        self.softKeyboard = environment.adbClient.map { SoftKeyboardLease(adb: $0, store: .userDefaults(environment.defaults)) }
        self.adbIsAvailable = environment.adbClient?.isResolved ?? false
        self.emulatorManager = environment.emulatorManager
        self.emulatorManagerForPath = environment.emulatorManagerForPath
        self.launchOptions = environment.launch
        self.expandAllControlsGroups = environment.launch.expandAllControlsGroups
        let status = self.status
        let displayShapes = DisplayShapeLibrary(store: environment.displayShapeStore)
        self.displayShapes = displayShapes
        // The first workspace's context: the hot-plug lifecycle reads the
        // mirrored device through it (one lifecycle until it moves to the
        // workspaces).
        let context = ActiveDeviceContext()
        let preferences = AppPreferences(defaults: environment.defaults)
        self.preferences = preferences
        self.androidSetup = AndroidSetupModel(preferences: preferences)
        let appleDeviceMemory = AppleDeviceMemory(preferences: preferences)
        self.appleDeviceMemory = appleDeviceMemory
        let simulatorCanvasMemory = SimulatorCanvasMemory()
        self.simulatorCanvasMemory = simulatorCanvasMemory
        let grpcPorts = GrpcPortService(adbClient: environment.adbClient)
        self.grpcPorts = grpcPorts
        let inventory = DeviceInventory(
            adbClient: environment.adbClient,
            context: context,
            status: status,
            grpcPorts: grpcPorts
        )
        self.inventory = inventory
        self.pairing = WirelessPairingController(adbClient: environment.adbClient, status: status)
        self.adbRecovery = AdbServerRecovery(
            probes: environment.adbClient.map(AdbServerRecovery.Probes.live),
            browser: environment.adbServiceBrowser,
            status: status,
            localNetworkWanted: preferences.localNetworkInUse
        )
        let catalog = AvdCatalogController(status: status, displayShapes: displayShapes)
        self.catalog = catalog
        let simulators = SimulatorInventory(apple: environment.apple, preferences: preferences)
        self.simulators = simulators
        let physicalInventory = ApplePhysicalInventory(
            preferences: preferences,
            iphoneUDID: environment.launch.iphoneUDID,
            launchInactive: environment.launch.launchInactive,
            toolchain: { await simulators.probedToolchain() }
        )
        self.physicalInventory = physicalInventory
        let physicalDevices = ApplePhysicalController(inventory: physicalInventory, picker: environment.picker)
        self.physicalDevices = physicalDevices
        self.physicalActions = PhysicalDeviceActions(
            inventory: physicalInventory,
            status: status,
            picker: environment.picker,
            adbClient: environment.adbClient,
            defaults: environment.defaults
        )
        self.simulatorLifecycle = SimulatorLifecycleController(status: status)
        self.boot = EmulatorBootController(adbClient: environment.adbClient, status: status, preferences: preferences)
        let recordingFinalizer = RecordingFinalizer(status: status, picker: environment.picker)
        self.recordingFinalizer = recordingFinalizer
        recordingFinalizer.preferredDirectory = { [preferences] in preferences.captureFolder }
        self.multiDevice = MultiDeviceController(status: status, picker: environment.picker)
        multiDevice.captureFolder = { [preferences] in preferences.captureFolder }
        self.settingsProfiles = SettingsProfileStore(defaults: environment.defaults)
        let libraries = SavedLibraries(directory: environment.libraryDirectory)
        self.libraries = libraries
        let services = AppServices(
            adbClient: environment.adbClient,
            launchOptions: environment.launch,
            preferences: preferences,
            status: status,
            inventory: inventory,
            catalog: catalog,
            grpcPorts: grpcPorts,
            simulators: simulators,
            physicalInventory: physicalInventory,
            physicalDevices: physicalDevices,
            simulatorLifecycle: simulatorLifecycle,
            boot: boot,
            environment: environment,
            displayShapes: displayShapes,
            appleDeviceMemory: appleDeviceMemory,
            simulatorCanvasMemory: simulatorCanvasMemory,
            recordingFinalizer: recordingFinalizer
        )
        self.services = services
        let workspace = DeviceWorkspace(services: services, context: context)
        self.workspace = workspace
        let registry = WorkspaceRegistry()
        registry.register(workspace)
        self.registry = registry
        wireSharedHooks(workspace)
        // The one Mac-pasteboard poll for every workspace's clipboard
        // auto-sync: started once here rather than per
        // workspace, so a later window never starts a second poll.
        services.clipboardPoll.start(registry: registry)

        // Background emulator creation: the create sheet and the Pixel page
        // hand their requests to the queue; it creates through the catalog
        // and starts through this model.
        avdCreation.actions = AvdCreationQueue.Actions(
            download: { sdk, package in await sdk.startDownload(package: package) },
            createAvd: { [catalog] request in
                await catalog.createAvd(
                    name: request.name,
                    deviceId: request.deviceID,
                    systemImage: request.image.package,
                    displayName: request.displayName
                )
            },
            start: { [weak self] name in await self?.startAndMirror(avd: name) },
            isCreatingElsewhere: { [catalog] in catalog.isCreatingAvd }
        )

        // Every per-device feature's own hooks — including location,
        // capture and mirror's — are wired by the workspace itself
        // (`DeviceWorkspace.wireAppHooks`), so a second workspace built via
        // `DeviceWorkspace.init(services:context:)` is fully wired the same
        // way without this model's help.
        // `workspace.selectionChanged` is wired by the workspace itself
        // (`DeviceWorkspace.wireLifecycle`), so every workspace — not just
        // this model's own — reaches its own coordinator on a selection
        // change.
        wireAvdCatalog()
        wireEmulatorBoot()
        wireGrpcPorts()
        wireInventory()
        wireSimulators()
        wirePhysicalDevices()
        // Every workspace's log is closed when nothing of its window shows
        // it, the first one's and the ones registered later.
        watchLogAudience(of: workspace)
        registry.onRegister = { [weak self] member in self?.watchLogAudience(of: member) }
        // The soft keyboard follows the focused window's stage.
        registry.onFocusChange = { [weak self] in self?.syncSoftKeyboard() }
        watchSoftKeyboard()
        wireMultiDevice()
        observeApplicationTermination()
        pairing.refresh = { [weak self] in await self?.refreshAndroid() }
        wireAdbRecovery()
        androidSetup.onToolsAvailable = { [weak self] in await self?.adoptAndroidTools() }
    }

    /// The first wireless need (the Pair Nearby Device sheet's Android tile,
    /// a wireless device that is already connected): starts what was held
    /// back so macOS would not ask for Local Network access at launch. The
    /// Bonjour browse starts, adb is started with mDNS discovery from now on
    /// (`AdbMdnsPolicy`), and an adb server this app started without it is
    /// restarted once, unless a recording or an install is running. The
    /// need is remembered, so the next launch starts everything at once.
    func wantLocalNetwork() {
        preferences.setLocalNetworkInUse(true)
        let wasDisabled = AdbMdnsPolicy.enable()
        adbRecovery.wantLocalNetwork()
        guard wasDisabled, localNetworkTask == nil else { return }
        localNetworkTask = Task { [weak self] in
            await self?.restartAdbIfDiscoveryIsOff()
            self?.localNetworkTask = nil
        }
    }

    /// Waits for the restart `wantLocalNetwork()` started (the QR pairing
    /// must not ask a server that is about to go away).
    func waitForLocalNetwork() async {
        await localNetworkTask?.value
    }

    private func restartAdbIfDiscoveryIsOff() async {
        guard let adbClient, adbClient.isResolved, !isAdbRestartUnsafe,
              await adbClient.mdnsDiscoveryDisabled()
        else { return }
        do {
            try await adbClient.restartServer()
        } catch {
            // The next adb call starts a server of its own, with mDNS now.
            return
        }
        await refreshAndroid()
    }

    /// No recording or install may run when adb restarts: any workspace's
    /// screen recording or APK install, or a batch action. Nor a phone's
    /// mirror: its scrcpy stream rides adb's forward, which a restart drops.
    var isAdbRestartUnsafe: Bool {
        multiDevice.isRunning
            || registry.workspaces.contains {
                $0.media.isRecording || $0.apps.isInstallingAPK
                    || $0.mirror.session is any PhysicalSessionControlling
            }
    }

    /// The online row standing for the same phone as `serial` when `serial`
    /// itself is not online: the row lists it among its other transports, or
    /// `serial` is the phone's own serialno (a USB serial). The alias map
    /// covers the snapshot a transport moved in; this catches a move the
    /// selection missed.
    nonisolated static func liveTransport(of serial: String, in devices: [AndroidDevice]) -> String? {
        guard !devices.contains(where: { $0.serial == serial && $0.isOnline }) else { return nil }
        return devices.first { row in
            row.isOnline && row.serial != serial
                && (row.alternateSerials.contains(serial) || row.hardwareSerial == serial)
        }?.serial
    }

    /// Points the adb-server recovery at this model and runs it while the app
    /// is the active one.
    private func wireAdbRecovery() {
        adbRecovery.isBusy = { [weak self] in self?.isAdbRestartUnsafe ?? true }
        adbRecovery.refresh = { [weak self] in await self?.refreshAndroid() }
        pairing.onConnectFailure = { [weak self] address, message in
            self?.adbRecovery.noteConnectFailure(address: address, message: message)
        }
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.adbRecovery.setActive(true) }
            // Back from Xcode after its first launch: iOS comes up at once.
            Task { @MainActor in
                guard let self, await self.simulators.recheckSetupIfPending() else { return }
                await self.refresh()
            }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.adbRecovery.setActive(false) }
        }
        if NSApp?.isActive == true { adbRecovery.setActive(true) }
    }

    /// How often the Xcode hint looks again while it is on screen.
    static let xcodePollInterval: Duration = .seconds(15)

    /// Reads Xcode's setup again now ("Check Again", and the poll): when it
    /// turned usable the lists refresh. Reads files only.
    func checkXcodeAgain() async {
        guard await simulators.recheckSetupIfPending() else { return }
        await refresh()
    }

    /// Looks again every `interval` while the Xcode hint shows, so opening
    /// Xcode, accepting its license or finishing its install is noticed
    /// without leaving the app. Ends when the hint is gone (usable Xcode) or
    /// the calling task is cancelled (the view left).
    func pollXcodeSetup(every interval: Duration = AppModel.xcodePollInterval) async {
        while !Task.isCancelled, simulators.tooling.isProbed, simulators.tooling.guidance != nil {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            await checkXcodeAgain()
        }
    }

    /// A model on exactly these tools, for tests: nil means none — never an
    /// adb or SDK emulator located on the Mac — and no launch options. Its
    /// settings persist in `defaults`, never in the process's standard
    /// defaults. The app builds its model with `AppEnvironment.live()`.
    convenience init(
        adbClient: AdbClient? = nil,
        emulatorManager: EmulatorManager? = nil,
        defaults: UserDefaults
    ) {
        self.init(environment: AppEnvironment(
            adbClient: adbClient,
            emulatorManager: emulatorManager,
            defaults: defaults,
            launch: .none,
            pasteboard: SystemPasteboard(),
            picker: SavePanelPicker()
        ))
    }

    /// Quit hygiene (S1): `NSApplication` posts `willTerminate` before the
    /// process exits — the last moment the `track-devices` child can be
    /// stopped. Delivery is on the main queue (the pattern `DeviceHubProApp` uses
    /// for its toolbar observers), so the callback enters the main actor with
    /// `assumeIsolated`. The observer is not torn down: the model is app
    /// lifetime and the `[weak self]` capture makes a discarded model a
    /// no-op, exactly like those toolbar observers.
    ///
    /// The full, awaited cleanup is `prepareForTermination()`, run from the
    /// app delegate's `applicationShouldTerminate`; this synchronous backstop
    /// covers a termination that skipped it.
    private func observeApplicationTermination() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.terminationBackstop()
            }
        }
    }

    // MARK: - Stage

    /// Closes a simulator's log as soon as nothing shows it: it streams
    /// only while the selected simulator is ready and the inspector shows
    /// the Diagnostics tab. Another selection, the simulator stopping or
    /// restarting, another tab or the inspector hidden closes it
    /// (`LogcatController.closeSimulatorLog`); the tab opens it again when it
    /// shows the ready simulator once more. Re-armed after every change it
    /// sees.
    private func watchLogAudience(of member: DeviceWorkspace) {
        let (unseen, physicalUnseen) = withObservationTracking {
            (simulatorLogIsUnseen(in: member), physicalLogIsUnseen(in: member))
        } onChange: { [weak self, weak member] in
            // Fires before the new value is stored; judge on the next turn.
            Task { @MainActor in
                guard let self, let member, self.registry.workspace(for: member.id) != nil else { return }
                self.watchLogAudience(of: member)
            }
        }
        if unseen {
            member.logcat.closeSimulatorLog()
        }
        if physicalUnseen {
            member.logcat.closePhysicalLog()
        }
    }

    /// Whether a physical iPhone's console runs with nothing showing it: the
    /// app session it holds then ends (Log focus left, another selection).
    private func physicalLogIsUnseen(in member: DeviceWorkspace) -> Bool {
        guard let udid = member.logcat.physicalLogUDID else { return false }
        return !(member.window.isLogFocus && member.deviceSelection == .physicalApple(udid))
    }

    /// Whether a simulator's log streams with nothing showing it.
    private func simulatorLogIsUnseen(in member: DeviceWorkspace) -> Bool {
        guard let udid = member.logcat.simulatorLogUDID else { return false }
        // The log window (Device ▸ Show Logs…) shows it whatever the
        // inspector does.
        let inLogWindow = member.window.isLogsSheetPresented
        let inInspector = member.window.showInspector && member.window.inspectorTab == .diagnostics
        let shown = (inLogWindow || inInspector || member.window.isLogFocus)
            && member.deviceSelection == .simulator(udid)
            && simulatorLifecycle.isReady(udid)
        return !shown
    }

    /// Serial for the inspector Info panel: the live device if any, else the
    /// selected AVD's serial when it is known (`SelectionRouting`).
    var inspectorSerial: String? {
        SelectionRouting.inspectorSerial(for: deviceSelection, in: liveRoutingSnapshot)
    }

    /// Serial shown live in the stage for the current selection, if any.
    /// Single source of truth for stage routing and toolbar state
    /// (`SelectionRouting`).
    var liveSelectionSerial: String? {
        SelectionRouting.liveSelectionSerial(for: deviceSelection, in: liveRoutingSnapshot)
    }

    /// What the stage's routing reads (`SelectionRouting.Snapshot`) for the
    /// members views read on every change: the device rows, the AVD cards
    /// and the in-app starts; the AVD names, the skin catalog and the
    /// simulators are left out (none of the three members routes a
    /// simulator to a serial). It reads all three whatever the selection, so a view reading
    /// `liveSelectionSerial`, `inspectorSerial` or `avdIsBooting(_:)`
    /// observes all three. The per-case code before it read only what its
    /// case reached (a phone's selection only the rows, no selection
    /// nothing), so such a view now also re-evaluates on the AVD cards'
    /// running-state pass after a hot-plug snapshot and on an in-app start
    /// or end: list writes, never per frame.
    var liveRoutingSnapshot: SelectionRouting.Snapshot {
        SelectionRouting.Snapshot(devices: inventory.devices, avdCards: catalog.avdCards, startingAvdNames: boot.startingAvdNames)
    }

    /// Boots AVDs for Start and Power On and keeps the bookkeeping of the
    /// starts in flight. Called directly (no forwarders); a test that
    /// shortens the boot clock also sets `apps.bootTiming`.
    let boot: EmulatorBootController

    /// Whether `name` is starting: an in-app start/restart is in flight, or
    /// its emulator process is up while adb has not reported it online yet.
    func avdIsBooting(_ name: String) -> Bool {
        SelectionRouting.avdIsBooting(name, in: liveRoutingSnapshot)
    }

    // MARK: - Emulator binary

    /// The emulator ≤36.x does not support the shared-memory video transport;
    /// pointing the app at the canary build (37.x) enables MMAP automatically.
    func setEmulatorBinaryPath(_ path: String) {
        preferences.setEmulatorBinaryPath(path)
        emulatorManager = emulatorManagerForPath(path)
    }

    var activeEmulatorDescription: String {
        guard let url = emulatorManager?.emulatorURL else { return "not found" }
        return url.path
    }

    func setEmulatorAudioMode(_ mode: EmulatorAudioMode) {
        preferences.setEmulatorAudioMode(mode)

        // Every workspace's emulator session follows the setting; with
        // multiple windows enabled, `applyAudioPolicy` still plays only the
        // focused one's.
        for workspace in registry.workspaces {
            workspace.applyAudioPolicy()
        }
    }

    @ObservationIgnored private var localNetworkTask: Task<Void, Never>?

    /// Whether adb has been found. Stored (not derived from `adbClient`) so
    /// the views that show the setup card update when the guided install or
    /// "Locate SDK…" brings the tools in (`adoptAndroidTools`).
    private(set) var adbIsAvailable: Bool

    /// The last device list failed because adb's server would not start, even
    /// after one restart. Shown inline in the sidebar (never an alert); the
    /// next successful list clears it.
    private(set) var adbServerProblem = false

    /// Picks up Android tools that appeared while the app runs (the guided
    /// install finished, or the user located an SDK): re-runs the locator
    /// into the existing adb client (every controller holds that one
    /// object), re-resolves the emulator, and starts the polling and the
    /// refresh a launch with adb would have run. No relaunch.
    func adoptAndroidTools() async {
        if let adbClient, !adbClient.isResolved, let url = AdbBinaryLocator.locate() {
            adbClient.resolve(url)
        }
        guard adbClient?.isResolved == true else { return }
        if emulatorManager == nil {
            emulatorManager = emulatorManagerForPath(preferences.emulatorBinaryPath)
        }
        adbIsAvailable = true
        catalog.avdCreateStatus = .unknown
        catalog.resetMinApiTable()
        await refreshAndroid()
    }

    // Private shims for `inventory`'s real rows and consoles' AVD names, so
    // this file's call sites keep their text.

    private var realDevices: [AndroidDevice] { inventory.realDevices }

    private func setRealDevices(_ remote: [AndroidDevice]) {
        inventory.setRealDevices(remote)
    }

    private var avdNamesBySerial: [String: (transportID: String?, avd: String)] {
        get { inventory.avdNamesBySerial }
        set { inventory.avdNamesBySerial = newValue }
    }

    private func avdName(of device: AndroidDevice) async -> String? {
        await inventory.avdName(of: device)
    }

    /// The waiting panel's Reconnect button (S4): re-arms the episode and
    /// resumes at once. Being user initiated it clears the auto marker, so a
    /// failure during this attempt still reaches the alert surface.
    func requestReconnect(serial: String) {
        // The waiting panel that shows this button is this model's own
        // workspace's (`model.workspace.reconnect`), so its click reaches that
        // workspace's own coordinator directly — structural, not a search.
        // `lifecycleIfRunning` is nil unless the watcher is running,
        // matching every other lifecycle entry point.
        workspace.lifecycleIfRunning?.noteReconnectRequested(serial: serial)
    }

    /// The auto-resume hook (spec §5.2; `DeviceWorkspace.lifecycleResume`).
    func lifecycleResume(serial: String) async {
        await workspace.lifecycleResume(serial: serial)
    }

    /// Refreshes every platform's devices on its own tools: the launch
    /// refresh and the Refresh commands. A missing tool is a soft state of
    /// its platform, never an alert: a Mac without adb (one with only
    /// Xcode) must still get through it. Android's shows as the toolbar's
    /// adb warning (`adbIsAvailable`), whose tooltip says how to install
    /// adb; Apple's is the simulators' tier T0 (`simulators.tooling`).
    /// Android goes first, as it always did. A simulator that reads as not
    /// responding is followed to ready again.
    func refresh() async {
        await refreshAndroid()
        await simulators.refresh()
        simulatorLifecycle.refollowUnresponsive()
        // Starts the physical-device poll when "Show physical Apple devices"
        // is on (idempotent); with it off nothing runs.
        physicalInventory.applyPreference()
        if physicalInventory.isShowing {
            await physicalInventory.refreshNow()
        }
    }

    /// The Android half of `refresh()`: the hot-plug watcher, adb's
    /// devices, the AVDs, the gallery, Device Info, the selection fix-up
    /// and the smoke-test hooks. Without adb it does nothing (the watcher
    /// needs adb too).
    ///
    /// The Android flows that end in a refresh (Stop, pairing, an AVD's
    /// create, delete or rename) call this half alone, often inside
    /// the busy scope or a spinner: the simulator half waits for the Xcode
    /// probe (`xcodebuild`, up to 15 s) on its first run and for simctl (up
    /// to 30 s a call) after, which has nothing to do with them.
    func refreshAndroid() async {
        inventory.startDeviceLifecycle()
        guard adbIsAvailable, adbClient != nil else { return }
        do {
            let remote = try await inventory.listGroupedDevices()
            for device in remote {
                inventory.lastKnownDetails[device.serial] = device
            }
            adbServerProblem = false
            setRealDevices(remote)
            if remote.contains(where: { AdbClient.isWirelessSerial($0.serial) }) {
                // A wireless device is connected: the local network is in use.
                wantLocalNetwork()
            }
            inventory.pruneDeviceInfos(for: remote)
            inventory.pruneAvdNames(for: remote)
        } catch let error as AdbError where error.isServerStartFailure {
            // The adb server would not start (already retried once after a
            // restart): not a device error, so no alert; the sidebar says so
            // with a Try Again.
            adbServerProblem = true
        } catch {
            if !error.isCancellation { status.errorMessage = "\(error)" }
        }
        if let emulatorManager {
            do {
                catalog.avds = try await emulatorManager.listAvds()
                catalog.avdsLoaded = true
            } catch {
                // Keep the last list: an empty one would also drop the AVD
                // selection in `ensureDeviceSelection` below.
                if !error.isCancellation { status.errorMessage = "Could not list the AVDs: \(error)" }
            }
        }
        await refreshGallery()
        await inventory.loadInfos(for: inventory.devices)
        ensureDeviceSelection()

        // Development conveniences for smoke testing the UI:
        //   DHP_AUTOMIRROR=1      mirror the first online emulator
        //   DHP_MIRROR_SERIAL=<serial>  mirror this device instead
        //   DHP_FORCE_PHYSICAL=<serial|1>  use the scrcpy transport
        //   DHP_LOG_SERIAL=<serial>  open the logcat workspace
        //   DHP_AUTOPAIR=1         open the Pair Device sheet
        await applyLaunchHooksOnce()
    }

    /// Whether `applyLaunchHooksOnce()` ran: the launch-time smoke hooks act
    /// on the first window once per launch, never again for a new tab.
    private var launchHooksApplied = false
    /// Whether the first window's initial refresh started.
    private var initialRefreshStarted = false

    /// What a window's first appearance triggers: the first window runs the
    /// app-wide refresh; a later tab or window finds the lists loaded (the
    /// watchers keep them current) and only fixes up its own selection.
    func refreshForNewWindow() async {
        if initialRefreshStarted {
            ensureDeviceSelection()
            return
        }
        initialRefreshStarted = true
        await refresh()
    }

    /// The development launch hooks (`DHP_AUTOMIRROR`, `_LOG_SERIAL`,
    /// `_AUTOPAIR` and the like), once per launch, on the first window's
    /// workspace.
    private func applyLaunchHooksOnce() async {
        guard !launchHooksApplied else { return }
        launchHooksApplied = true
        if launchOptions.autoMirror, mirror.session == nil {
            let preferred = launchOptions.mirrorSerial
            if let device = preferred.flatMap({ serial in
                inventory.devices.first { $0.serial == serial && $0.isOnline }
            }) ?? inventory.devices.first(where: { $0.isEmulator && $0.isOnline }) {
                await mirror(device: device)
            }
        }
        if let logSerial = launchOptions.logSerial,
           logcat.logcatSerial == nil {
            await logcat.openLogcat(serial: logSerial)
            window.inspectorTab = .diagnostics
            window.showInspector = true
        }
        if launchOptions.showControls {
            window.inspectorTab = .controls
            window.showInspector = true
        }
        if launchOptions.autoPair,
           !window.isPairSheetPresented {
            window.isPairSheetPresented = true
        }
        // Smoke-test convenience: open the Pixel catalog screen for a skin.
        if let skin = launchOptions.pixelSkin,
           deviceSelection != .pixel(skin) {
            deviceSelection = .pixel(skin)
        }
    }

    /// Builds the gallery model (`AvdCatalogController.refreshGallery()`).
    private func refreshGallery() async {
        await catalog.refreshGallery()
    }

    /// Hands `catalog` what it reads from this model (the current emulator,
    /// the adb snapshot's real rows and their consoles' AVD names) and the
    /// refresh and selection fix-up it leaves to this model.
    private func wireAvdCatalog() {
        catalog.emulatorManagerProvider = { [weak self] in self?.emulatorManager }
        catalog.realDevicesSource = { [weak self] in self?.realDevices ?? [] }
        catalog.avdSerialsResolver = { [weak self] devices in
            await self?.inventory.resolveAvdSerials(among: devices) ?? [:]
        }
        catalog.refresh = { [weak self] in await self?.refreshAndroid() }
        catalog.selectionFollowsAvd = { [weak self] avdName, replacement in
            guard let self else { return }
            if self.deviceSelection == .avd(avdName) { self.deviceSelection = replacement }
        }
    }

    /// Hands `inventory` what it reads from this model (the current emulator
    /// and the AVD cards) and what it leaves to this model's orchestration:
    /// the selection fix-up and the cards' running state after a snapshot.
    private func wireInventory() {
        inventory.emulatorManagerProvider = { [weak self] in self?.emulatorManager }
        inventory.avdCardsSource = { [weak self] in self?.catalog.avdCards ?? [] }
        inventory.keepSelectionValid = { [weak self] in self?.ensureDeviceSelection() }
        inventory.refreshAvdCards = { [weak self] in await self?.catalog.refreshAvdRunningState() }
        // Teardown and resume no longer route through a heuristic here:
        // each workspace's own coordinator was built with
        // that workspace's own `tearDownMirror`/`lifecycleResume` hooks
        // directly (`DeviceWorkspace.wireLifecycle`), so its own episode
        // always reaches its own window, structurally.
    }

    /// Hands the simulator controllers what they read from each other and
    /// from this model: a list change updates the lifecycle's view of the
    /// boots, ends the session of a simulator no longer booted and keeps the
    /// selection valid; the lifecycle reaches simctl, the listing, the logs
    /// folder and a list reload through the inventory; the canvas starts and
    /// ends its sessions through the session hubs, and the mirror hands it a
    /// stopped session and asks it for the simulator's display.
    private func wireSimulators() {
        simulators.listChanged = { [weak self] in
            guard let self else { return }
            self.simulatorLifecycle.noteSnapshot(self.simulators.simulators)
            // Every workspace's canvas: one may show a simulator that
            // stopped, and each forgets the failures of the ones that did.
            for workspace in self.registry.workspaces {
                workspace.simulatorCanvas.noteListing(self.simulators.simulators)
            }
            self.ensureDeviceSelection()
        }
        simulatorLifecycle.simctlSource = { [weak self] in self?.simulators.simctl }
        simulatorLifecycle.logsDirectorySource = { [weak self] in self?.simulators.logsDirectory }
        simulatorLifecycle.entrySource = { [weak self] udid in self?.simulators.entry(udid: udid) }
        simulatorLifecycle.snapshotSource = { [weak self] in self?.simulators.simulators ?? [] }
        simulatorLifecycle.reloadList = { [weak self] in await self?.simulators.reloadList() }
        // The Controls' boot time zone and kept location (simctl has no
        // time-zone command, and a shutdown loses the simulated location):
        // `appleDeviceMemory` is one app-global store, so this hook needs no
        // owning workspace.
        simulatorLifecycle.timeZoneSource = { [weak self] udid in self?.appleDeviceMemory.timeZone(for: udid) }
        // `screenContent` asks every registered workspace (the live-canvas
        // screen check belongs to whichever one shows that simulator);
        // `becameReady` is the shared Controls note, applied once.
        simulatorLifecycle.becameReady = { [weak self] udid, startedHere in
            // What it does (the respring note, the kept location and its
            // `simctl location` call) runs on app-global state, so once is
            // enough: one call per workspace would repeat the same command.
            self?.workspace.appleControls.simulatorBecameReady(udid, bootStartedHere: startedHere)
        }
        // Ready's screen check reads the live canvas's frame from whichever
        // workspace runs one for the simulator, else takes a screenshot.
        simulatorLifecycle.screenContent = { [weak self] udid, simctl in
            guard let self else { return await SimulatorLifecycleController.screenshotContent(udid, simctl) }
            for workspace in self.registry.workspaces {
                if let content = await workspace.simulatorCanvas.screenContentFromCanvas(udid) {
                    return content
                }
            }
            return await SimulatorLifecycleController.screenshotContent(udid, simctl)
        }
        // The canvas's session half (its begin and teardown hooks, the
        // stopped session, the display) and the rest of the per-device
        // hooks above (capture, media, simulatorApps, appleControls,
        // logcat/clipboard simctl) are each workspace's own
        // (`DeviceWorkspace.wireAppHooks`).
    }

    /// A physical-device list change keeps every workspace's selection valid
    /// (a device that went away, or the preference turned off, drops its
    /// selection; a physical device is never selected by this pass).
    private func wirePhysicalDevices() {
        physicalInventory.listChanged = { [weak self] in
            self?.ensureDeviceSelection()
        }
    }

    // MARK: - Mirroring

    /// Attaches the right mirror transport for `device`
    /// (`DeviceWorkspace.mirror(device:)`).
    @discardableResult
    func mirror(device: AndroidDevice) async -> DeviceWorkspace.AttachOutcome {
        await workspace.mirror(device: device)
    }

    /// Shows a running device in the center stage, merging it with its AVD
    /// card when the serial belongs to a known AVD.
    func select(_ device: AndroidDevice) {
        workspace.select(device)
    }

    /// Keeps every workspace's stage selection valid: drops stale entries
    /// and picks the first running device (else the first AVD) when
    /// nothing is selected. A simulator counts while the sidebar lists it
    /// (Show Unused decides for the never-used default ones).
    func ensureDeviceSelection() {
        let snapshot = SelectionRouting.Snapshot(
            devices: inventory.devices,
            avdCards: catalog.avdCards,
            avds: catalog.avds,
            skinCatalog: catalog.skinCatalog,
            startingAvdNames: boot.startingAvdNames,
            simulators: simulators.visibleSimulators,
            physicalApple: physicalInventory.listedUDIDs
        )
        for workspace in registry.workspaces {
            // A phone whose transport changed keeps its row: a selection of
            // one of its other adb serials follows the live one.
            if case .device(let serial) = workspace.deviceSelection,
               let live = inventory.serialAliases[serial] ?? Self.liveTransport(of: serial, in: snapshot.devices),
               snapshot.devices.contains(where: { $0.serial == live }) {
                workspace.deviceSelection = .device(live)
            }
            // A window that lost its device stays on "No Selection" until the
            // user picks another one (Device Hub does not jump).
            if workspace.deviceSelection != nil { workspace.window.selectionWasLost = false }
            let target = SelectionRouting.ensureTarget(
                for: workspace.deviceSelection,
                in: snapshot,
                autoSelect: !workspace.window.selectionWasLost
            )
            if case .assign(let selection) = target {
                if selection == nil, workspace.deviceSelection != nil { workspace.window.selectionWasLost = true }
                workspace.deviceSelection = selection
            }
            pruneMultiSelection(of: workspace, in: snapshot)
        }
    }

    /// Drops the multi-selected rows the lists no longer have (a removed
    /// AVD or simulator, an unplugged phone whose ghost is gone), keeping
    /// the primary.
    private func pruneMultiSelection(of workspace: DeviceWorkspace, in snapshot: SelectionRouting.Snapshot) {
        guard workspace.multiSelection.isMultiple else { return }
        var listed = Set<DeviceSelection>()
        listed.formUnion(snapshot.avds.map { DeviceSelection.avd($0) })
        listed.formUnion(snapshot.avdCards.map { DeviceSelection.avd($0.name) })
        listed.formUnion(snapshot.devices.map { DeviceSelection.device($0.serial) })
        listed.formUnion(snapshot.simulators.map { DeviceSelection.simulator($0.udid) })
        listed.formUnion(snapshot.physicalApple.map { DeviceSelection.physicalApple($0) })
        var multi = workspace.multiSelection
        multi.prune(keeping: listed, primary: workspace.deviceSelection)
        if multi != workspace.multiSelection { workspace.multiSelection = multi }
    }

    private static func pixelSizeLabel(_ size: CGSize) -> String {
        "\(Int(size.width))×\(Int(size.height))"
    }

    /// The status center a device-owning flow (`startAndMirror`,
    /// `stopEmulator`, `powerOnDevice` —'s "mirror/attach")
    /// writes to: `owner` when the caller already knows it (`stopEmulator`,
    /// `powerOnDevice`), else the focused workspace — the routing
    /// `WorkspaceRegistry` uses for the same flows. Never nil: `registry`
    /// always has at least `workspace` registered. This is never the
    /// app-global `status` (`AppModel`'s own), which stays for inventory,
    /// refresh, pairing, the AVD catalog, the SDK, preferences and a
    /// batch's aggregate line.
    private func deviceStatus(for owner: DeviceWorkspace? = nil) -> StatusCenter {
        (owner ?? registry.focused ?? workspace).status
    }

    /// The window in front (the key window's workspace), else the first.
    var focusedWorkspace: DeviceWorkspace { registry.focused ?? workspace }

    /// Settings are app-wide: the device frame applies to every window.
    func setShowDeviceFrameInAllWindows(_ show: Bool) {
        for member in registry.workspaces where member.window.showDeviceFrame != show {
            member.window.toggleDeviceFrame()
        }
    }

    /// The replay buffer preference applies to every window's ring.
    func setReplayEnabledInAllWindows(_ enabled: Bool) {
        for member in registry.workspaces { member.media.setReplayEnabled(enabled) }
    }

    func setReplayWindowSecondsInAllWindows(_ seconds: Double) {
        for member in registry.workspaces { member.media.setReplayWindowSeconds(seconds) }
    }

    /// True while the app-global center or any workspace's own center has a
    /// long operation in flight. With one workspace this is exactly the old
    /// single shared counter; with more, a busy device-owning flow in any
    /// window still holds off every busy-gated control app-wide, as it did
    /// before this center split.
    var isBusy: Bool {
        status.isBusy || registry.workspaces.contains { $0.status.isBusy }
    }

    /// `body`'s answer, or nil when the attach timeout (`MirrorController.attachTimeout`)
    /// passed first.
    private func bounded<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T? {
        await BoundedWait.run(mirror.attachTimeout, body)
    }

    /// Stops `avd`, then starts it again and mirrors it: the repair for an
    /// emulator whose display stream stopped answering (its host screenshot
    /// path is wedged for good; the guest is fine).
    func restartEmulator(avd: String, workspace: DeviceWorkspace? = nil) async {
        let target = workspace ?? registry.focused ?? self.workspace
        await stopEmulator(avd: avd)
        await startAndMirror(avd: avd, workspace: target)
    }

    /// Starts (or attaches to) `avd` and mirrors it in `target`'s window: the
    /// caller's own workspace, else the focused one. It never touches
    /// another window's selection or session.
    func startAndMirror(avd: String, workspace target: DeviceWorkspace? = nil) async {
        // Not yet attached to any device, so there is no owner to route to
        // yet: the caller's workspace (the window the user clicked in), else
        // the focused one, the same fallback `deviceStatus()` gives.
        let ws = target ?? registry.focused ?? self.workspace
        let deviceCenter = deviceStatus(for: ws)
        guard let adbClient, let emulatorManager else {
            deviceCenter.errorMessage = adbClient == nil
                ? UserFacingText.androidToolsMissing
                : EmulatorError.emulatorNotFound.description
            return
        }
        // A start already in flight owns this AVD: a second launch would
        // shut the booting instance down. Claimed before the first await (the
        // `ps` read below), so two quick clicks cannot both pass.
        guard boot.claim(avd) else { return }

        var shownStatus: String?
        func show(_ status: String) {
            deviceCenter.showProgress(status)
            shownStatus = status
        }
        beginBusy()
        defer {
            endBusy()
            boot.finish(avd)
            deviceCenter.clear(ifShowing: shownStatus)
        }

        // If the AVD is already running, attach to it. Launching a second instance
        // would shut down the running one (and can leave nothing running at all).
        // Every read on this path is bounded: a wedged emulator can leave a
        // call unanswered for good, which would hold `beginBusy` (and every
        // busy-gated button) for as long as the app runs.
        let timedOut = MirrorController.attachTimedOutMessage(avd)
        let manager = emulatorManager
        let adb = adbClient
        guard let runningRead = await bounded({ await self.boot.runningEmulator(named: avd, manager: manager) }) else {
            deviceCenter.errorMessage = timedOut
            return
        }
        if let running = runningRead {
            guard let serialRead = await bounded({ await self.boot.serial(forAvd: avd, adbClient: adb) }) else {
                deviceCenter.errorMessage = timedOut
                return
            }
            guard let serial = serialRead else {
                deviceCenter.errorMessage = "\(avd) is running but isn't ready yet. Try again in a moment."
                return
            }
            // The discovery file wins over the `ps` port: it also carries the
            // token of a VM started with -grpc-use-token (by this app in an
            // earlier run, or by Android Studio) and registers it, without
            // which every gRPC call is refused. A read that times out falls
            // back to the `ps` port.
            let discovered = await bounded({ await EmulatorDiscovery.grpcInfo(serial: serial, adbClient: adb) }) ?? nil
            guard let port = discovered?.port ?? running.grpcPort else {
                deviceCenter.errorMessage = "\(avd) is already running, but Device Hub Pro couldn't reach its controls. Restart it from Device Hub Pro."
                return
            }
            show("Attaching to \(avd)…")
            // A running emulator's framebuffer is fixed; a mismatch can only
            // be repaired by restarting it from here.
            if let skin = catalog.avdCards.first(where: { $0.name == avd })?.skin,
               let mismatch = AvdDisplayRepair.diagnose(avdName: avd, skin: skin)
            {
                show("Attaching to \(avd)… (display \(Self.pixelSizeLabel(mismatch.lcd)) ≠ skin \(Self.pixelSizeLabel(mismatch.skin)); restart it from Device Hub Pro to repair)")
            }
            grpcCache.store(port, for: serial)
            ws.deviceSelection = .avd(avd)
            // Best effort: a failed or timed-out read keeps the current list.
            let inventory = self.inventory
            if let listed = await bounded({ try? await inventory.listGroupedDevices() }), let grouped = listed {
                setRealDevices(grouped)
            }
            _ = await bounded({ await self.refreshGallery() })
            // A Stop that landed meanwhile is shutting the VM down.
            guard !boot.isStoppedByUser(avd) else { return }
            // As after a boot: the mirror starts only where the user still
            // looks, so a selection made during the reads above keeps its
            // stage (and whatever session it shows).
            guard ws.deviceSelection == .avd(avd) else { return }
            ws.startSession(serial: serial, port: port, avdName: avd)
            return
        }

        // Not a VM this model may attach to, but perhaps still a VM of the
        // AVD: one outside the emulator's process scope (a test's model sees
        // only its own), or one that started since the read above. Neither
        // is booted over, nor has its config.ini repaired from under it.
        if let refusal = await boot.launchRefusal(avd: avd, manager: emulatorManager) {
            deviceCenter.errorMessage = refusal
            return
        }

        var repairNote: String?
        if preferences.autoRepairAvdDisplay,
           let skin = catalog.avdCards.first(where: { $0.name == avd })?.skin
        {
            switch AvdDisplayRepair.repair(avdName: avd, skin: skin) {
            case .repaired(let from, let to):
                repairNote = "display repaired \(Self.pixelSizeLabel(from)) → \(Self.pixelSizeLabel(to))"
            case .alreadyMatches, .unsupported, .failed:
                break
            }
        }

        show(repairNote.map { "Starting \(avd)… (\($0))" } ?? "Starting \(avd)…")
        boot.markBooting(avd)
        // Quick boot, except right after a display repair: the saved
        // snapshot no longer matches the rewritten config.ini.
        let outcome = await boot.bootEmulator(
            avd: avd,
            coldBoot: repairNote != nil,
            manager: emulatorManager,
            adbClient: adbClient,
            launched: {
                // From here on the stage shows this AVD booting (skin hero +
                // progress) until the boot completes and the mirror takes over.
                ws.deviceSelection = .avd(avd)
            },
            progress: show
        )
        switch outcome {
        case .failed(let message, let details):
            deviceCenter.errorMessage = message
            deviceCenter.errorDetails = details
        case .stoppedByUser:
            break
        case .booted(let serial, let port):
            // Best effort: a failed read keeps the current list.
            setRealDevices((try? await inventory.listGroupedDevices()) ?? realDevices)
            if let device = inventory.devices.first(where: { $0.serial == serial }) {
                await inventory.loadInfo(for: device)
            }
            await refreshGallery()
            boot.markBooted(avd)
            // A Stop that landed during the reads above is shutting this VM
            // down: a session on it would read its exit as a disconnect (a
            // ghost row, auto-resume, an "interrupted" recording).
            guard !boot.isStoppedByUser(avd) else { return }
            // The mirror starts only where the user still looks: a boot that
            // finished after they moved on leaves the stage (and whatever
            // session it shows) alone; selecting the AVD attaches later.
            guard ws.deviceSelection == .avd(avd) else { return }
            ws.startSession(serial: serial, port: port, avdName: avd)
        }
    }

    /// Hands `boot` the console lookup (cached per adb transport) and the
    /// gRPC port cache it records a booted VM's port in.
    private func wireEmulatorBoot() {
        boot.consoleAvdName = { [weak self] device in await self?.avdName(of: device) }
        boot.storeGrpcPort = { [weak self] port, serial in self?.grpcCache.store(port, for: serial) }
    }

    func setActiveAvdName(_ name: String?) {
        activeAvdName = name
    }

    // MARK: - Emulator controls

    /// Stops the active emulator's VM for good (Device ▸ Stop Emulator); see
    /// `stopEmulator(avd:)`. Unlike "Shut Down Android" — which only asks the
    /// guest OS via adb and silently does nothing when adb cannot reach it —
    /// this ends the VM process itself.
    func stopActiveEmulator(in target: DeviceWorkspace? = nil) async {
        let ws = target ?? registry.focused ?? workspace
        var avd = ws.context.avdName
        if avd == nil, let adbClient, let serial = ws.context.serial {
            avd = try? await adbClient.avdName(serial: serial)
        }
        guard let avd else {
            deviceStatus(for: ws).errorMessage = "No AVD is known for the active device."
            return
        }
        await stopEmulator(avd: avd)
    }

    /// Stops `avd`'s VM the way `EmulatorManager.stop` does: the emulator's
    /// own clean shutdown first (its console `kill`, which saves the
    /// quick-boot snapshot and can take up to a minute for a large RAM
    /// image), then SIGTERM, and SIGKILL only for a VM this app launched. A
    /// VM started elsewhere that is still saving is left running and
    /// reported. The status line counts the seconds meanwhile.
    ///
    /// The VM's mirror ends first, as the user's stop: its recording goes to
    /// the save flow, and the lifecycle does not treat the VM leaving adb as
    /// a disconnect. The network conditions Device Hub Pro set on it are put back
    /// before the shutdown saves its state. A start of this AVD still in
    /// flight (booting, or attaching to the running VM) ends silently,
    /// without a session.
    func stopEmulator(avd: String) async {
        // The serial of *this* AVD only: the console `kill` goes to it, so a
        // fallback to whatever is mirrored would shut down the wrong VM.
        let cardSerial = catalog.avdCards.first(where: { $0.name == avd })?.serial
        // The workspace mirroring this VM, whichever window it is.
        let owner = registry.owner(ofAvd: avd, serial: cardSerial)
        let deviceCenter = deviceStatus(for: owner)
        guard let emulatorManager else {
            deviceCenter.errorMessage = EmulatorError.emulatorNotFound.description
            return
        }
        let serial = cardSerial ?? owner?.context.serial
        boot.requestStop(avd)
        owner?.stopMirror()
        beginBusy()
        defer { endBusy() }
        let result: EmulatorStopResult
        do {
            result = try await deviceCenter.withElapsedStatus("Stopping \(avd)…") {
                await awaitConditionsCleanup()
                return try await boot.stop(avd: avd, serial: serial, manager: emulatorManager)
            }
        } catch {
            // The VM lives on, so a boot still waiting on it must report as usual.
            boot.withdrawStop(avd)
            if !error.isCancellation { deviceCenter.errorMessage = "\(error)" }
            return
        }
        if let serial {
            grpcCache.invalidate(serial: serial)
            avdNamesBySerial[serial] = nil
            noteEmulatorExited(serial: serial)
        }
        await refreshAndroid()
        switch result {
        case .notRunning:
            deviceCenter.flash("\(avd) was not running")
        case .stopped(let gracefully):
            deviceCenter.flash(gracefully ? "Stopped \(avd)" : "Stopped \(avd) (forced)")
        }
    }

    /// Waits, bounded, for the put-backs every workspace's
    /// `conditions.detach()` started: they reach the VM through its console
    /// and adb shell, so a Stop's console `kill` (which saves the
    /// quick-boot state as it is) or the recovery's kill must not overtake
    /// them.
    private func awaitConditionsCleanup() async {
        let workspaces = registry.workspaces
        await Self.awaitBounded(DeviceConditionsController.cleanupWaitLimit) {
            for workspace in workspaces {
                await workspace.conditions.waitForPendingCleanup()
            }
        }
    }

    /// The VM behind `serial` exited: no workspace's conditions put back
    /// what they set on it (the next VM may reuse the serial).
    private func noteEmulatorExited(serial: String) {
        for workspace in registry.workspaces {
            workspace.conditions.emulatorExited(serial: serial)
            workspace.controlsPanel.languageTime.emulatorExited(serial: serial)
        }
    }

    // Private shims for the app-global `StatusCenter`'s busy count, so this
    // file's call sites keep their text. The busy count stays global (every
    // gated control across the app, not one workspace's) even for a
    // device-owning flow; only its status line and error alert route to
    // `deviceStatus`.

    private func beginBusy() {
        status.beginBusy()
    }

    private func endBusy() {
        status.endBusy()
    }

    // MARK: - AVD file actions

    /// The AVD `workspace` (the window the caller acts for) selects, if any.
    /// Never the first window's: a menu or button acts on its own tab.
    func selectedAvdName(in workspace: DeviceWorkspace?) -> String? {
        if case .avd(let name)? = workspace?.deviceSelection { return name }
        return nil
    }

    /// The Pixel catalog skin `workspace` selects, if any.
    func selectedPixelSkinName(in workspace: DeviceWorkspace?) -> String? {
        if case .pixel(let name)? = workspace?.deviceSelection { return name }
        return nil
    }

    /// The first installed AVD for the Pixel skin `workspace` selects, if any.
    func selectedPixelCard(in workspace: DeviceWorkspace?) -> AvdCard? {
        guard let skinName = selectedPixelSkinName(in: workspace) else { return nil }
        return catalog.avdCards(forPixelSkin: skinName).first
    }

    /// Whether `workspace`'s selected AVD comes from the last refreshed
    /// list. A stale selection is "unknown" and keeps its file actions
    /// disabled.
    func selectedAvdStateIsKnown(in workspace: DeviceWorkspace?) -> Bool {
        guard let name = selectedAvdName(in: workspace) else { return false }
        return catalog.avdCards.contains { $0.name == name }
    }

    /// Whether `workspace`'s selected AVD is running (its row actions stay
    /// disabled).
    func selectedAvdIsRunning(in workspace: DeviceWorkspace?) -> Bool {
        guard let name = selectedAvdName(in: workspace) else { return false }
        return catalog.avdCards.first { $0.name == name }?.isRunning ?? false
    }

    /// Rename, Reset and Start act on a stopped AVD `workspace` selects.
    func avdFileActionsEnabled(in workspace: DeviceWorkspace?) -> Bool {
        selectedAvdName(in: workspace) != nil
            && selectedAvdStateIsKnown(in: workspace)
            && !selectedAvdIsRunning(in: workspace)
    }

    // MARK: - Replay buffer

    /// The frame feed, the replay ring and the recording (the workspace's;
    /// the views and menus read it there). One long-lived instance: the
    /// session hubs attach and detach it.
    var media: MediaCaptureController { workspace.media }
    /// Finishes ended recordings; app-scoped, because a clip outlives the
    /// session it recorded and quit waits for it.
    let recordingFinalizer: RecordingFinalizer

    /// `stopActiveEmulator()` terminates the VM process; a physical mirror has
    /// no AVD/VM to stop, so the Device menu item must stay disabled for it
    /// (the action could only report that no AVD is known). Emulator serials
    /// carry the `emulator-` prefix, which also covers a VM that already
    /// dropped off the device list and left a zombie process behind.
    static func canStopActiveEmulator(activeSerial: String?) -> Bool {
        activeSerial?.hasPrefix("emulator-") == true
    }

    func canStopActiveEmulator(in workspace: DeviceWorkspace?) -> Bool {
        Self.canStopActiveEmulator(activeSerial: (workspace ?? registry.focused ?? self.workspace).context.serial)
    }

    // MARK: - Device controls (Controls tab)

    /// The Controls tab's state, poll, reads, probes, settings writes and
    /// volume stepping (`DeviceWorkspace`; the views read it there). One
    /// long-lived instance: the teardown hub detaches it.
    var controlsPanel: DeviceControlsController { workspace.controlsPanel }

    /// The battery, fold and resize workers of the Controls tab and the
    /// fold strip (`DeviceWorkspace`; the views read it there). One
    /// long-lived instance: the session hubs start its preset read and
    /// detach it.
    var hardware: EmulatorHardwareController { workspace.hardware }

    /// The Controls tab's Network conditions and App conditions groups,
    /// called directly by their rows. One long-lived instance: the session
    /// hubs attach and detach it.
    var conditions: DeviceConditionsController { workspace.conditions }

    /// The Controls tab's Links group, called directly by its rows. It
    /// writes no settings, so the session hubs only detach it.
    var links: DeviceLinksController { workspace.links }

    /// `controlsPanel` and `hardware`'s own hooks are wired by the workspace
    /// itself (`DeviceWorkspace.wireAppHooks`).

    // MARK: - Recovery

    /// Restores power: the broken VM is killed and cold-booted, and the
    /// mirror re-attaches once Android has booted.
    func powerOnDevice(in target: DeviceWorkspace? = nil) async {
        // The recovery card's window: the focused workspace owns the dead
        // device it shows.
        guard let adbClient, let emulatorManager, let owner = target ?? registry.focused,
              let avd = owner.context.avdName else {
            deviceStatus().errorMessage = "No AVD is known for the active device."
            return
        }
        let deviceCenter = deviceStatus(for: owner)
        guard boot.claim(avd) else { return }
        let deadSerial = owner.context.serial

        var shownStatus: String?
        func show(_ status: String) {
            deviceCenter.showProgress(status)
            shownStatus = status
        }
        beginBusy()
        boot.markBooting(avd)
        show("Powering on \(avd)…")
        defer {
            endBusy()
            boot.finish(avd)
            deviceCenter.clear(ifShowing: shownStatus)
        }
        let selection = owner.deviceSelection

        // The user asked for the restart: the dead mirror ends as their stop
        // (a recording goes to the save flow) and the lifecycle does not read
        // the VM leaving adb as a disconnect.
        owner.stopMirror()
        await awaitConditionsCleanup()

        // The broken VM is killed, not shut down: a clean exit would save the
        // powered-off guest as the quick-boot snapshot and keep the AVD locked
        // while it writes it, so the relaunch below would be refused.
        do {
            try await emulatorManager.killWithoutSaving(avd: avd)
        } catch {
            if !error.isCancellation { deviceCenter.errorMessage = "\(error)" }
            return
        }
        // The next VM is likely to reuse the serial; nothing learned about
        // the killed one may carry over.
        if let deadSerial {
            grpcCache.invalidate(serial: deadSerial)
            avdNamesBySerial[deadSerial] = nil
            noteEmulatorExited(serial: deadSerial)
        }

        // A powered-off guest is recovered with a cold boot, as before quick
        // boot became the launch default. The battery is left as the cold
        // boot sets it (no forced 100 % and charging).
        let outcome = await boot.bootEmulator(
            avd: avd,
            coldBoot: true,
            manager: emulatorManager,
            adbClient: adbClient,
            launched: {},
            progress: show
        )
        switch outcome {
        case .failed(let message, let details):
            deviceCenter.errorMessage = message
            deviceCenter.errorDetails = details
        case .stoppedByUser:
            break
        case .booted(let serial, let port):
            // Best effort: a failed read keeps the current list.
            setRealDevices((try? await inventory.listGroupedDevices()) ?? realDevices)
            await refreshGallery()
            boot.markBooted(avd)
            // A Stop that landed during the reads above is shutting this VM
            // down (see `startAndMirror`).
            guard !boot.isStoppedByUser(avd) else { return }
            // Re-attach only where the user still looks.
            guard owner.deviceSelection == selection else { return }
            owner.startSession(serial: serial, port: port, avdName: avd)
        }
    }

    var activeDeviceSerial: String? { activeSerial }

    /// The user's Stop Mirror (`DeviceWorkspace.stopMirror()`).
    func stopMirror() {
        workspace.stopMirror()
    }

    /// Ends the active mirror session and everything bound to it
    /// (`DeviceWorkspace.tearDownMirror(cause:)`).
    func tearDownMirror(cause: DeviceWorkspace.MirrorTeardownCause) {
        workspace.tearDownMirror(cause: cause)
    }

    // MARK: - Extended controls

    /// The sensors, telephony, VM pause and fingerprint of the Controls tab
    /// (`DeviceWorkspace`; the views read it there).
    var extras: EmulatorExtrasController { workspace.extras }

    // MARK: - Clipboard

    /// The Mac ↔ device clipboard sync (`DeviceWorkspace`; the views read
    /// it there, and its entry points act on `workspace.mirror`'s active
    /// physical session).
    var clipboard: ClipboardSyncController { workspace.clipboard }

    // MARK: - Logcat

    /// The Diagnostics tab's logcat (the workspace's; the views read it
    /// there).
    var logcat: LogcatController { workspace.logcat }

    // MARK: - Apps

    /// `apps`' own hooks are wired by the workspace itself
    /// (`DeviceWorkspace.wireAppHooks`).

    // MARK: - Internals

    /// The begin hub, for a session on any platform
    /// (`DeviceWorkspace.beginMirrorSession`).
    func beginMirrorSession(
        _ newSession: any MirrorSessionProtocol,
        device: DeviceRef,
        port: Int?,
        avdName: String? = nil,
        capabilities: DeviceCapabilities
    ) {
        workspace.beginMirrorSession(newSession, device: device, port: port, avdName: avdName, capabilities: capabilities)
    }

    /// The active session's generation (bumped by every session start and
    /// teardown), for results that must land on the session they were
    /// asked for.
    var mirrorSessionGeneration: Int { lifecycleGeneration }

    /// The console's AVD answer, landing only on the session it was asked
    /// for (`DeviceWorkspace.applyActiveAvdName`).
    func applyActiveAvdName(_ name: String?, serial: String, generation: Int) {
        workspace.applyActiveAvdName(name, serial: serial, generation: generation)
    }

    /// Hands `grpcPorts` what it reads from this model: the current emulator
    /// and the consoles' AVD names, cached per adb transport.
    private func wireGrpcPorts() {
        grpcPorts.emulatorManagerProvider = { [weak self] in self?.emulatorManager }
        grpcPorts.consoleAvdName = { [weak self] device in await self?.avdName(of: device) }
    }
}
