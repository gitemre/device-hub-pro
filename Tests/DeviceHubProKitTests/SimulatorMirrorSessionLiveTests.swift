import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import ImageIO
import XCTest
@testable import DeviceHubProKit

/// `SimulatorMirrorSession` and `SimulatorHardwareActions` against a real
/// simulator, behind `DHP_IOS_LIVE=1`:
///
///     DHP_IOS_LIVE=1 swift test --filter SimulatorMirrorSessionLiveTests
///
/// PRIVATE-API CoreSimulator 1171.7: the live canary for the bridge fixture
/// `orientation-uiOrientation.txt` and for the frame contract (upright
/// frames). The test creates an iPhone 17 Pro in a private device set
/// (`LiveTestSimulators`), boots it and deletes it afterwards with its set
/// and log folders. On the way it measures (printed as `MIRROR-LIVE` lines):
/// time to the first frame, the test process's CPU on an idle screen and
/// while dragging, the published frame rate while dragging Settings, copy
/// times upright and turned, and seed retries and torn frames.
///
/// Then, with Safari open, it turns the device to each orientation through
/// the GSEvent (a private set has no devicectl) and compares the published
/// frame with `simctl io screenshot` taken right after it: same size, and a
/// mean absolute difference per channel below `maximumDifference`, leaving
/// out the panel's top 160 rows, where the framebuffer draws the Dynamic
/// Island and the screenshot does not. It taps in landscape and checks the
/// frame changed, types through the HID keyboard and reads the field back
/// through the pasteboard, swipes Home from the displayed bottom edge in
/// landscape, and presses Home. Last, it checks that no SimulatorKit image
/// was mapped into the process.
///
/// It is also the live canary for the keyboard captures
/// (`SimulatorKeyboardTests`): the layout read from the simulator's
/// `.GlobalPreferences.plist` must match its `AppleLocale` (Turkish Q for
/// `tr`, U.S. for `en_US`; other locales are not checked), and text that
/// only that layout's keys type must read back exactly. The simulator takes
/// the Mac's locale, so a `tr_TR` Mac checks Turkish Q and an `en_US` Mac
/// (CI) checks U.S.; with a layout the tables do not know, typing is left
/// unchecked and the run prints why.
///
/// With `DHP_IOS_CAPTURE_DIR` set, the orientation rows are also written
/// there as `orientation-uiOrientation.txt`, the fixture's source.
final class SimulatorMirrorSessionLiveTests: XCTestCase {
    /// Per channel, 0–255. See the spec (§3.4) for the values measured: the
    /// matching picture and, as a control, the same frame compared half
    /// turned (printed with each row).
    static let maximumDifference = 3.0
    /// The framebuffer's rows that hold the Dynamic Island (y 0–152 differed
    /// in the spike's pixel check), rounded up.
    static let islandRows = 160

    private let background = DispatchQueue(label: "SimulatorMirrorSessionLiveTests.bridge")

