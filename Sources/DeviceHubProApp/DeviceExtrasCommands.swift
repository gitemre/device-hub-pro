import AppKit
import SwiftUI
import DeviceHubProKit

// The Device and Controls menus, built per selected device the way Device Hub
// builds its own (Device: the device's power and settings; Controls: its
// hardware buttons, rotation, screenshot and recording). Every setting the
// Controls panel offers is also a Device menu item:
// a simulator's Accessibility … Sound, Language, Time Zone…, Status Bar
// (`AppleDeviceSettingsMenus`), an Android device's the same set
// (`AndroidSettingsMenu.swift`); Push Notification…, Permissions…, Open URL…,
// Keyboard, Sensors…, Simulate ▸ and the emulator's Pause and Fingerprint Touch
// are menu-only or twin the panel's rows. They reuse the controllers the panel's
// rows use; a sheet-taking item presents one from `DeviceExtrasSheets.swift`
// through `WindowState.deviceExtrasSheet`.

// MARK: - What the selection is

/// What the Device and Controls menus show: one kind per selection, so an
/// Apple simulator never lists Android items (and the reverse). Pure, for
/// tests.
struct DeviceMenuLayout: Equatable {
    enum Kind: Equatable {
        case none
        /// A simulator of the listed set, running or not.
        case simulator
        /// An AVD, running or not, or a device adb lists (a foreign emulator,
        /// a phone the user opted in to).
        case android
        /// A physical iPhone or iPad (Control).
        case physicalApple
        /// A Pixel catalog entry that is not provisioned.
        case catalog
    }

    var kind: Kind = .none
    var isRunning = false
    /// The selected AVD, when the selection is one.
    var avdName: String?

    init(selection: DeviceSelection?, isRunning: Bool) {
        self.isRunning = isRunning
        switch selection {
        case nil: kind = .none
        case .simulator?: kind = .simulator
        case .avd(let name)?:
            kind = .android
            avdName = name
        case .device?: kind = .android
        case .physicalApple?: kind = .physicalApple
        case .pixel?: kind = .catalog
        }
    }

    /// Start / Restart / Shut Down: a simulator or an AVD (an adb device has
    /// no lifecycle here).
    var hasLifecycle: Bool { kind == .simulator || avdName != nil }
    /// Device Hub's settings submenus (Accessibility … Sound) and ours.
    var showsAppleSettings: Bool { kind == .simulator }
    /// Sensors…, Simulate ▸, Fingerprint Touch, Pause.
    var showsAndroidExtras: Bool { kind == .android && isRunning }
    /// Open URL… for a running simulator or Android device.
    var showsOpenURL: Bool { (kind == .simulator || kind == .android) && isRunning }
    /// Controls: the Android set (Back, Recents, Power, Volume …) rather than
    /// Device Hub's (Home, Lock).
    var usesAndroidControls: Bool { kind == .android }
    /// A physical iPhone has menus of its own (`PhysicalDeviceMenus.swift`).
    var usesPhysicalMenus: Bool { kind == .physicalApple }

    /// Reset Content and Settings…: only an AVD or an available simulator can be
    /// erased. A phone, a foreign emulator, a catalog entry and no selection get
    /// no such item (what cannot work is not shown).
    func offersReset(simulatorIsAvailable: Bool) -> Bool {
        avdName != nil || (kind == .simulator && simulatorIsAvailable)
    }

    /// Sensors…, Simulate ▸: they drive the emulator's console, which a phone
    /// (and a device without a console port) does not have.
    func offersEmulatorConsoleItems(hasConsolePort: Bool) -> Bool {
        showsAndroidExtras && hasConsolePort
    }
}

/// Which items of the Device menu's Apple settings block a simulator shows
/// (an item that cannot work on the selected device is
/// not shown, not greyed). Pure: the family decides, then the mechanism route
/// once the controller has read the simulator; a stopped simulator keeps the
/// items it would show (disabled, as Device Hub does).
struct AppleSettingsMenuPlan {
    enum AccessibilityItem: Equatable {
        case reduceMotion, reduceTransparency, increaseContrast, showBorders
        case textSize
        case voiceOver
    }

    let family: ControlsFamily
    var isRunning = true
    /// Whether the controller's route reaches `control` (true until it has read the device).
    var routeOffers: (AppleControl) -> Bool = { _ in true }
    var biometricType: String?
    var supportsBiometrics: Bool?

    func shows(_ control: AppleControl) -> Bool { family.offers(control) && routeOffers(control) }

    /// The Accessibility submenu's groups, each non-empty, in menu order.
    var accessibilityGroups: [[AccessibilityItem]] {
        let groups: [[(AccessibilityItem, AppleControl)]] = [
            [(.reduceMotion, .reduceMotion), (.reduceTransparency, .reduceTransparency),
             (.increaseContrast, .increaseContrast), (.showBorders, .showBorders)],
            [(.textSize, .textSize)],
            [(.voiceOver, .voiceOver)],
        ]
        return groups.map { $0.filter { shows($0.1) }.map(\.0) }.filter { !$0.isEmpty }
    }

    var showsAccessibility: Bool { !accessibilityGroups.isEmpty }
    var showsAppearance: Bool { shows(.appearance) }
    var showsLocation: Bool { shows(.location) }
    var showsSound: Bool { shows(.volume) }
    /// Orientation is also hidden while the simulator is off (as Device Hub does).
    var showsOrientation: Bool { isRunning && shows(.orientation) }

    /// The one biometrics menu this device has (Face ID, Touch ID or Optic ID);
    /// none where it has no biometrics. Face ID until the device type is read.
    var biometricMenuTitle: String? {
        guard shows(.biometrics), supportsBiometrics != false else { return nil }
        return biometricType ?? "Face ID"
    }

    var showsAnything: Bool {
        showsAccessibility || showsAppearance || biometricMenuTitle != nil
            || showsLocation || showsOrientation || showsSound
    }

    /// Add Sample Data and the Clean Status Bar item are the extras block's family-bound items.
    var showsSampleData: Bool {
        family.offersSampleData
    }
    var showsStatusBarMenu: Bool { shows(.statusBar) }
    /// Language ▸ 24-hour time: where the panel offers the 24-hour row.
    var showsTimeFormat24: Bool { shows(.timeFormat24) }
}

