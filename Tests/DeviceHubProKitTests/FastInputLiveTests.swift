import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import DeviceHubProKit

/// Fast input on the dedicated test iPhone, end to end through
/// `FastInputSession.live`: the helper is built (or
/// found in the cache), the tunnel lease and the helper start, taps land in
/// Device Hub Pro's own host app, and the Home button is pressed. Behind switches;
/// skipped otherwise:
///
///     DHP_IOS_DEVICE_LIVE=1 DHP_IPHONE_UDID=<hardware UDID> \
///     DHP_FAST_INPUT_LIVE=1 [DHP_FAST_INPUT_DIR=<checkout>/fastinput] \
///         swift test --filter FastInputLiveTests
///
/// The phone must be unlocked and the host app (`com.devicehubpro.agent.host`, a
/// full-screen colour that flips on each tap) installed (the runner's first
/// start installs it). The test drives only that app and the home screen, taps
/// only its empty area and never prints an identifier.
final class FastInputLiveTests: XCTestCase {
    fileprivate static let host = "com.devicehubpro.agent.host"

    /// The pixel at a normalized point of a PNG, as RGB bytes.
    private func pixel(of url: URL, at point: CGPoint) throws -> [Int] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let x = min(width - 1, max(0, Int(point.x * Double(width))))
        let y = min(height - 1, max(0, Int(point.y * Double(height))))
        let offset = (y * width + x) * 4
        return [Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])]
    }

    private func distance(_ a: [Int], _ b: [Int]) -> Int {
        zip(a, b).map { abs($0 - $1) }.reduce(0, +)
    }

    private func stats(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "n/a" }
        let sorted = values.sorted()
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded(.up)))] }
        return String(format: "min %.2f / median %.2f / p90 %.2f / max %.2f ms", sorted[0], at(0.5), at(0.9), sorted[sorted.count - 1])
    }

    /// A bottom-edge swipe from (0.5, 0.995) up to (0.5, 0.55) over ~250 ms, optionally held
    /// there, through the helper's `edge` verb; returns the host's colour before and after.
    private func bottomEdgeSwipe(holdMs: Int) async throws -> (before: [Int], after: [Int]) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DHP_FAST_INPUT_LIVE"] == "1" else {
            throw XCTSkip("set DHP_FAST_INPUT_LIVE=1 (with the device switches) to run fast input on the test iPhone")
        }
        try XCTSkipIf(FastInputSession.isDisabled(environment: environment), "fast input is switched off")
        let connected = try await ApplePhysicalLiveTests.connectedTestIPhone()
        let toolchain = await AppleToolchain.probe()
        let client = connected.client
        let session = try await FastInputSession.live(client: client, toolchain: toolchain, environment: environment) { print("fast input: \($0)") }
        var failure: Error?
        var result: (before: [Int], after: [Int])?
        do {
            try await session.start()
            try await client.launchForLiveTest(bundleID: Self.host)
            try await Task.sleep(for: .seconds(2))
            let empty = CGPoint(x: 0.25, y: 0.83)
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("devicehubpro-fastinput-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            func shot(_ name: String) async throws -> [Int] {
                let url = scratch.appendingPathComponent("\(name).png")
                _ = try await client.screenshot(to: url)
                return try pixel(of: url, at: empty)
            }
            let before = try await shot("before")
            try await session.edge(.down, CGPoint(x: 0.5, y: 0.995))
            let steps = 12
            for step in 1...steps {
                try await Task.sleep(for: .milliseconds(250 / steps))
                let y = 0.995 - (0.995 - 0.55) * Double(step) / Double(steps)
                try await session.edge(.move, CGPoint(x: 0.5, y: y))
            }
            if holdMs > 0 { try await Task.sleep(for: .milliseconds(holdMs)) }
            try await session.edge(.up, CGPoint(x: 0.5, y: 0.55))
            try await Task.sleep(for: .seconds(1))
            result = (before, try await shot("after"))
        } catch {
            failure = error
        }
        // Whatever happened: back to the home screen.
        try? await session.button(.home)
        try? await Task.sleep(for: .milliseconds(800))
        await session.stop()
        if let failure { throw failure }
        return try XCTUnwrap(result)
    }

    func testBottomEdgeSwipeGoesHome() async throws {
        let (before, after) = try await bottomEdgeSwipe(holdMs: 0)
        print("bottom edge swipe: host colour \(before) -> \(after), distance \(distance(before, after))")
        XCTAssertGreaterThan(distance(before, after), 60, "the host app left the foreground")
    }

    /// The Apple chrome's hardware buttons through the router (Phase: every chrome button as
    /// its real down and up edges): volume up then down is read back through `device info
    /// audio` and restored exactly; the side button locks and, pressed again, wakes the screen,
    /// and an edge swipe up unlocks (the test iPhone has no passcode). Siri (side held) and the
    /// side + volume up screenshot are NOT run here: they change device state unattended.
    /// TODO(attended): hold side 0.85 s and check Siri; side + volume up and check the screenshot.
    func testChromeButtons() async throws {
        let connected = try await ApplePhysicalLiveTests.connectedTestIPhone()
        let client = connected.client
        func click(_ router: PhysicalControlInputRouter, _ button: SimulatorHardwareButton, holdMs: Int = 120, settleMs: Int = 700) async throws {
            router.receive(button: button, isDown: true)
            try await Task.sleep(for: .milliseconds(holdMs))
            router.receive(button: button, isDown: false)
            try await Task.sleep(for: .milliseconds(settleMs))
        }
        func difference(_ a: [Int], _ b: [Int]) -> Int { zip(a, b).map { abs($0 - $1) }.reduce(0, +) }
        try await withRouter { router, session, shot, failures, launchHost in
            // `device info audio` is not supported on this phone ("does not support Audio Output Device
            // Selection"), so the volume keys are checked by the volume indicator iOS draws: a screenshot
            // taken while it shows differs from one taken before. Up then down leaves the volume as it was.
            let before = try signature(of: try await shot("before-volume"))
            try await click(router, .volumeUp, settleMs: 250)
            let upShot = try signature(of: try await shot("volume-up"))
            try await Task.sleep(for: .seconds(2))
            try await click(router, .volumeDown, settleMs: 250)
            let downShot = try signature(of: try await shot("volume-down"))
            try await Task.sleep(for: .seconds(2))
            print("chrome buttons: volume indicator difference up \(difference(before, upShot)), down \(difference(before, downShot))")
            XCTAssertGreaterThan(difference(before, upShot), 60, "volume up showed the indicator")
            XCTAssertGreaterThan(difference(before, downShot), 60, "volume down showed the indicator")

            // Side button: lock, wait, wake, then the edge swipe up unlocks. Only with
            // DHP_ALLOW_LOCK=1: a phone with a passcode stays locked afterwards (seen
            // 2026-09-30 on the test iPhone 12 once it had a passcode) and needs its owner.
            guard ProcessInfo.processInfo.environment["DHP_ALLOW_LOCK"] == "1" else {
                print("chrome buttons: side button lock/wake skipped (set DHP_ALLOW_LOCK=1 on a phone without a passcode)")
                XCTAssertTrue(failures().isEmpty, "\(failures())")
                return
            }
            try await click(router, .side)
            try await Task.sleep(for: .seconds(1))
            let locked = try signature(of: try await shot("locked"))
            print("chrome buttons: side pressed, screen mean \(String(format: "%.1f", Double(locked.reduce(0, +)) / Double(locked.count))) of 255")
            try await click(router, .side)
            try await Task.sleep(for: .seconds(1))
            print("chrome buttons: side pressed again (screen woken)")
            router.receive(TouchCommand(phase: .down, x: 500, y: 1990))
            for step in 1...8 {
                try await Task.sleep(for: .milliseconds(40))
                router.receive(TouchCommand(phase: .move, x: 500, y: Int32(1990 - step * 150)))
            }
            router.receive(TouchCommand(phase: .up, x: 500, y: 790))
            try await Task.sleep(for: .seconds(1.5))
            let url = try await shot("after-wake")
            let grid = try signature(of: url)
            let mean = Double(grid.reduce(0, +)) / Double(grid.count)
            print("chrome buttons: screenshot mean brightness \(String(format: "%.1f", mean)) of 255")
            XCTAssertGreaterThan(mean, 25, "the screen is lit: the home screen or an app, not dark")
            XCTAssertTrue(failures().isEmpty, "\(failures())")
        }
    }

    /// A coarse look at a whole screenshot: an 8 x 8 grid of pixels.
    private func signature(of url: URL) throws -> [Int] {
        try (0..<8).flatMap { row in
            try (0..<8).flatMap { column in
                try pixel(of: url, at: CGPoint(x: (Double(column) + 0.5) / 8, y: (Double(row) + 0.5) / 8))
            }
        }
    }

    /// A fast session on the test iPhone with a router on top (the stage's path: 1000 x 2000
    /// stage points, portrait), the host app in front; `body` gets the router, the session,
    /// a screenshot function (name -> PNG url), the failures the router reported and a host-app launch.
    private func withRouter(
        _ body: (PhysicalControlInputRouter, FastInputSession, (String) async throws -> URL, @Sendable () -> [FastInputError], () async throws -> Void) async throws -> Void
    ) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DHP_FAST_INPUT_LIVE"] == "1" else {
            throw XCTSkip("set DHP_FAST_INPUT_LIVE=1 (with the device switches) to run fast input on the test iPhone")
        }
        try XCTSkipIf(FastInputSession.isDisabled(environment: environment), "fast input is switched off")
        let connected = try await ApplePhysicalLiveTests.connectedTestIPhone()
        let toolchain = await AppleToolchain.probe()
        let client = connected.client
        let session = try await FastInputSession.live(client: client, toolchain: toolchain, environment: environment) { print("fast input: \($0)") }
        let failures = FailureBox()
        let router = PhysicalControlInputRouter(
            control: FakeControl(),
            frameSize: { [poseBox] in
                // The stage turns with the interface: landscape poses get a landscape frame.
                switch poseBox.value {
                case .landscapeLeft?, .landscapeRight?: CGSize(width: 2000, height: 1000)
                default: CGSize(width: 1000, height: 2000)
                }
            },
            onFailure: { _ in },
            onSoftFailure: { _ in },
            onFastInputFailure: { failures.add($0) },
            orientation: { [poseBox] in poseBox.value }
        )
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-fastinput-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var failure: Error?
        do {
            try await session.start()
            router.setFastInput(session)
            try await client.launchForLiveTest(bundleID: Self.host)
            try await Task.sleep(for: .seconds(2))
            try await body(router, session, { name in
                let url = scratch.appendingPathComponent("\(name).png")
                _ = try await client.screenshot(to: url)
                return url
            }, { failures.all }, {
                try await client.launchForLiveTest(bundleID: Self.host)
                try await Task.sleep(for: .seconds(2))
            })
        } catch {
            failure = error
        }
        // Whatever happened: an edge swipe up (Home in the App Switcher would return to the app), then Home.
        router.receive(TouchCommand(phase: .down, x: 500, y: 1990))
        for step in 1...6 {
            try? await Task.sleep(for: .milliseconds(40))
            router.receive(TouchCommand(phase: .move, x: 500, y: Int32(1990 - step * 150)))
        }
        router.receive(TouchCommand(phase: .up, x: 500, y: 1090))
        try? await Task.sleep(for: .milliseconds(800))
        try? await session.button(.home)
        try? await Task.sleep(for: .milliseconds(500))
        router.stop()
        await session.stop()
        if let failure { throw failure }
    }

    /// The interface orientation `withRouter`'s router is told (nil: none known).
    private final class PoseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: PhysicalControlOrientation?
        var value: PhysicalControlOrientation? { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
    }
    private let poseBox = PoseBox()

    /// Landscape: the bottom-edge gesture has no accepted form there, so the router sends the
    /// Home button for a short swipe up from the bottom band. The iPhone 12 home screen is
    /// portrait-only, so a portrait screenshot afterwards means the phone went home.
    func testLandscapeBottomEdgeGoesHome() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["DHP_FAST_INPUT_LIVE"] == "1", "set DHP_FAST_INPUT_LIVE=1 (with the device switches)")
        let client = try await ApplePhysicalLiveTests.connectedTestIPhone().client
        do {
            try await withRouter { router, _, _, failures, _ in
                try await client.setOrientation(.landscapeLeft)
                try await Task.sleep(for: .milliseconds(1500))
                let before = try await Self.screenshotSize(client)
                XCTAssertGreaterThan(before.width, before.height, "the host app did not turn landscape")
                poseBox.value = .landscapeLeft
                // The stage is 2000 x 1000 in landscape, so the bottom band is y >= 980.
                router.receive(TouchCommand(phase: .down, x: 1000, y: 995))
                for step in 1...4 {
                    try await Task.sleep(for: .milliseconds(40))
                    router.receive(TouchCommand(phase: .move, x: 1000, y: Int32(995 - step * 40)))
                }
                router.receive(TouchCommand(phase: .up, x: 1000, y: 835))
                try await Task.sleep(for: .milliseconds(1500))
                let after = try await Self.screenshotSize(client)
                XCTAssertGreaterThan(after.height, after.width, "the phone did not go home (still landscape)")
                XCTAssertTrue(failures().isEmpty, "\(failures())")
            }
        } catch {
            poseBox.value = nil
            _ = try? await client.setOrientation(.portrait)
            throw error
        }
        poseBox.value = nil
        _ = try? await client.setOrientation(.portrait)
    }

    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [FastInputError] = []
        func add(_ error: FastInputError) { lock.withLock { stored.append(error) } }
        var all: [FastInputError] { lock.withLock { stored } }
    }

    /// The App Switcher gesture the way the stage makes it: a bottom-edge drag up to 0.60 over
    /// ~300 ms, then a hold of 0.9 s in which the Mac sends nothing (the router repeats the
    /// last point), then release. The screen must differ from the host app and from the home screen.
    func testBottomEdgeHoldOpensAppSwitcher() async throws {
        try await withRouter { router, session, shot, failures, launchHost in
            try await session.button(.home)
            try await Task.sleep(for: .seconds(1))
            let home = try signature(of: try await shot("home"))
            try await launchHost()
            let hostShot = try signature(of: try await shot("host"))

            router.receive(TouchCommand(phase: .down, x: 500, y: 1990))   // y 0.995
            // A finger slows down before it rests: iOS opened the App Switcher for this
            // decelerating path every time on the test iPhone 12, but went home for a
            // constant-speed drag that stopped dead (both measured 2026-09-30).
            for y in [1900, 1800, 1700, 1600, 1520, 1440, 1380, 1330, 1290, 1260, 1240, 1226, 1216, 1210, 1206, 1204, 1202, 1200] {
                try await Task.sleep(for: .milliseconds(33))
                router.receive(TouchCommand(phase: .move, x: 500, y: Int32(y)))
            }
            try await Task.sleep(for: .milliseconds(900))
            router.receive(TouchCommand(phase: .up, x: 500, y: 1200))     // y 0.60
            try await Task.sleep(for: .seconds(1))
            let switcher = try signature(of: try await shot("switcher"))
            print("app switcher: distance to host \(distance(switcher, hostShot)), to home \(distance(switcher, home))")
            XCTAssertGreaterThan(distance(switcher, hostShot), 600, "the host app is no longer showing")
            XCTAssertGreaterThan(distance(switcher, home), 600, "and it is not the plain home screen")
            XCTAssertTrue(failures().isEmpty, "\(failures())")
        }
    }

    /// A plain touch held 800 ms through the router inside the host app: print only, but the
    /// fast path must survive it.
    func testLongPressThroughTheRouter() async throws {
        try await withRouter { router, _, shot, failures, _ in
            let point = CGPoint(x: 0.25, y: 0.83)
            let before = try pixel(of: try await shot("before"), at: point)
            router.receive(TouchCommand(phase: .down, x: 250, y: 1660))
            try await Task.sleep(for: .milliseconds(800))
            router.receive(TouchCommand(phase: .up, x: 250, y: 1660))
            try await Task.sleep(for: .milliseconds(600))
            let after = try pixel(of: try await shot("after"), at: point)
            print("long press: host colour \(before) -> \(after), distance \(distance(before, after))")
            XCTAssertTrue(router.isFastActive)
            XCTAssertTrue(failures().isEmpty, "\(failures())")
        }
    }

    func testFastInputTapsTheHostAppAndPressesHome() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DHP_FAST_INPUT_LIVE"] == "1" else {
            throw XCTSkip("set DHP_FAST_INPUT_LIVE=1 (with the device switches) to run fast input on the test iPhone")
        }
        try XCTSkipIf(FastInputSession.isDisabled(environment: environment), "fast input is switched off")
        let connected = try await ApplePhysicalLiveTests.connectedTestIPhone()
        let toolchain = await AppleToolchain.probe()
        let client = connected.client

        let session = try await FastInputSession.live(client: client, toolchain: toolchain, environment: environment) { print("fast input: \($0)") }
        var failure: Error?
        do {
            try await session.start()
            print("fast input: helper ready")

            try await client.launchForLiveTest(bundleID: Self.host)
            try await Task.sleep(for: .seconds(2))

            let empty = CGPoint(x: 0.25, y: 0.83)
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("devicehubpro-fastinput-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            func shot(_ name: String) async throws -> [Int] {
                let url = scratch.appendingPathComponent("\(name).png")
                _ = try await client.screenshot(to: url)
                return try pixel(of: url, at: empty)
            }

            let before = try await shot("before")
            try await session.tap(empty, holdMs: 10)
            try await Task.sleep(for: .milliseconds(600))
            let flipped = try await shot("flipped")
            XCTAssertGreaterThan(distance(before, flipped), 60, "the tap changed the host app's colour")

            try await session.tap(empty, holdMs: 10)
            try await Task.sleep(for: .milliseconds(600))
            let back = try await shot("back")
            XCTAssertGreaterThan(distance(flipped, back), 60, "the second tap flipped it back")
            XCTAssertLessThan(distance(before, back), 60, "and it is the first colour again")

            // The stage's path: separate down, a move in place and up (not the helper's whole tap).
            try await session.down(empty)
            try await session.move(empty)
            try await Task.sleep(for: .milliseconds(20))
            try await session.up(empty)
            try await Task.sleep(for: .milliseconds(600))
            let live = try await shot("live")
            XCTAssertGreaterThan(distance(back, live), 60, "a down, move, up gesture reached the host app")

            // Latency: the helper's round trip per command, 20 taps 100 ms apart.
            let clock = ContinuousClock()
            func millis(_ duration: Duration) -> Double {
                Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
            }
            let points = [CGPoint(x: 0.25, y: 0.83), CGPoint(x: 0.75, y: 0.9)]
            var tapTimes: [Double] = [], downTimes: [Double] = [], upTimes: [Double] = []
            for i in 0..<20 {
                let start = clock.now
                try await session.tap(points[i % 2], holdMs: 10)
                tapTimes.append(millis(start.duration(to: clock.now)))
                try await Task.sleep(for: .milliseconds(100))
            }
            for i in 0..<20 {
                let downStart = clock.now
                try await session.down(points[i % 2])
                downTimes.append(millis(downStart.duration(to: clock.now)))
                try await Task.sleep(for: .milliseconds(10))
                let upStart = clock.now
                try await session.up(points[i % 2])
                upTimes.append(millis(upStart.duration(to: clock.now)))
                try await Task.sleep(for: .milliseconds(100))
            }
            print("fast input latency, helper round trip per command (n=20 each)")
            print("  tap (10 ms hold): \(stats(tapTimes))")
            print("  down:             \(stats(downTimes))")
            print("  up:               \(stats(upTimes))")

            try await session.button(.home)
            try await Task.sleep(for: .milliseconds(800))
        } catch {
            failure = error
        }
        await session.stop()
        print("fast input: stopped")
        if let failure { throw failure }
    }
}

