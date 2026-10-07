import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// The Links rows' controller against a stub adb whose arms answer the
/// exact scripts with the API 37 emulator captures
/// (`DeviceHubProKitTests/Fixtures/api37-emulator/links`). Unmatched commands
/// fail, so a test also proves which commands did not run.
@MainActor
final class DeviceLinksControllerTests: XCTestCase {
    private static let serial = "emulator-5554"
    private static let maps = "geo:41.0082,28.9784?q=Istanbul"
    private static let videoLink = "https://video.example.com/watch?v=dQw4w9WgXcQ"

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DeviceHubProKitTests/Fixtures/api37-emulator/links")

    private static func fixture(_ name: String) -> String {
        AdbClient.shellQuoted(fixtures.appendingPathComponent("\(name).txt").path)
    }

    /// A `case` arm matching argv that ends in `-s <serial> shell <script>`.
    private static func arm(_ script: String, _ body: String) -> String {
        "  *" + FakeShell.quoted("-s \(serial) shell " + script) + ")\n    \(body) ;;\n"
    }

    private static func request(_ uri: String, browsable: Bool = true, package: String? = nil) throws -> LinkRequest {
        try LinkRequest(uri, browsable: browsable, package: package, apiLevel: 37)
    }

    private struct Bench {
        let links: DeviceLinksController
        let context: ActiveDeviceContext
        let status: StatusCenter
        let adb: StubAdb
        let defaults: UserDefaults
    }

    private func bench(arms: String, commandTimeout: Duration? = nil) throws -> Bench {
        let adb = try makeStubAdb(arms: arms)
        let client = commandTimeout.map { AdbClient(adbURL: adb.client.adbURL, commandTimeout: $0) } ?? adb.client
        let context = ActiveDeviceContext()
        context.serial = Self.serial
        let status = StatusCenter()
        let defaults = UserDefaults.scratch()
        let links = DeviceLinksController(
            adbClient: client,
            context: context,
            status: status,
            recents: RecentLinkStore(defaults: defaults)
        )
        return Bench(links: links, context: context, status: status, adb: adb, defaults: defaults)
    }

    // MARK: - Open

    func testOpenRecordsTheRecentAndTheReport() async throws {
        let open = try Self.request(Self.maps)
        let bench = try bench(arms: Self.arm(LinkCommands.openScript(open), "cat \(Self.fixture("open-maps-cold"))"))
        bench.links.draft = Self.maps
        let keyBefore = bench.links.previewKey(apiLevel: 37)

        await bench.links.open(apiLevel: 37)

        guard case .result(let result)? = bench.links.lastOpen?.outcome else {
            return XCTFail("\(String(describing: bench.links.lastOpen))")
        }
        XCTAssertEqual(result.launchState, .cold)
        XCTAssertEqual(bench.links.lastOpen?.request, open)
        XCTAssertEqual(bench.links.recents.links, [Self.maps])
        XCTAssertFalse(bench.links.isOpening)
        XCTAssertNotEqual(bench.links.previewKey(apiLevel: 37), keyBefore, "an Open re-runs the preview")
        XCTAssertNil(bench.status.errorMessage)
        XCTAssertEqual(bench.adb.calls.count, 1)
    }

    func testAnAdbFailureRaisesTheErrorAndRecordsNothing() async throws {
        let open = try Self.request(Self.maps)
        let bench = try bench(arms: Self.arm(
            LinkCommands.openScript(open),
            "printf \"error: device 'emulator-5554' not found\\n\" >&2; exit 1"
        ))
        bench.links.draft = Self.maps

        await bench.links.open(apiLevel: 37)

        XCTAssertEqual(bench.links.lastOpen?.outcome, .failed("error: device 'emulator-5554' not found"))
        // The short reason only: adb's argv (the script, the link, the
        // marker) stays out of the alert.
        let message = try XCTUnwrap(bench.status.errorMessage)
        XCTAssertEqual(message, "Could not open the link on emulator-5554: error: device 'emulator-5554' not found")
        XCTAssertFalse(message.contains(Self.maps))
        XCTAssertFalse(message.contains(LinkCommands.marker))
        XCTAssertEqual(bench.links.recents.links, [], "am never ran")
    }

