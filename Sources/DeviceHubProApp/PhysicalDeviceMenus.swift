import AppKit
import SwiftUI
import DeviceHubProKit

// The Device, Controls and "..." menus for a selected physical iPhone or iPad,
// built as Device Hub builds its own for the phone (measured on Device Hub
// 27.0 with the test iPhone, 2026-09-29) with only the items this app can
// carry out. Device Hub's Lock, Action Button, CarPlay Simulator, Restart,
// Unpair, Rename, Collect sysdiagnose and Show in Finder have no route here
// and are not listed; Battery, Face ID / Touch ID / Optic ID and Sound are
// Device Hub's disabled rows for the phone and are not listed either.
//
// The layout is data (`PhysicalMenuLayout`) that the views render from, so a
// test reads exactly what the menus show. The commands are the iOS session's
// API on `DeviceWorkspace.physicalLive` (`PhysicalLiveViewController`); the
// settings submenus act through `AppleControlsController`, attached to the
// phone on demand, as the Controls panel attaches it.

// MARK: - Layout (pure)

enum PhysicalMenuLayout {
    // MARK: Device menu

    /// One row of the Device menu for a physical iPhone.
    enum DeviceEntry: Equatable {
        case accessibility
        case appearance
        case location
        case keyboard
        case openURL
        case liveView
        case autoRefresh
        case control
        case muteAudio
        case separator

        var title: String? {
            switch self {
            case .accessibility: "Accessibility"
            case .appearance: "Appearance"
            case .location: "Location"
            case .keyboard: "Keyboard"
            case .openURL: "Open URL…"
            // Ours, not Device Hub's: the switches the stage's banner used to
            // hold, titled so they read as what they turn on.
            case .liveView: "Live View"
            case .autoRefresh: "Auto-refresh Screenshots"
            case .control: "Control This iPhone"
            case .muteAudio: "Mute iPhone Audio"
            case .separator: nil
            }
        }
    }

    /// Device Hub's structure for the phone (Accessibility, Appearance,
    /// Location; Keyboard), then ours. No Enter Resize Mode: a phone's display
    /// cannot be resized, so the item is not listed.
    /// This is the superset; `deviceEntries(...)` drops what this phone lacks.
    static let deviceEntries: [DeviceEntry] = [
        .accessibility, .appearance, .location,
        .separator,
        .keyboard,
        .separator,
        .openURL,
        .separator,
        .liveView, .autoRefresh, .control, .muteAudio,
    ]

    /// "Mute iPhone Audio" is on only while the phone's audio is captured.
    static func muteAudioEnabled(hasAudio: Bool) -> Bool { hasAudio }

    /// What the Device menu lists for this phone: the submenus its capability list
    /// has, and the mute item only while the phone's audio is played. Hidden items
    /// take their rules with them (no leading, trailing or doubled rule).
    static func deviceEntries(
        showsAccessibility: Bool = true, showsAppearance: Bool = true, showsLocation: Bool = true,
        hasAudio: Bool = true
    ) -> [DeviceEntry] {
        tidied(deviceEntries.filter { entry in
            switch entry {
            case .accessibility: showsAccessibility
            case .appearance: showsAppearance
            case .location: showsLocation
            case .muteAudio: muteAudioEnabled(hasAudio: hasAudio)
            default: true
            }
        }, isSeparator: { $0 == .separator })
    }

    /// `entries` without a rule at either end or two in a row.
    static func tidied<Entry>(_ entries: [Entry], isSeparator: (Entry) -> Bool) -> [Entry] {
        var result: [Entry] = []
        for entry in entries {
            if isSeparator(entry), result.isEmpty || isSeparator(result[result.count - 1]) { continue }
            result.append(entry)
        }
        while let last = result.last, isSeparator(last) { result.removeLast() }
        return result
    }

    // MARK: Controls menu

    /// One row of the Controls menu for a physical iPhone.
    enum ControlsEntry: Equatable {
        case home
        case siri
        case appSwitcher
        case rotateLeft
        case rotateRight
        case screenshot
        case recordScreen
        case separator

        var title: String? {
            switch self {
            case .home: "Home"
            case .siri: "Siri"
            case .appSwitcher: "App Switcher"
            case .rotateLeft: "Rotate Left"
            case .rotateRight: "Rotate Right"
            case .screenshot: "Screenshot"
            case .recordScreen: "Record Screen"
            case .separator: nil
            }
        }

