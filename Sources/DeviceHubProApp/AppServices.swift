import Foundation
import DeviceHubProKit

/// The app-global tools and lists a `DeviceWorkspace` reads: adb,
/// the launch options, the settings, the status line, the device rows with
/// their lifecycle, the AVD cards, the gRPC ports, the simulators, and the
/// stores every window shares (display shapes, what is kept per simulator,
/// the recording finalizer). `AppModel` builds it from the instances it
/// owns; a workspace holds it, never the model, and builds its own
/// per-device features from it (`DeviceWorkspace.init(services:)`).
@MainActor
final class AppServices {
    let adbClient: AdbClient?
    /// The `DHP_*` development hooks the model was built with.
    let launchOptions: LaunchOptions
    let preferences: AppPreferences
    let status: StatusCenter
    /// The adb rows, the consoles' AVD names and the hot-plug lifecycle.
    let inventory: DeviceInventory
    /// The AVD cards (a running device's row merges with its card).
    let catalog: AvdCatalogController
    let grpcPorts: GrpcPortService
    let simulators: SimulatorInventory
    /// The physical iPhones and iPads behind "Show physical Apple devices":
    /// the opt-in listing, each device's enabled state and its
    /// client. App-global, like the simulators.
    let physicalInventory: ApplePhysicalInventory
    /// What the app does with an enabled physical device (Info card,
    /// screenshot, recording, what it reported unsupported).
    let physicalDevices: ApplePhysicalController
    /// The simulators' boot/shutdown/erase/rename/delete/clone lifecycle and
    /// readiness — shared app-global (one simulator has one lifecycle
    /// whichever window looks at it), read here so a workspace's own wiring
    /// can reach `isReady`/`restart` without going through the model.
    let simulatorLifecycle: SimulatorLifecycleController
    /// AVD boot bookkeeping (the starts in flight, the clock) — shared
    /// app-global, read here for `startingAvdNames` (a workspace's own
    /// live-selection routing).
    let boot: EmulatorBootController
    /// What the workspace's features are built on: the defaults, the
    /// pasteboard, the save panel and the perf log.
    let environment: AppEnvironment
    let displayShapes: DisplayShapeLibrary
    let appleDeviceMemory: AppleDeviceMemory
    let simulatorCanvasMemory: SimulatorCanvasMemory
    /// Finishes ended recordings; app-scoped, because a clip outlives the
    /// session (and the window) it recorded and quit waits for it.
    let recordingFinalizer: RecordingFinalizer
    /// The recent APKs and links, one list each for every window: each
    /// store keeps its list in memory and writes it whole, so two copies
    /// over one defaults would drop each other's entries.
    let recentAPKs: RecentAPKStore
    let recentLinks: RecentLinkStore
    /// The single app-wide Mac-pasteboard poll behind every workspace's
    /// clipboard auto-sync: one read per tick, fanned out
    /// to every workspace, instead of one per window.
    let clipboardPoll: ClipboardPasteboardPoll

    init(
        adbClient: AdbClient?,
        launchOptions: LaunchOptions,
        preferences: AppPreferences,
        status: StatusCenter,
        inventory: DeviceInventory,
        catalog: AvdCatalogController,
        grpcPorts: GrpcPortService,
        simulators: SimulatorInventory,
        physicalInventory: ApplePhysicalInventory,
        physicalDevices: ApplePhysicalController,
        simulatorLifecycle: SimulatorLifecycleController,
        boot: EmulatorBootController,
        environment: AppEnvironment,
        displayShapes: DisplayShapeLibrary,
        appleDeviceMemory: AppleDeviceMemory,
        simulatorCanvasMemory: SimulatorCanvasMemory,
        recordingFinalizer: RecordingFinalizer
    ) {
        self.adbClient = adbClient
        self.launchOptions = launchOptions
        self.preferences = preferences
        self.status = status
        self.inventory = inventory
        self.catalog = catalog
        self.grpcPorts = grpcPorts
        self.simulators = simulators
        self.physicalInventory = physicalInventory
        self.physicalDevices = physicalDevices
        self.simulatorLifecycle = simulatorLifecycle
        self.boot = boot
        self.environment = environment
        self.displayShapes = displayShapes
        self.appleDeviceMemory = appleDeviceMemory
        self.simulatorCanvasMemory = simulatorCanvasMemory
        self.recordingFinalizer = recordingFinalizer
        self.recentAPKs = RecentAPKStore(defaults: environment.defaults)
        self.recentLinks = RecentLinkStore(defaults: environment.defaults)
        self.clipboardPoll = ClipboardPasteboardPoll(pasteboard: environment.pasteboard, isAppActive: environment.isAppActive)
    }

