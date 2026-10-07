import SwiftUI
import UniformTypeIdentifiers
import DeviceHubProKit

// The collapsible groups Device Hub Pro adds below Device Hub's cards (2026-09-30,
// an addition beyond DH: the parity audit). They are the Android panel's
// groups in its wording and its row shapes (DHGroup, DHToggleRow, DHPopupRow,
// DHSearchablePopupRow, DHControlRow, dhPanel buttons) over the backends the
// Device menu already uses (`AppleControlsController`). A simulator gets
// Biometrics, Language & time and App conditions, then plain rows; a physical iPhone only App conditions (Target app, Launch, Terminate)
// and Links, the shapes `DevicectlPhysicalClient` allows. Each row's title is
// the manifest's `ios` label (`controls-rows.json`).

/// The groups under the cards of a simulator or a physical iPhone.
struct AppleGroupsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let groups: [AppleGroup]
    let udid: String
    let isPhysical: Bool

    private var controls: AppleControlsController { workspace.appleControls }

    var body: some View {
        ForEach(groups) { group in
            DHGroup(
                id: "ios.\(group.id.rawValue)",
                title: group.id == .biometrics ? appleBiometricGroupTitle(controls.state.biometricType) : group.id.title,
                defaultExpanded: group.id.defaultExpanded,
                forceExpanded: model.expandAllControlsGroups
            ) {
                ForEach(Array(group.rows.enumerated()), id: \.element) { index, row in
                    AppleGroupRowView(row: row, udid: udid, isPhysical: isPhysical)
                    if index != group.rows.count - 1 {
                        DHHairline()
                    }
                }
            }
        }
        // The groups keep Android's tooltips (the cards above are DH's, with none).
        .environment(\.dhRowTooltips, true)
    }
}

/// One option of Target app, from either a simulator's or a phone's app list.
struct AppleTargetAppOption: Identifiable, Hashable {
    let id: String
    let title: String
    let isUserApp: Bool
}

/// One time zone of the Time zone popup.
struct AppleTimeZoneOption: Identifiable, Hashable {
    let id: String
}

