import SwiftUI
import DeviceHubProKit

// The sheets behind the Device menu's extras (`DeviceExtrasCommands.swift`):
// what used to be Settings-panel rows that need input — a push payload, a
// permission, a time zone, a sensor value, a call or an SMS — presented from
// the menu the way Device Hub keeps its own extras. Each reuses the controller
// its row used (`AppleControlsController`, `EmulatorExtrasController`,
// `DeviceLinksController`), so the working functionality is unchanged.

/// The sheet the Device menu presents on the window, one at a time.
enum DeviceExtrasSheet: String, Identifiable, Hashable {
    case pushNotification
    case permissions
    case timeZone
    case customLocation
    case sensors
    case incomingCall
    case incomingSMS
    case phoneNumber
    case openURL
    case physicalOpenURL
    case saveProfile
    case manageProfiles
    case portForwarding
    case deviceShell

    var id: String { rawValue }
}

/// Presents ``DeviceExtrasSheet`` for the window's workspace.
struct DeviceExtrasSheetHost: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace

    func body(content: Content) -> some View {
        @Bindable var window = workspace.window
        content.sheet(item: $window.deviceExtrasSheet) { sheet in
            Group {
                switch sheet {
                case .pushNotification: PushNotificationSheet()
                case .permissions: PermissionsSheet()
                case .timeZone: TimeZoneSheet()
                case .customLocation:
                    // A simulator's coordinate sheet, or the emulator's (the Android Location row's).
                    if case .simulator? = workspace.deviceSelection {
                        AppleLocationSheet()
                    } else {
                        AndroidCustomLocationSheet()
                    }
                case .sensors: SensorsSheet()
                case .incomingCall: IncomingCallSheet()
                case .incomingSMS: IncomingSMSSheet()
                case .phoneNumber: PhoneNumberSheet()
                case .openURL: AndroidOpenURLSheet()
                case .physicalOpenURL: PhysicalOpenURLSheet()
                case .saveProfile: SaveProfileSheet()
                case .manageProfiles: ManageProfilesSheet()
                case .portForwarding: PortForwardingSheet()
                case .deviceShell: DeviceShellSheet()
                }
            }
            .environment(model)
            .environment(workspace)
        }
    }
}

extension View {
    func deviceExtrasSheets() -> some View { modifier(DeviceExtrasSheetHost()) }
}

/// The frame every one-field extras sheet shares: Device Hub's sheet with a
/// title, the content and Cancel / a blue default button.
private struct ExtrasSheetFrame<Content: View>: View {
    let title: String
    let confirmTitle: String
    var isConfirmEnabled = true
    var width: CGFloat = 470
    let confirm: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        DHSheet(
            title: title,
            width: width,
            actions: [DHSheetAction(title: confirmTitle, isEnabled: isConfirmEnabled, isDefault: true, action: confirm)],
            content: content
        )
    }
}

// MARK: - Simulator: Push Notification…, Permissions…

/// The simulator app the Push and Permissions sheets act on, chosen from
/// `simctl listapps`; one row of the sheet's card.
private struct TargetAppRow: View {
    @Environment(DeviceWorkspace.self) private var workspace

    private var controls: AppleControlsController { workspace.appleControls }