        /// Whether the row is enabled. The buttons that press the phone
        /// (`controlAvailability`: nil when Control is on or can start) wait
        /// on Control; Screenshot needs a picture to save; Record Screen needs
        /// the USB live capture (Device Hub greys it out, but ours records
        /// that capture; the screenshot preview is too sparse to record).
        func isEnabled(controlAvailability: String?, canTakeScreenshot: Bool, canRecord: Bool = false) -> Bool {
            switch self {
            case .home, .siri, .appSwitcher, .rotateLeft, .rotateRight: controlAvailability == nil
            case .screenshot: canTakeScreenshot
            case .recordScreen: canRecord
            case .separator: false
            }
        }

        /// The tooltip of a disabled press: why Control is not available.
        func help(controlAvailability: String?) -> String? {
            switch self {
            case .home, .siri, .appSwitcher, .rotateLeft, .rotateRight: controlAvailability
            case .screenshot, .recordScreen, .separator: nil
            }
        }
    }

    /// Device Hub's order less Lock and Action Button: Home, Siri, App
    /// Switcher; the two rotations; Screenshot, Record Screen.
    static let controlsEntries: [ControlsEntry] = [
        .home, .siri, .appSwitcher,
        .separator,
        .rotateLeft, .rotateRight,
        .separator,
        .screenshot, .recordScreen,
    ]

    /// The Controls menu for this phone: Record Screen only while the USB live
    /// capture can record (or a recording runs and can be stopped).
    static func controlsEntries(showsRecordScreen: Bool) -> [ControlsEntry] {
        tidied(controlsEntries.filter { $0 != .recordScreen || showsRecordScreen }, isSeparator: { $0 == .separator })
    }

    // MARK: "..." menu

    /// One row of the toolbar's "..." menu for a physical iPhone.
    enum MoreEntry: Equatable {
        case stopScreenSharing(isEnabled: Bool)
        case separator
        case openInNewTab
        case openInNewWindow

        var title: String? {
            switch self {
            case .stopScreenSharing: "Stop Screen Sharing"
            case .separator: nil
            case .openInNewTab: "Open in New Tab"
            case .openInNewWindow: "Open in New Window"
            }
        }
    }

    /// Device Hub's items that have a route here: Stop Screen Sharing (the
    /// live view off; on while it is on and the device is usable), and the
    /// open-elsewhere pair, only with multi-window on.
    static func moreEntries(canUseClient: Bool, liveViewOn: Bool, multiWindow: Bool) -> [MoreEntry] {
        var entries: [MoreEntry] = [.stopScreenSharing(isEnabled: canUseClient && liveViewOn)]
        if multiWindow {
            entries.append(.separator)
            entries.append(.openInNewTab)
            entries.append(.openInNewWindow)
        }
        return entries
    }
}

// MARK: - Controller helper

extension AppleControlsController {
    /// The Device menu's settings act through the controller the panel reads
    /// with, attached to the phone only while the panel shows it: attach it
    /// (once) for a menu action, or wait for the attach already running.
    func ensurePhysicalAttached(_ hardwareUDID: String) async {
        let key = PhysicalDeviceOptIn.normalize(hardwareUDID)
        if !(isPhysical && udid == key) { await attachPhysical(hardwareUDID) }
        var waited = 0
        while isPhysical, udid == key, !isLoaded, waited < 200 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
    }
}

// MARK: - Device menu

/// The Device menu of a selected physical iPhone.
struct PhysicalDeviceMenuItems: View {
    let workspace: DeviceWorkspace
    let udid: String
    /// Whether the phone is enabled, paired and connected.
    let isUsable: Bool
    let model: AppModel?

    private var live: PhysicalLiveViewController { workspace.physicalLive }
    private var controls: AppleControlsController { workspace.appleControls }
    private var key: String { PhysicalDeviceOptIn.normalize(udid) }
    private var isAttached: Bool { controls.isPhysical && controls.udid == key }
    private var state: AppleControlsState { isAttached ? controls.state : AppleControlsState() }

    private func act(_ body: @escaping @MainActor (AppleControlsController) async -> Void) {
        let controls = controls
        let udid = udid
        Task { @MainActor in
            await controls.ensurePhysicalAttached(udid)
            await body(controls)
        }
    }

    /// Which settings the phone's capability list takes (everything until the
    /// controller has read the phone; the action attaches first).
    private var plan: AppleSettingsMenuPlan {
        let attached = isAttached && controls.isLoaded
        return AppleSettingsMenuPlan(
            family: .physicalApple,
            routeOffers: { control in !attached || controls.route(control).isOffered }
        )
    }

