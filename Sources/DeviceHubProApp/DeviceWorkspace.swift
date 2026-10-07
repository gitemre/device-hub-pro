import AppKit
import Foundation
import Observation
import DeviceHubProKit

/// What one window shows and drives: the mirrored device's
/// context and session, the per-device features bound to it, the stage and
/// inspector state, and the sidebar's selection.
///
/// Today there is exactly one, built by `AppModel` from the instances it
/// used to hold itself; `AppModel` keeps their old names as computed
/// properties over it (`workspace.mirror`, …) and one-line delegates to its
/// session hubs.
///
/// It owns the attach (`mirror(device:)`) and the session hubs
/// (`beginMirrorSession`, `tearDownMirror`) with what hangs on them (the
/// user's stop, the lifecycle's resume, the AVD-name lookup, the simulator
/// canvas's session hooks), and reads the app-global tools through
/// `services`; it never holds the model.
@MainActor
@Observable
final class DeviceWorkspace {
    typealias AttachOutcome = MirrorController.AttachOutcome
    typealias MirrorTeardownCause = MirrorController.MirrorTeardownCause

    /// The app-global tools and lists (adb, the device rows and their
    /// lifecycle, the AVD cards, the gRPC ports, the simulators).
    @ObservationIgnored let services: AppServices
    /// Names this workspace in the registry.
    let id = WorkspaceID()
    /// The registry it is a member of, which routes app-wide actions and
    /// holds the device claims; set by `WorkspaceRegistry.register`.
    @ObservationIgnored weak var registry: WorkspaceRegistry?
    /// The mirrored device: serial, emulator port, AVD and the session
    /// generations, shared by the per-device features below.
    let context: ActiveDeviceContext
    /// This window's own status line, error alert and busy count:
    /// every per-device controller below is built on it, not on
    /// `services.status` (the app-global one `AppModel` keeps for
    /// inventory, refresh, pairing, the AVD catalog, the SDK, preferences
    /// and a batch's aggregate line). `ContentView` merges the two by
    /// `StatusCenter.active(error:_:)`/`active(status:_:)` so a single
    /// window still shows exactly what the one shared center used to.
    let status: StatusCenter
    /// This workspace's own hot-plug episode decider: one
    /// per workspace, created with it and registered with the registry
    /// (`WorkspaceRegistry.register`), so this window's Android episode
    /// (its ghost, its reconnect schedule, its waiting panel) never touches
    /// another workspace's.
    let lifecycle: DeviceLifecycleCoordinator
    /// The stage's "waiting to reconnect" model, derived from this
    /// workspace's own coordinator through its `lifecycleState` hook; nil
    /// while healthy so the panel hides (S4).
    private(set) var reconnect: ReconnectStatus?
    /// The session, its attach state, the stats poll, the stage's view
    /// state and in-app audio.
    let mirror: MirrorController
    /// The inspector, sidebar, sheet, toggle and zoom state.
    let window: WindowState
    /// The Controls tab's state, poll, reads and writes.
    let controlsPanel: DeviceControlsController
    /// The battery, fold and resize workers.
    let hardware: EmulatorHardwareController
    /// The sensors, telephony, VM pause and fingerprint.
    let extras: EmulatorExtrasController
    /// The Network and App conditions (with the status bar, language and
    /// time, and color filter rows).
    let conditions: DeviceConditionsController
    /// The Controls tab's Links group.
    let links: DeviceLinksController
    /// The Location row.
    let location: LocationController
    /// Screenshots, the annotation editor and the diagnostics bundle.
    let capture: CaptureController
    /// The frame feed, the replay ring and the recording.
    let media: MediaCaptureController
    /// The Mac ↔ device clipboard sync.
    let clipboard: ClipboardSyncController
    /// The Diagnostics tab's logcat and simulator log.
    let logcat: LogcatController
    /// The Apps tab and APK install.
    let apps: AppsController
    /// A simulator's apps in the inspector and what is dropped on its stage.
    let simulatorApps: SimulatorAppsController
    /// The crash reports of the simulator the Diagnostics tab shows.
    let simulatorCrashReports: SimulatorCrashReportsController
    /// An enabled physical iPhone's or iPad's Apps tab and what is dropped on
    /// its stage.
    let physicalApps: PhysicalAppsController
    /// Send Files: drops and the Send Files… panel for every platform.
    let sendFiles: SendFilesController
    /// The crash logs of the physical device the Diagnostics tab shows.
    let physicalCrashLogs: PhysicalCrashLogsController
    /// A simulator's Controls panel.
    let appleControls: AppleControlsController
    /// A simulator's live stage.
    let simulatorCanvas: SimulatorCanvasController
    /// A selected physical iPhone's view-only screen: the live USB capture,
    /// the screenshot preview or the static panel.
    let physicalLive: PhysicalLiveViewController
    /// "Control this iPhone": the opt-in mode that
    /// lets the physical view's input reach the test iPhone through the
    /// public-XCTest runner. Off by default.
    let physicalControl = PhysicalControlController()

    /// The device shown in the center stage.
    var deviceSelection: DeviceSelection? {
        didSet {
            if deviceSelection != oldValue {
                // The user moved on: an attach still resolving for the old
                // selection must not select it back or raise its errors.
                mirror.cancelPendingAttach()
                // The stage's zoom is kept per device (opening at Physical
                // Size, Device Hub's default).
                window.showsDevice(deviceSelection.map { String(describing: $0) })
            }
            // A primary outside the multi-selection (an arrow, a start, a
            // stale selection's replacement) replaces it; one inside keeps
            // it. Written only on a change: every row's pill observes it.
            var multi = multiSelection
            multi.follow(primary: deviceSelection)
            if multi != multiSelection { multiSelection = multi }
            selectionChanged()
        }
    }
    /// The sidebar's multi-selection: the rows ⌘-click,
    /// ⇧-click and Select All gathered, `deviceSelection` among them as the
    /// primary the stage shows.
    var multiSelection = SidebarMultiSelection()

    /// Tells the hot-plug lifecycle the selection was written (its
    /// `noteSelectionChanged`); set by its owner.
    @ObservationIgnored var selectionChanged: @MainActor () -> Void = {}

    init(
        services: AppServices,
        context: ActiveDeviceContext,
        status: StatusCenter,
        mirror: MirrorController,
        window: WindowState,
        controlsPanel: DeviceControlsController,
        hardware: EmulatorHardwareController,
        extras: EmulatorExtrasController,
        conditions: DeviceConditionsController,
        links: DeviceLinksController,
        location: LocationController,
        capture: CaptureController,
        media: MediaCaptureController,
        clipboard: ClipboardSyncController,
        logcat: LogcatController,
        apps: AppsController,
        simulatorApps: SimulatorAppsController,
        simulatorCrashReports: SimulatorCrashReportsController,
        physicalApps: PhysicalAppsController,
        physicalCrashLogs: PhysicalCrashLogsController,
        appleControls: AppleControlsController,
        simulatorCanvas: SimulatorCanvasController
    ) {
        self.services = services
        self.context = context
        self.status = status
        self.mirror = mirror
        self.window = window
        window.staysOnTop = services.preferences.stayOnTopMain
        window.compactStaysOnTop = services.preferences.stayOnTopCompact
        self.controlsPanel = controlsPanel
        self.hardware = hardware
        self.extras = extras
        self.conditions = conditions
        self.links = links
        self.location = location
        self.capture = capture
        self.media = media
        self.clipboard = clipboard
        self.logcat = logcat
        self.apps = apps
        self.simulatorApps = simulatorApps
        self.simulatorCrashReports = simulatorCrashReports
        self.physicalApps = physicalApps
        self.sendFiles = SendFilesController(
            adbClient: services.adbClient,
            simulators: services.simulators,
            inventory: services.physicalInventory,
            status: status,
            defaults: services.environment.defaults,
            apps: apps,
            simulatorApps: simulatorApps,
            physicalApps: physicalApps
        )
        self.physicalCrashLogs = physicalCrashLogs
        self.appleControls = appleControls
        self.simulatorCanvas = simulatorCanvas
        self.physicalLive = PhysicalLiveViewController(provider: services.environment.screenCapture)
        // Two-phase init: the coordinator's real hooks close over `self`, so
        // it is built here with an inert placeholder and rebound once every
        // stored property (including this one) is set — see `wireLifecycle`.
        self.lifecycle = DeviceLifecycleCoordinator(hooks: DeviceWorkspace.placeholderLifecycleHooks)
        wireMirror()
        wireSimulatorCanvasSession()
        wirePhysicalLive()
        wirePhysicalControl()
        wireLifecycle()
        wireAppHooks()
    }

