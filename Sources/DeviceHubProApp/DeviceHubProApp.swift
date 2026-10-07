import DeviceHubProKit
import AppKit
import SwiftUI

@main
struct DeviceHubProApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel(environment: .live())
    @State private var avdActionDialogs = AvdActionDialogs()
    @State private var appActionDialogs = AppActionDialogs()
    @State private var simulatorActionDialogs = SimulatorActionDialogs()
    @State private var updater = AppUpdater()

    // `if`/`else` between two different `Scene` combinations does not build
    // under this SDK (`SceneBuilder` rejects any control-flow statement in a
    // `Scene`-returning closure, confirmed with a minimal repro outside this
    // package — not specific to this file), so the flag cannot switch which
    // `Scene`s exist. Both `WindowGroup`s below exist unconditionally;
    // the multi-window switch (`DHP_MULTIWINDOW`, on unless 0) instead gates every *behaviour* that could
    // produce a second window or tab: `AppCommands`' New Window/New Tab
    // items, the sidebar's "Open in New Window/Tab", and
    // `AppDelegate`'s tabbing. With the flag off nothing ever opens a
    // second `main`/`compact` window, so `WindowGroup(for:)`'s single
    // launch-time window is exactly the pre-step-8 single window.
    var body: some Scene {
        WindowGroup(id: "main", for: WorkspaceSeed.self) { $seed in
            MultiWindowContentHost(seed: seed ?? WorkspaceSeed())
                .environment(model)
                .environment(avdActionDialogs)
                .environment(appActionDialogs)
                .environment(simulatorActionDialogs)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1500, height: 950)
        .commands {
            AppCommands(
                avdActionDialogs: avdActionDialogs,
                simulatorActionDialogs: simulatorActionDialogs,
                multiWindowEnabled: model.launchOptions.multiWindowEnabled,
                updater: updater
            )
        }

        // One compact window per workspace, keyed by `WorkspaceID`
        // (`toggleCompactMirror` always opens/closes it by the focused
        // window's own workspace id, so with the flag off — one workspace —
        // this behaves exactly like the old singleton `Window`).
        WindowGroup(id: CompactMirrorWindow.id, for: WorkspaceID.self) { $id in
            CompactWorkspaceMirrorHost(id: id)
                .environment(model)
                .environment(avdActionDialogs)
                .environment(appActionDialogs)
                .environment(simulatorActionDialogs)
        }
        .defaultSize(
            width: CompactMirrorWindow.defaultSize.width,
            height: CompactMirrorWindow.defaultSize.height
        )
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(model)
                .environment(updater)
        }
    }
}

/// The model of the focused window, for menu commands.
private struct AppModelFocusKey: FocusedValueKey {
    typealias Value = AppModel
}

/// The device workspace of the focused window, for the menus' device items.
private struct DeviceWorkspaceFocusKey: FocusedValueKey {
    typealias Value = DeviceWorkspace
}

extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelFocusKey.self] }
        set { self[AppModelFocusKey.self] = newValue }
    }

    var deviceWorkspace: DeviceWorkspace? {
        get { self[DeviceWorkspaceFocusKey.self] }
        set { self[DeviceWorkspaceFocusKey.self] = newValue }
    }
}

/// Device Hub style menus: File, Edit's clipboard items, View, Device,
/// Controls, Window and Help (Device and Controls per selected device kind,
/// `DeviceExtrasCommands.swift`).
private struct AppCommands: Commands {
    /// The focused window's model, for the app-wide items (refresh, the
    /// AVD and simulator file actions, the shared clipboard, keyboard
    /// capture).
    @FocusedValue(\.appModel) private var model
    /// The focused window's device workspace, for the items that act on the
    /// window's device, stage and inspector.
    @FocusedValue(\.deviceWorkspace) private var workspace
    @Environment(\.openWindow) private var openWindow
    let avdActionDialogs: AvdActionDialogs
    let simulatorActionDialogs: SimulatorActionDialogs
    /// the multi-window switch (`DHP_MULTIWINDOW`, on unless 0), read from the app's own model rather than
    /// the focused one: `@FocusedValue(\.appModel)` is nil while focus sits
    /// where no view publishes it (the sidebar list), which left ⌘N and ⌘T
    /// out of the menu and silently did nothing.
    let multiWindowEnabled: Bool
    /// In-app updates; the menu item exists only when the packaged app names a feed.
    let updater: AppUpdater