    var body: some View {
        let plan = plan
        let entries = Array(PhysicalMenuLayout.deviceEntries(
            showsAccessibility: plan.showsAccessibility,
            showsAppearance: plan.showsAppearance,
            showsLocation: plan.showsLocation,
            hasAudio: live.hasAudio
        ).enumerated())
        ForEach(entries, id: \.offset) { _, entry in
            row(entry, plan: plan)
        }
    }

    @ViewBuilder
    private func row(_ entry: PhysicalMenuLayout.DeviceEntry, plan: AppleSettingsMenuPlan) -> some View {
        switch entry {
        case .separator:
            Divider()
        case .accessibility:
            accessibilityMenu(plan.accessibilityGroups)
        case .appearance:
            appearanceMenu
        case .location:
            locationMenu
        case .keyboard:
            KeyboardMenu(model: model, workspace: workspace, avdName: nil, isRunning: false)
        case .openURL:
            Button("Open URL…") { workspace.window.deviceExtrasSheet = .physicalOpenURL }
                .disabled(!isUsable)
        case .liveView:
            Toggle(entry.title ?? "", isOn: Binding(
                get: { live.liveViewEnabled },
                set: { live.setLiveView($0) }
            ))
        case .autoRefresh:
            Toggle(entry.title ?? "", isOn: Binding(
                get: { live.autoRefreshEnabled },
                set: { live.setAutoRefresh($0) }
            ))
        case .control:
            // Nothing to turn on while fast input carries the input by itself
            // only a Retry after a failure. The
            // switch remains for the runner route when fast input is off.
            if live.inputIsAutomatic {
                if live.inputFailure != nil {
                    Button("Retry iPhone Input") { live.retryInput() }
                }
            } else {
                Toggle(entry.title ?? "", isOn: Binding(
                    get: { live.controlEnabled },
                    set: { live.setControl($0) }
                ))
                // The reason Control cannot start, when it cannot.
                .disabled(!live.controlEnabled && live.controlAvailability != nil)
                .help(live.controlEnabled ? "" : (live.controlAvailability ?? ""))
            }
        case .muteAudio:
            Toggle(entry.title ?? "", isOn: Binding(
                get: { live.isAudioMuted },
                set: { _ in live.toggleAudioMuted() }
            ))
        }
    }

    // MARK: Accessibility, Appearance

