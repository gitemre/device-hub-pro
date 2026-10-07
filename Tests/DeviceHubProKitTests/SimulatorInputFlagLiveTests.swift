import Foundation
import XCTest
@testable import DeviceHubProKit

/// The dtuhidd flag and a locked screen against a real simulator, behind
/// `DHP_IOS_LIVE=1`:
///
///     DHP_IOS_LIVE=1 swift test --filter SimulatorInputFlagLiveTests
///
/// PRIVATE-API CoreSimulator 1171.7: the live canary for the fixtures
/// `simctl-spawn-notifyutil-g-dtuhidd-active.*.stdout.txt` and
/// for what the ready signal reads on a locked simulator's screen. It
/// creates an iPhone in a private device set (`LiveTestSimulators`), boots
/// it to its home screen, reads `com.apple.coredevice.dtuhidd.active` (0:
/// nothing connected dtuhidd in this boot), presses the side button through
/// the bridge — the first input, which opens the dtuhidd connection — reads
/// the flag again (1), and takes a screenshot of the locked simulator
/// within the readiness bound (20 s): it must not read as the boot screen
/// (which would read as not responding). On iOS 27.0 (2026-09-26) the side
/// button showed the lock screen, which reads as the home screen, 2.2 s
/// after the press; only a screen powered off (`simctl io <UDID>
/// screenConfig power off`) gives no picture (simctl waits 61 s). The
/// device, its set and its log folder are deleted after.
///
/// With `DHP_IOS_CAPTURE_DIR` set, both flag reads are written there
/// byte for byte (`notifyutil-g-dtuhidd-active.before-input.stdout.txt`,
/// `.after-input.stdout.txt`), the fixtures' sources.
final class SimulatorInputFlagLiveTests: XCTestCase {
    private static func report(_ line: String) {
        print("INPUT-FLAG-LIVE \(line)")
    }

    func testTheFirstInputSetsTheFlagAndALockedScreenReadsAsOff() async throws {
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
        let device = try await simulators.createDevice(name: "DeviceHubPro-InputFlagLive")
        let udid = device.udid
        let simctl = simulators.simctl
        Self.report("created \(udid) in \(simulators.setDirectory.path)")
        try await simctl.bootStatus(udid: udid, bootIfNeeded: true)

        let screen = simulators.setDirectory.appendingPathComponent("screen.png")
        var content: SimulatorReadiness.ScreenContent?
        let homeDeadline = ContinuousClock.now + .seconds(90)
        while content != .homeScreen, ContinuousClock.now < homeDeadline {
            try await simctl.screenshot(udid: udid, to: screen, timeout: .seconds(20))
            content = SimulatorReadiness.screenContent(imageAt: screen)
            if content != .homeScreen {
                try await Task.sleep(for: .seconds(1))
            }
        }
        XCTAssertEqual(content, .homeScreen)
        // Let SpringBoard settle before the first press.
        try await Task.sleep(for: .seconds(3))

        let name = SimulatorHardwareActions.dtuhiddActiveNotification
        let before = try await simctl.checked(["spawn", udid, "notifyutil", "-g", name])
        XCTAssertEqual(SimctlParsing.notifyState(fromNotifyutilOutput: before.standardOutputText, name: name), 0)
        let readBefore = try await simctl.notifyState(udid: udid, name: name)
        XCTAssertEqual(readBefore, 0, "nothing connected dtuhidd in this boot yet")

        let bridge = LiveSimulatorBridge()
        let address = SimulatorAddress(udid: udid, deviceSetPath: simulators.setDirectory.path)
        let actions = SimulatorHardwareActions(address: address, bridge: bridge, simctl: simctl)
        try await actions.lock()
        try await Task.sleep(for: .seconds(3))

        let after = try await simctl.checked(["spawn", udid, "notifyutil", "-g", name])
        let readAfter = try await simctl.notifyState(udid: udid, name: name)
        XCTAssertEqual(readAfter, 1, "the first input connected dtuhidd")
        Self.report("dtuhidd.active \(readBefore) -> \(readAfter)")

        let locked = simulators.setDirectory.appendingPathComponent("locked.png")
        let started = ContinuousClock.now
        var lockedContent: SimulatorReadiness.ScreenContent?
        var failure: Error?
        do {
            try await simctl.screenshot(udid: udid, to: locked, timeout: .seconds(20))
            lockedContent = SimulatorReadiness.screenContent(imageAt: locked)
        } catch {
            failure = error
        }
        let outcome = lockedContent.map { "\($0)" } ?? "no picture (\(failure.map { "\($0)" } ?? "unreadable"))"
        Self.report("locked screen: \(outcome) after \(ContinuousClock.now - started)")
        XCTAssertNotEqual(lockedContent, .bootScreen, "a screen that is off must not read as the boot screen")

        if let directory = ProcessInfo.processInfo.environment["DHP_IOS_CAPTURE_DIR"], !directory.isEmpty {
            let folder = URL(fileURLWithPath: directory)
            try before.standardOutput.write(to: folder.appendingPathComponent("notifyutil-g-dtuhidd-active.before-input.stdout.txt"))
            try after.standardOutput.write(to: folder.appendingPathComponent("notifyutil-g-dtuhidd-active.after-input.stdout.txt"))
            if lockedContent != nil {
                try FileManager.default.copyItem(at: locked, to: folder.appendingPathComponent("screenshot.locked.png"))
            }
        }
    }
}