    /// An inert `Hooks` value: every closure a no-op, so the coordinator
    /// built with it cannot observe anything before `wireLifecycle()` rebinds
    /// it to the real ones a few lines later in the same `init`.
    private static var placeholderLifecycleHooks: DeviceLifecycleCoordinator.Hooks {
        DeviceLifecycleCoordinator.Hooks(
            applySnapshot: { _, _ in },
            teardown: { _ in },
            resume: { _ in },
            showStatus: { _ in },
            setGhost: { _ in },
            healthFlash: { _ in },
            transportRestarted: {},
            selectedSerial: { nil },
            lifecycleState: { _ in }
        )
    }

    /// Binds this workspace's coordinator to its real hooks: its own
    /// teardown and resume hubs, its own ghost and waiting-panel state on
    /// `DeviceInventory` (keyed by `id`, never another workspace's), its own
    /// selection, and the shared `services` for the health flash, the gRPC
    /// cache invalidation and the VM liveness probe.
    private func wireLifecycle() {
        lifecycle.rebind(hooks: DeviceLifecycleCoordinator.Hooks(
            applySnapshot: { [weak self] devices, degraded in
                self?.services.inventory.applyWatcherSnapshot(devices, degraded: degraded)
            },
            // The lifecycle's own teardown is not the user's stop: it must
            // not report `.mirrorStopped`, or the episode it just began
            // (ghost, auto-resume) would end with it.
            teardown: { [weak self] reason in
                self?.tearDownMirror(cause: reason == .transportFatal ? .transportFatal : .disconnected)
            },
            resume: { [weak self] serial in await self?.lifecycleResume(serial: serial) },
            showStatus: { [weak self] status in
                guard let self else { return }
                self.services.inventory.lifecycleShowStatus(status, workspace: self.id)
            },
            setGhost: { [weak self] serial in
                guard let self else { return }
                self.services.inventory.lifecycleSetGhost(serial, workspace: self.id)
            },
            healthFlash: { [weak self] message in self?.status.flash(message) },
            transportRestarted: { [weak self] in self?.services.grpcPorts.invalidateAll() },
            selectedSerial: { [weak self] in
                if case .device(let serial) = self?.deviceSelection { return serial }
                return nil
            },
            lifecycleState: { [weak self] _ in
                // Re-derive rather than re-map: the armed attempt window
                // changes the panel model without changing the state (a
                // healthy session clears the marker while still
                // `.mirroring`), so the coordinator's own derivation is the
                // single source and every handoff refreshes it (S4).
                self?.reconnect = self?.lifecycle.reconnectStatus()
            },
            isEmulatorRunning: { [weak self] serial in
                await self?.services.inventory.isEmulatorVMRunning(serial: serial) ?? false
            }
        ))
        // The default wiring, so a workspace built via
        // `DeviceWorkspace.init(services:context:)` reaches its own
        // coordinator on a selection change without the model's help
        // (previously only `model.workspace` got this from `AppModel`).
        selectionChanged = { [weak self] in self?.lifecycleIfRunning?.noteSelectionChanged() }
    }

    /// This workspace's coordinator, but only while the hot-plug watcher
    /// runs — the same contract the old app-global `services.lifecycle`
    /// (an `Optional`, nil before `startDeviceLifecycle()`, without adb, or
    /// after `stopDeviceLifecycle()`) gave every `note*`/resume call for
    /// free. The coordinator itself now lives for this workspace's whole
    /// life, so every call that can arm a resume or ghost
    /// task is gated through this instead of the stored `lifecycle`
    /// directly, so none of them can arm anything once the watcher has
    /// stopped.
    var lifecycleIfRunning: DeviceLifecycleCoordinator? {
        services.inventory.isLifecycleRunning ? lifecycle : nil
    }

    /// A workspace with its own per-device features, built on the app's
    /// `services` the way `AppModel` builds its first one.
    convenience init(services: AppServices, context: ActiveDeviceContext = ActiveDeviceContext()) {
        let environment = services.environment
        // This workspace's own status line, error alert and busy count:
        // every per-device controller below is built on
        // it, never on `services.status` (the app-global one).
        let status = StatusCenter()
        let preferences = services.preferences
        let simulators = services.simulators
        let mirror = MirrorController(
            adbClient: services.adbClient,
            context: context,
            status: status,
            perfLog: environment.launch.perfLogURL.map { PerfLogWriter(url: $0) },
            displayShapes: services.displayShapes
        )
        mirror.rotationStore = AndroidRotationRecordStore(defaults: environment.defaults)
        let controlsPanel = DeviceControlsController(
            adbClient: services.adbClient,
            context: context,
            status: status
        )
        self.init(
            services: services,
            context: context,
            status: status,
            mirror: mirror,
            window: WindowState(),
            controlsPanel: controlsPanel,
            hardware: EmulatorHardwareController(
                adbClient: services.adbClient,
                context: context,
                controlsPanel: controlsPanel,
                status: status
            ),
            extras: EmulatorExtrasController(context: context, status: status),
            conditions: DeviceConditionsController(
                adbClient: services.adbClient,
                context: context,
                status: status,
                statusBarRecords: StatusBarDemoRecordStore(defaults: environment.defaults)
            ),
            links: DeviceLinksController(
                adbClient: services.adbClient,
                context: context,
                status: status,
                recents: services.recentLinks
            ),
            location: LocationController(
                context: context,
                status: status,
                presetStore: LocationPresetStore(defaults: environment.defaults)
            ),
            capture: CaptureController(
                adbClient: services.adbClient,
                status: status,
                preferences: preferences,
                context: context,
                pasteboard: environment.pasteboard,
                picker: environment.picker
            ),
            media: MediaCaptureController(
                preferences: preferences,
                status: status,
                context: context,
                finalizer: services.recordingFinalizer,
                picker: environment.picker
            ),
            clipboard: ClipboardSyncController(
                context: context,
                preferences: preferences,
                status: status,
                pasteboard: environment.pasteboard
            ),
            logcat: LogcatController(adbClient: services.adbClient, status: status, picker: environment.picker),
            apps: AppsController(
                adbClient: services.adbClient,
                status: status,
                recentAPKs: services.recentAPKs,
                pasteboard: environment.pasteboard
            ),
            simulatorApps: SimulatorAppsController(simulators: simulators, status: status, defaults: environment.defaults),
            simulatorCrashReports: SimulatorCrashReportsController(simulators: simulators, pasteboard: environment.pasteboard),
            physicalApps: PhysicalAppsController(
                inventory: services.physicalInventory,
                status: status,
                picker: environment.picker
            ),
            physicalCrashLogs: PhysicalCrashLogsController(
                inventory: services.physicalInventory,
                status: status,
                picker: environment.picker
            ),
            appleControls: AppleControlsController(
                simulators: simulators,
                preferences: preferences,
                memory: services.appleDeviceMemory,
                status: status
            ),
            simulatorCanvas: SimulatorCanvasController(
                simulators: simulators,
                mirror: mirror,
                memory: services.simulatorCanvasMemory,
                status: status
            )
        )
    }

    // MARK: - Wiring

    /// Hands `mirror` what it cannot know itself: the lifecycle's armed
    /// marker and health report, the teardown of a transport that failed
    /// for good, and the clipboard sync a physical device's pushes go to.
    private func wireMirror() {
        mirror.isDeviceOnline = { [weak self] serial in
            self?.services.inventory.devices.first { $0.serial == serial }?.isOnline ?? false
        }
        mirror.isAutoReconnectArmed = { [weak self] serial in
            self?.lifecycleIfRunning?.isAutoReconnectArmed(serial: serial) ?? false
        }
        mirror.onTransportFatal = { [weak self] serial in
            self?.tearDownMirror(cause: .transportFatal)
            if let serial {
                self?.lifecycleIfRunning?.noteTransportFatal(serial: serial)
            }
        }
        mirror.noteMirrorHealthy = { [weak self] serial in
            self?.lifecycleIfRunning?.noteMirrorHealthy(serial: serial)
        }
        mirror.receiveDeviceClipboard = { [weak self] text, serial in
            self?.clipboard.receive(text, serial: serial)
        }
    }

