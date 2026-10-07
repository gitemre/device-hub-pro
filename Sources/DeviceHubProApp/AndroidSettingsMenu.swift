import SwiftUI
import DeviceHubProKit

// The Device menu's settings submenus for an Android device (Accessibility,
// Appearance, Location, Sound, Language, Time Zone, Clean Status Bar): the
// same set Device Hub lists for a simulator (`AppleDeviceSettingsMenus`),
// every item one of the Controls panel's rows. The menu and the panel decide
// what a device can work with the same table (`controlsGroups`,
// `ControlsRow.availability(on:)`) and write through the same controllers
// (`DeviceControlsController`, `LanguageTimeController`, `LocationController`,
// `StatusBarDemoController`); an item that cannot work is not listed.

// MARK: - What the panel decides, shared

extension DeviceWorkspace {
    /// The Controls family of the Android device the panel shows: the class its
    /// `ro.build.characteristics` say, handheld until the Info read lands.
    func androidControlsFamily() -> ControlsFamily {
        .android(context.serial.flatMap { services.inventory.deviceInfos[$0] }?.formFactor)
    }

    /// The Android Controls panel's row flags, from the readings it holds
    /// (`ControlsView` builds its groups from these; the Device menu's
    /// settings block does too).
    var androidControlsAvailability: ControlsGroupAvailability {
        ControlsGroupAvailability(
            wifi: controlsPanel.showsWifiRow,
            bluetooth: controlsPanel.controls.bluetoothEnabled != nil,
            airplaneMode: controlsPanel.showsAirplaneModeRow,
            mobileData: controlsPanel.controls.mobileDataEnabled != nil,
            canUseEmulatorControls: controlsPanel.canUseEmulatorControls,
            appearance: controlsPanel.showsAppearanceSection,
            textSize: controlsPanel.showsTextSizeRow,
            reduceMotion: controlsPanel.showsReduceMotionRow,
            increaseContrast: controlsPanel.showsIncreaseContrastRow,
            showBorders: controlsPanel.showsShowBordersRow,
            talkBack: controlsPanel.showsTalkBackRow,
            colorFilter: controlsPanel.colorFilters.showsColorFilterRow,
            sound: controlsPanel.showsSoundRow,
            forceRTL: controlsPanel.showsToggle(.forceRTL),
            showTaps: controlsPanel.showsToggle(.showTaps),
            backgroundANRs: controlsPanel.showsToggle(.showBackgroundANRs),
            fingerprint: controlsPanel.canUseEmulatorControls && androidDeviceHas(Self.fingerprintFeature),
            dataSaver: controlsPanel.showsDataSaverRow,
            deviceLanguage: controlsPanel.languageTime.showsLanguageRow,
            dateTime: controlsPanel.languageTime.showsDateTimeRow,
            timeZone: controlsPanel.languageTime.showsTimeZoneRow,
            timeFormat24: controlsPanel.languageTime.showsTimeFormatRow,
            networkConditions: conditions.showsNetworkConditions,
            shaping: conditions.showsShaping,
            appConditions: conditions.showsAppConditions,
            lowMemory: conditions.showsLowMemory,
            links: links.showsLinks,
            statusBar: conditions.statusBar.showsGroup
        )
    }
}

// MARK: - The plan

/// Which items of the Device menu's Android settings block a device shows
/// (an item that cannot work on the selected device is
/// not shown, not greyed). Pure: the family and the panel's row flags decide;
/// a stopped AVD keeps the items every family of its class would show, disabled
/// (as the simulator block does). Until the Controls panel has read a running
/// device (its poll runs only while the panel is on screen) the plan offers
/// the rows no probe can take away; TalkBack and Clean Status Bar, which need
/// a read to exist at all, join once it has.
struct AndroidSettingsMenuPlan: Equatable {
    enum AccessibilityItem: Equatable {
        case reduceMotion, increaseContrast, showBorders
        case textSize
        case talkBack
    }

    let family: ControlsFamily
    let availability: ControlsGroupAvailability
    var isRunning = true

    init(family: ControlsFamily, availability: ControlsGroupAvailability, isRunning: Bool = true) {
        self.family = family
        self.availability = availability
        self.isRunning = isRunning
    }

