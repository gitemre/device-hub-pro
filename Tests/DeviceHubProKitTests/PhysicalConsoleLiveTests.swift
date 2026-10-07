import XCTest
@testable import DeviceHubProKit

/// The log pane's console bridge against the dedicated test iPhone, behind the
/// same switches as `ApplePhysicalLiveTests` (`DHP_IOS_DEVICE_LIVE=1` and
/// `DHP_IPHONE_UDID`). It launches Device Hub Pro's own host app
/// (`com.devicehubpro.agent.host`, `ios/agent`, which logs "host app launched"
/// through os_log at launch) under devicectl's console, waits for that line to
/// arrive as an entry, then stops the stream, which ends the app. Nothing else
/// is launched; the phone is left on its home screen.
final class PhysicalConsoleLiveTests: XCTestCase {
    func testTheHostAppsOsLogLineArrivesThroughTheConsoleBridge() async throws {
        let connected = try await ApplePhysicalLiveTests.connectedTestIPhone()
        let installed = try await connected.client.apps().value.apps
        try XCTSkipUnless(
            installed.contains { $0.bundleIdentifier == "com.devicehubpro.agent.host" },
            "the agent host app is not installed (ios/agent/build.sh, then devicectl install)"
        )

        let stream = try PhysicalConsoleLogStream(client: connected.client, bundleID: "com.devicehubpro.agent.host")
        stream.start()
        let deadline = Date().addingTimeInterval(30)
        while !stream.snapshot().contains(where: { $0.message == "host app launched" }), Date() < deadline {
            if case .stopped(let reason) = stream.status { return XCTFail("the session ended early: \(reason)") }
            try await Task.sleep(for: .milliseconds(100))
        }
        let line = stream.snapshot().first { $0.message == "host app launched" }
        await stream.stopAndWait()

        let entry = try XCTUnwrap(line, "no os_log line arrived within 30 s")
        XCTAssertEqual(entry.tag, "DeviceHubProAgentHost")
        XCTAssertEqual(entry.subsystem, "host")
        XCTAssertGreaterThan(entry.pid, 0)
        XCTAssertEqual(stream.status, .idle)
    }
}
