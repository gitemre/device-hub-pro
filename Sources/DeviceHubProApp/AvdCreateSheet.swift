import SwiftUI
import DeviceHubProKit

/// AVD creation readiness, resolved when the create sheet opens.
enum AvdCreateStatus: Equatable {
    case unknown
    case checking
    case ready
    case missingJava
    case missingAvdmanager
    case noSystemImages
    case loadFailed(String)
}

/// Device Hub-style create panel: Name, OS Version, Model.
///
/// The Name field's placeholder is the picked Model's name, made unique
/// against the AVD home, and an empty field creates with it (like Device
/// Hub and the iOS sheet). A typed name is validated live
/// (`AvdNameValidation`): characters avdmanager rejects, or a name an AVD
/// already uses (ignoring case), show why inline and keep Create disabled —
/// creating over an existing AVD would replace it and its data. Nothing is
/// shown before the user typed. Create hands the work (the system image
/// download when needed, then avdmanager) to `AvdCreationQueue` and the sheet
/// closes at once: the download shows in the sidebar and the toolbar's
/// activity popover, never as a locked screen.
struct AvdCreateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let formFactor: SkinCatalogEntry.Category
    /// The catalog skin the sheet was opened for: its hardware profile is
    /// preselected as the Model when avdmanager lists one.
    var preferredSkin: String? = nil
    /// Called after the AVD was created, before the sheet dismisses (the
    /// Browse Catalog closes itself then).
    var onCreated: (() -> Void)? = nil

    @State private var avdName = ""
    @State private var selectedImageID: String?
    @State private var selectedDeviceID: String?
    @State private var showsDownloads = false
    @State private var errorMessage: String?
    /// Names a new AVD must not reuse (AVD home + the model's list), read
    /// when the sheet opens and after the AVD list or a failed create changes.
    @State private var existingNames: [String] = []
    /// When the image list started loading, for the "still working" hint.
    @State private var imagesLoadStarted = Date()
    /// Free space on the SDK's volume, read when the sheet opens.
    @State private var freeBytes: Int64?

    /// The SDK model of the background queue: it outlives this sheet, so a
    /// download started here keeps running after the sheet closes.
    private var sdk: SDKComponentModel { model.avdCreation.sdk }

    private var models: [AvdDevice] {
        AvdDeviceCatalog.models(for: formFactor, in: model.catalog.avdDevices)
    }

    private var selectedDevice: AvdDevice? {
        models.first(where: { $0.id == selectedDeviceID }) ?? models.first
    }

    /// The hardware profile's form factor, which decides the images it takes.
    private var selectedCategory: SkinCatalogEntry.Category {
        selectedDevice?.formFactor ?? formFactor
    }

    /// The OS Version popup's images: installed and compatible with the
    /// chosen profile, newest first.
    private var installedOptions: [SystemImageOption] {
        SystemImageCatalog.options(
            SystemImageCatalog.compatible(sdk.installedImages, with: selectedCategory)
        )
    }

    /// The chosen profile's minimum API; nil (everything allowed) when the
    /// table could not be read or has no entry for the profile.
    private var minApi: String? {
        AvdProfileMinimum.minApi(profileID: selectedDevice?.id, table: model.catalog.minApiTable)
    }

    /// The not-installed image offered (for download) while no installed
    /// image meets the profile's minimum.
    private var offeredDownload: SystemImage? {
        guard !installedOptions.contains(where: { AvdProfileMinimum.meets($0.image, minApi: minApi) })
        else { return nil }
        return AvdProfileMinimum.downloadSuggestion(
            installed: sdk.installedImages,
            available: sdk.availableImages,
            minApi: minApi,
            category: selectedCategory,
            hostAbi: Self.hostAbi
        )
    }

    /// The pick when nothing (valid) is chosen: the newest installed image
    /// meeting the minimum, else the offered download, else (only for a
    /// profile with no minimum) the newest installed image. A profile with a
    /// minimum never falls back to a below-minimum image: while sdkmanager's
    /// list is still loading there is no pick yet, and the menu says so.
    private var defaultImage: SystemImage? {
        AvdProfileMinimum.defaultImage(
            installed: sdk.installedImages,
            available: sdk.availableImages,
            minApi: minApi,
            category: selectedCategory,
            hostAbi: Self.hostAbi
        ) ?? (minApi == nil ? installedOptions.first?.image : nil)
    }

    private var selectedImage: SystemImage? {
        if let id = selectedImageID {
            if let image = installedOptions.first(where: { $0.id == id })?.image { return image }
            if let offered = offeredDownload, offered.id == id { return offered }
        }
        return defaultImage
    }

    /// The selected image is below the profile's minimum API.
    private var selectionBelowMinimum: Bool {
        guard let image = selectedImage else { return false }
        return !AvdProfileMinimum.meets(image, minApi: minApi)
    }

    /// Whether sdkmanager offers images this Mac can run that are not
    /// installed yet (the popup's "Download More System Images…").
    private var hasDownloadableImages: Bool {
        sdk.availableImages.contains { !sdk.isInstalled($0.package) && $0.abi == Self.hostAbi }
    }

    /// The ABI of system images this Mac's emulator can run.
    private static var hostAbi: String {
        #if arch(arm64)
        "arm64-v8a"
        #else
        "x86_64"
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            switch model.catalog.avdCreateStatus {
            case .unknown, .checking:
                checkingView
            case .ready:
                if models.isEmpty {
                    messageView(
                        title: "No \(formFactor.label.lowercased()) profiles",
                        message: "No device models are available for this form factor.",
                        button: "Close",
                        action: { dismiss() }
                    )
                } else if sdk.installedImages.isEmpty, sdk.availableState == .loading {
                    loadingImagesView
                } else if sdk.installedImages.isEmpty, !hasDownloadableImages,
                          case .unavailable(let reason) = sdk.availableState {
                    unavailableView(reason)
                } else if sdk.installedImages.isEmpty, !hasDownloadableImages {
                    messageView(
                        title: "No system images",
                        message: "No system images are installed and none are offered for this Mac. Check the SDK and the network, then press Check Again.",
                        button: "Check Again",
                        action: { Task { await refreshAll() } }
                    )
                } else {
                    formView
                }
            case .missingJava:
                missingJavaView
            case .missingAvdmanager:
                messageView(
                    title: "Android tools needed",
                    message: "Creating an emulator needs Google\u{2019}s Android command-line tools. Device Hub Pro can download them for you.",
                    button: "Check Again",
                    offersSetup: true
                )
            case .noSystemImages:
                messageView(
                    title: "No system images",
                    message: "No Android system images are installed and the tool that downloads them is missing. Device Hub Pro can install it for you.",
                    button: "Check Again",
                    offersSetup: true
                )
            case .loadFailed(let message):
                messageView(title: "Could not load devices", message: message, button: "Try Again")
            }
        }
        .frame(width: 470)
        .task {
            freeBytes = DiskSpaceCheck.freeBytes(at: AvdmanagerClient.sdkRoot() ?? FileManager.default.homeDirectoryForCurrentUser)
            reloadExistingNames()
            switch model.catalog.avdCreateStatus {
            case .ready, .checking:
                break
            default:
                await model.catalog.refreshAvdCreateOptions()
            }
            async let table = model.catalog.ensureMinApiTable()
            await sdk.refresh()
            _ = await table
            prefillIfNeeded()
            reconcileImageSelection()
        }
        .onChange(of: model.catalog.avdCreateStatus) { prefillIfNeeded() }
        .onChange(of: model.catalog.avds) { reloadExistingNames() }
        .onChange(of: sdk.installedImages) { reconcileImageSelection() }
        .onChange(of: sdk.availableImages) { reconcileImageSelection() }
        .onChange(of: model.catalog.minApiTable) { reconcileImageSelection() }
        .onChange(of: selectedDeviceID) { reconcileImageSelection() }
        .sheet(isPresented: $showsDownloads) {
            SystemImageDownloadSheet(
                sdk: sdk,
                category: selectedCategory,
                hostAbi: Self.hostAbi,
                onInstalled: { image in selectImage(image) }
            )
        }
    }

    private var checkingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking Android tools…")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 20)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(20)
    }

    /// The hint under the loading spinner once the load is slow.
    static func loadingHint(elapsed: TimeInterval) -> String? {
        guard elapsed >= 20 else { return nil }
        return "Still working\u{2026} \(Int(elapsed)) s so far. Reading Google\u{2019}s catalog can take a minute on a slow connection."
    }

    /// The plain sentence (and raw text) for a failed system image listing.
    static func listFailure(_ raw: String) -> PlainFailure {
        PlainFailure.make(raw, fallback: "Couldn\u{2019}t load the list of system images.")
    }

    /// The caption under the form while a system image would be downloaded.
    static func downloadNote(freeBytes: Int64?) -> [String] {
        var lines = [
            "This downloads a system image (typically about \(DiskSpaceCheck.sizeText(DiskSpaceCheck.typicalImageBytes))). "
                + "Cancelling a download discards what was downloaded so far.",
        ]
        if let warning = DiskSpaceCheck.warning(freeBytes: freeBytes) { lines.append(warning) }
        return lines
    }

    private func unavailableView(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Couldn\u{2019}t load system images")
                .font(.headline)
            PlainFailureView(failure: Self.listFailure(reason))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Try Again") { Task { await refreshAll() } }
                    .glassProminentButton()
            }
        }
        .padding(20)
    }

    private var loadingImagesView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading available system images…")
                        .foregroundStyle(.secondary)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let hint = Self.loadingHint(elapsed: context.date.timeIntervalSince(imagesLoadStarted)) {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 20)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(20)
    }

    private var missingJavaView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Java is needed")
                .font(.headline)
            Text("Creating an emulator needs Java, and no working runtime was found. Device Hub Pro can download a free one into its own folder, or you can install a JDK yourself and press Check Again.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Check Again") {
                    Task { await model.catalog.refreshAvdCreateOptions() }
                }
                Button("Set Up Android Tools\u{2026}") { openAndroidSetup() }
                    .glassProminentButton()
            }
        }
        .padding(20)
    }

    /// Closes this sheet and opens the guided setup once it has gone.
    private func openAndroidSetup() {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            workspace.window.isAndroidSetupPresented = true
        }
    }

    private func messageView(
        title: String,
        message: String,
        button: String,
        offersSetup: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                if offersSetup {
                    Button(button) { Task { await model.catalog.refreshAvdCreateOptions() } }
                    Button("Set Up Android Tools\u{2026}") { openAndroidSetup() }
                        .glassProminentButton()
                } else {
                    Button(button) {
                        if let action {
                            action()
                        } else {
                            Task { await model.catalog.refreshAvdCreateOptions() }
                        }
                    }
                    .glassProminentButton()
                }
            }
        }
        .padding(20)
    }

    private var formView: some View {
        VStack(spacing: 0) {
            DHSheetCard {
                DHSheetRow(title: "Name:") {
                    VStack(alignment: .trailing, spacing: 4) {
                        DHSheetTextField(placeholder: placeholderName, text: $avdName)
                        if let message = typedNameValidation?.message {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: DHSheetMetrics.fieldWidth, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 4)
                }
                DHSheetRow(title: "OS Version:") { osVersionMenu }
                DHSheetRow(title: "Model:") { modelMenu }
            }
            .padding(DHSheetMetrics.cardInset)

            if selectionBelowMinimum, let minApi, let device = selectedDevice {
                Text(AvdProfileMinimum.explanation(deviceName: device.name, minApi: minApi))
                    .foregroundStyle(.red)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            if needsDownload {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(Self.downloadNote(freeBytes: freeBytes).enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(index == 0 ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            if case .unavailable(let reason) = sdk.availableState {
                VStack(alignment: .leading, spacing: 4) {
                    PlainFailureView(failure: Self.listFailure(reason))
                    Button("Try Again") { Task { await refreshAll() } }
                        .controlSize(.small)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(needsDownload ? "Download & Create" : "Create") { submit() }
                    .glassProminentButton()
                    .disabled(!canSubmit)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, DHSheetMetrics.footerSide)
            .padding(.top, DHSheetMetrics.footerTop)
            .padding(.bottom, DHSheetMetrics.footerBottom)
        }
    }

    /// The OS Version popup: the installed images that fit the profile,
    /// newest first, a separator and the download sheet. With none installed
    /// for this profile the popup says so and only offers the download.
    private var osVersionMenu: some View {
        let options = installedOptions
        return Menu {
            ForEach(options) { option in
                Toggle(menuTitle(for: option), isOn: Binding(
                    get: { selectedImage?.id == option.id },
                    set: { if $0 { selectedImageID = option.id } }
                ))
            }
            if let offered = offeredDownload {
                Toggle(offered.friendlyLabel + " \u{00B7} Download", isOn: Binding(
                    get: { selectedImage?.id == offered.id },
                    set: { if $0 { selectedImageID = offered.id } }
                ))
            }
            if !options.isEmpty || offeredDownload != nil { Divider() }
            Button("Download More System Images\u{2026}") { showsDownloads = true }
        } label: {
            Text(selectedImageTitle(options))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .modifier(DHSheetPopupChrome(symbol: "chevron.down"))
    }

    private func menuTitle(for option: SystemImageOption) -> String {
        var title = option.menuTitle
        if let minApi, !AvdProfileMinimum.meets(option.image, minApi: minApi) {
            title += AvdProfileMinimum.requiresSuffix(minApi: minApi)
        }
        return title
    }

    private func selectedImageTitle(_ options: [SystemImageOption]) -> String {
        if let option = options.first(where: { $0.id == selectedImage?.id }) { return menuTitle(for: option) }
        if let offered = selectedImage, offered.id == offeredDownload?.id {
            return offered.friendlyLabel + " \u{00B7} Download"
        }
        if case .loading = sdk.availableState { return "Finding a compatible image\u{2026}" }
        return hasDownloadableImages ? "Choose an image to download" : "No System Images"
    }

    private var modelMenu: some View {
        DHSheetPopup(
            options: models.map { DHSheetPopup<String>.Option(value: $0.id, title: $0.name) },
            selection: Binding(
                get: { selectedDevice?.id ?? "" },
                set: { selectedDeviceID = $0 }
            )
        )
    }

    /// The Name field's placeholder: the Model's name, free in the AVD home.
    private var placeholderName: String {
        Self.placeholderName(device: selectedDevice, existing: existingNames)
    }

    /// The AVD name a create would use right now.
    private var effectiveName: String {
        Self.effectiveName(typed: avdName, placeholder: placeholderName)
    }

    /// The problem with what the user typed; nil while the field is empty
    /// (the placeholder is used and is free) or valid.
    private var typedNameValidation: AvdNameValidation? {
        Self.typedNameValidation(typed: avdName, existing: existingNames)
    }

    private var needsDownload: Bool {
        guard let image = selectedImage else { return false }
        return !sdk.isInstalled(image.package)
    }

    private var canSubmit: Bool {
        Self.canSubmit(
            takenByQueuedJob: model.avdCreation.job(forAvdNamed: effectiveName) != nil
        ) && typedNameValidation == nil && selectedDevice != nil && selectedImage != nil
            && !selectionBelowMinimum
    }

    /// Whether Create can start. Nothing else running blocks it: a download
    /// waits its turn for the app-wide install slot in the background queue
    /// (shown as "Waiting"), and creates run one at a time there. Only a
    /// name a queued emulator already takes does.
    static func canSubmit(takenByQueuedJob: Bool) -> Bool {
        !takenByQueuedJob
    }

    /// The Model's display name, made unique against the AVDs that already
    /// exist: `Pixel 9 Pro`, then `Pixel 9 Pro 2`, `Pixel 9 Pro 3`, compared
    /// as the AVD name they become (`Pixel_9_Pro`), ignoring case.
    static func placeholderName(device: AvdDevice?, existing: [String]) -> String {
        let base = device?.name ?? "Name"
        let taken = Set(existing.map { $0.lowercased() })
        func isFree(_ name: String) -> Bool {
            !taken.contains(AvdmanagerClient.sanitizedAvdName(name).lowercased())
        }
        if isFree(base) { return base }
        var index = 2
        while !isFree("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    /// The AVD name to create: what was typed, else the placeholder turned
    /// into a valid AVD name (avdmanager takes no spaces).
    static func effectiveName(typed: String, placeholder: String) -> String {
        typed.isEmpty ? AvdmanagerClient.sanitizedAvdName(placeholder) : typed
    }

    /// Why a typed name cannot be used; nil for an empty field (the
    /// placeholder is used) and for a valid name.
    static func typedNameValidation(typed: String, existing: [String]) -> AvdNameValidation? {
        guard !typed.isEmpty else { return nil }
        let validation = AvdNameValidation.validate(typed, existing: existing)
        return validation.isValid ? nil : validation
    }

    /// The Model to preselect: the hardware profile matching the catalog
    /// skin the sheet was opened for, else the first profile listed.
    static func preferredDeviceID(skin: String?, in models: [AvdDevice]) -> String? {
        if let skin, let match = AvdmanagerClient.device(forSkinName: skin, devices: models) {
            return match.id
        }
        return models.first?.id
    }

    private func reloadExistingNames() {
        existingNames = model.catalog.existingAvdNames() + model.avdCreation.reservedNames
    }

    private func refreshAll() async {
        await model.catalog.refreshAvdCreateOptions()
        await sdk.refresh()
    }

    private func prefillIfNeeded() {
        guard model.catalog.avdCreateStatus == .ready else { return }
        if selectedDeviceID == nil {
            selectedDeviceID = Self.preferredDeviceID(skin: preferredSkin, in: models)
        }
        if selectedImageID == nil {
            selectedImageID = defaultImage?.id
        }
    }

    /// A new installed image (a finished download) is selected when it fits
    /// the profile; the popup then names it.
    private func selectImage(_ image: SystemImage) {
        if image.isCompatible(with: selectedCategory) {
            selectedImageID = image.id
        }
    }

    /// After the profile, the images or the minimum table change: keeps the
    /// pick when it still fits and meets the minimum, else the default.
    private func reconcileImageSelection() {
        // A pick below the new profile's minimum is replaced by the default.
        if let image = selectedImage, image.id == selectedImageID,
           AvdProfileMinimum.meets(image, minApi: minApi) { return }
        selectedImageID = defaultImage?.id
    }

    /// Hands the create to the background queue under exactly the validated
    /// name and closes the sheet: the download (when the image is not
    /// installed) and avdmanager run on, shown in the sidebar and the
    /// toolbar's activity popover; failures show there with Retry.
    private func submit() {
        guard canSubmit, let device = selectedDevice, let image = selectedImage else { return }
        let request = AvdCreationRequest(
            name: effectiveName,
            // The placeholder (the model's name, "Television (1080p)") is
            // what the user sees; the id is its sanitized form.
            displayName: avdName.isEmpty ? placeholderName : nil,
            deviceID: device.id,
            deviceName: device.name,
            image: image,
            reveal: CreatedAvdReveal(workspace: workspace)
        )
        guard model.avdCreation.enqueue(request) else {
            errorMessage = "An emulator named \(request.name) is already being created."
            return
        }
        errorMessage = nil
        onCreated?()
        dismiss()
    }
}