/// Whether the stage zoom (toolbar and View menu alike) can act: an adb device
/// is live, or a mirror session (a simulator's canvas) is.
func stageZoomIsAvailable(liveSelectionSerial: String?, hasSession: Bool) -> Bool {
    liveSelectionSerial != nil || hasSession
}

// MARK: - Controller helper

extension AppleControlsController {
    /// The menu items act through the controller the panel reads with; it is
    /// attached only while the panel shows the simulator. Attach it (once) for
    /// a menu action, or wait for the attach already running.
    func ensureAttached(_ udid: String) async {
        if self.udid != udid { await attach(udid) }
        var waited = 0
        while self.udid == udid, !isLoaded, waited < 100 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
    }
}

// MARK: - The Device menu

/// The contents of the Device menu.
struct DeviceMenuItems: View {
    @FocusedValue(\.appModel) private var model
    @FocusedValue(\.deviceWorkspace) private var workspace
    let avdActionDialogs: AvdActionDialogs
    let simulatorActionDialogs: SimulatorActionDialogs

    private var selection: DeviceSelection? { workspace?.deviceSelection }

    private var selectedSimulator: SimulatorEntry? {
        guard case .simulator(let udid)? = selection else { return nil }
        return model?.simulators.entry(udid: udid)
    }

    private var simulatorMenu: SimulatorDeviceMenuState {
        SimulatorDeviceMenuState(
            device: workspace?.context.simulatorDevice,
            capabilities: workspace?.context.capabilities ?? [],
            selected: selectedSimulator,
            operation: selectedSimulator.flatMap { model?.simulatorLifecycle.operations[$0.udid] }
        )
    }

    private var avdCard: AvdCard? {
        guard case .avd(let name)? = selection else { return nil }
        return model?.catalog.avdCards.first { $0.name == name }
    }

    private var isRunning: Bool {
        if selectedSimulator != nil { return simulatorMenu.isSelectedRunning }
        if case .avd? = selection { return avdCard?.isRunning == true }
        return workspace?.menuTargetSerial != nil
    }

    private var layout: DeviceMenuLayout { DeviceMenuLayout(selection: selection, isRunning: isRunning) }

    /// Rename/Reset are stopped-AVD actions; an AVD whose state is not in the
    /// refreshed list counts as unknown and stays disabled.
    private var avdFileActionsEnabled: Bool {
        model?.avdFileActionsEnabled(in: workspace) == true
    }

    private var avdStartEnabled: Bool { avdFileActionsEnabled && model?.isBusy != true }

    var body: some View {
        if layout.usesPhysicalMenus, let workspace, case .physicalApple(let udid)? = selection {
            // Device Hub's Device menu for the phone, less what has no route
            // here (`PhysicalDeviceMenus.swift`).
            PhysicalDeviceMenuItems(
                workspace: workspace, udid: udid,
                isUsable: model?.physicalInventory.entry(udid: udid)?.canUseClient == true,
                model: model
            )
            Divider()
            SendFilesMenuItem(workspace: workspace, model: model, simulatorActionDialogs: simulatorActionDialogs)
        } else {
            commonItems
        }
    }

    /// The simulator's Controls family: the selected simulator's own (a
    /// stopped one has no live device context, and the iPhone fallback gave a
    /// stopped Apple TV a Face ID menu), the iPhone family until it is known.
    private var simulatorFamily: ControlsFamily {
        if let entry = selectedSimulator {
            return ControlsFamily.simulator(platform: entry.platform, productFamily: entry.productFamily)
        }
        return workspace?.deviceFamily ?? .iPhone
    }

    private var simulatorPlan: AppleSettingsMenuPlan {
        let controls = workspace?.appleControls
        let udid = selectedSimulator?.udid
        let attached = controls != nil && controls?.udid == udid && controls?.isLoaded == true
        return AppleSettingsMenuPlan(
            family: simulatorFamily,
            isRunning: layout.isRunning,
            routeOffers: { control in !attached || controls?.route(control).isOffered == true },
            biometricType: attached ? controls?.state.biometricType : nil,
            supportsBiometrics: attached ? controls?.state.supportsBiometrics : nil
        )
    }

    /// The Android settings block's plan: the panel's own flags once it has read
    /// the running device, the rows no probe can take away before (an AVD that is
    /// off keeps them, disabled, by the class of its system image).
    private var androidPlan: AndroidSettingsMenuPlan? {
        guard layout.kind == .android, let workspace, layout.isRunning || layout.avdName != nil else { return nil }
        // The items act on the device this tab mirrors: an AVD running but not
        // mirrored here has none (its items stay listed, off), and until the
        // device's Info is read its class comes from its AVD's image, so a
        // running Wear or TV AVD is not taken for a phone.
        let isLive = layout.isRunning && workspace.menuTargetSerial != nil
        let isLoaded = isLive && workspace.controlsPanel.controlsLoaded
        let infoRead = workspace.context.serial.flatMap { workspace.services.inventory.deviceInfos[$0] } != nil
        return AndroidSettingsMenuPlan.make(
            family: isLive && infoRead ? workspace.androidControlsFamily() : .android(avdCard?.formFactor),
            readAvailability: isLoaded ? workspace.androidControlsAvailability : nil,
            isEmulator: layout.avdName != nil || workspace.context.port != nil,
            isRunning: isLive
        )
    }

