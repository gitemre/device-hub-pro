import XCTest
@testable import DeviceHubProKit

/// Byte-exact device output under `Fixtures/api37-emulator/links`, captured
/// from the API 37 emulator (`emulator-5556`, AVD Pixel_9_Pro,
/// sdk_gphone16k_arm64, API 37.1, build CP31.260623.012) with the exact
/// command each call runs: every `*.command.txt` is the device-shell string
/// byte for byte, without a trailing newline. One thing is replaced: the
/// `applinks-verifier-*` signatures are the digest of the capturing Mac's
/// debug key, a per-machine identifier, so each hex digit reads `0` (same
/// length). The rest holds no personal identifier (the `ID:` UUIDs are
/// per-install domain-verification ids, the other signatures public
/// certificate digests).
///
/// The `*-verifier-*` captures use the Device Hub Pro verifier (android/verifier)
/// as built from this branch. Its App Links states other than the
/// verifier's own answer (`1024`: `.test` never resolves) were set from the
/// shell for the capture and put back afterwards: `verified` is `cmd
/// package set-app-links --package com.devicehubpro.verifier 1
/// verifier.devicehubpro.test`, `selected` is state 0 with `cmd package
/// set-app-links-user-selection --user 0 --package com.devicehubpro.verifier
/// true verifier.devicehubpro.test`, and `handling-off` adds `cmd package
/// set-app-links-allowed --user 0 --package com.devicehubpro.verifier false`.
///
/// The `echo-*` captures are `am to-uri -a android.intent.action.VIEW -d
/// <word>` (research captures `to-uri-*`, renamed): `am to-uri` prints
/// `intent.toUri(0)`, which for a VIEW intent with only data is the data
/// string verbatim, so they show what reached `am` through adb and mksh.
enum LinksAPI37Fixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/api37-emulator/links", isDirectory: true)

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func text(_ name: String) throws -> String {
        let data = try Data(contentsOf: url(name))
        return try XCTUnwrap(String(data: data, encoding: .utf8), "\(name) is UTF-8")
    }
}

/// The Links parsers fed that output. Every expected value is read off the
/// capture itself; none is computed by the parser under test.
///
/// Capture sequence (it explains the Maps and the video app results): Maps was
/// stopped (`open-maps-cold`), then on top (`open-maps-again`), then behind
/// HOME (`open-maps-from-background`). The video app's process was already up
/// (WARM) and its first screen was the notification permission request.
/// The browser's first run had never been completed (FirstRunActivity).
final class LinksDeviceOutputTests: XCTestCase {
    private static let videoLink = "https://video.example.com/watch?v=dQw4w9WgXcQ"
    private static let maps = "geo:41.0082,28.9784?q=Istanbul"
    private static let noHandler = "aqa-nohandler://open/item?id=42"
    private static let backslashHost = #"https://evil.example\@video.example.com/watch?v=dQw4w9WgXcQ"#
    private static let verifierAppLink = "https://verifier.devicehubpro.test/a"
    /// A host whose `%0A`s make am print a `Warning:`, a `Status:` and an
    /// `Activity:` line of the link's own (nothing resolves the scheme).
    private static let injectedHost =
        "aqa-nohandler://h%0AWarning:%20Activity%20not%20started,%20its%20current%20task%20has%20been%20brought%20to%20the%20front%0AStatus:%20ok%0AActivity:%20com.evil/.X%0Ax/p"
    /// The same with U+2028 (`%E2%80%A8`), which is not a line break.
    private static let encodedLineSeparator =
        "aqa-nohandler://h%E2%80%A8Warning:%20Activity%20not%20started,%20intent%20has%20been%20delivered%20to%20currently%20running%20top-most%20instance.%E2%80%A8x/p"

    private func request(_ uri: String, browsable: Bool = true, package: String? = nil) throws -> LinkRequest {
        try LinkRequest(uri, browsable: browsable, package: package, apiLevel: 37)
    }

    // MARK: - Commands