    /// A device's name the way the device list shows it: an adb device's
    /// row name, else its serial; a simulator's name, else its UDID; a
    /// physical Apple device's name, else "Apple Device" (its hardware UDID
    /// is never shown).
    func displayName(of device: DeviceRef) -> String {
        guard let serial = device.adbSerial else {
            if let physical = physicalInventory.entry(udid: device.id) { return physical.name }
            return simulators.entry(udid: device.id)?.name ?? device.id
        }
        // An emulator is named after its AVD ("Pixel_10_Pro"), not the model
        // the image reports ("sdk_gphone16k_arm64"), as the sidebar does.
        if let card = catalog.avdCards.first(where: { $0.serial == serial }) { return card.displayName }
        return inventory.devices.first(where: { $0.serial == serial })?.displayName ?? serial
    }
}

/// The single app-wide Mac-pasteboard poll behind clipboard auto-sync.
/// Before this, every workspace's
/// `ClipboardSyncController.attach` ran its own timer that read the real
/// pasteboard on its own beat to drive the Mac → device direction; with
/// several windows syncing at once that was one real `NSPasteboard` read
/// per window per tick, all for the same text. This reads it once per
/// `interval` and fans the text out to every workspace's controller
/// (`applyMacPasteboardPoll`), which pushes it to whichever device that
/// workspace has attached (or does nothing, with sync off or nothing
/// attached). It never touches the Mac → device direction's semantics —
/// each controller still decides on its own echo state whether the text is
/// new and where it goes; only where the poll itself runs is shared. The
/// on-demand Send/Pull actions and the device → Mac direction are
/// unaffected: they read/write the real pasteboard directly, each device
/// still on its own cadence (it differs per device).
@MainActor
final class ClipboardPasteboardPoll {
    private let pasteboard: any MacPasteboard
    private let interval: Duration
    /// Whether the app is frontmost: a copy made in another app only
    /// matters once the user is back here, so the pasteboard is not read
    /// while the app is in the background.
    private let isAppActive: @MainActor () -> Bool
    private var task: Task<Void, Never>?

    init(
        pasteboard: any MacPasteboard,
        interval: Duration = .milliseconds(1200),
        isAppActive: @escaping @MainActor () -> Bool = { true }
    ) {
        self.pasteboard = pasteboard
        self.interval = interval
        self.isAppActive = isAppActive
    }

    /// Starts the one poll, if it is not already running: idempotent, so
    /// it can be started from `AppModel.init` without extra bookkeeping.
    func start(registry: WorkspaceRegistry) {
        guard task == nil else { return }
        task = Task { [weak self, weak registry] in
            guard let self else { return }
            while !Task.isCancelled {
                // Best effort: the sleep fails only on cancellation, checked next.
                try? await Task.sleep(for: self.interval)
                guard !Task.isCancelled else { return }
                // Nothing to push with auto-sync off everywhere, and nothing
                // new to see while the app is in the background.
                let workspaces = registry?.workspaces ?? []
                guard self.isAppActive(), workspaces.contains(where: { $0.clipboard.isAutoSyncOn }) else { continue }
                let text = self.pasteboard.string()
                for workspace in workspaces {
                    workspace.clipboard.applyMacPasteboardPoll(text)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
