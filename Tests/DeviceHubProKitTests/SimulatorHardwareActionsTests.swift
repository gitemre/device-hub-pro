import XCTest
@testable import DeviceHubProKit

/// `SimulatorHardwareActions` on `FakeSimulatorBridge` and fake tools, the
/// orientation names and GSEvent values, and the simctl/devicectl calls it
/// adds.
///
/// `devicectl-device-orientation-set-landscapeLeft.json` is the stdout of
/// `devicectl device orientation set landscapeLeft --device <UDID> -j - -t 30`
/// (devicectl 642.16, Xcode 27.0 27A266a), captured on 2026-09-25 against
/// `DeviceHubPro-MirrorSession-devicectl`, a throwaway iPhone 17 Pro (iOS 27.0)
/// created for it in the default set (CoreDevice does not see private sets),
/// UDID 5B59FD8E-4FE5-41B6-9B4F-0892086D6781, booted with Safari open, then
/// deleted. Byte-exact; it holds no user name or path.
final class SimulatorHardwareActionsTests: XCTestCase {
    private static let udid = "5B59FD8E-4FE5-41B6-9B4F-0892086D6781"
    private let address = SimulatorAddress(udid: SimulatorHardwareActionsTests.udid, deviceSetPath: "/tmp/set")

    func testOrientationNamesAndGSEventValues() {
        XCTAssertEqual(SimulatorOrientation.allCases.map(\.rawValue), ["portrait", "portraitUpsideDown", "landscapeLeft", "landscapeRight"])
        XCTAssertEqual(SimulatorOrientation.allCases.map(\.gsEventValue), [1, 2, 3, 4])
    }

    func testButtonUsages() {
        let buttons: [(SimulatorHardwareButton, UInt32, UInt32)] = [
            (.home, 0x0C, 0x40), (.side, 0x0C, 0x30), (.volumeUp, 0x0C, 0xE9),
            (.volumeDown, 0x0C, 0xEA), (.siri, 0x0C, 0xCF), (.usage(page: 0x0B, usage: 0x2D), 0x0B, 0x2D),
        ]
        for (button, page, usage) in buttons {
            XCTAssertEqual(button.usagePage, page, "\(button)")
            XCTAssertEqual(button.usage, usage, "\(button)")
        }
    }

    /// Each press is down, up, off the main thread, on one lazy connection.
    func testPressesSendDownThenUp() async throws {
        let bridge = FakeSimulatorBridge()
        let actions = SimulatorHardwareActions(address: address, bridge: bridge)
        XCTAssertTrue(bridge.inputs.isEmpty, "nothing connects before the first press")
        try await actions.home()
        try await actions.lock()
        try await actions.volumeUp()
        try await actions.volumeDown()
        try await actions.siri()
        try await actions.side(hold: .milliseconds(1))
        XCTAssertEqual(bridge.inputs.count, 1)
        let sent = try XCTUnwrap(bridge.inputs.first).sent
        let buttons: [SimulatorHardwareButton] = [.home, .side, .volumeUp, .volumeDown, .siri, .side]
        XCTAssertEqual(sent, buttons.flatMap { [SimulatorHIDEvent.button($0, isDown: true), .button($0, isDown: false)] })
        XCTAssertEqual(bridge.mainThreadCalls, 0)
    }

