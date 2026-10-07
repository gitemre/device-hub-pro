import Foundation
import XCTest
@testable import DeviceHubProKit

/// The vocabulary of "Control this iPhone": the
/// token, the tunnel endpoint (the Mac side refuses any address but the
/// CoreDevice tunnel's), the request shapes and their token header, the
/// coordinate mapping, the runner's launch (argv, environment), the build
/// cache and the tunnel address `details` carries. No test starts a process,
/// opens a socket or touches a device.
final class PhysicalControlTests: XCTestCase {
    // MARK: Token

    func testATokenIsAtLeast128BitsAndFreshEachTime() throws {
        let first = try PhysicalControlToken.generate()
        let second = try PhysicalControlToken.generate()
        XCTAssertNotEqual(first, second)
        XCTAssertGreaterThanOrEqual(first.value.count, PhysicalControlToken.minimumLength)
        XCTAssertEqual(first.value.count, PhysicalControlToken.generatedByteCount * 2)
        XCTAssertNotNil(PhysicalControlToken(first.value), "a made token is a valid one")
    }

    func testAShortOrNonHexTokenIsNotAToken() {
        XCTAssertNil(PhysicalControlToken(""))
        XCTAssertNil(PhysicalControlToken("abc"))
        XCTAssertNil(PhysicalControlToken(String(repeating: "a", count: 31)), "127 bits")
        XCTAssertNil(PhysicalControlToken(String(repeating: "z", count: 40)))
        XCTAssertNotNil(PhysicalControlToken(String(repeating: "a", count: 32)), "128 bits")
    }

    func testATokenNeverPrints() throws {
        let token = try PhysicalControlToken.generate()
        XCTAssertFalse("\(token)".contains(token.value))
        XCTAssertFalse(String(reflecting: token).contains(token.value))
        XCTAssertFalse("\([token])".contains(token.value), "not in a collection's description either")
    }

    // MARK: Endpoint

    private func token() throws -> PhysicalControlToken { try PhysicalControlToken.generate() }

    func testOnlyTheDeviceEndOfTheCoreDeviceTunnelIsAnEndpoint() throws {
        let endpoint = try PhysicalControlEndpoint(tunnelAddress: "fd12:3456:789a::1", token: try token())
        XCTAssertEqual(endpoint.address, "fd12:3456:789a::1")
        XCTAssertEqual(endpoint.port, 8765)
        XCTAssertEqual(endpoint.baseURL.absoluteString, "http://[fd12:3456:789a::1]:8765")

        // Canonical form, whatever the spelling.
        XCTAssertEqual(PhysicalControlEndpoint.canonicalTunnelAddress("FD12:0000:0000:0000:0000:0000:0000:0001"), "fd12::1")
        // The scrubbed placeholder of the captured `details` is a tunnel address too.
        XCTAssertEqual(PhysicalControlEndpoint.canonicalTunnelAddress("fd00:0000:0000::0"), "fd00::")
    }

    func testEveryOtherAddressIsRefusedWithNoFallback() throws {
        let refused = [
            "192.168.1.20",                  // Wi-Fi or USB IPv4
            "169.254.10.1",                  // link-local IPv4
            "fe80::1",                       // link-local IPv6
            "fe80::1%en0",                   // link-local with a zone
            "::1", "127.0.0.1", "localhost", // loopback
            "2001:db8::1",                   // global IPv6
            "fc00::1",                       // unique-local, but not fd00::/8
            "ff02::1",                       // multicast
            "0.0.0.0", "::",                 // wildcard
            "[fd12::1]", "fd12::1/64", "fd12::1%utun4", "",
            "aqa-test-pho.coredevice.local", // a hostname
            "fd12::1 ; rm",                  // not an address at all
        ]
        for address in refused {
            XCTAssertNil(PhysicalControlEndpoint.canonicalTunnelAddress(address), address)
            XCTAssertThrowsError(try PhysicalControlEndpoint(tunnelAddress: address, token: try token()), address) { error in
                XCTAssertEqual(error as? PhysicalControlError, .notATunnelAddress)
            }
        }
    }

    func testAnEndpointNeverPrintsItsAddressOrToken() throws {
        let value = try token()
        let endpoint = try PhysicalControlEndpoint(tunnelAddress: "fd12:3456:789a::1", token: value)
        for text in ["\(endpoint)", String(reflecting: endpoint)] {
            XCTAssertFalse(text.contains("fd12"), text)
            XCTAssertFalse(text.contains(value.value), text)
        }
    }

