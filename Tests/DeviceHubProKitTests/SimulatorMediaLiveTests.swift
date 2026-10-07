import AVFoundation
import CoreGraphics
import ImageIO
import XCTest
@testable import DeviceHubProKit

/// The simulator media tools against a real simulator, behind
/// `DHP_IOS_LIVE=1` (they skip otherwise):
///
///     DHP_IOS_LIVE=1 swift test --filter SimulatorMediaLiveTests
///
/// It creates an iPhone in a private device set (`LiveTestSimulators`),
/// boots it and, with the log stream started right after `boot`, measures the
/// stream through the boot's burst and settled; then the pasteboard round
/// trip with Turkish text and its change notification, `openurl` (a page, an
/// unknown scheme), a screenshot from the live canvas's frame beside simctl's
/// own (when the bridge may load), and a `recordVideo` stopped with SIGINT.
/// It deletes the device, its set and its log folder at the end. The numbers
/// it prints are the ones the parity audit quotes.
final class SimulatorMediaLiveTests: XCTestCase {
    func testTheMediaToolsOnARealSimulator() async throws {
        let toolchain = try await LiveTestSimulators.toolchain()
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
        let device = try await simulators.createDevice(name: "DeviceHubPro-MediaLive")
        let udid = device.udid
        let simctl = simulators.simctl
        Self.report("created \(udid) in \(simulators.setDirectory.path)")

        // The log stream from right after `boot`: a first boot's burst.
        let bootStarted = ContinuousClock.now
        try await simctl.boot(udid: udid)
        let log = SimulatorLogStream(simctl: simctl, udid: udid, level: .debug)
        log.start()
        defer { log.stop() }
        try await waitUntil(timeout: .seconds(60)) { log.snapshot().last != nil || log.status != .running }
        let streamStarted = ContinuousClock.now
        let finished = try await simctl.bootStatus(udid: udid)
        XCTAssertEqual(finished?.isFinished, true)
        let burstSeconds = Self.seconds(ContinuousClock.now - streamStarted)
        let burstEvents = log.snapshot().last.map { Int($0.id) } ?? 0
        Self.report(String(format: "boot → Finished %.1f s; log stream during it: %d events in %.1f s (%.0f/s)",
                           Self.seconds(ContinuousClock.now - bootStarted), burstEvents, burstSeconds,
                           Double(burstEvents) / max(burstSeconds, 0.001)))
        XCTAssertGreaterThan(burstEvents, 0)

        // Settled: 10 s once the home screen shows.
        let screen = simulators.setDirectory.appendingPathComponent("home.png")
        let homeDeadline = ContinuousClock.now + .seconds(90)
        var home = false
        while !home, ContinuousClock.now < homeDeadline {
            try await simctl.screenshot(udid: udid, to: screen, timeout: .seconds(20))
            home = SimulatorReadiness.showsHomeScreen(imageAt: screen) == true
        }
        XCTAssertTrue(home, "the home screen")
        try await Task.sleep(for: .seconds(5))
        let settledFirst = log.snapshot().last.map { Int($0.id) } ?? 0
        try await Task.sleep(for: .seconds(10))
        let settledLast = log.snapshot().last.map { Int($0.id) } ?? 0
        Self.report(String(format: "log stream settled: %.0f events/s over 10 s", Double(settledLast - settledFirst) / 10))
        XCTAssertEqual(log.status, .running)
        let levels = Set(log.logcatSnapshot().map(\.level))
        Self.report("levels seen: \(levels.map(\.rawValue).sorted().joined())")
        XCTAssertTrue(levels.isSubset(of: [.verbose, .debug, .info, .error, .fatal]))

        // Following one app by its process: only Safari's events come.
        let safari = SimulatorLogStream(
            simctl: simctl,
            udid: udid,
            level: .debug,
            predicate: SimulatorLogStream.processPredicate("MobileSafari")
        )
        safari.start()
        defer { safari.stop() }

        // The pasteboard, both ways, with Turkish text, and its notification.
        let posts = Counter()
        let watch = Task {
            try await simctl.watchDarwinNotification(udid: udid, name: SimctlClient.pasteboardChangedNotification) {
                posts.increment()
            }
        }
        try await Task.sleep(for: .seconds(2))
        let text = "Merhaba dünya: ğüşiöç İĞÜŞÖÇ ı"
        let copied = ContinuousClock.now
        try await simctl.setPasteboard(udid: udid, text: text)
        try await waitUntil(timeout: .seconds(10)) { posts.value >= 1 }
        Self.report(String(format: "pasteboard change notification %.0f ms after pbcopy returned",
                           Self.seconds(ContinuousClock.now - copied) * 1000))
        let pasted = try await simctl.pasteboard(udid: udid)
        XCTAssertEqual(pasted, text, "byte-exact UTF-8 round trip")
        try await simctl.setPasteboard(udid: udid, text: "ikinci")
        try await waitUntil(timeout: .seconds(10)) { posts.value >= 2 }
        watch.cancel()
        _ = try? await watch.value

        // openurl: Safari takes a page; an unknown scheme is refused.
        try await simctl.openURL(udid: udid, url: try XCTUnwrap(URL(string: "https://example.com")))
        do {
            try await simctl.openURL(udid: udid, url: try XCTUnwrap(URL(string: "nosuchscheme-devicehubpro://x")))
            XCTFail("an unknown scheme opened")
        } catch let failure as SimctlFailure {
            XCTAssertEqual(failure.error, SimctlErrorReference(domain: "LSApplicationWorkspaceErrorDomain", code: 115))
        }
        try await waitUntil(timeout: .seconds(20)) { safari.snapshot().contains { $0.process == "MobileSafari" } }
        XCTAssertTrue(safari.snapshot().allSatisfy { $0.process == "MobileSafari" }, "only Safari's events")
        Self.report("followed Safari: \(safari.snapshot().count) events, all MobileSafari")

        // A screenshot from the live canvas's frame, beside simctl's.
        try await Task.sleep(for: .seconds(3))
        try await compareCanvasScreenshot(simulators, udid: udid)

        // recordVideo stopped with SIGINT.
        let movie = simulators.setDirectory.appendingPathComponent("clip.mp4")
        let recording = Task {
            try await simctl.recordVideo(udid: udid, to: movie, codec: .h264)
        }
        try await Task.sleep(for: .seconds(4))
        _ = try await simctl.launch(udid: udid, bundleIdentifier: "com.apple.Preferences")
        try await Task.sleep(for: .seconds(2))
        recording.cancel()
        try await recording.value
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        let formats = try await track.load(.formatDescriptions)
        let codec = try XCTUnwrap(formats.first.map { CMFormatDescriptionGetMediaSubType($0) })
        let fourCC = String(bytes: withUnsafeBytes(of: codec.bigEndian) { Array($0) }, encoding: .ascii) ?? "?"
        let bytes = (try? FileManager.default.attributesOfItem(atPath: movie.path)[.size] as? Int) ?? 0
        Self.report(String(format: "recordVideo: %.2f s, %.0fx%.0f, %@, %d bytes", duration, size.width, size.height, fourCC, bytes))
        XCTAssertEqual(fourCC, "avc1")
        XCTAssertGreaterThan(duration, 3)
    }

