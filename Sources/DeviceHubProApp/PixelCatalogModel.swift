import Foundation
import Observation
import DeviceHubProKit

/// The Pixel device list and its provisioning flow. Owns the catalog, the
/// min-API table and one SDK download at a time; AppModel holds no Pixel
/// state (spec §3 boundary rule).
@MainActor
@Observable
final class PixelCatalogModel {
    enum ProvisioningState: Equatable {
        case idle
        /// Set by `startProvisioning` itself, so the run counts as running
        /// before its task reaches the first step.
        case starting
        case downloading(package: String)
        case creating(name: String)
        case failed(String)

        /// A run is starting, downloading or creating.
        var isRunning: Bool {
            switch self {
            case .starting, .downloading, .creating: true
            case .idle, .failed: false
            }
        }
    }

    /// The steps provisioning runs through; the tests replace them.
    struct Actions {
        var download: @MainActor (SDKComponentModel, _ package: String) async -> DownloadOutcome
        var createAvd: @MainActor (
            AppModel,
            _ name: String,
            _ profileID: String,
            _ package: String
        ) async -> String?
        var start: @MainActor (AppModel, _ avdName: String, _ workspace: DeviceWorkspace?) async -> Void

        static var live: Actions {
            Actions(
                download: { sdk, package in await sdk.startDownload(package: package) },
                createAvd: { model, name, profileID, package in
                    await model.catalog.createAvd(name: name, deviceId: profileID, systemImage: package)
                },
                start: { model, avdName, workspace in await model.startAndMirror(avd: avdName, workspace: workspace) }
            )
        }
    }

    private(set) var devices: [PixelDevice] = []
    private(set) var minApiTable: PixelMinApiTable?
    /// The one provisioning run's state; it belongs to `provisioningSkin`.
    /// Pages read it through `provisioningState(forSkin:)`.
    private(set) var provisioningState: ProvisioningState = .idle
    /// The Pixel skin the current (or last failed) run provisions.
    private(set) var provisioningSkin: String?

    let sdk: SDKComponentModel
    private let sdkRoot: URL?
    private var didLoadMinApi: Bool
    private let actions: Actions
    @ObservationIgnored private var provisioningTask: Task<Void, Never>?
    /// Bumped by every start and cancel, so a superseded run never writes
    /// the state of the run that replaced it.
    @ObservationIgnored private var provisioningRun: UInt64 = 0

    init(
        sdk: SDKComponentModel = SDKComponentModel(),
        sdkRoot: URL? = AvdmanagerClient.sdkRoot(),
        minApiTable: PixelMinApiTable? = nil,
        actions: Actions = .live
    ) {
        self.sdk = sdk
        self.sdkRoot = sdkRoot
        self.minApiTable = minApiTable
        self.didLoadMinApi = minApiTable != nil
        self.actions = actions
    }

    /// Rebuilds the device list from the app model. The SDK scan is lazy:
    /// sdkmanager's first run starts a JVM, so it happens when the user
    /// opens a Pixel detail screen, not on every sidebar refresh.
    func refresh(from model: AppModel) async {
        await loadMinApiIfNeeded(from: model)
        devices = PixelCatalog.devices(
            skins: model.catalog.skinCatalog,
            installedAvdNames: model.catalog.avds,
            avdDevices: model.catalog.avdDevices,
            minApiTable: minApiTable
        )
    }

    /// Loads the installed/downloadable system images. Runs when a Pixel
    /// detail screen appears.
    func loadImages() async {
        await sdk.refresh()
    }

    /// Loads the `avdmanager` device profiles when they have not been loaded
    /// yet (they start a JVM, so the create sheet and this screen load them
    /// lazily), then rebuilds the list so `deviceProfileID` is populated.
    func ensureProfiles(from model: AppModel) async {
        guard model.catalog.avdDevices.isEmpty else { return }
        await model.catalog.refreshAvdCreateOptions()
        await refresh(from: model)
    }