    /// Rename… acts on a stopped AVD, or the selected simulator.
    private var avdFileActionsEnabled: Bool {
        model?.avdFileActionsEnabled(in: workspace) == true
    }

    /// The simulator the stage selects, when it selects one.
    private var selectedSimulator: SimulatorEntry? {
        guard case .simulator(let udid)? = workspace?.deviceSelection else { return nil }
        return model?.simulators.entry(udid: udid)
    }

    private var canRenameSimulator: Bool {
        guard let simulator = selectedSimulator else { return false }
        let operation = model?.simulatorLifecycle.operations[simulator.udid]
        return operation == nil || operation == .starting
    }

    /// Whether the clipboard items can act: an adb device or a simulator is
    /// mirrored.
    /// The shown device's clipboard, only while it is the selected row's
    /// (a stopped AVD's selection must not reach the device shown before).
    private var canSyncClipboard: Bool {
        guard let workspace else { return false }
        if workspace.menuTargetSerial != nil { return true }
        guard let simulator = workspace.context.simulatorDevice else { return false }
        return workspace.deviceSelection == .simulator(simulator.id)
    }

    private func sortBinding(_ mode: WindowState.DeviceSortMode) -> Binding<Bool> {
        Binding(
            get: { (workspace?.window.deviceSortMode ?? .availability) == mode },
            set: { if $0 { workspace?.window.deviceSortMode = mode } }
        )
    }

    private func filterBinding(_ filter: WindowState.DeviceFilter) -> Binding<Bool> {
        Binding(
            get: { (workspace?.window.deviceFilter ?? .all) == filter },
            set: { if $0 { workspace?.window.deviceFilter = filter } }
        )
    }

    /// The checkmark and action of one View ▸ scale item: on while `mode` is
    /// the window's zoom mode; turning it on applies it (an active item
    /// stays on).
    private func scaleModeBinding(_ mode: WindowState.ZoomMode) -> Binding<Bool> {
        Binding(
            get: { workspace?.window.zoomMode == mode },
            set: { on in
                guard on, let window = workspace?.window else { return }
                switch mode {
                case .fit: window.resetZoom()
                case .physical: window.physicalSizeZoom()
                case .pointAccurate: window.pointAccurateZoom()
                case .pixelAccurate: window.pixelAccurateZoom()
                case .custom: break
                }
            }
        )
    }

    /// Whether the key window is the compact mirror (Stay on Top then acts
    /// on it, not on the main window).
    private var keyWindowIsCompact: Bool {
        guard let compact = workspace?.window.compactNSWindow else { return false }
        return NSApp.keyWindow === compact
    }

    private var zoomAvailable: Bool {
        stageZoomIsAvailable(
            liveSelectionSerial: workspace?.liveSelectionSerial,
            hasSession: workspace?.selectedDeviceHasSession ?? false
        )
    }