    /// The live canvas's frame as a PNG (`FrameImage`, tagged sRGB) against
    /// `simctl io screenshot` taken right after it, the Dynamic Island rows
    /// left out (only the framebuffer draws it).
    private func compareCanvasScreenshot(_ simulators: LiveTestSimulators.Session, udid: String) async throws {
        let installed = BridgeCompatibility.installedCoreSimulatorVersion()
        guard BridgeCompatibility.verdict(coreSimulatorVersion: installed).allowsBridge else {
            Self.report("canvas screenshot skipped: the bridge is off on CoreSimulator \(installed ?? "?")")
            return
        }
        let session = SimulatorMirrorSession(
            udid: udid,
            deviceSet: simulators.setDirectory,
            bridge: LiveSimulatorBridge(),
            simctl: simulators.simctl
        )
        defer { session.stopAndWait() }
        session.start()
        try await waitUntil(timeout: .seconds(5)) { session.frames.current != nil }
        // Let the screen settle, so both captures show the same picture.
        try await Task.sleep(for: .seconds(2))
        let frame = try XCTUnwrap(session.frames.current)
        let started = ContinuousClock.now
        let png = try XCTUnwrap(FrameImage.pngData(from: frame))
        let encode = Self.seconds(ContinuousClock.now - started) * 1000
        let shot = simulators.setDirectory.appendingPathComponent("shot.png")
        try await simulators.simctl.screenshot(udid: udid, to: shot)

        let ours = try XCTUnwrap(Self.rgba(png))
        let theirs = try XCTUnwrap(Self.rgba(try Data(contentsOf: shot)))
        XCTAssertEqual(ours.width, theirs.width)
        XCTAssertEqual(ours.height, theirs.height)
        XCTAssertEqual(ours.colorSpace, CGColorSpace.sRGB as String)
        let skipped = 160
        var sum = 0
        var count = 0
        for row in skipped..<ours.height {
            for column in 0..<(ours.width * 4) where column % 4 != 3 {
                let index = row * ours.width * 4 + column
                sum += abs(Int(ours.bytes[index]) - Int(theirs.bytes[index]))
                count += 1
            }
        }
        let difference = Double(sum) / Double(max(count, 1))
        Self.report(String(format: "canvas screenshot %dx%d, PNG %d bytes in %.0f ms; MAD against simctl's %.3f",
                           ours.width, ours.height, png.count, encode, difference))
        XCTAssertLessThan(difference, 3)
    }

    private static func rgba(_ png: Data) -> (bytes: [UInt8], width: Int, height: Int, colorSpace: String?)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (bytes, image.width, image.height, image.colorSpace?.name as String?)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func report(_ line: String) {
        print("MEDIA-LIVE \(line)")
    }

    private func waitUntil(timeout: Duration, _ condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("condition not met within \(timeout)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private final class Counter: @unchecked Sendable {
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
}