    /// The fixtures are the output of the current scripts: a script change
    /// needs a recapture. The table holds the inputs of each capture (URI,
    /// Browsable, package), not device output.
    func testTheFixturesComeFromTheCurrentScripts() throws {
        let opens: [(String, String, Bool, String?)] = [
            ("open-browser-first-run", "https://example.com/a b?q=1&r=2#frag", true, nil),
            ("open-video-verified", Self.videoLink, true, nil),
            ("open-chooser", "content://com.aqa.none/x", true, nil),
            ("open-maps-cold", Self.maps, true, nil),
            ("open-maps-again", Self.maps, true, nil),
            ("open-maps-from-background", Self.maps, true, nil),
            ("open-unresolved", Self.noHandler, true, nil),
            ("open-unresolved-not-browsable", Self.noHandler, false, nil),
            ("open-package-mismatch", "https://example.com/", true, "com.example.video"),
            ("open-uppercase-scheme", "HTTPS://EXAMPLE.COM/", true, nil),
            ("open-verifier-nodefault", "devicehubpro-verifier://nodefault/x", true, nil),
            ("open-injected-host", Self.injectedHost, true, nil),
            ("open-encoded-line-separator", Self.encodedLineSeparator, true, nil),
        ]
        for (name, uri, browsable, package) in opens {
            XCTAssertEqual(
                try LinksAPI37Fixture.text("\(name).command.txt"),
                LinkCommands.openScript(try request(uri, browsable: browsable, package: package)),
                name
            )
        }
        let previews: [(String, String, Bool, String?)] = [
            ("preview-example", "https://example.com/", true, nil),
            ("preview-video-verified", Self.videoLink, true, nil),
            ("preview-video-in-browser", Self.videoLink, true, "com.example.browser"),
            ("preview-not-browsable", Self.videoLink, false, nil),
            ("preview-no-handler", Self.noHandler, true, nil),
            ("preview-package-mismatch", "https://example.com/", true, "com.example.video"),
            ("preview-chooser", "content://com.aqa.none/x", true, nil),
            ("preview-uppercase-scheme", "HTTPS://EXAMPLE.COM/", true, nil),
            ("preview-uppercase-host", "https://VIDEO.EXAMPLE.COM/watch?v=dQw4w9WgXcQ", true, nil),
            ("preview-intent-scheme", "intent://example.com/#Intent;scheme=https;end", true, nil),
            ("preview-backslash-host", Self.backslashHost, true, nil),
            ("preview-percent-host", "https://www%2Evideo.example.com/watch?v=dQw4w9WgXcQ", true, nil),
            ("preview-verifier-app-link", Self.verifierAppLink, true, "com.devicehubpro.verifier"),
            ("preview-verifier-nodefault", "devicehubpro-verifier://nodefault/x", true, nil),
            ("preview-verifier-single-label", "https://devicehubpro-verifier/x", true, nil),
        ]
        for (name, uri, browsable, package) in previews {
            XCTAssertEqual(
                try LinksAPI37Fixture.text("\(name).command.txt"),
                LinkCommands.previewScript(try request(uri, browsable: browsable, package: package)),
                name
            )
        }
    }

    // MARK: - Open

