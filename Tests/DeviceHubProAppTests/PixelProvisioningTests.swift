import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// Pixel provisioning: the primary button works when no usable image is
/// installed yet (F2), one run at a time (F3), and the run belongs to its
/// device's page (F13). The steps run through fake `Actions`, so no
/// sdkmanager, avdmanager or emulator is involved.
@MainActor
final class PixelProvisioningTests: XCTestCase {
    // MARK: - Button state (F2)

    func testDownloadableImageIsNotBlockedByTheMissingSystemImage() {
        // PixelReadiness reports `.systemImage` whenever no *installed* image
        // qualifies — exactly when "Download & Create & Start" is needed.
        XCTAssertTrue(
            PixelCatalogModel.canProvision(
                candidate: downloadable,
                missing: [.systemImage],
                canStartDownload: true
            )
        )
        XCTAssertTrue(
            PixelCatalogModel.canProvision(candidate: installed, missing: [], canStartDownload: true)
        )
    }

    func testRealMissingToolsStillBlock() {
        XCTAssertFalse(
            PixelCatalogModel.canProvision(
                candidate: downloadable,
                missing: [.systemImage, .java],
                canStartDownload: true
            )
        )
        XCTAssertFalse(
            PixelCatalogModel.canProvision(
                candidate: installed,
                missing: [.commandLineTools],
                canStartDownload: true
            )
        )
    }

    func testImageBelowTheMinimumOrNoImageBlocks() {
        let tooOld = PixelImageCandidate(image: image, isInstalled: true, meetsMinimum: false)
        XCTAssertFalse(
            PixelCatalogModel.canProvision(candidate: tooOld, missing: [], canStartDownload: true)
        )
        XCTAssertFalse(
            PixelCatalogModel.canProvision(candidate: nil, missing: [], canStartDownload: true)
        )
    }

    // MARK: - One run at a time (F3)

    func testSecondStartWhileCreatingIsIgnored() async throws {
        let fake = FakeSteps()
        let catalog = makeCatalog(fake)
        let model = AppModel.testing()

        catalog.startProvisioning(device: device, candidate: installed, model: model)
        try await waitUntil("the create starts") { fake.createCalls.count == 1 }
        XCTAssertTrue(catalog.isProvisioning)
        XCTAssertFalse(catalog.canProvision(device: device, candidate: installed, hasJava: true))

        catalog.startProvisioning(device: device, candidate: installed, model: model)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fake.createCalls.count, 1, "a double click must not run a second create")