    /// No answer within adb's bound: nothing says the device got the link
    /// (adb may not have reached it) or that am started it, so it is not
    /// recorded and the caption says both.
    func testNoReportWhenAdbsBoundElapses() async throws {
        let open = try Self.request(Self.maps)
        let bench = try bench(
            arms: Self.arm(LinkCommands.openScript(open), "sleep 5"),
            commandTimeout: .seconds(1)
        )
        bench.links.draft = Self.maps

        await bench.links.open(apiLevel: 37)

        XCTAssertEqual(bench.links.lastOpen?.outcome, .noReport(seconds: 1))
        XCTAssertEqual(bench.links.recents.links, [])
        XCTAssertNil(bench.status.errorMessage)
        XCTAssertEqual(
            bench.links.openCaption(apiLevel: 37),
            "No answer within 1 s: either the device could not be reached, or the app is still launching (waiting for a debugger, or stuck before its first frame). Check the device screen."
        )
    }

    /// The report describes the link it opened: another draft shows the
    /// idle caption; the same request again shows it.
    func testTheOpenCaptionFollowsTheDraft() async throws {
        let open = try Self.request(Self.maps)
        let bench = try bench(arms: Self.arm(LinkCommands.openScript(open), "cat \(Self.fixture("open-maps-cold"))"))
        bench.links.draft = Self.maps
        XCTAssertEqual(bench.links.openCaption(apiLevel: 37), LinksRowText.openIdleCaption)

        await bench.links.open(apiLevel: 37)
        let report = "Opened com.example.maps/com.example.maps.MapsActivity · cold start · 331 ms."
        XCTAssertEqual(bench.links.openCaption(apiLevel: 37), report)

        bench.links.draft = "geo:0,0"
        XCTAssertEqual(bench.links.openCaption(apiLevel: 37), LinksRowText.openIdleCaption)
        bench.links.draft = Self.maps
        XCTAssertEqual(bench.links.openCaption(apiLevel: 37), report)
    }

    /// While an Open waits for `am start -W`, the caption says so instead
    /// of showing the previous report.
    func testTheOpenCaptionWhileOpening() async throws {
        let open = try Self.request(Self.maps)
        let bench = try bench(arms: Self.arm(
            LinkCommands.openScript(open),
            "sleep 1; cat \(Self.fixture("open-maps-cold"))"
        ))
        bench.links.draft = Self.maps
        let opening = Task { await bench.links.open(apiLevel: 37) }
        await waitUntil { bench.links.isOpening }
        XCTAssertEqual(bench.links.openCaption(apiLevel: 37), LinksRowText.openingCaption)
        await opening.value
        XCTAssertNotEqual(bench.links.openCaption(apiLevel: 37), LinksRowText.openingCaption)
    }

    func testAnInvalidDraftOpensNothing() async throws {
        let bench = try bench(arms: "")
        bench.links.draft = "example.com"
        await bench.links.open(apiLevel: 37)
        bench.links.draft = "myapp://a\nb"
        await bench.links.open(apiLevel: 37)
        XCTAssertEqual(bench.adb.calls, [])
        XCTAssertNil(bench.links.lastOpen)
    }

    // MARK: - Preview

    func testThePreviewRead() async throws {
        let request = try Self.request(Self.videoLink)
        let bench = try bench(arms:
            Self.arm(LinkCommands.previewScript(request), "cat \(Self.fixture("preview-video-verified"))")
        )
        bench.links.draft = Self.videoLink

        await bench.links.refreshPreview(apiLevel: nil)

        XCTAssertEqual(bench.links.preview(for: request)?.resolvedPackage, "com.example.video")
        XCTAssertEqual(bench.links.probedAPILevel, 37)
        XCTAssertEqual(bench.links.apiLevel(deviceInfo: nil), 37)
        XCTAssertEqual(bench.links.apiLevel(deviceInfo: 30), 30, "the Info read wins")
        XCTAssertFalse(bench.links.isPreviewing)
        XCTAssertEqual(bench.adb.calls.count, 1, "the preview alone: no App Links read")
    }

