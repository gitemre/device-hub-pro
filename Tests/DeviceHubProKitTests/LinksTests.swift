import XCTest
@testable import DeviceHubProKit

/// The Links Kit without a device: request validation, the shell word, the
/// exact scripts, and the parsers fed output derived from AOSP where no
/// capture is possible (each such case names its source).
final class LinksTests: XCTestCase {
    // MARK: - Validation

    func testEmptyAndWhitespaceOnlyLinksAreRefused() {
        XCTAssertThrowsError(try LinkRequest("", apiLevel: 37)) { XCTAssertEqual($0 as? LinkError, .empty) }
        XCTAssertThrowsError(try LinkRequest(" \n\t ", apiLevel: 37)) { XCTAssertEqual($0 as? LinkError, .empty) }
    }

    func testSurroundingWhitespaceIsTrimmed() throws {
        let request = try LinkRequest("\n  https://example.com/a  \n", apiLevel: 37)
        XCTAssertEqual(request.uri, "https://example.com/a")
        XCTAssertTrue(request.browsable)
        XCTAssertNil(request.package)
    }

    func testALinkNeedsAScheme() {
        for text in ["example.com", "example.com/path", ":nothing", "1abc://x", "a b://x", "/path:x"] {
            XCTAssertThrowsError(try LinkRequest(text, apiLevel: 37), text) {
                XCTAssertEqual($0 as? LinkError, .noScheme, text)
            }
        }
        XCTAssertNoThrow(try LinkRequest("a+b-c.d://x", apiLevel: 37))
        XCTAssertNoThrow(try LinkRequest("geo:41,29", apiLevel: 37))
    }

    func testControlCharactersInsideAreRefused() {
        // C0, DEL, C1 (NEL among them) and the invisible line and paragraph
        // separators: none survives a paste on purpose.
        for control in ["\n", "\t", "\r", "\u{0}", "\u{7F}", "\u{1B}", "\u{85}", "\u{9F}", "\u{2028}", "\u{2029}"] {
            XCTAssertThrowsError(try LinkRequest("myapp://a\(control)b", apiLevel: 37)) {
                XCTAssertEqual($0 as? LinkError, .controlCharacter, "\(control.unicodeScalars.map(\.value))")
            }
        }
        // Percent-encoded, they are the link's own data.
        XCTAssertNoThrow(try LinkRequest("myapp://a/x?t=a%0Ab%E2%80%A8c", apiLevel: 37))
        XCTAssertNoThrow(try LinkRequest("myapp://a\u{A0}b", apiLevel: 37), "NBSP is not a control character")
    }

    func testTheLengthLimitFollowsTheAPILevel() throws {
        let prefix = "myapp://"
        // The word of a plain ASCII link is the link itself.
        let atLimit = prefix + String(repeating: "a", count: 3_700 - prefix.count)
        XCTAssertNoThrow(try LinkRequest(atLimit, apiLevel: nil))
        let over = atLimit + "a"
        for level in [nil, 23] as [Int?] {
            XCTAssertThrowsError(try LinkRequest(over, apiLevel: level)) {
                XCTAssertEqual($0 as? LinkError, .tooLong(bytes: 3_701, limit: 3_700))
            }
        }
        XCTAssertNoThrow(try LinkRequest(over, apiLevel: 24))

        let long = prefix + String(repeating: "a", count: 30_001 - prefix.count)
        XCTAssertThrowsError(try LinkRequest(long, apiLevel: 24)) {
            XCTAssertEqual($0 as? LinkError, .tooLong(bytes: 30_001, limit: 30_000))
        }

        // ü is two UTF-8 bytes, each an 4-character octal escape: 463 of
        // them take 3,704 bytes, plus `$'` and `'`.
        let umlauts = String(repeating: "ü", count: 463)
        XCTAssertThrowsError(try LinkRequest("m:" + umlauts, apiLevel: nil)) {
            XCTAssertEqual($0 as? LinkError, .tooLong(bytes: 463 * 8 + 2 + 3, limit: 3_700))
        }
        XCTAssertEqual(LinkRequest.maximumShellWordBytes(apiLevel: nil), 3_700)
        XCTAssertEqual(LinkRequest.maximumShellWordBytes(apiLevel: 37), 30_000)
    }

