import XCTest
@testable import DeviceHubProKit

/// The Links calls against a live emulator. Emulators only
/// (`LiveTestDevices.allowed`, then `isEmulator`): a phone is never touched,
/// even when pinned. The class changes no settings. Every test but one
/// launches nothing (`am to-uri`, links nothing resolves, previews and App
/// Links reads); `testOpeningAVerifierLinkDeliversItByteForByte` opens a
/// link in the Device Hub Pro verifier, only while the launcher or the verifier
/// is on top (another app on top belongs to someone else: the test skips),
/// and puts back what it changed: the task it created, the verifier process
/// it started (only while no other verifier task exists), and the launcher
/// when it was on top. It never clears logcat (other sessions share it).
///
/// `DHP_CAPTURE_LINKS_FIXTURES=<dir>` also writes the non-launching
/// previews', App Links reads', Opens' and echoes' commands and outputs
/// there (`testCaptureFixtures`), to recapture the `links` fixtures on
/// another image. The Opens that launch apps, and the App Links states set
/// from the shell, are taken by hand.
final class LinksIntegrationTests: XCTestCase {
    private static let verifier = "com.devicehubpro.verifier"

    private func onlineEmulator() async throws -> (AdbClient, String) {
        guard let adb = AdbClient.locate() else { throw XCTSkip("adb not found") }
        let devices = try await adb.listDevices()
        guard let serial = LiveTestDevices.allowed(devices).first(where: \.isEmulator)?.serial else {
            throw XCTSkip("no online emulator")
        }
        return (adb, serial)
    }