    /// The table is the app model's shared one (the create sheet reads the
    /// same), so the jars are parsed once; a model built with its own
    /// `sdkRoot` (tests) still loads from that.
    private func loadMinApiIfNeeded(from model: AppModel) async {
        guard !didLoadMinApi, let sdkRoot else { return }
        didLoadMinApi = true
        if sdkRoot != AvdmanagerClient.sdkRoot() {
            minApiTable = await PixelMinApiTable.load(sdkRoot: sdkRoot)
        } else {
            minApiTable = await model.catalog.ensureMinApiTable()
        }
        // Nothing found (the SDK or its jars are not there yet): ask again on
        // the next refresh instead of keeping the empty answer for good.
        if minApiTable == nil { didLoadMinApi = false }
    }

    // MARK: - Device queries

    func device(forSkin skinName: String) -> PixelDevice? {
        devices.first(where: { $0.skinName == skinName })
    }

    func candidates(for device: PixelDevice) -> [PixelImageCandidate] {
        PixelImageSuggestion.candidates(
            device: device,
            installed: sdk.installedImages,
            available: sdk.availableImages,
            hostAbi: Self.hostAbi
        )
    }

    func preferredCandidate(for device: PixelDevice) -> PixelImageCandidate? {
        PixelImageSuggestion.preferred(in: candidates(for: device))
    }

    /// The prerequisites still missing for this device. The Java probe is
    /// async and runs in the detail view; here Java counts as present unless
    /// the caller passes a known answer.
    func readiness(for device: PixelDevice, hasJava: Bool = true) -> [PixelDependency] {
        PixelReadiness.missing(
            hasAdb: AdbClient.locate() != nil,
            hasEmulator: EmulatorManager.locateBinary() != nil,
            hasCommandLineTools: AvdmanagerClient.locate() != nil,
            hasJava: hasJava,
            hasUsableImage: candidates(for: device)
                .contains(where: { $0.isInstalled && $0.meetsMinimum })
        )
    }

    /// The ABI of system images this Mac's emulator can run.
    static var hostAbi: String {
        #if arch(arm64)
        "arm64-v8a"
        #else
        "x86_64"
        #endif
    }

    // MARK: - Provisioning

    var licensePrompt: SDKLicensePrompt? { sdk.licensePrompt }

    func downloadState(for candidate: PixelImageCandidate) -> DownloadState {
        sdk.downloadState(package: candidate.image.package)
    }

    func acceptLicense() { sdk.acceptLicense() }
    func declineLicense() { sdk.declineLicense() }
    func cancelDownload() { sdk.cancelDownload() }

    /// `skinName`'s provisioning state: another device's run reads as idle,
    /// so its progress or failure never shows on this page.
    func provisioningState(forSkin skinName: String) -> ProvisioningState {
        provisioningSkin == skinName ? provisioningState : .idle
    }

    /// Whether a provisioning run is starting, downloading or creating.
    var isProvisioning: Bool { provisioningState.isRunning }

    /// Whether "Create & Start" / "Download & Create & Start" can run for
    /// `candidate` with `missing` prerequisites. A missing system image does
    /// not block: downloading one is exactly what the button does, and the
    /// readiness report lists it whenever no *installed* image qualifies.
    /// Only a candidate that needs a download waits for the app-wide install
    /// slot (`canStartDownload`); an installed one runs no sdkmanager.
    static func canProvision(
        candidate: PixelImageCandidate?,
        missing: [PixelDependency],
        canStartDownload: Bool
    ) -> Bool {
        guard let candidate, candidate.meetsMinimum else { return false }
        if !candidate.isInstalled, !canStartDownload { return false }
        return missing.allSatisfy { $0 == .systemImage }
    }

