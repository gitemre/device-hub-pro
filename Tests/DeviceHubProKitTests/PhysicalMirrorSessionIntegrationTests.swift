import XCTest
@testable import DeviceHubProKit

/// Live verification of the scrcpy transport against a real adb target (the
/// emulator stands in for a phone). Skipped when no suitable device is
/// attached. A physical phone is used only when `DHP_SCRCPY_SERIAL`
/// names it — these tests type into Settings and replace the clipboard.
///
/// The transport test mirrors for a few seconds while poking the screen (so
/// frames keep arriving), then prints the measured numbers and asserts the
/// stream contract (RGBA frames at the decoded size, no fatal error, teardown
/// complete). The input tests drive taps/swipes/text through the session and
/// read the device-side effects back (`screencap` + `uiautomator dump`), once
/// over the shipped control socket and once over the `adb shell input`
/// fallback.
final class PhysicalMirrorSessionIntegrationTests: XCTestCase {
    func testMirrorsAndMeasuresThePhysicalTransport() async throws {
        guard let adb = AdbClient.locate() else {
            throw XCTSkip("adb not found")
        }
        let online = try await adb.listDevices().filter(\.isOnline)
        guard let device = pickDevice(from: online) else {
            throw XCTSkip("no online device for the scrcpy transport")
        }

        let clock = await Self.readDeviceClock(adb: adb, serial: device.serial)
        // Exercise the shipped production settings (native size, 60 fps,
        // 8 Mbps), not the server defaults, so the measured numbers describe
        // what the app actually runs.
        let session = PhysicalMirrorSession(
            serial: device.serial,
            adb: adb,
            options: .physicalMirror
        )
        let collector = MeasurementCollector()
        session.onDecodedFrame = { pts, host in
            collector.record(pts: pts, host: host)
        }

        let startedAt = Date()
        session.start()

        // Wait for the first frame (server push/launch dominates this).
        var firstFrame: Frame?
        let firstDeadline = Date().addingTimeInterval(15)
        while Date() < firstDeadline {
            if let frame = session.frames.current {
                firstFrame = frame
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let firstFrameSeconds = Date().timeIntervalSince(startedAt)
        XCTAssertNotNil(firstFrame, "no frame within 15 s: \(session.lastError ?? "no error")")

        // Keep the screen moving so the stream produces frames to measure.
        // One long-lived shell runs a tight swipe loop: spawning an adb client
        // per poke throttles the motion (and with it the stream's bitrate).
        // The stroke follows the decoded frame size, so it stays in bounds
        // whichever way the display is rotated.
        let windowSeconds = 6.0
        let measurementStart = Date()
        let pokeProcess = Process()
        pokeProcess.executableURL = adb.adbURL
        if let firstFrame {
            let midX = firstFrame.width / 2
            let topY = firstFrame.height / 5
            let bottomY = firstFrame.height * 4 / 5
            pokeProcess.arguments = [
                "-s", device.serial, "shell",
                "while true; do input swipe \(midX) \(bottomY) \(midX) \(topY) 80; input swipe \(midX) \(topY) \(midX) \(bottomY) 80; done",
            ]
            try? pokeProcess.run()
        }
        try await Task.sleep(for: .seconds(windowSeconds))
        if pokeProcess.isRunning { pokeProcess.terminate() }
        _ = try? await adb.shell(serial: device.serial, ["pkill", "-f", "input swipe"])

        let stats = await session.stats()
        let samples = collector.snapshot().filter { $0.host >= measurementStart }
        let frame = session.frames.current

        XCTAssertNil(session.lastError, "session reported \(session.lastError ?? "")")
        XCTAssertNotNil(frame, "no frame after the measurement window")
        if let frame {
            XCTAssertEqual(frame.data.count, frame.width * frame.height * 4)
        }

        let measured = Self.summarize(
            samples: samples,
            clock: clock,
            windowSeconds: windowSeconds
        )
        print(
            "P5-TRANSPORT serial=\(device.serial) "
                + "firstFrame=\(String(format: "%.2f", firstFrameSeconds))s "
                + "decoded=\(samples.count) fps=\(String(format: "%.1f", measured.fps)) "
                + "statsFPS=\(String(format: "%.1f", stats.fps)) "
                + "decodeLatencyMs=\(String(format: "%.1f", stats.averageLatencyMs)) "
                + "e2eMs=\(String(format: "%.1f", measured.endToEndMs)) "
                + "e2eStdMs=\(String(format: "%.1f", measured.endToEndStdMs)) "
                + "clockRttMs=\(String(format: "%.1f", clock.roundTripMs)) "
                + "hostAgeMs=\(String(format: "%.1f", measured.meanHostAgeMs)) "
                + "deviceAgeMs=\(String(format: "%.1f", measured.meanDeviceAgeMs)) "
                + "size=\(frame?.width ?? 0)x\(frame?.height ?? 0)"
        )

        // Tear down synchronously before proving the tunnel is gone.
        session.stop()
        try await Task.sleep(for: .seconds(1))
        let forwards = (try? await adb.run(["-s", device.serial, "forward", "--list"])) ?? ""
        XCTAssertFalse(
            forwards.contains("localabstract:scrcpy"),
            "the scrcpy forward must be removed on stop: \(forwards)"
        )
    }

    // MARK: - Input

    /// The shipped path (`.physicalMirror`): touches stream over scrcpy's
    /// control socket as INJECT_TOUCH_EVENT in video coordinates, ASCII text
    /// goes out as INJECT_TEXT, and Turkish letters typed one keystroke at a
    /// time are pasted through SET_CLIPBOARD, each paste acknowledged before
    /// the next (otherwise a later letter can be pasted twice).
    func testInputDrivesTheDeviceOverTheControlSocket() async throws {
        try await driveInput(
            options: .physicalMirror,
            keystrokes: ["devicehubpro", "ı", "ş", "ı", "k"],
            expectedText: "devicehubproışık",
            label: "control"
        )
    }

    /// The fallback for sessions without a control socket: gestures are
    /// replayed on release with `adb shell input`, scaled to the display.
    func testInputDrivesTheDeviceOverTheAdbInputFallback() async throws {
        try await driveInput(
            options: ScrcpyServer.Options(),
            keystrokes: ["devicehubpro"],
            expectedText: "devicehubpro",
            label: "adb-input"
        )
    }

    /// Drives the live physical session's input path against the emulator-as-
    /// physical: a tap opens the Settings search, typed text lands in its
    /// field, and a swipe scrolls the homepage. Effects are read back from the
    /// device (screencap hashes and the accessibility tree), not from the
    /// session itself.
    ///
    /// The stock keyboard on the emulator image swallows injected key events ("Cancelling
    /// event (no window focus)" from the IME window), so on an emulator the IME
    /// is disabled for the text leg and restored right after, with a teardown
    /// backstop. A phone keeps its owner's keyboard settings untouched.
    private func driveInput(
        options: ScrcpyServer.Options,
        keystrokes: [String],
        expectedText: String,
        label: String
    ) async throws {
        guard let adb = AdbClient.locate() else {
            throw XCTSkip("adb not found")
        }
        let online = try await adb.listDevices().filter(\.isOnline)
        guard let device = pickDevice(from: online) else {
            throw XCTSkip("no online device for the scrcpy transport")
        }
        let serial = device.serial

        let session = PhysicalMirrorSession(serial: serial, adb: adb, options: options)
        session.start()
        defer { session.stop() }

        var first: Frame?
        let firstDeadline = Date().addingTimeInterval(15)
        while Date() < firstDeadline, first == nil {
            first = session.frames.current
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try XCTUnwrap(
            first,
            "no frame within 15 s: \(session.lastError ?? "no error")"
        )
        XCTAssertEqual(
            session.usesControlSocket,
            options.control,
            "serial \(serial): the input must travel over the \(label) path"
        )

        await Self.clearTheStage(adb: adb, serial: serial)
        _ = try? await adb.shell(serial: serial, ["am", "start", "-a", "android.settings.SETTINGS"])
        let (homepage, searchEntry) = await Self.waitForSettingsSearchEntry(adb: adb, serial: serial)

        // The stage's coordinates are frame coordinates; the scrcpy stream is
        // in the display's current orientation, so each leg waits for the
        // newest frame to match the screen the UI dump describes (a rotation
        // between legs would otherwise send input to the wrong pixels).
        let rootBounds = try XCTUnwrap(
            Self.rootBounds(in: homepage),
            "no root bounds in the Settings dump"
        )
        let tapFrameCandidate = await Self.waitForFrame(on: session, matching: rootBounds.size)
        let tapFrame = try XCTUnwrap(
            tapFrameCandidate,
            "serial \(serial): no frame matching the \(Int(rootBounds.width))x\(Int(rootBounds.height)) screen"
        )
        XCTAssertTrue(
            Self.frame(tapFrame, matches: rootBounds.size),
            "serial \(serial): the tap frame \(tapFrame.width)x\(tapFrame.height) does not match the dump's \(Int(rootBounds.width))x\(Int(rootBounds.height))"
        )

        // Tap: the search bar opens the search screen.
        let searchBar = try XCTUnwrap(searchEntry, "no search bar in the Settings homepage")
        let tapX = Int32(searchBar.midX)
        let tapY = Int32(searchBar.midY)
        let beforeTap = try await adb.screenshot(serial: serial)
        session.send(TouchCommand(phase: .down, x: tapX, y: tapY))
        session.send(TouchCommand(phase: .up, x: tapX, y: tapY))
        let afterTap = await Self.waitForFocusedEditText(adb: adb, serial: serial)
        XCTAssertTrue(
            Self.hasFocusedEditText(afterTap),
            "the tap did not open the Settings search field"
        )
        let afterTapShot = try await adb.screenshot(serial: serial)
        XCTAssertNotEqual(
            afterTapShot,
            beforeTap,
            "the tap did not change the screen"
        )

        // Text: type into the focused search field through the session.
        // The IME is disabled only on an emulator (see above); a phone keeps
        // its owner's keyboard, which is also the case the app must handle.
        let imeID = "com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME"
        let togglesIME = serial.hasPrefix("emulator-")
        if togglesIME {
            _ = try? await adb.shell(serial: serial, ["ime", "disable", imeID])
            addTeardownBlock {
                _ = try? await adb.shell(serial: serial, ["ime", "enable", imeID])
            }
        }
        // One command per keystroke, sent back to back, as the stage does.
        for keystroke in keystrokes {
            session.send(KeyboardCommand.text(keystroke))
        }
        let afterText = await Self.waitForUI(adb: adb, serial: serial, matching: expectedText)
        XCTAssertTrue(
            Self.visibleTexts(in: afterText).contains(expectedText),
            "the typed text did not reach the search field as \"\(expectedText)\": \(Self.visibleTexts(in: afterText))"
        )
        if togglesIME {
            _ = try? await adb.shell(serial: serial, ["ime", "enable", imeID])
        }

        // Swipe: on a fresh homepage, a vertical stroke scrolls the list.
        await Self.clearTheStage(adb: adb, serial: serial)
        _ = try? await adb.shell(serial: serial, ["am", "start", "-a", "android.settings.SETTINGS"])
        let (beforeSwipe, _) = await Self.waitForSettingsSearchEntry(adb: adb, serial: serial)
        let titlesBefore = Self.visibleTexts(in: beforeSwipe)
        let beforeSwipeShot = try await adb.screenshot(serial: serial)

        let swipeScreen = try XCTUnwrap(
            Self.rootBounds(in: beforeSwipe),
            "no root bounds in the Settings dump"
        )
        let swipeFrameCandidate = await Self.waitForFrame(on: session, matching: swipeScreen.size)
        let swipeFrame = try XCTUnwrap(
            swipeFrameCandidate,
            "serial \(serial): no frame matching the \(Int(swipeScreen.width))x\(Int(swipeScreen.height)) screen"
        )
        XCTAssertTrue(
            Self.frame(swipeFrame, matches: swipeScreen.size),
            "serial \(serial): the swipe frame \(swipeFrame.width)x\(swipeFrame.height) does not match the dump's \(Int(swipeScreen.width))x\(Int(swipeScreen.height))"
        )

        let midX = Int32(swipeScreen.midX)
        let startY = Int32(swipeScreen.height * 0.75)
        let endY = Int32(swipeScreen.height * 0.25)
        // Per-event pacing matters: a swipe injected with a ~0 ms duration
        // reads as a click on the row under the start point, not a scroll.
        session.send(TouchCommand(phase: .down, x: midX, y: startY))
        for step in 1...8 {
            let y = startY + (endY - startY) * Int32(step) / 8
            try await Task.sleep(for: .milliseconds(30))
            session.send(TouchCommand(phase: .move, x: midX, y: y))
        }
        try await Task.sleep(for: .milliseconds(30))
        session.send(TouchCommand(phase: .up, x: midX, y: endY))
        try await Task.sleep(for: .seconds(1.5))

        let afterSwipe = await Self.waitForUI(adb: adb, serial: serial, matching: "node")
        let titlesAfter = Self.visibleTexts(in: afterSwipe)
        XCTAssertNotEqual(
            titlesBefore,
            titlesAfter,
            "the swipe did not scroll the Settings list"
        )
        let afterSwipeShot = try await adb.screenshot(serial: serial)
        XCTAssertNotEqual(
            afterSwipeShot,
            beforeSwipeShot,
            "the swipe did not change the screen"
        )

        XCTAssertNil(session.lastError, "session reported \(session.lastError ?? "")")
        print(
            "P5-INPUT transport=\(label) serial=\(serial) screen=\(swipeScreen.width)x\(swipeScreen.height) "
                + "tap=searchBar@(\(tapX),\(tapY)) fieldOpened=true "
                + "text=\"\(expectedText)\" visible=true "
                + "swipe=(\(midX),\(startY))->(\(midX),\(endY)) "
                + "titlesBefore=\(titlesBefore.sorted().joined(separator: "|")) "
                + "titlesAfter=\(titlesAfter.sorted().joined(separator: "|"))"
        )
    }

    // MARK: - Helpers

    /// A physical phone only when pinned (`LiveTestDevices`); otherwise an
    /// emulator standing in for one. The ATD image idles without producing
    /// frames, so any other emulator is preferred.
    private func pickDevice(from devices: [AndroidDevice]) -> AndroidDevice? {
        let allowed = LiveTestDevices.allowed(devices)
        let nonIdle = allowed.first { device in
            !(device.model ?? "").localizedCaseInsensitiveContains("ATD")
        }
        return nonIdle ?? allowed.first
    }

    /// The accessibility tree of the current screen, via `uiautomator dump`
    /// (also the read-back for text injection).
    private static func dumpUI(adb: AdbClient, serial: String) async -> String {
        _ = try? await adb.shell(
            serial: serial,
            ["uiautomator", "dump", "/sdcard/devicehubpro-input-dump.xml"]
        )
        return (try? await adb.shell(
            serial: serial,
            ["cat", "/sdcard/devicehubpro-input-dump.xml"]
        )) ?? ""
    }

    /// A clean starting screen: Settings force-stopped, and no heads-up
    /// notification over the search bar. On an emulator, an SMS the telephony
    /// integration test sent earlier in the same run otherwise sits where the
    /// tap lands and opens Messages; force-stopping Messages also cancels its
    /// notifications. A phone's Messages is left alone.
    static func clearTheStage(adb: AdbClient, serial: String) async {
        // Messages is stopped only on an emulator: its welcome screen is what
        // the telephony test's SMS brings up there, while on a phone it is the
        // the user's messaging app and stopping it clears their notifications.
        var packages = ["com.google.android.settings.intelligence", "com.android.settings"]
        if serial.hasPrefix("emulator-") {
            packages.insert("com.example.messages", at: 0)
        }
        for package in packages {
            _ = try? await adb.shell(serial: serial, ["am", "force-stop", package])
        }
        _ = try? await adb.shell(serial: serial, ["cmd", "statusbar", "collapse"])
    }

    /// Polls `dumpUI` until the dump contains `needle` (or times out).
    private static func waitForUI(
        adb: AdbClient,
        serial: String,
        matching needle: String,
        timeout: TimeInterval = 8
    ) async -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var dump = ""
        while Date() < deadline {
            dump = await dumpUI(adb: adb, serial: serial)
            if dump.contains(needle) { return dump }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return dump
    }

    /// The decoded frame's dimensions are the encoder's *coded* size, not the
    /// display size the UI dump reports: VideoToolbox pads up to the 16-px
    /// H.264 macroblock alignment (on the 16k-page-size emulator image 2076
    /// pads to 2080). The padding only ever adds pixels, so the decoded
    /// dimension never falls below the dump's. A rotation changes a dimension
    /// by hundreds of pixels, so a one-macroblock tolerance still tells the
    /// current orientation.
    private static let frameSizeTolerance = 15

    /// Waits until the session's newest frame matches the screen size the UI
    /// dump reports. A rotation between legs makes frame coordinates and
    /// `adb shell input` coordinates disagree, so each input leg waits for the
    /// stream to catch up with the current orientation.
    private static func waitForFrame(
        on session: PhysicalMirrorSession,
        matching size: CGSize,
        timeout: TimeInterval = 10
    ) async -> Frame? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = session.frames.current, Self.frame(frame, matches: size) {
                return frame
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return session.frames.current
    }

    /// Whether a decoded frame shows the screen a UI dump describes. The width
    /// must match within one macroblock (see `frameSizeTolerance`). The dump's
    /// root can be shorter than the display: AOSP reports the whole display,
    /// but HyperOS 1.0 (Redmi Note 12 Pro, Android 13) reports the app window
    /// without the 137-px gesture bar (2263 of 2400). A rotation swaps the
    /// dimensions, which still fails the width check.
    private static func frame(_ frame: Frame, matches size: CGSize) -> Bool {
        let extraHeight = frame.height - Int(size.height)
        return (0...frameSizeTolerance).contains(frame.width - Int(size.width))
            && extraHeight >= 0
            && Double(extraHeight) <= Double(frame.height) * 0.1
    }

    /// Settings' search entry on the homepage, by the ids seen on real
    /// devices: AOSP's `search_action_bar` (Pixel images) and HyperOS's
    /// `search_mode_stub` (Xiaomi, captured on a Redmi Note 12 Pro).
    private static let settingsSearchEntryIDs = [
        "com.android.settings:id/search_action_bar",
        "com.android.settings:id/search_mode_stub",
    ]

    /// Polls until the Settings homepage shows a known search entry; returns
    /// the last dump and the entry's bounds (nil on timeout).
    private static func waitForSettingsSearchEntry(
        adb: AdbClient,
        serial: String,
        timeout: TimeInterval = 10
    ) async -> (String, CGRect?) {
        let deadline = Date().addingTimeInterval(timeout)
        var dump = ""
        while Date() < deadline {
            dump = await dumpUI(adb: adb, serial: serial)
            for id in settingsSearchEntryIDs {
                if let bounds = bounds(ofResourceID: id, in: dump) { return (dump, bounds) }
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return (dump, nil)
    }

    /// A focused text field: the search screen's input on any vendor.
    private static func hasFocusedEditText(_ dump: String) -> Bool {
        dump.components(separatedBy: "<node ").contains { node in
            node.contains("class=\"android.widget.EditText\"") && node.contains("focused=\"true\"")
        }
    }

    private static func waitForFocusedEditText(
        adb: AdbClient,
        serial: String,
        timeout: TimeInterval = 10
    ) async -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var dump = ""
        while Date() < deadline {
            dump = await dumpUI(adb: adb, serial: serial)
            if hasFocusedEditText(dump) { return dump }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return dump
    }

    /// The bounds of the first node whose `resource-id` matches, parsed from a
    /// uiautomator XML dump (`bounds="[x1,y1][x2,y2]"`).
    private static func bounds(ofResourceID id: String, in dump: String) -> CGRect? {
        guard let idRange = dump.range(of: "resource-id=\"\(id)\"") else { return nil }
        return firstBounds(in: String(dump[idRange.upperBound...]))
    }

    /// The root node's bounds: the screen size in the dump.
    private static func rootBounds(in dump: String) -> CGRect? {
        firstBounds(in: dump)
    }

    /// The non-empty `text` attributes of the dump, for scroll comparisons.
    private static func visibleTexts(in dump: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"text="([^"]+)""#) else {
            return []
        }
        let range = NSRange(dump.startIndex..., in: dump)
        return Set(regex.matches(in: dump, range: range).compactMap { match in
            Range(match.range(at: 1), in: dump).map { String(dump[$0]) }
        })
    }

    private static func firstBounds(in dump: String) -> CGRect? {
        guard
            let regex = try? NSRegularExpression(
                pattern: #"bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]""#
            ),
            let match = regex.firstMatch(
                in: dump,
                range: NSRange(dump.startIndex..., in: dump)
            ),
            match.numberOfRanges == 5
        else { return nil }

        func value(at index: Int) -> Int? {
            Range(match.range(at: index), in: dump).flatMap { Int(dump[$0]) }
        }
        guard let x1 = value(at: 1), let y1 = value(at: 2),
              let x2 = value(at: 3), let y2 = value(at: 4)
        else { return nil }
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    /// A host-time anchor paired with the device's monotonic uptime, read
    /// together. PTS comes from the device's monotonic clock, so the anchor is
    /// all that is needed to translate it into host time; the tightest of
    /// several adb round trips is kept and its half is the alignment error.
    private struct DeviceClock {
        /// Host time at the midpoint of the uptime read.
        let hostAnchor: Date
        /// Device `/proc/uptime` (seconds in the first field) in milliseconds.
        let uptimeMs: Double
        /// The adb round trip this sample was read with.
        let roundTripMs: Double
    }

    private static func readDeviceClock(adb: AdbClient, serial: String) async -> DeviceClock {
        var best: DeviceClock?
        for _ in 0..<5 {
            let before = Date()
            guard let output = try? await adb.shell(serial: serial, ["cat", "/proc/uptime"]),
                  let uptime = Double(
                      output.split(whereSeparator: \.isNewline).first?
                          .split(separator: " ").first ?? ""
                  )
            else { continue }
            let after = Date()

            let candidate = DeviceClock(
                hostAnchor: before.addingTimeInterval(after.timeIntervalSince(before) / 2),
                uptimeMs: uptime * 1000,
                roundTripMs: after.timeIntervalSince(before) * 1000
            )
            if best == nil || candidate.roundTripMs < best!.roundTripMs {
                best = candidate
            }
        }
        return best ?? DeviceClock(hostAnchor: Date(), uptimeMs: 0, roundTripMs: 0)
    }

    private struct Measurement {
        let fps: Double
        let endToEndMs: Double
        let endToEndStdMs: Double
        let meanHostAgeMs: Double
        let meanDeviceAgeMs: Double
    }

    /// fps over the fixed measurement window; end-to-end latency is
    /// `hostReceive − hostAt(pts)`, where the device monotonic clock is
    /// anchored to host time by the uptime read. Capture (encoder PTS) →
    /// decode, with the alignment's half-round-trip as error.
    private static func summarize(
        samples: [MeasurementCollector.Sample],
        clock: DeviceClock,
        windowSeconds: Double
    ) -> Measurement {
        guard !samples.isEmpty else {
            return Measurement(
                fps: 0, endToEndMs: 0, endToEndStdMs: 0,
                meanHostAgeMs: 0, meanDeviceAgeMs: 0
            )
        }
        let fps = Double(samples.count) / windowSeconds
        let latencies = samples.map { sample -> Double in
            let hostSinceAnchorMs = sample.host.timeIntervalSince(clock.hostAnchor) * 1000
            let ptsMs = Double(sample.pts) / 1000
            return hostSinceAnchorMs - (ptsMs - clock.uptimeMs)
        }
        let meanHostAge = samples.reduce(0.0) {
            $0 + $1.host.timeIntervalSince(clock.hostAnchor) * 1000
        } / Double(samples.count)
        let meanDeviceAge = samples.reduce(0.0) {
            $0 + (Double($1.pts) / 1000 - clock.uptimeMs)
        } / Double(samples.count)
        let mean = latencies.reduce(0, +) / Double(latencies.count)
        let variance = latencies.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(latencies.count)
        return Measurement(
            fps: fps,
            endToEndMs: mean,
            endToEndStdMs: variance.squareRoot(),
            meanHostAgeMs: meanHostAge,
            meanDeviceAgeMs: meanDeviceAge
        )
    }

    private final class MeasurementCollector: @unchecked Sendable {
        struct Sample {
            let pts: Int64
            let host: Date
        }

        private let lock = NSLock()
        private var samples: [Sample] = []

        func record(pts: Int64, host: Date) {
            lock.lock()
            samples.append(Sample(pts: pts, host: host))
            if samples.count > 20_000 {
                samples.removeFirst(samples.count - 20_000)
            }
            lock.unlock()
        }

        func snapshot() -> [Sample] {
            lock.lock()
            defer { lock.unlock() }
            return samples
        }
    }
}
