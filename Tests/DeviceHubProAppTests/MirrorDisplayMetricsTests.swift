import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// The display density the mirror's input reads from the device (`wm size`,
/// `wm density`): parsing, fitting it to the streamed frame, and reading it
/// once per session even while the views' requests are superseded.
@MainActor
final class MirrorDisplayMetricsTests: XCTestCase {
    private let phone = MirrorDisplayMetrics(width: 1080, height: 2400, dpi: 420)

    // MARK: - Parsing

    func testParsesSizeAndDensityFromOneShell() {
        let metrics = MirrorDisplayMetrics(wmOutput: "Physical size: 2560x1600\nPhysical density: 320\n")
        XCTAssertEqual(metrics, MirrorDisplayMetrics(width: 2560, height: 1600, dpi: 320))
    }

    func testOverridesWinAsThatIsWhatAppsSee() {
        let metrics = MirrorDisplayMetrics(wmOutput: """
        Physical size: 1080x2400
        Override size: 720x1600
        Physical density: 420
        Override density: 280
        """)
        XCTAssertEqual(metrics, MirrorDisplayMetrics(width: 720, height: 1600, dpi: 280))
    }

    func testAMissingDensityIsNoMetrics() {
        XCTAssertNil(MirrorDisplayMetrics(wmOutput: "Physical size: 1080x2400\n"))
        XCTAssertNil(MirrorDisplayMetrics(wmOutput: "Physical density: 420\n"))
        XCTAssertNil(MirrorDisplayMetrics(wmOutput: "error: device offline\n"))
    }

    // MARK: - Fitting the frame

    func testPixelsPerDpFollowsTheStreamScaleAndOrientation() throws {
        let tablet = MirrorDisplayMetrics(width: 2560, height: 1600, dpi: 320)
        XCTAssertEqual(try XCTUnwrap(tablet.pixelsPerDp(frame: CGSize(width: 2560, height: 1600))), 2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(tablet.pixelsPerDp(frame: CGSize(width: 1600, height: 2560))), 2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(tablet.pixelsPerDp(frame: CGSize(width: 1280, height: 800))), 1, accuracy: 1e-9)

        let wear = MirrorDisplayMetrics(width: 384, height: 384, dpi: 320)
        XCTAssertEqual(try XCTUnwrap(wear.pixelsPerDp(frame: CGSize(width: 384, height: 384))), 2, accuracy: 1e-9)
    }

    func testAScrcpyDownscaleRoundedToMultiplesOf8StillFits() throws {
        // 1080x2400 with --max-size 1024: 460.8 rounds to 464.
        let density = try XCTUnwrap(phone.pixelsPerDp(frame: CGSize(width: 464, height: 1024)))
        XCTAssertEqual(density, 464.0 / 1080 * 420 / 160, accuracy: 1e-9)
    }

    func testAnotherScreenShapeIsNotEstimatedFromTheseMetrics() {
        // A Fold's outer display metrics while the inner display streams.
        let outer = MirrorDisplayMetrics(width: 1080, height: 2092, dpi: 420)
        XCTAssertNil(outer.pixelsPerDp(frame: CGSize(width: 2208, height: 1840)))
    }

    // MARK: - Reading once per session

    func testASupersededRequestLeavesItsReadToTheNextOne() async throws {
        let state = MirrorViewState()
        let reader = FakeMetricsReader(results: [phone])
        let read: @Sendable () async -> MirrorDisplayMetrics? = { await reader.read() }

        // The view appears before the first frame settles.
        let first = Task { await state.loadDisplayMetrics(reading: read) }
        try await waitUntil { await reader.pending == 1 }

        // The first frame settles: SwiftUI cancels the view's task and starts
        // another for the new stream size, which joins the read in flight.
        first.cancel()
        state.devicePixelSize = CGSize(width: 1080, height: 2400)
        let second = Task { await state.loadDisplayMetrics(reading: read) }
        await Task.yield()
        await reader.releaseAll()
        await first.value
        await second.value

        XCTAssertEqual(state.displayMetrics, phone, "cancelling the first request must not drop the read")
        let reads = await reader.reads
        XCTAssertEqual(reads, 1)
    }