    @ViewBuilder
    private var commonItems: some View {
        let layout = layout
        let plan = simulatorPlan
        let androidPlan = androidPlan
        let androidSettings = androidPlan?.showsAnything == true
        let simulatorAvailable = selectedSimulator?.isAvailable == true
        // A section's rule is drawn only when a section above it is shown.
        let lifecycle = layout.hasLifecycle && (layout.kind != .simulator || simulatorAvailable)
        let appleBlock = layout.showsAppleSettings && selectedSimulator?.udid != nil && workspace != nil && plan.showsAnything
        let appleExtras = layout.showsAppleSettings && layout.isRunning && selectedSimulator?.udid != nil && workspace != nil
        // The emulator extras (Sensors…, Simulate ▸) act on the context's
        // console: only while it is the selected row's device.
        let androidBlock = layout.showsAndroidExtras && workspace?.menuTargetSerial != nil
        let profile = layout.kind == .android || layout.kind == .simulator
        let sendFiles = layout.isRunning && (layout.kind == .simulator || layout.kind == .android) && workspace != nil
        let showsFold = workspace?.hardware.showsFoldControls == true && workspace?.menuTargetSerial != nil
        let stage = showsFold || workspace?.offersResizeMode == true
        if lifecycle { lifecycleItems(layout) }
        if appleBlock, let udid = selectedSimulator?.udid, let workspace {
            if lifecycle { Divider() }
            AppleDeviceSettingsMenus(workspace: workspace, udid: udid, plan: plan)
        }
        // What only a running simulator answers is hidden while it is off,
        // as Device Hub hides Orientation there.
        if appleExtras, let udid = selectedSimulator?.udid, let workspace {
            if lifecycle || appleBlock { Divider() }
            SimulatorExtrasMenuItems(
                workspace: workspace, udid: udid, isRunning: layout.isRunning, plan: plan,
                canOpenURL: simulatorMenu.canOpenURL, simulatorActionDialogs: simulatorActionDialogs,
                simulator: selectedSimulator, libraries: model?.libraries
            )
        }
        if androidSettings, let androidPlan, let workspace {
            if lifecycle { Divider() }
            AndroidDeviceSettingsMenus(workspace: workspace, plan: androidPlan)
        }
        if androidBlock, let workspace {
            if lifecycle || appleBlock || appleExtras || androidSettings { Divider() }
            AndroidExtrasMenuItems(
                workspace: workspace, showsOpenURL: layout.showsOpenURL,
                showsConsoleItems: layout.offersEmulatorConsoleItems(hasConsolePort: workspace.context.port != nil)
            )
        }
        if profile {
            if lifecycle || appleBlock || appleExtras || androidSettings || androidBlock { Divider() }
            ApplyProfileMenu(model: model, workspace: workspace)
        }
        if sendFiles, let workspace {
            Divider()
            SendFilesMenuItem(workspace: workspace, model: model, simulatorActionDialogs: simulatorActionDialogs)
        }
        if stage {
            if lifecycle || appleBlock || appleExtras || androidSettings || androidBlock || profile || sendFiles { Divider() }
            stageModeItems(layout)
        }
        if lifecycle || appleBlock || appleExtras || androidSettings || androidBlock || profile || sendFiles || stage { Divider() }
        KeyboardMenu(
            model: model, workspace: workspace, avdName: layout.avdName, isRunning: layout.isRunning,
            capturesWhenStopped: false
        )
        if layout.kind == .android {
            Button("Stop Mirror") { workspace?.stopMirror() }
                .disabled(workspace?.mirror.session == nil || workspace?.menuTargetSerial == nil)
        }
        // The log window left the Reports panel (DH has no log viewer
        // there); this is its menu entry, for a device that is running.
        if layout.isRunning, layout.kind == .simulator || layout.kind == .android {
            Button("Show Logs…") { workspace?.window.isLogsSheetPresented = true }
                .disabled(workspace?.menuTargetSerial == nil && workspace?.context.simulatorDevice == nil)
        }
        // The sidebar's multi-selection (⌘-click, ⇧-click, ⌘A): one action on
        // every selected device. It left this menu with the Device Hub menu bar
        // (2026-09-29) and lived on only in the rows' context menu, while the
        // README and the items' own shortcut pointed here.
        if workspace?.multiSelection.isMultiple == true {
            Divider()
            ApplyToSelectedMenuItems(model: model, workspace: workspace, showsShortcuts: true)
        }
        // Only an AVD or an available simulator can be erased.
        if layout.offersReset(simulatorIsAvailable: simulatorAvailable) {
            Divider()
            Button("Reset Content and Settings…") {
                if let name = model?.selectedAvdName(in: workspace) {
                    avdActionDialogs.requestWipeData(name)
                } else if let simulator = selectedSimulator {
                    simulatorActionDialogs.requestErase(simulator)
                }
            }
            .disabled(!avdFileActionsEnabled && !(simulatorMenu.canManage && selectedSimulator?.isAvailable == true))
        }
    }

    // MARK: Power

    @ViewBuilder
    private func lifecycleItems(_ layout: DeviceMenuLayout) -> some View {
        if layout.kind == .simulator {
            if layout.isRunning {
                Button("Restart") {
                    if let udid = simulatorMenu.selectedUDID {
                        Task { await model?.simulatorLifecycle.restart(udid) }
                    }
                }
                .disabled(!simulatorMenu.canRestart)
                // ⌘. as an AVD's Shut Down.
                Button("Shut Down") {
                    if let udid = simulatorMenu.selectedUDID {
                        Task { await model?.simulatorLifecycle.shutDown(udid) }
                    }
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!simulatorMenu.canShutDown)
                // Device Hub's Option alternate of Shut Down (made one by
                // `DeviceMenuAlternates`): the same `simctl shutdown`.
                Button(DeviceMenuAlternates.forceShutDownTitle) {
                    if let udid = simulatorMenu.selectedUDID {
                        Task { await model?.simulatorLifecycle.shutDown(udid) }
                    }
                }
                .disabled(!simulatorMenu.canShutDown)
            } else {
                Button("Start") {
                    if let udid = simulatorMenu.selectedUDID {
                        Task { await model?.simulatorLifecycle.boot(udid) }
                    }
                }
                .disabled(!simulatorMenu.canStart)
                // Shut Down is hidden while the simulator is off.
            }
        } else if layout.avdName != nil {
            if layout.isRunning {
                Button("Restart") { Task { await workspace?.mirror.restartAndroid() } }
                    .disabled(workspace?.menuTargetSerial == nil)
                // The selected AVD by name, as the toolbar's and the row's Shut
                // Down do: the context's emulator may be another one.
                Button("Shut Down") {
                    if let name = layout.avdName { Task { await model?.stopEmulator(avd: name) } }
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(layout.avdName == nil)
            } else {
                Button("Start") {
                    if let name = model?.selectedAvdName(in: workspace) {
                        Task { await model?.startAndMirror(avd: name, workspace: workspace) }
                    }
                }
                .disabled(!avdStartEnabled)
            }
        }
        // No lifecycle (an adb device, a catalog entry): no power items at all.
    }

    // MARK: Resize, fold

    @ViewBuilder
    private func stageModeItems(_ layout: DeviceMenuLayout) -> some View {
        if workspace?.hardware.showsFoldControls == true, workspace?.menuTargetSerial != nil {
            Button("Fold / Unfold") {
                Task { @MainActor in workspace?.hardware.toggleFold() }
            }
        }
        // Device Hub's Device > Enter Resize Mode (no shortcut there either):
        // only a device whose display can be resized lists it; a stopped one
        // keeps it, disabled.
        if workspace?.offersResizeMode == true {
            Button(workspace?.isInResizeMode == true ? "Exit Resize Mode" : "Enter Resize Mode") {
                workspace?.window.toggleResizeMode()
            }
            .disabled(workspace?.canEnterResizeMode != true)
        }
    }
}

// MARK: - Keyboard ▸

/// Device Hub's Keyboard submenu: Keyboard Capture (⌘K) is the toolbar's
/// keyboard toggle; an AVD created without a hardware keyboard adds Enable
/// Keyboard Input, which used to be a note under the stopped AVD's Start.
struct KeyboardMenu: View {
    let model: AppModel?
    let workspace: DeviceWorkspace?
    let avdName: String?
    let isRunning: Bool
    /// Whether Keyboard Capture answers: the toolbar's toggle is dimmed while
    /// the device is off, so the menu item is too (the physical menu, which
    /// has no such state, leaves it on).
    var capturesWhenStopped = true