    /// Android 6 and older: no preview command runs, and the caption says so.
    func testNoPreviewCommandAtAKnownAPI23() async throws {
        let bench = try bench(arms: "")
        bench.links.draft = Self.videoLink
        await bench.links.refreshPreview(apiLevel: 23)
        XCTAssertEqual(bench.adb.calls, [])
        XCTAssertFalse(bench.links.isPreviewing)
        XCTAssertEqual(
            LinksRowText.urlCaption(
                validation: bench.links.validation(apiLevel: 23),
                preview: nil,
                previewError: nil,
                apiLevel: 23
            ),
            "Android 6 and older cannot preview the app; Open reports what handled it."
        )
    }

    func testAStalePreviewIsDropped() async throws {
        let request = try Self.request(Self.videoLink)
        let bench = try bench(arms: Self.arm(
            LinkCommands.previewScript(request),
            "sleep 1; cat \(Self.fixture("preview-video-verified"))"
        ))
        bench.links.draft = Self.videoLink

        // The device changed while the preview ran.
        let generationChange = Task { await bench.links.refreshPreview(apiLevel: 37) }
        await waitUntil { !bench.adb.calls.isEmpty }
        bench.context.controlsGeneration += 1
        await generationChange.value
        XCTAssertNil(bench.links.preview(for: request))
        XCTAssertNil(bench.links.previewRequest)

        // The serial changed.
        let serialChange = Task { await bench.links.refreshPreview(apiLevel: 37) }
        await waitUntil { bench.adb.calls.count == 2 }
        bench.context.serial = "emulator-5556"
        await serialChange.value
        XCTAssertNil(bench.links.previewRequest)
        bench.context.serial = Self.serial

        // The draft changed: a preview for an older draft is dropped.
        let draftChange = Task { await bench.links.refreshPreview(apiLevel: 37) }
        await waitUntil { bench.adb.calls.count == 3 }
        bench.links.draft = "https://example.com/"
        await draftChange.value
        XCTAssertNil(bench.links.previewRequest)
        XCTAssertFalse(bench.links.isPreviewing)
    }

    // MARK: - Session

    func testDetachForgetsTheDeviceButKeepsTheDraftAndRecents() async throws {
        let open = try Self.request(Self.maps)
        let preview = try Self.request(Self.maps, package: "com.example.maps")
        let bench = try bench(arms:
            Self.arm(LinkCommands.openScript(open), "cat \(Self.fixture("open-maps-cold"))")
            + Self.arm(LinkCommands.previewScript(preview), "cat \(Self.fixture("preview-example"))")
        )
        bench.links.draft = Self.maps
        await bench.links.open(apiLevel: 37)
        await bench.links.refreshPreview(apiLevel: 37)
        XCTAssertNotNil(bench.links.previewRequest)

        bench.links.detach()

        XCTAssertNil(bench.links.preview)
        XCTAssertNil(bench.links.previewRequest)
        XCTAssertNil(bench.links.lastOpen)
        XCTAssertNil(bench.links.probedAPILevel)
        XCTAssertEqual(bench.links.draft, Self.maps)
        XCTAssertEqual(bench.links.recents.links, [Self.maps])
    }

    func testPackagesChangedReRunsThePreviewOfTheMirroredDeviceOnly() throws {
        let bench = try bench(arms: "")
        bench.links.draft = Self.maps
        let key = bench.links.previewKey(apiLevel: 37)
        bench.links.packagesChanged(serial: "emulator-5556")
        XCTAssertEqual(bench.links.previewKey(apiLevel: 37), key)
        bench.links.packagesChanged(serial: Self.serial)
        XCTAssertNotEqual(bench.links.previewKey(apiLevel: 37), key)
    }

}

/// Single-quoting for the stub's POSIX `case` patterns.
private enum FakeShell {
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