    func testTwoViewsOfOneSessionReadOnce() async throws {
        let state = MirrorViewState()
        state.devicePixelSize = CGSize(width: 1080, height: 2400)
        let reader = FakeMetricsReader(results: [phone])
        let read: @Sendable () async -> MirrorDisplayMetrics? = { await reader.read() }

        let stage = Task { await state.loadDisplayMetrics(reading: read) }
        let compact = Task { await state.loadDisplayMetrics(reading: read) }
        try await waitUntil { await reader.pending == 1 }
        await reader.releaseAll()
        await stage.value
        await compact.value

        let reads = await reader.reads
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(state.displayMetrics, phone)
    }

    func testARotationDoesNotReadAgain() async {
        let state = MirrorViewState()
        state.devicePixelSize = CGSize(width: 1080, height: 2400)
        let reader = FakeMetricsReader(results: [phone], gated: false)
        let read: @Sendable () async -> MirrorDisplayMetrics? = { await reader.read() }
        await state.loadDisplayMetrics(reading: read)

        state.devicePixelSize = CGSize(width: 2400, height: 1080)
        await state.loadDisplayMetrics(reading: read)

        let reads = await reader.reads
        XCTAssertEqual(reads, 1)
    }

    func testAFoldableSwitchingScreensReadsAgain() async {
        let outer = MirrorDisplayMetrics(width: 1080, height: 2092, dpi: 420)
        let inner = MirrorDisplayMetrics(width: 2208, height: 1840, dpi: 420)
        let state = MirrorViewState()
        state.devicePixelSize = CGSize(width: 1080, height: 2092)
        let reader = FakeMetricsReader(results: [outer, inner], gated: false)
        let read: @Sendable () async -> MirrorDisplayMetrics? = { await reader.read() }
        await state.loadDisplayMetrics(reading: read)
        XCTAssertEqual(state.displayMetrics, outer)

        state.devicePixelSize = CGSize(width: 2208, height: 1840)
        await state.loadDisplayMetrics(reading: read)
        XCTAssertEqual(state.displayMetrics, inner)
    }

    func testMetricsThatNeverFitAreNotReadAgainForTheSameStream() async {
        let state = MirrorViewState()
        state.devicePixelSize = CGSize(width: 1000, height: 1000)
        let reader = FakeMetricsReader(results: [phone, phone, phone], gated: false)
        let read: @Sendable () async -> MirrorDisplayMetrics? = { await reader.read() }

        await state.loadDisplayMetrics(reading: read)
        await state.loadDisplayMetrics(reading: read)

        let reads = await reader.reads
        XCTAssertEqual(reads, 1, "the same answer would come back")
    }

    func testAFailedReadIsRetriedByTheNextRequest() async {
        let state = MirrorViewState()
        state.devicePixelSize = CGSize(width: 1080, height: 2400)
        let reader = FakeMetricsReader(results: [nil, phone], gated: false)
        let read: @Sendable () async -> MirrorDisplayMetrics? = { await reader.read() }

        await state.loadDisplayMetrics(reading: read)
        XCTAssertNil(state.displayMetrics)
        await state.loadDisplayMetrics(reading: read)
        XCTAssertEqual(state.displayMetrics, phone)
    }

    // MARK: - adb

    func testReadsBothValuesWithOneAdbShell() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirrorDisplayMetricsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("calls.log")
        let adbURL = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(logURL.path)"
        printf 'Physical size: 2560x1600\\nPhysical density: 320\\n'
        """
        try Data(script.utf8).write(to: adbURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adbURL.path)

        let metrics = await MirrorController.readDisplayMetrics(adb: AdbClient(adbURL: adbURL), serial: "emulator-5554")

        XCTAssertEqual(metrics, MirrorDisplayMetrics(width: 2560, height: 1600, dpi: 320))
        let calls = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(calls, ["-s emulator-5554 shell wm size; wm density"])
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition not met within \(timeout) s")
    }
}

/// Answers display-metrics reads in order. A gated read waits for
/// `releaseAll()`, and a read whose task was cancelled meanwhile returns
/// nothing, as the adb read does.
private actor FakeMetricsReader {
    private var results: [MirrorDisplayMetrics?]
    private let gated: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var reads = 0

    init(results: [MirrorDisplayMetrics?], gated: Bool = true) {
        self.results = results
        self.gated = gated
    }

    var pending: Int { waiting.count }

    func read() async -> MirrorDisplayMetrics? {
        reads += 1
        let result = results.isEmpty ? nil : results.removeFirst()
        if gated {
            await withCheckedContinuation { waiting.append($0) }
        }
        return Task.isCancelled ? nil : result
    }

    func releaseAll() {
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}