    private func onBackground<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            background.async { continuation.resume(with: Result { try body() }) }
        }
    }

    private static func report(_ line: String) {
        print("MIRROR-LIVE \(line)")
    }

    /// The keyboard layout a simulator with this `AppleLocale` must get, or
    /// nil for a locale the tables do not cover (then nothing is checked).
    static func layout(forLocale locale: String?) -> SimulatorKeyboardLayout? {
        guard let locale else { return nil }
        let identifier = locale.split(separator: "@").first.map(String.init) ?? locale
        if identifier == "tr" || identifier.hasPrefix("tr_") { return .turkishQ }
        if identifier == "en_US" { return .usQWERTY }
        return nil
    }

    /// Text the layout types key by key, with Shift and symbols: Turkish
    /// letters on Turkish Q (where @ is Option+Q), ASCII on U.S.
    static func typingProbe(for layout: SimulatorKeyboardLayout) -> String {
        switch layout {
        case .turkishQ: return "0 İş ğ@Ç?"
        case .usQWERTY: return "0 Is g@C?"
        }
    }

    /// The canary's own rules, without a simulator: each probe is typed
    /// with keys only (a paste would not arrive, see the spec, §3.4).
    func testTheKeyboardCanaryTypesEveryProbeWithKeys() {
        XCTAssertEqual(Self.layout(forLocale: "tr_TR"), .turkishQ)
        XCTAssertEqual(Self.layout(forLocale: "en_US"), .usQWERTY)
        XCTAssertNil(Self.layout(forLocale: "en_GB"))
        XCTAssertNil(Self.layout(forLocale: "de_DE"))
        XCTAssertNil(Self.layout(forLocale: nil))
        for layout in SimulatorKeyboardLayout.allCases {
            let probe = Self.typingProbe(for: layout)
            let steps = SimulatorKeyboard.steps(for: probe, layout: layout)
            XCTAssertEqual(steps.count, probe.count, "\(layout)")
            XCTAssertFalse(steps.contains { if case .paste = $0 { return true } else { return false } }, "\(layout)")
        }
    }

    // swiftlint:disable:next function_body_length
    func testTheSessionMirrorsRotatesAndDrivesALiveSimulator() async throws {
        let toolchain = try await LiveTestSimulators.toolchain()
        let installed = BridgeCompatibility.installedCoreSimulatorVersion()
        guard BridgeCompatibility.verdict(coreSimulatorVersion: installed).allowsBridge else {
            throw XCTSkip("the bridge is off on CoreSimulator \(installed ?? "?")")
        }
        let simulators = try LiveTestSimulators.Session(toolchain: toolchain)
        do {
            try await exercise(simulators)
        } catch {
            let leftovers = await simulators.tearDown()
            XCTAssertEqual(leftovers, [])
            throw error
        }
        let leftovers = await simulators.tearDown()
        XCTAssertEqual(leftovers, [])
    }

    private func exercise(_ simulators: LiveTestSimulators.Session) async throws {
        let device = try await simulators.createDevice(name: "DeviceHubPro-MirrorSessionLive")
        let udid = device.udid
        let simctl = simulators.simctl
        print("MIRROR-LIVE created \(udid) in \(simulators.setDirectory.path)")
        try await simctl.bootStatus(udid: udid, bootIfNeeded: true)
        // "Booted" comes long before SpringBoard settles.
        try await Task.sleep(for: .seconds(12))

        let bridge = LiveSimulatorBridge()
        let address = SimulatorAddress(udid: udid, deviceSetPath: simulators.setDirectory.path)
        let session = SimulatorMirrorSession(udid: udid, deviceSet: simulators.setDirectory, bridge: bridge, simctl: simctl)
        defer { session.stopAndWait() }
        let actions = SimulatorHardwareActions(address: address, bridge: bridge, simctl: simctl)
        let probe = try await onBackground { try bridge.makeScreen(for: address) }

        // First frame, with no input and no frame callback needed.
        let started = Date()
        session.start()
        let firstFrame = await waitUntil(5) { session.frames.current != nil }
        XCTAssertTrue(firstFrame, "a frame after start: \(session.lastError ?? "")")
        let firstFrameSeconds = Date().timeIntervalSince(started)
        Self.report(String(format: "first frame %.0f ms", firstFrameSeconds * 1000))
        XCTAssertLessThan(firstFrameSeconds, 3, "the T3 bound")
        XCTAssertEqual(session.frames.current?.width, 1206)
        XCTAssertEqual(session.frames.current?.height, 2622)
        XCTAssertEqual(session.frames.current?.rotation, 0)
        XCTAssertEqual(session.transport, .simulatorSurface)

        // Idle: no copies, little CPU.
        await waitForIdle(session, quiet: 1.5, timeout: 20)
        let homeReference = try XCTUnwrap(Pixels(session.frames.current))
        let idleStart = session.surfaceStatistics()
        let idleCPU = await cpuPercent(over: 10)
        let idleEnd = session.surfaceStatistics()
        Self.report(String(format: "idle 10 s: cpu %.2f%% of one core, callbacks %d, published %d",
                           idleCPU, idleEnd.frameCallbacks - idleStart.frameCallbacks, idleEnd.publishedFrames - idleStart.publishedFrames))
        // The home screen still changes now and then (the clock, a widget):
        // every publish must answer a callback, and the process stays quiet.
        let idleCallbacks = idleEnd.frameCallbacks - idleStart.frameCallbacks
        XCTAssertLessThanOrEqual(idleEnd.publishedFrames - idleStart.publishedFrames, idleCallbacks + 1, "no publish without a change")
        XCTAssertLessThan(idleCPU, 3, "idle CPU bound")

        // Dragging Settings: frames flow at up to 60 per second.
        _ = try await simctl.launch(udid: udid, bundleIdentifier: "com.apple.Preferences")
        try await Task.sleep(for: .seconds(2))
        await waitForIdle(session, quiet: 1.0, timeout: 20)
        let dragBefore = session.surfaceStatistics()
        var peakFPS = 0.0
        let (dragCPU, dragSeconds) = await measuringCPU {
            for gesture in 0..<8 {
                let (from, to) = gesture.isMultiple(of: 2) ? (1900.0, 800.0) : (800.0, 1900.0)
                await self.drag(session, x: 603, fromY: from, toY: to, steps: 24)
                peakFPS = max(peakFPS, session.surfaceStatistics().publishFPS)
            }
        }
        // Up to the last touch: the fling that follows is not dragging.
        let dragAfter = session.surfaceStatistics()
        await waitForIdle(session, quiet: 0.8, timeout: 10)
        let dragged = dragAfter.publishedFrames - dragBefore.publishedFrames
        Self.report(String(format: "drag %.2f s: published %d (%.1f fps; best second %.0f), callbacks %d, coalesced %d, retried %d, torn %d, cpu %.1f%%",
                           dragSeconds, dragged, Double(dragged) / dragSeconds, peakFPS,
                           dragAfter.frameCallbacks - dragBefore.frameCallbacks,
                           dragAfter.coalescedCallbacks - dragBefore.coalescedCallbacks,
                           dragAfter.retriedCopies - dragBefore.retriedCopies,
                           dragAfter.tornFrames - dragBefore.tornFrames, dragCPU))
        XCTAssertGreaterThanOrEqual(dragged, 30, "frames while dragging")
        XCTAssertNil(session.lastError)

        // Safari, then each orientation against a screenshot.
        try await simctl.checked(["openurl", udid, "https://example.com"])
        try await Task.sleep(for: .seconds(4))
        await waitForIdle(session, quiet: 1.0, timeout: 20)
        var captureRows = ["request\tgs_event\tui_orientation\tscreenshot\tpublished"]
        var previousRotation = SimulatorFrameRotation.upright
        for orientation in [SimulatorOrientation.landscapeLeft, .landscapeRight, .portraitUpsideDown, .portrait] {
            let route = try await actions.rotate(to: orientation)
            XCTAssertEqual(route, .gsEvent, "a private set has no devicectl")
            try await Task.sleep(for: .milliseconds(600))
            await waitForIdle(session, quiet: 1.0, timeout: 10)
            let properties = try await onBackground { try probe.currentProperties() }
            let rotation = SimulatorFrameRotation(uiOrientation: properties.uiOrientation)
            XCTAssertEqual(session.publishedRotation, rotation, "\(orientation)")
            let frame = try XCTUnwrap(Pixels(session.frames.current))
            let shotURL = simulators.setDirectory.appendingPathComponent("shot-\(orientation.rawValue).png")
            try await simctl.screenshot(udid: udid, to: shotURL, timeout: .seconds(20))
            let shot = try XCTUnwrap(Pixels(png: shotURL))
            XCTAssertEqual(frame.width, shot.width, "\(orientation)")
            XCTAssertEqual(frame.height, shot.height, "\(orientation)")
            let difference = frame.meanAbsoluteDifference(shot, rotation: rotation, skippingNativeRows: Self.islandRows)
            let control = frame.meanAbsoluteDifference(shot.turnedHalf(), rotation: rotation, skippingNativeRows: Self.islandRows)
            Self.report(String(format: "%@: gs %u -> uiOrientation %u, screenshot %dx%d, published %dx%d, MAD %.3f (half-turned control %.1f)",
                               orientation.rawValue, orientation.gsEventValue, properties.uiOrientation,
                               shot.width, shot.height, frame.width, frame.height, difference, control))
            XCTAssertLessThan(difference, Self.maximumDifference, "\(orientation)")
            if orientation == .portraitUpsideDown {
                XCTAssertEqual(rotation, previousRotation, "a Face ID iPhone never turns its interface upside down")
            }
            previousRotation = rotation
            captureRows.append("\(orientation.rawValue)\t\(orientation.gsEventValue)\t\(properties.uiOrientation)\t\(shot.width)x\(shot.height)\t\(frame.width)x\(frame.height)")
        }
        if let directory = ProcessInfo.processInfo.environment["DHP_IOS_CAPTURE_DIR"], !directory.isEmpty {
            try (captureRows.joined(separator: "\n") + "\n").write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("orientation-uiOrientation.txt"),
                atomically: true, encoding: .utf8
            )
        }

        // Landscape: a drag for turned-copy times, then a tap on the address
        // bar changes the frame.
        _ = try await actions.rotate(to: .landscapeLeft)
        try await Task.sleep(for: .milliseconds(800))
        await waitForIdle(session, quiet: 1.0, timeout: 10)
        XCTAssertEqual(session.publishedRotation, .counterClockwise)
        XCTAssertEqual(session.frames.current?.width, 2622)
        for gesture in 0..<4 {
            let (from, to) = gesture.isMultiple(of: 2) ? (900.0, 400.0) : (400.0, 900.0)
            await drag(session, x: 1311, fromY: from, toY: to, steps: 20)
        }
        await waitForIdle(session, quiet: 1.0, timeout: 10)
        let beforeTap = try XCTUnwrap(Pixels(session.frames.current))
        let tapFrames = session.surfaceStatistics().publishedFrames
        // The address field, centred in the landscape toolbar.
        session.send(TouchCommand(phase: .down, x: 1311, y: 98, id: 9))
        try await Task.sleep(for: .milliseconds(60))
        session.send(TouchCommand(phase: .up, x: 1311, y: 98, id: 9))
        let tapped = await waitUntil(2) { session.surfaceStatistics().publishedFrames > tapFrames }
        XCTAssertTrue(tapped, "a frame after the landscape tap")
        await waitForIdle(session, quiet: 1.0, timeout: 10)
        let afterTap = try XCTUnwrap(Pixels(session.frames.current))
        let tapChange = beforeTap.differingShare(afterTap)
        Self.report(String(format: "landscape tap changed %.1f%% of the sampled pixels", tapChange * 100))
        XCTAssertGreaterThan(tapChange, 0.02, "the landscape tap focused the address field")

        // Typing into the focused field, read back through the pasteboard.
        // The simulator inherits the Mac's locale, and its hardware keyboard
        // layout follows: the layout read from its preferences must match the
        // locale, and text only that layout's keys can type must arrive
        // exactly. "0" first: no autocompletion starts with it.
        let preferencesURL = SimulatorKeyboard.globalPreferencesURL(udid: udid, deviceSet: simulators.setDirectory)
        let preferences = try PropertyListSerialization.propertyList(from: Data(contentsOf: preferencesURL), format: nil) as? [String: Any]
        let locale = preferences?["AppleLocale"] as? String
        let layout = SimulatorKeyboard.layout(udid: udid, deviceSet: simulators.setDirectory)
        Self.report("simulator locale \(locale ?? "none"), keyboard layout \(layout.map { "\($0)" } ?? "unknown")")
        if let expected = Self.layout(forLocale: locale) {
            XCTAssertEqual(layout, expected, "the layout chosen from the preferences of a \(locale ?? "") simulator")
        }
        if let layout {
            let typed = Self.typingProbe(for: layout)
            session.send(.text(typed))
            session.send(.text("😀"))
            try await Task.sleep(for: .seconds(2))
            let input = try await onBackground { bridge.makeInput(for: address) }
            try await onBackground {
                for event in SimulatorKeyStroke(usage: 0x04, modifiers: [SimulatorKeyboard.leftCommand]).events
                    + SimulatorKeyStroke(usage: 0x06, modifiers: [SimulatorKeyboard.leftCommand]).events {
                    try input.send(event)
                }
                try input.flush(timeout: .seconds(2))
            }
            try await Task.sleep(for: .milliseconds(500))
            let readBack = try await simctl.pasteboard(udid: udid)
            Self.report("typed \"\(typed)\" + paste \"😀\", field read back \"\(readBack)\"")
            XCTAssertTrue(readBack.hasPrefix(typed), "the HID-typed text arrived exactly: \(readBack)")
            try await onBackground { input.disconnect() }
        } else {
            // No table for this layout: the session would type U.S. key
            // positions, so there is nothing exact to check.
            Self.report("typing not checked: no table for this simulator's keyboard layout")
        }

        // Home from the displayed bottom edge, in landscape.
        session.send(.specialKey(53))  // escape, to leave the field
        try await Task.sleep(for: .milliseconds(500))
        await swipeUpFromBottom(session, width: 2622, height: 1206)
        try await Task.sleep(for: .seconds(1.5))
        await waitForIdle(session, quiet: 1.0, timeout: 10)
        let afterSwipe = try XCTUnwrap(Pixels(session.frames.current))
        let swipeHome = afterSwipe.width == homeReference.width ? afterSwipe.differingShare(homeReference) : 1
        Self.report(String(format: "landscape bottom-edge swipe: frame %dx%d, %.1f%% differs from the home screen",
                           afterSwipe.width, afterSwipe.height, swipeHome * 100))
        XCTAssertLessThan(swipeHome, 0.15, "the edge swipe went Home")

        // Home button: from Safari back to the home screen.
        _ = try await actions.rotate(to: .portrait)
        try await simctl.checked(["openurl", udid, "https://example.com"])
        try await Task.sleep(for: .seconds(3))
        await waitForIdle(session, quiet: 1.0, timeout: 10)
        let inSafari = try XCTUnwrap(Pixels(session.frames.current))
        XCTAssertGreaterThan(inSafari.differingShare(homeReference), 0.2)
        try await actions.home()
        try await Task.sleep(for: .seconds(1.5))
        await waitForIdle(session, quiet: 1.0, timeout: 10)
        let home = try XCTUnwrap(Pixels(session.frames.current))
        let homeDifference = home.differingShare(homeReference)
        Self.report(String(format: "Home: %.1f%% differs from the home screen", homeDifference * 100))
        XCTAssertLessThan(homeDifference, 0.15, "Home returned to the home screen")

        let statistics = session.surfaceStatistics()
        Self.report(String(format: "copies upright n=%d p50 %.2f ms p95 %.2f ms; turned n=%d p50 %.2f ms p95 %.2f ms",
                           statistics.uprightCopies.count, statistics.uprightCopies.p50, statistics.uprightCopies.p95,
                           statistics.rotatedCopies.count, statistics.rotatedCopies.p50, statistics.rotatedCopies.p95))
        Self.report("totals: callbacks \(statistics.frameCallbacks), published \(statistics.publishedFrames), coalesced \(statistics.coalescedCallbacks), retried \(statistics.retriedCopies), torn \(statistics.tornFrames), copy failures \(statistics.copyFailures), latency \(String(format: "%.1f", statistics.averageLatencyMilliseconds)) ms")
        XCTAssertEqual(statistics.copyFailures, 0)
        XCTAssertTrue(session.isRunning)

        // Frames, touch, the keyboard, the GSEvents and the buttons all ran
        // without SimulatorKit (PROVENANCE.md).
        let simulatorKit = LiveSimulatorBridge.diagnostics.simulatorKitLoaded
        Self.report("SimulatorKit mapped after frames, touch, keyboard, GSEvents and buttons: \(simulatorKit ? "yes" : "no")")
        XCTAssertFalse(simulatorKit, "the bridge must not need SimulatorKit")

        // Shutting the simulator down stops the session itself.
        try await simctl.shutdown(udid: udid)
        let stopped = await waitUntil(15) { !session.isRunning }
        XCTAssertTrue(stopped)
        XCTAssertEqual(session.lastError, SimulatorMirrorSession.shutDownMessage)
        try await onBackground { probe.stop() }
    }

    // MARK: - Gestures

    /// A vertical drag in displayed-frame pixels, a move every 16 ms.
    private func drag(_ session: SimulatorMirrorSession, x: Double, fromY: Double, toY: Double, steps: Int) async {
        session.send(TouchCommand(phase: .down, x: Int32(x), y: Int32(fromY), id: 1))
        for step in 1...steps {
            let y = fromY + (toY - fromY) * Double(step) / Double(steps)
            try? await Task.sleep(for: .milliseconds(16))
            session.send(TouchCommand(phase: .move, x: Int32(x), y: Int32(y), id: 1))
        }
        session.send(TouchCommand(phase: .up, x: Int32(x), y: Int32(toY), id: 1))
    }

    /// A quick swipe up from the displayed bottom edge.
    private func swipeUpFromBottom(_ session: SimulatorMirrorSession, width: Int, height: Int) async {
        let x = Int32(width / 2)
        let startY = Double(height - 3)
        let endY = Double(height) * 0.55
        session.send(TouchCommand(phase: .down, x: x, y: Int32(startY), id: 3))
        for step in 1...5 {
            try? await Task.sleep(for: .milliseconds(16))
            session.send(TouchCommand(phase: .move, x: x, y: Int32(startY + (endY - startY) * Double(step) / 5), id: 3))
        }
        session.send(TouchCommand(phase: .up, x: x, y: Int32(endY), id: 3))
    }

    // MARK: - Waiting and measuring

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Waits until nothing was published for `quiet` seconds.
    private func waitForIdle(_ session: SimulatorMirrorSession, quiet: TimeInterval, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        var last = session.surfaceStatistics().publishedFrames
        var since = Date()
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            let now = session.surfaceStatistics().publishedFrames
            if now != last {
                last = now
                since = Date()
            } else if Date().timeIntervalSince(since) >= quiet {
                return
            }
        }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// This process's CPU over `seconds`, in percent of one core.
    private func cpuPercent(over seconds: Double) async -> Double {
        let (percent, _) = await measuringCPU { try? await Task.sleep(for: .seconds(seconds)) }
        return percent
    }

    private func measuringCPU(_ body: () async -> Void) async -> (Double, Double) {
        let cpuStart = Self.cpuSeconds()
        let wallStart = Date()
        await body()
        let wall = Date().timeIntervalSince(wallStart)
        return ((Self.cpuSeconds() - cpuStart) / wall * 100, wall)
    }
}