    private var needsEnabling: Bool {
        guard let avdName else { return false }
        return model?.catalog.avdCards.first(where: { $0.name == avdName })?.hasHardwareKeyboard == false
    }

    var body: some View {
        Menu("Keyboard") {
            Toggle("Keyboard Capture", isOn: Binding(
                get: { model?.preferences.keyboardForwardingEnabled ?? false },
                set: { model?.setKeyboardCapture($0) }
            ))
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!capturesWhenStopped && !isRunning)
            if let avdName, needsEnabling {
                Divider()
                // The change needs the AVD stopped and makes its next start a
                // cold boot.
                Button("Enable Keyboard Input") {
                    Task { await model?.catalog.enableHardwareKeyboard(avdName) }
                }
                .disabled(isRunning)
            }
        }
    }
}

// MARK: - Simulator: Device Hub's settings submenus

/// Device Hub's Device-menu submenus for a simulator: Accessibility,
/// Appearance, Face ID / Touch ID / Optic ID, Location, Orientation, Sound.
/// Disabled while the simulator is off, as in Device Hub. Each acts through
/// `AppleControlsController` (attached on demand, `ensureAttached`).
private struct AppleDeviceSettingsMenus: View {
    let workspace: DeviceWorkspace
    let udid: String
    /// Which items the simulator's family and mechanisms show; the rest are not listed.
    let plan: AppleSettingsMenuPlan

    private var isRunning: Bool { plan.isRunning }
    private var controls: AppleControlsController { workspace.appleControls }
    private var state: AppleControlsState { controls.udid == udid ? controls.state : AppleControlsState() }

    private func act(_ body: @escaping @MainActor (AppleControlsController) async -> Void) {
        let controls = controls
        Task { @MainActor in
            await controls.ensureAttached(udid)
            await body(controls)
        }
    }

