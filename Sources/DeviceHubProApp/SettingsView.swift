import AppKit
import SwiftUI
import DeviceHubProKit

/// App settings, hosted in the standard Settings window.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppUpdater.self) private var updater
    @State private var sdk = SDKComponentModel()
    @State private var installedEmulatorVersion: String?
    @State private var emulatorUpdateError: String?
    /// The image whose removal the alert is asking about.
    @State private var pendingRemoval: SystemImageRemovalPlan?

    var body: some View {
        Form {
            if updater.isEnabled {
                Section("Updates") {
                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { updater.automaticChecks },
                        set: { updater.setAutomaticChecks($0) }
                    ))
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }

            Section("Android tools") {
                LabeledContent(
                    "Android SDK tools",
                    value: model.adbIsAvailable ? (model.adbClient?.adbURL.path ?? "Not found") : "Not set up"
                )
                if !model.preferences.androidSDKPath.isEmpty {
                    LabeledContent("SDK folder", value: model.preferences.androidSDKPath)
                }
                HStack {
                    Button("Locate SDK\u{2026}") { model.androidSetup.chooseSDKFolder() }
                    if !model.adbIsAvailable {
                        Button("Install Android Tools\u{2026}") {
                            model.focusedWorkspace.window.isAndroidSetupPresented = true
                        }
                    }
                }
                if let error = model.androidSetup.locateError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Android system images") {
                sdkSection
            }

            Section("Appearance") {
                Toggle("Show device frame", isOn: Binding(
                    get: { model.focusedWorkspace.window.showDeviceFrame },
                    set: { model.setShowDeviceFrameInAllWindows($0) }
                ))
            }

            Section("Screenshots") {
                Toggle("Include device frame", isOn: Binding(
                    get: { model.preferences.includeDeviceFrameInScreenshots },
                    set: { model.preferences.setIncludeDeviceFrameInScreenshots($0) }
                ))

                Text("Composites each capture into the active device's skin artwork. Falls back to the raw screenshot when no skin is available. Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Save in") {
                    HStack {
                        Text(captureFolderLabel)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseCaptureFolder() }
                        Button("Use Default") { model.preferences.setCaptureFolder(nil) }
                            .disabled(model.preferences.captureFolderPath.isEmpty)
                    }
                }

                Text("Where screenshots and recordings are saved. By default the Mac's screenshot folder, else the Desktop. A folder that no longer exists falls back to the default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Only with simulator tooling, like the app menu's Option
            // alternate the caption points to.
            if model.simulators.tooling.tier >= .t1 {
                Section("Simulators") {
                    Picker("When Device Hub Pro quits", selection: Binding(
                        get: { model.preferences.shutsDownStartedSimulatorsOnQuit },
                        set: { model.preferences.setShutsDownStartedSimulatorsOnQuit($0) }
                    )) {
                        Text("Shut down the simulators it started").tag(true)
                        Text("Keep simulators running").tag(false)
                    }

                    Text("Hold Option in the Device Hub Pro menu to quit the other way. A simulator Device Hub Pro did not start is never shut down.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Off by default. Off, the app never runs `devicectl list
            // devices`; on, it lists iPhones and iPads every 5 s while
            // active, and a device gets no other command until it is chosen
            // with "Use This Device…".
            if model.simulators.tooling.tier >= .t1 {
                Section("Physical Apple devices") {
                    Toggle("Show physical Apple devices", isOn: Binding(
                        get: { model.physicalInventory.isShowing },
                        set: { model.physicalInventory.setShowing($0) }
                    ))

                    if model.physicalInventory.isShowing, model.physicalInventory.restrictedUDID != nil {
                        Text("A launch option limits the list to one device, which counts as enabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Only the devices in use: choosing one is done in the
                    // sidebar or the stage, where its confirmation shows.
                    ForEach(model.physicalInventory.entries.filter(\.isEnabled)) { entry in
                        LabeledContent(entry.name) {
                            if entry.isEnabledByLaunchOption {
                                Text("Enabled")
                                    .foregroundStyle(.secondary)
                            } else {
                                Button("Stop Using This Device") {
                                    model.physicalInventory.disable(udid: entry.udid)
                                }
                            }
                        }
                    }

                    Text("Lists iPhones and iPads connected to this Mac in the sidebar. Every device starts Not enabled: Device Hub Pro sends nothing to a device until you choose Use This Device in the sidebar. Device Hub Pro pairs a phone only when you press Pair in Pair Nearby Device; trusting it and Developer Mode stay your own steps on the phone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Siri and the standard input runner need a development profile that covers the phone (Xcode's automatic signing). The helper is built and signed once, is reachable only over the phone's own link to this Mac (USB or Wi-Fi) and takes commands only from this Mac. It uses the Apple Development certificate Xcode keeps for you; nothing needs entering here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // On by default; the public capture stays the fallback.
                    Toggle("Native live view (private Apple API; no Camera permission)", isOn: Binding(
                        get: { model.preferences.physicalNativeLiveView },
                        set: { model.preferences.setPhysicalNativeLiveView($0) }
                    ))
                    Text("Shows a wired iPhone's screen the way Device Hub does, so macOS never asks for the Camera. The iPhone's audio is not played in this mode. If it cannot start or stalls, the standard live view takes over.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // On by default; the runner stays the lazy fallback.
                    Toggle("Fast input (private Apple API; may break with Xcode updates)", isOn: Binding(
                        get: { model.preferences.physicalFastInput },
                        set: { model.preferences.setPhysicalFastInput($0) }
                    ))
                    Text("As soon as you select an enabled iPhone and its screen shows, mouse, keyboard and the Home and volume buttons reach it directly; nothing needs turning on, and it stops when you leave the device. Keys are sent as physical keys: set the iPhone\u{2019}s hardware keyboard layout to match the Mac\u{2019}s (Settings \u{25B8} General \u{25B8} Keyboard \u{25B8} Hardware Keyboard). Siri still uses the runner (it needs Xcode signed in with an Apple ID). If it cannot start, the status line under the phone says why and offers Retry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Replay") {
                Toggle("Keep a replay buffer", isOn: Binding(
                    get: { model.preferences.replayEnabled },
                    set: { model.setReplayEnabledInAllWindows($0) }
                ))

                Picker("Window", selection: Binding(
                    get: { model.preferences.replayWindowSeconds },
                    set: { model.setReplayWindowSecondsInAllWindows($0) }
                )) {
                    ForEach(AppPreferences.replayWindowOptions, id: \.self) { seconds in
                        Text("\(Int(seconds)) seconds").tag(seconds)
                    }
                }
                .disabled(!model.preferences.replayEnabled)

                Text("Keeps the last \(Int(model.preferences.replayWindowSeconds)) seconds of the screen in memory, so Save Replay (⌥⌘R) can save what just happened. Recording starts when the screen shows; changing the length starts over.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Emulator") {
                Picker("Audio", selection: Binding(
                    get: { model.preferences.emulatorAudioMode },
                    set: { model.setEmulatorAudioMode($0) }
                )) {
                    ForEach(EmulatorAudioMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                Text("In-app: Device Hub Pro plays the device's sound. Emulator: the emulator plays it through the Mac. Disabled: no sound. Applies to emulators started from Device Hub Pro; a USB iPhone's live view plays its sound unless this is Disabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Emulator", value: model.activeEmulatorDescription)

                HStack(spacing: 8) {
                    Button("Use System") {
                        model.setEmulatorBinaryPath("")
                    }
                    .disabled(model.preferences.emulatorBinaryPath.isEmpty)

                    Button("Choose…") {
                        chooseEmulatorBinary()
                    }
                }

                Text("The emulator Device Hub Pro starts virtual devices with. The mirror uses the faster video path automatically on emulator 37.2.3 and newer, and falls back to a slower one on older emulators or if the fast one fails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                emulatorUpdateRow

                Toggle("Repair AVD display mismatches", isOn: Binding(
                    get: { model.preferences.autoRepairAvdDisplay },
                    set: { model.preferences.setAutoRepairAvdDisplay($0) }
                ))

                Text("Before boot, aligns an AVD's LCD size with its skin when exactly one axis disagrees (the original configuration file is kept as a backup beside it). Keeps the live video filling the device frame.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 760)
        .task {
            reloadInstalledEmulatorVersion()
            await sdk.refresh()
        }
        .sheet(item: Binding(get: { sdk.licensePrompt }, set: { _ in })) { prompt in
            SDKLicenseSheet(
                prompt: prompt,
                onAccept: { sdk.acceptLicense() },
                onDecline: { sdk.declineLicense() }
            )
        }
    }

    private func reloadInstalledEmulatorVersion() {
        installedEmulatorVersion = model.emulatorManager.flatMap {
            EmulatorVersion.installedVersion(emulatorBinary: $0.emulatorURL)
        }
    }

    private var emulatorUpdateOffer: EmulatorUpdateOffer? {
        let running = model.inventory.devices.contains { $0.isEmulator }
            || !model.boot.startingAvdNames.isEmpty
        return EmulatorUpdateOffer.make(
            installed: installedEmulatorVersion,
            available: sdk.availableEmulatorVersion,
            emulatorRunning: running
        )
    }

    /// Shown only while an update would help; nothing otherwise.
    @ViewBuilder
    private var emulatorUpdateRow: some View {
        if let offer = emulatorUpdateOffer {
            LabeledContent {
                switch sdk.downloadState(package: EmulatorUpdateOffer.package) {
                case .downloading(let progress):
                    HStack(spacing: 8) {
                        if let progress {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .frame(width: 80)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Button("Cancel") { sdk.cancelDownload() }
                            .controlSize(.small)
                    }
                default:
                    Button("Update\u{2026}") { updateEmulator() }
                        .disabled(offer.blockedByRunningEmulator || !sdk.canStartDownload)
                }
            } label: {
                Text(offer.title)
            }
            Text(offer.blockedByRunningEmulator ? EmulatorUpdateOffer.blockedCaption : offer.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message = emulatorUpdateError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func updateEmulator() {
        emulatorUpdateError = nil
        Task {
            let outcome = await sdk.startDownload(package: EmulatorUpdateOffer.package)
            if case .failed(let message) = outcome { emulatorUpdateError = message }
            reloadInstalledEmulatorVersion()
        }
    }

    /// The capture folder's name, or what the default is.
    /// The folder captures land in, by name: a "Default" label next to the
    /// "Default" button said nothing about where that is.
    private var captureFolderLabel: String {
        if let folder = model.preferences.captureFolder { return folder.lastPathComponent }
        let fallback = FileManager.default.displayName(atPath: ScreenshotFile.defaultDirectory().path)
        return model.preferences.captureFolderPath.isEmpty
            ? "\(fallback) (default)"
            : "\(fallback) (chosen folder missing)"
    }

    private func chooseCaptureFolder() {
        let panel = NSOpenPanel()
        panel.message = "Choose where screenshots and recordings are saved."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.preferences.captureFolder
        if panel.runModal() == .OK, let url = panel.url {
            model.preferences.setCaptureFolder(url)
        }
    }

    /// Installed system images with their on-disk size, plus sdkmanager's
    /// availability state when it could not be reached.
    @ViewBuilder
    private var sdkSection: some View {
        if sdk.installedImages.isEmpty {
            Text("No system images are installed.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(sdk.installedImages) { image in
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(sdk.installedSizeText(package: image.package))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if sdk.removingPackage == image.package {
                            ProgressView().controlSize(.small)
                            Text("Removing\u{2026}").foregroundStyle(.secondary)
                        } else {
                            Button("Remove\u{2026}") { pendingRemoval = removalPlan(for: image) }
                                .disabled(!sdk.canStartDownload)
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(image.friendlyLabel)
                        if let failure = sdk.removalFailures[image.package] {
                            Text(failure)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .alert(
                pendingRemoval?.title ?? "",
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                presenting: pendingRemoval
            ) { plan in
                Button("Cancel", role: .cancel) {}
                if plan.blockedReason == nil {
                    Button("Remove", role: .destructive) {
                        Task {
                            await sdk.removeImage(package: plan.package)
                            // The emulators' cards and the create sheet's
                            // image lists read the disk again.
                            await model.refresh()
                        }
                    }
                }
            } message: { plan in
                Text(plan.blockedReason.map { "\(plan.message)\n\n\($0)" } ?? plan.message)
            }
        }
        if case .unavailable(let reason) = sdk.availableState {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The confirmation for removing `image`: what it frees and which
    /// emulators (by the sidebar's names) are built on it.
    private func removalPlan(for image: SystemImage) -> SystemImageRemovalPlan {
        let names = AvdConfig.avdNames(usingSystemImage: image.package)
        let cards = model.catalog.avdCards
        let shown = { (name: String) in cards.first { $0.name == name }?.displayName ?? name }
        return SystemImageRemovalPlan.make(
            image: image,
            sizeText: sdk.installedSizeText(package: image.package),
            users: names.map(shown),
            runningUsers: names.filter { name in cards.first { $0.name == name }?.isRunning == true }.map(shown)
        )
    }

    private func chooseEmulatorBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the emulator binary"
        if panel.runModal() == .OK, let url = panel.url {
            model.setEmulatorBinaryPath(url.path)
        }
    }
}