    // MARK: Errors

    func testNoErrorNamesTheTeamTheUDIDTheAddressOrTheToken() {
        // The redactor takes them out of anything a message carries.
        let text = "signing ABCDE12345 for 00000000-0000000000000000 at fd12:3456:789a::1 with abcdef0123456789abcdef0123456789"
        let redacted = PhysicalControlRedactor.redact(
            text,
            secrets: ["ABCDE12345", "00000000-0000000000000000", "fd12:3456:789a::1", "abcdef0123456789abcdef0123456789"]
        )
        for secret in ["ABCDE12345", "00000000-0000000000000000", "fd12:3456:789a::1", "abcdef0123456789abcdef0123456789"] {
            XCTAssertFalse(redacted.contains(secret), redacted)
        }
        XCTAssertTrue(redacted.contains("‹redacted›"))
        // Cut to the last part.
        XCTAssertLessThanOrEqual(PhysicalControlRedactor.redact(String(repeating: "x", count: 5000), secrets: []).count, 401)
    }

    func testSoftFailuresLeaveControlOn() {
        XCTAssertTrue(PhysicalControlError.busy.isSoft)
        XCTAssertTrue(PhysicalControlError.noForegroundApp.isSoft)
        XCTAssertTrue(PhysicalControlError.keyboardNotShowing.isSoft)
        XCTAssertTrue(PhysicalControlError.runnerRestarted.isSoft)
        XCTAssertFalse(PhysicalControlError.transportFailed("x").isSoft)
        XCTAssertFalse(PhysicalControlError.actionFailed(status: 500, message: "").isSoft)
        XCTAssertFalse(PhysicalControlError.noTeam.isSoft)
        XCTAssertEqual(PhysicalControlError.noForegroundApp.description, "Tap a text field first")
    }

    // MARK: Coordinates

    private let portrait = CGSize(width: 390, height: 844)

    func testAPortraitFrameMapsToThePortraitPointSpace() throws {
        let frame = CGSize(width: 1170, height: 2532) // the phone's own pixels, 3x
        let centre = try XCTUnwrap(PhysicalControlGeometry.point(forFramePoint: CGPoint(x: 585, y: 1266), frame: frame, portrait: portrait))
        XCTAssertEqual(centre.x, 195, accuracy: 0.01)
        XCTAssertEqual(centre.y, 422, accuracy: 0.01)
        // A smaller picture (the stage may scale) maps the same.
        let small = try XCTUnwrap(PhysicalControlGeometry.point(forFramePoint: CGPoint(x: 100, y: 100), frame: CGSize(width: 200, height: 433), portrait: portrait))
        XCTAssertEqual(small.x, 195, accuracy: 0.01)
        XCTAssertEqual(small.y, 844 * 100 / 433, accuracy: 0.01)
        let origin = try XCTUnwrap(PhysicalControlGeometry.point(forFramePoint: .zero, frame: frame, portrait: portrait))
        XCTAssertEqual(origin, .zero)
    }

    /// A phone on its side gives a landscape frame; the interface is the
    /// portrait size swapped, and the origin stays the picture's top left.
    /// Landscape left and right differ only in which way the phone turned,
    /// not in the picture's coordinates.
    func testALandscapeFrameMapsToTheSwappedInterface() throws {
        let frame = CGSize(width: 2532, height: 1170)
        XCTAssertEqual(PhysicalControlGeometry.interfaceSize(portrait: portrait, frame: frame), CGSize(width: 844, height: 390))
        let centre = try XCTUnwrap(PhysicalControlGeometry.point(forFramePoint: CGPoint(x: 1266, y: 585), frame: frame, portrait: portrait))
        XCTAssertEqual(centre.x, 422, accuracy: 0.01)
        XCTAssertEqual(centre.y, 195, accuracy: 0.01)
        let corner = try XCTUnwrap(PhysicalControlGeometry.point(forFramePoint: CGPoint(x: 2532, y: 1170), frame: frame, portrait: portrait))
        XCTAssertEqual(corner, CGPoint(x: 843, y: 389), "kept on the screen")
        // Both landscapes: the same picture point, the same interface point.
        let a = PhysicalControlGeometry.point(forFramePoint: CGPoint(x: 600, y: 300), frame: frame, portrait: portrait)
        let b = PhysicalControlGeometry.point(forFramePoint: CGPoint(x: 600, y: 300), frame: CGSize(width: 2532, height: 1170), portrait: portrait)
        XCTAssertEqual(a, b)
    }