    var body: some View {
        if plan.showsAccessibility {
            IconMenu("Accessibility", "accessibility", disabled: !isRunning) {
                let groups = plan.accessibilityGroups
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Divider() }
                    ForEach(group, id: \.self) { item in accessibilityRow(item) }
                }
            }
        }

        if plan.showsAppearance {
            IconMenu("Appearance", "circle.lefthalf.filled", disabled: !isRunning) {
                Button("Toggle Appearance") { act { await $0.setAppearance(dark: !($0.state.dark ?? false)) } }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Divider()
                Toggle("Light", isOn: Binding(
                    get: { state.dark == false },
                    set: { if $0 { act { await $0.setAppearance(dark: false) } } }
                ))
                Toggle("Dark", isOn: Binding(
                    get: { state.dark == true },
                    set: { if $0 { act { await $0.setAppearance(dark: true) } } }
                ))
            }
        }


        if let title = plan.biometricMenuTitle {
            biometricMenu(title, symbol: Self.biometricSymbol(title))
        }

        if plan.showsLocation { locationMenu }
        // Device Hub hides Orientation while the simulator is off.
        if plan.showsOrientation { orientationMenu }

        if plan.showsSound { soundMenu }
    }

    @ViewBuilder
    private func accessibilityRow(_ item: AppleSettingsMenuPlan.AccessibilityItem) -> some View {
        switch item {
        case .reduceMotion:
            Toggle("Reduce Motion", isOn: flag(state.reduceMotion, .reduceMotion) { await $0.setReduceMotion($1) })
        case .reduceTransparency:
            Toggle("Reduce Transparency", isOn: flag(state.reduceTransparency, .reduceTransparency) { await $0.setReduceTransparency($1) })
        case .increaseContrast:
            Toggle("Increase Contrast", isOn: flag(state.increaseContrast, .increaseContrast) { await $0.setIncreaseContrast($1) })
        case .showBorders:
            Toggle("Show Borders", isOn: flag(state.showBorders, .showBorders) { await $0.setShowBorders($1) })
        case .textSize:
            Button("Increase Text Size") { stepTextSize(by: 1) }
                .keyboardShortcut("+", modifiers: [.command, .option])
            Button("Decrease Text Size") { stepTextSize(by: -1) }
                .keyboardShortcut("-", modifiers: [.command, .option])
        case .voiceOver:
            Toggle("VoiceOver", isOn: flag(state.voiceOver, .voiceOver) { await $0.setVoiceOver($1) })
        }
    }

    private static func biometricSymbol(_ title: String) -> String {
        switch title {
        case "Touch ID": "touchid"
        case "Optic ID": "opticid"
        default: "faceid"
        }
    }

    // MARK: Sound

    /// Device Hub's Sound ▸ volume steps, then the Input and Output devices
    /// (None, Use System Settings, the Mac's own devices).
    private var soundMenu: some View {
        IconMenu("Sound", "speaker.wave.2", disabled: !isRunning) {
            Button("Increase Volume") { stepVolume(by: 1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!volumeReady)
            Button("Decrease Volume") { stepVolume(by: -1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!volumeReady)
            Divider()
            audioSection("Input", isOutput: false)
            audioSection("Output", isOutput: true)
        }
    }

    @ViewBuilder
    private func audioSection(_ title: String, isOutput: Bool) -> some View {
        let pinned = isOutput ? state.audioOutput : state.audioInput
        let devices = isOutput ? MacAudioDevices.outputs() : MacAudioDevices.inputs()
        // Until the panel's controller has read the simulator, the item
        // stays available (the action attaches first), as the others do.
        let loaded = controls.udid == udid && controls.isLoaded
        let canSet = isRunning && (!loaded || pinned != nil)
        Section(title) {
            Toggle("None", isOn: Binding(get: { false }, set: { _ in choose(.systemDefault, isOutput: isOutput) }))
                .disabled(!canSet)
            Toggle("Use System Settings", isOn: Binding(
                get: { pinned == .systemDefault },
                set: { if $0 { choose(.systemDefault, isOutput: isOutput) } }
            ))
            .disabled(!canSet)
            ForEach(devices, id: \.uid) { device in
                Toggle(device.name, isOn: Binding(
                    get: { pinned == .device(device.uid) },
                    set: { if $0 { choose(.device(device.uid), isOutput: isOutput) } }
                ))
                .disabled(!canSet)
            }
        }
    }

    private func choose(_ device: DevicectlAudioDevice, isOutput: Bool) {
        act { controls in
            if isOutput { await controls.setAudioOutput(device) } else { await controls.setAudioInput(device) }
        }
    }

    /// A checkmark item over an optional reading: unknown shows unchecked.
    private func flag(
        _ value: Bool?,
        _ control: AppleControl,
        _ write: @escaping @MainActor (AppleControlsController, Bool) async -> Void
    ) -> Binding<Bool> {
        Binding(get: { value == true }, set: { on in act { await write($0, on) } })
    }

    private func stepTextSize(by delta: Int) {
        act { controls in
            let sizes = SimulatorContentSize.settable
            guard let current = controls.state.textSize, let index = sizes.firstIndex(of: current) else { return }
            let next = min(max(index + delta, 0), sizes.count - 1)
            if next != index { await controls.setTextSize(sizes[next]) }
        }
    }

    /// Volume steps work before the controller has read the level (the
    /// action attaches first); once read, only where a level exists.
    private var volumeReady: Bool {
        isRunning && (controls.udid != udid || !controls.isLoaded || state.volume != nil)
    }

    private func stepVolume(by delta: Int) {
        act { controls in
            guard let current = controls.state.volume else { return }
            await controls.setVolume(min(max(current + delta * 10, 0), 100))
        }
    }

    // MARK: Face ID, Touch ID, Optic ID

    /// Device Hub lists all three, two of them dimmed; only the one this device
    /// type has is listed here (`AppleSettingsMenuPlan.biometricMenuTitle`).
    private func biometricMenu(_ title: String, symbol: String) -> some View {
        IconMenu(title, symbol, disabled: !isRunning) {
            Toggle("Enrolled", isOn: Binding(
                get: { state.biometricsEnrolled == true },
                set: { on in act { await $0.setBiometricsEnrolled(on) } }
            ))
            Divider()
            Button("Authorized with \(title)") { act { await $0.simulateBiometricMatch(success: true) } }
                .keyboardShortcut(BiometricShortcuts.shortcut(menu: title, deviceType: state.biometricType, matching: true))
                .disabled(state.biometricsEnrolled != true)
            Button("Unauthorized with \(title)") { act { await $0.simulateBiometricMatch(success: false) } }
                .keyboardShortcut(BiometricShortcuts.shortcut(menu: title, deviceType: state.biometricType, matching: false))
                .disabled(state.biometricsEnrolled != true)
        }
    }

    // MARK: Location

    private var locationMenu: some View {
        let current = controls.udid == udid ? controls.location : nil
        let scenarios = controls.udid == udid ? controls.locationScenarios : []
        return IconMenu("Location", "location", disabled: !isRunning) {
            ForEach(LocationMenuModel.entries(trips: LocationMenuModel.trips(named: scenarios))) { entry in
                switch entry {
                case .none:
                    Toggle(LocationMenuModel.noneTitle, isOn: Binding(
                        get: { current == nil },
                        set: { if $0 { act { await $0.setLocation(nil) } } }
                    ))
                case .separator:
                    Divider()
                case .place(let place):
                    Toggle(place.name, isOn: Binding(
                        get: { current == place.choice },
                        set: { if $0 { act { await $0.setLocation(place.choice) } } }
                    ))
                case .header(let title):
                    Text(title)
                case .trip(let trip):
                    Toggle(trip.name, isOn: Binding(
                        get: { current == .scenario(trip.name) },
                        set: { if $0 { act { await $0.setLocation(.scenario(trip.name)) } } }
                    ))
                case .custom:
                    Button(LocationMenuModel.customTitle) { workspace.window.deviceExtrasSheet = .customLocation }
                }
            }
        }
    }

    // MARK: Orientation

    private var orientationMenu: some View {
        IconMenu("Orientation", "rectangle.portrait.rotate", disabled: !isRunning) {
            ForEach([SimulatorDevicePose.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight], id: \.self) { pose in
                poseToggle(pose)
            }
            Divider()
            ForEach([SimulatorDevicePose.faceUp, .faceDown], id: \.self) { pose in
                poseToggle(pose)
            }
        }
    }

    private func poseToggle(_ pose: SimulatorDevicePose) -> some View {
        Toggle(AppleControlsText.poseName(pose), isOn: Binding(
            get: { state.pose == pose },
            set: { if $0 { act { await $0.setPose(pose) } } }
        ))
    }
}

// MARK: - Simulator: our extras

/// What Device Hub's Device menu does not carry and this app keeps: Push
/// Notification…, Permissions…, Open URL…, Language ▸, Time Zone…,
/// Status Bar ▸.
private struct SimulatorExtrasMenuItems: View {
    let workspace: DeviceWorkspace
    let udid: String
    let isRunning: Bool
    let plan: AppleSettingsMenuPlan
    let canOpenURL: Bool
    let simulatorActionDialogs: SimulatorActionDialogs
    let simulator: SimulatorEntry?
    let libraries: SavedLibraries?

    private var resendTitle: String {
        libraries?.lastPush.map { "Resend Last Push to \($0.bundleIdentifier)" } ?? "Resend Last Push"
    }

    private var controls: AppleControlsController { workspace.appleControls }
    private var state: AppleControlsState { controls.udid == udid ? controls.state : AppleControlsState() }

    private func act(_ body: @escaping @MainActor (AppleControlsController) async -> Void) {
        let controls = controls
        Task { @MainActor in
            await controls.ensureAttached(udid)
            await body(controls)
        }
    }

    var body: some View {
        Button("Push Notification…") { workspace.window.deviceExtrasSheet = .pushNotification }
            .disabled(!isRunning)
        Button(resendTitle) {
            guard let last = libraries?.lastPush else { return }
            act { controls in
                controls.targetBundle = last.bundleIdentifier
                controls.pushText = last.payload
                await controls.sendPush()
            }
        }
        .disabled(!isRunning || libraries?.lastPush == nil)
        Button("Permissions…") { workspace.window.deviceExtrasSheet = .permissions }
            .disabled(!isRunning)
        // `simctl openurl`: a web page or a deep link, with the recent links
        // Android's Links row keeps.
        Button("Open URL…") {
            if let simulator { simulatorActionDialogs.requestOpenURL(simulator) }
        }
        .disabled(!canOpenURL)
        if plan.showsSampleData { sampleDataMenu }

        Divider()
        languageMenu
        Button("Time Zone…") { workspace.window.deviceExtrasSheet = .timeZone }
            .disabled(!isRunning)
        if plan.showsStatusBarMenu { statusBarMenu }
    }

    // MARK: Sample data

    /// Fake contacts and numbered placeholder pictures, added with
    /// `simctl addmedia` (`SimulatorSampleData`). Calendar, Reminders and
    /// Health need a helper app on the simulator and are not offered.
    private var sampleDataMenu: some View {
        Menu("Add Sample Data") {
            Menu("Contacts") {
                ForEach([10, 50, 200], id: \.self) { count in
                    Button("\(count) Sample Contacts") {
                        Task { await workspace.simulatorApps.addSampleContacts(count: count, udid: udid) }
                    }
                }
            }
            Menu("Photos") {
                ForEach([6, 24, 100], id: \.self) { count in
                    Button("\(count) Sample Photos") {
                        Task { await workspace.simulatorApps.addSamplePhotos(count: count, udid: udid) }
                    }
                }
            }
        }
        .disabled(!isRunning || workspace.simulatorApps.isBusy)
    }

    // MARK: Language

    private var languageMenu: some View {
        let current = state.preferences?.languages.first.flatMap(DeviceLocale.init(tag:))
        return Menu("Language") {
            ForEach(DeviceLocalePresets.resolved(against: nil), id: \.tag) { locale in
                Toggle(DeviceLocaleNames.nativeName(locale), isOn: Binding(
                    get: { current?.tag == locale.tag },
                    set: { if $0 { act { await $0.setLanguage(locale) } } }
                ))
            }
            if controls.udid == udid, controls.respringSuggested {
                Divider()
                Button("Respring to Apply") { act { await $0.respring() } }
            }
            // The 24-hour time row's switch: without an override it shows the
            // clock the simulator's locale has.
            if plan.showsTimeFormat24 {
                Divider()
                Toggle("24-Hour Time", isOn: Binding(
                    get: { state.preferences?.uses24HourClock() == true },
                    set: { on in act { await $0.setTimeFormat(on ? .twentyFourHour : .twelveHour) } }
                ))
            }
        }
        .disabled(!isRunning)
    }

    // MARK: Status Bar

    private var statusBarMenu: some View {
        let isOn = controls.udid == udid && controls.statusBarActive == true
        return Toggle("Clean Status Bar", isOn: Binding(
            get: { isOn },
            set: { on in act { await $0.setCleanStatusBar(on) } }
        ))
        .disabled(!isRunning)
    }
}

// MARK: - Send Files

/// Device ▸ Send Files… (⇧⌘U): the panel that picks files and folders and where
/// they go, for the shown Android device, simulator or physical iPhone.
private struct SendFilesMenuItem: View {
    let workspace: DeviceWorkspace
    let model: AppModel?
    let simulatorActionDialogs: SimulatorActionDialogs

    private var target: SendFilesController.Target? {
        guard let model else { return nil }
        if case .physicalApple(let udid)? = workspace.deviceSelection {
            return model.physicalInventory.entry(udid: udid)?.canUseClient == true ? .physical(udid: udid) : nil
        }
        return workspace.stageSendFilesTarget(physical: model.physicalInventory)
    }

    var body: some View {
        let target = target
        Button("Send Files…") {
            guard let target else { return }
            Task {
                await workspace.sendFiles.presentPanel(for: target) { certificates in
                    if case .simulator(let udid) = target {
                        let name = model?.simulators.entry(udid: udid)?.name ?? udid
                        simulatorActionDialogs.requestTrust(certificates: certificates, udid: udid, simulator: name)
                    }
                }
            }
        }
        .keyboardShortcut("u", modifiers: [.command, .shift])
        .disabled(target == nil)
        if workspace.sendFiles.canCancel {
            Button("Cancel Transfer") { workspace.sendFiles.cancelTransfer() }
        }
    }
}

// MARK: - Android: our extras

/// Sensors…, Simulate ▸ (Incoming Call…, Incoming SMS…, Phone Number…,
/// Fingerprint Touch, Pause / Resume Emulator) and Open URL…, for a running
/// Android device.
private struct AndroidExtrasMenuItems: View {
    let workspace: DeviceWorkspace
    let showsOpenURL: Bool
    /// Sensors… and Simulate ▸ drive the emulator's console: a phone has none.
    let showsConsoleItems: Bool

    var body: some View {
        if showsConsoleItems { consoleItems }
        if showsOpenURL {
            Button("Open URL…") { workspace.window.deviceExtrasSheet = .openURL }
                .disabled(workspace.menuTargetSerial == nil)
        }
        Divider()
        Button("Port Forwarding…") { workspace.window.deviceExtrasSheet = .portForwarding }
            .disabled(workspace.menuTargetSerial == nil)
        Button("Shell…") { workspace.window.deviceExtrasSheet = .deviceShell }
            .disabled(workspace.menuTargetSerial == nil)
    }

    @ViewBuilder
    private var consoleItems: some View {
        Button("Sensors…") { workspace.window.deviceExtrasSheet = .sensors }
        Menu("Simulate") {
            // What the device has no hardware for is not listed (a TV has no
            // telephony, a watch no fingerprint sensor).
            if workspace.androidDeviceHas(DeviceWorkspace.telephonyFeature) {
                Button("Incoming Call…") { workspace.window.deviceExtrasSheet = .incomingCall }
                Button("Incoming SMS…") { workspace.window.deviceExtrasSheet = .incomingSMS }
                Button("Phone Number…") { workspace.window.deviceExtrasSheet = .phoneNumber }
                Divider()
            }
            if workspace.androidDeviceHas(DeviceWorkspace.fingerprintFeature) {
                // A simulator's Authorized with Face ID key.
                Button("Fingerprint Touch") { Task { await workspace.extras.touchFingerprint() } }
                    .keyboardShortcut("m", modifiers: [.command, .option, .shift])
                Divider()
            }
            Button(workspace.extras.isVmPaused ? "Resume Emulator" : "Pause Emulator") {
                Task { await workspace.extras.toggleVmPause() }
            }
        }
    }
}

// MARK: - The Controls menu

/// The contents of the Controls menu: Device Hub's set (Home, Lock, rotation,
/// screenshot, recording) for Apple devices, the Android set (Home, Back,
/// Recents, Assistant, Power, volume …) for an Android one.
struct ControlsMenuItems: View {
    @FocusedValue(\.appModel) private var model
    @FocusedValue(\.deviceWorkspace) private var workspace

    private var selectedSimulator: SimulatorEntry? {
        guard case .simulator(let udid)? = workspace?.deviceSelection else { return nil }
        return model?.simulators.entry(udid: udid)
    }

    private var simulatorMenu: SimulatorDeviceMenuState {
        SimulatorDeviceMenuState(
            device: workspace?.context.simulatorDevice,
            capabilities: workspace?.context.capabilities ?? [],
            selected: selectedSimulator,
            operation: selectedSimulator.flatMap { model?.simulatorLifecycle.operations[$0.udid] }
        )
    }

    private var hasSerial: Bool { workspace?.menuTargetSerial != nil }

    private var layout: DeviceMenuLayout {
        DeviceMenuLayout(selection: workspace?.deviceSelection, isRunning: hasSerial || simulatorMenu.isSelectedRunning)
    }

    private var canRotate: Bool { hasSerial || (shownIsSelected && simulatorMenu.canRotate) }

    /// Whether the device the context holds is the selected row's: capture,
    /// rotation and the rest act on the context's device, which a stopped
    /// row selected after a live one leaves in place, unseen.
    private var shownIsSelected: Bool { workspace?.contextIsSelection == true }

    /// Whether a simulator of `family` lists Shake.
    static func shakes(_ family: ControlsFamily) -> Bool { family == .iPhone || family == .iPad }

    /// The Controls menu of a stopped simulator: every item is off, as in
    /// Device Hub.
    private var isStoppedSimulator: Bool {
        selectedSimulator != nil && !simulatorMenu.isSelectedRunning
    }

    var body: some View {
        if layout.usesPhysicalMenus, let workspace {
            // Device Hub's Controls menu for the phone (`PhysicalDeviceMenus.swift`).
            PhysicalControlsMenuItems(workspace: workspace)
        } else {
            commonItems
        }
    }

    @ViewBuilder
    private var commonItems: some View {
        if layout.usesAndroidControls {
            androidButtons
        } else {
            appleButtons
        }
        // Device Hub drops the Rotate rows while a simulator is off.
        // A TV, a watch and a car do not rotate: no Rotate rows.
        let hidesRotate = (layout.kind == .simulator && !simulatorMenu.isSelectedRunning)
            || workspace?.deviceRotates == false
        if !hidesRotate {
            Divider()
            Button("Rotate Left") { Task { await workspace?.rotateDevice(.left) } }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!canRotate)
            Button("Rotate Right") { Task { await workspace?.rotateDevice(.right) } }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!canRotate)
        }
        Divider()
        Button("Screenshot") { Task { await workspace?.capture.takeScreenshot() } }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(isStoppedSimulator || !shownIsSelected || workspace?.capture.canTakeScreenshot != true)
        // The camera button's long press and right-click copy, as a menu item.
        Button("Copy Screenshot") { Task { await workspace?.capture.copyScreenshotToClipboard() } }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(isStoppedSimulator || !shownIsSelected || workspace?.capture.canTakeScreenshot != true)
        // Any mirrored device, a simulator's too (its canvas's frames, or
        // simctl's recording on the view-only canvas).
        Button(workspace?.media.isRecording == true ? "Stop Recording" : "Record Screen") {
            Task { await workspace?.media.toggleRecording() }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        // A running recording can always be stopped, wherever the selection went.
        .disabled(workspace?.media.isRecording != true
            && (isStoppedSimulator || !shownIsSelected || workspace?.media.canRecord != true))
        // The replay buffer is an Android device's and a simulator's live
        // canvas's; Device Hub has nothing like it. Hidden while the buffer
        // is off in Settings or the device keeps none (nothing to save).
        if layout.kind == .android || layout.kind == .simulator, workspace?.media.offersReplay == true {
            Button("Save Replay (\(workspace?.media.replayWindowLabel ?? "last 30 s"))") {
                Task { await workspace?.media.saveReplay() }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(!shownIsSelected || workspace?.media.canSaveReplay != true)
        }
    }

    /// Device Hub's Home, Lock and Siri for a simulator (a physical iPhone has
    /// its own menu, `PhysicalControlsMenuItems`).
    @ViewBuilder
    private var appleButtons: some View {
        Button("Home") { workspace?.simulatorCanvas.home() }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(!simulatorMenu.canPressHome)
        Button("Lock") { workspace?.simulatorCanvas.lock() }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(!simulatorMenu.canLock)
        if layout.kind == .simulator {
            // The Siri button (dtuhidd 0x0C/0xCF), held as a real press is.
            Button("Siri") { workspace?.simulatorCanvas.siri() }
                .keyboardShortcut("h", modifiers: [.command, .shift, .option])
                .disabled(!simulatorMenu.canPressHome)
            // Simulator.app's Device ▸ Shake (⌃⌘Z): a shake gesture is an
            // iPhone's and an iPad's, not a TV's, a watch's or a headset's
            // (not shown where it cannot work).
            if selectedSimulator.map({ Self.shakes(ControlsFamily.simulator(platform: $0.platform, productFamily: $0.productFamily)) }) ?? true {
                Button("Shake") { Task { await workspace?.simulatorCanvas.shake() } }
                    .keyboardShortcut("z", modifiers: [.command, .control])
                    .disabled(!simulatorMenu.canShake)
            }
            Divider()
            // Simulator.app's Debug ▸ Slow Animations (it was ⌘T, which New Tab
            // holds here, so ⌥⌘T) and Device ▸ Simulate Memory Warning (⇧⌘M).
            Toggle("Slow Animations", isOn: Binding(
                get: { workspace?.simulatorCanvas.isSlowAnimationOn ?? false },
                set: { _ in Task { await workspace?.simulatorCanvas.toggleSlowAnimations() } }
            ))
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(!simulatorMenu.canDebug)
            Button("Simulate Memory Warning") { workspace?.simulatorCanvas.simulateMemoryWarning() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!simulatorMenu.canDebug)
        }
    }

    @ViewBuilder
    private var androidButtons: some View {
        Button("Home") { Task { await workspace?.mirror.goHome() } }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(!hasSerial)
        Button("Back") { Task { await workspace?.mirror.goBack() } }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!hasSerial)
        Button("Recents") { Task { await workspace?.mirror.openRecents() } }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!hasSerial)
        // A simulator's Siri key.
        Button("Assistant") { Task { await workspace?.mirror.openAssistant() } }
            .keyboardShortcut("h", modifiers: [.command, .option, .shift])
            .disabled(!hasSerial)
        Button("Previous App") { Task { await workspace?.mirror.switchToPreviousApp() } }
            .keyboardShortcut("[", modifiers: [.command, .option])
            .disabled(!hasSerial)
        // A TV (leanback only) has no split screen.
        if !(workspace.map { $0.androidHasReadFeatures && $0.androidDeviceHas(DeviceWorkspace.leanbackOnlyFeature) } ?? false) {
            Button("Split Screen") { Task { await workspace?.mirror.splitScreen() } }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(!hasSerial)
        }
        Divider()
        // ⌘L is Device Hub's Lock: Power is its Android equivalent.
        Button("Power") { Task { await workspace?.mirror.power() } }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(!hasSerial)
        Button("Power Menu") { Task { await workspace?.mirror.showPowerMenu() } }
            .disabled(!hasSerial)
        Divider()
        // A simulator's Sound ▸ Increase / Decrease Volume keys.
        Button("Volume Up") { Task { await workspace?.mirror.volumeUp() } }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(!hasSerial)
        Button("Volume Down") { Task { await workspace?.mirror.volumeDown() } }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(!hasSerial)
        Button("Mute") { Task { await workspace?.mirror.muteAudio() } }
            .disabled(!hasSerial)
        // The same ⌃⌘Z as a simulator's: the virtual accelerometer is jolted.
        // A running device without a console port (a phone) has none: not listed.
        // Nor one without an accelerometer (a TV).
        if !(hasSerial && workspace?.context.port == nil),
           workspace?.androidDeviceHas(DeviceWorkspace.accelerometerFeature) != false {
            Button("Shake") { Task { await workspace?.extras.shake() } }
                .keyboardShortcut("z", modifiers: [.command, .control])
                .disabled(!hasSerial)
        }
        // The App conditions row's Send (`am send-trim-memory`) on the panel's
        // target app: listed where the row is, off until an app is chosen.
        if let workspace, hasSerial,
           AndroidLowMemoryMenu.isShown(
               family: workspace.androidControlsFamily(),
               showsAppConditions: workspace.conditions.showsAppConditions,
               showsLowMemory: workspace.conditions.showsLowMemory
           ) {
            Button("Simulate Low Memory") { Task { await AndroidSettingsMenuActions(workspace: workspace).simulateLowMemory() } }
                // A simulator's Simulate Memory Warning key.
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!AndroidLowMemoryMenu.isEnabled(
                    targetPackage: workspace.conditions.targetPackage,
                    gate: workspace.conditions.lowMemoryGate,
                    isWriting: workspace.conditions.isWriting
                ))
        }
    }
}

extension DeviceWorkspace {
    /// The adb serial the menus may act on: the mirrored device, only while
    /// it is the selected row's. With a stopped AVD selected the context
    /// could still hold the device shown before (its mirror ends lazily), and
    /// Controls ▸ Home sent that unseen device home.
    var menuTargetSerial: String? {
        guard let serial = context.serial, liveSelectionSerial == serial else { return nil }
        return serial
    }

    /// Whether the device in the context is the selected row's: an adb
    /// device by `menuTargetSerial`, an Apple device by its identifier.
    var contextIsSelection: Bool {
        if menuTargetSerial != nil { return true }
        guard let device = context.device, device.platform == .apple else { return false }
        return Self.sessionBelongs(to: deviceSelection, sessionDevice: device, isPhysicalView: context.isPhysicalView)
    }
}
