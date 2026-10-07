import SwiftUI
import DeviceHubProKit

/// Stopped-or-unprovisioned Pixel detail: the skin hero, a readiness card
/// listing every prerequisite (tools, Java, system image) with the image
/// picker, and the primary action (Start / Download & Create & Start).
/// Mirrors AvdDetailView's layout language.
///
/// The stage keeps this view's identity while the sidebar moves from one
/// Pixel to another, so the per-device state (image pick, posture) is reset
/// and the previous device's provisioning abandoned on every `skinName`
/// change; the provisioning run itself lives in `PixelCatalogModel`.
struct PixelDeviceDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(PixelCatalogModel.self) private var catalog
    let skinName: String

    @State private var selectedPackage: String?
    @State private var javaAvailable: Bool?
    @State private var variantID = "default"

    private var device: PixelDevice? { catalog.device(forSkin: skinName) }

    private var provisioning: PixelCatalogModel.ProvisioningState {
        catalog.provisioningState(forSkin: skinName)
    }

    private var card: AvdCard? {
        model.catalog.avdCards.first(where: { $0.skin?.name == skinName })
    }

    private var variant: SkinVariant? {
        device?.skin.variants.first(where: { $0.id == variantID })
            ?? device?.skin.preferredVariant
    }

    private var isOnline: Bool {
        guard let serial = card?.serial else { return false }
        return model.inventory.devices.first(where: { $0.serial == serial })?.isOnline ?? false
    }

    private var candidates: [PixelImageCandidate] {
        device.map(catalog.candidates(for:)) ?? []
    }

    private var selectedCandidate: PixelImageCandidate? {
        if let selectedPackage,
           let match = candidates.first(where: { $0.image.package == selectedPackage })
        {
            return match
        }
        return device.flatMap(catalog.preferredCandidate(for:))
    }

    private var missingDependencies: [PixelDependency] {
        guard let device else { return [] }
        return catalog.readiness(for: device, hasJava: javaAvailable ?? true)
    }

    private var subtitle: String {
        guard let device else { return "Pixel device" }
        var parts: [String] = []
        if let card {
            parts.append(isOnline ? "Running" : "Installed")
            if let target = card.targetLabel { parts.append(target) }
        } else {
            parts.append("Not installed")
        }
        if let minApi = device.minApi {
            parts.append("Requires API \(minApi)+")
        }
        return parts.joined(separator: " · ")
    }

    private var primaryTitle: String {
        if card != nil {
            return isOnline ? "Mirror" : "Start"
        }
        if selectedCandidate?.isInstalled == true { return "Create & Start" }
        return "Download & Create & Start"
    }

    private var primaryDisabled: Bool {
        if model.isBusy { return true }
        if card != nil { return false }
        if model.catalog.isCreatingAvd { return true }
        guard let device else { return true }
        if let candidate = selectedCandidate, !candidate.isInstalled {
            // A download is queued in the background (it waits for the
            // install slot there), so only a job of this device blocks.
            return queuedJob != nil || !PixelCatalogModel.canProvision(
                candidate: candidate,
                missing: catalog.readiness(for: device, hasJava: javaAvailable ?? true),
                canStartDownload: true
            )
        }
        return !catalog.canProvision(
            device: device,
            candidate: selectedCandidate,
            hasJava: javaAvailable ?? true
        )
    }

    /// This device's background creation, if one is queued or running.
    private var queuedJob: AvdCreationJob? {
        model.avdCreation.jobs.first { $0.request.deviceName == device?.displayName }
    }

    var body: some View {
        Group {
            if let device {
                content(device: device)
            } else {
                Text("Device not found")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: skinName) {
            await catalog.refresh(from: model)
            await catalog.ensureProfiles(from: model)
            await catalog.loadImages()
            await probeJava()
        }
        .onChange(of: catalog.sdk.installedImages) { followSelection() }
        // A background download finished: this page's own scan is stale.
        .onChange(of: model.avdCreation.sdk.installedImages) {
            Task { await catalog.loadImages() }
        }
        .onChange(of: skinName) {
            selectedPackage = nil
            variantID = "default"
            catalog.cancelProvisioning()
        }
        .onDisappear { catalog.cancelProvisioning() }
        .sheet(item: licensePromptBinding) { prompt in
            SDKLicenseSheet(
                prompt: prompt,
                onAccept: { catalog.acceptLicense() },
                onDecline: { catalog.declineLicense() }
            )
        }
    }

    /// Same contract as the create sheet's binding: answering the prompt is
    /// the model's job, recording a dismissal here could satisfy the install's
    /// next prompt early.
    private var licensePromptBinding: Binding<SDKLicensePrompt?> {
        Binding(
            get: { catalog.licensePrompt },
            set: { _ in }
        )
    }

    @ViewBuilder
    private func content(device: PixelDevice) -> some View {
        StoppedStagePanel {
            SkinHero(variant: variant)
                .frame(height: SkinHero.height)

            if device.category == .foldable {
                Picker("", selection: $variantID) {
                    Text("Open").tag("default")
                    Text("Cover").tag("closed")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Posture")
                .frame(width: 200)
            }

            VStack(spacing: 4) {
                Text(device.displayName)
                    .font(.system(size: ParityMetrics.stoppedNameFontSize, weight: ParityMetrics.stoppedNameFontWeight))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, ParityMetrics.stoppedHeroToNameGap)

            // Device Hub has no counterpart for a Pixel skin's dependencies
            // (no Android SDK, no system image): our own card, unconditional
            // like the rest of this page.
            readinessCard(device: device)
                .frame(maxWidth: 460)

            HStack(spacing: 12) {
                Button {
                    performPrimary(device: device)
                } label: {
                    StagePrimaryButtonLabel(primaryTitle)
                }
                .stagePrimaryButton()
                .disabled(primaryDisabled)

                if card?.serial != nil {
                    Button("Logs") {
                        Task {
                            await workspace.logcat.openLogcat(serial: card?.serial ?? "")
                            workspace.window.selectInspectorTab(.diagnostics)
                        }
                    }
                    .glassButton()
                    .controlSize(.large)
                    .disabled(!isOnline || model.isBusy)
                }
            }
            .padding(.top, 4)

            provisioningStatusView
        }
    }

    // MARK: - Readiness card

    @ViewBuilder
    private func readinessCard(device: PixelDevice) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Dependencies")
                .font(.headline)
                .padding(.bottom, 8)

            dependencyRow(
                title: "Android platform tools",
                detail: "Not installed yet. They let Device Hub Pro talk to devices.",
                isReady: !missingDependencies.contains(.platformTools)
            )
            dependencyRow(
                title: "Android Emulator",
                detail: "Not installed yet.",
                isReady: !missingDependencies.contains(.emulator)
            )
            dependencyRow(
                title: "Command-line tools",
                detail: "Not installed yet. They create emulators and download system images.",
                isReady: !missingDependencies.contains(.commandLineTools)
            )
            if javaAvailable == false {
                dependencyRow(
                    title: "Java runtime",
                    detail: "No Java runtime was found. Creating emulators needs one.",
                    isReady: false
                )
            }

            if !missingDependencies.isEmpty || javaAvailable == false {
                Button("Set Up Android Tools\u{2026}") {
                    workspace.window.isAndroidSetupPresented = true
                }
                .glassProminentButton()
                .padding(.top, 6)
            }

            Divider()
                .padding(.vertical, 8)

            systemImageRow(device: device)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    @ViewBuilder
    private func dependencyRow(title: String, detail: String, isReady: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isReady ? Color.green : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !isReady {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(isReady ? "ready" : "missing")")
    }

    @ViewBuilder
    private func systemImageRow(device: PixelDevice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(
                    systemName: candidates.contains(where: { $0.isInstalled && $0.meetsMinimum })
                        ? "checkmark.circle.fill"
                        : "arrow.down.circle.fill"
                )
                .foregroundStyle(
                    candidates.contains(where: { $0.isInstalled && $0.meetsMinimum })
                        ? Color.green
                        : Color.accentColor
                )
                .accessibilityHidden(true)

                Text("System image")
                Spacer(minLength: 8)

                Picker("System image", selection: Binding(
                    get: { selectedCandidate?.image.package ?? "" },
                    set: { selectedPackage = $0 }
                )) {
                    ForEach(candidates) { candidate in
                        Text(label(for: candidate, device: device))
                            .tag(candidate.image.package)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                // A different pick mid-run would hide the running download's
                // progress and its Cancel button.
                .disabled(candidates.isEmpty || catalog.isProvisioning || catalog.sdk.isDownloading)
            }

            downloadStatusView

            if let minApi = device.minApi,
               let candidate = selectedCandidate,
               !candidate.meetsMinimum
            {
                Text("\(device.displayName) requires API \(minApi) or newer.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func label(for candidate: PixelImageCandidate, device: PixelDevice) -> String {
        var text = candidate.image.friendlyLabel
        if candidate.isInstalled {
            text += " · Installed"
        } else {
            text += " · Download"
        }
        if !candidate.meetsMinimum, let minApi = device.minApi {
            text += " · Requires API \(minApi)+"
        }
        return text
    }

    @ViewBuilder
    private var downloadStatusView: some View {
        if let candidate = selectedCandidate, !candidate.isInstalled {
            switch model.avdCreation.sdk.downloadState(package: candidate.image.package) {
            case .downloading(let progress):
                HStack(spacing: 8) {
                    if let progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(width: 100)
                            .accessibilityLabel("Downloading \(candidate.image.friendlyLabel)")
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Downloading \(candidate.image.friendlyLabel)")
                    }
                    Text(progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "…")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Spacer(minLength: 4)
                    Button("Cancel Download") {
                        if let job = queuedJob {
                            model.avdCreation.cancel(job.id)
                        } else {
                            model.avdCreation.sdk.cancelDownload()
                        }
                    }
                        .fixedSize()
                }
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .font(.callout)
            case .idle:
                Text(queuedJob != nil
                     ? "Waiting for another download to finish; this image downloads next, in the background."
                     : "This image is not installed; it will be downloaded from Google's SDK repository first, in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The provisioning run's step after the download (which the image row
    /// shows with its own progress), or its failure.
    @ViewBuilder
    private var provisioningStatusView: some View {
        switch provisioning {
        case .creating(let name):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Creating \(name)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        case .idle, .starting, .downloading:
            EmptyView()
        }
    }

    // MARK: - Actions

    private func performPrimary(device: PixelDevice) {
        if let card {
            Task {
                if isOnline, let serial = card.serial,
                   let live = model.inventory.devices.first(where: { $0.serial == serial })
                {
                    await workspace.mirror(device: live)
                } else {
                    await model.startAndMirror(avd: card.name, workspace: workspace)
                }
            }
            return
        }
        guard !primaryDisabled, let candidate = selectedCandidate else { return }
        if !candidate.isInstalled {
            // The download and the create run in the background queue, so
            // leaving this page does not cancel them; the AVD starts when
            // it is ready.
            guard let profileID = device.deviceProfileID else { return }
            let name = PixelCatalog.avdName(
                for: device,
                image: candidate.image,
                existing: model.catalog.existingAvdNames() + model.avdCreation.reservedNames
            )
            model.avdCreation.enqueue(AvdCreationRequest(
                name: name,
                displayName: nil,
                deviceID: profileID,
                deviceName: device.displayName,
                image: candidate.image,
                startAfter: true
            ))
            return
        }
        catalog.startProvisioning(device: device, candidate: candidate, model: model, workspace: workspace)
    }

    /// Keeps the user's pick after an install; otherwise falls back to the
    /// model's preferred candidate.
    private func followSelection() {
        guard let selectedPackage,
              candidates.contains(where: { $0.image.package == selectedPackage })
        else {
            self.selectedPackage = nil
            return
        }
    }

    private func probeJava() async {
        // Probe the runtime directly: Java is required for AVD creation even
        // when avdmanager itself cannot be found, and vice versa.
        javaAvailable = await AvdmanagerLocator.workingJava() != nil
    }
}