struct AppleGroupRowView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(SimulatorActionDialogs.self) private var dialogs
    let row: ControlsRow
    let udid: String
    let isPhysical: Bool

    private var controls: AppleControlsController { workspace.appleControls }
    private var state: AppleControlsState { controls.state }

    var body: some View {
        switch row {
        case .biometricsEnrolled: enrolledRow
        case .biometricsMatch: matchRow
        case .deviceLanguage: languageRow
        case .timeFormat24: timeFormatRow
        case .timeZone: timeZoneRow
        case .cleanStatusBar: cleanStatusBarRow
        case .targetApp: targetAppRow
        case .permissions: permissionRow
        case .permissionsAccess: accessRow
        case .pushNotification: pushRow
        case .launchApp: launchRow
        case .terminateApp: terminateRow
        case .memoryWarning: memoryWarningRow
        case .linkURL: urlRow
        case .addRootCertificate: rootCertificateRow
        case .resetKeychain: keychainRow
        case .resetDefaults: resetDefaultsRow
        default: AppleControlsRowView(row: row, udid: udid) {}
        }
    }

    // MARK: - Biometrics

    private var biometricName: String { appleBiometricGroupTitle(state.biometricType) }

    private var enrolledRow: some View {
        DHToggleRow(
            title: "Enrolled",
            glyph: state.biometricType == "Touch ID" ? "touchid" : (state.biometricType == "Optic ID" ? "opticid" : "faceid"),
            help: "Enrols or removes \(biometricName) on the simulator (devicectl device settings biometrics), read back from the device.",
            value: state.biometricsEnrolled
        ) { await controls.setBiometricsEnrolled($0) }
        .disabled(controls.isBusy(.biometrics))
    }

    private var matchRow: some View {
        DHControlRow(
            "Try",
            glyph: "checkmark.shield",
            help: "Sends a \(biometricName) attempt that matches or does not match (devicectl device simulate biometrics). Needs \(biometricName) enrolled. Pressed before the app shows its \(biometricName) prompt, the result waits for the prompt (up to 30 s)."
        ) {
            if let pending = controls.pendingBiometric, pending.udid == controls.udid {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for \(biometricName)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("The \(pending.success ? "matching" : "non-matching") result is sent as soon as the app shows its \(biometricName) prompt.")
                    Button("Cancel") { controls.cancelPendingBiometric() }
                        .buttonStyle(.dhPanel)
                }
            } else {
                HStack(spacing: 6) {
                    Button("Matching") { Task { await controls.simulateBiometricMatch(success: true) } }
                        .buttonStyle(.dhPanel)
                    Button("Non-matching") { Task { await controls.simulateBiometricMatch(success: false) } }
                        .buttonStyle(.dhPanel)
                }
                .disabled(state.biometricsEnrolled != true || controls.isBusy(.biometrics))
            }
        }
    }

    // MARK: - Language & time

    private var languageRow: some View {
        let current = state.preferences?.languages.first.flatMap(DeviceLocale.init(tag:))
        let pending = controls.respringSuggested
        return VStack(spacing: 0) {
            DHSearchablePopupRow(
                title: "Language",
                glyph: "globe",
                help: appleSupportCaption(controls.route(.language).support) ?? "The simulator's system language.",
                valueText: current.map { AppleControlsText.languageValueName($0) } ?? "Unknown",
                pinnedTitle: "Suggested",
                pinned: DeviceLocalePresets.resolved(against: nil),
                allTitle: "All languages",
                all: AppleLanguageOptions.all,
                selectedID: current?.id,
                titleFor: { DeviceLocaleNames.nativeName($0) },
                matches: { locale, query in
                    DeviceLocaleNames.nativeName(locale).range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                        || locale.tag.range(of: query, options: .caseInsensitive) != nil
                },
                actions: pending ? [DHPopupAction(id: "respring", title: "Respring to Apply") { Task { await controls.respring() } }] : [],
                searchPrompt: DHSearchPrompt.languages,
                onSelect: { locale in Task { await controls.setLanguage(locale) } }
            )
            .disabled(state.preferences == nil || controls.isBusy(.language))
            if pending {
                DHHairline()
                DHControlRow("Apply language", glyph: "arrow.clockwise", help: "Restarts SpringBoard so the home screen and status bar use the new language (apps use it when they relaunch).") {
                    Button("Respring") { Task { await controls.respring() } }
                        .buttonStyle(.dhPanel)
                        .disabled(controls.isBusy(.language))
                }
            }
        }
    }

    private var timeFormatRow: some View {
        // Without an override the switch shows the clock the simulator's locale has.
        let is24Hour = state.preferences?.uses24HourClock()
        return DHToggleRow(
            title: "24-hour time",
            glyph: "clock",
            help: appleSupportCaption(controls.route(.timeFormat24).support) ?? "Shows the simulator's clock in 24-hour time.",
            value: is24Hour
        ) { on in await controls.setTimeFormat(on ? .twentyFourHour : .twelveHour) }
        .disabled(state.preferences == nil || controls.isBusy(.timeFormat24))
    }

    private var timeZoneRow: some View {
        let chosen = controls.timeZone(for: udid)
        let running: String? = controls.bootTimeZone.flatMap { $0 }
        let options = allTimeZoneIdentifiers().map(AppleTimeZoneOption.init(id:))
        return VStack(spacing: 0) {
            DHSearchablePopupRow(
                title: "Time zone",
                glyph: "globe.europe.africa",
                help: "The zone the simulator takes at the next boot Device Hub Pro starts or restarts. Now: \(running ?? "the Mac's zone (\(TimeZone.current.identifier))").",
                valueText: chosen ?? "Mac's zone",
                allTitle: "All time zones",
                all: options,
                selectedID: chosen,
                titleFor: { $0.id },
                detailFor: { timeZoneDetail($0.id) },
                matches: { timeZoneMatches($0.id, query: $1) },
                actions: [DHPopupAction(id: "mac", title: "Mac's time zone") { controls.setTimeZone(nil) }],
                searchPrompt: DHSearchPrompt.timeZones,
                onSelect: { controls.setTimeZone($0.id) }
            )
            if controls.needsRestartForTimeZone {
                DHHairline()
                DHControlRow("Apply time zone", glyph: "arrow.clockwise", help: "A zone applies when Device Hub Pro starts or restarts the simulator.") {
                    Button("Restart") { Task { await controls.restartForTimeZone() } }
                        .buttonStyle(.dhPanel)
                }
            }
        }
    }

    // MARK: - Status bar

    private var cleanStatusBarRow: some View {
        VStack(spacing: 0) {
            DHToggleRow(
                title: "Clean status bar",
                glyph: "rectangle.topthird.inset.filled",
                help: "The store-screenshot look: 9:41, full Wi-Fi and cellular bars, battery 100% charged, no carrier name (simctl status_bar override). Off clears the override.",
                value: controls.statusBarActive
            ) { await controls.setCleanStatusBar($0) }
            .disabled(controls.isBusy(.statusBar))
            if let caption = appleSupportCaption(.cosmetic) {
                DHCaptionRow(caption)
            }
        }
    }

    // MARK: - App conditions

    /// The apps Target app lists: a simulator's `simctl listapps`, a phone's
    /// `device info apps` (the Apps tab's list).
    private var targetOptions: [AppleTargetAppOption] {
        if isPhysical {
            return workspace.physicalApps.apps.map {
                AppleTargetAppOption(id: $0.bundleIdentifier, title: $0.title, isUserApp: $0.isDeveloperApp || !$0.isDefaultApp)
            }
        }
        return controls.apps.map {
            AppleTargetAppOption(id: $0.bundleIdentifier, title: $0.title, isUserApp: $0.isUserApp)
        }
    }

    private var isLoadingApps: Bool {
        isPhysical ? workspace.physicalApps.isLoading : controls.isLoadingApps
    }

    private func loadApps() async {
        if isPhysical {
            await workspace.physicalApps.load(udid: udid)
        } else {
            await controls.loadApps()
        }
    }

    private var targetAppRow: some View {
        let options = targetOptions
        let target = controls.targetBundle
        let selected = options.first { $0.id == target }
        return DHSearchablePopupRow(
            title: "Target app",
            glyph: "app",
            help: "The app the rows below act on. Choose com.devicehubpro.verifier to watch them in the verifier.",
            valueText: selected?.title ?? target ?? "Choose an app",
            pinnedTitle: "User apps",
            pinned: options.filter(\.isUserApp),
            allTitle: "System apps",
            all: options.filter { !$0.isUserApp },
            selectedID: selected?.id,
            titleFor: { $0.title },
            detailFor: { $0.id },
            matches: {
                $0.title.range(of: $1, options: .caseInsensitive) != nil || $0.id.range(of: $1, options: .caseInsensitive) != nil
            },
            isLoading: isLoadingApps,
            searchPrompt: "Search apps",
            onOpen: { Task { await loadApps() } },
            onSelect: { controls.targetBundle = $0.id }
        )
        .task { await loadApps() }
    }

    private var permissionRow: some View {
        DHPopupRow(
            title: "Permissions",
            glyph: "hand.raised",
            help: "The privacy service the next Allow, Deny or Ask again changes for the target app (simctl privacy).",
            options: SimulatorPrivacyService.allCases,
            selection: controls.permissionService,
            placeholder: nil,
            titleFor: { $0.title },
            valueTitleFor: { $0.valueTitle },
            onSelect: { controls.permissionService = $0 }
        )
    }

    private var accessRow: some View {
        VStack(spacing: 0) {
            DHControlRow("Access", glyph: "lock.open", help: "Allow or deny the chosen service for the target app, or reset it so the app asks again.") {
                HStack(spacing: 6) {
                    Button("Allow") { Task { await controls.setPermission(.grant) } }
                        .buttonStyle(.dhPanel)
                    Button("Deny") { Task { await controls.setPermission(.revoke) } }
                        .buttonStyle(.dhPanel)
                    Button("Reset") { Task { await controls.setPermission(.reset) } }
                        .buttonStyle(.dhPanel)
                }
                .disabled(controls.targetBundle == nil || controls.isBusy(.permissions))
            }
            if let caption = appleSupportCaption(controls.route(.permissions).support) {
                DHCaptionRow(caption)
            }
        }
    }

    private var pushRow: some View {
        VStack(spacing: 0) {
            DHControlRow("Push", glyph: "bell.badge", help: "Send push notification: sends the payload to the target app (simctl push). Edit the payload first if you need another one.") {
                HStack(spacing: 6) {
                    Button("Send") { Task { await controls.sendPush() } }
                        .buttonStyle(.dhPanel)
                        .disabled(controls.targetBundle == nil || controls.isBusy(.push))
                    Button("Edit Payload…") { workspace.window.deviceExtrasSheet = .pushNotification }
                        .buttonStyle(.dhPanel)
                }
            }
            if let note = controls.pushNote {
                DHCaptionRow(note)
            }
        }
    }

    private var targetSimulatorApp: SimulatorApp? {
        controls.apps.first { $0.bundleIdentifier == controls.targetBundle }
    }

    private var targetPhysicalApp: PhysicalApp? {
        workspace.physicalApps.apps.first { $0.bundleIdentifier == controls.targetBundle }
    }

    private var hasTarget: Bool {
        isPhysical ? targetPhysicalApp != nil : targetSimulatorApp != nil
    }

    private var launchRow: some View {
        DHControlRow(
            "Launch app",
            glyph: "play.circle",
            help: isPhysical
                ? "Launches the target app, replacing a running copy (devicectl device process launch)."
                : "Launches the target app (simctl launch)."
        ) {
            Button("Launch") {
                if isPhysical, let app = targetPhysicalApp {
                    Task { await workspace.physicalApps.launch(app, udid: udid) }
                } else if let app = targetSimulatorApp {
                    Task { await workspace.simulatorApps.launch(app, udid: udid) }
                }
            }
            .buttonStyle(.dhPanel)
            .disabled(!hasTarget)
        }
    }

    private var terminateRow: some View {
        DHControlRow(
            "Terminate app",
            glyph: "xmark.circle",
            help: isPhysical
                ? "Ends the target app's processes (devicectl device process terminate)."
                : "Ends the target app (simctl terminate)."
        ) {
            Button("Terminate") {
                if isPhysical, let app = targetPhysicalApp {
                    Task { await workspace.physicalApps.terminate(app, udid: udid) }
                } else if let app = targetSimulatorApp {
                    Task { await workspace.simulatorApps.terminate(app, udid: udid) }
                }
            }
            .buttonStyle(.dhPanel)
            .disabled(!hasTarget)
        }
    }

    /// The Device menu's Simulate Memory Warning (⇧⌘M): the same
    /// `SimulatorCanvasController.simulateMemoryWarning`.
    private var memoryWarningRow: some View {
        let canDebug = SimulatorDeviceMenuState(
            device: workspace.context.simulatorDevice,
            capabilities: workspace.context.capabilities,
            selected: model.simulators.entry(udid: udid),
            operation: model.simulatorLifecycle.operations[udid]
        ).canDebug
        return DHControlRow(
            "Memory warning",
            glyph: "memorychip",
            help: "Sends the running apps a memory warning, as Simulator.app's Simulate Memory Warning does (it touches the simulator's memory_warning_simulation file)."
        ) {
            Button("Send") { workspace.simulatorCanvas.simulateMemoryWarning() }
                .buttonStyle(.dhPanel)
                .disabled(!canDebug)
        }
    }

    // MARK: - Links

    private func open() async {
        let text = controls.linkDraft
        if isPhysical {
            await workspace.physicalApps.openURL(text, udid: udid)
        } else {
            await workspace.simulatorApps.openURL(text, udid: udid)
        }
    }

    private var urlRow: some View {
        @Bindable var controls = controls
        return OpenURLRowContent(
            draft: $controls.linkDraft,
            recents: workspace.links.recents.links,
            clearRecents: { workspace.links.clearRecents() },
            canOpen: !controls.linkDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            help: isPhysical
                ? "A web page or a deep link to open on the device. Hands the link to the phone (devicectl device process openURL)."
                : "A web page or a deep link to open on the device. Opens the link in the simulator (simctl openurl).",
            open: { Task { await open() } }
        )
    }

    // MARK: - Data

    private var simulatorName: String { model.simulators.entry(udid: udid)?.name ?? "this simulator" }

    /// Add Root Certificate…: a file chooser for what a drop on the stage takes
    /// (`SimulatorDropRouting`), then the same `simctl keychain add-root-cert`
    /// path, after the same confirmation.
    private var rootCertificateRow: some View {
        DHControlRow(
            "Root certificate",
            glyph: "checkmark.seal",
            help: "Add Root Certificate…: makes Safari and every app on the simulator trust what a PEM or DER certificate signs (simctl keychain add-root-cert), after you confirm."
        ) {
            Button("Add…") { chooseCertificates() }
                .buttonStyle(.dhPanel)
                .disabled(workspace.simulatorApps.isBusy)
                .accessibilityLabel("Add Root Certificate…")
        }
    }

    private func chooseCertificates() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose a PEM or DER root certificate for the simulator to trust."
        panel.allowedContentTypes = SimulatorDropRouting.certificateExtensions.sorted().compactMap {
            UTType(filenameExtension: $0)
        }
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        dialogs.requestTrust(certificates: panel.urls, udid: udid, simulator: simulatorName)
    }

    private var keychainRow: some View {
        VStack(spacing: 0) {
            DHControlRow(
                "Keychain",
                glyph: "key",
                help: "Reset Keychain…: removes the keychain items, saved logins included, from this simulator (simctl keychain reset), after you confirm."
            ) {
                Button("Reset…") { dialogs.requestResetKeychain(udid: udid, name: simulatorName) }
                    .buttonStyle(.dhPanel)
                    .disabled(workspace.simulatorApps.isBusy)
                    .accessibilityLabel("Reset Keychain…")
            }
            if let note = workspace.simulatorApps.dataNote {
                DHCaptionRow(note)
            }
        }
    }

    private var resetDefaultsRow: some View {
        DHControlRow(
            "Reset to defaults",
            glyph: "arrow.counterclockwise",
            help: "Puts the settings above back: appearance Light, text size Large, the accessibility switches and the color filter off, Liquid Glass Clear (iOS 26) or 50 % (iOS 27), the status bar override off and no location. Apps and data stay."
        ) {
            Button("Reset…") {
                let steps = controls.resetSteps(osVersion: model.simulators.entry(udid: udid)?.osVersion)
                if steps.isEmpty {
                    workspace.status.flash("Settings are already at their defaults")
                } else {
                    dialogs.requestResetDefaults(udid: udid, name: simulatorName, items: steps.map(\.title))
                }
            }
            .buttonStyle(.dhPanel)
            .accessibilityLabel("Reset to Defaults")
        }
    }
}