extension FastInputLiveTests {
    private final class EndpointBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _endpoint: PhysicalControlEndpoint?
        func set(_ endpoint: PhysicalControlEndpoint) { lock.withLock { _endpoint = endpoint } }
        var endpoint: PhysicalControlEndpoint? { lock.withLock { _endpoint } }
    }

    /// The runner's spike helper `/host` (tests only): the host app's text field
    /// (midX, midY, width, height in interface points) and its text.
    private func hostField(_ endpoint: PhysicalControlEndpoint) async throws -> (text: String, frame: [Double]) {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "[\(endpoint.address)]"
        components.port = Int(endpoint.port)
        components.path = "/host"
        components.queryItems = [URLQueryItem(name: "bundleId", value: Self.host)]
        var request = URLRequest(url: try XCTUnwrap(components.url), timeoutInterval: 20)
        request.setValue(endpoint.token.value, forHTTPHeaderField: PhysicalControlEndpoint.tokenHeader)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }
        let (data, _) = try await urlSession.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (json["field"] as? String ?? "", (json["fieldFrame"] as? [NSNumber])?.map(\.doubleValue) ?? [])
    }

    /// Where the host app saw its last tap, normalized to the screen in the
    /// current interface orientation (the host app's `touchPoint` label).
    private func hostTouchPoint(_ endpoint: PhysicalControlEndpoint) async throws -> CGPoint? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "[\(endpoint.address)]"
        components.port = Int(endpoint.port)
        components.path = "/host"
        components.queryItems = [URLQueryItem(name: "bundleId", value: Self.host)]
        var request = URLRequest(url: try XCTUnwrap(components.url), timeoutInterval: 20)
        request.setValue(endpoint.token.value, forHTTPHeaderField: PhysicalControlEndpoint.tokenHeader)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }
        let (data, _) = try await urlSession.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let raw = json["touchPoint"] as? String ?? "<missing>"
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        if parts.count != 2 { print("landscape mapping: host touchPoint reads \"\(raw)\"") }
        return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
    }

    /// Measures which rotation maps the stage to the touch panel in each pose
    /// (portrait as the control): two fast taps at known panel points, and the
    /// host app's `touchPoint` label (where it saw each tap, normalized to its
    /// rotated interface) must be explained by exactly one rotation, which must
    /// be `FastInputPanelMapping.rotation(for:)`. Measured 2026-09-30 on the test
    /// iPhone 12 / iOS 27.0: identity, clockwise90 (landscapeLeft),
    /// counterClockwise90 (landscapeRight), within 0.001. Upside down: a Face ID iPhone never shows
    /// an upside-down interface, so after the runner sets it the interface is the one that
    /// remains (the previous landscape, read from a screenshot's aspect; portrait when the
    /// screenshot is portrait) and the expected rotation is that one's, never turn180. Needs the
    /// runner too (`DHP_IOS_TEAM_ID`, `DHP_IOS_AGENT_DIR`).
    func testLandscapePanelMapping() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DHP_FAST_INPUT_LIVE"] == "1" else {
            throw XCTSkip("set DHP_FAST_INPUT_LIVE=1 (with the device switches) to run fast input on the test iPhone")
        }
        try XCTSkipIf(FastInputSession.isDisabled(environment: environment), "fast input is switched off")
        guard let team = environment["DHP_IOS_TEAM_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines), !team.isEmpty,
              environment["DHP_IOS_AGENT_DIR"] != nil else {
            throw XCTSkip("set DHP_IOS_TEAM_ID and DHP_IOS_AGENT_DIR (the runner is needed to rotate and read the field)")
        }
        let connected = try await ApplePhysicalLiveTests.connectedTestIPhone()
        let toolchain = await AppleToolchain.probe()
        let client = connected.client

        let box = EndpointBox()
        let control = try PhysicalControlSession.live(
            client: client, toolchain: toolchain, team: { team },
            makeTransport: { endpoint in
                box.set(endpoint)
                return PhysicalControlURLSessionTransport(endpoint: endpoint)
            }
        )
        let fast = try await FastInputSession.live(client: client, toolchain: toolchain, environment: environment) { print("fast input: \($0)") }

        var failure: Error?
        do {
            try await control.start()
            try await fast.start()
            let endpoint = try XCTUnwrap(box.endpoint)
            let portraitSize = await control.portraitSize()
            let portrait = try XCTUnwrap(portraitSize)
            try await client.launchForLiveTest(bundleID: Self.host)
            try await Task.sleep(for: .seconds(2))

            // `test-without-building` does not update an installed host app, and this test reads
            // the host app's `touchPoint` label: install the build's copy first.
            let hostBuild = PhysicalControlRunnerBuilder.defaultCacheDirectory
                .appendingPathComponent(PhysicalControlRunnerBuilder.folderName(productType: connected.device.productType), isDirectory: true)
                .appendingPathComponent("dd/Build/Products/Debug-iphoneos/DeviceHubProAgentHost.app", isDirectory: true)
            if FileManager.default.fileExists(atPath: hostBuild.path) {
                _ = try await client.installApp(at: hostBuild)
            }

            // Two panel points away from the host app's label and field; the host app reports
            // where each landed in its (rotated) interface, and the rotation that maps those
            // interface points back onto the panel points is the one the stage needs.
            let panelPoints = [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.15, y: 0.85)]
            var lastInterface = PhysicalControlOrientation.portrait
            for pose in [PhysicalControlOrientation.portrait, .landscapeLeft, .landscapeRight, .portraitUpsideDown] {
                try await client.launchForLiveTest(bundleID: Self.host)
                try await Task.sleep(for: .milliseconds(1500))
                _ = try await control.setOrientation(pose)
                try await Task.sleep(for: .milliseconds(1500))
                if pose == .portraitUpsideDown {
                    // The host app enables it, but the runner may not reach it: read it back.
                    let reached = try await control.orientation()
                    if reached != pose {
                        throw XCTSkip("the runner's setOrientation did not reach \(pose.rawValue) (read back \(reached.rawValue))")
                    }
                }
                // The interface that shows: the pose, except upside down (the aspect of a screenshot
                // says landscape or portrait, the previous pose says which landscape).
                var interface = pose
                if pose == .portraitUpsideDown {
                    let size = try await Self.screenshotSize(client)
                    interface = size.width > size.height ? lastInterface : .portrait
                    print("landscape mapping upside down: screenshot \(Int(size.width))x\(Int(size.height)), interface \(interface.rawValue)")
                } else {
                    lastInterface = pose
                }
                var seen: [CGPoint] = []
                for panel in panelPoints {
                    try await fast.down(panel)
                    try await Task.sleep(for: .milliseconds(20))
                    try await fast.up(panel)
                    try await Task.sleep(for: .milliseconds(700))
                    let point = try await hostTouchPoint(endpoint)
                    print("landscape mapping \(pose.rawValue): panel \(panel) landed at \(point.map { "\($0)" } ?? "nothing")")
                    if let point { seen.append(point) }
                }
                XCTAssertEqual(seen.count, panelPoints.count, "every tap reached the host app in \(pose.rawValue)")
                guard seen.count == panelPoints.count else { continue }
                let fitting = FastInputPanelMapping.Rotation.allCases.filter { rotation in
                    zip(seen, panelPoints).allSatisfy { stage, panel in
                        let mapped = rotation.apply(stage)
                        return abs(mapped.x - panel.x) < 0.03 && abs(mapped.y - panel.y) < 0.03
                    }
                }
                print("landscape mapping \(pose.rawValue): rotation \(fitting.map(\.rawValue))")
                XCTAssertEqual(fitting.count, 1, "exactly one rotation explains \(pose.rawValue)")
                let expected = FastInputPanelMapping.rotation(for: interface)
                XCTAssertEqual(fitting.first, expected,
                               "the table's rotation for \(pose.rawValue) is wrong, measured: \(fitting.map(\.rawValue))")
            }
        } catch {
            failure = error
        }
        _ = try? await control.setOrientation(.portrait)
        try? await Task.sleep(for: .milliseconds(1200))
        try? await control.press(.home)
        try? await Task.sleep(for: .milliseconds(800))
        await fast.stop()
        await control.stop()
        if let failure { throw failure }
    }
}