    /// The physical view's hubs: it starts and ends its sessions through the
    /// session hubs, reads its inputs from the shared inventory and the
    /// preferences, and reaches a phone's screenshot only through the
    /// inventory's client (`client(for:)`, nil unless the device is enabled,
    /// paired and connected).
    private func wirePhysicalLive() {
        physicalLive.inputs = { [weak self] in
            guard let self else { return PhysicalLiveViewController.Inputs() }
            let inventory = self.services.physicalInventory
            let preferences = self.services.preferences
            var entry: ApplePhysicalEntry?
            if case .physicalApple(let udid)? = self.deviceSelection {
                entry = inventory.entry(udid: udid)
            }
            return PhysicalLiveViewController.Inputs(
                entry: entry,
                listed: inventory.entries.map(\.device),
                // A recording keeps the capture running while the window is
                // hidden: stopping it would end the recording mid-take.
                isWindowVisible: self.window.isStageVisible || self.media.isRecording,
                showsPhysicalDevices: inventory.isShowing,
                liveViewOn: preferences.physicalLiveViewEnabled,
                nativeLiveViewOn: preferences.physicalNativeLiveView && !NativeMirrorEndpoint.isDisabled(),
                autoRefreshOn: preferences.physicalAutoRefreshEnabled,
                screenshotSupported: entry.map { self.services.physicalDevices.isSupported(.screenshot, udid: $0.udid) } ?? true
            )
        }
        physicalLive.prefetchChrome = { [weak self] productType in
            guard let simulators = self?.services.simulators,
                  simulators.deviceType(forModelIdentifier: productType) != nil
            else { return false }
            Task { await simulators.loadDisplayShape(forModelIdentifier: productType) }
            return true
        }
        physicalLive.audioPolicyProvider = { [weak self] in self?.physicalAudioPolicy ?? .disabledInSettings }
        physicalLive.beginSession = { [weak self] session, device, capabilities in
            self?.beginMirrorSession(session, device: device, port: nil, capabilities: capabilities) ?? false
        }
        physicalLive.tearDownSession = { [weak self] cause in self?.tearDownMirror(cause: cause) }
        physicalLive.activeSession = { [weak self] in self?.mirror.session }
        physicalLive.screenshotCapture = { [weak self] udid in
            guard let self else { return nil }
            let inventory = self.services.physicalInventory
            let devices = self.services.physicalDevices
            return { destination in
                guard let client = await inventory.client(for: udid) else {
                    throw PhysicalPreviewError(message: "the device is not available")
                }
                do {
                    _ = try await client.screenshot(to: destination)
                } catch DevicectlPhysicalError.unsupportedCapability {
                    await devices.noteUnsupported(.screenshot, udid: udid)
                    throw PhysicalPreviewError(message: "this device does not support screenshots")
                } catch let error as CancellationError {
                    throw error
                } catch {
                    throw PhysicalPreviewError(message: ApplePhysicalController.describe(error))
                }
            }
        }
        physicalLive.makeNativeSession = { [weak self] entry in
            guard let self else { return nil }
            let inventory = self.services.physicalInventory
            let simulators = self.services.simulators
            let udid = entry.udid
            return try? PhysicalNativeMirrorSession.live(hardwareUDID: udid) {
                guard let client = await inventory.client(for: udid) else { throw PhysicalControlError.notReady }
                guard let toolchain = await simulators.probedToolchain() else {
                    throw PhysicalControlError.launchFailed("Xcode was not found")
                }
                return (client, toolchain)
            }
        }
        physicalLive.deviceScreenshot = { [weak self] udid in
            await self?.services.physicalDevices.takeScreenshot(udid: udid)
        }
        physicalLive.resetPose = { [weak self] in self?.simulatorCanvas.devicePose.reset() }
        physicalLive.settlePose = { [weak self] turns, animated in
            guard let pose = self?.simulatorCanvas.devicePose else { return }
            if animated { pose.settle(rotation: turns) } else { pose.snap(toTurns: turns) }
        }
        physicalLive.flash = { [weak self] message in self?.status.flash(message) }
        // The commands the menus and the pill call.
        physicalLive.control = physicalControl
        physicalLive.setLiveViewPreference = { [weak self] on in
            self?.services.preferences.setPhysicalLiveViewEnabled(on)
        }
        physicalLive.setAutoRefreshPreference = { [weak self] on in
            self?.services.preferences.setPhysicalAutoRefreshEnabled(on)
        }
        physicalLive.captureScreenshot = { [weak self] in
            await self?.capture.takeScreenshot()
        }
        physicalApps.selectedUDID = { [weak self] in
            if case .physicalApple(let udid)? = self?.deviceSelection { return udid }
            return nil
        }
        mirror.onPhysicalViewSessionStopped = { [weak self] session in
            self?.physicalLive.sessionStopped(session)
        }
        mirror.onPhysicalViewSessionPolled = { [weak self] session in
            self?.physicalLive.noteHealth(of: session)
        }
    }

    /// Shows the one-time team picker and waits for the answer (nil when the
    /// user cancels or closes it).
    func pickSigningTeam(_ teams: [SigningTeam]) async -> SigningTeam? {
        await withCheckedContinuation { continuation in
            window.teamPickerRequest = TeamPickerRequest(teams: teams) { continuation.resume(returning: $0) }
        }
    }

    /// "Control this iPhone": what it reads (the selection, the team), the
    /// runner it starts (only through the inventory's client, nil unless the
    /// device is enabled, paired and connected), and how it follows the
    /// physical view (`PhysicalLiveViewController.viewChanged`).
    private func wirePhysicalControl() {
        physicalControl.inputs = { [weak self] in
            guard let self else { return PhysicalControlController.Inputs() }
            var entry: ApplePhysicalEntry?
            if case .physicalApple(let udid)? = self.deviceSelection {
                entry = self.services.physicalInventory.entry(udid: udid)
            }
            return PhysicalControlController.Inputs(
                entry: entry,
                team: self.services.preferences.validPhysicalControlTeamID
            )
        }
        physicalControl.teamResolver = { [weak self] in
            guard let self else { throw PhysicalControlError.stopped }
            let preferences = self.services.preferences
            let resolver = SigningTeamResolver(
                stored: { await MainActor.run { preferences.validPhysicalControlTeamID } },
                store: { team in await MainActor.run { preferences.setPhysicalControlTeamID(team) } },
                detect: { try SigningTeamDetector.teams(from: KeychainCodeSigningCertificateSource()) },
                pick: { teams in await self.pickSigningTeam(teams) }
            )
            return try await resolver.resolve()
        }
        // The runner resolves its team when an action needs it, so it may
        // always take over from fast input.
        physicalControl.runnerMayTakeOver = { true }
        physicalControl.viewSession = { [weak self] udid in self?.physicalLive.session(for: udid) }
        physicalControl.makeControl = { [weak self] entry, team, onChange in
            guard let self else { throw PhysicalControlError.stopped }
            guard let client = await self.services.physicalInventory.client(for: entry.udid) else {
                throw PhysicalControlError.notReady
            }
            guard let toolchain = await self.services.simulators.probedToolchain() else {
                throw PhysicalControlError.launchFailed("Xcode was not found")
            }
            return try PhysicalControlSession.live(
                client: client,
                toolchain: toolchain,
                team: { team },
                onChange: onChange
            )
        }
        physicalControl.fastInputEnabled = { [weak self] in
            (self?.services.preferences.physicalFastInput ?? false) && !FastInputSession.isDisabled()
        }
        physicalControl.makeFastInput = { [weak self] entry in
            guard let self else { throw FastInputError.stopped }
            guard let client = await self.services.physicalInventory.client(for: entry.udid) else {
                throw FastInputError.notReady
            }
            guard let toolchain = await self.services.simulators.probedToolchain() else {
                throw FastInputError.launchFailed("Xcode was not found")
            }
            let session = try await FastInputSession.live(client: client, toolchain: toolchain)
            try await session.start()
            return session
        }
        physicalControl.deviceOrientation = { [weak self] udid in
            guard let self, let client = await self.services.physicalInventory.client(for: udid) else {
                throw PhysicalControlError.notReady
            }
            let name = try await client.orientation().value.deviceOrientation
            return name.flatMap(PhysicalControlOrientation.init(rawValue:)) ?? .unknown
        }
        physicalControl.setDeviceOrientation = { [weak self] udid, pose in
            guard let self, let client = await self.services.physicalInventory.client(for: udid) else {
                throw PhysicalControlError.notReady
            }
            try await client.setOrientation(pose)
        }
        physicalControl.settlePose = { [weak self] turns, animated in
            guard let pose = self?.simulatorCanvas.devicePose else { return }
            if animated { pose.settle(rotation: turns) } else { pose.snap(toTurns: turns) }
        }
        physicalControl.setControlCapabilities = { [weak self] on in
            guard let self, self.context.isPhysicalView else { return }
            self.context.capabilities = on
                ? PhysicalLiveViewController.capabilities.union(PhysicalControlController.controlCapabilities)
                : PhysicalLiveViewController.capabilities
        }
        physicalControl.flash = { [weak self] message in self?.status.flash(message) }
        physicalLive.viewChanged = { [weak self] in self?.physicalControl.syncWithView() }
        physicalLive.knownChromeTurns = { [weak self] in self?.physicalControl.knownChromeTurns }
        physicalLive.frameShapeChanged = { [weak self] in self?.physicalControl.refreshOrientation() }
    }

