import XCTest
@testable import DeviceHubProKit

/// `SimctlClient` against a fake `simctl` that replays the real captures in
/// `Fixtures/ios27-simulator/` (provenance in `SimctlFixtureTests`). These
/// pin the argv production sends — the private set first, an explicit UDID,
/// never an implicit selector — and how exit codes and stderr turn into
/// typed errors.
final class SimctlClientTests: XCTestCase {
    private static let udid = SimctlFixtureTests.udid

    private static func fixture(_ folder: String, _ name: String) -> URL {
        SimctlFixtureTests.url(folder, name)
    }

    private func makeSet() throws -> URL {
        let set = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimctlClientTests-set-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        // Best effort: a leftover temporary folder must not fail the test.
        addTeardownBlock { try? FileManager.default.removeItem(at: set) }
        return set
    }

    // MARK: Argv

    func testEveryCallAddressesTheDeviceSetFirst() async throws {
        let set = try makeSet()
        let fake = try FakeTool(name: "simctl", rules: [
            .init("list -j devices", stdoutFile: Self.fixture("simctl-core", "simctl-list-j-devices.booted.json")),
            .init("ui \(Self.udid) appearance", stdoutFile: Self.fixture("controls", "simctl-ui-appearance.dark.stdout.txt")),
        ])
        let client = SimctlClient(simctlURL: fake.executableURL, deviceSet: set)

        let devices = try await client.listDevices()
        XCTAssertEqual(devices.map(\.udid), [Self.udid])
        let appearance = try await client.appearance(udid: Self.udid)
        XCTAssertEqual(appearance, .dark)

        XCTAssertEqual(fake.invocations, [
            ["--set", set.path, "list", "-j", "devices"],
            ["--set", set.path, "ui", Self.udid, "appearance"],
        ])
    }

    func testWithoutADeviceSetTheArgvStartsWithTheSubcommand() throws {
        let client = SimctlClient(simctlURL: URL(fileURLWithPath: "/usr/bin/false"))
        XCTAssertEqual(try client.commandLine(["list", "-j", "devices"]), ["list", "-j", "devices"])
    }