    var body: some Commands {
        // File (Device Hub's): New Simulator, New Tab / New Window, Rename…;
        // Close and Close All are the system's. Everything sits in the
        // `.newItem` group: a `.saveItem` replacement is ignored once the app
        // has a second WindowGroup (the compact window), and an empty
        // `.newItem` group drops the whole File menu, so its items are always
        // there, disabled while no window has focus.
        // App menu: Check for Updates… under About, only in a build that
        // names an appcast (AppUpdater).
        CommandGroup(after: .appInfo) {
            if updater.isEnabled {
                Button("Check for Updates\u{2026}") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }

        CommandGroup(replacing: .newItem) {
            // The + menu's items: Device Hub's simulators, once Xcode can
            // run them (the sheet points to Xcode for a missing runtime).
            if model?.simulators.tooling.tier ?? .t0 >= .t1 {
                Menu("New Simulator") {
                    ForEach(SimulatorFamily.offered(runtimes: model?.simulators.runtimes ?? [])) { family in
                        Button(family.menuTitle) { workspace?.window.simulatorCreateFamily = family }
                    }
                }
            }
            Menu("New Emulator") {
                Button("Phone…") { workspace?.window.createFormFactor = .phone }
                Button("Tablet…") { workspace?.window.createFormFactor = .tablet }
                Button("Foldable…") { workspace?.window.createFormFactor = .foldable }
                Button("Wear OS…") { workspace?.window.createFormFactor = .wear }
                Button("TV…") { workspace?.window.createFormFactor = .tv }
                Button("Automotive…") { workspace?.window.createFormFactor = .automotive }
                Divider()
                Button("Browse Catalog…") { workspace?.window.isCatalogPresented = true }
            }
            .disabled(workspace == nil)
            Button("Pair Nearby Device…") { workspace?.window.isPairSheetPresented = true }
                .disabled(workspace == nil)
            if multiWindowEnabled {
                Divider()
                Button("New Tab") {
                    openWorkspaceTab(seed: WorkspaceSeed(), keyWindow: NSApp.keyWindow, openWindow: openWindow)
                }
                .keyboardShortcut("t", modifiers: .command)
                Button("New Window") {
                    openWindow(value: WorkspaceSeed())
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            Divider()
            Button("Rename…") {
                if let name = model?.selectedAvdName(in: workspace) {
                    avdActionDialogs.requestRename(name)
                } else if let simulator = selectedSimulator {
                    simulatorActionDialogs.requestRename(simulator)
                }
            }
            .disabled(!avdFileActionsEnabled && !canRenameSimulator)
        }

        // Device Hub's Edit ▸ Use Shared Clipboard / Get Clipboard / Send
        // Clipboard: an adb device's clipboard, or a simulator's (simctl
        // pbcopy / pbpaste).
        CommandGroup(after: .pasteboard) {
            Divider()
            Toggle("Use Shared Clipboard", isOn: Binding(
                get: { model?.preferences.clipboardAutoSyncEnabled ?? false },
                set: { on in
                    if let workspace {
                        workspace.clipboard.setAutoSync(on, physical: workspace.mirror.activePhysicalSession)
                    }
                }
            ))
            .disabled(!canSyncClipboard)
            Button("Get Clipboard") {
                if let workspace {
                    Task { await workspace.clipboard.pull(physical: workspace.mirror.activePhysicalSession) }
                }
            }
            .disabled(!canSyncClipboard)
            Button("Send Clipboard") {
                if let workspace {
                    Task { await workspace.clipboard.send(physical: workspace.mirror.activePhysicalSession) }
                }
            }
            .disabled(!canSyncClipboard)
        }

        CommandGroup(after: .toolbar) {
            Menu("Sort By") {
                Toggle("Availability", isOn: sortBinding(.availability))
                Divider()
                Toggle("Recent", isOn: sortBinding(.recent))
                Toggle("Name", isOn: sortBinding(.name))
                Toggle("Fidelity", isOn: sortBinding(.fidelity))
                Toggle("Platform", isOn: sortBinding(.platform))
                Toggle("Operating System", isOn: sortBinding(.operatingSystem))
            }

            // Device Hub's View ▸ Filter carries Show Groups under the
            // filters (its sidebar popup keeps it inside Sort By).
            Menu("Filter") {
                Toggle("All Devices", isOn: filterBinding(.all))
                Toggle("Simulators", isOn: filterBinding(.emulators))
                Toggle("Physical Devices", isOn: filterBinding(.physical))
                Divider()
                Toggle("Show Groups", isOn: Binding(
                    get: { workspace?.window.deviceShowsGroups ?? true },
                    set: { workspace?.window.deviceShowsGroups = $0 }
                ))
            }

            Divider()

            Button(workspace?.window.columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar") {
                workspace?.window.toggleSidebarColumn()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Button(workspace?.window.isLogFocus == true ? "Exit Log Focus" : "Log Focus") {
                Task { @MainActor in workspace?.window.toggleLogFocus() }
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(workspace == nil)

            Menu("Inspectors") {
                // Not listed for a device with no Controls panel (a watch, a headset simulator).
                if workspace?.deviceFamily?.hasControlsPanel != false {
                    Button("Settings") {
                        Task { @MainActor in workspace?.window.selectInspectorTab(.controls) }
                    }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                }
                Button("Reports") {
                    Task { @MainActor in workspace?.window.selectInspectorTab(.diagnostics) }
                }
                .keyboardShortcut("2", modifiers: [.command, .option])
                Button("Info") {
                    Task { @MainActor in workspace?.window.toggleDeviceInfoInspector() }
                }
                .keyboardShortcut("3", modifiers: [.command, .option])

                Divider()

                Button(workspace?.window.showInspector == false ? "Show Inspector" : "Hide Inspector") {
                    Task { @MainActor in workspace?.window.toggleInspector() }
                }
                .keyboardShortcut("i", modifiers: .command)
            }

            Divider()

            // The Back / Home / Recents bar under an Android handheld: listed only
            // there (it changes nothing on any other device).
            if NavigationBarSpec.offersToggle(family: workspace?.deviceFamily) {
                Toggle("Show Navigation Buttons", isOn: Binding(
                    get: { model?.preferences.showNavigationButtons ?? true },
                    set: { model?.preferences.setShowNavigationButtons($0) }
                ))

                Divider()
            }

            // Enabled whenever the toolbar's zoom works, a simulator's canvas
            // included.
            Button("Zoom In") { workspace?.window.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!zoomAvailable)
            Button("Zoom Out") { workspace?.window.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!zoomAvailable)
            Button("Zoom to Fit") { workspace?.window.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!zoomAvailable)
            // Simulator.app's four scale modes (Window ▸ Physical Size ⌘1,
            // Point Accurate ⌘2, Pixel Accurate ⌘3, Fit Screen ⌘4), each a
            // mode the stage keeps while the window or stream changes; the
            // checkmark follows the active one.
            Toggle("Physical Size", isOn: scaleModeBinding(.physical))
                .keyboardShortcut("1", modifiers: .command)
                .disabled(!zoomAvailable || workspace?.window.canShowPhysicalSize != true)
            Toggle("Point Accurate", isOn: scaleModeBinding(.pointAccurate))
                .keyboardShortcut("2", modifiers: .command)
                .disabled(!zoomAvailable || workspace?.window.canShowPointAccurate != true)
            Toggle("Pixel Accurate", isOn: scaleModeBinding(.pixelAccurate))
                .keyboardShortcut("3", modifiers: .command)
                .disabled(!zoomAvailable || workspace?.window.canShowPixelAccurate != true)
            Toggle("Fit Screen", isOn: scaleModeBinding(.fit))
                .keyboardShortcut("4", modifiers: .command)
                .disabled(!zoomAvailable)
        }

        CommandMenu("Device") {
            DeviceMenuItems(
                avdActionDialogs: avdActionDialogs,
                simulatorActionDialogs: simulatorActionDialogs
            )
        }

        CommandMenu("Controls") {
            ControlsMenuItems()
        }

        // Window: Device Hub's has no Minimize All / Zoom All (those are
        // Option alternates AppKit adds to the stock Minimize and Zoom).
        CommandGroup(replacing: .windowSize) {
            Button("Minimize") { NSApp.keyWindow?.performMiniaturize(nil) }
                .keyboardShortcut("m", modifiers: .command)
            Button("Zoom") { NSApp.keyWindow?.performZoom(nil) }
            Divider()
            // Simulator.app's "Float on Top": the key window (the compact
            // mirror or the main window) stays above other windows.
            Toggle("Stay on Top", isOn: Binding(
                get: {
                    keyWindowIsCompact
                        ? workspace?.window.compactStaysOnTop ?? false
                        : workspace?.window.staysOnTop ?? false
                },
                set: { workspace?.setStaysOnTop($0, compact: keyWindowIsCompact) }
            ))
            .disabled(workspace == nil)
        }

        // A plain "<App> Help" (no lightbulb, no ⌘?) that opens the project's
        // README: there is no Help Book. Listed only when the packaged app
        // names the page (DeviceHubProHelpURL, filled by Scripts/package-app.sh),
        // never as an item that only says help is not available.
        CommandGroup(replacing: .help) {
            if let url = HelpLink.url() {
                Button("\(ProcessInfo.processInfo.processName) Help") { NSWorkspace.shared.open(url) }
            }
        }
    }
}

/// Where Help ▸ Device Hub Pro Help goes: `DeviceHubProHelpURL` in the app's
/// Info.plist, https only; nil (no Help item) when it is empty or missing.
enum HelpLink {
    static func url(info: [String: Any]? = Bundle.main.infoDictionary) -> URL? {
        guard let text = info?["DeviceHubProHelpURL"] as? String,
              let url = URL(string: text), url.scheme == "https", url.host != nil
        else { return nil }
        return url
    }
}

extension NSToolbarItem {
    /// SwiftUI's automatic split-view sidebar toggle, matched by identifier
    /// (`com.apple.SwiftUI.navigationSplitView.toggleSidebar`). Our own
    /// leading toggle's id is `sidebar-toggle`, which deliberately does not
    /// match (the naming differs by the hyphen).
    var devicehubproIsSystemSidebarToggle: Bool {
        let id = itemIdentifier.rawValue.lowercased()
        return id.contains("togglesidebar") || id.contains("sidebartoggle")
            || id == "nstoolbartogglesidebaritem"
    }
}

/// Carries the non-Sendable notification across the main-actor boundary: the
/// `willAddItem` observer is delivered on the main queue, so the reference is
/// main-thread confined in practice.
private struct ToolbarNotification: @unchecked Sendable {
    let note: Notification
}

/// Brings the window to the front on launch. When the app is started from a
/// terminal (as during development) macOS may otherwise leave it behind other
/// windows or on another Space. Window state restoration is disabled so a
/// previously-saved fullscreen/offscreen frame can never hide the window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app's model, for the quit cleanup; set when the main window
    /// appears.
    weak var model: AppModel?
    private var isTerminating = false
    /// Logs this process's footprint to `~/Library/Logs/DeviceHubPro/footprint.log`
    /// (`FootprintWatchdog`): a heartbeat every ten minutes and, past each of
    /// 1, 2, 4, 8 and 16 GB, a line with `footprint`'s breakdown by memory
    /// category. `DHP_FOOTPRINT_LOG=0` turns it off.
    private var footprintWatchdog: FootprintWatchdog?

    /// Quit waits for the model's cleanup (recording saved, mirror, logcat,
    /// connections and watcher stopped), which is bounded, so it never hangs.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A quit from the compact window still saves the main one as showing.
        CompactSwitch.restoreAll()
        // A second quit while the cleanup runs means "now".
        guard let model, !isTerminating else { return .terminateNow }
        // A download, an emulator being created or the Android setup is cut
        // short by the quit: ask first. (`terminateAll` then ends the tool.)
        if let notice = model.quitInterruptionNotice {
            let alert = NSAlert()
            alert.messageText = "Quit Device Hub Pro?"
            alert.informativeText = notice
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        isTerminating = true
        Task { @MainActor in
            await model.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // the multi-window switch (`DHP_MULTIWINDOW`, on unless 0) turns on tabbing (shared
        // `tabbingIdentifier`, `MultiWindowSupport.swift`) for ⌘N/⌘T and
        // "Open in New Tab". Off (the default): the single main window, no tab bar, no "New Tab".
        NSWindow.allowsAutomaticWindowTabbing = LaunchOptions.live().multiWindowEnabled
    }

    func applicationWillTerminate(_ notification: Notification) {
        FastInputTermination.terminateAll()
    }

    func applicationShouldSaveApplicationState(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreApplicationState(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A SIGTERM must not leave the tunnel lease's `devicectl` children running.
        FastInputTermination.installSignalHandlers()
        // Dev hook: `DHP_APPEARANCE=dark` forces the dark appearance so
        // the calibrated fills can be captured and verified.
        if LaunchOptions.live().forceDarkAppearance {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        NSApp.setActivationPolicy(.regular)
        if ProcessInfo.processInfo.environment["DHP_FOOTPRINT_LOG"] != "0" {
            let watchdog = FootprintWatchdog(url: FootprintWatchdog.defaultLogURL)
            watchdog.start()
            footprintWatchdog = watchdog
        }
        // Dev hook: `DHP_LAUNCH_INACTIVE=1` leaves the app in the
        // background, its windows behind the active app's, so a live check
        // driven through accessibility takes no focus from the Mac's user.
        let inactive = LaunchOptions.live().launchInactive
        if inactive {
            sendWindowsBack()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            bringWindowsToFront()
        }
        adjustWindowChrome()
        installQuitAlternate()
        TextInputShortcutGuard.install()
        MenuBarDecorations.observeAddedItems()

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            if inactive {
                self?.sendWindowsBack()
            } else {
                self?.bringWindowsToFront()
            }
            self?.adjustWindowChrome()
            self?.installQuitAlternate()
        }

        // The quit choice's alternate carries Settings' current default by
        // the time the app menu opens.
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.installQuitAlternate()
                MenuBarDecorations.apply(to: NSApp.mainMenu)
            }
        }

        // SwiftUI rebuilds the window toolbar whenever the detail content or
        // inspector changes, which re-adds the system sidebar toggle and drops
        // the trailing flexible space. Re-apply the Device Hub toolbar layout
        // on every toolbar change (and on a light watchdog) so the surgical
        // tweak sticks.
        //
        // The removal observer runs synchronously: SwiftUI drops the flexible
        // space and re-adds the system toggle in one pass, and waiting for the
        // next main-actor turn let AppKit paint that intermediate arrangement
        // (the one-frame item jump when switching devices or toggling the
        // sidebar, which moves the leading cluster).
        NotificationCenter.default.addObserver(
            forName: NSToolbar.didRemoveItemNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.adjustToolbars()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSToolbar.willAddItemNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // NSNotification is not Sendable; the observer runs on the main
            // queue, so the reference crosses into the main actor inside an
            // unchecked box.
            let boxed = ToolbarNotification(note: note)
            MainActor.assumeIsolated {
                self?.hideJustAddedSystemToggle(boxed.note)
                // Belt and braces: correct once on the next main-actor turn,
                // then once more after the rebuild settles.
                Task { @MainActor in
                    self?.adjustToolbars()
                    self?.adjustWindowChrome()
                    try? await Task.sleep(for: .milliseconds(60))
                    self?.adjustToolbars()
                    self?.adjustWindowChrome()
                }
            }
        }
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.adjustToolbars()
                self?.adjustWindowChrome()
                self?.installQuitAlternate()
                MenuBarDecorations.apply(to: NSApp.mainMenu)
            }
        }
    }

    // MARK: - Quit choice

    /// Keeps the quit choice's Option alternate right after the app menu's
    /// Quit (`SimulatorQuitMenu`): the opposite of Settings' default,
    /// hidden while the Mac has no simulator tooling.
    private func installQuitAlternate() {
        guard let model, let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        let saved = SimulatorLifecycleController.QuitChoice(
            shutsDownByDefault: model.preferences.shutsDownStartedSimulatorsOnQuit
        )
        let tooling = model.simulators.tooling
        SimulatorQuitMenu.install(
            in: appMenu,
            alternate: saved.opposite,
            isHidden: !tooling.isProbed || tooling.tier == .t0,
            target: self,
            action: #selector(quitTheOtherWay(_:))
        )
    }

    /// The Option alternate: quits doing the opposite of Settings' default
    /// with the simulators Device Hub Pro started.
    @objc func quitTheOtherWay(_ sender: Any?) {
        if let model {
            let saved = SimulatorLifecycleController.QuitChoice(
                shutsDownByDefault: model.preferences.shutsDownStartedSimulatorsOnQuit
            )
            model.simulatorLifecycle.quitChoiceOverride = saved.opposite
        }
        NSApp.terminate(sender)
    }

    /// Matches Device Hub's window chrome: the toolbar band shows the window
    /// background instead of the tinted titlebar material, no baseline
    /// separator sits under the toolbar, and the split-view columns meet
    /// without AppKit's hairline dividers. The dividers stay interactive —
    /// only their alpha is cleared — so the panes remain draggable.
    private func adjustWindowChrome() {
        for window in NSApp.windows {
            guard window.toolbar != nil else { continue }
            if !window.titlebarAppearsTransparent {
                window.titlebarAppearsTransparent = true
            }
            if window.backgroundColor != .windowBackgroundColor {
                window.backgroundColor = .windowBackgroundColor
            }
            if window.titlebarSeparatorStyle != .none {
                window.titlebarSeparatorStyle = .none
            }
            for splitView in window.contentView?.devicehubproDescendants(ofType: NSSplitView.self) ?? [] {
                for divider in splitView.subviews
                where divider.devicehubproIsSplitDivider && divider.alphaValue != 0 {
                    divider.alphaValue = 0
                }
            }
        }
    }

    /// Brings the toolbar back to the Device Hub layout: one sidebar toggle
    /// after the create/filter controls, and a flexible space that pushes the
    /// device capsules (and the inspector controls) to the trailing edge.
    /// Re-entrant calls are dropped: the observer runs synchronously, and its
    /// own item mutations post the same notifications again.
    private var isAdjustingToolbars = false

    /// Removes the system sidebar toggle in the very turn it is added:
    /// waiting for the next-turn removal let AppKit paint it for a frame,
    /// shifting the leading cluster (the flicker on device switches while the
    /// inspector is open). `removeItem` only works once the item is in the
    /// toolbar; a not-yet-added item gets the overflow priority instead so it
    /// cannot claim a slot.
    private func hideJustAddedSystemToggle(_ note: Notification) {
        guard let item = note.userInfo?["item"] as? NSToolbarItem,
              item.devicehubproIsSystemSidebarToggle
        else { return }
        if let toolbar = note.object as? NSToolbar,
           toolbar.items.contains(where: { $0 === item }) {
            withoutToolbarAnimation {
                toolbar.removeItem(identifier: item.itemIdentifier)
            }
        } else {
            // Not in the toolbar yet: keep it out of the visible strip until
            // the next-turn removal.
            item.visibilityPriority = .low
        }
    }

    /// Runs toolbar item mutations without AppKit's insertion/removal
    /// animation: the repair happens while SwiftUI re-applies the toolbar, and
    /// the animation exposed intermediate item positions (the leading cluster
    /// sliding sideways for a frame).
    private func withoutToolbarAnimation(_ body: () -> Void) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
        NSAnimationContext.endGrouping()
    }

    private func adjustToolbars() {
        guard !isAdjustingToolbars else { return }
        isAdjustingToolbars = true
        defer { isAdjustingToolbars = false }

        for window in NSApp.windows {
            guard let toolbar = window.toolbar else { continue }
            // Only the main window's toolbar has the Device Hub layout to
            // restore; the compact window's is title + pill.
            guard toolbar.items.contains(where: { $0.itemIdentifier.rawValue == "keyboard-capsule" }) else { continue }

            withoutToolbarAnimation {
                var index = toolbar.items.count - 1
                while index >= 0 {
                    let item = toolbar.items[index]
                    if item.devicehubproIsSystemSidebarToggle {
                        toolbar.removeItem(at: index)
                    }
                    index -= 1
                }

                // The first app item is the middle trio's keyboard capsule;
                // the flexible space goes right before it.
                let appIndices = toolbar.items.indices.filter { isAppItem(toolbar.items[$0]) }
                guard let target = appIndices.first(where: {
                    toolbar.items[$0].itemIdentifier.rawValue == "keyboard-capsule"
                }) ?? appIndices.first else { return }
                let previous = target > 0 ? toolbar.items[target - 1].itemIdentifier : nil
                if previous != .flexibleSpace {
                    toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: target)
                }
                // DH's inspector section: an inspector tracking separator and a
                // flexible space before the inspector capsule, so the capsule
                // sits right-aligned over the inspector column and the trio
                // ends at its divider, following it as the inspector resizes,
                // hides or the window narrows. A fixed 168 pt gap stood in for
                // it: the trio ran ≈14 pt into the inspector, collapsed into
                // the overflow chevron at 1200 pt and kept the gap with the
                // inspector hidden (TB-03).
                if let inspectorIndex = toolbar.items.firstIndex(where: {
                    $0.itemIdentifier.rawValue == "inspector-capsule"
                }), !toolbar.items.contains(where: { $0.itemIdentifier == .inspectorTrackingSeparator }) {
                    toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: inspectorIndex)
                    toolbar.insertItem(withItemIdentifier: .inspectorTrackingSeparator, at: inspectorIndex)
                }
            }
        }
    }

    /// App items carry our stable identifiers; the system and spacer items
    /// use `NSToolbar…`/`com.apple…` identifiers. Navigation-placed items
    /// (the stage title) are pinned by SwiftUI and must not shift the
    /// flexible-space target.
    private func isAppItem(_ item: NSToolbarItem) -> Bool {
        guard !item.isNavigational else { return false }
        let id = item.itemIdentifier.rawValue
        return !id.hasPrefix("NSToolbar") && !id.hasPrefix("com.apple")
    }

    /// `DHP_LAUNCH_INACTIVE`: the windows go behind every other app's,
    /// unfocused, still on screen (captured by window id).
    private func sendWindowsBack() {
        for window in NSApp.windows where window.canBecomeMain {
            window.orderBack(nil)
        }
    }

    private func bringWindowsToFront() {
        for window in NSApp.windows where window.canBecomeMain {
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            // A previously saved fullscreen frame can associate the window with
            // another Space; move it back to the active one.
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

extension NSView {
    /// Every descendant of the receiver that matches `type`, depth first.
    func devicehubproDescendants<T: NSView>(ofType type: T.Type) -> [T] {
        var found: [T] = []
        for subview in subviews {
            if let match = subview as? T { found.append(match) }
            found.append(contentsOf: subview.devicehubproDescendants(ofType: type))
        }
        return found
    }

    /// AppKit's split dividers are private classes (`NSVibrantSplitDividerView`,
    /// `NSSplitDividerView`); matching them by name keeps the chrome surgery on
    /// public API.
    var devicehubproIsSplitDivider: Bool {
        String(describing: type(of: self)).contains("DividerView")
    }
}