    func testAPackageMustBeAPackageName() throws {
        XCTAssertThrowsError(try LinkRequest("https://example.com/", package: "com.x; reboot", apiLevel: 37)) {
            XCTAssertEqual($0 as? LinkError, .invalidPackage("com.x; reboot"))
        }
        XCTAssertThrowsError(try LinkRequest("https://example.com/", package: "", apiLevel: 37)) {
            XCTAssertEqual($0 as? LinkError, .invalidPackage(""))
        }
        XCTAssertEqual(try LinkRequest("https://example.com/", package: "com.example.browser", apiLevel: 37).package, "com.example.browser")
    }

    /// Canonically equivalent links are different requests: the device gets
    /// different bytes.
    func testRequestsCompareBytes() throws {
        let composed = try LinkRequest("myapp://\u{E9}", apiLevel: 37)
        let decomposed = try LinkRequest("myapp://e\u{301}", apiLevel: 37)
        XCTAssertEqual(composed.uri, decomposed.uri, "Swift's String == is canonical equivalence")
        XCTAssertNotEqual(composed, decomposed)
        XCTAssertEqual(composed, try LinkRequest("myapp://\u{E9}", apiLevel: 24))
        XCTAssertNotEqual(composed, try LinkRequest("myapp://\u{E9}", browsable: false, apiLevel: 37))
    }

    // MARK: - Parts

    func testSchemeHostAndCase() throws {
        let web = try LinkRequest("https://user@www.Example.com:8443/p?q#f", apiLevel: 37)
        XCTAssertEqual(web.scheme, "https")
        XCTAssertEqual(web.host, "www.Example.com")
        XCTAssertTrue(web.isWebLink)
        XCTAssertFalse(web.schemeHasUppercase)
        XCTAssertTrue(web.webHostHasUppercase)
        XCTAssertEqual(web.lowercasedForm, "https://user@www.example.com:8443/p?q#f")

        let upper = try LinkRequest("HTTPS://EXAMPLE.COM/", apiLevel: 37)
        XCTAssertFalse(upper.isWebLink, "Intent.isWebIntent compares the scheme exactly")
        XCTAssertTrue(upper.schemeHasUppercase)
        XCTAssertTrue(upper.webHostHasUppercase)
        XCTAssertEqual(upper.lowercasedForm, "https://example.com/")

        let geo = try LinkRequest("geo:41,29", apiLevel: 37)
        XCTAssertEqual(geo.scheme, "geo")
        XCTAssertNil(geo.host)
        XCTAssertNil(geo.lowercasedForm)

        let app = try LinkRequest("myapp://x/y", apiLevel: 37)
        XCTAssertEqual(app.host, "x")
        XCTAssertFalse(app.isWebLink)

        let mixed = try LinkRequest("MyApp://X", apiLevel: 37)
        XCTAssertTrue(mixed.schemeHasUppercase)
        XCTAssertFalse(mixed.webHostHasUppercase, "the host case matters for web links only")
        XCTAssertEqual(mixed.lowercasedForm, "myapp://X")

        XCTAssertEqual(try LinkRequest("http://[::1]:8080/x", apiLevel: 37).host, "[::1]")
        XCTAssertEqual(try LinkRequest("http://[::1]/x", apiLevel: 37).host, "[::1]")
        XCTAssertEqual(try LinkRequest("https://a@b@example.com?x", apiLevel: 37).host, "example.com")
        XCTAssertEqual(try LinkRequest("https://exa%6Dple.com/", apiLevel: 37).host, "example.com")
        XCTAssertEqual(try LinkRequest("https://example.com:port/", apiLevel: 37).host, "example.com:port")
    }

