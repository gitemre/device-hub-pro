import Foundation
import XCTest
@testable import DeviceHubProKit

/// Control of the dedicated test iPhone through the public-XCTest runner,
/// end to end through `PhysicalControlSession.live`:
/// the signed runner is built (or found in the cache), started on the phone
/// over the CoreDevice tunnel, and driven. Behind switches; skipped otherwise:
///
///     DHP_IOS_DEVICE_LIVE=1 DHP_IPHONE_UDID=<hardware UDID> \
///     DHP_IOS_TEAM_ID=<development team> \
///     DHP_IOS_AGENT_DIR=<checkout>/ios/agent \
///     [DHP_CONTROL_LOG=<file>] \
///         swift test --filter PhysicalControlLiveTests
///
/// The phone must be unlocked. The test drives only Device Hub Pro's own host app
/// (`com.devicehubpro.agent.host`, a coloured page with a tap counter and a text
/// field) and the home screen: it never taps inside another app's content. It
/// reads the host app's state through the runner's spike helper `/host` (the
/// only place a helper endpoint is used; the app itself never asks for one),
/// checks that the runner refuses a missing or wrong token and answers on no
/// other address of the phone, and puts the phone back: portrait, home
/// screen, runner stopped. The UDID, the team, the address and the token are
/// never printed; every phone command is appended to `DHP_CONTROL_LOG`
/// with `<test iPhone>` for the UDID.
final class PhysicalControlLiveTests: XCTestCase {
    private static let host = "com.devicehubpro.agent.host"