    /// The plan before the panel has read the device: the rows every device of
    /// the family has (Location needs an emulator).
    static func unread(family: ControlsFamily, isEmulator: Bool, isRunning: Bool) -> AndroidSettingsMenuPlan {
        var available = ControlsGroupAvailability()
        available.canUseEmulatorControls = isEmulator
        available.appearance = true
        available.textSize = true
        available.reduceMotion = true
        available.increaseContrast = true
        available.showBorders = true
        available.sound = true
        available.deviceLanguage = true
        available.timeZone = true
        available.timeFormat24 = true
        return AndroidSettingsMenuPlan(family: family, availability: available, isRunning: isRunning)
    }

    /// `readAvailability` is the panel's flags once it has read the device, nil before.
    static func make(
        family: ControlsFamily,
        readAvailability: ControlsGroupAvailability?,
        isEmulator: Bool,
        isRunning: Bool
    ) -> AndroidSettingsMenuPlan {
        guard let readAvailability else { return unread(family: family, isEmulator: isEmulator, isRunning: isRunning) }
        return AndroidSettingsMenuPlan(family: family, availability: readAvailability, isRunning: isRunning)
    }

    /// The rows the panel would list for this family and these flags.
    var rows: Set<ControlsRow> {
        Set(controlsGroups(availability, family: family).flatMap(\.rows) + controlsTrailingRows(availability, family: family))
    }

    func shows(_ row: ControlsRow) -> Bool { rows.contains(row) }

    /// The Accessibility submenu's groups, each non-empty, in menu order.
    var accessibilityGroups: [[AccessibilityItem]] {
        let groups: [[(AccessibilityItem, ControlsRow)]] = [
            [(.reduceMotion, .reduceMotion), (.increaseContrast, .increaseContrast), (.showBorders, .showBorders)],
            [(.textSize, .textSize)],
            [(.talkBack, .talkBack)],
        ]
        let shown = rows
        return groups.map { $0.filter { shown.contains($0.1) }.map(\.0) }.filter { !$0.isEmpty }
    }

    var showsAccessibility: Bool { !accessibilityGroups.isEmpty }
    var showsAppearance: Bool { shows(.appearance) }
    var showsLocation: Bool { shows(.location) }
    var showsSound: Bool { shows(.sound) }
    var showsLanguage: Bool { shows(.deviceLanguage) }
    var showsTimeFormat24: Bool { shows(.timeFormat24) }
    /// Language ▸: the locales, then the 24-hour toggle; either alone is enough.
    var showsLanguageMenu: Bool { showsLanguage || showsTimeFormat24 }
    var showsTimeZone: Bool { shows(.timeZone) }
    var showsCleanStatusBar: Bool { shows(.cleanStatusBar) }

    var showsAnything: Bool {
        showsAccessibility || showsAppearance || showsLocation || showsSound
            || showsLanguageMenu || showsTimeZone || showsCleanStatusBar
    }

    // MARK: Steps

    /// The text size one step from the current reading in the device's own
    /// steps (the Text Size row's), nil at an end of the list.
    static func steppedTextSize(current: Double?, steps: [FontScaleStep], by delta: Int) -> FontScaleStep? {
        let now = current.map { FontScaleStep.nearest(to: $0, in: steps) } ?? .standard
        guard let index = steps.firstIndex(of: now) else { return nil }
        let next = min(max(index + delta, 0), steps.count - 1)
        return next == index ? nil : steps[next]
    }

    /// The media volume one index from the reading (the Sound row's scale), nil at an end.
    static func steppedVolume(_ reading: MediaVolumeReading, by delta: Int) -> Int? {
        let next = min(max(reading.index + delta, reading.minimum), reading.maximum)
        return next == reading.index ? nil : next
    }

    /// What the 24-hour toggle writes: on is 24-hour, off 12-hour (the locale's
    /// own default is the Time format popup's third choice, kept in the panel).
    static func timeFormat(is24Hour on: Bool) -> TimeFormatSetting { on ? .twentyFourHour : .twelveHour }

    /// The mode Toggle Appearance writes: Dark unless the device is Dark already.
    static func toggledAppearance(from reading: AppearanceReading?) -> AppearanceMode {
        if case .mode(.dark)? = reading { return .light }
        return .dark
    }
}