    func testAnInjectedInputIsShared() async throws {
        let bridge = FakeSimulatorBridge()
        let address = self.address
        let input = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: bridge.makeInput(for: address)) }
        }
        let actions = SimulatorHardwareActions(address: address, bridge: bridge, input: input)
        try await actions.home()
        XCTAssertEqual(bridge.inputs.count, 1)
        XCTAssertEqual(bridge.inputs.first?.sent.count, 2)
    }

    /// Without devicectl the rotation is the GSEvent.
    func testRotationWithoutDevicectlUsesTheGSEvent() async throws {
        let bridge = FakeSimulatorBridge()
        let actions = SimulatorHardwareActions(address: address, bridge: bridge)
        for orientation in SimulatorOrientation.allCases {
            let route = try await actions.rotate(to: orientation)
            XCTAssertEqual(route, .gsEvent)
        }
        XCTAssertEqual(bridge.gsEvents.count, 1, "one port object, looked up per send")
        XCTAssertEqual(bridge.gsEvents.first?.sent, [.orientation(1), .orientation(2), .orientation(3), .orientation(4)])
        XCTAssertEqual(bridge.mainThreadCalls, 0)
    }

    /// devicectl first; the answer is the captured one.
    func testRotationPrefersDevicectl() async throws {
        let fake = try FakeTool(name: "devicectl", rules: [
            .init("orientation set landscapeLeft", stdoutFile: SimctlFixtureTests.url("devicectl", "devicectl-device-orientation-set-landscapeLeft.json")),
        ])
        let devicectl = try DevicectlClient(devicectlURL: fake.executableURL, simulator: makeSimulator(), commandTimeout: .seconds(30))
        let bridge = FakeSimulatorBridge()
        let actions = SimulatorHardwareActions(address: address, bridge: bridge, devicectl: devicectl)
        let route = try await actions.rotate(to: .landscapeLeft)
        XCTAssertEqual(route, .devicectl)
        XCTAssertEqual(fake.invocations, [["device", "orientation", "set", "landscapeLeft", "--device", Self.udid, "-j", "-", "-t", "30"]])
        XCTAssertTrue(bridge.gsEvents.isEmpty)

        let answer = try await devicectl.setOrientation(.landscapeLeft)
        XCTAssertEqual(answer.value.deviceOrientation, "landscapeLeft")
        XCTAssertEqual(answer.value.deviceOrientationNonFlat, "landscapeLeft")
        XCTAssertEqual(answer.value.deviceIsOrientationLocked, false)
    }

    /// A devicectl that fails (a private-set simulator is unknown to
    /// CoreDevice) falls back to the GSEvent.
    func testRotationFallsBackWhenDevicectlFails() async throws {
        let devicectl = try DevicectlClient(
            devicectlURL: URL(fileURLWithPath: "/nonexistent/devicectl"),
            simulator: makeSimulator(),
            commandTimeout: .seconds(5)
        )
        let bridge = FakeSimulatorBridge()
        let actions = SimulatorHardwareActions(address: address, bridge: bridge, devicectl: devicectl)
        let route = try await actions.rotate(to: .landscapeRight)
        XCTAssertEqual(route, .gsEvent)
        XCTAssertEqual(bridge.gsEvents.first?.sent, [.orientation(4)])
    }

    func testAGSEventFailureIsThrown() async {
        var configuration = FakeSimulatorBridge.Configuration()
        configuration.gsEventError = SimulatorBridgeError(.timedOut, "PurpleWorkspacePort send: (ipc/send) timed out")
        let actions = SimulatorHardwareActions(address: address, bridge: FakeSimulatorBridge(configuration))
        do {
            try await actions.rotate(to: .portrait)
            XCTFail("the send failed")
        } catch {
            XCTAssertEqual((error as? SimulatorBridgeError)?.kind, .timedOut)
        }
    }

    func testShakePostsTheNotification() async throws {
        let fake = try FakeTool(name: "simctl", rules: [])
        let simctl = SimctlClient(simctlURL: fake.executableURL, deviceSet: URL(fileURLWithPath: "/tmp/set"))
        let actions = SimulatorHardwareActions(address: address, bridge: FakeSimulatorBridge(), simctl: simctl)
        try await actions.shake()
        XCTAssertEqual(fake.invocations, [["--set", "/tmp/set", "spawn", Self.udid, "notifyutil", "-p", "com.apple.UIKit.SimulatorShake"]])

        let withoutSimctl = SimulatorHardwareActions(address: address, bridge: FakeSimulatorBridge())
        do {
            try await withoutSimctl.shake()
            XCTFail("shake needs simctl")
        } catch {}
    }

    /// The simctl calls the session and the live tests use.
    func testPasteboardAndScreenshotArgv() async throws {
        let fake = try FakeTool(name: "simctl", rules: [.init("pbpaste", output: "şğ")])
        let simctl = SimctlClient(simctlURL: fake.executableURL)
        try await simctl.setPasteboard(udid: Self.udid, text: "ş")
        let text = try await simctl.pasteboard(udid: Self.udid)
        XCTAssertEqual(text, "şğ")
        try await simctl.screenshot(udid: Self.udid, to: URL(fileURLWithPath: "/tmp/shot.png"))
        XCTAssertEqual(fake.invocations, [
            ["pbcopy", Self.udid],
            ["pbpaste", Self.udid],
            ["io", Self.udid, "screenshot", "--type=png", "/tmp/shot.png"],
        ])
        do {
            try await simctl.postDarwinNotification(udid: Self.udid, name: "-p")
            XCTFail("a flag is not a notification name")
        } catch let error as SimctlClientError {
            XCTAssertEqual(error, .invalidValue("notification name '-p'"))
        }
    }

    private func makeSimulator() -> SimulatorDevice {
        SimulatorDevice(
            udid: Self.udid,
            name: "DeviceHubPro-MirrorSession-devicectl",
            state: .booted,
            isAvailable: true,
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
        )
    }
}
