import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// Every caption and value of the Links rows, fed the Kit's API 37
/// captures (`DeviceHubProKitTests/Fixtures/api37-emulator/links`, loaded by
/// path). Where a test builds a model value instead, it is a combination
/// the parsers cannot produce from one capture (named in the test).
final class LinksRowTextTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DeviceHubProKitTests/Fixtures/api37-emulator/links")

    private func text(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent("\(name).txt"), encoding: .utf8)
    }

    private func preview(_ name: String) throws -> LinkPreview {
        LinkPreview.parse(try text(name))
    }

    private func launch(_ name: String) throws -> LinkLaunchResult {
        LinkLaunchResult.parse(try text(name))
    }

    private func request(_ uri: String, browsable: Bool = true, package: String? = nil) throws -> LinkRequest {
        try LinkRequest(uri, browsable: browsable, package: package, apiLevel: 37)
    }

    private func urlCaption(_ request: LinkRequest, _ preview: LinkPreview?, apiLevel: Int? = 37) -> String {
        LinksRowText.urlCaption(validation: .success(request), preview: preview, previewError: nil, apiLevel: apiLevel)
    }

    private static let videoLink = "https://video.example.com/watch?v=dQw4w9WgXcQ"
    private static let browser = "com.example.browser/com.example.browser.app.IntentDispatcher"

    // MARK: - URL

    func testTheURLCaptionBeforeAPreview() throws {
        XCTAssertEqual(
            LinksRowText.urlCaption(validation: nil, preview: nil, previewError: nil, apiLevel: 37),
            "Opens a web link or an app's deep link on the device as an ACTION_VIEW intent."
        )
        XCTAssertEqual(
            LinksRowText.urlCaption(validation: .failure(.noScheme), preview: nil, previewError: nil, apiLevel: 37),
            "Add a scheme: https:// for a web link, or the app's own (myapp://)."
        )
        XCTAssertEqual(
            LinksRowText.urlCaption(validation: .failure(.controlCharacter), preview: nil, previewError: nil, apiLevel: 37),
            "The link contains a line break, tab or other control character. Percent-encode it (%0A, %09) to send it."
        )
        XCTAssertEqual(
            LinksRowText.urlCaption(validation: .failure(.tooLong(bytes: 3_705, limit: 3_700)), preview: nil, previewError: nil, apiLevel: nil),
            "Too long for this device: Device Hub Pro sends links up to 3,700 bytes after escaping (a non-ASCII character takes 8 to 16)."
        )
        XCTAssertEqual(
            LinksRowText.validationCaption(.tooLong(bytes: 30_001, limit: 30_000)),
            "Too long for this device: Device Hub Pro sends links up to 30,000 bytes after escaping (a non-ASCII character takes 8 to 16)."
        )
        let example = try request("https://example.com/")
        XCTAssertEqual(urlCaption(example, nil), "Checking which app opens it…")
        XCTAssertEqual(
            urlCaption(example, nil, apiLevel: 23),
            "Android 6 and older cannot preview the app; Open reports what handled it."
        )
        XCTAssertEqual(
            LinksRowText.urlCaption(validation: .success(example), preview: nil, previewError: "error: device offline", apiLevel: 37),
            "Could not check which app opens it: error: device offline."
        )
    }

    func testTheURLCaptionOfEachPreview() throws {
        XCTAssertEqual(
            urlCaption(try request("https://example.com/"), try preview("preview-example")),
            "Opens in \(Self.browser)."
        )
        XCTAssertEqual(
            urlCaption(try request(Self.videoLink), try preview("preview-video-verified")),
            "Opens in com.example.video/.UrlActivity. 2 apps can open it."
        )
        XCTAssertEqual(
            urlCaption(try request("content://com.aqa.none/x"), try preview("preview-chooser")),
            "Android will ask which app to open it with: no app is the default for it. Android also matches the provider's file type when it opens these links, so the choice can differ."
        )
        XCTAssertEqual(
            urlCaption(try request("aqa-nohandler://open/item?id=42"), try preview("preview-no-handler")),
            "No app on this device opens it as a web link (Browsable)."
        )
        XCTAssertEqual(
            urlCaption(try request("aqa-nohandler://open/item?id=42", browsable: false), try preview("preview-no-handler")),
            "No app on this device opens it."
        )
        XCTAssertEqual(
            urlCaption(try request("https://example.com/", package: "com.example.video"), try preview("preview-package-mismatch")),
            "com.example.video has no activity for this link that accepts web links (BROWSABLE)."
        )
    }

    func testTheCaseAndIntentHints() throws {
        XCTAssertEqual(
            urlCaption(try request("HTTPS://EXAMPLE.COM/"), try preview("preview-uppercase-scheme")),
            "No app on this device opens it as a web link (Browsable). Android matches the scheme case-sensitively (HTTPS is not https): try https://example.com/."
        )
        XCTAssertEqual(
            urlCaption(try request("https://VIDEO.EXAMPLE.COM/watch?v=dQw4w9WgXcQ"), try preview("preview-uppercase-host")),
            "Opens in \(Self.browser). 2 apps can open it."
        )
        XCTAssertEqual(
            urlCaption(try request("intent://example.com/#Intent;scheme=https;end"), try preview("preview-intent-scheme")),
            "No app on this device opens it as a web link (Browsable). intent: links are read by the web page's browser (Intent.parseUri), not by Android's VIEW resolution: open the URI it names instead."
        )
    }

    /// The captures of this round: a filter without DEFAULT is named, and
    /// a percent-encoded host is not an uppercase one.
    func testTheURLCaptionsOfHostsAndFilters() throws {
        XCTAssertEqual(
            urlCaption(try request("devicehubpro-verifier://nodefault/x"), try preview("preview-verifier-nodefault")),
            "No app on this device opens it as a web link (Browsable). com.devicehubpro.verifier/.MainActivity matches it, but its filter lacks android.intent.category.DEFAULT, so am start and other apps' startActivity never reach it."
        )
        // With Open in, only the target's own entries.
        XCTAssertEqual(
            LinksRowText.unreachableHint(
                try preview("preview-verifier-nodefault"),
                request: try request("devicehubpro-verifier://nodefault/x", package: "com.example.other")
            ),
            ""
        )
        XCTAssertEqual(
            urlCaption(try request("https://www%2Evideo.example.com/watch?v=dQw4w9WgXcQ"), try preview("preview-percent-host")),
            "Opens in com.example.video/.UrlActivity. 2 apps can open it.",
            "no uppercase hint: the decoded host has none"
        )
        let backslash = try request(#"https://evil.example\@video.example.com/watch?v=dQw4w9WgXcQ"#)
        XCTAssertEqual(urlCaption(backslash, try preview("preview-backslash-host")), "Opens in \(Self.browser).")
    }

    /// Model values: several unreachable activities (no app on this image
    /// has more than the verifier's one).
    func testTheUnreachableHintNamesTwoAndCounts() throws {
        let components = try ["a.one/.A", "b.two/.B", "c.three/.C"].map { try XCTUnwrap(LinkComponent(flattened: $0)) }
        let preview = LinkPreview(
            apiLevel: 37,
            resolution: .none,
            unreachable: components.map { LinkCandidate(component: $0, match: 0x308000) }
        )
        XCTAssertEqual(
            LinksRowText.unreachableHint(preview, request: nil),
            " a.one/.A, b.two/.B and 1 more match it, but their filters lack android.intent.category.DEFAULT, so am start and other apps' startActivity never reach them."
        )
    }

    // MARK: - Open

    private func openCaption(_ name: String, _ request: LinkRequest, preview: LinkPreview? = nil) throws -> String {
        LinksRowText.openCaption(outcome: .result(try launch(name)), request: request, preview: preview, apiLevel: 37)
    }

    func testTheOpenCaptions() throws {
        XCTAssertEqual(
            LinksRowText.openCaption(outcome: nil, request: nil, preview: nil),
            "Runs am start -W with ACTION_VIEW and reports what Android started."
        )
        let maps = try request("geo:41.0082,28.9784?q=Istanbul")
        XCTAssertEqual(
            try openCaption("open-maps-cold", maps),
            "Opened com.example.maps/com.example.maps.MapsActivity · cold start · 331 ms."
        )
        XCTAssertEqual(
            try openCaption("open-video-verified", try request(Self.videoLink), preview: try preview("preview-video-verified")),
            "Sent to com.example.video; the screen now shows com.google.android.permissioncontroller/com.android.permissioncontroller.permission.ui.GrantPermissionsActivity · warm start · 374 ms."
        )
        XCTAssertEqual(
            try openCaption("open-browser-first-run", try request("https://example.com/a b?q=1&r=2#frag"), preview: try preview("preview-example")),
            "Opened com.example.browser/com.example.browser.engine.firstrun.FirstRunActivity · warm start · 148 ms.",
            "the same package as the preview's: no Sent to"
        )
        XCTAssertEqual(
            try openCaption("open-chooser", try request("content://com.aqa.none/x")),
            "Android asked which app to open it with; the choice is on the device screen."
        )
        XCTAssertEqual(
            try openCaption("open-maps-again", maps),
            "Android started no new screen: com.example.maps/com.example.maps.MapsActivity was already on top. If it is singleTop or singleTask it received the link in onNewIntent; otherwise Android only reused the screen and the app did not get this link."
        )
        XCTAssertEqual(
            try openCaption("open-maps-from-background", maps),
            "Android brought com.example.maps's existing task to the front instead of starting a screen. If the activity is singleTop or singleTask it received the link in onNewIntent; otherwise the app did not get this link. Force-stop the app (Apps ▸ Force Stop) to test a fresh start."
        )
    }

    func testTheUnresolvedOpenCaptions() throws {
        XCTAssertEqual(
            try openCaption(
                "open-verifier-nodefault",
                try request("devicehubpro-verifier://nodefault/x"),
                preview: try preview("preview-verifier-nodefault")
            ),
            "No app opened it: Android found no activity for this link that accepts web links. com.devicehubpro.verifier/.MainActivity matches it, but its filter lacks android.intent.category.DEFAULT, so am start and other apps' startActivity never reach it."
        )
        XCTAssertEqual(
            try openCaption("open-unresolved", try request("aqa-nohandler://open/item?id=42")),
            "No app opened it: Android found no activity for this link that accepts web links."
        )
        XCTAssertEqual(
            try openCaption("open-unresolved-not-browsable", try request("aqa-nohandler://open/item?id=42", browsable: false)),
            "No app opened it: Android found no activity for this link."
        )
        XCTAssertEqual(
            try openCaption("open-package-mismatch", try request("https://example.com/", package: "com.example.video")),
            "No app opened it: Android found no activity for this link in com.example.video that accepts web links."
        )
        XCTAssertEqual(
            try openCaption("open-uppercase-scheme", try request("HTTPS://EXAMPLE.COM/")),
            "No app opened it: Android found no activity for this link that accepts web links. Android matches the scheme case-sensitively (HTTPS is not https): try https://example.com/."
        )
    }

    /// A build's own resolver: am names it, and the preview of the same
    /// request resolved to it as the chooser. (Model values: no such build
    /// here; the parse is SOURCE-DERIVED in the Kit's LinksTests.)
    func testAVendorResolverIsTheChooserInTheOpenCaption() throws {
        let vendor = try XCTUnwrap(LinkComponent(flattened: "com.vendor.resolver/.VendorResolverActivity"))
        let preview = LinkPreview(apiLevel: 36, resolution: .chooser(vendor))
        let launch = LinkLaunchResult(outcome: .started, status: "ok", launchState: .cold, activity: vendor, totalTimeMs: 90)
        let example = try request("https://example.com/")
        XCTAssertEqual(
            LinksRowText.openCaption(outcome: .result(launch), request: example, preview: preview),
            "Android asked which app to open it with; the choice is on the device screen."
        )
        XCTAssertEqual(
            LinksRowText.openCaption(outcome: .result(launch), request: example, preview: nil),
            "Opened com.vendor.resolver/.VendorResolverActivity · cold start · 90 ms.",
            "without the preview, a vendor resolver is an activity like any other"
        )
    }

    func testTheOpenRowCaption() throws {
        let maps = try request("geo:41.0082,28.9784?q=Istanbul")
        let outcome = LinkOpenOutcome.result(try launch("open-maps-cold"))
        func caption(current: LinkRequest?, isOpening: Bool = false) -> String {
            LinksRowText.openRowCaption(
                outcome: outcome, openedRequest: maps, current: current, isOpening: isOpening, preview: nil, apiLevel: 37
            )
        }
        XCTAssertEqual(caption(current: maps), "Opened com.example.maps/com.example.maps.MapsActivity · cold start · 331 ms.")
        XCTAssertEqual(caption(current: try request("geo:0,0")), LinksRowText.openIdleCaption)
        XCTAssertEqual(caption(current: try request(maps.uri, browsable: false)), LinksRowText.openIdleCaption)
        XCTAssertEqual(caption(current: nil), LinksRowText.openIdleCaption)
        XCTAssertEqual(caption(current: maps, isOpening: true), "Opening: am start -W reports once the app's first screen has drawn.")
    }

    /// Model values: the outcomes no capture on this image produced (their
    /// output is SOURCE-DERIVED in the Kit's LinksTests).
    func testTheOtherOpenCaptions() throws {
        let example = try request("https://example.com/")
        XCTAssertEqual(
            LinksRowText.openCaption(outcome: .noReport(seconds: 30), request: example, preview: nil),
            "No answer within 30 s: either the device could not be reached, or the app is still launching (waiting for a debugger, or stuck before its first frame). Check the device screen."
        )
        XCTAssertEqual(
            LinksRowText.openCaption(outcome: .failed("error: device 'emulator-5554' not found"), request: example, preview: nil),
            "No answer from the device: error: device 'emulator-5554' not found."
        )
        XCTAssertEqual(
            LinksRowText.openCaption(outcome: .result(LinkLaunchResult(outcome: .started, status: "timeout")), request: example, preview: nil),
            "Android started it, but reported a timeout before the screen drew."
        )
        XCTAssertEqual(
            LinksRowText.openCaption(
                outcome: .result(LinkLaunchResult(outcome: .otherWarning("Activity not started because intent should be handled by the caller"))),
                request: example,
                preview: nil
            ),
            "Activity not started because intent should be handled by the caller."
        )
        XCTAssertEqual(
            LinksRowText.openCaption(outcome: .result(LinkLaunchResult(outcome: .refused("Permission Denial: starting Intent"))), request: example, preview: nil),
            "Android refused to open it: Permission Denial: starting Intent."
        )
    }

    // MARK: - Popups

    func testRecentTitlesAreShortenedInTheMiddle() {
        XCTAssertEqual(LinksRowText.recentTitle("https://example.com/"), "https://example.com/")
        let long = "https://example.com/oauth/callback?code=" + String(repeating: "x", count: 80) + "&state=end"
        let title = LinksRowText.recentTitle(long)
        XCTAssertEqual(title.count, 60)
        XCTAssertEqual(title, "https://example.com/oauth/call…" + String(repeating: "x", count: 19) + "&state=end")
        XCTAssertEqual(LinksRowText.recentTitle(String(repeating: "a", count: 60)).count, 60)
    }
}