/// The Controls menu's Simulate Low Memory item: the App conditions group's
/// row of the same name (`ConditionsRowView.lowMemoryRow`), same gate.
enum AndroidLowMemoryMenu {
    /// Listed where the panel lists the row: the family offers it, a device is
    /// mirrored and it is API 23+.
    static func isShown(family: ControlsFamily, showsAppConditions: Bool, showsLowMemory: Bool) -> Bool {
        showsAppConditions && showsLowMemory && ControlsRow.lowMemory.availability(on: family).isVisible
    }

    /// Enabled where the row's Send button is: a target app is chosen, the
    /// device accepts the level and no condition write runs.
    static func isEnabled(targetPackage: String?, gate: TrimMemoryGate?, isWriting: Bool) -> Bool {
        targetPackage != nil && gate == .allowed && !isWriting
    }
}

// MARK: - The actions

/// What the menu items do, each one the call the panel's row makes, on the
/// workspace of the window the menu was used in (never `AppModel.workspace`,
/// the first window's).
@MainActor
struct AndroidSettingsMenuActions {
    let workspace: DeviceWorkspace

    private var panel: DeviceControlsController { workspace.controlsPanel }

    /// The panel's poll runs only while it is on screen: a menu action that
    /// needs a reading reads first, as the simulator's `ensureAttached` does.
    func ensureLoaded() async {
        if !panel.controlsLoaded { await panel.refreshControls() }
    }

    func setAppearance(_ mode: AppearanceMode) async { await panel.setAppearance(mode) }

    func toggleAppearance() async {
        await ensureLoaded()
        await panel.setAppearance(AndroidSettingsMenuPlan.toggledAppearance(from: panel.controls.appearance))
    }

    func setReduceMotion(_ on: Bool) async { await panel.setReduceMotion(on) }
    func setIncreaseContrast(_ on: Bool) async { await panel.setIncreaseContrast(on) }
    func setShowBorders(_ on: Bool) async { await panel.setShowBorders(on) }
    func setTalkBack(_ on: Bool) async { await panel.setTalkBack(on) }

    /// Flips a switch from a fresh reading: the panel polls only while it is
    /// on screen, so the menu's checkmark can be unread or stale (a Reduce
    /// Motion that was on showed unchecked, and its click wrote "on" again).
    func toggle(
        _ read: @MainActor (DeviceControlsController) -> Bool?,
        _ write: (AndroidSettingsMenuActions, Bool) async -> Void
    ) async {
        await panel.refreshControls()
        await write(self, !(read(panel) ?? false))
    }

    /// 24-hour time from a fresh reading, for the same reason.
    func toggleTimeFormat24() async {
        await panel.languageTime.refresh()
        let isOn = panel.languageTime.readings?.timeFormat == .twentyFourHour
        await setTimeFormat24(!isOn)
    }

    /// One step through the Text Size row's list (API-dependent, as the row's).
    func stepTextSize(by delta: Int) async {
        await ensureLoaded()
        guard let reading = panel.deviceSettings.fontScale else { return }
        let apiLevel = workspace.context.serial
            .flatMap { workspace.services.inventory.deviceInfos[$0] }
            .flatMap { Int($0.apiLevel) }
        let steps = FontScaleStep.steps(apiLevel: apiLevel)
        guard let next = AndroidSettingsMenuPlan.steppedTextSize(current: reading.value, steps: steps, by: delta) else { return }
        await panel.setTextSize(next)
    }

    /// One index of the media volume (what the Sound row's commit writes).
    func stepVolume(by delta: Int) async {
        await ensureLoaded()
        guard let reading = panel.deviceSettings.mediaVolume,
              let next = AndroidSettingsMenuPlan.steppedVolume(reading, by: delta)
        else { return }
        await panel.setMediaVolume(next)
    }

    func chooseLocation(_ choice: EmulatorLocationChoice?) async {
        await workspace.location.chooseFromMenu(choice)
    }

    /// Opens the panel's Custom Location sheet, from the current fix.
    func presentCustomLocation() {
        workspace.location.primeLocationDraft(from: workspace.location.currentFix())
        workspace.window.deviceExtrasSheet = .customLocation
    }