    /// The simulator canvas's session half: it starts and ends its
    /// sessions through the session hubs, and the mirror hands it a stopped
    /// session and asks the simulators for the simulator's display.
    private func wireSimulatorCanvasSession() {
        simulatorCanvas.beginSession = { [weak self] session, device, capabilities in
            self?.beginMirrorSession(session, device: device, port: nil, capabilities: capabilities)
        }
        simulatorCanvas.tearDownSession = { [weak self] cause in self?.tearDownMirror(cause: cause) }
        simulatorCanvas.activeDevice = { [weak self] in self?.context.device }
        simulatorCanvas.updateCapabilities = { [weak self] device, capabilities in
            guard let self, self.context.device == device else { return }
            self.context.capabilities = capabilities
        }
        simulatorCanvas.activeSession = { [weak self] in self?.mirror.session }
        mirror.onSimulatorSessionStopped = { [weak self] session in
            self?.simulatorCanvas.sessionStopped(session)
        }
        mirror.appleDisplayShapes = { [weak self] device in
            guard let self else { return [] }
            if let entry = self.services.simulators.entry(udid: device.id) {
                return self.services.simulators.displayShape(for: entry).map { [$0] } ?? []
            }
            // A physical iPhone's view: the display of the device type with
            // its model identifier.
            if let phone = self.services.physicalInventory.entry(udid: device.id),
               let shape = self.services.simulators.displayShape(forModelIdentifier: phone.device.productType) {
                return [shape]
            }
            return []
        }
    }

    /// Serial for the inspector Info panel: the live device if any, else the
    /// selected AVD's serial when it is known (`SelectionRouting`). This
    /// workspace's own `deviceSelection` over the shared device rows and AVD
    /// cards.
    var inspectorSerial: String? {
        SelectionRouting.inspectorSerial(for: deviceSelection, in: liveRoutingSnapshot)
    }

    /// Serial shown live in this workspace's stage for its own selection, if
    /// any (`SelectionRouting`).
    var liveSelectionSerial: String? {
        SelectionRouting.liveSelectionSerial(for: deviceSelection, in: liveRoutingSnapshot)
    }

    /// What the stage's routing reads for this workspace: the shared device
    /// rows, the shared AVD cards and the shared in-app starts (none of
    /// which differ between workspaces — only `deviceSelection` does).
    var liveRoutingSnapshot: SelectionRouting.Snapshot {
        SelectionRouting.Snapshot(
            devices: services.inventory.devices,
            avdCards: services.catalog.avdCards,
            startingAvdNames: services.boot.startingAvdNames
        )
    }

    /// The rest of the per-device features' hooks ("Open for
    /// steps 6–8"): everything `AppModel`'s own wire* methods used to reach
    /// only through `model.workspace` — `mirror.physicalModel`,
    /// `media.displayName`, `capture.*`, `window.*`, `controlsPanel.*`,
    /// `hardware.*`, `apps.*`, `location.*`, the logcat/clipboard `simctl`
    /// source, and `simulatorApps.*`/`appleControls.restartSimulator`/
    /// `media.simulatorVideoRecording` — now wired here, so a workspace
    /// built through `DeviceWorkspace.init(services:context:)` is fully
    /// wired without the model's help. `simulatorLifecycle`'s own
    /// `becameReady`/`screenContent` hooks stay app-level (one shared
    /// instance) but fan out to every registered workspace
    /// (`AppModel.wireSimulators`).
    private func wireAppHooks() {
        mirror.physicalModel = { [weak self] serial in
            self?.services.inventory.devices.first { $0.serial == serial }?.model
        }
        mirror.deviceFormFactor = { [weak self] serial in
            guard let inventory = self?.services.inventory else { return nil }
            // The running system's class; until its Info is read (a session
            // starts before that), the AVD's own image tag.
            if let read = inventory.deviceInfos[serial]?.formFactor, read != .handheld { return read }
            if let avd = inventory.avdNamesBySerial[serial]?.avd {
                return AvdConfig.formFactor(avdName: avd)
            }
            return inventory.deviceInfos[serial]?.formFactor
        }
        media.displayName = { [weak self] device in
            self?.services.displayName(of: device) ?? device.id
        }
        media.onRecordingSaved = { [weak self] url in self?.capture.showSavedRecording(at: url) }
        media.onReplaySaved = { [weak self] url in self?.capture.showSavedRecording(at: url, kind: .replay) }
        capture.onScreenshotSaved = { [weak self] in self?.media.noteCaptureTaken() }
        media.simulatorIsLiveCanvas = { [weak self] in
            guard let self, let udid = self.context.simulatorDevice?.id else { return true }
            return self.simulatorCanvas.session(for: udid)?.isLiveCanvas ?? true
        }
        media.isStageVisible = { [weak self] in self?.window.isStageVisible ?? true }
        capture.liveSelectionSerialProvider = {[weak self] in self?.liveSelectionSerial }
        capture.displayName = { [weak self] device in self?.services.displayName(of: device) ?? device.id }
        capture.displayShapesProvider = { [weak self] in self?.mirror.liveDisplayShapes ?? [] }
        capture.simulatorScreenshot = { [weak self] in
            guard let self else { return nil }
            // A physical iPhone's view captures its own frame (else a
            // `devicectl` screenshot); a simulator its canvas.
            if self.context.isPhysicalView, let device = self.context.device {
                return await self.physicalLive.screenshotPNG(udid: device.id)
            }
            return try await self.simulatorCanvas.screenshotPNG()
        }
        capture.appleChromeCapture = { [weak self] in
            guard let self, let device = self.context.device,
                  let frame = DeviceChromeResolver.appleChrome(
                      for: device,
                      simulators: self.services.simulators,
                      physical: self.services.physicalInventory
                  )
            else { return nil }
            return CaptureController.AppleChromeCapture(
                frame: frame,
                deviceTurns: self.simulatorCanvas.devicePose.targetTurns,
                reported: (self.mirror.session as? SimulatorMirrorSession)?.publishedRotation
            )
        }
        window.openDiagnosticsLogcat = { [weak self] in
            guard let self else { return }
            if let serial = self.liveSelectionSerial {
                self.logcat.openLogcatIfNeeded(serial: serial)
            } else if case .simulator(let udid)? = self.deviceSelection, self.services.simulatorLifecycle.isReady(udid) {
                self.logcat.openSimulatorLogIfNeeded(udid: udid)
            }
        }
        window.devicePixelSize = { [weak self] in
            self?.mirror.mirrorViewState.devicePixelSize
        }
        window.videoPointsPerPixel = { [weak self] in
            self?.mirror.mirrorViewState.videoPointsPerPixel
        }
        window.physicalPointsPerPixel = { [weak self] in
            self?.physicalPointsPerPixel()
        }
        window.pointAccuratePointsPerPixel = { [weak self] in
            self?.pointAccuratePointsPerPixel()
        }
        window.pixelAccuratePointsPerPixel = { [weak self] in
            self?.pixelAccuratePointsPerPixel()
        }
        controlsPanel.hasSession = { [weak self] in self?.mirror.session != nil }
        controlsPanel.isPostureBusy = { [weak self] in
            guard let self else { return false }
            return self.hardware.postureAnimationTask != nil || self.hardware.hingeSendTask != nil
        }
        controlsPanel.locationPolled = { [weak self] location in
            self?.location.primeLocationDraft(from: location)
        }
        hardware.resync = { [weak self] in await self?.mirror.session?.resync() }
        hardware.devicesSource = { [weak self] in self?.services.inventory.devices ?? [] }
        hardware.avdNameLookup = { [weak self] device in await self?.services.inventory.avdName(of: device) }
        apps.inspectorSerialSource = { [weak self] in self?.inspectorSerial }
        apps.activeSerialSource = { [weak self] in self?.context.serial }
        apps.packagesChanged = { [weak self] serial in
            self?.controlsPanel.forgetTalkBackPackage(ifSerial: serial)
            self?.conditions.packagesChanged(serial: serial)
            self?.links.packagesChanged(serial: serial)
        }
        location.currentFix = { [weak self] in self?.controlsPanel.controls.location }
        location.refreshControls = { [weak self] in await self?.controlsPanel.refreshControls() }
        // `adb root` / `adb unroot` restart adbd, which ends a logcat stream:
        // start it again, on the same app. The mirror (gRPC) and the other
        // adb calls (one-shot) need nothing.
        conditions.onAdbdRestarted = { [weak self] serial in self?.logcat.restartAfterAdbdRestart(serial: serial) }
        logcat.simctlSource = { [weak self] in self?.services.simulators.simctl }
        logcat.physicalClientSource = { [weak self] udid in
            await self?.services.physicalInventory.client(for: udid)
        }
        mirror.isStageVisible = { [weak self] in self?.window.isStageVisible ?? true }
        clipboard.isStageVisible = { [weak self] in self?.window.isStageVisible ?? true }
        clipboard.simctlSource = { [weak self] in self?.services.simulators.simctl }
        simulatorApps.recordRecentURL = { [weak self] url in self?.links.recents.record(url) }
        physicalApps.recordRecentURL = { [weak self] url in self?.links.recents.record(url) }
        // A new or removed app shows in the log's App picker while this
        // workspace's simulator log streams.
        simulatorApps.appsChanged = { [weak self] udid in
            Task { await self?.logcat.reloadSimulatorApps(udid: udid) }
        }
        appleControls.restartSimulator = { [weak self] udid in
            _ = await self?.services.simulatorLifecycle.restart(udid)
        }
        // A physical iPhone's Controls reach it only through the inventory.
        appleControls.physicalClient = { [weak self] udid in
            await self?.services.physicalInventory.client(for: udid)
        }
        media.simulatorVideoRecording = { [weak self] url in
            self?.simulatorCanvas.startViewOnlyRecording(to: url)
        }
    }