    private func apiLevel(_ adb: AdbClient, _ serial: String) async throws -> Int {
        let text = try await adb.shell(serial: serial, ["getprop", "ro.build.version.sdk"])
        return try XCTUnwrap(Int(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// `am to-uri` prints `intent.toUri(0)`: for a VIEW intent with only
    /// data, the data string verbatim.
    private static func echoScript(_ word: String) -> String {
        "am to-uri -a android.intent.action.VIEW -d " + word
    }

    // MARK: - Shell words (non-launching)

    func testEveryShellMetacharacterReachesAmVerbatim() async throws {
        let (adb, serial) = try await onlineEmulator()
        let corpus = [
            "myapp://x/'single'\"double\"\\back|pipe>gt<lt!bang*glob~tilde{a,b}",
            "myapp://x/$(touch /data/local/tmp/aqa_links_pwned)/`id`/${PATH}/$HOME",
            "myapp://x/;echo INJECTED;",
            "https://example.com/a b?q=1&r=2#frag",
            "--es evil 1",
            "https://example.com/ünïcödé/çğış?q=日本語&e=😀",
            "myapp://ü/;echo INJECTED;$(id)`id`'q'\"d\"\\b ${HOME}&x=1#f",
            "myapp://e\u{301}/\u{E9}/👩‍👩‍👧",
            "myapp://עברית/مرحبا?x=' $ ` ; & # ? \\",
        ]
        for uri in corpus {
            let output = try await adb.shell(serial: serial, [Self.echoScript(AdbClient.shellWord(uri))])
            XCTAssertEqual(Array(output.utf8), Array((uri + "\n").utf8), uri)
        }
        let probe = try await adb.shell(serial: serial, ["ls /data/local/tmp/aqa_links_pwned 2>&1; true"])
        XCTAssertTrue(probe.contains("No such file"), "the substitution ran: \(probe)")

        // The finding shellWord guards: quoted as is, a non-ASCII argument
        // reaches the device decomposed (Foundation.Process).
        let quoted = try await adb.shell(serial: serial, [Self.echoScript(AdbClient.shellQuoted("https://example.com/ü"))])
        XCTAssertEqual(Array(quoted.utf8.suffix(4)), [0x75, 0xCC, 0x88, 0x0A], "u + U+0308, not U+00FC")
    }

    // MARK: - Resolution (non-launching)

    func testAnUnknownSchemeIsNotResolved() async throws {
        let (adb, serial) = try await onlineEmulator()
        let request = try LinkRequest("aqa-nohandler://live/\(UUID().uuidString)", apiLevel: nil)
        let result = try await adb.openLink(serial: serial, request)
        XCTAssertEqual(result.outcome, .notResolved)
        if try await apiLevel(adb, serial) >= LinkCommands.previewMinimumAPI {
            let preview = try await adb.linkPreview(serial: serial, request)
            XCTAssertEqual(preview.resolution, LinkPreview.Resolution.none)
            XCTAssertEqual(preview.candidates, [])
        }
    }

    func testATargetWithoutAMatchingActivityIsNotResolved() async throws {
        let (adb, serial) = try await onlineEmulator()
        let request = try LinkRequest("https://example.com/", package: "com.android.shell", apiLevel: nil)
        let result = try await adb.openLink(serial: serial, request)
        XCTAssertEqual(result.outcome, .notResolved)
    }

    // MARK: - Open (launches the verifier, then puts it back)

    private struct DeviceState {
        let verifierPids: String
        let launcherOnTop: Bool
        let verifierOnTop: Bool
        let verifierRootTasks: Set<Int>
    }

    /// The root tasks whose tasks run the verifier (`am stack list`).
    private static func verifierRootTasks(_ list: String) -> Set<Int> {
        var roots = Set<Int>()
        var current: Int?
        for line in list.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("RootTask id=") {
                current = ConditionsText.integer(after: "RootTask id", in: trimmed[...])
            } else if trimmed.hasPrefix("taskId="), trimmed.contains(" \(verifier)/"), let current {
                roots.insert(current)
            }
        }
        return roots
    }

    private static func verifierPids(_ adb: AdbClient, _ serial: String) async throws -> String {
        try await adb.shell(serial: serial, ["pidof \(verifier); true"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func deviceState(_ adb: AdbClient, _ serial: String) async throws -> DeviceState {
        let pids = try await Self.verifierPids(adb, serial)
        let top = try await adb.shell(serial: serial, [AppConditionsSnapshot.foregroundScript])
        let foreground = AppConditionsSnapshot.foregroundPackage(fromActivities: top)
        let home = try await adb.shell(serial: serial, ["cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>&1 | tail -n 1"])
        let launcher = home.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").first.map(String.init)
        let stacks = try await adb.shell(serial: serial, ["am stack list 2>&1; true"])
        return DeviceState(
            verifierPids: pids,
            launcherOnTop: foreground != nil && foreground == launcher,
            verifierOnTop: foreground == Self.verifier,
            verifierRootTasks: Self.verifierRootTasks(stacks)
        )
    }

    /// Puts back what the Open changed. The Open creates at most one
    /// verifier root task: exactly one new one is removed; more mean
    /// another session opened the verifier meanwhile, so none is removed
    /// and the process stays. The verifier is force-stopped only when this
    /// test started it (it was not running, and `pidof` still names the
    /// process read right after the Open). HOME when the launcher was on
    /// top.
    private static func restore(
        _ before: DeviceState,
        startedPids: String?,
        _ adb: AdbClient,
        _ serial: String
    ) async throws {
        let stacks = try await adb.shell(serial: serial, ["am stack list 2>&1; true"])
        let created = Self.verifierRootTasks(stacks).subtracting(before.verifierRootTasks)
        guard created.count <= 1 else { return }
        for root in created {
            _ = try await adb.shell(serial: serial, ["am stack remove \(root)"])
        }
        if before.verifierPids.isEmpty, let startedPids, !startedPids.isEmpty,
           try await verifierPids(adb, serial) == startedPids {
            _ = try await adb.shell(serial: serial, ["am force-stop \(Self.verifier)"])
        }
        if before.launcherOnTop {
            _ = try await adb.shell(serial: serial, ["input keyevent KEYCODE_HOME"])
        }
    }

    func testOpeningAVerifierLinkDeliversItByteForByte() async throws {
        let (adb, serial) = try await onlineEmulator()
        let level = try await apiLevel(adb, serial)
        guard level >= LinkCommands.previewMinimumAPI else { throw XCTSkip("the resolve check needs API 24") }
        let resolve = try await adb.shell(serial: serial, [
            "cmd package resolve-activity --brief -a android.intent.action.VIEW -d devicehubpro-verifier://link/x "
                + "-c android.intent.category.BROWSABLE -c android.intent.category.DEFAULT 2>&1",
        ])
        guard resolve.contains("\(Self.verifier)/") else {
            throw XCTSkip("the Device Hub Pro verifier with its Links filters is not installed (android/verifier/install.sh)")
        }

        let before = try await deviceState(adb, serial)
        // Another app on top belongs to someone else on a shared emulator:
        // the Open would put the verifier in front of it.
        guard before.launcherOnTop || before.verifierOnTop else {
            throw XCTSkip("neither the launcher nor the verifier is on top: the Open would cover another app")
        }
        let started = StartedPids()
        addTeardownBlock { try await Self.restore(before, startedPids: await started.value, adb, serial) }

        let nonce = UUID().uuidString
        let uri = "devicehubpro-verifier://link/live?n=\(nonce)&q=a b&x=ü&y=$(id)'\""
        let request = try LinkRequest(uri, apiLevel: level)
        let result = try await adb.openLink(serial: serial, request, apiLevel: level)
        if before.verifierPids.isEmpty {
            await started.set(try await Self.verifierPids(adb, serial))
        }
        switch result.outcome {
        case .started, .deliveredToTop, .broughtToFront:
            break
        default:
            XCTFail("\(result.outcome)")
        }
        XCTAssertEqual(result.activity?.package, Self.verifier)

        // The verifier logs every VIEW intent it receives; the last line with
        // this nonce ends with the exact URI.
        var line: String?
        for _ in 0..<20 {
            let log = try await adb.shell(serial: serial, ["logcat -d -s \(Self.logTag):I 2>&1 | grep -F \(nonce); true"])
            line = log.components(separatedBy: .newlines).last { $0.contains(nonce) }
            if line != nil { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        let logged = try XCTUnwrap(line, "the verifier logged no link with the nonce")
        XCTAssertTrue(logged.utf8.reversed().starts(with: ("link " + uri).utf8.reversed()), logged)
    }

    private static let logTag = "DeviceHubProVerifierLink"

    /// The verifier process the Open started, read right after it.
    private actor StartedPids {
        private(set) var value: String?

        func set(_ pids: String) {
            value = pids
        }
    }

    // MARK: - Fixtures

    /// Writes the non-launching commands and outputs behind the `links`
    /// fixtures when `DHP_CAPTURE_LINKS_FIXTURES` names a directory
    /// (read-only on the device).
    func testCaptureFixtures() async throws {
        guard let path = ProcessInfo.processInfo.environment["DHP_CAPTURE_LINKS_FIXTURES"], !path.isEmpty else {
            throw XCTSkip("set DHP_CAPTURE_LINKS_FIXTURES to capture")
        }
        let (adb, serial) = try await onlineEmulator()
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func capture(_ name: String, _ script: String) async throws {
            let output = try await adb.shell(serial: serial, [script])
            try Data(script.utf8).write(to: directory.appendingPathComponent("\(name).command.txt"))
            try Data(output.utf8).write(to: directory.appendingPathComponent("\(name).txt"))
        }
        let video = "https://video.example.com/watch?v=dQw4w9WgXcQ"
        let previews: [(String, String, Bool, String?)] = [
            ("preview-example", "https://example.com/", true, nil),
            ("preview-video-verified", video, true, nil),
            ("preview-video-in-browser", video, true, "com.example.browser"),
            ("preview-not-browsable", video, false, nil),
            ("preview-no-handler", "aqa-nohandler://open/item?id=42", true, nil),
            ("preview-package-mismatch", "https://example.com/", true, "com.example.video"),
            ("preview-chooser", "content://com.aqa.none/x", true, nil),
            ("preview-uppercase-scheme", "HTTPS://EXAMPLE.COM/", true, nil),
            ("preview-uppercase-host", "https://VIDEO.EXAMPLE.COM/watch?v=dQw4w9WgXcQ", true, nil),
            ("preview-intent-scheme", "intent://example.com/#Intent;scheme=https;end", true, nil),
            ("preview-backslash-host", #"https://evil.example\@video.example.com/watch?v=dQw4w9WgXcQ"#, true, nil),
            ("preview-percent-host", "https://www%2Evideo.example.com/watch?v=dQw4w9WgXcQ", true, nil),
            // The Device Hub Pro verifier's own filters (android/verifier).
            ("preview-verifier-app-link", "https://verifier.devicehubpro.test/a", true, "com.devicehubpro.verifier"),
            ("preview-verifier-nodefault", "devicehubpro-verifier://nodefault/x", true, nil),
            ("preview-verifier-single-label", "https://devicehubpro-verifier/x", true, nil),
        ]
        for (name, uri, browsable, package) in previews {
            let request = try LinkRequest(uri, browsable: browsable, package: package, apiLevel: nil)
            try await capture(name, LinkCommands.previewScript(request))
        }
        // Opens nothing resolves: am prints the decoded host back; the
        // verifier's filter without DEFAULT is never reached.
        let opens = [
            ("open-verifier-nodefault", "devicehubpro-verifier://nodefault/x"),
            (
                "open-injected-host",
                "aqa-nohandler://h%0AWarning:%20Activity%20not%20started,%20its%20current%20task%20has%20been%20brought%20to%20the%20front%0AStatus:%20ok%0AActivity:%20com.evil/.X%0Ax/p"
            ),
            (
                "open-encoded-line-separator",
                "aqa-nohandler://h%E2%80%A8Warning:%20Activity%20not%20started,%20intent%20has%20been%20delivered%20to%20currently%20running%20top-most%20instance.%E2%80%A8x/p"
            ),
        ]
        for (name, uri) in opens {
            try await capture(name, LinkCommands.openScript(try LinkRequest(uri, apiLevel: nil)))
        }
        let echoes = [
            ("echo-quotes", "myapp://x/'single'\"double\"\\back|pipe>gt<lt!bang*glob~tilde{a,b}"),
            ("echo-subst", "myapp://x/$(touch /data/local/tmp/aqa_pwned2)/`id`/${PATH}/$HOME"),
            ("echo-semicolon", "myapp://x/;touch /data/local/tmp/aqa_pwned;"),
            ("echo-space-amp-hash", "https://example.com/a b?q=1&r=2#frag"),
            ("echo-leading-dash", "--es evil 1"),
            ("echo-unicode-octal-word", "https://example.com/ünïcödé/çğış?q=日本語&e=😀"),
            ("echo-unicode-metachar-octal-word", "myapp://ü/;echo INJECTED;$(id)`id`'q'\"d\"\\b ${HOME}&x=1#f"),
        ]
        for (name, uri) in echoes {
            try await capture(name, Self.echoScript(AdbClient.shellWord(uri)))
        }
    }
}