    func setLanguage(_ locale: DeviceLocale) async {
        await workspace.controlsPanel.languageTime.setDeviceLanguage(locale)
    }

    func setTimeFormat24(_ on: Bool) async {
        await workspace.controlsPanel.languageTime.setTimeFormat(AndroidSettingsMenuPlan.timeFormat(is24Hour: on))
    }

    func setTimeZone(_ identifier: String) async {
        await workspace.controlsPanel.languageTime.setTimeZone(identifier)
    }

    func setAutomaticTimeZone() async {
        await workspace.controlsPanel.languageTime.setAutomaticTimeZone(true)
    }

    func setCleanStatusBar(_ on: Bool) async {
        await workspace.conditions.statusBar.setDemoMode(on)
    }

    func touchFingerprint() async { await workspace.extras.touchFingerprint() }

    func simulateLowMemory() async { await workspace.conditions.simulateLowMemory() }
}

// MARK: - The menus

/// Device ▸ Accessibility, Appearance, Location, Sound, Language, Time Zone and
/// Clean Status Bar for an Android device. Items are disabled while the device
/// is off; each acts on `workspace` through `AndroidSettingsMenuActions`.
struct AndroidDeviceSettingsMenus: View {
    let workspace: DeviceWorkspace
    let plan: AndroidSettingsMenuPlan

    private var isRunning: Bool { plan.isRunning }
    private var panel: DeviceControlsController { workspace.controlsPanel }
    private var languageTime: LanguageTimeController { panel.languageTime }
    private var actions: AndroidSettingsMenuActions { AndroidSettingsMenuActions(workspace: workspace) }

    private func act(_ body: @escaping @MainActor (AndroidSettingsMenuActions) async -> Void) {
        let actions = actions
        Task { @MainActor in await body(actions) }
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
        if plan.showsAppearance { appearanceMenu }
        if plan.showsLocation { locationMenu }
        if plan.showsSound { soundMenu }
        if plan.showsLanguageMenu { languageMenu }
        if plan.showsTimeZone { timeZoneMenu }
        if plan.showsCleanStatusBar { cleanStatusBar }
    }

    // MARK: Accessibility

    @ViewBuilder
    private func accessibilityRow(_ item: AndroidSettingsMenuPlan.AccessibilityItem) -> some View {
        switch item {
        case .reduceMotion:
            Toggle("Reduce Motion", isOn: flag(panel.deviceSettings.reduceMotion?.isEnabled,
                read: { $0.deviceSettings.reduceMotion?.isEnabled }) { await $0.setReduceMotion($1) })
        case .increaseContrast:
            Toggle("Increase Contrast", isOn: flag(panel.deviceSettings.increaseContrast?.isOn,
                read: { $0.deviceSettings.increaseContrast?.isOn }) { await $0.setIncreaseContrast($1) })
        case .showBorders:
            Toggle("Show Borders", isOn: flag(panel.deviceSettings.showBorders?.isOn,
                read: { $0.deviceSettings.showBorders?.isOn }) { await $0.setShowBorders($1) })
        case .textSize:
            Button("Increase Text Size") { act { await $0.stepTextSize(by: 1) } }
                .keyboardShortcut("+", modifiers: [.command, .option])
            Button("Decrease Text Size") { act { await $0.stepTextSize(by: -1) } }
                .keyboardShortcut("-", modifiers: [.command, .option])
        case .talkBack:
            Toggle("TalkBack", isOn: flag(panel.deviceSettings.voiceOver?.isOn,
                read: { $0.deviceSettings.voiceOver?.isOn }) { await $0.setTalkBack($1) })
        }
    }

    /// A checkmark item over an optional reading (unknown shows unchecked);
    /// a click flips the device's fresh reading, not the shown one.
    private func flag(
        _ value: Bool?,
        read: @escaping @MainActor (DeviceControlsController) -> Bool?,
        _ write: @escaping @MainActor (AndroidSettingsMenuActions, Bool) async -> Void
    ) -> Binding<Bool> {
        Binding(get: { value == true }, set: { _ in act { await $0.toggle(read, write) } })
    }

    // MARK: Appearance