    private final class EndpointBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _endpoint: PhysicalControlEndpoint?
        func set(_ endpoint: PhysicalControlEndpoint) { lock.withLock { _endpoint = endpoint } }
        var endpoint: PhysicalControlEndpoint? { lock.withLock { _endpoint } }
    }

    private var logURL: URL?

    private func log(_ line: String) {
        guard let logURL else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    /// A raw request with the token the test chooses (or none): only for the
    /// security checks and the host app's state.
    private func raw(
        _ endpoint: PhysicalControlEndpoint,
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        token: String?,
        body: [String: Any]? = nil,
        host: String? = nil,
        timeout: TimeInterval = 20
    ) async throws -> (status: Int, json: [String: Any]) {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host ?? "[\(endpoint.address)]"
        components.port = Int(endpoint.port)
        components.path = path
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: try XCTUnwrap(components.url), timeoutInterval: timeout)
        request.httpMethod = method
        if let token { request.setValue(token, forHTTPHeaderField: PhysicalControlEndpoint.tokenHeader) }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (http.statusCode, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
    }

    private func hostState(_ endpoint: PhysicalControlEndpoint) async throws -> (taps: String, field: String, fieldFrame: [Double]) {
        let answer = try await raw(endpoint, "GET", "/host", query: ["bundleId": Self.host], token: endpoint.token.value)
        XCTAssertEqual(answer.status, 200)
        return (
            answer.json["tapCount"] as? String ?? "",
            answer.json["field"] as? String ?? "",
            (answer.json["fieldFrame"] as? [NSNumber])?.map(\.doubleValue) ?? []
        )
    }

    func testControlOfTheTestIPhoneEndToEnd() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let team = environment["DHP_IOS_TEAM_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines), !team.isEmpty else {
            throw XCTSkip("set DHP_IOS_TEAM_ID to the development team the runner is signed with")
        }
        if let path = environment["DHP_CONTROL_LOG"], !path.isEmpty { logURL = URL(fileURLWithPath: path) }
        let connected = try await ApplePhysicalLiveTests.connectedTestIPhone()
        let toolchain = await AppleToolchain.probe()
        let client = connected.client
        log("control: live check starts on <test iPhone> (devicectl reads: list devices, device info details, device info apps)")

        let box = EndpointBox()
        let session = try PhysicalControlSession.live(
            client: client,
            toolchain: toolchain,
            team: { team },
            makeTransport: { endpoint in
                box.set(endpoint)
                return PhysicalControlURLSessionTransport(endpoint: endpoint)
            }
        )

        var failure: Error?
        do {
            log("control: xcodebuild build-for-testing (cached when unchanged) then test-without-building on <test iPhone>")
            try await session.start()
            let endpoint = try XCTUnwrap(box.endpoint)
            let size = await session.portraitSize()
            XCTAssertEqual(size?.width, 390, "an iPhone 12's portrait width in points")
            XCTAssertEqual(size?.height, 844)

            // --- Security: the token is required, on the tunnel address only.
            log("control: security checks against the runner (no token, wrong token, the phone's other addresses)")
            let noToken = try await raw(endpoint, "GET", "/status", token: nil)
            XCTAssertEqual(noToken.status, 401, "no token")
            let wrongToken = try await raw(endpoint, "GET", "/status", token: String(repeating: "0", count: 64))
            XCTAssertEqual(wrongToken.status, 401, "a wrong token")
            let unauthorizedStop = try await raw(endpoint, "POST", "/stop", token: String(repeating: "0", count: 64), body: [:])
            XCTAssertEqual(unauthorizedStop.status, 401, "an unauthorized stop does nothing")
            let stillThere = try await raw(endpoint, "GET", "/status", token: endpoint.token.value)
            XCTAssertEqual(stillThere.status, 200, "the runner is still running after an unauthorized stop")

            let addresses = try await raw(endpoint, "GET", "/ifaddrs", token: endpoint.token.value)
            let others = (addresses.json["addresses"] as? [[String: String]] ?? []).compactMap { $0["addr"] }
                .filter { !$0.contains("%") && !$0.hasPrefix("fe80") && !$0.hasPrefix("fd") && $0 != "127.0.0.1" && $0 != "::1" }
            var probed = 0
            for other in others {
                let host = other.contains(":") ? "[\(other)]" : other
                do {
                    _ = try await raw(endpoint, "GET", "/status", token: endpoint.token.value, host: host, timeout: 3)
                    XCTFail("the runner answered on another address of the phone")
                } catch {
                    probed += 1 // refused or unreachable: the runner listens only on the tunnel address
                }
            }
            print("control live: probed \(probed) other address(es) of the phone, none answered")

            // --- The host app in front (a public devicectl launch).
            log("control: devicectl device process launch com.devicehubpro.agent.host on <test iPhone>")
            try await client.launchForLiveTest(bundleID: Self.host)
            try await Task.sleep(for: .seconds(2))

            let front = try await session.foregroundApp()
            XCTAssertEqual(front, Self.host, "the host app is the foreground app (the apps list or the Apple list names it)")

            // --- Tap: an empty area of the page flips the counter.
            let before = try await hostState(endpoint)
            log("control: tap on the host app's page (portrait)")
            try await session.tap(CGPoint(x: 195, y: 700))
            try await Task.sleep(for: .milliseconds(600))
            let afterTap = try await hostState(endpoint)
            XCTAssertNotEqual(before.taps, afterTap.taps, "the tap reached the host app")

            // --- Type: focus the field, type, delete.
            let field = afterTap.fieldFrame
            XCTAssertEqual(field.count, 4)
            log("control: tap on the host app's text field, type, delete")
            try await session.tap(CGPoint(x: field[0], y: field[1]))
            try await Task.sleep(for: .milliseconds(1200))
            try await session.type("ab", bundleID: Self.host)
            try await Task.sleep(for: .milliseconds(500))
            var typed = try await hostState(endpoint)
            XCTAssertEqual(typed.field, "ab", "typed through the runner")
            try await session.type("\u{8}", bundleID: Self.host)
            try await Task.sleep(for: .milliseconds(500))
            typed = try await hostState(endpoint)
            print("control live: after Delete the field reads \(typed.field.count) character(s)")
            XCTAssertEqual(typed.field, "a", "Delete typed as a control character removes one character")

            // --- A swipe (one atomic gesture) on the page.
            log("control: swipe on the host app's page")
            let swipeBefore = try await hostState(endpoint)
            try await session.swipe(from: CGPoint(x: 195, y: 650), to: CGPoint(x: 195, y: 500), duration: 0.3)
            try await Task.sleep(for: .milliseconds(400))
            _ = swipeBefore

            // --- Orientation: landscape left, a tap in the landscape interface, the read-back.
            log("control: rotate to landscape left, tap, back to portrait")
            let landscape = try await session.setOrientation(.landscapeLeft)
            XCTAssertEqual(landscape, .landscapeLeft)
            try await Task.sleep(for: .milliseconds(1500))
            let read = try await session.orientation()
            XCTAssertEqual(read, .landscapeLeft, "the read-back names the side the capture cannot tell")
            let landscapeState = try await hostState(endpoint)
            let landscapeField = landscapeState.fieldFrame
            XCTAssertEqual(landscapeField.count, 4)
            // Dismiss the keyboard focus by tapping the empty page, then tap the
            // field at its landscape coordinates: it must take focus (typing works).
            try await session.tap(CGPoint(x: 60, y: 60))
            try await Task.sleep(for: .milliseconds(700))
            let counterBefore = try await hostState(endpoint)
            try await session.tap(CGPoint(x: landscapeField[0], y: landscapeField[1]))
            try await Task.sleep(for: .milliseconds(1200))
            try await session.type("z", bundleID: Self.host)
            try await Task.sleep(for: .milliseconds(500))
            let landscapeTyped = try await hostState(endpoint)
            XCTAssertTrue(landscapeTyped.field.hasSuffix("z"), "a tap at the landscape interface point focused the field")
            XCTAssertNotEqual(counterBefore.taps, "", "the counter is readable in landscape")

            let right = try await session.setOrientation(.landscapeRight)
            XCTAssertEqual(right, .landscapeRight)
            try await Task.sleep(for: .milliseconds(1500))
            let rightRead = try await session.orientation()
            XCTAssertEqual(rightRead, .landscapeRight)
            let rightState = try await hostState(endpoint)
            try await session.tap(CGPoint(x: 60, y: 60))
            try await Task.sleep(for: .milliseconds(700))
            try await session.tap(CGPoint(x: rightState.fieldFrame[0], y: rightState.fieldFrame[1]))
            try await Task.sleep(for: .milliseconds(1200))
            try await session.type("y", bundleID: Self.host)
            try await Task.sleep(for: .milliseconds(500))
            let rightTyped = try await hostState(endpoint)
            XCTAssertTrue(rightTyped.field.hasSuffix("y"), "landscape right takes the same interface coordinates")
        } catch {
            failure = error
        }

        // --- Put the phone back, whatever happened.
        log("control: restore: portrait, Home, stop the runner")
        _ = try? await session.setOrientation(.portrait)
        try? await Task.sleep(for: .milliseconds(1200))
        try? await session.press(.home)
        try? await Task.sleep(for: .milliseconds(800))
        await session.stop()
        log("control: live check ends (runner stopped)")
        if let failure { throw failure }
    }

    // MARK: Tap latency

    private struct LatencySamples {
        var roundTrip: [Double] = []
        var resolve: [Double] = []
        var action: [Double] = []
        var delivery: [Double] = []
    }

    private func stats(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "n/a" }
        let sorted = values.sorted()
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded(.up)))] }
        return String(format: "min %.0f / median %.0f / p90 %.0f / max %.0f ms", sorted[0], at(0.5), at(0.9), sorted[sorted.count - 1])
    }

    private func report(_ name: String, _ samples: LatencySamples) {
        print("tap latency [\(name)] n=\(samples.roundTrip.count)")
        print("  Mac round trip:  \(stats(samples.roundTrip))")
        print("  runner resolve:  \(stats(samples.resolve))")
        print("  runner action:   \(stats(samples.action))")
        print("  touch delivery:  \(stats(samples.delivery))")
    }

    /// Measures what a tap costs: the old two-request path, the session's
    /// one-request path and a full candidate scan (the home screen's case),
    /// each tapping only the host app's empty page. Extra switch:
    /// `DHP_CONTROL_LATENCY=1` (`DHP_CONTROL_LATENCY_N`, default 20).
    func testTapLatency() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DHP_CONTROL_LATENCY"] == "1" else {
            throw XCTSkip("set DHP_CONTROL_LATENCY=1 to measure the tap latency")
        }
        guard let team = environment["DHP_IOS_TEAM_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines), !team.isEmpty else {
            throw XCTSkip("set DHP_IOS_TEAM_ID to the development team the runner is signed with")
        }
        if let path = environment["DHP_CONTROL_LOG"], !path.isEmpty { logURL = URL(fileURLWithPath: path) }
        let runs = max(1, Int(environment["DHP_CONTROL_LATENCY_N"] ?? "") ?? 20)
        let connected = try await ApplePhysicalLiveTests.connectedTestIPhone()
        let toolchain = await AppleToolchain.probe()
        let client = connected.client
        log("latency: live check starts on <test iPhone>")

        let box = EndpointBox()
        let session = try PhysicalControlSession.live(
            client: client, toolchain: toolchain, team: { team },
            makeTransport: { endpoint in
                box.set(endpoint)
                return PhysicalControlURLSessionTransport(endpoint: endpoint)
            }
        )

        var failure: Error?
        do {
            try await session.start()
            let endpoint = try XCTUnwrap(box.endpoint)
            let token = endpoint.token.value
            log("latency: devicectl device process launch com.devicehubpro.agent.host on <test iPhone>")
            try await client.launchForLiveTest(bundleID: Self.host)
            try await Task.sleep(for: .seconds(2))

            let candidates = await session.candidateIDs()
            let clock = ContinuousClock()
            func millis(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
            func touchTime() async throws -> Double? {
                let answer = try await raw(endpoint, "GET", "/host", query: ["bundleId": Self.host], token: token)
                return Double(answer.json["touchTime"] as? String ?? "")
            }
            let points = [CGPoint(x: 100, y: 700), CGPoint(x: 290, y: 760)]
            func add(_ samples: inout LatencySamples, roundTrip: Double, resolve: Double?, action: Double?, t0: Double?) async throws {
                samples.roundTrip.append(roundTrip)
                if let resolve { samples.resolve.append(resolve) }
                if let action { samples.action.append(action) }
                try await Task.sleep(for: .milliseconds(250))
                if let t0, let touched = try await touchTime() { samples.delivery.append((touched - t0) * 1000) }
            }

            // Legacy: GET /foreground, then POST /tap with the reference.
            var legacy = LatencySamples()
            log("latency: legacy taps on the host app's page")
            for i in 0..<runs {
                let point = points[i % points.count]
                let start = clock.now
                let front = try await raw(endpoint, "GET", "/foreground", query: ["ids": candidates.joined(separator: ",")], token: token, timeout: 10)
                var body: [String: Any] = ["x": Double(point.x), "y": Double(point.y)]
                if let ref = (front.json["foreground"] as? [String])?.first { body["ref"] = ref }
                let answer = try await raw(endpoint, "POST", "/tap", token: token, body: body)
                let elapsed = millis(start.duration(to: clock.now))
                XCTAssertEqual(answer.status, 200)
                let runner = answer.json["timing"] as? [String: Any]
                try await add(&legacy, roundTrip: elapsed, resolve: (runner?["resolveMs"] as? NSNumber)?.doubleValue,
                              action: (runner?["actionMs"] as? NSNumber)?.doubleValue, t0: (answer.json["t0"] as? NSNumber)?.doubleValue)
            }

            // Session: one request with the candidate list.
            var current = LatencySamples()
            log("latency: session taps on the host app's page")
            for i in 0..<runs {
                let point = points[i % points.count]
                let start = clock.now
                try await session.tap(point)
                let elapsed = millis(start.duration(to: clock.now))
                let timing = await session.lastActionTiming()
                try await add(&current, roundTrip: elapsed, resolve: timing?.runnerResolveMs, action: timing?.runnerActionMs,
                              t0: timing?.runnerTapStart)
            }

            // Miss scan: the host app is not among the candidates, so the whole list is scanned and
            // Springboard is the reference (the home screen's case), while the tap still hits the host app.
            var miss = LatencySamples()
            log("latency: full-scan taps on the host app's page")
            let others = candidates.filter { $0 != Self.host }
            if environment["DHP_CONTROL_SCAN_PROBE"] == "1" {
                // Diagnostic: the state query's cost per candidate, one id per request.
                print("scan probe: \(others.count) candidates")
                for id in others {
                    let start = clock.now
                    do {
                        _ = try await raw(endpoint, "GET", "/foreground", query: ["ids": id], token: token, timeout: 8)
                        let ms = millis(start.duration(to: clock.now))
                        if ms > 50 { print("scan probe: slow \(id) \(Int(ms)) ms") }
                    } catch {
                        print("scan probe: timeout \(id)")
                    }
                }
                let front = try await raw(endpoint, "GET", "/foreground", query: ["ids": others.joined(separator: ",")], token: token, timeout: 20)
                print("scan probe: foreground among others: \(front.json["foreground"] ?? "none")")
                let all = try await client.apps(includeDefaultApps: false, includeAll: true).value.apps
                let hidden = all.filter { $0.hidden == true }.map(\.bundleIdentifier)
                print("scan probe: all-apps \(all.count), hidden \(hidden.count): \(hidden.joined(separator: " "))")
                for app in all where app.bundleIdentifier.contains("HUD") || app.bundleIdentifier == "com.apple.HangHUD" {
                    print("scan probe: \(app.bundleIdentifier) hidden=\(String(describing: app.hidden)) default=\(String(describing: app.defaultApp)) internal=\(String(describing: app.internalApp)) removable=\(String(describing: app.removable))")
                }
                print("scan probe: done")
            }
            for i in 0..<runs {
                let point = points[i % points.count]
                let start = clock.now
                let answer = try await raw(endpoint, "POST", "/tap", token: token,
                                           body: ["x": Double(point.x), "y": Double(point.y), "refs": others])
                let elapsed = millis(start.duration(to: clock.now))
                XCTAssertEqual(answer.status, 200)
                let runner = answer.json["timing"] as? [String: Any]
                try await add(&miss, roundTrip: elapsed, resolve: (runner?["resolveMs"] as? NSNumber)?.doubleValue,
                              action: (runner?["actionMs"] as? NSNumber)?.doubleValue, t0: (answer.json["t0"] as? NSNumber)?.doubleValue)
            }

            print("tap latency: \(candidates.count) candidates, \(runs) taps per variant")
            report("legacy: /foreground then /tap", legacy)
            report("session: one request", current)
            report("miss-scan: refs without the host app", miss)
        } catch {
            failure = error
        }

        log("latency: restore: portrait, Home, stop the runner")
        _ = try? await session.setOrientation(.portrait)
        try? await Task.sleep(for: .milliseconds(1200))
        try? await session.press(.home)
        try? await Task.sleep(for: .milliseconds(800))
        await session.stop()
        log("latency: live check ends (runner stopped)")
        if let failure { throw failure }
    }
}
