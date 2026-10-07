import CoreVideo
import ImageIO
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// A simulator's media on a model whose simctl is a stub replaying the
/// lifecycle captures (a booted iPhone 17 Pro on iOS 27.0 in a private set,
/// followed to ready; provenance in `SimulatorLifecycleFixtureTests`) and
/// whose sessions are `FakeSimulatorSession`s: the screenshot from the live
/// canvas's frame or from `simctl io screenshot`, copy, and the recording
/// through the app's recorder or `simctl io recordVideo`. No adb is run.
@MainActor
final class SimulatorMediaTests: XCTestCase {
    static let udid = SimulatorFixtures.udid

    /// The model and what the test reads back from it.
    @MainActor
    final class Harness {
        let model: AppModel
        let simctl: StubTool
        let pasteboard: TestPasteboard
        let picker: TestPicker
        var sessions: [FakeSimulatorSession] = []

        init(model: AppModel, simctl: StubTool, pasteboard: TestPasteboard, picker: TestPicker) {
            self.model = model
            self.simctl = simctl
            self.pasteboard = pasteboard
            self.picker = picker
        }

        /// Every simctl argv as logged, file arguments included, without the
        /// private set's `--set <folder>`.
        var rawCalls: [String] {
            ((try? String(contentsOf: simctl.callsURL, encoding: .utf8)) ?? "")
                .split(separator: "\n")
                .map { line in
                    var call = String(line)
                    if call.hasPrefix("--set "), let space = call.dropFirst("--set ".count).firstIndex(of: " ") {
                        call = String(call[call.index(after: space)...])
                    }
                    return call
                }
        }

        func calls(containing text: String) -> [String] {
            rawCalls.filter { $0.contains(text) }
        }
    }

    /// The arms a ready simulator needs, after `extra` (matched first).
    func makeSimctl(_ extra: String = "") throws -> StubTool {
        try makeStubTool("simctl", arms: extra + """
          *"spawn \(Self.udid) notifyutil -g com.apple.coredevice.dtuhidd.active")
            \(SimulatorFixtures.cat("simctl-spawn-notifyutil-g-dtuhidd-active.before-input.stdout.txt")) ;;
          *"list -j devices")
            \(SimulatorFixtures.cat("simctl-list-j-devices.booted-after-rename.json")) ;;
          *"list -j runtimes")
            \(SimulatorFixtures.cat("simctl-list-j-runtimes.json")) ;;
          *"list -j devicetypes")
            \(SimulatorFixtures.cat("simctl-list-j-devicetypes.json")) ;;
          *"bootstatus \(Self.udid)")
            \(SimulatorFixtures.cat("simctl-bootstatus.already-booted.stdout.txt")) ;;
          *"spawn \(Self.udid) launchctl list")
            \(SimulatorFixtures.cat("simctl-spawn-launchctl-list.ready.stdout.txt")) ;;
          *"io \(Self.udid) screenshot --type=png "*)
            \(SimulatorFixtures.screenshot("simctl-io-screenshot.home-screen-loading.png")) ;;

        """)
    }

    /// A model whose simulator is ready, on the live canvas when `live`
    /// (the bridge exists and is allowlisted), else on the view-only one.
    func readyHarness(
        extraArms: String = "",
        live: Bool = true,
        defaults: UserDefaults = .scratch()
    ) async throws -> Harness {
        let simctl = try makeSimctl(extraArms)
        var apple = AppleTooling.stubbed(
            simctl: simctl,
            devicesDirectory: try makeTemporaryFolder("set"),
            logsDirectory: try makeTemporaryFolder("logs")
        )
        let bridge: FakeSimulatorBridge? = live ? FakeSimulatorBridge() : nil
        apple.makeBridge = { _ in bridge }
        apple.bridgeVerdict = { .allowlisted(CoreSimulatorVersion(1171, 7)) }
        let environment = AppEnvironment.testing(apple: apple, defaults: defaults)
        let pasteboard = try XCTUnwrap(environment.pasteboard as? TestPasteboard)
        let picker = try XCTUnwrap(environment.picker as? TestPicker)
        let model = AppModel(environment: environment)
        let harness = Harness(model: model, simctl: simctl, pasteboard: pasteboard, picker: picker)
        addTeardownBlock { @MainActor in
            model.tearDownMirror(cause: .userStop)
            model.stopSimulatorProvider()
            model.workspace.logcat.stopLogcat()
        }
        model.mirror.simulatorSessionFactoryOverride = { [weak harness] udid, live in
            let session = FakeSimulatorSession(udid: udid, isLiveCanvas: live)
            harness?.sessions.append(session)
            return session
        }
        model.simulatorCanvas.smokeTimeout = .milliseconds(300)
        model.simulatorCanvas.smokePollInterval = .milliseconds(10)
        model.simulatorCanvas.smokeGrace = .zero
        await model.simulators.refresh()
        await waitUntil(timeout: 10, "ready") { model.simulatorLifecycle.isReady(Self.udid) }
        return harness
    }