    private var appearanceMenu: some View {
        let reading = panel.controls.appearance
        return IconMenu("Appearance", "circle.lefthalf.filled", disabled: !isRunning) {
            Button("Toggle Appearance") { act { await $0.toggleAppearance() } }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            Toggle("Light", isOn: Binding(
                get: { reading == .mode(.light) },
                set: { if $0 { act { await $0.setAppearance(.light) } } }
            ))
            Toggle("Dark", isOn: Binding(
                get: { reading == .mode(.dark) },
                set: { if $0 { act { await $0.setAppearance(.dark) } } }
            ))
        }
    }

    // MARK: Location

    /// The Location row's menu (`LocationMenuModel`): None, the places, the
    /// Trips, Custom Location… (the panel's sheet).
    private var locationMenu: some View {
        let current = workspace.location.current
        return IconMenu("Location", "location", disabled: !isRunning) {
            ForEach(LocationMenuModel.entries()) { entry in
                switch entry {
                case .none:
                    Toggle(LocationMenuModel.noneTitle, isOn: Binding(
                        get: { current == nil },
                        set: { if $0 { act { await $0.chooseLocation(nil) } } }
                    ))
                case .separator:
                    Divider()
                case .place(let place):
                    Toggle(place.name, isOn: Binding(
                        get: { current == .place(place) },
                        set: { if $0 { act { await $0.chooseLocation(.place(place)) } } }
                    ))
                case .header(let title):
                    Text(title)
                case .trip(let trip):
                    Toggle(trip.name, isOn: Binding(
                        get: { current == .trip(trip) },
                        set: { if $0 { act { await $0.chooseLocation(.trip(trip)) } } }
                    ))
                case .custom:
                    Button(LocationMenuModel.customTitle) { actions.presentCustomLocation() }
                }
            }
        }
    }

    // MARK: Sound

    private var soundMenu: some View {
        IconMenu("Sound", "speaker.wave.2", disabled: !isRunning) {
            Button("Increase Volume") { act { await $0.stepVolume(by: 1) } }
            Button("Decrease Volume") { act { await $0.stepVolume(by: -1) } }
        }
    }

    // MARK: Language and time

    /// The Language row's locales (its Suggested list), then 24-hour time.
    private var languageMenu: some View {
        let readings = languageTime.readings
        let primary = readings?.locales?.first
        let presets = DeviceLocalePresets.resolved(against: languageTime.deviceLocales.isEmpty ? nil : languageTime.deviceLocales)
        return Menu("Language") {
            if plan.showsLanguage {
                ForEach(presets, id: \.tag) { locale in
                    Toggle(DeviceLocaleNames.nativeName(locale), isOn: Binding(
                        get: { primary?.id == locale.id },
                        set: { if $0 { act { await $0.setLanguage(locale) } } }
                    ))
                }
            }
            if plan.showsLanguage, plan.showsTimeFormat24 { Divider() }
            if plan.showsTimeFormat24 {
                Toggle("24-Hour Time", isOn: Binding(
                    get: { readings?.timeFormat == .twentyFourHour },
                    set: { _ in act { await $0.toggleTimeFormat24() } }
                ))
            }
        }
        .disabled(!isRunning)
    }

    /// The Time zone row's Suggested zones and Automatic (the panel's popup
    /// without its search over every zone).
    private var timeZoneMenu: some View {
        let readings = languageTime.readings
        return Menu("Time Zone") {
            Toggle(languageTime.isEmulator ? "Automatic (the Mac's zone)" : "Automatic", isOn: Binding(
                get: { readings?.autoTimeZone == true },
                set: { if $0 { act { await $0.setAutomaticTimeZone() } } }
            ))
            Divider()
            ForEach(TimeZoneOptions.presets, id: \.id) { zone in
                Toggle(zone.id, isOn: Binding(
                    get: { readings?.autoTimeZone != true && readings?.timeZoneID == zone.id },
                    set: { if $0 { act { await $0.setTimeZone(zone.id) } } }
                ))
            }
        }
        .disabled(!isRunning)
    }

    // MARK: Status bar

    private var cleanStatusBar: some View {
        let statusBar = workspace.conditions.statusBar
        return Toggle("Clean Status Bar", isOn: Binding(
            get: { statusBar.demoModeRow.value == true },
            set: { on in act { await $0.setCleanStatusBar(on) } }
        ))
        .disabled(!isRunning || statusBar.isWriting)
    }
}
