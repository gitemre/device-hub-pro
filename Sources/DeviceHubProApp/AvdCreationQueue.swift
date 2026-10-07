import Foundation
import Observation
import DeviceHubProKit

/// What an emulator creation needs: the AVD to make and the system image it
/// runs, downloaded first when it is not installed.
struct AvdCreationRequest: Equatable {
    /// The AVD name, validated by the sheet.
    let name: String
    /// What the user sees when the name is the model's placeholder.
    let displayName: String?
    /// The avdmanager hardware profile id.
    let deviceID: String
    /// The profile's display name ("Pixel 10 Pro"), for the placeholder row.
    let deviceName: String
    let image: SystemImage
    /// Start (and mirror) the AVD once created: the Pixel page's
    /// "Create & Start".
    var startAfter = false
    /// The window to show the new AVD in once it exists, when its selection
    /// has not moved since the request (the create sheet's).
    var reveal: CreatedAvdReveal?
}

/// Selects a newly created AVD in the window that asked for it, unless the
/// user picked something else while it downloaded and was created: a new
/// emulator was left unselected at the bottom of a long sidebar.
@MainActor
final class CreatedAvdReveal: Equatable {
    private weak var workspace: DeviceWorkspace?
    private let selectionAtRequest: DeviceSelection?

    init(workspace: DeviceWorkspace) {
        self.workspace = workspace
        self.selectionAtRequest = workspace.deviceSelection
    }

    func reveal(_ avdName: String) {
        guard let workspace, workspace.deviceSelection == selectionAtRequest else { return }
        workspace.deviceSelection = .avd(avdName)
    }

    nonisolated static func == (lhs: CreatedAvdReveal, rhs: CreatedAvdReveal) -> Bool { lhs === rhs }
}

/// One emulator being made in the background: queued, downloading its
/// system image, waiting to create, creating, or failed.
struct AvdCreationJob: Identifiable, Equatable {
    enum Phase: Equatable {
        /// Needs a download and waits for the app-wide sdkmanager slot.
        case waiting
        case downloading
        /// The image is installed; waits for the one avdmanager create.
        case waitingToCreate
        case creating
        case failed(String)
    }

    let id: UUID
    let request: AvdCreationRequest
    var phase: Phase
}

/// The emulators being created in the background, app-wide. A create from
/// the sheet or the Pixel page hands its request here and returns at once,
/// so a multi-gigabyte system image download never holds a window: the
/// sidebar and the toolbar's activity popover show every job's progress,
/// and the rest of the app keeps working.
///
/// Downloads run through the one `SDKComponentModel` (and so the app-wide
/// `SDKInstallSlot`): one at a time, the next shown as "Waiting". Creates
/// run one at a time too (avdmanager and the AVD list). Jobs run in the
/// order they were added.
@MainActor
@Observable
final class AvdCreationQueue {
    /// The steps a job runs; the tests replace them.
    struct Actions {
        var download: @MainActor (SDKComponentModel, _ package: String) async -> DownloadOutcome
        /// Returns the failure message, nil when the AVD was created.
        var createAvd: @MainActor (AvdCreationRequest) async -> String?
        var start: @MainActor (_ avdName: String) async -> Void
        /// Whether a create started elsewhere (the Pixel page) is running.
        var isCreatingElsewhere: @MainActor () -> Bool

        /// Downloads for real; `AppModel` connects the create and the start.
        static var inert: Actions {
            Actions(
                download: { sdk, package in await sdk.startDownload(package: package) },
                createAvd: { _ in "Creating emulators is not available." },
                start: { _ in },
                isCreatingElsewhere: { false }
            )
        }
    }

    private(set) var jobs: [AvdCreationJob] = []
    /// Bumped each time a job finishes its AVD, for views that reload.
    private(set) var completedCount = 0
    /// The SDK model every background download (and the "Download More
    /// System Images…" sheet) goes through; it outlives the sheets.
    let sdk: SDKComponentModel
    var actions: Actions

    @ObservationIgnored private var retryScheduled = false
    @ObservationIgnored private let retryDelay: Duration

    init(
        sdk: SDKComponentModel = SDKComponentModel(),
        actions: Actions = .inert,
        retryDelay: Duration = .seconds(1)
    ) {
        self.sdk = sdk
        self.actions = actions
        self.retryDelay = retryDelay
    }

    // MARK: - Queries

    /// Names the queued AVDs will take, which a new AVD must not reuse.
    var reservedNames: [String] { jobs.map(\.request.name) }