    /// Attaches the simulator's canvas; a live one gets its first frame at
    /// once, so the smoke check keeps it.
    func attach(_ harness: Harness, frame: Frame? = nil) throws -> FakeSimulatorSession {
        harness.model.simulatorCanvas.attach(Self.udid)
        let session = try XCTUnwrap(harness.sessions.last)
        if let frame {
            session.frames.put(frame)
        } else if session.isLiveCanvas {
            session.putFrame()
        }
        return session
    }

    /// A 2×2 frame with four known colours.
    static let quadFrame = Frame(
        data: Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 10, 20, 30, 255]),
        width: 2,
        height: 2,
        seq: 1
    )

    // MARK: - Screenshots

    /// On the live canvas the screenshot is the frame it shows, tagged sRGB,
    /// into the annotation editor; simctl takes none.
    func testALiveScreenshotIsTheCanvasFrameTaggedSRGB() async throws {
        let harness = try await readyHarness()
        _ = try attach(harness, frame: Self.quadFrame)
        let taken = harness.calls(containing: " screenshot ").count

        await harness.model.workspace.capture.annotateScreenshot()

        let png = try XCTUnwrap(harness.model.workspace.capture.annotationEditRequest?.png)
        let decoded = try Self.decode(png)
        XCTAssertEqual(decoded.rgba, [UInt8](Self.quadFrame.data))
        XCTAssertEqual(decoded.colorSpace, CGColorSpace.sRGB as String)
        XCTAssertEqual(harness.calls(containing: " screenshot ").count, taken, "no simctl screenshot on the live canvas")
        XCTAssertNil(harness.model.workspace.status.errorMessage)
    }

    /// On the view-only canvas the screenshot is a fresh `simctl io
    /// screenshot` into a temporary file (never `-`), read back as it is.
    func testAViewOnlyScreenshotComesFromSimctl() async throws {
        let harness = try await readyHarness(live: false)
        let session = try attach(harness)
        XCTAssertFalse(session.isLiveCanvas)
        let taken = harness.calls(containing: " screenshot ").count

        await harness.model.workspace.capture.annotateScreenshot()

        let png = try XCTUnwrap(harness.model.workspace.capture.annotationEditRequest?.png)
        XCTAssertEqual(png, try Data(contentsOf: SimulatorFixtures.url("simctl-io-screenshot.home-screen-loading.png")))
        let calls = harness.calls(containing: " screenshot ")
        XCTAssertEqual(calls.count, taken + 1)
        let call = try XCTUnwrap(calls.last)
        XCTAssertTrue(call.hasPrefix("io \(Self.udid) screenshot --type=png /"), call)
        XCTAssertTrue(call.hasSuffix(".png"), call)
        XCTAssertFalse(call.hasSuffix(" -"), "simctl writes a file named - for -")
        let file = String(call.dropFirst("io \(Self.udid) screenshot --type=png ".count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file), "the temporary file is removed")
    }

    /// Copy puts the same capture on the Mac pasteboard.
    func testCopyPutsTheScreenshotOnTheMacPasteboard() async throws {
        let harness = try await readyHarness()
        _ = try attach(harness, frame: Self.quadFrame)

        await harness.model.workspace.capture.copyScreenshotToClipboard()

        let png = try XCTUnwrap(harness.pasteboard.png)
        XCTAssertEqual(try Self.decode(png).rgba, [UInt8](Self.quadFrame.data))
        XCTAssertNil(harness.model.workspace.capture.annotationEditRequest, "Copy opens no editor")
    }

    /// A screen that is off never answers `io screenshot` in time: simctl
    /// waits 61 s before it fails (`SimctlClientTests
    /// .testAScreenshotOfAScreenThatIsOffFails`), so the app's bound ends it
    /// first, and the alert says what that means where it showed the
    /// runner's "did not finish within 20.0s and was terminated". The stub
    /// hangs past a bound shortened to a second.
    func testAScreenshotTheScreenDoesNotAnswerRaisesTheAlert() async throws {
        let harness = try await readyHarness(live: false)
        _ = try attach(harness)
        XCTAssertEqual(harness.model.simulatorCanvas.screenshotTimeout, .seconds(20), "the shipped bound")
        harness.model.simulatorCanvas.screenshotTimeout = .seconds(1)
        // Every later screenshot hangs, as one of a screen that is off does.
        harness.simctl.signal("screen-off")
        let flag = harness.simctl.path("screen-off")
        let stub = try String(contentsOf: harness.simctl.url, encoding: .utf8).replacingOccurrences(
            of: "case \"$*\" in\n",
            with: "case \"$*\" in\n  *\" screenshot \"*)\n    if [ -e '\(flag)' ]; then exec sleep 30; fi\n    "
                + SimulatorFixtures.screenshot("simctl-io-screenshot.home-screen-loading.png") + " ;;\n"
        )
        try Data(stub.utf8).write(to: harness.simctl.url)

        let started = ContinuousClock.now
        await harness.model.workspace.capture.takeScreenshot()

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10), "the bound ended the hang")
        XCTAssertNil(harness.model.workspace.capture.annotationEditRequest)
        XCTAssertEqual(harness.model.workspace.status.errorMessage, "The simulator's screen did not answer within 1 s. Is it off?")
        XCTAssertEqual(
            SimulatorCanvasController.CaptureError.screenDidNotAnswer(seconds: "20").description,
            "The simulator's screen did not answer within 20 s. Is it off?"
        )
    }

    // MARK: - Recording

    /// The live canvas records its own frames through the app's recorder;
    /// simctl records nothing.
    func testTheLiveCanvasRecordsItsFrames() async throws {
        let harness = try await readyHarness()
        _ = try attach(harness, frame: Self.quadFrame)
        XCTAssertTrue(harness.model.media.canRecord)

        await harness.model.workspace.media.toggleRecording()
        XCTAssertTrue(harness.model.workspace.media.isRecording)
        XCTAssertNotNil(harness.model.media.screenRecorder)
        XCTAssertNil(harness.model.media.simulatorRecording)

        harness.model.recordingFinalizer.recordingSaveOverride = { _, _ in }
        await harness.model.workspace.media.toggleRecording()
        XCTAssertFalse(harness.model.workspace.media.isRecording)
        await harness.model.recordingFinalizer.waitForRecordingsToFinish()
        XCTAssertEqual(harness.calls(containing: "recordVideo"), [])
    }

    /// The stub `simctl io recordVideo`: it says `Recording started` on
    /// stderr, as simctl does at its first frame, and writes the movie
    /// only when interrupted, as simctl writes its index.
    static let recordVideoArm = """
      *"io \(udid) recordVideo --codec=h264 "*)
        for last; do :; done
        trap 'printf movie > "$last"; exit 0' INT
        echo "Recording started" >&2
        while :; do sleep 0.05; done ;;

    """

    /// The view-only canvas records through `simctl io recordVideo` (H.264)
    /// into the clip's temporary file; Stop interrupts it, and the movie
    /// goes to the save panel like a recorder's clip.
    func testTheViewOnlyCanvasRecordsThroughSimctl() async throws {
        let harness = try await readyHarness(extraArms: Self.recordVideoArm, live: false)
        _ = try attach(harness)
        var saved: [(URL, String)] = []
        harness.model.recordingFinalizer.recordingSaveOverride = { url, name in saved.append((url, name)) }

        await harness.model.workspace.media.toggleRecording()
        XCTAssertTrue(harness.model.workspace.media.isRecording)
        XCTAssertNil(harness.model.media.screenRecorder)
        XCTAssertNotNil(harness.model.media.simulatorRecording)
        await waitUntil(timeout: 5, "simctl never started") { !harness.calls(containing: "recordVideo").isEmpty }
        let call = try XCTUnwrap(harness.calls(containing: "recordVideo").first)
        XCTAssertTrue(call.hasPrefix("io \(Self.udid) recordVideo --codec=h264 /"), call)
        XCTAssertTrue(call.hasSuffix(".mp4"), call)
        // Let simctl report its first frame.
        try await Task.sleep(for: .milliseconds(400))

        await harness.model.workspace.media.toggleRecording()
        XCTAssertFalse(harness.model.workspace.media.isRecording)
        await harness.model.recordingFinalizer.waitForRecordingsToFinish()

        let clip = try XCTUnwrap(saved.first)
        XCTAssertEqual(try String(contentsOf: clip.0, encoding: .utf8), "movie")
        XCTAssertTrue(clip.1.hasSuffix(".mp4"), clip.1)
        XCTAssertNil(harness.model.status.errorMessage)
        try? FileManager.default.removeItem(at: clip.0.deletingLastPathComponent())
    }

    /// The simulator shuts down during a view-only recording: simctl
    /// records on (measured 2026-09-26 on my own default-set iPhone 17 Pro,
    /// iOS 27.0 24A434, Xcode 27A266a: still running 4 s and 33 s after
    /// `simctl shutdown` returned, then exit 0 on SIGINT, the movie playable
    /// up to the shutdown), so the listing's shutdown tears the canvas down as
    /// disconnected, the interrupt ends simctl, and the clip is kept and
    /// reported, as a disconnected Android device's is. The stub records on
    /// the same way.
    func testAViewOnlyRecordingKeepsTheClipWhenTheSimulatorShutsDown() async throws {
        let harness = try await readyHarness(extraArms: Self.recordVideoArm, live: false)
        _ = try attach(harness)
        let kept = try makeTemporaryFolder("kept")
        harness.model.recordingFinalizer.recordingAutoSaveDirectory = kept
        await harness.model.workspace.media.toggleRecording()
        await waitUntil(timeout: 5, "simctl never started") { !harness.calls(containing: "recordVideo").isEmpty }
        // Let simctl report its first frame.
        try await Task.sleep(for: .milliseconds(400))

        harness.model.simulatorCanvas.noteListing([
            try SimulatorFixtures.entry("simctl-list-j-devices.cloned.json", udid: Self.udid),
        ])

        XCTAssertFalse(harness.model.workspace.media.isRecording)
        await harness.model.recordingFinalizer.waitForRecordingsToFinish()
        let clips = try FileManager.default.contentsOfDirectory(at: kept, includingPropertiesForKeys: nil)
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(try clips.first.map { try String(contentsOf: $0, encoding: .utf8) }, "movie")
        let message = try XCTUnwrap(harness.model.status.errorMessage)
        XCTAssertTrue(message.contains("disconnected"), message)
        XCTAssertTrue(message.contains("The clip was saved to \(kept.path)"), message)
    }

    /// A simctl recording that ends on its own (a failure: the stub replays
    /// simctl's invalid-device answer; a shutdown does not end simctl, see
    /// above) ends the recording and says why; nothing is left recording,
    /// and the clip is not kept.
    func testASimctlRecordingThatEndsOnItsOwnEndsTheRecording() async throws {
        let arm = """
          *"io \(Self.udid) recordVideo --codec=h264 "*)
            echo "Recording started" >&2
            sleep 0.3
            \(SimulatorFixtures.catToStderr("simctl-io-recordVideo-invalid-device.stderr.txt"))
            exit 148 ;;

        """
        let harness = try await readyHarness(extraArms: arm, live: false)
        _ = try attach(harness)

        await harness.model.workspace.media.toggleRecording()
        XCTAssertTrue(harness.model.workspace.media.isRecording)
        await waitUntil(timeout: 5, "the recording never ended") { !harness.model.workspace.media.isRecording }
        await harness.model.recordingFinalizer.waitForRecordingsToFinish()
        let message = try XCTUnwrap(harness.model.status.errorMessage)
        XCTAssertTrue(message.hasPrefix("Could not save the recording"), message)
    }

    /// Nothing mirrored: nothing to record.
    func testNothingMirroredCannotRecord() async throws {
        let harness = try await readyHarness()
        XCTAssertFalse(harness.model.media.canRecord)
        await harness.model.workspace.media.toggleRecording()
        XCTAssertFalse(harness.model.workspace.media.isRecording)
    }

    // MARK: - Clipboard

    /// A stub simulator pasteboard in `folder`: `pbcopy` writes
    /// `device.txt` (and the `LANG` it ran with to `lang`), `pbpaste` reads
    /// it, and the pasteboard watch prints a change whenever `post` appears
    /// (a copy made inside the simulator, or `autopost` makes every `pbcopy`
    /// post one, as the real pasteboard does).
    static func pasteboardArms(_ folder: URL) -> String {
        let path = { (name: String) in SimulatorFixtures.quoted(folder.appendingPathComponent(name).path) }
        return """
          *"pbcopy \(udid)")
            printf '%s' "$LANG" > \(path("lang")); cat > \(path("device.txt"))
            if [ -e \(path("autopost")) ]; then touch \(path("post")); fi ;;
          *"pbpaste \(udid)")
            cat \(path("device.txt")) ;;
          *"spawn \(udid) notifyutil -w com.apple.pasteboard.notify.changed")
            while :; do
              if [ -e \(path("post")) ]; then rm -f \(path("post")); echo com.apple.pasteboard.notify.changed; fi
              sleep 0.05
            done ;;

        """
    }

    /// Send puts the Mac's text on the simulator through `pbcopy` with a
    /// UTF-8 `LANG` (without one simctl reads the input as MacRoman); Pull
    /// brings the simulator's text to the Mac.
    func testSendAndPullCarryTurkishText() async throws {
        let folder = try makeTemporaryFolder("pasteboard")
        try Data("İkinci kopya: ğüıöç".utf8).write(to: folder.appendingPathComponent("device.txt"))
        let harness = try await readyHarness(extraArms: Self.pasteboardArms(folder))
        _ = try attach(harness)

        await harness.model.workspace.clipboard.pull(physical: harness.model.workspace.mirror.activePhysicalSession)
        XCTAssertEqual(harness.pasteboard.text, "İkinci kopya: ğüıöç")

        harness.pasteboard.text = "Mac'ten gönderildi: şçöğüı İ"
        await harness.model.workspace.clipboard.send(physical: harness.model.workspace.mirror.activePhysicalSession)
        XCTAssertEqual(
            try String(contentsOf: folder.appendingPathComponent("device.txt"), encoding: .utf8),
            "Mac'ten gönderildi: şçöğüı İ"
        )
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("lang"), encoding: .utf8), "en_US.UTF-8")
        XCTAssertNil(harness.model.workspace.status.errorMessage)
    }

    /// Pull from an empty simulator pasteboard leaves the Mac's alone.
    func testPullingAnEmptyPasteboardKeepsTheMacs() async throws {
        let folder = try makeTemporaryFolder("pasteboard")
        try Data().write(to: folder.appendingPathComponent("device.txt"))
        let harness = try await readyHarness(extraArms: Self.pasteboardArms(folder))
        _ = try attach(harness)
        harness.pasteboard.text = "keep me"

        await harness.model.workspace.clipboard.pull(physical: harness.model.workspace.mirror.activePhysicalSession)

        XCTAssertEqual(harness.pasteboard.text, "keep me")
        XCTAssertEqual(harness.model.workspace.status.statusMessage, "The device clipboard is empty")
    }

    /// Auto-sync on: turning it on overwrites neither side; a copy inside
    /// the simulator (its pasteboard's change notification) reaches the Mac;
    /// a Mac copy reaches the simulator, and its own notification is not
    /// echoed back. Turned off, the watch stops and the Mac is left alone.
    func testAutoSyncFollowsBothSides() async throws {
        let folder = try makeTemporaryFolder("pasteboard")
        let device = folder.appendingPathComponent("device.txt")
        try Data("seed".utf8).write(to: device)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("autopost").path, contents: nil)
        let harness = try await readyHarness(extraArms: Self.pasteboardArms(folder))
        harness.pasteboard.text = "mac-1"
        harness.model.workspace.clipboard.setAutoSync(true, physical: harness.model.workspace.mirror.activePhysicalSession)
        _ = try attach(harness)

        await waitUntil(timeout: 5, "the watch never started") {
            !harness.calls(containing: "notifyutil -w").isEmpty
        }
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(harness.pasteboard.text, "mac-1", "turning sync on does not overwrite the Mac")
        XCTAssertEqual(try String(contentsOf: device, encoding: .utf8), "seed", "…nor the simulator")

        // A copy inside the simulator.
        try Data("Cihazdan: ığüş".utf8).write(to: device)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("post").path, contents: nil)
        await waitUntil(timeout: 5, "the simulator's copy never reached the Mac") {
            harness.pasteboard.text == "Cihazdan: ığüş"
        }

        // A copy on the Mac: `pbcopy` posts the change, whose echo the app
        // reads once (one `pbpaste`) and does not send back.
        let pastes = harness.calls(containing: "pbpaste").count
        harness.pasteboard.text = "Mac'ten: çö"
        await waitUntil(timeout: 5, "the Mac's copy never reached the simulator") {
            (try? String(contentsOf: device, encoding: .utf8)) == "Mac'ten: çö"
        }
        await waitUntil(timeout: 5, "the echo of its own copy was never read") {
            harness.calls(containing: "pbpaste").count == pastes + 1
        }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(harness.pasteboard.text, "Mac'ten: çö")
        XCTAssertEqual(harness.calls(containing: "pbcopy").count, 1, "the echo of its own copy is not sent back")
        XCTAssertEqual(harness.calls(containing: "pbpaste").count, pastes + 1, "the echo is read once")

        // Off: the Mac is no longer written.
        harness.model.workspace.clipboard.setAutoSync(false, physical: harness.model.workspace.mirror.activePhysicalSession)
        try Data("after off".utf8).write(to: device)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("post").path, contents: nil)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(harness.pasteboard.text, "Mac'ten: çö")
    }

    /// Auto-sync off: attaching starts no watch, and a simulator copy never
    /// reaches the Mac.
    func testWithoutAutoSyncNothingWatchesThePasteboard() async throws {
        let folder = try makeTemporaryFolder("pasteboard")
        try Data("seed".utf8).write(to: folder.appendingPathComponent("device.txt"))
        let harness = try await readyHarness(extraArms: Self.pasteboardArms(folder))
        harness.pasteboard.text = "mac"
        _ = try attach(harness)
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(harness.calls(containing: "notifyutil -w"), [])
        XCTAssertEqual(harness.calls(containing: "pbpaste"), [])
        XCTAssertEqual(harness.pasteboard.text, "mac")
    }

    // MARK: - Open URL

    /// The stub's `openurl`: a success prints nothing (measured); an
    /// unknown scheme answers with simctl's real stderr (provenance in
    /// `SimctlAppsFixtureTests`, the capture of `openurl <UDID>
    /// nosuchscheme-aqa://x`) and exit 115.
    static let openURLArms = """
      *"openurl \(udid) nosuchscheme-aqa://"*)
        \(SimulatorFixtures.catToStderr("simctl-openurl-unknown-scheme.stderr.txt"))
        exit 115 ;;
      *"openurl \(udid) "*)
        ;;

    """

    /// Open URL hands the link to simctl, remembers it with the recent links
    /// Android's Links row keeps, as it was typed, and says so; an unknown
    /// scheme is named in the alert and not remembered; text without a
    /// scheme, or with one but reading as no URL, never reaches simctl and
    /// the alert says which. What a URL cannot hold is percent-encoded, as
    /// simctl encodes its own argument.
    func testOpenURLOpensAndRemembersTheURL() async throws {
        let harness = try await readyHarness(extraArms: Self.openURLArms)
        let apps = harness.model.simulatorApps

        let opened = await apps.openURL("  myapp://orders/42?ref=ş  ", udid: Self.udid)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.calls(containing: "openurl"), ["openurl \(Self.udid) myapp://orders/42?ref=%C5%9F"])
        XCTAssertEqual(harness.model.links.recents.links.first, "myapp://orders/42?ref=ş")
        XCTAssertEqual(harness.model.workspace.status.statusMessage, "Opened myapp://orders/42?ref=ş")

        let unknown = await apps.openURL("nosuchscheme-aqa://x", udid: Self.udid)
        XCTAssertFalse(unknown)
        XCTAssertEqual(harness.model.workspace.status.errorMessage, "No app on the simulator opens nosuchscheme-aqa: links.")
        XCTAssertEqual(harness.model.links.recents.links, ["myapp://orders/42?ref=ş"])

        harness.model.workspace.status.errorMessage = nil
        let schemeless = await apps.openURL("example.com", udid: Self.udid)
        XCTAssertFalse(schemeless)
        XCTAssertEqual(harness.calls(containing: "openurl").count, 2)
        XCTAssertEqual(
            harness.model.workspace.status.errorMessage,
            "example.com is not a URL: it needs a scheme, such as https: or myapp:."
        )

        // A scheme, but no URL can be read from the rest: the unreadable-URL
        // alert, not "it needs a scheme" (the sheet's Open is on for it).
        harness.model.workspace.status.errorMessage = nil
        let unreadable = await apps.openURL("myapp://open page", udid: Self.udid)
        XCTAssertFalse(unreadable)
        XCTAssertEqual(harness.calls(containing: "openurl").count, 2)
        XCTAssertEqual(harness.model.workspace.status.errorMessage, "myapp://open page cannot be read as a URL.")
        XCTAssertNil(apps.activity, "the slot is free again")
    }

    /// A link dropped on the stage takes the sheet's path: it joins the same
    /// recent links, so the sheet (and Android's Links row) offers it next.
    func testADroppedLinkJoinsTheRecentLinks() async throws {
        let harness = try await readyHarness(extraArms: Self.openURLArms)
        let link = try XCTUnwrap(URL(string: "https://example.com/?from=drop"))

        await harness.model.simulatorApps.handleDrop([link], udid: Self.udid) { _ in
            XCTFail("a link asks nothing")
        }

        XCTAssertEqual(harness.calls(containing: "openurl"), ["openurl \(Self.udid) https://example.com/?from=drop"])
        XCTAssertEqual(harness.model.links.recents.links, ["https://example.com/?from=drop"])
        XCTAssertEqual(harness.model.workspace.status.statusMessage, "Opened https://example.com/?from=drop")
    }

    /// The Device menu's Open URL… is on for a booted simulator with
    /// nothing in flight; the sheet's Open is on for text with a scheme
    /// that is not a host file.
    func testOpenURLGates() throws {
        let entry = try SimulatorFixtures.entry("simctl-list-j-devices.booted-after-rename.json", udid: Self.udid)
        XCTAssertTrue(SimulatorDeviceMenuState(device: nil, capabilities: [], selected: entry).canOpenURL)
        XCTAssertFalse(SimulatorDeviceMenuState(device: nil, capabilities: [], selected: entry, operation: .restarting).canOpenURL)
        let stopped = try SimulatorFixtures.entry(
            "simctl-list-j-devices.shutdown.json",
            udid: "95D9676B-3317-4BA5-8CF6-3CDD0488CACA"
        )
        XCTAssertFalse(SimulatorDeviceMenuState(device: nil, capabilities: [], selected: stopped).canOpenURL)
        XCTAssertFalse(SimulatorDeviceMenuState(device: nil, capabilities: []).canOpenURL)

        let dialogs = SimulatorActionDialogs()
        dialogs.requestOpenURL(entry)
        XCTAssertEqual(dialogs.openURLTarget?.udid, Self.udid)
        XCTAssertFalse(dialogs.canOpenURL)
        dialogs.openURLDraft = " https://example.com "
        XCTAssertTrue(dialogs.canOpenURL)
        dialogs.openURLDraft = "example.com"
        XCTAssertFalse(dialogs.canOpenURL)
        dialogs.openURLDraft = "file:///tmp/a.html"
        XCTAssertFalse(dialogs.canOpenURL, "a host file is not a link")
        // On as on track 2, whose check was the scheme: Open's alert says
        // why it reads as no URL (it was off, unexplained, after the merge).
        dialogs.openURLDraft = "myapp://open page"
        XCTAssertTrue(dialogs.canOpenURL)
    }

    // MARK: - Readiness from the canvas

    /// A frame of a screenshot capture, as the canvas publishes it.
    static func frame(ofCapture name: String) throws -> Frame {
        let image = try XCTUnwrap(SimulatorScreenshotSession.rgbaImage(fromPNGAt: SimulatorFixtures.url(name)))
        return Frame(data: image.bytes, width: image.width, height: image.height, seq: 1)
    }

    /// The live canvas answers ready's screen check from its frame: the
    /// home screen and the boot screen told apart as from a screenshot, and
    /// the lifecycle's hook takes no screenshot while it can. Without a live
    /// frame the hook takes one.
    func testReadyReadsTheLiveCanvasFrame() async throws {
        let harness = try await readyHarness()
        let canvas = harness.model.simulatorCanvas
        let hook = harness.model.simulatorLifecycle.screenContent
        let simctl = try XCTUnwrap(harness.model.simulators.simctl)
        let unmirrored = await canvas.screenContentFromCanvas(Self.udid)
        XCTAssertNil(unmirrored, "nothing mirrored")

        let session = try attach(harness, frame: try Self.frame(ofCapture: "simctl-io-screenshot.boot-screen.png"))
        XCTAssertTrue(session.isLiveCanvas)
        let booting = await canvas.screenContentFromCanvas(Self.udid)
        XCTAssertEqual(booting, .bootScreen)
        session.frames.put(try Self.frame(ofCapture: "simctl-io-screenshot.home-screen-loading.png"))
        let home = await canvas.screenContentFromCanvas(Self.udid)
        XCTAssertEqual(home, .homeScreen)

        let taken = harness.calls(containing: " screenshot ").count
        let content = await hook(Self.udid, simctl)
        XCTAssertEqual(content, .homeScreen)
        XCTAssertEqual(harness.calls(containing: " screenshot ").count, taken, "no screenshot while the canvas answers")

        harness.model.tearDownMirror(cause: .userStop)
        let fromScreenshot = await hook(Self.udid, simctl)
        XCTAssertEqual(fromScreenshot, .homeScreen)
        XCTAssertEqual(harness.calls(containing: " screenshot ").count, taken + 1)
    }

    /// The view-only canvas does not answer: its pictures are screenshots
    /// taken only while shown.
    func testTheViewOnlyCanvasDoesNotAnswerReady() async throws {
        let harness = try await readyHarness(live: false)
        _ = try attach(harness, frame: try Self.frame(ofCapture: "simctl-io-screenshot.home-screen-loading.png"))
        let content = await harness.model.simulatorCanvas.screenContentFromCanvas(Self.udid)
        XCTAssertNil(content)
    }

    /// The canvas may start under the booting page for the whole boot (the
    /// stage follows its frames, `followBootFrames`) and only then; only the
    /// live canvas does, once.
    func testTheCanvasStartsEarlyOnlyWhileTheSimulatorBoots() async throws {
        let entry = try SimulatorFixtures.entry("simctl-list-j-devices.booted-after-rename.json", udid: Self.udid)
        for state: DeviceRunState in [.booting(.launching), .booting(.migratingData), .booting(.waitingOnSystemApp), .booting(.waitingOnHomeScreen)] {
            XCTAssertEqual(SimulatorStageView.earlyCanvasKey(entry: entry, runState: state), Self.udid, "\(state)")
        }
        for state: DeviceRunState in [.ready, .stopped] {
            XCTAssertNil(SimulatorStageView.earlyCanvasKey(entry: entry, runState: state), "\(state)")
        }

        let live = try await readyHarness()
        live.model.simulatorCanvas.attachForReadiness(Self.udid)
        XCTAssertEqual(live.sessions.count, 1)
        XCTAssertTrue(live.sessions[0].isLiveCanvas)
        live.sessions[0].putFrame()
        live.model.simulatorCanvas.attachForReadiness(Self.udid)
        XCTAssertEqual(live.sessions.count, 1, "nothing new for a simulator mirrored already")

        let viewOnly = try await readyHarness(live: false)
        viewOnly.model.simulatorCanvas.attachForReadiness(Self.udid)
        XCTAssertEqual(viewOnly.sessions.count, 0, "the view-only canvas waits for ready")
    }

    /// Before its first frame a simulator's stage draws the body around the
    /// display its device type declares, not a black box; an Android
    /// device's still waits for its stream's size.
    func testTheBodyIsPlannedBeforeTheFirstFrame() {
        let display = SimulatorDisplayProfile(width: 1206, height: 2622, scale: 3).displayShape(id: "iPhone-17-Pro")
        XCTAssertEqual(
            MirrorStageContent.vectorPixels(settled: nil, device: .apple(Self.udid), displays: [display]),
            CGSize(width: 1206, height: 2622)
        )
        XCTAssertEqual(
            MirrorStageContent.vectorPixels(settled: CGSize(width: 2622, height: 1206), device: .apple(Self.udid), displays: [display]),
            CGSize(width: 2622, height: 1206)
        )
        XCTAssertNil(MirrorStageContent.vectorPixels(settled: nil, device: .apple(Self.udid), displays: []))
        XCTAssertNil(MirrorStageContent.vectorPixels(settled: nil, device: .android("emulator-5554"), displays: [display]))
    }

    // MARK: - Frame feed

    /// A 32BGRA frame (the simulator's canvas, a phone's decoded video)
    /// reaches the encoders as a copy of its buffer: the pixels as they are,
    /// and no RGBA bytes are made on the way.
    func testTheFeedCopiesABGRAFrameWithoutConvertingIt() throws {
        let bgra: [UInt8] = [1, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 255, 10, 11, 12, 255, 13, 14, 15, 255, 16, 17, 18, 255]
        let source = try Self.makeBGRAPixelBuffer(width: 3, height: 2, bytes: bgra)
        let conversions = ConversionCounter()
        let frame = Frame(pixelBuffer: source, seq: 1) { _ in
            conversions.count += 1
            return nil
        }

        let fed = try XCTUnwrap(MediaCaptureController.feedPixelBuffer(from: frame, pool: BGRAPixelBufferPool(width: 3, height: 2)))

        XCTAssertFalse(fed === source, "a copy: the session reuses its buffer")
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(fed), kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(fed, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(fed, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(fed)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(fed)
        var read: [UInt8] = []
        for row in 0..<2 {
            read += (0..<12).map { base[row * rowBytes + $0] }
        }
        XCTAssertEqual(read, bgra)
        XCTAssertEqual(conversions.count, 0)
    }

    // MARK: - Helpers

    /// An IOSurface-backed 32BGRA buffer (rows padded) holding `bytes`.
    static func makeBGRAPixelBuffer(width: Int, height: Int, bytes: [UInt8]) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &pixelBuffer
        ), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<height {
            for column in 0..<(width * 4) {
                base[row * rowBytes + column] = bytes[row * width * 4 + column]
            }
        }
        return buffer
    }

    /// A PNG's pixels drawn into straight RGBA in sRGB, and the name of the
    /// colour space ImageIO reads it in.
    static func decode(_ png: Data) throws -> (rgba: [UInt8], colorSpace: String?) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (bytes, image.colorSpace?.name as String?)
    }
}

/// Counts a frame's RGBA conversions.
private final class ConversionCounter: @unchecked Sendable {
    var count = 0
}
