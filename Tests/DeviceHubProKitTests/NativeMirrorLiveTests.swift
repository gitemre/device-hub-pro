import CoreGraphics
import CoreVideo
import Foundation
import XCTest
import AppKit
@testable import DeviceHubProKit

/// The native live view on the dedicated test iPhone:
/// the tunnel lease and the stream start, frames are counted for 10 s, and the
/// frame size and rate are checked. Behind switches; skipped otherwise:
///
///     DHP_IOS_DEVICE_LIVE=1 DHP_IPHONE_UDID=<hardware UDID> \
///     DHP_NATIVE_MIRROR_LIVE=1 swift test --filter NativeMirrorLiveTests
///
/// View only: nothing is sent to the phone. The phone must be unlocked and in
/// portrait; the test asserts the screen size of iPhone13,2 (1170x2532) and
/// prints fps and the frame interval p50/p95, never an identifier.
final class NativeMirrorLiveTests: XCTestCase {
    func testNativeMirrorDeliversFramesAtTheScreenSize() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DHP_NATIVE_MIRROR_LIVE"] == "1" else {
            throw XCTSkip("set DHP_NATIVE_MIRROR_LIVE=1 (with the device switches) to run the native live view on the test iPhone")
        }
        try XCTSkipIf(NativeMirrorEndpoint.isDisabled(environment: environment), "the native live view is switched off")
        let connected = try await ApplePhysicalLiveTests.connectedTestIPhone()
        let toolchain = await AppleToolchain.probe()
        let client = connected.client

        let session = try PhysicalNativeMirrorSession.live(hardwareUDID: connected.device.hardwareUDID, environment: environment) {
            (client, toolchain)
        }
        session.start()
        defer { session.stop() }

        // Collect for 10 s, sampling the store's generation.
        let clock = ContinuousClock()
        var stamps: [ContinuousClock.Instant] = []
        var lastGeneration: UInt64 = 0
        var size: (width: Int, height: Int)?
        let deadline = clock.now + .seconds(40)   // startup (lease, negotiation) counts against this
        var windowEnd: ContinuousClock.Instant?
        while clock.now < deadline, session.lastError == nil {
            if let frame = session.frames.current, frame.generation != lastGeneration {
                lastGeneration = frame.generation
                let now = clock.now
                if windowEnd == nil { windowEnd = now + .seconds(10) }
                stamps.append(now)
                size = (frame.width, frame.height)
            }
            if let windowEnd, clock.now >= windowEnd { break }
            try await Task.sleep(for: .milliseconds(4))
        }
        XCTAssertNil(session.lastError, "the stream failed")
        let seen = size
        let intervals = zip(stamps.dropFirst(), stamps).map { later, earlier -> Double in
            let c = earlier.duration(to: later).components
            return Double(c.seconds) * 1000 + Double(c.attoseconds) * 1e-15
        }
        let sorted = intervals.sorted()
        func percentile(_ q: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }
        print(String(format: "native mirror: %d frames in 10 s (%.1f fps), interval p50 %.1f ms / p95 %.1f ms",
                     stamps.count, Double(stamps.count) / 10, percentile(0.5), percentile(0.95)))
        XCTAssertGreaterThanOrEqual(stamps.count, 60)
        if connected.device.productType == "iPhone13,2" {
            XCTAssertEqual(seen?.width, 1170)
            XCTAssertEqual(seen?.height, 2532)
        } else {
            XCTAssertNotNil(seen)
        }
    }

    private func latencyStats(_ stamps: [ContinuousClock.Instant]) -> (p50: Double, p95: Double) {
        let intervals = zip(stamps.dropFirst(), stamps).map { later, earlier -> Double in
            let c = earlier.duration(to: later).components
            return Double(c.seconds) * 1000 + Double(c.attoseconds) * 1e-15
        }.sorted()
        func at(_ q: Double) -> Double { intervals.isEmpty ? 0 : intervals[min(intervals.count - 1, Int(Double(intervals.count - 1) * q))] }
        return (at(0.5), at(0.95))
    }

    private func nativeLiveSetup(_ environment: [String: String]) async throws
        -> (connected: (client: DevicectlPhysicalClient, device: ApplePhysicalDevice), toolchain: AppleToolchain)
    {
        guard environment["DHP_NATIVE_MIRROR_LIVE"] == "1" else {
            throw XCTSkip("set DHP_NATIVE_MIRROR_LIVE=1 (with the device switches) to run the native live view on the test iPhone")
        }
        try XCTSkipIf(NativeMirrorEndpoint.isDisabled(environment: environment), "the native live view is switched off")
        try XCTSkipIf(FastInputSession.isDisabled(environment: environment), "fast input is switched off")
        let connected = try await ApplePhysicalLiveTests.connectedTestIPhone()
        let toolchain = await AppleToolchain.probe()
        return ((connected.client, connected.device), toolchain)
    }

    /// The frame rate while the screen moves: fast swipes across the HOME SCREEN
    /// only (a horizontal swipe changes pages; nothing is tapped), 10 s.
    ///
    ///     ... DHP_NATIVE_MIRROR_LIVE=1 [DHP_FAST_INPUT_DIR=<checkout>/fastinput] \
    ///         swift test --filter NativeMirrorLiveTests/testNativeMirrorFrameRateWhileTheScreenMoves
    func testNativeMirrorFrameRateWhileTheScreenMoves() async throws {
        let environment = ProcessInfo.processInfo.environment
        let setup = try await nativeLiveSetup(environment)
        let client = setup.connected.client
        let fast = try await FastInputSession.live(client: client, toolchain: setup.toolchain, environment: environment) { print("fast input: \($0)") }
        let session = try PhysicalNativeMirrorSession.live(hardwareUDID: setup.connected.device.hardwareUDID, environment: environment) {
            (client, setup.toolchain)
        }

        var failure: Error?
        var stamps: [ContinuousClock.Instant] = []
        do {
            try await fast.start()
            session.start()
            let clock = ContinuousClock()
            let startDeadline = clock.now + .seconds(40)
            while clock.now < startDeadline, session.lastError == nil, session.frames.current == nil {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertNil(session.lastError, "the stream failed")
            try await fast.button(.home)
            try await Task.sleep(for: .seconds(1))

            var lastGeneration = session.frames.current?.generation ?? 0
            let windowEnd = clock.now + .seconds(10)
            var forward = true
            while clock.now < windowEnd {
                let from = CGPoint(x: forward ? 0.8 : 0.2, y: 0.5)
                let to = CGPoint(x: forward ? 0.2 : 0.8, y: 0.5)
                try await fast.down(from)
                let steps = 15
                let swipeStart = clock.now
                for step in 1...steps {
                    let t = Double(step) / Double(steps)
                    try await fast.move(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y))
                    try await Task.sleep(for: .milliseconds(20))
                    while let frame = session.frames.current, frame.generation != lastGeneration {
                        lastGeneration = frame.generation
                        stamps.append(clock.now)
                    }
                }
                try await fast.up(to)
                forward.toggle()
                // Keep counting through the settle of each swipe (about 300 ms in total per swipe).
                while swipeStart.duration(to: clock.now) < .milliseconds(300) { try await Task.sleep(for: .milliseconds(4)) }
                let settleEnd = clock.now + .milliseconds(150)
                while clock.now < settleEnd {
                    if let frame = session.frames.current, frame.generation != lastGeneration {
                        lastGeneration = frame.generation
                        stamps.append(clock.now)
                    }
                    try await Task.sleep(for: .milliseconds(4))
                }
            }
        } catch {
            failure = error
        }
        session.stop()
        try? await fast.button(.home)
        await fast.stop()
        if let failure { throw failure }
        let stat = latencyStats(stamps)
        let fps = Double(stamps.count) / 10
        print(String(format: "native mirror while moving: %d frames in 10 s (%.1f fps), interval p50 %.1f ms / p95 %.1f ms",
                     stamps.count, fps, stat.p50, stat.p95))
        XCTAssertGreaterThanOrEqual(fps, 20)
    }

    /// Thread-safe collector for the latency test's frame hooks.
    private final class LatencyProbe: @unchecked Sendable {
        struct Sample { var instant: ContinuousClock.Instant; var value: Int }
        private let lock = NSLock()
        private var raw: [Sample] = [], published: [Sample] = [], crops: [Double] = []
        private var rawCount = 0, publishedCount = 0
        func addRaw(_ s: Sample) { lock.withLock { raw.append(s); rawCount += 1; if raw.count > 600 { raw.removeFirst(300) } } }
        func addPublished(_ s: Sample) { lock.withLock { published.append(s); publishedCount += 1; if published.count > 600 { published.removeFirst(300) } } }
        func addCrop(_ ms: Double) { lock.withLock { crops.append(ms) } }
        var counts: (raw: Int, published: Int) { lock.withLock { (rawCount, publishedCount) } }
        var cropTimes: [Double] { lock.withLock { crops } }
        var last: (raw: Int?, published: Int?) { lock.withLock { (raw.last?.value, published.last?.value) } }
        func firstRaw(after t0: ContinuousClock.Instant, differingFrom base: Int) -> Sample? {
            lock.withLock { raw.first { $0.instant > t0 && abs($0.value - base) > Self.threshold } }
        }
        func firstPublished(after t0: ContinuousClock.Instant, differingFrom base: Int) -> Sample? {
            lock.withLock { published.first { $0.instant > t0 && abs($0.value - base) > Self.threshold } }
        }
        static let threshold = 40
    }

    /// A colour signature of the pixel at `fx, fy` (fractions) of `region` (the whole
    /// buffer when nil): Cb of a planar YCbCr buffer, or B of a BGRA one. The host app flips
    /// between blue and orange, whose luma differs by only ~35 but whose Cb and B differ by
    /// ~180 and 255 (luma missed every flip on the test iPhone 12).
    private static func signature(_ buffer: CVPixelBuffer, fx: Double, fy: Double, region: CGRect? = nil) -> Int? {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let area = region ?? CGRect(x: 0, y: 0, width: width, height: height)
        let x = min(width - 1, max(0, Int(area.minX + area.width * fx)))
        let y = min(height - 1, max(0, Int(area.minY + area.height * fy)))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        if CVPixelBufferIsPlanar(buffer) {
            guard CVPixelBufferGetPlaneCount(buffer) >= 2, let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            return Int(base.load(fromByteOffset: (y / 2) * stride + (x / 2) * 2, as: UInt8.self))
        }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let p = base.advanced(by: y * stride + x * 4)
        return Int(p.load(as: UInt8.self))
    }

    private static func millis(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private static func summary(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "no samples" }
        let sorted = values.sorted()
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded(.up)))] }
        return String(format: "n=%d min %.1f / median %.1f / p90 %.1f / max %.1f ms", sorted.count, sorted[0], at(0.5), at(0.9), sorted[sorted.count - 1])
    }

    /// Touch to picture: 20 fast-input taps on the host app (`com.devicehubpro.agent.host`, whose
    /// full-screen colour flips on each tap); for each, the time from just before `down` to the
    /// first RAW decoded frame showing the new colour and to the first PUBLISHED (cropped) frame
    /// showing it. Then raw vs published frames over 10 s of home-screen paging swipes and the
    /// cropper's time per frame. Drives only the host app and the home screen; ends with Home.
    ///
    ///     DHP_IOS_DEVICE_LIVE=1 DHP_IPHONE_UDID=<hardware UDID> DHP_NATIVE_MIRROR_LIVE=1 \
    ///     [DHP_FAST_INPUT_DIR=<checkout>/fastinput] \
    ///         swift test --filter NativeMirrorLiveTests/testTouchToFrameLatency
    func testTouchToFrameLatency() async throws {
        let environment = ProcessInfo.processInfo.environment
        let setup = try await nativeLiveSetup(environment)
        let client = setup.connected.client
        let fast = try await FastInputSession.live(client: client, toolchain: setup.toolchain, environment: environment) { print("fast input: \($0)") }
        let session = try PhysicalNativeMirrorSession.live(hardwareUDID: setup.connected.device.hardwareUDID, environment: environment) {
            (client, setup.toolchain)
        }
        let probe = LatencyProbe()
        var diagnostics = PhysicalNativeMirrorSession.Diagnostics()
        diagnostics.onRaw = { buffer, rect, instant in
            if let v = Self.signature(buffer, fx: 0.25, fy: 0.5, region: rect) { probe.addRaw(.init(instant: instant, value: v)) }
        }
        diagnostics.onPublished = { buffer, instant in
            if let v = Self.signature(buffer, fx: 0.25, fy: 0.5) { probe.addPublished(.init(instant: instant, value: v)) }
        }
        diagnostics.onCrop = { probe.addCrop(Self.millis($0)) }
        session.diagnostics = diagnostics

        var failure: Error?
        var rawLatencies: [Double] = [], publishedLatencies: [Double] = [], misses = 0
        var windowCounts: (raw: Int, published: Int) = (0, 0)
        var windowCrops: [Double] = []
        do {
            try await fast.start()
            session.start()
            let clock = ContinuousClock()
            let startDeadline = clock.now + .seconds(40)
            while clock.now < startDeadline, session.lastError == nil, session.frames.current == nil {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertNil(session.lastError, "the stream failed")
            try await client.launchForLiveTest(bundleID: "com.devicehubpro.agent.host")
            try await Task.sleep(for: .seconds(1))

            let point = CGPoint(x: 0.25, y: 0.83)
            for _ in 0..<20 {
                // The phone's screen is static between taps, so the newest samples are the baseline.
                guard let base = probe.last.raw, let basePublished = probe.last.published else {
                    try await Task.sleep(for: .milliseconds(200)); continue
                }
                let t0 = clock.now
                try await fast.down(point)
                try await Task.sleep(for: .milliseconds(10))
                try await fast.up(point)
                let deadline = clock.now + .seconds(2)
                var raw: LatencyProbe.Sample?, published: LatencyProbe.Sample?
                while clock.now < deadline, raw == nil || published == nil {
                    raw = raw ?? probe.firstRaw(after: t0, differingFrom: base)
                    published = published ?? probe.firstPublished(after: t0, differingFrom: basePublished)
                    try await Task.sleep(for: .milliseconds(1))
                }
                if let raw { rawLatencies.append(Self.millis(t0.duration(to: raw.instant))) } else { misses += 1 }
                if let published { publishedLatencies.append(Self.millis(t0.duration(to: published.instant))) }
                try await Task.sleep(for: .milliseconds(400))
            }

            // Frame counts while the screen moves.
            try await fast.button(.home)
            try await Task.sleep(for: .seconds(1))
            let before = probe.counts
            let cropsBefore = probe.cropTimes.count
            let windowEnd = clock.now + .seconds(10)
            var forward = true
            while clock.now < windowEnd {
                let from = CGPoint(x: forward ? 0.8 : 0.2, y: 0.5), to = CGPoint(x: forward ? 0.2 : 0.8, y: 0.5)
                try await fast.down(from)
                for step in 1...15 {
                    let t = Double(step) / 15
                    try await fast.move(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y))
                    try await Task.sleep(for: .milliseconds(20))
                }
                try await fast.up(to)
                forward.toggle()
                try await Task.sleep(for: .milliseconds(450))
            }
            let after = probe.counts
            windowCounts = (after.raw - before.raw, after.published - before.published)
            windowCrops = Array(probe.cropTimes.dropFirst(cropsBefore))
        } catch {
            failure = error
        }
        session.stop()
        try? await fast.button(.home)
        await fast.stop()
        if let failure { throw failure }
        print("touch to raw decoded frame (down to arrival):     \(Self.summary(rawLatencies)), \(misses) without a change")
        print("touch to published frame (down to store):         \(Self.summary(publishedLatencies))")
        print("10 s moving screen: \(windowCounts.raw) raw frames received, \(windowCounts.published) published")
        print("cropper time per frame:                           \(Self.summary(windowCrops))")
        XCTAssertGreaterThanOrEqual(rawLatencies.count, 10, "most taps showed up in the raw frames")
    }

    /// The stream never rotates (measured 2026-09-30, iPhone 12 / iOS 27.0): the raw frame is
    /// always the portrait panel (1184x2576, crop 1170x2532). The session turns it with the
    /// frame, i.e. the device pose (Device Hub 27.0, 2026-10-01): landscapeLeft and landscapeRight
    /// give a 2532x1170 stage, upside down a half turn of the portrait size, portrait gives it
    /// back; the interface orientation (a screenshot's aspect) only decides the home-indicator band.
    /// Rotates through `devicectl device orientation set` as the app's Rotate does (no runner); drives
    /// only the host app and the home screen.
    func testNativeMirrorFollowsLandscape() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let team = environment["DHP_IOS_TEAM_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines), !team.isEmpty,
              environment["DHP_IOS_AGENT_DIR"] != nil else {
            throw XCTSkip("set DHP_IOS_TEAM_ID and DHP_IOS_AGENT_DIR (the runner rotates the phone)")
        }
        let setup = try await nativeLiveSetup(environment)
        let client = setup.connected.client
        let known = setup.connected.device.productType == "iPhone13,2"
        _ = team
        let fast = try await FastInputSession.live(client: client, toolchain: setup.toolchain, environment: environment) { print("fast input: \($0)") }
        let session = try PhysicalNativeMirrorSession.live(hardwareUDID: setup.connected.device.hardwareUDID, environment: environment) {
            (client, setup.toolchain)
        }

        /// Waits until the tracker reports `expected` and a frame of the stage's shape arrived.
        func waitForInterface(_ expected: PhysicalControlOrientation) async throws -> (width: Int, height: Int)? {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(12)
            while clock.now < deadline {
                if session.stagePose == expected, let size = session.frames.currentSize,
                   FastInputPanelMapping.frame(CGSize(width: size.width, height: size.height), fits: expected) {
                    return size
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            return session.frames.currentSize
        }

        var failure: Error?
        do {
            try await fast.start()
            session.start()
            let clock = ContinuousClock()
            let startDeadline = clock.now + .seconds(40)
            while clock.now < startDeadline, session.lastError == nil, session.frames.current == nil {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertNil(session.lastError, "the stream failed")
            try await client.launchForLiveTest(bundleID: "com.devicehubpro.agent.host")
            try await Task.sleep(for: .seconds(1))
            let first = try await waitForInterface(.portrait)
            XCTAssertNotNil(first, "the tracker read the interface at the start")

            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("aqa-nm-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: scratch) }
            for pose in [PhysicalControlOrientation.landscapeLeft, .landscapeRight, .portraitUpsideDown, .portrait] {
                // As the app's Rotate does: `devicectl device orientation set`, then the stage takes the pose.
                _ = try await client.setOrientation(try XCTUnwrap(SimulatorDevicePose(rawValue: pose.rawValue)))
                await session.noteTurn(to: pose)
                // The stage follows the device pose (Device Hub 27.0), upside down included.
                let expected = pose
                let stage = try await waitForInterface(expected)
                let raw = session.lastRawFrame
                let reported = try? await client.orientation().value
                _ = try? await client.screenshot(to: scratch)
                let shot = NSImage(contentsOf: scratch)?.representations.first.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "none"
                print("native mirror \(pose.rawValue): raw \(raw.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "none") crop \(raw.map { "\($0.crop)" } ?? "none") devicectl \(reported.map { "\($0)" } ?? "none") screenshot \(shot) stage pose \(session.stagePose?.rawValue ?? "nil") interface landscape \(session.interfaceIsLandscape) stage \(stage.map { "\($0.width)x\($0.height)" } ?? "none")")
                XCTAssertEqual(session.stagePose, expected, "the tracker's stage pose after \(pose.rawValue)")
                if let raw {
                    XCTAssertLessThan(raw.size.width, raw.size.height, "the raw stream stays the portrait panel in \(pose.rawValue)")
                    let want = PhysicalStageRotation.stageSize(panel: raw.crop.size, pose: expected)
                    XCTAssertEqual(CGFloat(stage?.width ?? 0), want.width, "the stage is the panel turned for \(expected.rawValue)")
                    XCTAssertEqual(CGFloat(stage?.height ?? 0), want.height)
                }
                if known, expected == .landscapeLeft || expected == .landscapeRight {
                    XCTAssertEqual(stage?.width, 2532)
                    XCTAssertEqual(stage?.height, 1170)
                } else if known {
                    XCTAssertEqual(stage?.width, 1170)
                    XCTAssertEqual(stage?.height, 2532)
                }
            }
            // The home screen (an iPhone 12's never rotates): Device Hub 27.0 still turns the
            // frame with the device pose, and so must the stage; the interface stays portrait.
            try await fast.button(.home)
            try await Task.sleep(for: .seconds(1))
            _ = try await client.setOrientation(.landscapeLeft)
            await session.noteTurn(to: .landscapeLeft)
            let home = try await waitForInterface(.landscapeLeft)
            print("native mirror home screen landscapeLeft: stage \(home.map { "\($0.width)x\($0.height)" } ?? "none") interface landscape \(session.interfaceIsLandscape)")
            XCTAssertEqual(session.stagePose, .landscapeLeft)
            XCTAssertFalse(session.interfaceIsLandscape, "the home screen stayed portrait")
            if known { XCTAssertEqual(home?.width, 2532) }
        } catch {
            failure = error
        }
        _ = try? await client.setOrientation(.portrait)
        try? await Task.sleep(for: .milliseconds(1200))
        try? await fast.button(.home)
        session.stop()
        await fast.stop()
        if let failure { throw failure }
    }
}