        fake.releaseCreate = true
        try await waitUntil("the start") { fake.startCalls.count == 1 }
        XCTAssertEqual(fake.startCalls, fake.createCalls)
        XCTAssertEqual(catalog.provisioningState, .idle)
    }

    func testRunIsBusyBeforeItsTaskFirstRuns() async throws {
        // Two starts in one main-actor turn: the first run's task has not
        // reached its download yet. It used to count as idle, so the second
        // start superseded it while its download still ran — and the second
        // run's own download was then refused as "already running".
        let fake = FakeSteps()
        let catalog = makeCatalog(fake)
        let model = AppModel.testing()

        catalog.startProvisioning(device: device, candidate: downloadable, model: model)
        XCTAssertTrue(catalog.isProvisioning, "busy as soon as the start returns")
        XCTAssertFalse(catalog.canProvision(device: device, candidate: downloadable, hasJava: true))
        catalog.startProvisioning(device: device, candidate: downloadable, model: model)

        try await waitUntil("the download starts") { fake.downloadCalls >= 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fake.downloadCalls, 1, "a second start must not run a second download")
        XCTAssertEqual(
            catalog.provisioningState(forSkin: "pixel_9_pro"),
            .downloading(package: image.package)
        )

        catalog.cancelProvisioning()
        try await waitUntil("the download sees the cancel") { fake.downloadCancelled }
    }

    func testCancelBeforeTheTaskRunsStartsNothing() async throws {
        let fake = FakeSteps()
        let catalog = makeCatalog(fake)

        catalog.startProvisioning(device: device, candidate: downloadable, model: AppModel.testing())
        catalog.cancelProvisioning()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(fake.downloadCalls, 0, "a run abandoned before its first step must not download")
        XCTAssertTrue(fake.createCalls.isEmpty)
        XCTAssertEqual(catalog.provisioningState, .idle)
    }

    // MARK: - The run belongs to its page (F13)

    func testStateShowsOnlyOnItsDevicesPage() async throws {
        let fake = FakeSteps()
        let catalog = makeCatalog(fake)

        catalog.startProvisioning(device: device, candidate: installed, model: AppModel.testing())
        try await waitUntil("the create starts") { fake.createCalls.count == 1 }

        XCTAssertEqual(
            catalog.provisioningState(forSkin: "pixel_9_pro"),
            .creating(name: fake.createCalls[0])
        )
        XCTAssertEqual(catalog.provisioningState(forSkin: "pixel_8"), .idle)
        fake.releaseCreate = true
    }

    func testLeavingThePageDuringCreateLetsItFinishButSkipsTheStart() async throws {
        let fake = FakeSteps()
        let catalog = makeCatalog(fake)

        catalog.startProvisioning(device: device, candidate: installed, model: AppModel.testing())
        try await waitUntil("the create starts") { fake.createCalls.count == 1 }

        catalog.cancelProvisioning()
        XCTAssertEqual(catalog.provisioningState, .idle)
        fake.releaseCreate = true
        try await waitUntil("the create finishes") { fake.createFinished }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(fake.createSawCancellation, "avdmanager must not be killed half-way")
        XCTAssertTrue(fake.startCalls.isEmpty, "the previous device must not start under the new page")
        XCTAssertEqual(catalog.provisioningState, .idle)
    }

    func testLeavingThePageDuringDownloadCancelsIt() async throws {
        let fake = FakeSteps()
        let catalog = makeCatalog(fake)

        catalog.startProvisioning(device: device, candidate: downloadable, model: AppModel.testing())
        try await waitUntil("the download starts") { fake.downloadCalls == 1 }
        XCTAssertEqual(
            catalog.provisioningState(forSkin: "pixel_9_pro"),
            .downloading(package: image.package)
        )

        catalog.cancelProvisioning()
        try await waitUntil("the download sees the cancel") { fake.downloadCancelled }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(fake.createCalls.isEmpty)
        XCTAssertEqual(catalog.provisioningState, .idle)
    }

    func testTheStartIsNotCancelledWhenItsPageGoesAway() async throws {
        // Starting selects the new AVD, which removes the Pixel page and
        // runs its onDisappear cancel; that must not abort the boot.
        let fake = FakeSteps()
        fake.releaseCreate = true
        fake.holdStart = true
        let catalog = makeCatalog(fake)

        catalog.startProvisioning(device: device, candidate: installed, model: AppModel.testing())
        try await waitUntil("the start") { fake.startCalls.count == 1 }
        catalog.cancelProvisioning()
        fake.holdStart = false
        try await waitUntil("the start finishes") { fake.startFinished }

        XCTAssertFalse(fake.startSawCancellation)
    }

    func testFailureIsReportedOnItsPageAndDroppedWhenLeaving() async throws {
        let fake = FakeSteps()
        fake.releaseCreate = true
        fake.createFailure = "avdmanager exploded"
        let catalog = makeCatalog(fake)

        catalog.startProvisioning(device: device, candidate: installed, model: AppModel.testing())
        try await waitUntil("the failure") { catalog.provisioningState == .failed("avdmanager exploded") }

        XCTAssertEqual(catalog.provisioningState(forSkin: "pixel_9_pro"), .failed("avdmanager exploded"))
        XCTAssertEqual(catalog.provisioningState(forSkin: "pixel_8"), .idle)
        XCTAssertTrue(fake.startCalls.isEmpty)

        catalog.cancelProvisioning()
        XCTAssertEqual(catalog.provisioningState(forSkin: "pixel_9_pro"), .idle)
    }

    // MARK: - SDK downloads (F14)

    func testMissingSdkmanagerIsLookedUpAgainOnTheNextDownload() async {
        var lookups = 0
        let sdk = SDKComponentModel(
            locateClient: {
                lookups += 1
                return nil
            },
            locateSdkRoot: { nil },
            installSlot: SDKInstallSlot()
        )

        _ = await sdk.startDownload(package: image.package)
        _ = await sdk.startDownload(package: image.package)

        XCTAssertEqual(lookups, 2, "tools installed after launch must be found without a restart")
    }

    func testAnotherDownloadAnywhereIsRefusedWithoutTouchingTheRunningOne() async {
        let slot = SDKInstallSlot()
        XCTAssertTrue(slot.claim(image.package))
        let sdk = SDKComponentModel(
            locateClient: { nil },
            locateSdkRoot: { nil },
            installSlot: slot
        )
        XCTAssertFalse(sdk.canStartDownload, "another model's install holds the slot")
        XCTAssertFalse(sdk.isDownloading, "this model is not downloading anything")

        let same = await sdk.startDownload(package: image.package)
        XCTAssertEqual(same, .failed("Another download is already running."))
        XCTAssertEqual(
            sdk.downloadState(package: image.package),
            .idle,
            "the running package's state must not be overwritten with a failure"
        )

        let other = await sdk.startDownload(package: "system-images;android-34;google_apis;arm64-v8a")
        XCTAssertEqual(other, .failed("Another download is already running."))
        XCTAssertFalse(slot.claim("anything"), "the refused start must not take the slot")
        slot.release(image.package)
        XCTAssertTrue(sdk.canStartDownload)
    }

    func testAnotherDownloadOnlyBlocksACandidateThatNeedsOne() {
        // Another model's download (the create sheet's) holds the slot:
        // creating from an installed image runs no sdkmanager and must stay
        // possible.
        XCTAssertTrue(
            PixelCatalogModel.canProvision(candidate: installed, missing: [], canStartDownload: false)
        )
        XCTAssertFalse(
            PixelCatalogModel.canProvision(
                candidate: downloadable,
                missing: [.systemImage],
                canStartDownload: false
            )
        )
    }

    func testQueuedDownloadsNeverBlockTheCreateSheet() {
        // Another download holds the slot: the request still queues (it
        // shows as "Waiting"); only a name a queued emulator takes blocks.
        XCTAssertTrue(AvdCreateSheet.canSubmit(takenByQueuedJob: false))
        XCTAssertFalse(AvdCreateSheet.canSubmit(takenByQueuedJob: true))
    }

    // MARK: - Harness

    private let image = SystemImage(
        package: "system-images;android-35;google_apis;arm64-v8a",
        api: "android-35",
        tag: "google_apis",
        abi: "arm64-v8a"
    )

    private var installed: PixelImageCandidate {
        PixelImageCandidate(image: image, isInstalled: true, meetsMinimum: true)
    }

    private var downloadable: PixelImageCandidate {
        PixelImageCandidate(image: image, isInstalled: false, meetsMinimum: true)
    }

    private var device: PixelDevice {
        PixelDevice(
            skinName: "pixel_9_pro",
            displayName: "Pixel 9 Pro",
            category: .phone,
            skin: SkinCatalogEntry(
                name: "pixel_9_pro",
                displayName: "Pixel 9 Pro",
                category: .phone,
                directory: URL(fileURLWithPath: "/tmp"),
                variants: []
            ),
            deviceProfileID: "pixel_9_pro",
            minApi: "35",
            playstoreEnabled: true,
            installedAvdNames: []
        )
    }

    private func makeCatalog(_ fake: FakeSteps) -> PixelCatalogModel {
        PixelCatalogModel(
            sdk: SDKComponentModel(locateClient: { nil }, locateSdkRoot: { nil }, installSlot: SDKInstallSlot()),
            sdkRoot: nil,
            minApiTable: nil,
            actions: fake.actions
        )
    }

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 5,
        until condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("\(what) did not happen within \(timeout) s")
    }
}

/// Records the provisioning steps; the create and the start can be held
/// open to observe the state in between.
@MainActor
private final class FakeSteps {
    var downloadCalls = 0
    var downloadCancelled = false
    var createCalls: [String] = []
    var releaseCreate = false
    var createFailure: String?
    var createFinished = false
    var createSawCancellation = false
    var startCalls: [String] = []
    var holdStart = false
    var startFinished = false
    var startSawCancellation = false

    var actions: PixelCatalogModel.Actions {
        PixelCatalogModel.Actions(
            download: { _, _ in
                self.downloadCalls += 1
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                self.downloadCancelled = true
                return .cancelled
            },
            createAvd: { _, name, _, _ in
                self.createCalls.append(name)
                while !self.releaseCreate {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                self.createSawCancellation = Task.isCancelled
                self.createFinished = true
                return self.createFailure
            },
            start: { _, name, _ in
                self.startCalls.append(name)
                while self.holdStart {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                self.startSawCancellation = Task.isCancelled
                self.startFinished = true
            }
        )
    }
}