    var body: some View {
        @Bindable var controls = controls
        DHSheetRow(title: "App:") {
            Picker("App", selection: $controls.targetBundle) {
                Text("Choose an app").tag(String?.none)
                Section("User apps") {
                    ForEach(controls.apps.filter(\.isUserApp)) { app in
                        Text("\(app.title) (\(app.bundleIdentifier))").tag(Optional(app.bundleIdentifier))
                    }
                }
                Section("System apps") {
                    ForEach(controls.apps.filter { !$0.isUserApp }) { app in
                        Text(app.title).tag(Optional(app.bundleIdentifier))
                    }
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .task {
            if let udid = simulatorUDID(workspace) {
                await controls.ensureAttached(udid)
                await controls.loadApps()
            }
        }
    }
}

/// The selected simulator's UDID.
@MainActor
func simulatorUDID(_ workspace: DeviceWorkspace) -> String? {
    if case .simulator(let udid)? = workspace.deviceSelection { return udid }
    return nil
}

/// Sends a push payload to an app (`simctl push`): a built-in template or a
/// saved payload fills the editor, the payload is checked as JSON before it
/// is sent, and a push can be saved to the library.
struct PushNotificationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var namingMode: NamingMode?
    @State private var nameDraft = ""
    @FocusState private var nameFieldFocused: Bool

    private enum NamingMode: Equatable {
        case save
        case rename(UUID)
    }

    private var controls: AppleControlsController { workspace.appleControls }

    var body: some View {
        @Bindable var controls = controls
        let libraries = model.libraries
        let bytes = Data(controls.pushText.trimmingCharacters(in: .whitespacesAndNewlines).utf8).count
        let problem = PushPayloadText.problem(in: PushPayloadText.straightened(controls.pushText))
        ExtrasSheetFrame(
            title: "Push Notification",
            confirmTitle: "Send",
            isConfirmEnabled: controls.targetBundle != nil && !controls.isBusy(.push),
            width: 500,
            confirm: { Task { if await controls.sendPush() { dismiss() } } }
        ) {
            DHSheetCard { TargetAppRow() }
            HStack(spacing: 8) {
                Menu("Templates") {
                    ForEach(PushTemplate.builtIn) { template in
                        Button(template.title) { controls.pushText = template.payload }
                    }
                }
                .fixedSize()
                Menu("Library") {
                    ForEach(libraries.pushes.items) { push in
                        Menu(push.name) {
                            Button("Use") {
                                controls.pushText = push.payload
                                if !push.bundleIdentifier.isEmpty,
                                   controls.apps.contains(where: { $0.bundleIdentifier == push.bundleIdentifier }) {
                                    controls.targetBundle = push.bundleIdentifier
                                }
                            }
                            Button("Update with Current Payload") {
                                var updated = push
                                updated.payload = controls.pushText
                                updated.bundleIdentifier = controls.targetBundle ?? push.bundleIdentifier
                                libraries.updatePush(updated)
                            }
                            Button("Rename…") {
                                nameDraft = push.name
                                namingMode = .rename(push.id)
                            }
                            Button("Duplicate") { libraries.duplicatePush(id: push.id) }
                            Divider()
                            Button("Delete", role: .destructive) { libraries.deletePush(id: push.id) }
                        }
                    }
                    if !libraries.pushes.items.isEmpty { Divider() }
                    Button("Save Current as…") {
                        nameDraft = ""
                        namingMode = .save
                    }
                    .disabled(problem != nil)
                }
                .fixedSize()
                Spacer()
            }
            if let mode = namingMode {
                HStack(spacing: 6) {
                    TextField("Name", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFieldFocused)
                        .onSubmit { commitName(mode, controls: controls) }
                    Button("OK") { commitName(mode, controls: controls) }
                        .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { namingMode = nil }
                }
            }
            PlainCodeEditor(text: $controls.pushText)
                .modifier(CodeEditorWell(height: 150))
                .accessibilityLabel("Push payload")
                .onChange(of: namingMode) { _, mode in
                    // The menu item that opened the row hands focus to the name.
                    if mode != nil { Task { @MainActor in nameFieldFocused = true } }
                }
            HStack(alignment: .top) {
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let note = controls.pushNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(verbatim: "\(bytes) B")
                    .font(.caption)
                    .foregroundStyle(bytes > SimulatorPushPayload.maximumBytes ? .red : .secondary)
                    .monospacedDigit()
            }
        }
    }

    private func commitName(_ mode: NamingMode, controls: AppleControlsController) {
        let libraries = model.libraries
        switch mode {
        case .save:
            libraries.savePush(
                name: nameDraft,
                bundleIdentifier: controls.targetBundle ?? "",
                payload: PushPayloadText.straightened(controls.pushText)
            )
        case .rename(let id):
            libraries.renamePush(id: id, to: nameDraft)
        }
        namingMode = nil
    }
}

/// Grants, denies or resets one privacy service for an app (`simctl privacy`).
struct PermissionsSheet: View {
    @Environment(DeviceWorkspace.self) private var workspace

    @State private var access: SimulatorPrivacyAction = .grant

    private var controls: AppleControlsController { workspace.appleControls }

    var body: some View {
        @Bindable var controls = controls
        DHSheet(
            title: "Permissions",
            width: 470,
            actions: [
                DHSheetAction(
                    title: "Apply",
                    isEnabled: controls.targetBundle != nil && !controls.isBusy(.permissions),
                    isDefault: true
                ) { Task { await controls.setPermission(access) } },
            ]
        ) {
            DHSheetCard {
                TargetAppRow()
                DHSheetRow(title: "Service:") {
                    Picker("Service", selection: $controls.permissionService) {
                        ForEach(SimulatorPrivacyService.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                DHSheetRow(title: "Access:") {
                    Picker("Access", selection: $access) {
                        Text("Allow").tag(SimulatorPrivacyAction.grant)
                        Text("Deny").tag(SimulatorPrivacyAction.revoke)
                        Text("Ask Again").tag(SimulatorPrivacyAction.reset)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if let caption = appleSupportCaption(controls.route(.permissions).support) {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Simulator: Time Zone…

/// Chooses the zone the simulator takes at the next boot Device Hub Pro starts.
struct TimeZoneSheet: View {
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var choice: String?

    private var controls: AppleControlsController { workspace.appleControls }

    private var udid: String? { simulatorUDID(workspace) }

    private var zones: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let all = allTimeZoneIdentifiers()
        return trimmed.isEmpty ? all : all.filter { timeZoneMatches($0, query: trimmed) }
    }

    var body: some View {
        let running: String? = controls.bootTimeZone.flatMap { $0 }
        DHSheet(
            title: "Time Zone",
            width: 470,
            actions: [
                DHSheetAction(title: "Set and Restart") {
                    controls.setTimeZone(choice)
                    dismiss()
                    Task { await controls.restartForTimeZone() }
                },
                DHSheetAction(title: "Set", isDefault: true) {
                    controls.setTimeZone(choice)
                    dismiss()
                },
            ]
        ) {
            TextField("Search time zones", text: $query)
                .textFieldStyle(.roundedBorder)
            List(selection: $choice) {
                Text("Mac's time zone").tag(String?.none)
                ForEach(zones, id: \.self) { zone in
                    HStack {
                        Text(zone)
                        Spacer()
                        if let detail = timeZoneDetail(zone) {
                            Text(detail).foregroundStyle(.secondary)
                        }
                    }
                    .tag(Optional(zone))
                }
            }
            .scrollContentBackground(.hidden)
            .background(
                RoundedRectangle(cornerRadius: DHSheetMetrics.cardRadius, style: .continuous)
                    .fill(Color(nsColor: .quaternarySystemFill))
            )
            .frame(height: 240)
            Text("Now \(running ?? "the Mac's zone (\(TimeZone.current.identifier))"). "
                 + "A zone applies when Device Hub Pro starts or restarts the simulator.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            if let udid {
                await controls.ensureAttached(udid)
                choice = controls.timeZone(for: udid)
            }
        }
    }
}

// MARK: - Android: Sensors…, Simulate ▸ sheets, Open URL…

/// The emulator's virtual sensors: pick a sensor, click a preset (applied at
/// once) or enter values by hand within the sensor's official range.
struct SensorsSheet: View {
    @Environment(DeviceWorkspace.self) private var workspace

    var body: some View {
        @Bindable var extras = workspace.extras
        let kind = extras.selectedSensor
        let range = kind.range
        DHSheet(
            title: "Sensors",
            width: 540,
            cancelTitle: "Done",
            actions: [
                DHSheetAction(title: "Refresh") { Task { await extras.refreshSensorDraft() } },
                DHSheetAction(title: "Apply", isDefault: true) { Task { await extras.applySensorValues() } },
            ]
        ) {
            DHSheetCard {
                DHSheetRow(title: "Sensor:") {
                    Picker("Sensor", selection: Binding(
                        get: { extras.selectedSensor },
                        set: { extras.selectSensor($0) }
                    )) {
                        ForEach(SensorKind.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text(kind.guideDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DHSheetMetrics.rowInset)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("sensor-description")
                VStack(alignment: .leading, spacing: 6) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(kind.presets) { preset in
                            Button(preset.title) { Task { await extras.applyPreset(preset) } }
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("sensor-preset-\(preset.title)")
                        }
                    }
                    if let caption = kind.presetCaption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DHSheetMetrics.rowInset)
                .padding(.vertical, 8)
                if let values = extras.sensorReadings[kind] {
                    DHSheetRow(title: "Reading:") {
                        Text("\(values.map { String(format: "%.3f", $0) }.joined(separator: ", ")) \(kind.unit)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                ForEach(extras.sensorDraft.indices, id: \.self) { index in
                    DHSheetRow(
                        title: (kind.axisLabels.indices.contains(index) ? kind.axisLabels[index] : "\(index)") + ":"
                    ) {
                        HStack(spacing: 8) {
                            Slider(
                                value: Binding(
                                    get: {
                                        let values = extras.currentDraftValues()
                                        return values.indices.contains(index) ? Double(range.clamp(values[index])) : 0
                                    },
                                    set: {
                                        if extras.sensorDraft.indices.contains(index) {
                                            extras.sensorDraft[index] = String(format: "%.3f", $0)
                                        }
                                    }
                                ),
                                in: Double(range.minimum)...Double(range.maximum),
                                onEditingChanged: { editing in
                                    if !editing { Task { await extras.applySensorValues() } }
                                }
                            )
                            .frame(width: 130)
                            .accessibilityLabel("Sensor slider \(index + 1)")
                            DHSheetTextField(
                                placeholder: "0",
                                text: Binding(
                                    get: { extras.sensorDraft.indices.contains(index) ? extras.sensorDraft[index] : "" },
                                    set: { if extras.sensorDraft.indices.contains(index) { extras.sensorDraft[index] = $0 } }
                                ),
                                width: 86
                            )
                            .onSubmit { extras.clampDraft() }
                            .accessibilityLabel("Sensor value \(index + 1)")
                            Text(range.caption(unit: kind.unit))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 110, alignment: .leading)
                        }
                    }
                }
            }
        }
        .task { await workspace.extras.refreshSensor() }
    }
}

/// Simulates an incoming call to the emulator.
struct IncomingCallSheet: View {
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var extras = workspace.extras
        ExtrasSheetFrame(
            title: "Incoming Call",
            confirmTitle: "Call",
            isConfirmEnabled: !extras.callNumber.isEmpty,
            confirm: {
                Task { if await workspace.extras.placeIncomingCall() { dismiss() } }
            }
        ) {
            DHSheetCard {
                DHSheetRow(title: "Number:") {
                    DHSheetTextField(placeholder: "Number", text: $extras.callNumber)
                        .accessibilityLabel("Caller number")
                }
            }
        }
    }
}

/// Delivers an SMS to the emulator.
struct IncomingSMSSheet: View {
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var extras = workspace.extras
        ExtrasSheetFrame(
            title: "Incoming SMS",
            confirmTitle: "Send",
            isConfirmEnabled: !extras.smsFrom.isEmpty && !extras.smsText.isEmpty,
            confirm: {
                Task { if await workspace.extras.sendSMS() { dismiss() } }
            }
        ) {
            DHSheetCard {
                DHSheetRow(title: "From:") {
                    DHSheetTextField(placeholder: "Number", text: $extras.smsFrom)
                        .accessibilityLabel("SMS sender")
                }
                DHSheetRow(title: "Message:") {
                    DHSheetTextField(placeholder: "Message", text: $extras.smsText)
                        .accessibilityLabel("SMS message")
                }
            }
        }
    }
}

/// Sets the emulator's own phone number.
struct PhoneNumberSheet: View {
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var extras = workspace.extras
        ExtrasSheetFrame(
            title: "Phone Number",
            confirmTitle: "Set",
            isConfirmEnabled: !extras.emulatorPhoneNumber.isEmpty,
            confirm: {
                Task { if await workspace.extras.applyEmulatorPhoneNumber() { dismiss() } }
            }
        ) {
            DHSheetCard {
                DHSheetRow(title: "Number:") {
                    DHSheetTextField(placeholder: "Number", text: $extras.emulatorPhoneNumber)
                        .accessibilityLabel("Device phone number")
                }
            }
        }
    }
}

/// Opens a web page or a deep link on an Android device (`am start`), with
/// the recent links the simulator's Open URL… and the Links row share.
struct AndroidOpenURLSheet: View {
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var links = workspace.links
        let recents = links.recents.links
        let apiLevel = links.apiLevel(deviceInfo: nil)
        DHSheet(
            // A simulator's sheet names its device ("Open URL on “iPhone 17 Pro”").
            title: workspace.context.device.map { "Open URL on \(dhQuoted(workspace.services.displayName(of: $0)))" } ?? "Open URL",
            width: 470,
            actions: [
                DHSheetAction(
                    title: "Open",
                    isEnabled: links.validation(apiLevel: apiLevel) != nil && !links.isOpening,
                    isDefault: true
                ) {
                    dismiss()
                    Task { await workspace.links.open(apiLevel: apiLevel) }
                },
            ]
        ) {
            DHSheetCard {
                DHSheetRow(title: "URL:") {
                    HStack(spacing: 6) {
                        DHSheetTextField(placeholder: "https://example.com or myapp://path", text: $links.draft, width: 250)
                        SavedLinksControl(draft: $links.draft)
                        Menu {
                            ForEach(recents, id: \.self) { link in
                                Button(LinksRowText.recentTitle(link)) { links.draft = link }
                            }
                            Divider()
                            Button("Clear Recents") { links.clearRecents() }
                        } label: {
                            Image(systemName: LinksRowText.recentGlyph)
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