    /// `canProvision(candidate:missing:canStartDownload:)` for `device`,
    /// false while a provisioning run is going.
    func canProvision(
        device: PixelDevice,
        candidate: PixelImageCandidate?,
        hasJava: Bool
    ) -> Bool {
        guard !isProvisioning else { return false }
        return Self.canProvision(
            candidate: candidate,
            missing: readiness(for: device, hasJava: hasJava),
            canStartDownload: sdk.canStartDownload
        )
    }

    /// Downloads the image when needed, creates the AVD and starts it. One
    /// run at a time: a start while a run is going is ignored (a double
    /// click must not run two creates of the same name, nor two downloads).
    /// The run is marked busy here, before its task runs, so a second start
    /// in the meantime cannot supersede it. The outcome lands in
    /// `provisioningState`.
    func startProvisioning(
        device: PixelDevice,
        candidate: PixelImageCandidate,
        model: AppModel,
        workspace: DeviceWorkspace? = nil
    ) {
        guard !isProvisioning else { return }
        provisioningRun &+= 1
        let run = provisioningRun
        provisioningSkin = device.skinName
        provisioningState = .starting
        provisioningTask = Task { [weak self] in
            guard let self,
                  let name = await self.prepareAvd(
                      device: device,
                      candidate: candidate,
                      model: model,
                      run: run
                  )
            else { return }
            // From here on the run is over: the AVD exists, and starting it
            // is the app model's job. `cancelProvisioning` — the page going
            // away because the start selects the new AVD — must not reach it.
            if self.provisioningRun == run { self.provisioningTask = nil }
            await self.actions.start(model, name, workspace)
        }
    }

    /// Abandons the running provisioning (the page left its device): a
    /// download is cancelled; a create already running finishes — killing
    /// avdmanager half-way would leave a broken AVD — but the AVD is not
    /// started. A failed run's message is dropped too. The start itself,
    /// once handed over, is never cancelled.
    func cancelProvisioning() {
        provisioningRun &+= 1
        provisioningTask?.cancel()
        provisioningTask = nil
        if case .downloading = provisioningState {
            sdk.cancelDownload()
        }
        provisioningState = .idle
        provisioningSkin = nil
    }

    /// Download and create; returns the new AVD's name, or nil when the run
    /// failed (see `provisioningState`) or was cancelled.
    private func prepareAvd(
        device: PixelDevice,
        candidate: PixelImageCandidate,
        model: AppModel,
        run: UInt64
    ) async -> String? {
        // Cancelled before the task first ran: start nothing.
        guard !Task.isCancelled, provisioningRun == run else { return nil }
        let package = candidate.image.package
        if !candidate.isInstalled {
            setProvisioningState(.downloading(package: package), run: run)
            switch await actions.download(sdk, package) {
            case .installed:
                break
            case .cancelled:
                setProvisioningState(.idle, run: run)
                return nil
            case .failed(let message):
                setProvisioningState(.failed(message), run: run)
                return nil
            }
        }
        guard !Task.isCancelled, provisioningRun == run else { return nil }
        guard let profileID = device.deviceProfileID else {
            setProvisioningState(
                .failed("No avdmanager hardware profile matches \(device.displayName)."),
                run: run
            )
            return nil
        }
        // The AVD home, not only the model's possibly stale list: an AVD
        // created elsewhere since the last refresh must not be reused.
        let name = PixelCatalog.avdName(
            for: device,
            image: candidate.image,
            existing: model.catalog.existingAvdNames()
        )
        setProvisioningState(.creating(name: name), run: run)
        // An unstructured task, so cancelling the run does not reach (and
        // kill) avdmanager; a cancel only skips the start below.
        let actions = actions
        let failure = await Task {
            await actions.createAvd(model, name, profileID, package)
        }.value
        if let failure {
            setProvisioningState(.failed(failure), run: run)
            return nil
        }
        guard !Task.isCancelled, provisioningRun == run else { return nil }
        setProvisioningState(.idle, run: run)
        return name
    }

    private func setProvisioningState(_ state: ProvisioningState, run: UInt64) {
        guard provisioningRun == run else { return }
        provisioningState = state
    }
}