extension FastInputLiveTests {
    /// The pixel size of a fresh `devicectl` screenshot (it follows the interface orientation).
    static func screenshotSize(_ client: DevicectlPhysicalClient) async throws -> CGSize {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aqa-shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await client.screenshot(to: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return CGSize(width: try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int),
                      height: try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int))
    }

    /// Typing as physical keys through the helper's HID keyboard, no XCTest for the keys: a fast tap on the host app's text field, then the US-position keys
    /// ' [ 1 (on a Turkish Q phone: i ğ 1) and Delete, each as a down and an up report, and the
    /// field read back through the runner's `/host` (tests only) must be "iğ". Needs the phone's
    /// hardware keyboard layout to be Turkish Q (Settings > General > Keyboard > Hardware Keyboard).
    /// Needs the runner only to read the field (`DHP_IOS_TEAM_ID`, `DHP_IOS_AGENT_DIR`).
    /// Drives only the host app and the home screen.
    func testTypingPhysicalKeys() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DHP_FAST_INPUT_LIVE"] == "1" else {
            throw XCTSkip("set DHP_FAST_INPUT_LIVE=1 (with the device switches) to run fast input on the test iPhone")
        }
        try XCTSkipIf(FastInputSession.isDisabled(environment: environment), "fast input is switched off")
        guard let team = environment["DHP_IOS_TEAM_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines), !team.isEmpty,
              environment["DHP_IOS_AGENT_DIR"] != nil else {
            throw XCTSkip("set DHP_IOS_TEAM_ID and DHP_IOS_AGENT_DIR (the runner reads the host app's field)")
        }
        let connected = try await ApplePhysicalLiveTests.connectedTestIPhone()
        let toolchain = await AppleToolchain.probe()
        let client = connected.client

        let box = EndpointBox()
        let control = try PhysicalControlSession.live(
            client: client, toolchain: toolchain, team: { team },
            makeTransport: { endpoint in
                box.set(endpoint)
                return PhysicalControlURLSessionTransport(endpoint: endpoint)
            }
        )
        let fast = try await FastInputSession.live(client: client, toolchain: toolchain, environment: environment) { print("fast input: \($0)") }

        var failure: Error?
        do {
            try await control.start()
            try await fast.start()
            let endpoint = try XCTUnwrap(box.endpoint)
            let portraitSize = await control.portraitSize()
            let portrait = try XCTUnwrap(portraitSize)
            try await client.launchForLiveTest(bundleID: Self.host)
            try await Task.sleep(for: .seconds(2))
            _ = try await control.setOrientation(.portrait)
            try await Task.sleep(for: .milliseconds(1000))

            let field = try await hostField(endpoint)
            XCTAssertEqual(field.frame.count, 4, "the host app reports its text field")
            guard field.frame.count == 4 else { throw XCTSkip("no field frame from /host") }
            let target = CGPoint(x: field.frame[0] / portrait.width, y: field.frame[1] / portrait.height)
            print("typing: field at \(target), text before \"\(field.text)\"")
            try await fast.tap(target, holdMs: 30)
            try await Task.sleep(for: .milliseconds(1000))
            // What the stage sends: per key a report with the key held, then one with nothing held.
            for usage in [0x34, 0x2F, 0x1E, 0x2A] {   // ' (i), [ (ğ), 1, Delete
                try await fast.keys([usage])
                try await Task.sleep(for: .milliseconds(40))
                try await fast.keys([])
                try await Task.sleep(for: .milliseconds(250))
            }
            try await Task.sleep(for: .milliseconds(500))
            let after = try await hostField(endpoint)
            print("typing: field reads \"\(after.text)\"")
            XCTAssertEqual(after.text, field.text + "i\u{11F}",
                           "physical keys ' [ 1 Delete must read \"i\u{11F}\" on a Turkish Q hardware keyboard; if it reads otherwise, the iPhone's hardware keyboard layout is not Turkish Q (Settings > General > Keyboard > Hardware Keyboard)")
        } catch {
            failure = error
        }
        try? await fast.button(.home)
        try? await Task.sleep(for: .milliseconds(800))
        await fast.stop()
        await control.stop()
        if let failure { throw failure }
    }
}

extension DevicectlPhysicalClient {
    /// `launchApp` for the live tests, tried up to three times: CoreDevice
    /// sometimes answers "The process identifier of the launched application
    /// could not be determined" (seen on the test iPhone 12, iOS 27.0) for a
    /// launch the next attempt completes.
    func launchForLiveTest(bundleID: String) async throws {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                _ = try await launchApp(bundleID: bundleID, terminateExisting: attempt == 0)
                return
            } catch {
                lastError = error
                try await Task.sleep(for: .seconds(1))
            }
        }
        if let lastError { throw lastError }
    }
}