    // MARK: - Attach

    /// Attaches the right mirror transport for `device`: the emulator gRPC
    /// path for emulators, the scrcpy/H.264 physical path otherwise (spec
    /// §11.1). `DHP_FORCE_PHYSICAL=<serial>` (or `=1`) routes an emulator
    /// through the physical transport for live verification.
    ///
    /// The emulator path awaits the port resolution (adb console reads, `ps`,
    /// gRPC probes). An attach that was cancelled (its stage task went away)
    /// or superseded (the user selected something else, or a newer attach
    /// started) during that await ends silently: it neither selects its
    /// device back nor replaces the session, nor raises an alert for a device
    /// the user left.
    ///
    /// Returns how the attach ended (`AttachOutcome`); a failure's message is
    /// the one raised through the status center and parked in
    /// `mirror.mirrorAttach`.
    @discardableResult
    func mirror(device: AndroidDevice) async -> AttachOutcome {
        if let owner = registry?.owner(of: .android(device.serial)), owner !== self {
            return .ownedElsewhere(owner.id)
        }
        let generation = mirror.beginAttachRequest()
        guard device.isOnline else {
            return mirror.failAttach(serial: device.serial, "\(device.displayName) is \(device.stateLabel.lowercased()).")
        }

        let forcePhysical = services.launchOptions.forcesPhysicalTransport(serial: device.serial)
        if device.isEmulator, !forcePhysical {
            mirror.showAttaching(serial: device.serial)
            // Bounded: a wedged emulator can leave its gRPC calls unanswered
            // for good, and the attach would show "Attaching…" forever.
            let ports = services.grpcPorts
            let resolved = await BoundedWait.run(mirror.attachTimeout) { await ports.resolveGrpcPort(for: device) }
            guard !Task.isCancelled, mirror.isCurrentAttachRequest(generation) else {
                // Cancelled but not superseded: nothing else owns the state.
                if mirror.isCurrentAttachRequest(generation), mirror.mirrorAttach?.serial == device.serial {
                    mirror.clearAttach()
                }
                return .cancelled
            }
            guard let resolution = resolved else {
                return mirror.failAttach(serial: device.serial, MirrorController.attachTimedOutMessage(device.displayName))
            }
            switch resolution {
            case .success(let port):
                mirror.clearAttach()
                select(device)
                startSession(serial: device.serial, port: port)
                return .started
            case .failure(let failure):
                // Fail closed: the precise reason (e.g. multi-emulator
                // ambiguity) when the resolver has one, generic guidance
                // otherwise.
                return mirror.failAttach(
                    serial: device.serial,
                    failure.reason
                        ?? "Couldn't reach \(device.displayName)'s controls. Start the emulator from Device Hub Pro and try again."
                )
            }
        }

        guard services.adbClient != nil else {
            return mirror.failAttach(serial: device.serial, AdbError.adbNotFound.description)
        }
        mirror.clearAttach()
        select(device)
        startPhysicalSession(serial: device.serial)
        return .started
    }

    /// Retry for a mirror whose emulator stopped sending its screen: ends the
    /// session, forgets the port and attaches again.
    func reattachMirror(device: AndroidDevice) async {
        services.grpcPorts.invalidate(serial: device.serial)
        tearDownMirror(cause: .replaced)
        await mirror(device: device)
    }

    /// Shows a running device in the center stage, merging it with its AVD
    /// card when the serial belongs to a known AVD.
    func select(_ device: AndroidDevice) {
        deviceSelection = SelectionRouting.selection(
            for: device,
            in: SelectionRouting.Snapshot(avdCards: services.catalog.avdCards)
        )
    }

    /// The auto-resume hook (spec §5.2): re-validates the resume intent
    /// before `mirror`, then reports a failed attempt back to the lifecycle.
    func lifecycleResume(serial: String) async {
        let generation = context.sessionGeneration
        // Captured before the attempt: a machine-driven resume silences its
        // own failure (the waiting panel narrates it), a manual Reconnect's
        // does not — see `TransportErrorPolicy`.
        let isArmed = lifecycleIfRunning?.isAutoReconnectArmed(serial: serial) ?? false
        let errorBeforeResume = status.errorMessage
        let selection: String? = if case .device(let selected) = deviceSelection { selected } else { nil }
        // Pre-mirror re-check (spec §5.2, "intent invalid … → no action"):
        // the resume task can run after the user moved on or a newer session
        // landed, and `mirror` would `select` + `beginMirrorSession` over the
        // user's fresh session — bail before it does.
        guard DeviceLifecycleCoordinator.shouldApplyLifecycleEffect(
            isCancelled: Task.isCancelled,
            isCurrentGeneration: generation == context.sessionGeneration
        ), selection == serial else { return }
        guard let device = services.inventory.devices.first(where: { $0.serial == serial }) else { return }
        let outcome = await mirror(device: device)
        guard DeviceLifecycleCoordinator.shouldApplyLifecycleEffect(
            isCancelled: Task.isCancelled,
            isCurrentGeneration: generation == context.sessionGeneration
        ) else { return }
        if mirror.session == nil {
            // The attempt failed: record it for the panel's Details — from
            // the outcome, so a failure the alert already shows is recorded
            // too — and raise it only when this resume was not
            // machine-driven (S2). Only an alert this attempt changed is
            // taken back.
            if case .failed(let failure) = outcome {
                mirror.recordTransportFailure(failure)
            }
            if let failure = status.errorMessage, failure != errorBeforeResume,
               !TransportErrorPolicy.shouldSurface(isAutoReconnectArmed: isArmed) {
                status.errorMessage = nil
            }
            lifecycleIfRunning?.noteResumeFailed(serial: serial)
        }
    }

    // MARK: - Session hubs

    /// Starts the emulator gRPC mirror. `avdName` is passed when the caller
    /// already knows the AVD (it just started it); otherwise the console is
    /// asked.
    func startSession(serial: String, port: Int, avdName: String? = nil) {
        let newSession = mirror.makeEmulatorSession(serial: serial, port: port)
        beginMirrorSession(
            newSession,
            device: .android(serial),
            port: port,
            avdName: avdName,
            capabilities: .android(emulatorGrpc: true)
        )
    }