    /// Implicit selectors are refused before anything runs, wherever they
    /// appear and however they are spelled.
    func testImplicitSelectorsAreRefused() async throws {
        let fake = try FakeTool(name: "simctl", rules: [])
        let client = SimctlClient(simctlURL: fake.executableURL)
        for arguments in [
            ["shutdown", "booted"],
            ["ui", "BOOTED", "appearance"],
            ["io", "booted_phone", "screenshot", "x.png"],
            ["delete", "all"],
            ["delete", "unavailable"],
            ["privacy", Self.udid, "reset", "all", "com.example"],
        ] {
            do {
                _ = try await client.run(arguments)
                XCTFail("\(arguments) must be refused")
            } catch let error as SimctlClientError {
                guard case .refusedSelector = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(fake.calls, [], "nothing may reach simctl")
    }

    /// A device name is the user's to choose: `create` and `rename` pass a
    /// name spelled like a selector, since the device slot holds a UDID.
    /// The generic `run` still refuses it anywhere.
    func testDeviceNamesMaySpellASelector() async throws {
        let fake = try FakeTool(name: "simctl", rules: [
            .init("create", stdoutFile: Self.fixture("simctl-core", "simctl-create.stdout.txt")),
        ])
        let client = SimctlClient(simctlURL: fake.executableURL)
        let udid = try await client.create(
            name: "All",
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
        )
        try await client.rename(udid: udid, to: "Booted")
        do {
            _ = try await client.run(["rename", udid, "Booted"])
            XCTFail("the generic run must refuse it")
        } catch let error as SimctlClientError {
            XCTAssertEqual(error, .refusedSelector("Booted"))
        }
        XCTAssertEqual(fake.invocations, [
            ["create", "All", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "com.apple.CoreSimulator.SimRuntime.iOS-27-0"],
            ["rename", udid, "Booted"],
        ])
    }

    /// Typed calls take a simulator UDID and nothing else: not a device
    /// name, not a physical device's identifier.
    func testTypedCallsRequireASimulatorUDID() async throws {
        let fake = try FakeTool(name: "simctl", rules: [])
        let client = SimctlClient(simctlURL: fake.executableURL)
        for identifier in ["iPhone 17 Pro", "00008101-000A0C123456001E", ""] {
            do {
                try await client.shutdown(udid: identifier)
                XCTFail("\(identifier) must be refused")
            } catch let error as SimctlClientError {
                XCTAssertEqual(error, .invalidUDID(identifier))
            }
        }
        XCTAssertEqual(fake.calls, [])
    }

    func testDeveloperDirectoryReachesTheChild() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimctlClientTests-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Best effort: a leftover temporary folder must not fail the test.
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("simctl")
        try Data("#!/bin/sh\nprintf '%s|%s' \"$DEVELOPER_DIR\" \"$SIMCTL_CHILD_TZ\"\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let client = SimctlClient(
            simctlURL: script,
            developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer")
        )
        let output = try await client.run(["getenv", Self.udid, "HOME"], extraEnvironment: ["SIMCTL_CHILD_TZ": "America/New_York"])
        XCTAssertEqual(output.standardOutputText, "/Applications/Xcode.app/Contents/Developer|America/New_York")
    }

    // MARK: Failures

    /// A non-zero exit becomes the decoded `SimctlFailure` (the real stderr of
    /// `erase` on a booted device, exit 149).
    func testFailedCallsThrowTheDecodedFailure() async throws {
        let fake = try FakeTool(name: "simctl", rules: [
            .init(
                "erase \(Self.udid)",
                stdoutFile: nil,
                stderrFile: Self.fixture("simctl-core", "simctl-erase-booted.stderr.txt"),
                exitCode: 149
            ),
        ])
        let client = SimctlClient(simctlURL: fake.executableURL)
        do {
            try await client.erase(udid: Self.udid)
            XCTFail("expected the invalid-state failure")
        } catch let failure as SimctlFailure {
            XCTAssertEqual(failure.kind, .invalidState)
            XCTAssertEqual(failure.exitCode, 149)
            XCTAssertEqual(failure.arguments, ["erase", Self.udid])
            XCTAssertTrue(failure.description.contains("com.apple.CoreSimulator.SimError 405"), failure.description)
        }
    }

    /// `ui … content_size bogus` exits 0 with `Invalid argument` on stderr
    /// (the real capture); the typed setter still throws.
    func testUISetterTreatsExitZeroInvalidArgumentAsFailure() async throws {
        let fake = try FakeTool(name: "simctl", rules: [
            .init(
                "content_size",
                stdoutFile: nil,
                stderrFile: Self.fixture("controls", "simctl-ui-content_size-invalid.stderr.txt"),
                exitCode: 0
            ),
        ])
        let client = SimctlClient(simctlURL: fake.executableURL)
        do {
            try await client.setContentSize(udid: Self.udid, .large)
            XCTFail("expected the invalid-argument failure")
        } catch let failure as SimctlFailure {
            XCTAssertEqual(failure.kind, .invalidArgument)
            XCTAssertEqual(failure.exitCode, 0)
        }
    }

    /// Values simctl would accept silently are refused before a call.
    func testValuesSimctlDoesNotValidateAreCheckedHere() async throws {
        let fake = try FakeTool(name: "simctl", rules: [])
        let client = SimctlClient(simctlURL: fake.executableURL)
        await XCTAssertThrowsErrorAsync(try await client.setAppearance(udid: Self.udid, .unknown))
        await XCTAssertThrowsErrorAsync(try await client.setContentSize(udid: Self.udid, .unsupported))
        await XCTAssertThrowsErrorAsync(try await client.setLocation(udid: Self.udid, latitude: 999, longitude: 999))
        XCTAssertEqual(fake.calls, [])

        try await client.setLocation(udid: Self.udid, latitude: 41.0082, longitude: 28.9784)
        XCTAssertEqual(fake.invocations.last, ["location", Self.udid, "set", "41.008200,28.978400"])
    }

    /// A call that outlives its bound is terminated and named in the error.
    func testCallsAreBoundedByTheTimeout() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimctlClientTests-slow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Best effort: a leftover temporary folder must not fail the test.
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("simctl")
        try Data("#!/bin/sh\nexec sleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let client = SimctlClient(simctlURL: script, commandTimeout: .milliseconds(300))
        let started = Date()
        do {
            _ = try await client.listDevices()
            XCTFail("expected a timeout")
        } catch ProcessRunnerError.timedOut(let command, let seconds) {
            XCTAssertEqual(command, "simctl list -j devices")
            XCTAssertEqual(seconds, .milliseconds(300))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: Typed calls

    func testLifecycleArgv() async throws {
        let fake = try FakeTool(name: "simctl", rules: [
            .init("create", stdoutFile: Self.fixture("simctl-core", "simctl-create.stdout.txt")),
        ])
        let client = SimctlClient(simctlURL: fake.executableURL)
        let udid = try await client.create(
            name: "DeviceHubPro-Test",
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
        )
        XCTAssertEqual(udid, Self.udid)
        try await client.boot(udid: udid)
        try await client.shutdown(udid: udid)
        try await client.rename(udid: udid, to: "Renamed")
        try await client.delete(udid: udid)
        XCTAssertEqual(fake.invocations, [
            ["create", "DeviceHubPro-Test", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "com.apple.CoreSimulator.SimRuntime.iOS-27-0"],
            ["boot", udid],
            ["shutdown", udid],
            ["rename", udid, "Renamed"],
            ["delete", udid],
        ])
    }

    func testAppCallsParseTheirOutput() async throws {
        let fake = try FakeTool(name: "simctl", rules: [
            .init("listapps", stdoutFile: Self.fixture("simctl-core", "simctl-listapps.stdout.txt")),
            .init("appinfo", stdoutFile: Self.fixture("simctl-core", "simctl-appinfo-mobilesafari.stdout.txt")),
            .init("groups", stdoutFile: Self.fixture("simctl-core", "simctl-get_app_container-groups.stdout.txt")),
            .init("mobilesafari data", stdoutFile: Self.fixture("simctl-core", "simctl-get_app_container-data.stdout.txt")),
            .init("launch", stdoutFile: Self.fixture("simctl-core", "simctl-launch-mobilesafari.stdout.txt")),
            .init(
                "terminate",
                stdoutFile: nil,
                stderrFile: Self.fixture("simctl-core", "simctl-terminate-not-running.stderr.txt"),
                exitCode: 3
            ),
        ])
        let client = SimctlClient(simctlURL: fake.executableURL)
        let apps = try await client.listApps(udid: Self.udid)
        XCTAssertEqual(apps.count, 39)
        let safari = try await client.appInfo(udid: Self.udid, bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertEqual(safari.displayName, "Safari")
        let groups = try await client.groupContainers(udid: Self.udid, bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertEqual(groups.count, 3)
        let data = try await client.appContainerPath(udid: Self.udid, bundleIdentifier: "com.apple.mobilesafari", container: .data)
        XCTAssertTrue(data.hasSuffix("/Containers/Data/Application/DEEC28D4-5835-4EBF-8A41-D5F388E542AC"), data)
        let pid = try await client.launch(udid: Self.udid, bundleIdentifier: "com.apple.mobilesafari", terminateRunning: true)
        XCTAssertEqual(pid, 76487)
        XCTAssertEqual(
            fake.invocations.first { $0.first == "launch" },
            ["launch", "--terminate-running-process", Self.udid, "com.apple.mobilesafari"]
        )
        do {
            try await client.terminate(udid: Self.udid, bundleIdentifier: "com.apple.mobilesafari")
            XCTFail("expected not-found")
        } catch let failure as SimctlFailure {
            XCTAssertEqual(failure.kind, .notFound)
        }
    }

    func testStatusBarAndLocationReads() async throws {
        let fake = try FakeTool(name: "simctl", rules: [
            .init("status_bar \(Self.udid) list", stdoutFile: Self.fixture("controls", "simctl-status_bar-list.override-full.stdout.txt")),
            .init("location \(Self.udid) list", stdoutFile: Self.fixture("controls", "simctl-location-list.stdout.txt")),
        ])
        let client = SimctlClient(simctlURL: fake.executableURL)
        let overrides = try await client.statusBarOverrides(udid: Self.udid)
        XCTAssertEqual(overrides.batteryLevel, 100)
        let scenarios = try await client.locationScenarios(udid: Self.udid)
        XCTAssertEqual(scenarios.count, 4)
        try await client.clearStatusBar(udid: Self.udid)
        XCTAssertEqual(fake.invocations.last, ["status_bar", Self.udid, "clear"])
    }

    /// `bootStatus` streams the real cold-boot output: every update reaches
    /// the callback in order and the last one (Finished) is returned.
    func testBootStatusStreamsUpdates() async throws {
        let fake = try FakeTool(name: "simctl", rules: [
            .init("bootstatus", stdoutFile: Self.fixture("simctl-core", "simctl-bootstatus-b.cold-first-boot.stdout.txt")),
        ])
        let client = SimctlClient(simctlURL: fake.executableURL)
        let collected = UpdateBox()
        let last = try await client.bootStatus(udid: Self.udid, bootIfNeeded: true) { collected.append($0) }
        XCTAssertEqual(last?.isFinished, true)
        XCTAssertEqual(collected.updates.count, 21)
        XCTAssertEqual(fake.invocations, [["bootstatus", Self.udid, "-b"]])
    }

    /// A failed `bootstatus` throws its decoded failure. The stderr is the
    /// real answer of `simctl --set <empty private set> bootstatus
    /// 00000000-0000-0000-0000-000000000000` (exit 148, nothing on stdout),
    /// captured on 2026-09-25 with Xcode 27.0 27A266a, CoreSimulator 1171.7.
    func testBootStatusFailureCarriesTheError() async throws {
        let fake = try FakeTool(name: "simctl", rules: [
            .init(
                "bootstatus",
                stdoutFile: nil,
                stderrFile: Self.fixture("simctl-core", "simctl-bootstatus-invalid-device.stderr.txt"),
                exitCode: 148
            ),
        ])
        let client = SimctlClient(simctlURL: fake.executableURL)
        do {
            _ = try await client.bootStatus(udid: Self.udid)
            XCTFail("expected a failure")
        } catch let failure as SimctlFailure {
            XCTAssertEqual(failure.kind, .invalidDevice)
        }
    }

    /// A recorder that fails on its own surfaces its decoded failure. The
    /// stderr is the real answer of `simctl --set <empty private set> io
    /// 00000000-0000-0000-0000-000000000000 recordVideo --codec=hevc <file>`
    /// (exit 148, nothing on stdout, no file written), captured on
    /// 2026-09-25 with Xcode 27.0 27A266a, CoreSimulator 1171.7.
    func testRecordVideoFailureIsThrown() async throws {
        let fake = try FakeTool(name: "simctl", rules: [
            .init(
                "recordVideo",
                stdoutFile: nil,
                stderrFile: Self.fixture("simctl-core", "simctl-io-recordVideo-invalid-device.stderr.txt"),
                exitCode: 148
            ),
        ])
        let client = SimctlClient(simctlURL: fake.executableURL)
        do {
            try await client.recordVideo(udid: Self.udid, to: URL(fileURLWithPath: "/tmp/x.mov"))
            XCTFail("expected the failure")
        } catch let failure as SimctlFailure {
            XCTAssertEqual(failure.kind, .invalidDevice)
        }
    }

    // MARK: Open URL

    /// `openurl <UDID> <url>` (a success prints nothing: measured on
    /// 2026-09-26, rc 0 with empty stdout and stderr). An unknown scheme is
    /// the real answer `simctl-openurl-unknown-scheme.stderr.txt`, captured
    /// on 2026-09-26 for `openurl <UDID> nosuchscheme-aqa://x` (exit 115;
    /// provenance in `SimctlAppsFixtureTests`), byte-exact. The Open URL
    /// sheet's text becomes a link through `SimctlClient.link`: trimmed,
    /// with a scheme, not a host file, and percent-encoded where a URL
    /// cannot hold a character, as simctl encodes its own argument
    /// (`simctl-openurl-invalid.stderr.txt`: "failed to open
    /// not%20a%20url").
    func testOpenURLArgvAndFailures() async throws {
        let fake = try FakeTool(name: "simctl", rules: [
            .init(
                "nosuchscheme-aqa",
                stdoutFile: nil,
                stderrFile: Self.fixture("simctl-core", "simctl-openurl-unknown-scheme.stderr.txt"),
                exitCode: 115
            ),
            .init("openurl"),
        ])
        let client = SimctlClient(simctlURL: fake.executableURL)
        try await client.openURL(udid: Self.udid, url: try XCTUnwrap(SimctlClient.link(" https://example.com/a?b=c\n")))
        XCTAssertEqual(fake.invocations, [["openurl", Self.udid, "https://example.com/a?b=c"]])

        do {
            try await client.openURL(udid: Self.udid, url: try XCTUnwrap(SimctlClient.link("nosuchscheme-aqa://x")))
            XCTFail("expected the failure")
        } catch let failure as SimctlFailure {
            XCTAssertEqual(failure.error, SimctlErrorReference(domain: "LSApplicationWorkspaceErrorDomain", code: 115))
            XCTAssertEqual(failure.message, "Simulator device failed to open nosuchscheme-aqa://x.")
        }

        for refused in ["not a url", "example.com", "-u:x", "://x", "1a:b", "file:///tmp/a.html", "https://exa mple.com"] {
            XCTAssertNil(SimctlClient.link(refused), refused)
            if let url = URL(string: refused) {
                await XCTAssertThrowsErrorAsync(try await client.openURL(udid: Self.udid, url: url), refused)
            }
        }
        XCTAssertEqual(fake.invocations.count, 2, "a refused URL never runs simctl")
        // Why each is refused: the sheet says so rather than staying off.
        XCTAssertEqual(SimctlClient.readLink("example.com"), .failure(.noScheme))
        XCTAssertEqual(SimctlClient.readLink("-u:x"), .failure(.noScheme))
        XCTAssertEqual(SimctlClient.readLink("file:///tmp/a.html"), .failure(.hostFile))
        XCTAssertEqual(SimctlClient.readLink("FILE://exa mple/a"), .failure(.hostFile), "a file URL that reads as no URL")
        XCTAssertEqual(SimctlClient.readLink("https://exa mple.com"), .failure(.unreadable))
        XCTAssertEqual(SimctlClient.readLink("myapp://open page"), .failure(.unreadable))
        XCTAssertEqual(SimctlClient.readLink("https://example.com:abc"), .failure(.unreadable))
        XCTAssertEqual(
            SimctlClient.readLink(" myapp://open/a page ").map(\.absoluteString),
            .success("myapp://open/a%20page")
        )
        XCTAssertEqual(SimctlClient.link("myapp://orders/42?ref=ş")?.absoluteString, "myapp://orders/42?ref=%C5%9F")
        XCTAssertEqual(SimctlClient.link("tel:123")?.absoluteString, "tel:123")
        XCTAssertTrue(SimctlClient.hasScheme("myapp+x.y-z:path"))
        XCTAssertTrue(SimctlClient.hasScheme("tel:123"))
        XCTAssertFalse(SimctlClient.hasScheme("şema:x"))
    }

    // MARK: Screenshot

    /// A screenshot of a screen that is off: simctl's real stderr
    /// `simctl-io-screenshot-screen-off-timeout.stderr.txt` (`io
    /// screenConfig power off`, then `io <UDID> screenshot`: exit 60 after
    /// 61 s), captured on 2026-09-25 from a throwaway iPhone 18 Pro on iOS
    /// 27.0 (24A434), Xcode 27.0 (27A266a), byte-exact. The app bounds the
    /// call well below the 61 s (`SimulatorCanvasController.simctlScreenshot`);
    /// this pins the failure simctl reports when it does answer.
    func testAScreenshotOfAScreenThatIsOffFails() async throws {
        let fake = try FakeTool(name: "simctl", rules: [
            .init(
                "screenshot",
                stdoutFile: nil,
                stderrFile: Self.fixture("simctl-core", "simctl-io-screenshot-screen-off-timeout.stderr.txt"),
                exitCode: 60
            ),
        ])
        let client = SimctlClient(simctlURL: fake.executableURL)
        do {
            try await client.screenshot(udid: Self.udid, to: URL(fileURLWithPath: "/tmp/x.png"))
            XCTFail("expected the failure")
        } catch let failure as SimctlFailure {
            XCTAssertEqual(failure.exitCode, 60)
            XCTAssertEqual(failure.error, SimctlErrorReference(domain: "NSPOSIXErrorDomain", code: 60))
            XCTAssertTrue(failure.message.contains("Timeout waiting for screen surfaces"), failure.message)
        }
        XCTAssertEqual(fake.invocations, [["io", Self.udid, "screenshot", "--type=png", "/tmp/x.png"]])
    }

    // MARK: Pasteboard

    /// The captures behind the pasteboard tests, from my own default-set
    /// iPhone 17 Pro on iOS 27.0 (24A434), Xcode 27.0 (27A266a), 2026-09-26,
    /// byte-exact: `simctl spawn <UDID> notifyutil -w
    /// com.apple.pasteboard.notify.changed` while the host ran `simctl
    /// pbcopy` twice, then SIGTERM (stdout: the name once per copy; stderr:
    /// simctl's line about the child's signal); and `simctl pbpaste <UDID>`
    /// after the second copy (Turkish letters, UTF-8, no newline). The
    /// capture's simctl ended on the signal, so its exit status was never
    /// captured and is not judged: the fake exits 0 only to end the watch.
    func testTheWatchReportsEachPasteboardChange() async throws {
        let fake = try FakeTool(name: "simctl", rules: [
            .init(
                "notifyutil -w",
                stdoutFile: Self.fixture("simctl-core", "simctl-spawn-notifyutil-w-pasteboard-changed.stdout.txt"),
                stderrFile: Self.fixture("simctl-core", "simctl-spawn-notifyutil-w-pasteboard-changed.stderr.txt"),
                exitCode: 0
            ),
        ])
        let client = SimctlClient(simctlURL: fake.executableURL)
        let posts = PostCounter()
        _ = try await client.watchDarwinNotification(
            udid: Self.udid,
            name: SimctlClient.pasteboardChangedNotification
        ) {
            posts.increment()
        }
        XCTAssertEqual(posts.value, 2, "one per copy; the stderr line is not a post")
        XCTAssertEqual(fake.invocations, [[
            "spawn", Self.udid, "notifyutil", "-w", "com.apple.pasteboard.notify.changed",
        ]])
        await XCTAssertThrowsErrorAsync(try await client.watchDarwinNotification(udid: Self.udid, name: "-x") {})
        await XCTAssertThrowsErrorAsync(try await client.watchDarwinNotification(udid: "booted", name: "a.b") {})
    }

    func testPasteboardReadsUTF8() async throws {
        let fake = try FakeTool(name: "simctl", rules: [
            .init("pbpaste", stdoutFile: Self.fixture("simctl-core", "simctl-pbpaste.turkish.stdout.txt")),
        ])
        let text = try await SimctlClient(simctlURL: fake.executableURL).pasteboard(udid: Self.udid)
        XCTAssertEqual(text, "İkinci kopya: ğüıöç")
    }

    private final class PostCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private final class UpdateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [SimulatorBootStatus] = []

        func append(_ update: SimulatorBootStatus) {
            lock.lock()
            stored.append(update)
            lock.unlock()
        }

        var updates: [SimulatorBootStatus] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}

/// `XCTAssertThrowsError` for async expressions.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error. \(message)", file: file, line: line)
    } catch {
        // expected
    }
}
