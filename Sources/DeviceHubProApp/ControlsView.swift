import SwiftUI
import DeviceHubProKit

/// The Android Controls inspector, organized as collapsible domain groups in
/// Device Hub's card/row language: Network (the switches, then the emulator's network conditions), App
/// conditions, Power & battery, Location,
/// Language & time, Display & sound, Accessibility and Debug (`controlsGroups(_:)` orders and gates them). The daily groups start
/// expanded; the conditions and UI/a11y/QA-pass groups
/// start collapsed; the URL and Clean status bar rows are plain rows at the bottom. Sensors, Telephony and Emulator state left
/// the panel for the Device menu (2026-09-29; their actions stay on
/// `workspace.extras`); Fingerprint is back, in Biometrics, beside its menu item. Metrics live in `ParityMetrics`.
struct ControlsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace

    var body: some View {
        // A simulator has its own panel: its rows, mechanisms and poll
        // (AppleControlsView); the Android reads below never run for it.
        if case .simulator(let udid)? = workspace.deviceSelection {
            AppleControlsView(udid: udid)
        } else if case .physicalApple(let udid)? = workspace.deviceSelection {
            // A physical iPhone's Controls: the rows its CoreDevice
            // capability list offers (ApplePhysicalControlsView).
            if let entry = model.physicalInventory.entry(udid: udid) {
                ApplePhysicalControlsView(entry: entry)
            } else {
                DeviceNoLongerListedState(glyph: "slider.horizontal.3")
            }
        } else {
            androidPanel
        }
    }

    private var androidPanel: some View {
        @Bindable var location = workspace.location

        // A stopped AVD keeps its last session in the workspace for a
        // while; the panel follows the selection's live serial (as Apps and
        // Reports do), so a stopped one shows DH's placeholder, not a list.
        let content = controlsPanelContent(
            // The mirrored device only while it is the selected row's: a live
            // row this tab has not attached (shown in another tab, or its
            // attach failed) must not get the earlier device's rows.
            activeSerial: workspace.menuTargetSerial,
            controlsLoaded: workspace.controlsPanel.controlsLoaded
        )

        return Group {
            if content == .noDevice {
                // DH's empty state fills the whole panel (CT-10); it is
                // never inside the card scroll below.
                noDeviceCard
            } else {
                DHSettingsPanel {
                    if let reason = workspace.controlsPanel.recoveryReason {
                        recoveryCard(reason)
                    }
                    if content == .loading {
                        loadingCard
                    }
                    ForEach(groups) { group in
                        DHGroup(
                            id: group.id.rawValue,
                            title: group.id.title,
                            defaultExpanded: group.id.defaultExpanded,
                            forceExpanded: model.expandAllControlsGroups
                        ) {
                            groupRows(group)
                        }
                    }
                    // Plain rows after the groups (no disclosure).
                    if !trailingRows.isEmpty {
                        DHCard {
                            ForEach(Array(trailingRows.enumerated()), id: \.element) { index, row in
                                rowView(row)
                                if index != trailingRows.count - 1 {
                                    DHHairline()
                                }
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $location.isLocationSheetPresented) {
            AndroidCustomLocationSheet()
        }
        .task(id: ControlsPollKey(serial: workspace.menuTargetSerial, isWindowVisible: workspace.window.isWindowVisible)) {
            // Nothing to read without a mirrored device; the next attach
            // changes the id and starts the poll. A fully occluded or
            // miniaturized window stops it too — the id
            // changing on either edge cancels the old task before this one
            // runs, so a hidden window neither refreshes once more nor
            // keeps polling.
            guard workspace.menuTargetSerial != nil, workspace.window.isWindowVisible else { return }
            await workspace.controlsPanel.refreshControls()
            await workspace.hardware.refreshResizePresets()
            await ControlsPoll.run { await workspace.controlsPanel.refreshControls() }
        }
        .task(id: ControlsPollKey(serial: workspace.menuTargetSerial, isWindowVisible: workspace.window.isWindowVisible)) {
            // The Network and App conditions rows and the Status bar group
            // poll on the same beat, their reads side by side; gated the
            // same way.
            guard workspace.menuTargetSerial != nil, workspace.window.isWindowVisible else { return }
            await refreshConditions()
            await ControlsPoll.run { await refreshConditions() }
        }
    }

    /// The Controls poll's `.task(id:)` key: restarts the
    /// poll on a device switch, same as before, and now also on the
    /// window's occlusion edges, so hiding or showing the window cancels
    /// the old task and lets the new one decide whether to poll at all.
    private struct ControlsPollKey: Equatable {
        let serial: String?
        let isWindowVisible: Bool
    }

    private func refreshConditions() async {
        let conditions = workspace.conditions
        let statusBar = conditions.statusBar
        async let conditionsRead: Void = conditions.refresh()
        async let statusBarRead: Void = statusBar.refresh()
        _ = await (conditionsRead, statusBarRead)
    }

    // MARK: - Groups

    private var availability: ControlsGroupAvailability { workspace.androidControlsAvailability }

    /// The Links rows' API level: the Info read, else the preview's.
    private var linksAPILevel: Int? {
        workspace.links.apiLevel(
            deviceInfo: workspace.context.serial
                .flatMap { model.inventory.deviceInfos[$0] }
                .flatMap { Int($0.apiLevel) }
        )
    }

    private var groups: [ControlsGroup] { controlsGroups(availability, family: family) }

    /// The plain rows at the bottom of the panel (`controlsTrailingRows`).
    private var trailingRows: [ControlsRow] { controlsTrailingRows(availability, family: family) }

    /// The mirrored device's class, from its `ro.build.characteristics`
    /// (handheld until the Info read lands).
    private var family: ControlsFamily { workspace.androidControlsFamily() }

    private var languageTime: LanguageTimeController { workspace.controlsPanel.languageTime }

    private var colorFilters: ColorFilterController { workspace.controlsPanel.colorFilters }

    /// Rows whose presence depends on a live reading are filtered here; the
    /// model keeps the canonical order.
    private func visibleRows(in group: ControlsGroup) -> [ControlsRow] {
        group.rows.filter { row in
            switch row {
            case .battery, .charging:
                return workspace.controlsPanel.controls.battery != nil
            default:
                return true
            }
        }
    }

    @ViewBuilder
    private func groupRows(_ group: ControlsGroup) -> some View {
        let rows = visibleRows(in: group)
        ForEach(Array(rows.enumerated()), id: \.element) { index, row in
            rowView(row)
            if index != rows.count - 1 {
                DHHairline()
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func rowView(_ row: ControlsRow) -> some View {
        switch row {
        case .wifi:
            DHToggleRow(
                title: "Wi-Fi",
                glyph: "wifi",
                help: "Turns Wi-Fi on or off.",
                value: workspace.controlsPanel.controls.wifiEnabled
            ) { _ in await workspace.controlsPanel.toggleWifi() }
        case .bluetooth:
            DHToggleRow(
                title: "Bluetooth",
                glyph: "bolt.horizontal",
                help: "Turns Bluetooth on or off.",
                value: workspace.controlsPanel.controls.bluetoothEnabled
            ) { _ in await workspace.controlsPanel.toggleBluetooth() }
        case .airplaneMode:
            DHToggleRow(
                title: "Airplane mode",
                glyph: "airplane",
                help: "Turns airplane mode on or off.",
                value: workspace.controlsPanel.controls.airplaneModeEnabled
            ) { _ in await workspace.controlsPanel.toggleAirplaneMode() }
        case .mobileData:
            DHToggleRow(
                title: "Mobile data",
                glyph: "antenna.radiowaves.left.and.right",
                help: "Turns mobile data on or off.",
                value: workspace.controlsPanel.controls.mobileDataEnabled
            ) { _ in await workspace.controlsPanel.toggleMobileData() }
        case .dataSaver:
            DHToggleRow(
                title: "Data Saver",
                glyph: "leaf.circle",
                help: "Restricts background data use.",
                value: workspace.controlsPanel.controls.dataSaverEnabled
            ) { await workspace.controlsPanel.setDataSaver($0) }
        case .battery:
            batteryRow
        case .charging:
            DHToggleRow(
                title: "Charging",
                glyph: "bolt.fill",
                help: "Plugs or unplugs the emulator's charger. Battery saver can't turn on while the device is charging.",
                value: workspace.controlsPanel.controls.battery?.isCharging
            ) { _ in await workspace.hardware.toggleCharging() }
        case .batterySaver:
            batterySaverRow
        case .location:
            locationRow
        case .appearance:
            appearanceRow
        case .textSize:
            textSizeRow
        case .reduceMotion:
            DHToggleRow(
                title: "Reduce Motion",
                glyph: "figure.walk.motion",
                help: "Turns off the system's window and transition animations.",
                value: workspace.controlsPanel.deviceSettings.reduceMotion?.isEnabled
            ) { await workspace.controlsPanel.setReduceMotion($0) }
        case .showBorders:
            DHToggleRow(
                title: "Show Borders",
                glyph: "rectangle.dashed",
                help: "Outlines the edges and margins of every view, like Show layout bounds in Developer options.",
                value: workspace.controlsPanel.deviceSettings.showBorders?.isOn
            ) { await workspace.controlsPanel.setShowBorders($0) }
        case .sound:
            soundRow
        case .talkBack:
            DHToggleRow(
                title: "TalkBack",
                glyph: "accessibility",
                help: "Shown only while TalkBack is installed.",
                value: workspace.controlsPanel.deviceSettings.voiceOver?.isOn
            ) { await workspace.controlsPanel.setTalkBack($0) }
        // Color filters (ColorFilterControlsRows.swift)
        case .colorFilter:
            ColorFilterRow(title: "Color Filter")
        case .increaseContrast:
            DHToggleRow(
                title: "Increase Contrast",
                glyph: "circle.lefthalf.filled",
                help: "Draws text with higher contrast.",
                value: workspace.controlsPanel.deviceSettings.increaseContrast?.isOn
            ) { await workspace.controlsPanel.setIncreaseContrast($0) }
        case .forceRTL:
            toggleRow(.forceRTL)
        case .showTaps:
            toggleRow(.showTaps)
        case .backgroundANRs:
            toggleRow(.showBackgroundANRs)
        // Language & time (LanguageTimeControlsRows.swift)
        case .deviceLanguage:
            DeviceLanguageRow(title: "Language")
        case .dateTime:
            DateTimeRow(title: "Date & time")
        case .timeZone:
            TimeZoneRow(title: "Time zone")
        case .timeFormat24:
            TimeFormatRow(title: "24-hour time")
        case .networkSpeed, .connectionLatency, .meteredMobileData,
             .resetConditions, .targetApp, .lowMemory, .killProcess:
            ConditionsRowView(row: row)
        // Link URL (LinksControlsRows.swift)
        case .linkURL:
            LinksRowView(row: row)
        // Clean status bar (StatusBarControlsRows.swift)
        case .cleanStatusBar:
            StatusBarRowView(row: row)
        case .fingerprint:
            fingerprintRow
        // iOS only: a simulator's panel draws them (AppleControlsView);
        // `controlsGroups(_:)` never lists them.
        case .liquidGlass, .reduceTransparency, .audioOutput, .audioInput,
             .biometricsEnrolled, .biometricsMatch, .permissions, .permissionsAccess, .pushNotification,
             .launchApp, .terminateApp, .memoryWarning, .addRootCertificate, .resetKeychain,
             .resetDefaults:
            EmptyView()
        }
    }

    /// A developer toggle. Toggles Android applies only at the next restart
    /// (Force RTL before Android 8, Wi-Fi verbose logging before Android 11)
    /// say so under the row, and say when a restart is still pending.
    private func toggleRow(_ toggle: DeviceToggle) -> some View {
        let status = toggleRowStatus(for: workspace.controlsPanel.deviceSettings.effect(for: toggle))
        return VStack(spacing: 0) {
            DHToggleRow(
                title: toggle.label,
                glyph: glyph(for: toggle),
                help: help(for: toggle),
                value: workspace.controlsPanel.deviceSettings.reading(for: toggle)?.isOn,
                accessibilityStatus: status.accessibilityStatus
            ) { await workspace.controlsPanel.setToggle(toggle, enabled: $0) }
            if let caption = status.caption {
                DHCaptionRow(caption)
            }
        }
    }

    /// Battery saver: disabled while a charger is connected (Android refuses
    /// it then); the Charging row above is the one control for the charger,
    /// and the reason is in this row's help.
    private var batterySaverRow: some View {
        let row = batterySaverRowModel(
            saverEnabled: workspace.controlsPanel.controls.batterySaverEnabled,
            effect: workspace.controlsPanel.deviceSettings.effects?.batterySaver,
            devicePowered: workspace.controlsPanel.deviceSettings.effects?.isPowered,
            emulatorCharging: workspace.controlsPanel.controls.battery?.isCharging
        )
        return VStack(spacing: 0) {
            DHToggleRow(
                title: "Battery saver",
                glyph: "leaf",
                help: dhHelp(
                    "Runs cmd power set-mode. Android refuses battery saver while the device is charging.",
                    row.caption
                ),
                value: row.value,
                accessibilityStatus: row.isEnabled || row.value == nil ? nil : "unavailable while charging"
            ) { _ in await workspace.controlsPanel.toggleBatterySaver() }
            .disabled(!row.isEnabled)
            // A phone has no Charging row to turn the charger off: the dimmed
            // switch says why right under it, not only on hover.
            if let caption = Self.batterySaverCaption(row) {
                DHCaptionRow(caption)
            }
        }
    }

    /// The line under a phone's dimmed Battery saver switch; nil where the
    /// switch works or the emulator's Charging row is the way out.
    static func batterySaverCaption(_ row: BatterySaverRowModel) -> String? {
        guard !row.isEnabled, row.value != nil, !row.offersChargingOff else { return nil }
        return "Unplug the device to turn battery saver on: Android refuses it while charging."
    }

    private func glyph(for toggle: DeviceToggle) -> String {
        switch toggle {
        case .showTaps: return "hand.tap"
        case .forceRTL: return "text.alignright"
        case .showBackgroundANRs: return "exclamationmark.triangle"
        case .wifiVerboseLogging: return "text.bubble"
        case .mobileDataAlwaysActive: return "antenna.radiowaves.left.and.right.circle"
        }
    }

    private func help(for toggle: DeviceToggle) -> String {
        switch toggle {
        case .showTaps:
            return "Draws a marker where the screen is touched (system show_touches)."
        case .forceRTL:
            return "Forces right-to-left layout for localization testing (global and property debug.force_rtl), then pushes the current languages again so Android recomputes the layout direction at once, as Developer options does (Android 8 and newer; older images apply it when the device restarts)."
        case .showBackgroundANRs:
            return "Shows ANR dialogs for background apps too (secure anr_show_background)."
        case .wifiVerboseLogging:
            return "Turns on verbose Wi-Fi logging: cmd wifi set-verbose-logging on Android 11 and newer; older images store global wifi_verbose_logging_enabled, which applies after a restart."
        case .mobileDataAlwaysActive:
            return "Keeps mobile data connected while Wi-Fi is on (global mobile_data_always_on)."
        }
    }

    /// Device Hub's Appearance row (`cmd uimode night`): label left, the
    /// current mode in the trailing value popup. Only a failing command hides
    /// the row (`showsAppearanceSection`); an answered mode the popup cannot
    /// represent (`custom_schedule` / `custom_bedtime` / `unknown`) shows a
    /// non-selectable **Custom** value while Light/Dark/System stay
    /// selectable, so the user can leave that state from here.
    private var appearanceRow: some View {
        let popup = appearancePopupModel(for: workspace.controlsPanel.controls.appearance)
        return DHPopupRow(
            title: "Appearance",
            glyph: "circle.lefthalf.filled",
            help: popup.help,
            options: popup.selectableModes,
            selection: popup.selection,
            placeholder: popup.placeholderTitle,
            titleFor: { $0.label },
            onSelect: { mode in Task { await workspace.controlsPanel.setAppearance(mode) } }
        )
        .disabled(workspace.controlsPanel.controls.appearance == nil)
    }

    /// Device Hub's Text Size row: the stock Android steps on a dotted,
    /// stepped slider. The write happens on release, never while dragging.
    private var textSizeRow: some View {
        let reading = workspace.controlsPanel.deviceSettings.fontScale
        // Android 14+ offers 150–200 % as well; older images stop at 130 %.
        let apiLevel = workspace.context.serial
            .flatMap { model.inventory.deviceInfos[$0] }
            .flatMap { Int($0.apiLevel) }
        let steps = FontScaleStep.steps(apiLevel: apiLevel)
        let current = reading?.value.map { FontScaleStep.nearest(to: $0, in: steps) } ?? .standard

        return DHSliderRow(
            title: "Text Size",
            glyph: "textformat.size",
            help: "The stock steps are 85%, 100%, 115% and 130%, plus 150%, 180% and 200% from Android 14. The change applies when the slider is released.",
            values: steps.map(\.rawValue),
            value: current.rawValue,
            showsDots: true,
            accessibilityValue: "\(Int((current.rawValue * 100).rounded())) percent",
            onLiveChange: nil,
            onCommit: { value in
                Task { await workspace.controlsPanel.setTextSize(FontScaleStep.nearest(to: value, in: steps)) }
            }
        )
        .disabled(reading == nil)
    }

    /// The media-stream volume, Device Hub's Sound row.
    private var soundRow: some View {
        let reading = workspace.controlsPanel.deviceSettings.mediaVolume
        let values: [Double]
        if let reading, reading.maximum >= reading.minimum {
            values = (reading.minimum...reading.maximum).map(Double.init)
        } else {
            values = [0]
        }
        let current = Double(reading?.index ?? 0)

        return DHSliderRow(
            title: "Sound",
            glyph: "speaker.wave.2",
            help: "The media volume. It follows the knob while it moves.",
            values: values,
            value: current,
            showsDots: false,
            tickCount: ParityMetrics.controlsSoundTickCount,
            accessibilityValue: "\(Int(current))",
            onLiveChange: { value in
                workspace.controlsPanel.setMediaVolumeLive(Int(value.rounded()))
            },
            onCommit: { value in
                Task { await workspace.controlsPanel.setMediaVolume(Int(value.rounded())) }
            }
        )
        .disabled(reading == nil)
    }

    // MARK: - Power & battery

    private var batteryRow: some View {
        Group {
            if let battery = workspace.controlsPanel.controls.battery {
                DHRow(
                    "Battery",
                    glyph: "battery.100",
                    help: "The emulator's battery level. At 0% with no charger Android shuts down."
                ) {
                    HStack(spacing: ParityMetrics.controlsBatteryValueSpacing) {
                        Text("\(battery.level)%")
                            .font(.system(size: ParityMetrics.controlsCaptionFontSize))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                            .frame(minWidth: ParityMetrics.controlsBatteryValueWidth, alignment: .trailing)
                        DHSlider(
                            values: (0...100).map(Double.init),
                            value: Double(battery.level),
                            accessibilityLabel: "Battery level",
                            accessibilityValue: "\(battery.level)%"
                        ) { level in
                            workspace.hardware.setBatteryLevel(Int(level.rounded()))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Location

    /// DH's single Location row: the ready locations live in the popup;
    /// entering a custom fix or managing the saved list opens the popup
    /// sheet. Emulator-gated with the rest of the gRPC groups.
    /// The shared Location menu (`LocationMenuModel`): None, the places, the
    /// Trips an emulator plays itself, and Custom Location….
    private var locationRow: some View {
        let location = workspace.location
        let current = location.current
        return DHMenuRow(
            title: "Location",
            glyph: "mappin.and.ellipse",
            help: "The emulator's GPS location. A place or a coordinate is one fix; a trip or a custom route plays at about 1 Hz until you pick another location or None. Android cannot clear a fix, so None stops a route and leaves the last position.",
            valueText: current?.title ?? LocationMenuModel.noneTitle,
            entries: {
                LocationMenuModel.entries().map { entry in
                    switch entry {
                    case .none:
                        return .item(id: entry.id, title: LocationMenuModel.noneTitle, isSelected: current == nil) {
                            Task { await location.chooseFromMenu(nil) }
                        }
                    case .separator(let id):
                        return .separator(id: id)
                    case .place(let place):
                        return .item(id: entry.id, title: place.name, isSelected: current == .place(place)) {
                            Task { await location.chooseFromMenu(.place(place)) }
                        }
                    case .header(let title):
                        return .header(id: entry.id, title: title)
                    case .trip(let trip):
                        return .item(id: entry.id, title: trip.name, isSelected: current == .trip(trip)) {
                            Task { await location.chooseFromMenu(.trip(trip)) }
                        }
                    case .custom:
                        return .item(id: entry.id, title: LocationMenuModel.customTitle) {
                            location.isLocationSheetPresented = true
                        }
                    }
                }
            }
        )
    }

    // MARK: - Biometrics

    /// A fingerprint touch on the emulator's sensor (the Device menu's
    /// Simulate ▸ Fingerprint Touch runs the same `touchFingerprint`).
    private var fingerprintRow: some View {
        DHControlRow("Fingerprint", glyph: "touchid", help: "Posts a fingerprint touch (id 0) to the emulator's sensor.") {
            Button("Touch") {
                Task { await workspace.extras.touchFingerprint() }
            }
            .buttonStyle(.dhPanel)
        }
    }

    // MARK: - Recovery and loading

    private func recoveryCard(_ reason: DeviceControlsController.RecoveryReason) -> some View {
        DHCard {
            DHRow(reason.title, glyph: "power", help: "") {
                Button(reason.actionTitle) {
                    Task { await model.powerOnDevice(in: workspace) }
                }
                .buttonStyle(.dhPanel)
                .disabled(model.isBusy)
            }
            DHHairline()
            DHCaptionRow(reason.caption)
        }
    }

    /// The empty state: Controls read and write the mirrored device, and
    /// there is none. A selected-but-stopped device (an AVD or a physical
    /// device that dropped off adb) gets DH's own wording (CT-10: "Start
    /// the simulator to customize behavior and appearance." on its Apple
    /// side); nothing selected at all keeps a fuller hint, since DH's
    /// sidebar always has something selected and never shows that case.
    private var noDeviceCard: some View {
        DHControlsEmptyState(
            glyph: "slider.horizontal.3",
            caption: workspace.deviceSelection != nil
                ? SelectionRouting.unavailableCaption(
                    for: workspace.deviceSelection,
                    in: workspace.liveRoutingSnapshot,
                    stopped: "Start the device to customize behavior and appearance."
                )
                : "Select a running device, or start one, to use its controls."
        )
    }

    private var loadingCard: some View {
        DHCard {
            DHControlRow {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading controls")
                    Text("Loading controls")
                        .font(.system(size: ParityMetrics.controlsLabelFontSize))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