    private func accessibilityMenu(_ groups: [[AppleSettingsMenuPlan.AccessibilityItem]]) -> some View {
        IconMenu("Accessibility", "accessibility", disabled: !isUsable) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group, id: \.self) { item in accessibilityRow(item) }
            }
        }
    }

    @ViewBuilder
    private func accessibilityRow(_ item: AppleSettingsMenuPlan.AccessibilityItem) -> some View {
        switch item {
        case .reduceMotion:
            Toggle("Reduce Motion", isOn: flag(state.reduceMotion) { await $0.setReduceMotion($1) })
        case .reduceTransparency:
            Toggle("Reduce Transparency", isOn: flag(state.reduceTransparency) { await $0.setReduceTransparency($1) })
        case .increaseContrast:
            Toggle("Increase Contrast", isOn: flag(state.increaseContrast) { await $0.setIncreaseContrast($1) })
        case .showBorders:
            Toggle("Show Borders", isOn: flag(state.showBorders) { await $0.setShowBorders($1) })
        case .textSize:
            Button("Increase Text Size") { stepTextSize(by: 1) }
                .keyboardShortcut("+", modifiers: [.command, .option])
            Button("Decrease Text Size") { stepTextSize(by: -1) }
                .keyboardShortcut("-", modifiers: [.command, .option])
        case .voiceOver:
            Toggle("VoiceOver", isOn: flag(state.voiceOver) { await $0.setVoiceOver($1) })
        }
    }

    private var appearanceMenu: some View {
        IconMenu("Appearance", "circle.lefthalf.filled", disabled: !isUsable) {
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

    /// A checkmark item over an optional reading: unknown shows unchecked.
    private func flag(
        _ value: Bool?,
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

    // MARK: Location

    /// None, Device Hub's fourteen places and Custom Coordinates…. The phone
    /// takes a place or a coordinate, not a trip (`devicectl device simulate
    /// location`), so there is no Trips section.
    private var locationMenu: some View {
        let current = isAttached ? controls.location : nil
        return IconMenu("Location", "location", disabled: !isUsable) {
            Toggle("None", isOn: Binding(
                get: { current == nil },
                set: { if $0 { act { await $0.setLocation(nil) } } }
            ))
            Divider()
            ForEach(AppleLocationPlaces.all) { place in
                Toggle(place.name, isOn: Binding(
                    get: { current == place.choice },
                    set: { if $0 { act { await $0.setLocation(place.choice) } } }
                ))
            }
            Divider()
            Button("Custom Coordinates…") {
                // The sheet writes through the attached controller.
                act { _ in }
                workspace.window.deviceExtrasSheet = .customLocation
            }
        }
    }
}

// MARK: - Controls menu

/// The Controls menu of a selected physical iPhone.
struct PhysicalControlsMenuItems: View {
    let workspace: DeviceWorkspace

    private var live: PhysicalLiveViewController { workspace.physicalLive }

    var body: some View {
        let availability = live.controlAvailability
        // The phone's own picture only, not one an earlier device left in the context.
        let canScreenshot = workspace.contextIsSelection && workspace.capture.canTakeScreenshot
        // Recording follows the USB live capture only (or stops a running one);
        // without it the item is not listed.
        let canRecord = workspace.media.isRecording
            || (workspace.media.canRecord && workspace.mirror.session is PhysicalScreenCaptureSession)
        let entries = Array(PhysicalMenuLayout.controlsEntries(showsRecordScreen: canRecord).enumerated())
        ForEach(entries, id: \.offset) { _, entry in
            row(entry, availability: availability, canScreenshot: canScreenshot, canRecord: canRecord)
        }
    }

    @ViewBuilder
    private func row(
        _ entry: PhysicalMenuLayout.ControlsEntry, availability: String?, canScreenshot: Bool, canRecord: Bool
    ) -> some View {
        // Rotate needs no Control: it has its own availability (an enabled, ready iPhone).
        let isRotate = entry == .rotateLeft || entry == .rotateRight
        let availability = isRotate ? live.rotationAvailability : availability
        let enabled = entry.isEnabled(controlAvailability: availability, canTakeScreenshot: canScreenshot, canRecord: canRecord)
        let help = entry.help(controlAvailability: availability) ?? ""
        switch entry {
        case .separator:
            Divider()
        case .home:
            Button("Home") { live.pressHome() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!enabled).help(help)
        case .siri:
            Button("Siri") { live.activateSiri() }
                .keyboardShortcut("h", modifiers: [.command, .shift, .option])
                .disabled(!enabled).help(help)
        case .appSwitcher:
            Button("App Switcher") { live.showAppSwitcher() }
                .keyboardShortcut("h", modifiers: [.command, .shift, .control])
                .disabled(!enabled).help(help)
        case .rotateLeft:
            Button("Rotate Left") { live.rotate(left: true) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!enabled).help(help)
        case .rotateRight:
            Button("Rotate Right") { live.rotate(left: false) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!enabled).help(help)
        case .screenshot:
            Button("Screenshot") { live.takeScreenshot() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!enabled)
        case .recordScreen:
            Button(workspace.media.isRecording ? "Stop Recording" : "Record Screen") {
                Task { await workspace.media.toggleRecording() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!enabled)
            .help(enabled ? "" : "Record Screen needs the phone connected with a cable and Live View on.")
        }
    }
}

// MARK: - Open URL sheet

/// Device ▸ Open URL… for a physical iPhone: the link is handed to the phone
/// (`device process openURL`) through `PhysicalAppsController.openURL(_:)`.
struct PhysicalOpenURLSheet: View {
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var apps = workspace.physicalApps
        let recents = workspace.links.recents.links
        DHSheet(
            // A simulator's sheet names its device ("Open URL on “iPhone 17 Pro”").
            title: workspace.context.device.map { "Open URL on \(dhQuoted(workspace.services.displayName(of: $0)))" } ?? "Open URL",
            width: 470,
            actions: [
                DHSheetAction(
                    title: "Open",
                    isEnabled: !apps.openURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    isDefault: true
                ) {
                    let text = apps.openURLDraft
                    dismiss()
                    Task { await workspace.physicalApps.openURL(text) }
                },
            ]
        ) {
            DHSheetCard {
                DHSheetRow(title: "URL:") {
                    HStack(spacing: 6) {
                        DHSheetTextField(
                            placeholder: "URL or deep link",
                            text: $apps.openURLDraft,
                            width: 280
                        )
                        Menu {
                            ForEach(recents, id: \.self) { link in
                                Button(LinksRowText.recentTitle(link)) { apps.openURLDraft = link }
                            }
                            Divider()
                            Button("Clear Recents") { workspace.links.recents.clear() }
                        } label: {
                            Label("Recent URLs", systemImage: LinksRowText.recentGlyph)
                            .labelStyle(.iconOnly)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(recents.isEmpty)
                        .help("Recent URLs")
                        .accessibilityLabel("Recent URLs")
                    }
                }
            }
        }
    }
}