    func testAnEmptyFrameOrScreenMapsNothing() {
        XCTAssertNil(PhysicalControlGeometry.point(forFramePoint: .zero, frame: .zero, portrait: portrait))
        XCTAssertNil(PhysicalControlGeometry.point(forFramePoint: .zero, frame: CGSize(width: 10, height: 10), portrait: .zero))
    }

    func testTheScreenIsReadFromSpringboardsFrameInPortraitOrder() throws {
        let screen = try XCTUnwrap(PhysicalControlScreen(json: ["springboardFrameWidth": 844, "springboardFrameHeight": 390, "scale": 3]))
        XCTAssertEqual(screen.portraitSize, CGSize(width: 390, height: 844), "whichever way the phone is held")
        XCTAssertEqual(screen.scale, 3)
        XCTAssertNil(PhysicalControlScreen(json: [:]))
        XCTAssertNil(PhysicalControlScreen(json: ["springboardFrameWidth": 0, "springboardFrameHeight": 0]))
        // The runner's own UIScreen bounds (a 320x480 compatibility space) are not used.
        XCTAssertNil(PhysicalControlScreen(json: ["widthPoints": 320, "heightPoints": 480]))
    }

    // MARK: Orientation

    func testOrientationsTurnLikeThePhoneAndSaySideForTheChrome() {
        XCTAssertEqual(PhysicalControlOrientation.portrait.chromeTurns, 0)
        XCTAssertEqual(PhysicalControlOrientation.landscapeLeft.chromeTurns, 1)
        XCTAssertEqual(PhysicalControlOrientation.portraitUpsideDown.chromeTurns, 2)
        XCTAssertEqual(PhysicalControlOrientation.landscapeRight.chromeTurns, 3)
        XCTAssertNil(PhysicalControlOrientation.faceUp.chromeTurns)
        XCTAssertNil(PhysicalControlOrientation.unknown.chromeTurns)

        XCTAssertEqual(PhysicalControlOrientation.portrait.turned(.left), .landscapeLeft)
        XCTAssertEqual(PhysicalControlOrientation.portrait.turned(.right), .landscapeRight)
        XCTAssertEqual(PhysicalControlOrientation.landscapeLeft.turned(.left), .portraitUpsideDown, "upside down is part of the cycle, an iPhone included")
        XCTAssertEqual(PhysicalControlOrientation.portraitUpsideDown.turned(.left), .landscapeRight)
        XCTAssertEqual(PhysicalControlOrientation.portraitUpsideDown.turned(.right), .landscapeLeft)
        XCTAssertEqual(PhysicalControlOrientation.landscapeRight.turned(.right), .portraitUpsideDown)
        XCTAssertEqual(PhysicalControlOrientation.landscapeLeft.turned(.right), .portrait)
        XCTAssertEqual(PhysicalControlOrientation.faceUp.turned(.left), .landscapeLeft, "a flat phone turns from portrait")
    }

    // MARK: Requests