    /// Starts the scrcpy-backed mirror for a non-emulator adb device. There is
    /// no gRPC control channel, so the emulator-only extras (audio, extended
    /// controls) stay off; the stage, capture, replay and recording flows run
    /// on the shared session surface, and the clipboard travels over scrcpy's
    /// control channel.
    func startPhysicalSession(serial: String) {
        guard let physical = mirror.makePhysicalSession(serial: serial) else { return }
        beginMirrorSession(
            physical,
            device: .android(serial),
            port: nil,
            capabilities: .android(emulatorGrpc: false)
        )
    }

    /// The begin hub, for a session on any platform: the previous session
    /// is torn down, the context names `device` with its `capabilities`,
    /// and the frames, stats and clipboard sync start. Returns false and
    /// changes nothing when `device` is another workspace's session already
    /// — `mirror(device:)` checks this ahead of the async
    /// attach for the Android path so it can show the placeholder instead
    /// of failing, and this is the last-line defence for every other caller
    /// (the simulator canvas's own attach, a resume, a direct call).
    ///
    /// The Android machinery runs for an Android device only: the
    /// lifecycle's episode (which would read an Apple device missing from
    /// adb as a disconnect, tear the session down and leave a ghost row), the
    /// gRPC port and what hangs on it, the AVD, and the Controls conditions.
    /// A `port` or `avdName` passed with an Apple device is not recorded.
    /// An Apple session still ends the lifecycle's episode about the Android
    /// session it replaces, as an Android start does: otherwise that
    /// device's later unplug would tear the Apple session down.
    @discardableResult
    func beginMirrorSession(
        _ newSession: any MirrorSessionProtocol,
        device: DeviceRef,
        port: Int?,
        avdName: String? = nil,
        capabilities: DeviceCapabilities
    ) -> Bool {
        // Honours `claim` before anything here changes:
        // a device another workspace's session already owns is refused —
        // this workspace's own session, if any, is left running. Claimed
        // now, ahead of the teardown below, so the device is never briefly
        // unclaimed between this workspace's old session ending and the
        // new one starting.
        guard registry?.claim(device, for: self) ?? true else { return false }
        let isAndroid = device.platform == .android
        tearDownMirror(cause: .replaced)
        context.device = device
        context.capabilities = capabilities
        context.isPhysicalView = newSession is any PhysicalViewSession
        context.sessionGeneration += 1
        context.controlsGeneration &+= 1
        if let serial = device.adbSerial {
            lifecycleIfRunning?.noteMirrorStarted(serial: serial)
        } else {
            lifecycleIfRunning?.noteNonAdbMirrorStarted()
        }
        context.port = isAndroid ? port : nil
        mirror.stagePose.reset()
        mirror.mirrorViewState = MirrorViewState()
        // A physical view starts from the picture the device showed last
        // (and its size), never from the previous device's geometry.
        if context.isPhysicalView {
            mirror.beginSeedPicture(for: device)
        } else {
            mirror.clearSeedPicture()
        }
        context.avdName = isAndroid ? avdName : nil
        if avdName == nil, let serial = device.adbSerial, serial.hasPrefix("emulator-") {
            lookUpActiveAvdName(serial: serial)
        }

        mirror.session = newSession
        newSession.start()
        if newSession is any PhysicalSessionControlling, let serial = device.adbSerial {
            mirror.restorePendingRotation(serial: serial, aliases: services.inventory.serialAliases)
        }
        if context.port != nil {
            let controller = mirror
            Task { await controller.followEmulatorDevicePose(snapping: true) }
        }
        updateFrameFeed()
        mirror.startStatsPolling()
        clipboard.attach(physical: mirror.activePhysicalSession)
        if isAndroid {
            conditions.attach()
        }
        noteSessionCapIfExceeded()

        // A physical iPhone's live audio follows the same policy;
        // the port-less branch below never reaches it.
        physicalLive.applyAudio()
        // A session that replaces the one Control drives (a permission
        // granted, the plan changed) keeps Control's capabilities.
        if physicalControl.isReady, newSession is any PhysicalViewSession {
            context.capabilities.formUnion(PhysicalControlController.controlCapabilities)
        }

        // Attaching leaves the device's rotation settings alone: the lock is
        // released only for an explicit rotate (`rotateDevice`).
        guard context.port != nil else { return true }
        extras.attach()
        hardware.startResizePresetsLoad()
        applyAudioPolicy()
        return true
    }

    /// The begin hub's frame feed start: the new session's frames go to the
    /// replay ring and the recorder.
    private func updateFrameFeed() {
        guard let session = mirror.session else { return }
        media.attach(frames: session.frames)
    }

    /// Whether this workspace's in-app audio should be playing right now:
    /// Settings' mode is In-App, this workspace mirrors an emulator, and
    /// (with multiple windows enabled) this is the focused workspace — or
    /// multi-window is off, or nothing has become key yet, in which case
    /// every workspace plays, exactly as before step 9 (single-window mode
    /// has nothing else to defer to). Exposed separately from
    /// `applyAudioPolicy` so the decision can be checked without touching
    /// `AudioPlayer`'s real `AVAudioEngine`.
    var shouldPlayInAppAudio: Bool {
        guard services.preferences.emulatorAudioMode == .inApp, context.port != nil else { return false }
        return isFocusedForAudio
    }

    /// Whether this workspace is the one whose audio plays: multi-window is
    /// off, nothing has become key yet, or this is the focused workspace.
    private var isFocusedForAudio: Bool {
        !services.launchOptions.multiWindowEnabled
            || registry?.focusedID == nil
            || registry?.focusedID == id
    }

    /// What the audio policy says about a physical iPhone's live audio:
    /// the same two rules as the emulator's in-app audio, with
    /// one difference in the setting. An emulator's Settings mode "Emulator"
    /// means the emulator itself plays through the host; a phone has no such
    /// player, so the phone's audio is played by the app in "Emulator" and
    /// "In-app" alike and only "Disabled" silences it. With multiple windows
    /// only the focused workspace's phone plays.
    var physicalAudioPolicy: PhysicalAudioPolicy {
        guard services.preferences.emulatorAudioMode != .disabled else { return .disabledInSettings }
        return isFocusedForAudio ? .plays : .otherWindowFocused
    }

    /// Applies `shouldPlayInAppAudio` to this workspace's in-app audio:
    /// only the focused workspace's mirror plays; every
    /// other workspace mutes. Switching focus moves the audio without
    /// restarting the session — `AudioPlayer.start`/`stop` only start or
    /// stop the audio stream, the mirror session itself is untouched.
    ///
    /// Called after a session starts (`beginMirrorSession`), on every focus
    /// change (`WorkspaceRegistry.focusedID`) and when Settings' audio mode
    /// changes (`AppModel.setEmulatorAudioMode`).
    func applyAudioPolicy() {
        physicalLive.applyAudio()
        guard shouldPlayInAppAudio, let port = context.port else {
            mirror.audioPlayer.stop()
            return
        }
        guard !mirror.audioPlayer.isRunning else { return }
        mirror.audioPlayer.start(port: port)
    }

    /// The soft session cap (cap 4, the multi-window switch (`DHP_MULTIWINDOW`, on unless 0)
    /// only): the session just started here counts toward the registry's
    /// live total; past 4, `window.sessionCapWarning` offers to stop
    /// whichever other workspace was focused longest ago. Never blocks —
    /// this workspace's own session is already running by the time this
    /// runs, and nothing here stops it or any other.
    private func noteSessionCapIfExceeded() {
        guard services.launchOptions.multiWindowEnabled, let registry else { return }
        guard registry.liveSessionCount > Self.softSessionCap else { return }
        guard let candidate = registry.leastRecentlyFocused(excluding: id) else { return }
        let candidateName = candidate.context.device.map(services.displayName(of:)) ?? "another window"
        window.sessionCapWarning = WindowState.SessionCapWarning(
            leastRecentlyFocusedID: candidate.id,
            leastRecentlyFocusedName: candidateName
        )
    }

    private static let softSessionCap = 4

    /// Resolves the soft session cap's warning (its alert's two buttons):
    /// `stop: true` is Stop & Continue (ends the suggested workspace's
    /// session), `false` is Continue Anyway (just dismisses it). Either way
    /// this workspace's own session, already running, is untouched.
    func resolveSessionCapWarning(stop: Bool) {
        guard let warning = window.sessionCapWarning else { return }
        if stop {
            registry?.workspace(for: warning.leastRecentlyFocusedID)?.stopMirror()
        }
        window.sessionCapWarning = nil
    }