    func testALaunchInAWarmBrowserFirstRun() throws {
        let result = LinkLaunchResult.parse(try LinksAPI37Fixture.text("open-browser-first-run.txt"))
        XCTAssertEqual(result.outcome, .started)
        XCTAssertEqual(result.status, "ok")
        XCTAssertEqual(result.launchState, .warm)
        XCTAssertEqual(result.activity?.flattened, "com.example.browser/com.example.browser.engine.firstrun.FirstRunActivity")
        XCTAssertEqual(result.activity?.package, "com.example.browser")
        XCTAssertEqual(result.totalTimeMs, 148)
        XCTAssertEqual(result.waitTimeMs, 157)
        XCTAssertNil(result.thisTimeMs, "API 29+ prints LaunchState instead of ThisTime")
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.isChooser)
    }

    func testAColdStart() throws {
        let result = LinkLaunchResult.parse(try LinksAPI37Fixture.text("open-maps-cold.txt"))
        XCTAssertEqual(result.outcome, .started)
        XCTAssertEqual(result.launchState, .cold)
        XCTAssertEqual(result.activity?.flattened, "com.example.maps/com.example.maps.MapsActivity")
        XCTAssertEqual(result.totalTimeMs, 331)
        XCTAssertEqual(result.waitTimeMs, 333)
    }

    func testDeliveredToTheRunningInstance() throws {
        let result = LinkLaunchResult.parse(try LinksAPI37Fixture.text("open-maps-again.txt"))
        XCTAssertEqual(result.outcome, .deliveredToTop)
        XCTAssertEqual(result.launchState, .unknown(0))
        XCTAssertEqual(result.activity?.package, "com.example.maps")
        XCTAssertEqual(result.totalTimeMs, 0)
        XCTAssertEqual(result.waitTimeMs, 17)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testATaskBroughtToFrontHasNoTotalTime() throws {
        let result = LinkLaunchResult.parse(try LinksAPI37Fixture.text("open-maps-from-background.txt"))
        XCTAssertEqual(result.outcome, .broughtToFront)
        XCTAssertEqual(result.launchState, .unknown(0))
        XCTAssertNil(result.totalTimeMs)
        XCTAssertEqual(result.waitTimeMs, 15)
        XCTAssertTrue(result.completed)
    }

    func testAPermissionRequestOnTop() throws {
        let result = LinkLaunchResult.parse(try LinksAPI37Fixture.text("open-video-verified.txt"))
        XCTAssertEqual(result.outcome, .started)
        XCTAssertEqual(
            result.activity?.flattened,
            "com.google.android.permissioncontroller/com.android.permissioncontroller.permission.ui.GrantPermissionsActivity"
        )
        XCTAssertEqual(result.launchState, .warm)
        XCTAssertEqual(result.totalTimeMs, 374)
        XCTAssertEqual(result.waitTimeMs, 377)
    }

    func testTheChooser() throws {
        let result = LinkLaunchResult.parse(try LinksAPI37Fixture.text("open-chooser.txt"))
        XCTAssertEqual(result.outcome, .started)
        XCTAssertTrue(result.isChooser)
        XCTAssertEqual(result.activity?.flattened, "android/com.android.internal.app.ResolverActivity")
        XCTAssertEqual(result.launchState, .cold)
    }

    func testUnresolvedLinks() throws {
        for name in [
            "open-unresolved", "open-unresolved-not-browsable", "open-package-mismatch", "open-uppercase-scheme",
            "open-verifier-nodefault",
        ] {
            let result = LinkLaunchResult.parse(try LinksAPI37Fixture.text("\(name).txt"))
            XCTAssertEqual(result.outcome, .notResolved, name)
            XCTAssertEqual(result.exitCode, 1, name)
            XCTAssertNil(result.status, name)
            XCTAssertNil(result.activity, name)
            XCTAssertFalse(result.completed, name)
        }
    }

    /// am printed the decoded host back, line feeds included: read raw,
    /// the echo's lines win; with the request (its echo flattened) or the
    /// API level (status 1 admits only an error), the link is unresolved.
    func testAnEchoedHostIsNotReadAsAmsLines() throws {
        let output = try LinksAPI37Fixture.text("open-injected-host.txt")
        XCTAssertEqual(LinkLaunchResult.parse(output).outcome, .broughtToFront, "the hazard")

        let request = try request(Self.injectedHost)
        let flattened = LinkLaunchResult.parse(output, request: request)
        XCTAssertEqual(flattened.outcome, .notResolved)
        XCTAssertNil(flattened.status)
        XCTAssertNil(flattened.activity)
        XCTAssertEqual(flattened.exitCode, 1)

        XCTAssertEqual(LinkLaunchResult.parse(output, apiLevel: 37).outcome, .notResolved)
        XCTAssertEqual(LinkLaunchResult.parse(output, request: request, apiLevel: 37).outcome, .notResolved)
    }

    /// U+2028 in the decoded host does not end a line.
    func testAnEchoedLineSeparatorIsNotALineBreak() throws {
        let output = try LinksAPI37Fixture.text("open-encoded-line-separator.txt")
        XCTAssertTrue(output.unicodeScalars.contains("\u{2028}"))
        XCTAssertEqual(LinkLaunchResult.parse(output).outcome, .notResolved)
        XCTAssertEqual(try request(Self.encodedLineSeparator).host?.unicodeScalars.contains("\u{2028}"), true)
    }

    // MARK: - Preview

    private func preview(_ name: String) throws -> LinkPreview {
        LinkPreview.parse(try LinksAPI37Fixture.text("\(name).txt"))
    }

    private func candidate(_ preview: LinkPreview, _ package: String) -> LinkCandidate? {
        preview.candidates.first { $0.component.package == package }
    }

    func testPreviews() throws {
        let browser = "com.example.browser/com.example.browser.app.IntentDispatcher"
        let video = "com.example.video/.UrlActivity"

        let example = try preview("preview-example")
        XCTAssertEqual(example.apiLevel, 37)
        XCTAssertEqual(example.resolution, .activity(LinkCandidate(component: try XCTUnwrap(LinkComponent(flattened: browser)), match: 0x208000)))
        XCTAssertEqual(example.candidates.count, 1)
        XCTAssertEqual(candidate(example, "com.example.browser")?.claimsHost, false, "0x208000: scheme only")

        let verified = try preview("preview-video-verified")
        XCTAssertEqual(verified.resolvedPackage, "com.example.video")
        if case .activity(let resolved) = verified.resolution {
            XCTAssertEqual(resolved.component.flattened, video)
            XCTAssertEqual(resolved.match, 0x508000)
        } else {
            XCTFail("\(verified.resolution)")
        }
        XCTAssertEqual(verified.candidates.map(\.component.flattened), [video, browser])
        XCTAssertEqual(candidate(verified, "com.example.video")?.claimsHost, true, "0x508000: host and path")
        XCTAssertEqual(candidate(verified, "com.example.browser")?.claimsHost, false)
        XCTAssertEqual(verified.packages, ["com.example.video", "com.example.browser"])
        XCTAssertEqual(verified.unreachable, [])

        let inBrowser = try preview("preview-video-in-browser")
        XCTAssertEqual(inBrowser.resolvedPackage, "com.example.browser")
        XCTAssertEqual(inBrowser.candidates.count, 2)

        let notBrowsable = try preview("preview-not-browsable")
        XCTAssertEqual(notBrowsable.resolvedPackage, "com.example.video")
        XCTAssertEqual(notBrowsable.candidates.count, 2)

        let noHandler = try preview("preview-no-handler")
        XCTAssertEqual(noHandler.resolution, LinkPreview.Resolution.none)
        XCTAssertEqual(noHandler.candidates, [])

        let mismatch = try preview("preview-package-mismatch")
        XCTAssertEqual(mismatch.resolution, LinkPreview.Resolution.none)
        XCTAssertEqual(mismatch.candidates.count, 1)

        let chooser = try preview("preview-chooser")
        XCTAssertEqual(
            chooser.resolution,
            .chooser(try XCTUnwrap(LinkComponent(flattened: "android/com.android.internal.app.ResolverActivity")))
        )
        XCTAssertEqual(chooser.candidates.count, 2)
        XCTAssertFalse(chooser.packages.contains("android"))
        XCTAssertEqual(chooser.packages, ["com.example.messages", "com.google.android.googlequicksearchbox"])

        let uppercaseScheme = try preview("preview-uppercase-scheme")
        XCTAssertEqual(uppercaseScheme.resolution, LinkPreview.Resolution.none)
        XCTAssertEqual(uppercaseScheme.candidates, [])

        // The filters match the host ignoring case, so the video app is still a
        // candidate that claims it; App Links approval compares the host
        // exactly, so the browser opens it.
        let uppercaseHost = try preview("preview-uppercase-host")
        XCTAssertEqual(uppercaseHost.resolvedPackage, "com.example.browser")
        XCTAssertEqual(uppercaseHost.candidates.count, 2)
        XCTAssertEqual(candidate(uppercaseHost, "com.example.video")?.claimsHost, true)

        let intentScheme = try preview("preview-intent-scheme")
        XCTAssertEqual(intentScheme.resolution, LinkPreview.Resolution.none)
        XCTAssertEqual(intentScheme.candidates, [])

        // Android's host is evil.example (`\` ends the authority): only
        // The browser matches.
        let backslash = try preview("preview-backslash-host")
        XCTAssertEqual(backslash.resolvedPackage, "com.example.browser")
        XCTAssertEqual(backslash.packages, ["com.example.browser"])
        XCTAssertEqual(try request(Self.backslashHost).host, "evil.example")

        // `%2E` is a dot to the filters and App Links alike.
        let percent = try preview("preview-percent-host")
        XCTAssertEqual(percent.resolvedPackage, "com.example.video")
    }

    /// The verifier's own filters: an App Link (host claimed, 0x308000), a
    /// filter without DEFAULT, and a single-label web host.
    func testTheVerifierPreviews() throws {
        let mainActivity = try XCTUnwrap(LinkComponent(flattened: "com.devicehubpro.verifier/.MainActivity"))

        let appLink = try preview("preview-verifier-app-link")
        XCTAssertEqual(appLink.resolution, .activity(LinkCandidate(component: mainActivity, match: 0x308000)))
        XCTAssertEqual(appLink.packages, ["com.devicehubpro.verifier", "com.example.browser"])

        // Listed by the query (isDefault=false), never resolved.
        let noDefault = try preview("preview-verifier-nodefault")
        XCTAssertEqual(noDefault.resolution, LinkPreview.Resolution.none)
        XCTAssertEqual(noDefault.candidates, [])
        XCTAssertEqual(noDefault.unreachable, [LinkCandidate(component: mainActivity, match: 0x308000)])

        // App Links does not apply to a single label: the verifier's
        // autoVerify filter is not approved, so Android asks.
        let singleLabel = try preview("preview-verifier-single-label")
        XCTAssertEqual(
            singleLabel.resolution,
            .chooser(try XCTUnwrap(LinkComponent(flattened: "android/com.android.internal.app.ResolverActivity")))
        )
        XCTAssertEqual(singleLabel.candidates.first, LinkCandidate(component: mainActivity, match: 0x308000))
        XCTAssertEqual(singleLabel.resolverComponent?.package, "android")
    }

    // MARK: - Shell words

    /// Each echo reached `am` byte for byte: the URI is the output minus its
    /// final newline, and the command is `shellWord` of exactly that URI
    /// (single-quoted for ASCII, the octal `$'…'` form otherwise).
    func testTheEchoesRoundTripOnTheDevice() throws {
        let names = [
            "echo-quotes", "echo-subst", "echo-semicolon", "echo-space-amp-hash", "echo-leading-dash",
            "echo-unicode-octal-word", "echo-unicode-metachar-octal-word",
        ]
        for name in names {
            let output = try LinksAPI37Fixture.text("\(name).txt")
            XCTAssertTrue(output.hasSuffix("\n"), name)
            let uri = String(output.dropLast())
            XCTAssertEqual(
                try LinksAPI37Fixture.text("\(name).command.txt"),
                "am to-uri -a android.intent.action.VIEW -d " + AdbClient.shellWord(uri),
                name
            )
        }
        // The metacharacters stayed literal: nothing ran on the device.
        let metachar = try LinksAPI37Fixture.text("echo-unicode-metachar-octal-word.txt")
        XCTAssertEqual(metachar, "myapp://ü/;echo INJECTED;$(id)`id`'q'\"d\"\\b ${HOME}&x=1#f\n")
    }
}