    /// `\` ends the authority, as in android.net.Uri (android-16.0.0_r1:
    /// 749–758): the host is `evil.example`, not the one after `@` (the
    /// capture `preview-backslash-host` resolves to the browser only).
    func testABackslashEndsTheAuthority() throws {
        let request = try LinkRequest(#"https://evil.example\@video.example.com/watch?v=dQw4w9WgXcQ"#, apiLevel: 37)
        XCTAssertEqual(request.host, "evil.example")
        XCTAssertFalse(request.webHostHasUppercase)
        XCTAssertNil(request.lowercasedForm)
    }

    /// App Links compares the decoded host: `%2E` is a dot, and an escape
    /// is not an uppercase letter (the capture `preview-percent-host`
    /// resolves `www%2Evideo.example.com` to the video app).
    func testThePercentEncodedHostCase() throws {
        let dot = try LinkRequest("https://www%2Evideo.example.com/watch?v=x", apiLevel: 37)
        XCTAssertEqual(dot.host, "www.video.example.com")
        XCTAssertFalse(dot.webHostHasUppercase)
        XCTAssertNil(dot.lowercasedForm)

        let umlaut = try LinkRequest("https://m%C3%BCnchen.example/", apiLevel: 37)
        XCTAssertEqual(umlaut.host, "münchen.example")
        XCTAssertFalse(umlaut.webHostHasUppercase)
        XCTAssertNil(umlaut.lowercasedForm)

        // The letters are lowercased, the escapes kept as typed.
        let upper = try LinkRequest("https://WWW%2Evideo.example.com/Watch", apiLevel: 37)
        XCTAssertTrue(upper.webHostHasUppercase)
        XCTAssertEqual(upper.lowercasedForm, "https://www%2Evideo.example.com/Watch")
        let upperEscape = try LinkRequest("HTTPS://M%C3%9Cnchen.example/", apiLevel: 37)
        XCTAssertEqual(upperEscape.host, "MÜnchen.example")
        XCTAssertEqual(upperEscape.lowercasedForm, "https://m%C3%9Cnchen.example/")
    }

    // MARK: - Shell word

    func testAnASCIIWordIsShellQuoted() {
        for text in ["https://example.com/", "https://example.com/a b?q=1&r=2#frag", "myapp://x/'q'\"d\"\\b", "--es evil 1"] {
            XCTAssertEqual(AdbClient.shellWord(text), AdbClient.shellQuoted(text), text)
        }
    }

    func testANonASCIIWordIsOctal() {
        XCTAssertEqual(
            AdbClient.shellWord("myapp://ü/;echo INJECTED;$(id)`id`'q'\"d\"\\b ${HOME}&x=1#f"),
            #"$'myapp://\303\274/;echo INJECTED;$(id)`id`\047q\047"d"\134b ${HOME}&x=1#f'"#
        )
        // Control characters of a non-ASCII word are octal too.
        XCTAssertEqual(AdbClient.shellWord("ü\n"), #"$'\303\274\012'"#)
    }

    func testEveryWordIsPureASCII() {
        let corpus = [
            "myapp://😀/👩‍👩‍👧", "myapp://e\u{301}\u{302}", "myapp://עברית/مرحبا", "https://example.com/日本語",
            "myapp://ü/'\\$`;&|<>(){}*?~!#\"", "ü'", "ü\\", "ü$HOME", "ü`id`", "ü;reboot",
        ]
        for text in corpus {
            let word = AdbClient.shellWord(text)
            XCTAssertTrue(word.utf8.allSatisfy { $0 < 0x80 }, text)
            XCTAssertTrue(word.hasPrefix("$'") && word.hasSuffix("'"), text)
            XCTAssertFalse(word.dropFirst(2).dropLast().contains("'"), "no raw quote inside: \(text)")
        }
    }

    /// Through Foundation.Process (so the NFD path is exercised) into zsh,
    /// which ships with every macOS (`/bin/sh` may be dash): the bytes that
    /// come out are the link's own.
    func testShellWordsRoundTripThroughAPosixShell() async throws {
        let corpus = [
            "https://example.com/ünïcödé/çğış?q=日本語&e=😀",
            "myapp://ü/;echo INJECTED;$(id)`id`'q'\"d\"\\b ${HOME}&x=1#f",
            "myapp://e\u{301}/\u{E9}",
            "myapp://עברית/😀/'\\",
            "https://example.com/a b?q=1&r=2#frag",
            "myapp://x/'single'\"double\"\\back|pipe>gt<lt!bang*glob~tilde{a,b}",
            "--es evil 1",
        ]
        for uri in corpus {
            let result = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-f", "-c", "printf %s " + AdbClient.shellWord(uri)],
                timeout: .seconds(10)
            )
            XCTAssertEqual(result.exitCode, 0, uri)
            XCTAssertEqual(Array(result.standardOutput), Array(uri.utf8), uri)
        }
    }

    /// Why `shellWord` exists: Foundation.Process decomposes a non-ASCII
    /// argument (research evidence `process-nfd-local.txt`, macOS 27.0).
    func testFoundationProcessDecomposesNonASCIIArguments() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", "\u{FC}"],
            timeout: .seconds(10)
        )
        XCTAssertEqual(
            Array(result.standardOutput),
            [0x75, 0xCC, 0x88],
            "Foundation.Process no longer decomposes argv; shellWord's octal form is then unnecessary but still correct."
        )
    }

    // MARK: - Scripts

    func testTheOpenScript() throws {
        XCTAssertEqual(
            LinkCommands.openScript(try LinkRequest("https://example.com/", apiLevel: 37)),
            "am start -W -a android.intent.action.VIEW -d https://example.com/ -c android.intent.category.BROWSABLE 2>&1; echo @@devicehubpro:link:exit=$?"
        )
        XCTAssertEqual(
            LinkCommands.openScript(try LinkRequest("myapp://x?a=1&b=2", browsable: false, package: "com.example.app", apiLevel: 37)),
            "am start -W -a android.intent.action.VIEW -d 'myapp://x?a=1&b=2' -p com.example.app 2>&1; echo @@devicehubpro:link:exit=$?"
        )
        XCTAssertEqual(
            LinkCommands.openScript(try LinkRequest("myapp://ü", apiLevel: 37)),
            #"am start -W -a android.intent.action.VIEW -d $'myapp://\303\274' -c android.intent.category.BROWSABLE 2>&1; echo @@devicehubpro:link:exit=$?"#
        )
    }

    func testThePreviewScript() throws {
        let flags = #"flags=; if [ "$api" -ge 29 ]; then flags='--query-flags 0x20000'; fi; "#
        XCTAssertEqual(
            LinkCommands.previewScript(try LinkRequest("https://example.com/", apiLevel: 37)),
            "echo @@devicehubpro:link:api; api=$(getprop ro.build.version.sdk); echo $api; echo @@devicehubpro:link:resolve; "
                + "if [ \"$api\" -ge 24 ]; then cmd package resolve-activity --brief -a android.intent.action.VIEW -d https://example.com/ "
                + "-c android.intent.category.BROWSABLE -c android.intent.category.DEFAULT 2>&1; fi; echo @@devicehubpro:link:candidates; "
                + flags
                + "if [ \"$api\" -ge 24 ]; then cmd package query-activities --brief $flags -a android.intent.action.VIEW -d https://example.com/ "
                + "-c android.intent.category.BROWSABLE 2>&1; fi; true"
        )
        // Browsable off, with a package: DEFAULT and -p on the resolve half
        // only; the candidates half has no category.
        XCTAssertEqual(
            LinkCommands.previewScript(try LinkRequest("myapp://ü", browsable: false, package: "com.example.app", apiLevel: 37)),
            "echo @@devicehubpro:link:api; api=$(getprop ro.build.version.sdk); echo $api; echo @@devicehubpro:link:resolve; "
                + #"if [ "$api" -ge 24 ]; then cmd package resolve-activity --brief -a android.intent.action.VIEW -d $'myapp://\303\274' "#
                + "-c android.intent.category.DEFAULT -p com.example.app 2>&1; fi; echo @@devicehubpro:link:candidates; "
                + flags
                + #"if [ "$api" -ge 24 ]; then cmd package query-activities --brief $flags -a android.intent.action.VIEW -d $'myapp://\303\274' "#
                + "2>&1; fi; true"
        )
    }

    /// `$flags` expands to two words from API 29 and to none before, when
    /// `cmd package` would refuse `--query-flags` (PackageManagerShellCommand
    /// android-9.0.0_r1 has no such option). Through zsh in sh mode, as
    /// the device's mksh splits unquoted words.
    func testTheQueryFlagsWordSplitting() async throws {
        for (api, expected) in [(28, "[-a]"), (29, "[--query-flags][0x20000][-a]")] {
            let script = "api=\(api); flags=; if [ \"$api\" -ge 29 ]; then flags='--query-flags 0x20000'; fi; "
                + "printf '[%s]' $flags -a"
            let result = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-f", "-o", "shwordsplit", "-c", script],
                timeout: .seconds(10)
            )
            XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), expected, "API \(api)")
        }
    }

    // MARK: - Components and candidates

    func testComponents() throws {
        let short = try XCTUnwrap(LinkComponent(flattened: "com.example.video/.UrlActivity"))
        XCTAssertEqual(short.package, "com.example.video")
        XCTAssertEqual(short.className, ".UrlActivity")
        XCTAssertFalse(short.isChooser)
        XCTAssertTrue(try XCTUnwrap(LinkComponent(flattened: "android/com.android.internal.app.ResolverActivity")).isChooser)
        XCTAssertTrue(try XCTUnwrap(LinkComponent(flattened: "android/com.android.internal.app.ChooserActivity")).isChooser)
        XCTAssertTrue(try XCTUnwrap(LinkComponent(flattened: "com.android.intentresolver/.ChooserActivity")).isChooser)
        let forwarder = try XCTUnwrap(LinkComponent(flattened: "android/com.android.internal.app.IntentForwarderActivity"))
        XCTAssertTrue(forwarder.isFrameworkForwarder)
        XCTAssertFalse(forwarder.isChooser)
        XCTAssertNil(LinkComponent(flattened: "No activity found"))
    }

    func testHostClaims() throws {
        let component = try XCTUnwrap(LinkComponent(flattened: "com.example/.Main"))
        XCTAssertFalse(LinkCandidate(component: component, match: 0x208000).claimsHost)
        XCTAssertTrue(LinkCandidate(component: component, match: 0x308000).claimsHost)
        XCTAssertTrue(LinkCandidate(component: component, match: 0x508000).claimsHost)
    }

    // MARK: - SOURCE-DERIVED launch output

    /// SOURCE-DERIVED: ActivityManagerShellCommand android-9.0.0_r1:552–569,
    /// the `-W` block of API 28 and older (ThisTime, no LaunchState).
    func testTheAPI28WaitBlock() {
        let output = """
        Starting: Intent { act=android.intent.action.VIEW cat=[android.intent.category.BROWSABLE] dat=https://example.com/... }
        Status: ok
        Activity: com.example.browser/com.example.browser.app.Main
        ThisTime: 412
        TotalTime: 412
        WaitTime: 430
        Complete
        @@devicehubpro:link:exit=0

        """
        let result = LinkLaunchResult.parse(output)
        XCTAssertEqual(result.outcome, .started)
        XCTAssertNil(result.launchState)
        XCTAssertEqual(result.activity?.package, "com.example.browser")
        XCTAssertEqual(result.thisTimeMs, 412)
        XCTAssertEqual(result.totalTimeMs, 412)
        XCTAssertEqual(result.waitTimeMs, 430)
        XCTAssertTrue(result.completed)
    }

    /// SOURCE-DERIVED: the same block through a pre-N PTY shell (CRLF line
    /// ends, no exit marker from adb).
    func testCarriageReturnsArePartOfTheLineBreak() {
        let output = "Status: ok\r\nActivity: com.example/.Main\r\nThisTime: 5\r\nTotalTime: 5\r\nWaitTime: 9\r\nComplete\r\n"
        let result = LinkLaunchResult.parse(output)
        XCTAssertEqual(result.outcome, .started)
        XCTAssertEqual(result.activity?.flattened, "com.example/.Main")
        XCTAssertEqual(result.waitTimeMs, 9)
        XCTAssertNil(result.exitCode)
    }

    /// SOURCE-DERIVED: ActivityManagerShellCommand android-16.0.0_r1:947
    /// (`Status: timeout` when the wait gave up before the first frame).
    func testATimeout() {
        let output = """
        Starting: Intent { act=android.intent.action.VIEW cat=[android.intent.category.BROWSABLE] dat=myapp://x/... }
        Status: timeout
        LaunchState: COLD
        Activity: com.example/.Main
        WaitTime: 10012
        Complete
        @@devicehubpro:link:exit=0

        """
        let result = LinkLaunchResult.parse(output)
        XCTAssertEqual(result.outcome, .started)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.launchState, .cold)
        XCTAssertNil(result.totalTimeMs)
    }

    /// SOURCE-DERIVED: ShellCommand android-10.0.0_r1:105–120 (API 29 and
    /// older): `Security exception: <msg>`, a blank line and the stack;
    /// the message is ActivityTaskSupervisor's (android-16.0.0_r1:1199–1202).
    func testASecurityExceptionIsARefusal() {
        let message = "Permission Denial: starting Intent { act=android.intent.action.VIEW dat=myapp://x/... flg=0x10000000 cmp=com.example/.Secret } from null (pid=4242, uid=2000) not exported from uid 10183"
        let output = """
        Starting: Intent { act=android.intent.action.VIEW dat=myapp://x/... }
        Security exception: \(message)

        java.lang.SecurityException: \(message)
        \tat com.android.server.am.ActivityStackSupervisor.checkStartAnyActivityPermission(ActivityStackSupervisor.java:1043)
        \tat com.android.server.am.ActivityStarter.startActivity(ActivityStarter.java:760)
        @@devicehubpro:link:exit=255

        """
        let result = LinkLaunchResult.parse(output)
        XCTAssertEqual(result.outcome, .refused(message))
        XCTAssertEqual(result.exitCode, 255)
    }

    /// SOURCE-DERIVED: BasicShellCommandHandler android-11.0.0_r1:107 and
    /// android-16.0.0_r1:95–107 (API 30+): a blank line, `Exception
    /// occurred while executing 'start':` and the stack.
    func testAnExceptionWhileExecutingIsARefusal() {
        let message = "Permission Denial: starting Intent { act=android.intent.action.VIEW dat=myapp://x/... flg=0x10000000 cmp=com.example/.Secret } from null (pid=4242, uid=2000) not exported from uid 10183"
        let output = """
        Starting: Intent { act=android.intent.action.VIEW dat=myapp://x/... }

        Exception occurred while executing 'start':
        java.lang.SecurityException: \(message)
        \tat com.android.server.wm.ActivityTaskSupervisor.checkStartAnyActivityPermission(ActivityTaskSupervisor.java:1206)
        @@devicehubpro:link:exit=255

        """
        XCTAssertEqual(LinkLaunchResult.parse(output).outcome, .refused(message))
    }

    /// SOURCE-DERIVED: ActivityManagerShellCommand android-16.0.0_r1:880–884
    /// (START_SWITCHES_CANCELED; the double space is in the source).
    func testAnotherWarning() {
        let output = """
        Starting: Intent { act=android.intent.action.VIEW dat=myapp://x/... }
        Warning: Activity not started because the  current activity is being kept for the user.
        Status: ok
        LaunchState: UNKNOWN (0)
        WaitTime: 12
        Complete
        @@devicehubpro:link:exit=0

        """
        XCTAssertEqual(
            LinkLaunchResult.parse(output).outcome,
            .otherWarning("Activity not started because the  current activity is being kept for the user.")
        )
    }

    func testUnrecognisedOutputIsARefusal() {
        XCTAssertEqual(
            LinkLaunchResult.parse("/system/bin/sh: am: inaccessible or not found\n@@devicehubpro:link:exit=127\n").outcome,
            .refused("am printed nothing Device Hub Pro recognises: /system/bin/sh: am: inaccessible or not found")
        )
        XCTAssertEqual(LinkLaunchResult.parse("").outcome, .refused("am printed nothing"))
    }

    /// Lines end at LF, CR LF and CR only: a link's U+2028 or NEL, echoed
    /// in `Intent { … }`, stays inside its line.
    func testOnlyLineFeedsAndCarriageReturnsEndALine() {
        XCTAssertEqual(LinkCommands.lines("a\nb\r\nc\rd\u{2028}e\u{85}f\u{0B}g"), ["a", "b", "c", "d\u{2028}e\u{85}f\u{0B}g"])
        XCTAssertEqual(LinkCommands.lines("a\n"), ["a", ""])
    }

    /// SOURCE-DERIVED: am's own lines (ActivityManagerShellCommand
    /// android-16.0.0_r1:874–956) in orders an echo that escaped
    /// `safeStringEchoes` would produce, and the exit status each release
    /// gives (`LinkCommands`): a non-zero status admits only an error (API
    /// 24+), status 0 no error (API 35+).
    func testTheExitStatusCrossChecksTheLines() {
        let warningThenError = """
        Warning: Activity not started, its current task has been brought to the front
        Error: Activity not started, unable to resolve Intent { act=android.intent.action.VIEW dat=myapp://x/... }
        @@devicehubpro:link:exit=1

        """
        XCTAssertEqual(LinkLaunchResult.parse(warningThenError, apiLevel: 35).outcome, .notResolved)
        XCTAssertEqual(LinkLaunchResult.parse(warningThenError, apiLevel: 24).outcome, .notResolved)
        XCTAssertEqual(LinkLaunchResult.parse(warningThenError).outcome, .broughtToFront, "no level: the lines decide")
        XCTAssertEqual(LinkLaunchResult.parse(warningThenError, apiLevel: 23).outcome, .broughtToFront)

        let errorThenStatus = """
        Error: Activity not started, unable to resolve Intent { act=android.intent.action.VIEW dat=myapp://x/... }
        Status: ok
        LaunchState: COLD
        Activity: com.example/.Main
        TotalTime: 300
        WaitTime: 310
        Complete
        @@devicehubpro:link:exit=0

        """
        XCTAssertEqual(LinkLaunchResult.parse(errorThenStatus, apiLevel: 35).outcome, .started)
        XCTAssertEqual(
            LinkLaunchResult.parse(errorThenStatus, apiLevel: 34).outcome,
            .notResolved,
            "API 34 and older exit 0 after an error"
        )

        XCTAssertEqual(
            LinkLaunchResult.parse("Status: ok\n@@devicehubpro:link:exit=255\n", apiLevel: 30).outcome,
            .refused("am exited with status 255")
        )
        // Status 0 and nothing but an error: the error stands.
        XCTAssertEqual(
            LinkLaunchResult.parse("Error: Activity not started, unable to resolve Intent { }\n@@devicehubpro:link:exit=0\n", apiLevel: 36)
                .outcome,
            .notResolved
        )
    }

    /// SOURCE-DERIVED: Uri.toSafeString android-12.0.0_r1:399–440 prints the
    /// decoded path and query of a custom scheme, so on API 32 and older a
    /// `%0A` there reaches am's output; the request's echo is flattened
    /// before the lines are read (API 23's PTY turns the line feed into CR
    /// LF: flattened too).
    func testAnEchoedPathIsNotReadAsLines() throws {
        let request = try LinkRequest(
            "myapp://share/a%0AWarning:%20Activity%20not%20started,%20its%20current%20task%20has%20been%20brought%20to%20the%20front",
            apiLevel: 32
        )
        let intent = "Intent { act=android.intent.action.VIEW cat=[android.intent.category.BROWSABLE] "
            + "dat=myapp://share/a\nWarning: Activity not started, its current task has been brought to the front flg=0x10000000 }"
        let api32 = """
        Starting: \(intent)
        Status: ok
        LaunchState: COLD
        Activity: com.example/.ShareActivity
        TotalTime: 212
        WaitTime: 230
        Complete
        @@devicehubpro:link:exit=0

        """
        XCTAssertEqual(LinkLaunchResult.parse(api32, request: request).outcome, .started)
        XCTAssertEqual(LinkLaunchResult.parse(api32).outcome, .broughtToFront, "what the echo reads as unflattened")

        let api23 = api32.replacingOccurrences(of: "\n", with: "\r\n")
        let result = LinkLaunchResult.parse(api23, request: request)
        XCTAssertEqual(result.outcome, .started)
        XCTAssertEqual(result.activity?.flattened, "com.example/.ShareActivity")
    }

    // MARK: - SOURCE-DERIVED preview output

    /// SOURCE-DERIVED: a build's own resolver (`config_customResolverActivity`,
    /// PackageManagerService android-16.0.0_r1:2217–2222, 7947–7973) takes
    /// the place of ResolverActivity in the capture `preview-chooser`, with
    /// the same `match=0x0 … isDefault=false` line; the cross-profile
    /// forwarder prints `match=0x0` with `isDefault=true` (ComputerEngine
    /// android-16.0.0_r1:1809–1812) and is not the chooser.
    func testAVendorResolverIsTheChooser() throws {
        let vendor = """
        priority=0 preferredOrder=0 match=0x0 specificIndex=-1 isDefault=false
        com.vendor.resolver/.VendorResolverActivity
        """
        XCTAssertEqual(
            LinkPreview.parseResolution(vendor),
            .chooser(try XCTUnwrap(LinkComponent(flattened: "com.vendor.resolver/.VendorResolverActivity")))
        )
        let forwarder = """
        priority=0 preferredOrder=0 match=0x0 specificIndex=-1 isDefault=true
        android/com.android.internal.app.IntentForwarderActivity
        """
        guard case .activity(let candidate) = LinkPreview.parseResolution(forwarder) else {
            return XCTFail("the forwarder is an activity")
        }
        XCTAssertTrue(candidate.component.isFrameworkForwarder)
    }

    /// Below API 24 the script prints the level and empty sections.
    func testNoPreviewBeforeAPI24() {
        let preview = LinkPreview.parse("@@devicehubpro:link:api\n23\n@@devicehubpro:link:resolve\n@@devicehubpro:link:candidates\n")
        XCTAssertEqual(preview.apiLevel, 23)
        XCTAssertEqual(preview.resolution, .unavailable)
        XCTAssertEqual(preview.candidates, [])
        XCTAssertEqual(LinkPreview.parse("error: closed\n").resolution, .unreadable("no API level"))
    }

    /// SOURCE-DERIVED: DomainVerificationDebug android-16.0.0_r1:196–204,
    /// 284–305 — `*.` wildcard domains in the state and selection lists and
    /// a wildcard among the invalid ones. The verifier declares no
    /// wildcard, so this is the one App Links block not captured (the
    /// verifier's states are, in LinksDeviceOutputTests).
}