    /// The user's Stop Mirror (menus, the stage). Tells the lifecycle, so a
    /// later unplug/replug of the device neither shows a ghost nor resumes
    /// the mirror, and hands a running recording to the save panel. The
    /// app's own teardowns (the lifecycle's, a fatal stream, a device switch,
    /// quit) use `tearDownMirror(cause:)`.
    /// The waiting panel's "Reconnect" (spec §5.2): this workspace's own
    /// coordinator resumes at once. Being user initiated it clears the auto
    /// marker, so a failure during this attempt still reaches the alert
    /// surface. Nil unless the watcher is running, like every other
    /// lifecycle entry point.
    func requestReconnect(serial: String) {
        lifecycleIfRunning?.noteReconnectRequested(serial: serial)
    }

    func stopMirror() {
        // The lifecycle decides Android episodes only: the serial is nil
        // for an Apple device.
        if let serial = context.serial {
            lifecycleIfRunning?.noteMirrorStopped(serial: serial)
        }
        tearDownMirror(cause: .userStop)
    }

    /// Ends the active mirror session and everything bound to it: the
    /// recording (finalized, never discarded — see `RecordingEnd`), the frame
    /// feed, clipboard sync, the extended-controls poll, every per-device
    /// worker, audio, the stats poll, the transport itself and the emulator's
    /// shared control connection.
    ///
    /// The gRPC port cache, the control connection and the Controls
    /// conditions are an Android device's: the context's serial is adb-only
    /// and its port emulator-only, and the conditions are left alone for an
    /// Apple device, so its teardown reaches none of them.
    func tearDownMirror(cause: MirrorTeardownCause) {
        context.sessionGeneration += 1
        context.controlsGeneration &+= 1
        let deviceName = context.device.map(services.displayName(of:)) ?? "the device"
        switch cause {
        case .userStop, .replaced, .windowClosed:
            media.endRecording(.user)
        case .disconnected:
            media.endRecording(.interrupted("\(deviceName) disconnected"))
        case .transportFatal:
            media.endRecording(.interrupted("the connection to \(deviceName) failed"))
        case .quit:
            media.endRecording(.quit)
        }
        if let serial = context.serial {
            services.grpcPorts.invalidate(serial: serial)
        }
        // The frame feed: the poll stops and the ring is dropped.
        media.detach()
        clipboard.detach()
        extras.stopPolling()
        cancelDeviceWork()
        mirror.audioPlayer.stop()
        mirror.stopStatsPolling()
        if context.isPhysicalView, let device = context.device {
            mirror.rememberLastPicture(for: device)
        }
        // "Control this iPhone" ends with the view session it drives; a
        // replaced session is followed by the next reconcile
        // (`physicalLive.viewChanged`), which moves or ends Control.
        if cause != .replaced {
            physicalControl.viewSessionEnded(quit: cause == .quit)
        }
        mirror.stopSession(cause: cause)
        if let port = context.port {
            // Released now instead of by the pool's idle sweep; in-flight
            // calls (a keyboard clipboard restore) still finish.
            Task { await EmulatorControls.closeConnections(port: port) }
        }
        mirror.session = nil
        mirror.clearSeedPicture()
        physicalLive.applyAudio()
        // Forgets the ended session's stream state: the error already
        // raised, the transport failure, the health episode, the stream
        // warning and the stats line.
        mirror.resetMirrorHealth()
        // Before the context forgets the serial: puts back the memory
        // factor and the network conditions Device Hub Pro set on the device
        // being left. An Apple device has none of them.
        if context.device?.platform != .apple {
            conditions.detach()
        }
        links.detach()
        if let device = context.device {
            registry?.release(device, for: self)
        }
        context.clear()
        // Empties the Controls panel for the next device: its state, the
        // settings rows, the loaded flag and the unresponsive-poll count.
        controlsPanel.detach()
    }

    /// The window-close path: tears the session down
    /// first — `.windowClosed` finalizes a running recording like `.user`
    /// and tells the lifecycle (`noteMirrorStopped`, the same as
    /// `stopMirror()`) so a later replug of the device neither ghosts nor
    /// auto-resumes it into a window that no longer exists — then leaves
    /// the registry. Never the reverse: `WorkspaceRegistry.unregister` on
    /// its own only defends against a caller that forgot this (a `.replaced`
    /// teardown), it does not tell the lifecycle the user stopped anything.
    /// The caller (the window's close/delegate handling) asks "Stop
    /// recording and save?" before calling this, so by the time it runs
    /// there is nothing left to confirm.
    func closeForWindow() {
        if let serial = context.serial {
            lifecycleIfRunning?.noteMirrorStopped(serial: serial)
        }
        tearDownMirror(cause: .windowClosed)
        // A compact window of this workspace goes with it, without bringing
        // back the main window that is closing.
        if let compact = window.compactNSWindow {
            window.mainWindowHiddenForCompact = nil
            compact.close()
        }
        registry?.unregister(self)
    }

    /// The app's quit, first half: tears the session down as
    /// `tearDownMirror(cause: .quit)` does, in the same order, except that
    /// the transport's bounded blocking stop (a physical session's sockets
    /// and device server, a live simulator session's queues) starts on a
    /// background thread instead of blocking the main actor. Returns it to
    /// await, nil when the session had none, so quit begins every window's
    /// stop before it waits for any.
    func beginQuitTeardown() -> Task<Void, Never>? {
        mirror.defersQuitStop = true
        defer { mirror.defersQuitStop = false }
        tearDownMirror(cause: .quit)
        let mirrorStop = mirror.takeQuitStop()
        // The runner on the phone stops too (its `POST /stop`, then the
        // child), bounded by the quit's own timeout.
        let controlStop = physicalControl.takeStopTask()
        let rotationRestore = mirror.takeRotationRestore()
        guard mirrorStop != nil || controlStop != nil || rotationRestore != nil else { return nil }
        return Task {
            await mirrorStop?.value
            await controlStop?.value
            await rotationRestore?.value
        }
    }

    /// Cancels every per-device worker and forgets per-device state, so
    /// nothing reaches the next device and none of it shows there: the
    /// emulator hardware workers, the Sound knob's live volume stepping,
    /// the extended controls' per-device state, the Location draft (handed
    /// back to the Controls poll) and whose TalkBack package was read.
    private func cancelDeviceWork() {
        hardware.detach()
        controlsPanel.stopLiveVolumeStepping()
        extras.detach()
        location.detach()
        controlsPanel.forgetTalkBackPackage()
    }

    // MARK: - Rotation

    /// A quarter turn of the mirrored device: an Apple device's through the
    /// simulator canvas, an Android one's through the mirror.
    func rotateDevice(_ direction: RotationDirection) async {
        // A physical iPhone turns through `devicectl device orientation set`
        // (no runner, no Control needed).
        if context.isPhysicalView {
            physicalControl.rotate(direction)
            return
        }
        if context.device?.platform == .apple {
            await simulatorCanvas.rotate(direction)
            return
        }
        await mirror.rotateDevice(direction)
    }

    // MARK: - AVD name

    /// Asks the emulator's console which AVD the new session shows.
    private func lookUpActiveAvdName(serial: String) {
        let generation = context.sessionGeneration
        Task { [weak self] in
            guard let self else { return }
            let name: String?
            if let device = self.services.inventory.devices.first(where: { $0.serial == serial }) {
                name = await self.services.inventory.avdName(of: device)
            } else if let adbClient = self.services.adbClient {
                // Best effort: an unanswered console leaves the AVD unknown.
                name = try? await adbClient.avdName(serial: serial)
            } else {
                name = nil
            }
            self.applyActiveAvdName(name, serial: serial, generation: generation)
        }
    }

    /// The console's answer lands only on the session it was asked for: a
    /// slow answer about the previous emulator must not name the new one
    /// (Stop Emulator would then stop the VM the user is not looking at).
    func applyActiveAvdName(_ name: String?, serial: String, generation: Int) {
        guard generation == context.sessionGeneration, serial == context.serial else { return }
        context.avdName = name
        // Shapes read before the console answered are the AVD's too.
        mirror.recordDisplayShapes()
    }
}


// MARK: - Physical size (TB-08)

