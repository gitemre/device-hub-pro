import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// The background creation queue: a request returns at once (the sheet
/// closes early), downloads wait for the one sdkmanager slot, creates run
/// one at a time, and failures stay as rows with Retry.
@MainActor
final class AvdCreationQueueTests: XCTestCase {
    private let image35 = SystemImage(
        package: "system-images;android-35;google_apis_playstore;arm64-v8a",
        api: "android-35", tag: "google_apis_playstore", abi: "arm64-v8a"
    )
    private let image36 = SystemImage(
        package: "system-images;android-36;google_apis_playstore;arm64-v8a",
        api: "android-36", tag: "google_apis_playstore", abi: "arm64-v8a"
    )

    private func request(_ name: String, image: SystemImage, startAfter: Bool = false) -> AvdCreationRequest {
        AvdCreationRequest(
            name: name, displayName: nil, deviceID: "pixel_9",
            deviceName: "Pixel 9", image: image, startAfter: startAfter
        )
    }

    private func makeQueue(
        slot: SDKInstallSlot = SDKInstallSlot(),
        fake: FakeJobSteps
    ) -> AvdCreationQueue {
        AvdCreationQueue(
            sdk: SDKComponentModel(locateClient: { nil }, locateSdkRoot: { nil }, installSlot: slot),
            actions: fake.actions,
            retryDelay: .milliseconds(10)
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

    func testEnqueueReturnsAtOnceWhileTheDownloadRuns() async throws {
        let fake = FakeJobSteps()
        fake.holdDownloads = true
        let queue = makeQueue(fake: fake)

        // Synchronous: the sheet dismisses right after this returns.
        XCTAssertTrue(queue.enqueue(request("A", image: image35)))
        XCTAssertEqual(queue.jobs.count, 1)

        try await waitUntil("the download starts") { queue.jobs.first?.phase == .downloading }
        XCTAssertTrue(queue.hasActivity)
        XCTAssertTrue(fake.createCalls.isEmpty, "no create before the image is installed")

        fake.holdDownloads = false
        try await waitUntil("the AVD is created") { queue.jobs.isEmpty }
        XCTAssertEqual(fake.createCalls, ["A"])
        XCTAssertEqual(queue.completedCount, 1)
    }

    /// The window that asked shows the new emulator once it exists, unless
    /// its selection moved meanwhile (the user went on to something else).
    func testACreatedAvdIsSelectedOnlyWhereTheSelectionDidNotMove() async throws {
        let model = AppModel.testing()
        let asked = model.workspace
        asked.deviceSelection = .avd("Pixel_10_Pro")
        let moved = DeviceWorkspace(services: model.services)
        moved.deviceSelection = .avd("Pixel_10_Pro")

        let fake = FakeJobSteps()
        let queue = makeQueue(fake: fake)
        var first = request("Wear", image: image35)
        first.reveal = CreatedAvdReveal(workspace: asked)
        var second = request("TV", image: image35)
        second.reveal = CreatedAvdReveal(workspace: moved)
        moved.deviceSelection = .simulator("SIM")
        XCTAssertTrue(queue.enqueue(first))
        XCTAssertTrue(queue.enqueue(second))

        try await waitUntil("both AVDs are created") { queue.jobs.isEmpty && fake.createCalls.count == 2 }
        XCTAssertEqual(asked.deviceSelection, .avd("Wear"))
        XCTAssertEqual(moved.deviceSelection, .simulator("SIM"), "a selection the user moved is left alone")
    }

    func testSecondDownloadWaitsForTheSlotThenRuns() async throws {
        let fake = FakeJobSteps()
        fake.holdDownloads = true
        let queue = makeQueue(fake: fake)

        queue.enqueue(request("A", image: image35))
        queue.enqueue(request("B", image: image36))
        try await waitUntil("the first download starts") { !fake.downloadedPackages.isEmpty }
        XCTAssertEqual(queue.jobs.last?.phase, .waiting, "one sdkmanager install runs at a time")
        XCTAssertEqual(fake.downloadedPackages, [image35.package])

        fake.holdDownloads = false
        try await waitUntil("both are created") { queue.jobs.isEmpty }
        XCTAssertEqual(fake.downloadedPackages, [image35.package, image36.package])
        XCTAssertEqual(fake.createCalls, ["A", "B"])
    }

    func testDownloadWaitsWhileAnotherModelHoldsTheInstallSlot() async throws {
        let slot = SDKInstallSlot()
        XCTAssertTrue(slot.claim("system-images;android-33;google_apis;arm64-v8a"))
        let fake = FakeJobSteps()
        let queue = makeQueue(slot: slot, fake: fake)

        queue.enqueue(request("A", image: image35))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(queue.jobs.first?.phase, .waiting)
        XCTAssertTrue(fake.downloadedPackages.isEmpty)

        slot.release("system-images;android-33;google_apis;arm64-v8a")
        try await waitUntil("the waiting job runs once the slot frees") { queue.jobs.isEmpty }
        XCTAssertEqual(fake.createCalls, ["A"])
    }

    func testFailedDownloadStaysAsARowAndRetryRunsItAgain() async throws {
        let fake = FakeJobSteps()
        fake.downloadFailure = "offline"
        let queue = makeQueue(fake: fake)

        queue.enqueue(request("A", image: image35))
        try await waitUntil("the failure shows") { queue.jobs.first?.phase == .failed("offline") }
        XCTAssertTrue(fake.createCalls.isEmpty)

        fake.downloadFailure = nil
        queue.retry(queue.jobs[0].id)
        try await waitUntil("the retry finishes") { queue.jobs.isEmpty }
        XCTAssertEqual(fake.createCalls, ["A"])
    }

    func testCancelledDownloadDropsTheJob() async throws {
        let fake = FakeJobSteps()
        fake.holdDownloads = true
        let queue = makeQueue(fake: fake)

        queue.enqueue(request("A", image: image35))
        try await waitUntil("the download starts") { queue.jobs.first?.phase == .downloading }
        fake.cancelOnRelease = true
        queue.cancel(queue.jobs[0].id)
        XCTAssertTrue(queue.jobs.isEmpty)
        fake.holdDownloads = false
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(fake.createCalls.isEmpty, "a cancelled download creates nothing")
    }

    func testWaitingJobCanBeCancelledAndFailedJobDismissed() async throws {
        let fake = FakeJobSteps()
        fake.holdDownloads = true
        let queue = makeQueue(fake: fake)
        queue.enqueue(request("A", image: image35))
        queue.enqueue(request("B", image: image36))
        try await waitUntil("A downloads") { queue.jobs.first?.phase == .downloading }

        queue.cancel(queue.jobs[1].id)
        XCTAssertEqual(queue.jobs.map(\.request.name), ["A"])
        fake.holdDownloads = false
        try await waitUntil("A is created") { queue.jobs.isEmpty }
    }

    func testCreateFailureShowsOnTheRow() async throws {
        let fake = FakeJobSteps()
        fake.createFailure = "avdmanager said no"
        let queue = makeQueue(fake: fake)

        queue.enqueue(request("A", image: image35))
        try await waitUntil("the create failure shows") {
            queue.jobs.first?.phase == .failed("avdmanager said no")
        }
        XCTAssertEqual(queue.completedCount, 0)
    }

    func testDuplicateNameIsRefusedAndReserved() {
        let fake = FakeJobSteps()
        fake.holdDownloads = true
        let queue = makeQueue(fake: fake)

        XCTAssertTrue(queue.enqueue(request("Pixel_9", image: image35)))
        XCTAssertFalse(queue.enqueue(request("pixel_9", image: image36)))
        XCTAssertEqual(queue.reservedNames, ["Pixel_9"])
        fake.holdDownloads = false
    }

    func testCreatesRunOneAtATimeAndStartAfterRunsLast() async throws {
        let fake = FakeJobSteps()
        fake.holdCreate = true
        let queue = makeQueue(fake: fake)
        // Both images "installed" is not modelled here: the fake download
        // installs instantly, then both wait for the single create.
        queue.enqueue(request("A", image: image35, startAfter: true))
        queue.enqueue(request("B", image: image36))
        try await waitUntil("A is creating") { queue.jobs.first?.phase == .creating }
        XCTAssertEqual(fake.createCalls, ["A"])
        XCTAssertNotEqual(queue.jobs.last?.phase, .creating)

        fake.holdCreate = false
        try await waitUntil("both are created") { queue.jobs.isEmpty }
        XCTAssertEqual(fake.createCalls, ["A", "B"])
        try await waitUntil("A is started") { fake.startCalls == ["A"] }
    }

    func testCreateWaitsForACreateRunningElsewhere() async throws {
        let fake = FakeJobSteps()
        fake.creatingElsewhere = true
        let queue = makeQueue(fake: fake)

        queue.enqueue(request("A", image: image35))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(queue.jobs.first?.phase, .waitingToCreate)
        XCTAssertTrue(fake.createCalls.isEmpty)

        fake.creatingElsewhere = false
        try await waitUntil("the create runs") { queue.jobs.isEmpty }
        XCTAssertEqual(fake.createCalls, ["A"])
    }

    func testStatusText() {
        let job = AvdCreationJob(id: UUID(), request: request("A", image: image35), phase: .downloading)
        XCTAssertEqual(
            job.statusText(progress: 0.34, licensePending: false),
            "Downloading \(image35.friendlyLabel)\u{2026} 34%"
        )
        XCTAssertEqual(job.statusText(progress: nil, licensePending: true), "Waiting for the license\u{2026}")
        var waiting = job
        waiting.phase = .waiting
        XCTAssertEqual(waiting.statusText(progress: nil, licensePending: false), "Waiting for another download\u{2026}")
        waiting.phase = .failed("boom")
        XCTAssertEqual(waiting.statusText(progress: nil, licensePending: false), "boom")
    }
}

/// Fake download/create/start steps, holdable to observe the state between.
@MainActor
private final class FakeJobSteps {
    var holdDownloads = false
    var cancelOnRelease = false
    var downloadFailure: String?
    var downloadedPackages: [String] = []
    var holdCreate = false
    var createFailure: String?
    var createCalls: [String] = []
    var startCalls: [String] = []
    var creatingElsewhere = false

    var actions: AvdCreationQueue.Actions {
        AvdCreationQueue.Actions(
            download: { _, package in
                self.downloadedPackages.append(package)
                while self.holdDownloads { try? await Task.sleep(for: .milliseconds(5)) }
                if self.cancelOnRelease { return .cancelled }
                if let failure = self.downloadFailure { return .failed(failure) }
                return .installed
            },
            createAvd: { request in
                self.createCalls.append(request.name)
                while self.holdCreate { try? await Task.sleep(for: .milliseconds(5)) }
                return self.createFailure
            },
            start: { name in self.startCalls.append(name) },
            isCreatingElsewhere: { self.creatingElsewhere }
        )
    }
}