/// BGRA pixels copied out of a frame or a PNG.
private struct Pixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    init?(_ frame: Frame?) {
        guard let buffer = frame?.pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<(width * 4) {
                bytes[row * width * 4 + column] = base[row * rowBytes + column]
            }
        }
        self.init(width: width, height: height, bytes: bytes)
    }

    /// Decodes a PNG into BGRA in the image's own colour space, so no colour
    /// conversion moves a byte.
    init?(png url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, bytes: bytes)
    }

    func turnedHalf() -> Pixels {
        var turned = [UInt8](repeating: 0, count: bytes.count)
        for y in 0..<height {
            for x in 0..<width {
                let from = (y * width + x) * 4
                let to = ((height - 1 - y) * width + (width - 1 - x)) * 4
                for channel in 0..<4 { turned[to + channel] = bytes[from + channel] }
            }
        }
        return Pixels(width: width, height: height, bytes: turned)
    }

    /// Mean absolute difference per colour channel, skipping the pixels that
    /// show the panel's first `skippingNativeRows` rows.
    func meanAbsoluteDifference(_ other: Pixels, rotation: SimulatorFrameRotation, skippingNativeRows skipped: Int) -> Double {
        guard width == other.width, height == other.height else { return .infinity }
        var total = 0
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let nativeY: Int
                switch rotation {
                case .upright: nativeY = y
                case .upsideDown: nativeY = height - 1 - y
                case .clockwise: nativeY = width - 1 - x
                case .counterClockwise: nativeY = x
                }
                if nativeY < skipped { continue }
                let offset = (y * width + x) * 4
                for channel in 0..<3 {
                    total += abs(Int(bytes[offset + channel]) - Int(other.bytes[offset + channel]))
                }
                count += 3
            }
        }
        return count > 0 ? Double(total) / Double(count) : .infinity
    }

    /// The share of a coarse grid of samples that differ clearly.
    func differingShare(_ other: Pixels) -> Double {
        guard width == other.width, height == other.height else { return 1 }
        var differing = 0
        var samples = 0
        for y in stride(from: 0, to: height, by: max(1, height / 80)) {
            for x in stride(from: 0, to: width, by: max(1, width / 40)) {
                let offset = (y * width + x) * 4
                let delta = (0..<3).reduce(0) { $0 + abs(Int(bytes[offset + $1]) - Int(other.bytes[offset + $1])) }
                if delta > 48 { differing += 1 }
                samples += 1
            }
        }
        return Double(differing) / Double(max(1, samples))
    }
}