extension DeviceWorkspace {
    /// Mac points per streamed pixel that show this device at its real size
    /// on the screen the window is on: the screen's points per inch over the
    /// panel's pixels per inch (`ZoomMath.physicalPointsPerPixel`). Nil until
    /// the stream's size and the panel's density are known (an AVD's `xDpi`
    /// comes from `dumpsys display`, a simulator's `hdpi` from its device
    /// type).
    func physicalPointsPerPixel() -> Double? {
        guard let pixels = mirror.mirrorViewState.devicePixelSize, pixels.width > 0, pixels.height > 0 else {
            return nil
        }
        let shape = DisplayShape.matching(frame: pixels, in: mirror.liveDisplayShapes)
        guard let dpi = ZoomMath.devicePixelsPerInch(
            xDpi: shape?.xDpi,
            densityDpi: shape?.densityDpi,
            fallback: mirror.mirrorViewState.displayDensityDpi.map(Double.init)
        ) else { return nil }
        return ZoomMath.physicalPointsPerPixel(
            macPointsPerInch: Self.macPointsPerInch(),
            devicePixelsPerInch: dpi,
            panelLongSide: shape.map { Double(max($0.width, $0.height)) },
            streamLongSide: Double(max(pixels.width, pixels.height))
        )
    }

    /// Mac points per streamed pixel that show one device point (one dp on
    /// Android) per Mac point: Simulator.app's Point Accurate. The device's
    /// scale is its density over 160 (an iOS simulator's `densityDpi` is
    /// `160 * scale`), counted on the panel's pixels and carried to the
    /// stream's. Nil until the stream and the density are known.
    func pointAccuratePointsPerPixel() -> Double? {
        guard let pixels = mirror.mirrorViewState.devicePixelSize, pixels.width > 0, pixels.height > 0 else {
            return nil
        }
        let shape = DisplayShape.matching(frame: pixels, in: mirror.liveDisplayShapes)
        let density = shape?.densityDpi ?? mirror.mirrorViewState.displayDensityDpi
        return ZoomMath.pointAccuratePointsPerPixel(
            densityDpi: density.map(Double.init),
            panelLongSide: shape.map { Double(max($0.width, $0.height)) },
            streamLongSide: Double(max(pixels.width, pixels.height))
        )
    }

    /// Mac points per streamed pixel that show one device pixel per Mac
    /// screen pixel: Simulator.app's Pixel Accurate, on the window's backing
    /// scale (2 on a Retina screen). Nil before the first frame.
    func pixelAccuratePointsPerPixel() -> Double? {
        guard let pixels = mirror.mirrorViewState.devicePixelSize, pixels.width > 0, pixels.height > 0 else {
            return nil
        }
        let shape = DisplayShape.matching(frame: pixels, in: mirror.liveDisplayShapes)
        return ZoomMath.pixelAccuratePointsPerPixel(
            backingScaleFactor: Self.backingScaleFactor(),
            panelLongSide: shape.map { Double(max($0.width, $0.height)) },
            streamLongSide: Double(max(pixels.width, pixels.height))
        )
    }

    /// The backing scale of the key window's screen (the main screen's
    /// without one).
    static func backingScaleFactor() -> Double {
        let factor = NSApp?.keyWindow?.backingScaleFactor
            ?? NSApp?.mainWindow?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        return Double(factor)
    }

    /// The Mac's points per inch on the key window's screen (the main
    /// screen without one).
    static func macPointsPerInch() -> Double {
        let screen = NSApp?.keyWindow?.screen ?? NSApp?.mainWindow?.screen ?? NSScreen.main
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return 110 }
        let size = CGDisplayScreenSize(CGDirectDisplayID(number.uint32Value))
        return ZoomMath.macPointsPerInch(
            screenWidthMillimetres: size.width,
            screenWidthPoints: Double(screen.frame.width)
        )
    }
}

// MARK: - Resize mode

extension DeviceWorkspace {
    /// Whether the live mirror session is the selected device's. A session can
    /// outlive the selection that started it (an Android mirror keeps running
    /// after another row, or nothing, is selected), and the toolbar's zoom,
    /// keyboard and resize buttons must not treat it as the selection's:
    /// with No Selection, or a stopped simulator selected, Device Hub dims
    /// them.
    var selectedDeviceHasSession: Bool {
        guard mirror.session != nil, contextIsSelection else { return false }
        return Self.sessionBelongs(
            to: deviceSelection,
            sessionDevice: context.device,
            isPhysicalView: context.isPhysicalView
        )
    }

    /// The pure half of `selectedDeviceHasSession`.
    nonisolated static func sessionBelongs(to selection: DeviceSelection?, sessionDevice: DeviceRef?, isPhysicalView: Bool) -> Bool {
        guard let selection, let sessionDevice else { return false }
        switch selection {
        case .simulator(let udid):
            return sessionDevice.platform == .apple && !isPhysicalView && sessionDevice.id == udid
        case .physicalApple(let udid):
            return sessionDevice.platform == .apple && isPhysicalView
                && sessionDevice.id.caseInsensitiveCompare(udid) == .orderedSame
        case .avd, .device:
            // An Android selection is live through `liveSelectionSerial`; its
            // session is the Android one.
            return sessionDevice.platform == .android
        case .pixel:
            return false
        }
    }

    /// Whether the shown device can be put in resize mode: an emulator with
    /// a resizable display, which is the one whose console offers display
    /// presets (`EmulatorHardwareController.refreshResizePresets`). Device
    /// Hub disables "Enter resize mode" for every simulator (iPhone, iPad,
    /// Apple TV measured on Xcode 27.0), and so do we; a physical device
    /// has no display to resize.
    var canEnterResizeMode: Bool {
        selectedDeviceHasSession && !hardware.resizePresets.isEmpty
    }

    /// Whether resize mode is listed for the shown device at all (the toolbar button,
    /// Device ▸ Enter Resize Mode): only an AVD with a resizable display, or an emulator
    /// the console already gave presets for. A simulator, a physical device, a phone and a
    /// non-resizable AVD never offer it; a stopped resizable AVD keeps it, dimmed.
    var offersResizeMode: Bool {
        switch deviceSelection {
        case .avd(let name)?: hardware.isResizableAvd(name) || !hardware.resizePresets.isEmpty
        case .device?: !hardware.resizePresets.isEmpty
        default: false
        }
    }

    /// Resize mode is on and still possible (the presets can vanish with the
    /// session while the window's flag stays set).
    var isInResizeMode: Bool {
        window.isResizeModeActive && canEnterResizeMode
    }
}

extension DeviceWorkspace {
    /// The device the stage's Send Files drop and the Device menu's Send
    /// Files… act on: the mirrored Android device, the shown simulator, or an
    /// enabled, connected physical iPhone's view; nil when none can take files.
    func stageSendFilesTarget(physical: ApplePhysicalInventory) -> SendFilesController.Target? {
        // Only the selected row's device: another tab's emulator selected
        // here must not send to the one this tab still mirrors.
        guard contextIsSelection else { return nil }
        if let device = context.simulatorDevice { return .simulator(udid: device.id) }
        if context.isPhysicalView, let device = context.device {
            return physical.entry(udid: device.id)?.canUseClient == true ? .physical(udid: device.id) : nil
        }
        if let serial = context.serial { return .android(serial: serial) }
        return nil
    }
}


// MARK: - Stay on Top

extension DeviceWorkspace {
    /// Window ▸ Stay on Top for the main window (`compact: false`) or the
    /// compact mirror: keeps the choice per window, applies the window level
    /// now, and remembers it as the start state of new windows.
    func setStaysOnTop(_ on: Bool, compact: Bool) {
        if compact {
            window.compactStaysOnTop = on
            WindowLevel.apply(onTop: on, to: window.compactNSWindow)
        } else {
            window.staysOnTop = on
            WindowLevel.apply(onTop: on, to: window.mainNSWindow)
        }
        services.preferences.setStayOnTop(on, compact: compact)
    }
}

/// The window level Stay on Top sets.
enum WindowLevel {
    /// `.floating` keeps a window above ordinary ones, `.normal` is the rest.
    static func level(onTop: Bool) -> NSWindow.Level { onTop ? .floating : .normal }

    @MainActor
    static func apply(onTop: Bool, to window: NSWindow?) {
        guard let window else { return }
        let level = level(onTop: onTop)
        if window.level != level { window.level = level }
        // A floating panel-like window should not vanish when the app is
        // inactive; a normal one keeps AppKit's default.
        window.hidesOnDeactivate = false
    }
}