    func job(forAvdNamed name: String) -> AvdCreationJob? {
        jobs.first { $0.request.name.lowercased() == name.lowercased() }
    }

    /// The package a direct download (the "Download More System Images…"
    /// sheet), not one of the jobs, is fetching.
    var directDownloadPackage: String? {
        guard let package = sdk.activeDownloadPackage,
              !jobs.contains(where: { $0.phase == .downloading && $0.request.image.package == package })
        else { return nil }
        return package
    }

    /// Whether the activity popover has anything to show.
    var hasActivity: Bool { !jobs.isEmpty || sdk.activeDownloadPackage != nil }

    /// The download progress of a job, 0...1; nil while unknown.
    func progress(of job: AvdCreationJob) -> Double? {
        guard job.phase == .downloading,
              case .downloading(let progress) = sdk.downloadState(package: job.request.image.package)
        else { return nil }
        return progress
    }

    // MARK: - Commands

    /// Queues the create and returns at once; false (nothing queued) when
    /// a queued job already takes the AVD's name.
    @discardableResult
    func enqueue(_ request: AvdCreationRequest) -> Bool {
        guard job(forAvdNamed: request.name) == nil else { return false }
        let needsDownload = !sdk.isInstalled(request.image.package)
        jobs.append(AvdCreationJob(
            id: UUID(),
            request: request,
            phase: needsDownload ? .waiting : .waitingToCreate
        ))
        pump()
        return true
    }

    /// Removes a job that has not started creating: a queued one is
    /// dropped, a download is cancelled, a failed one is dismissed. A create
    /// already running finishes — killing avdmanager half-way would leave a
    /// broken AVD.
    func cancel(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        switch job.phase {
        case .creating:
            return
        case .downloading:
            remove(id)
            sdk.cancelDownload()
        case .waiting, .waitingToCreate, .failed:
            remove(id)
        }
    }

    /// Runs a failed job again.
    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              case .failed = jobs[index].phase
        else { return }
        jobs[index].phase = sdk.isInstalled(jobs[index].request.image.package)
            ? .waitingToCreate
            : .waiting
        pump()
    }

    // MARK: - Running

    /// Starts whatever can start now. Called after every change; a job
    /// blocked by something this queue does not own (another sdkmanager
    /// install, a create from the Pixel page) is looked at again shortly.
    func pump() {
        var blocked = false
        if !jobs.contains(where: { $0.phase == .downloading }),
           let job = jobs.first(where: { $0.phase == .waiting }) {
            if sdk.canStartDownload {
                startDownload(job)
            } else {
                blocked = true
            }
        }
        if !jobs.contains(where: { $0.phase == .creating }),
           let job = jobs.first(where: { $0.phase == .waitingToCreate }) {
            if actions.isCreatingElsewhere() {
                blocked = true
            } else {
                startCreate(job)
            }
        }
        if blocked { scheduleRetry() }
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        let delay = retryDelay
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.retryScheduled = false
            self.pump()
        }
    }

    private func startDownload(_ job: AvdCreationJob) {
        setPhase(.downloading, of: job.id)
        let package = job.request.image.package
        Task { [weak self] in
            guard let self else { return }
            // An earlier job (or the download sheet) may have fetched it.
            await self.sdk.rescanInstalled()
            let outcome: DownloadOutcome = self.sdk.isInstalled(package)
                ? .installed
                : await self.actions.download(self.sdk, package)
            switch outcome {
            case .installed:
                self.setPhase(.waitingToCreate, of: job.id)
            case .cancelled:
                self.remove(job.id)
            case .failed(let message):
                if message == SDKComponentModel.busyMessage {
                    // Another install took the slot in between: wait.
                    self.setPhase(.waiting, of: job.id)
                } else {
                    self.setPhase(.failed(message), of: job.id)
                }
            }
            self.pump()
        }
    }

    private func startCreate(_ job: AvdCreationJob) {
        setPhase(.creating, of: job.id)
        Task { [weak self] in
            guard let self else { return }
            let failure = await self.actions.createAvd(job.request)
            if let failure {
                self.setPhase(.failed(failure), of: job.id)
                self.pump()
                return
            }
            self.remove(job.id)
            self.completedCount += 1
            self.pump()
            job.request.reveal?.reveal(job.request.name)
            if job.request.startAfter {
                await self.actions.start(job.request.name)
            }
        }
    }

    private func setPhase(_ phase: AvdCreationJob.Phase, of id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].phase = phase
    }

    private func remove(_ id: UUID) {
        jobs.removeAll { $0.id == id }
    }
}