    private func object(_ request: PhysicalControlRequest) throws -> [String: Any] {
        try XCTUnwrap(request.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
    }

    func testTheRequestShapesMatchTheRunnersApi() throws {
        XCTAssertEqual(PhysicalControlRequest.status.method, .get)
        XCTAssertEqual(PhysicalControlRequest.status.path, "/status")
        XCTAssertEqual(PhysicalControlRequest.screen.path, "/screen")
        XCTAssertEqual(PhysicalControlRequest.stop.method, .post)
        XCTAssertEqual(PhysicalControlRequest.stop.path, "/stop")

        let tap = PhysicalControlRequest.tap(x: 195, y: 422.5, ref: "com.apple.Preferences")
        XCTAssertEqual(tap.method, .post)
        XCTAssertEqual(tap.path, "/tap")
        XCTAssertEqual(try object(tap) as NSDictionary, ["x": 195, "y": 422.5, "ref": "com.apple.Preferences"] as NSDictionary)
        XCTAssertNil(try object(.tap(x: 1, y: 2, ref: nil))["ref"], "no reference: Springboard")
        XCTAssertNil(try object(.tap(x: 1, y: 2, ref: nil))["refs"], "no candidates: no refs key")
        XCTAssertEqual(try object(.tap(x: 1, y: 2, ref: nil, refs: ["a.b", "c.d"]))["refs"] as? [String], ["a.b", "c.d"])

        let swipe = PhysicalControlRequest.swipe(x1: 10, y1: 700, x2: 10, y2: 300, duration: 0.4, ref: nil)
        XCTAssertEqual(swipe.path, "/swipe")
        XCTAssertEqual(try object(swipe) as NSDictionary, ["x1": 10, "y1": 700, "x2": 10, "y2": 300, "duration": 0.4] as NSDictionary)

        let type = PhysicalControlRequest.type(text: "ab", bundleID: "com.apple.mobilenotes")
        XCTAssertEqual(type.path, "/type")
        XCTAssertEqual(try object(type) as NSDictionary, ["text": "ab", "bundleId": "com.apple.mobilenotes"] as NSDictionary)

        XCTAssertEqual(PhysicalControlRequest.button(.volumeUp).path, "/button")
        XCTAssertEqual(try object(.button(.home)) as NSDictionary, ["name": "home"] as NSDictionary)
        XCTAssertEqual(try object(.button(.volumeDown)) as NSDictionary, ["name": "volumeDown"] as NSDictionary)

        XCTAssertEqual(PhysicalControlRequest.orientation.method, .get)
        XCTAssertEqual(PhysicalControlRequest.orientation.path, "/orientation")
        let set = PhysicalControlRequest.setOrientation(.landscapeRight)
        XCTAssertEqual(set.method, .post)
        XCTAssertEqual(try object(set) as NSDictionary, ["value": "landscapeRight"] as NSDictionary)

        // Siri (a text is optional) and the App Switcher.
        let siri = PhysicalControlRequest.siri(text: "what time is it")
        XCTAssertEqual(siri.method, .post)
        XCTAssertEqual(siri.path, "/siri")
        XCTAssertEqual(try object(siri) as NSDictionary, ["text": "what time is it"] as NSDictionary)
        XCTAssertEqual(try object(.siri(text: nil)) as NSDictionary, [:] as NSDictionary)
        XCTAssertEqual(try object(.siri(text: "")) as NSDictionary, [:] as NSDictionary, "an empty text is no text")
        XCTAssertEqual(PhysicalControlRequest.appSwitcher.method, .post)
        XCTAssertEqual(PhysicalControlRequest.appSwitcher.path, "/appSwitcher")
        XCTAssertEqual(try object(.appSwitcher) as NSDictionary, [:] as NSDictionary)

        let foreground = PhysicalControlRequest.foreground(ids: ["a.b", "c.d"])
        XCTAssertEqual(foreground.method, .get)
        XCTAssertEqual(foreground.path, "/foreground")
        XCTAssertEqual(foreground.query, ["ids": "a.b,c.d"])
    }

    func testARequestIsTheSameBytesEveryTime() {
        XCTAssertEqual(
            PhysicalControlRequest.swipe(x1: 1, y1: 2, x2: 3, y2: 4, duration: 0.5, ref: "x.y").body,
            PhysicalControlRequest.swipe(x1: 1, y1: 2, x2: 3, y2: 4, duration: 0.5, ref: "x.y").body
        )
    }

    /// Only the endpoints Device Hub Pro uses can be built; none of the spike's
    /// helpers (launch, probe, host, ifaddrs, screenshot) can.
    func testOnlyTheUsedEndpointsCanBeBuilt() {
        let requests: [PhysicalControlRequest] = [
            .status, .screen, .orientation, .stop,
            .tap(x: 0, y: 0, ref: nil), .swipe(x1: 0, y1: 0, x2: 1, y2: 1, duration: 1, ref: nil),
            .type(text: "a", bundleID: "b.c"), .button(.home), .setOrientation(.portrait), .foreground(ids: ["a.b"]),
            .siri(text: nil), .appSwitcher,
        ]
        XCTAssertEqual(
            Set(requests.map(\.path)),
            [
                "/status", "/screen", "/orientation", "/stop", "/tap", "/swipe", "/type", "/button", "/foreground",
                "/siri", "/appSwitcher",
            ]
        )
    }

    // MARK: The URLSession transport

    func testEveryRequestCarriesTheTokenAndGoesToTheTunnelAddress() throws {
        let value = try token()
        let endpoint = try PhysicalControlEndpoint(tunnelAddress: "fd12:3456:789a::1", token: value)
        let transport = PhysicalControlURLSessionTransport(endpoint: endpoint)
        let requests: [PhysicalControlRequest] = [
            .status, .screen, .stop, .tap(x: 1, y: 2, ref: nil), .foreground(ids: ["a.b"]), .button(.home),
            .siri(text: "hi"), .appSwitcher,
        ]
        for request in requests {
            let url = transport.urlRequest(for: request, timeout: .seconds(3))
            XCTAssertEqual(url.value(forHTTPHeaderField: PhysicalControlEndpoint.tokenHeader), value.value, request.path)
            XCTAssertEqual(url.url?.host, "fd12:3456:789a::1", request.path)
            XCTAssertEqual(url.url?.port, 8765)
            XCTAssertEqual(url.url?.scheme, "http")
            XCTAssertEqual(url.url?.path, request.path)
            XCTAssertEqual(url.httpMethod, request.method.rawValue)
            XCTAssertEqual(url.timeoutInterval, 3, accuracy: 0.001)
        }
        let tap = transport.urlRequest(for: .tap(x: 1, y: 2, ref: nil), timeout: .seconds(3))
        XCTAssertEqual(tap.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(tap.httpBody, PhysicalControlRequest.tap(x: 1, y: 2, ref: nil).body)
        let foreground = transport.urlRequest(for: .foreground(ids: ["a.b", "c.d"]), timeout: .seconds(3))
        XCTAssertEqual(foreground.url?.query, "ids=a.b,c.d")
    }

    /// The header goes out on the wire (a `URLProtocol` stub stands in for the
    /// network) and a failure names no address.
    func testTheTokenGoesOutOnTheWireAndAFailureNamesNoAddress() async throws {
        final class Stub: URLProtocol, @unchecked Sendable {
            nonisolated(unsafe) static var seen: [URLRequest] = []
            nonisolated(unsafe) static var fail = false
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                Stub.seen.append(request)
                if Stub.fail {
                    client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
                    return
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        Stub.seen = []
        Stub.fail = false
        let value = try token()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        let endpoint = try PhysicalControlEndpoint(tunnelAddress: "fd12:3456:789a::1", token: value)
        let transport = PhysicalControlURLSessionTransport(endpoint: endpoint, configuration: configuration)

        let answer = try await transport.send(.status, timeout: .seconds(2))
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(answer.object?["ok"] as? Bool, true)
        XCTAssertEqual(Stub.seen.first?.value(forHTTPHeaderField: PhysicalControlEndpoint.tokenHeader), value.value)

        Stub.fail = true
        do {
            _ = try await transport.send(.status, timeout: .seconds(2))
            XCTFail("a failed connection throws")
        } catch let error as PhysicalControlError {
            guard case .transportFailed(let text) = error else { return XCTFail("\(error)") }
            XCTAssertFalse(text.contains("fd12"), text)
            XCTAssertFalse(error.description.contains("fd12"))
        }
    }

    // MARK: The runner's launch

    private func configuration() throws -> PhysicalControlLaunchConfiguration {
        PhysicalControlLaunchConfiguration(
            xctestrunURL: URL(fileURLWithPath: "/tmp/DeviceHubProAgent.xctestrun"),
            hardwareUDID: ControlHarness.udid,
            endpoint: try PhysicalControlEndpoint(
                tunnelAddress: ControlHarness.address,
                token: try XCTUnwrap(PhysicalControlToken(String(repeating: "ab", count: 32)))
            ),
            developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"),
            maximumSeconds: 7200
        )
    }

    func testTheRunnerIsStartedWithTheBindAddressAndTheTokenInItsEnvironmentOnly() throws {
        let configuration = try configuration()
        let arguments = XcodebuildRunnerLauncher.arguments(for: configuration)
        XCTAssertEqual(arguments.first, "test-without-building")
        XCTAssertTrue(arguments.contains("-only-testing:DeviceHubProAgentUITests/DeviceHubProAgentUITests/testServe"))
        XCTAssertFalse(arguments.joined(separator: " ").contains(String(repeating: "ab", count: 32)), "the token is never on the command line")
        XCTAssertFalse(arguments.joined(separator: " ").contains(ControlHarness.address), "nor is the address")

        let environment = XcodebuildRunnerLauncher.environment(for: configuration)
        XCTAssertEqual(environment["TEST_RUNNER_DHP_BIND"], ControlHarness.address)
        XCTAssertEqual(environment["TEST_RUNNER_DHP_TOKEN"], String(repeating: "ab", count: 32))
        XCTAssertEqual(environment["TEST_RUNNER_DHP_PORT"], "8765")
        XCTAssertEqual(environment["TEST_RUNNER_DHP_MAX_SECONDS"], "7200")
        XCTAssertEqual(environment["TEST_RUNNER_DHP_IDLE_SECONDS"], "90", "a runner nobody polls ends itself")
        XCTAssertEqual(environment["DEVELOPER_DIR"], "/Applications/Xcode.app/Contents/Developer")
    }

    func testTheInheritedEnvironmentCannotOverrideTheRunnersSecrets() throws {
        setenv("TEST_RUNNER_DHP_TOKEN", "inherited-token-that-must-not-survive", 1)
        setenv("TEST_RUNNER_DHP_BIND", "0.0.0.0", 1)
        defer {
            unsetenv("TEST_RUNNER_DHP_TOKEN")
            unsetenv("TEST_RUNNER_DHP_BIND")
        }
        let environment = XcodebuildRunnerLauncher.environment(for: try configuration())
        XCTAssertEqual(environment["TEST_RUNNER_DHP_BIND"], ControlHarness.address, "never a wider bind")
        XCTAssertEqual(environment["TEST_RUNNER_DHP_TOKEN"], String(repeating: "ab", count: 32))
    }

    // MARK: The tunnel address in `details`

    private func detailsJSON(edit: (inout [String: Any]) -> Void) throws -> Data {
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: try ApplePhysicalDeviceTests.data("devicectl-info-details.json")) as? [String: Any])
        var result = try XCTUnwrap(document["result"] as? [String: Any])
        edit(&result)
        document["result"] = result
        return try JSONSerialization.data(withJSONObject: document)
    }

    func testDetailsCarryTheTunnelAddress() throws {
        let details = try DevicectlJSON.decode(
            DevicectlDeviceDetails.self,
            from: try ApplePhysicalDeviceTests.data("devicectl-info-details.json")
        ).value
        XCTAssertEqual(details.tunnelIPAddress, "fd00:0000:0000::0", "the capture's scrubbed placeholder")
        XCTAssertNotNil(PhysicalControlEndpoint.canonicalTunnelAddress(try XCTUnwrap(details.tunnelIPAddress)))
    }

    func testTheDeprecatedBlockIsTheFallbackAndAMissingAddressIsNil() throws {
        // Only `connectionProperties.tunnelIPAddress` (the deprecated block).
        let legacyOnly = try detailsJSON { result in
            var properties = result["properties"] as? [String: Any] ?? [:]
            var connection = properties["connection"] as? [String: Any] ?? [:]
            connection["tunnelIPAddressString"] = nil
            properties["connection"] = connection
            result["properties"] = properties
            var legacy = result["connectionProperties"] as? [String: Any] ?? [:]
            legacy["tunnelIPAddress"] = "fd12:3456:789a::1"
            result["connectionProperties"] = legacy
        }
        XCTAssertEqual(try DevicectlJSON.decode(DevicectlDeviceDetails.self, from: legacyOnly).value.tunnelIPAddress, "fd12:3456:789a::1")

        // A phone that is not connected through the tunnel has none.
        let none = try detailsJSON { result in
            var properties = result["properties"] as? [String: Any] ?? [:]
            var connection = properties["connection"] as? [String: Any] ?? [:]
            connection["tunnelIPAddressString"] = nil
            properties["connection"] = connection
            result["properties"] = properties
            var legacy = result["connectionProperties"] as? [String: Any] ?? [:]
            legacy["tunnelIPAddress"] = nil
            result["connectionProperties"] = legacy
        }
        XCTAssertNil(try DevicectlJSON.decode(DevicectlDeviceDetails.self, from: none).value.tunnelIPAddress)
    }

    // MARK: The build cache

    private func makeFolder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aqa-control-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeSources() throws -> URL {
        let root = try makeFolder("sources")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Host"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tests"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("client"), withIntermediateDirectories: true)
        try "print('gen')".write(to: root.appendingPathComponent("gen_project.py"), atomically: true, encoding: .utf8)
        try "host".write(to: root.appendingPathComponent("Host/AgentHostApp.swift"), atomically: true, encoding: .utf8)
        try "tests".write(to: root.appendingPathComponent("Tests/AgentActions.swift"), atomically: true, encoding: .utf8)
        try "client".write(to: root.appendingPathComponent("client/agentclient.py"), atomically: true, encoding: .utf8)
        try "notes".write(to: root.appendingPathComponent("SPIKE.md"), atomically: true, encoding: .utf8)
        return root
    }

    func testTheSourcesDigestFollowsTheBuildInputsOnly() throws {
        let sources = try makeSources()
        let base = try PhysicalControlRunnerBuilder.sourcesDigest(of: sources)
        XCTAssertEqual(try PhysicalControlRunnerBuilder.sourcesDigest(of: sources), base, "stable")

        // Not inputs: the notes, the Python client, the generated project.
        try "changed".write(to: sources.appendingPathComponent("SPIKE.md"), atomically: true, encoding: .utf8)
        try "changed".write(to: sources.appendingPathComponent("client/agentclient.py"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: sources.appendingPathComponent("DeviceHubProAgent.xcodeproj"), withIntermediateDirectories: true)
        try "generated".write(to: sources.appendingPathComponent("DeviceHubProAgent.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try PhysicalControlRunnerBuilder.sourcesDigest(of: sources), base)

        // Inputs: a runner source changes the digest.
        try "tests v2".write(to: sources.appendingPathComponent("Tests/AgentActions.swift"), atomically: true, encoding: .utf8)
        let changed = try PhysicalControlRunnerBuilder.sourcesDigest(of: sources)
        XCTAssertNotEqual(changed, base)
        try "print('gen2')".write(to: sources.appendingPathComponent("gen_project.py"), atomically: true, encoding: .utf8)
        XCTAssertNotEqual(try PhysicalControlRunnerBuilder.sourcesDigest(of: sources), changed)
    }

    func testTheStampChangesWithEachSigningInput() {
        let base = PhysicalControlRunnerBuilder.stamp(sourcesDigest: "d1", team: "ABCDE12345", hardwareUDID: "u1", xcodeBuild: "27A266a")
        XCTAssertNotEqual(base, PhysicalControlRunnerBuilder.stamp(sourcesDigest: "d2", team: "ABCDE12345", hardwareUDID: "u1", xcodeBuild: "27A266a"))
        XCTAssertNotEqual(base, PhysicalControlRunnerBuilder.stamp(sourcesDigest: "d1", team: "ZZZZZ99999", hardwareUDID: "u1", xcodeBuild: "27A266a"))
        XCTAssertNotEqual(base, PhysicalControlRunnerBuilder.stamp(sourcesDigest: "d1", team: "ABCDE12345", hardwareUDID: "u2", xcodeBuild: "27A266a"))
        XCTAssertNotEqual(base, PhysicalControlRunnerBuilder.stamp(sourcesDigest: "d1", team: "ABCDE12345", hardwareUDID: "u1", xcodeBuild: "27B1"))
        XCTAssertEqual(base, PhysicalControlRunnerBuilder.stamp(sourcesDigest: "d1", team: "ABCDE12345", hardwareUDID: "U1", xcodeBuild: "27A266a"), "the UDID's case does not matter")
        XCTAssertFalse(base.contains("ABCDE12345"), "a digest, never the team")
    }

    func testAMatchingCacheIsUsedWithoutBuildingAndAStaleOneIsNot() async throws {
        let sources = try makeSources()
        let cache = try makeFolder("cache")
        let builder = PhysicalControlRunnerBuilder(
            sourcesDirectory: sources,
            cacheDirectory: cache,
            developerDirectory: URL(fileURLWithPath: "/nonexistent/Developer"),
            xcodeBuild: "27A266a"
        )
        let folder = cache.appendingPathComponent("iPhone13,2", isDirectory: true)
        let products = folder.appendingPathComponent("dd/Build/Products", isDirectory: true)
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        try "plist".write(to: products.appendingPathComponent("DeviceHubProAgent.xctestrun"), atomically: true, encoding: .utf8)
        let stamp = PhysicalControlRunnerBuilder.stamp(
            sourcesDigest: try PhysicalControlRunnerBuilder.sourcesDigest(of: sources),
            team: "ABCDE12345",
            hardwareUDID: ControlHarness.udid,
            xcodeBuild: "27A266a"
        )
        try stamp.write(to: folder.appendingPathComponent("stamp"), atomically: true, encoding: .utf8)

        let target = PhysicalControlTarget(hardwareUDID: ControlHarness.udid, productType: "iPhone13,2")
        let build = try await builder.ensureRunner(for: target, team: "ABCDE12345") { _ in }
        XCTAssertFalse(build.wasBuilt, "cached: no build")
        XCTAssertEqual(build.xctestrunURL.lastPathComponent, "DeviceHubProAgent.xctestrun")

        // A changed source makes the stamp stale: it rebuilds, and here the
        // build cannot run (no Xcode at that path), so it fails.
        try "tests v2".write(to: sources.appendingPathComponent("Tests/AgentActions.swift"), atomically: true, encoding: .utf8)
        do {
            _ = try await builder.ensureRunner(for: target, team: "ABCDE12345") { _ in }
            XCTFail("a stale cache is rebuilt")
        } catch let error as PhysicalControlError {
            guard case .buildFailed = error else { return XCTFail("\(error)") }
        } catch {
            // The generator or xcodebuild could not even be started.
        }
    }

    func testNoTeamMeansNoBuild() async throws {
        let builder = PhysicalControlRunnerBuilder(
            sourcesDirectory: try makeSources(),
            cacheDirectory: try makeFolder("cache"),
            developerDirectory: nil,
            xcodeBuild: nil
        )
        for team in ["", "   "] {
            do {
                _ = try await builder.ensureRunner(for: PhysicalControlTarget(hardwareUDID: ControlHarness.udid, productType: nil), team: team) { _ in }
                XCTFail("no team")
            } catch {
                XCTAssertEqual(error as? PhysicalControlError, .noTeam)
            }
        }
    }

    func testTheCacheFolderIsNamedByProductType() {
        XCTAssertEqual(PhysicalControlRunnerBuilder.folderName(productType: "iPhone13,2"), "iPhone13,2")
        XCTAssertEqual(PhysicalControlRunnerBuilder.folderName(productType: "../../etc"), "etc")
        XCTAssertEqual(PhysicalControlRunnerBuilder.folderName(productType: nil), "device")
        XCTAssertEqual(PhysicalControlRunnerBuilder.folderName(productType: "///"), "device")
    }

    func testABuildFailureNamesNeitherTheTeamNorThePhone() {
        let output = """
        note: something
        error: No profiles for 'com.devicehubpro.agent.host' were found: Xcode couldn't find any iOS App Development provisioning profiles matching team ABCDE12345 for 00000000-0000000000000000
        """
        let summary = PhysicalControlRunnerBuilder.summary(ofBuildOutput: output, secrets: ["ABCDE12345", "00000000-0000000000000000"])
        XCTAssertTrue(summary.contains("No profiles"))
        XCTAssertFalse(summary.contains("ABCDE12345"))
        XCTAssertFalse(summary.contains("00000000-0000000000000000"))
    }

    func testTheSourcesAreFoundFromTheEnvironmentTheBundleOrTheCheckout() throws {
        let sources = try makeSources()
        XCTAssertEqual(
            PhysicalControlRunnerBuilder.locateSources(environment: ["DHP_IOS_AGENT_DIR": sources.path], resourceURL: nil, executableURL: nil)?.path,
            sources.path
        )
        XCTAssertNil(
            PhysicalControlRunnerBuilder.locateSources(environment: ["DHP_IOS_AGENT_DIR": "/nonexistent"], resourceURL: nil, executableURL: nil),
            "an override that is not the sources is not silently replaced"
        )
        // The bundle's resource folder.
        let resources = try makeFolder("resources")
        try FileManager.default.copyItem(at: sources, to: resources.appendingPathComponent("ios-agent"))
        XCTAssertEqual(
            PhysicalControlRunnerBuilder.locateSources(environment: [:], resourceURL: resources, executableURL: nil)?.lastPathComponent,
            "ios-agent"
        )
        // The checkout the executable was built in: an ancestor holds ios/agent.
        let checkout = try makeFolder("checkout")
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent("ios"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sources, to: checkout.appendingPathComponent("ios/agent"))
        let executable = checkout.appendingPathComponent(".build/debug/DeviceHubPro")
        XCTAssertEqual(
            PhysicalControlRunnerBuilder.locateSources(environment: [:], resourceURL: nil, executableURL: executable)?.path,
            checkout.appendingPathComponent("ios/agent").path
        )
        XCTAssertNil(PhysicalControlRunnerBuilder.locateSources(environment: [:], resourceURL: nil, executableURL: nil))
    }

    /// The runner's own sources are in the repository (`ios/agent`), so the
    /// digest of the real folder works and the stamp follows them.
    func testTheRepositorysRunnerSourcesDigest() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ios/agent", isDirectory: true)
        let digest = try PhysicalControlRunnerBuilder.sourcesDigest(of: root)
        XCTAssertEqual(digest.count, 64)
        XCTAssertEqual(PhysicalControlRunnerBuilder.locateSources(environment: ["DHP_IOS_AGENT_DIR": root.path], resourceURL: nil, executableURL: nil)?.path, root.path)
    }
}
