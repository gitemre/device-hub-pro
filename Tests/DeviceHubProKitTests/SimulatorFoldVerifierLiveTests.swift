import Foundation
import XCTest
@testable import DeviceHubProKit

/// The verifier's Device & hardware rows against Device Hub Pro's own
/// senders on a foldable simulator of its own (`DHP_IOS_LIVE=1`,
/// `DHP_IOS_LIVE_DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-Duo`,
/// Xcode 27.1): each fold preset as the app reads the hinge and the panel it
/// is on, a ⌘ shortcut, Home, and the laptop and the tent as the app reads
/// the way they are held.
final class SimulatorFoldVerifierLiveTests: XCTestCase {
    func testTheVerifierReadsTheFoldAShortcutAndHome() async throws {
        let toolchain = try await LiveTestSimulators.toolchain()
        let simulators = try LiveTestSimulators.Session(toolchain: toolchain)
        do {
            try await exercise(simulators, toolchain: toolchain)
        } catch {
            await simulators.tearDown()
            throw error
        }
        let leftovers = await simulators.tearDown()
        XCTAssertEqual(leftovers, [])
    }

    private func exercise(_ simulators: LiveTestSimulators.Session, toolchain: AppleToolchain) async throws {
        let device = try await simulators.createDevice(name: "DeviceHubPro-FoldVerifierLive")
        let simctl = simulators.simctl
        guard let panels = try await LiveTestSimulators.displays(ofDeviceType: device.deviceTypeIdentifier, simctl: simctl).panels else {
            throw XCTSkip("needs a foldable: DHP_IOS_LIVE_DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-Duo")
        }
        let udid = device.udid
        try await simctl.boot(udid: udid)
        _ = try await simctl.bootStatus(udid: udid)
        let app = try await iosVerifierApp(toolchain: toolchain)
        try await simctl.install(udid: udid, app: app)
        _ = try await simctl.launch(udid: udid, bundleIdentifier: IOSVerifierLiveTests.bundle, terminateRunning: true)
        let verifier = VerifierReader(simctl: simctl, udid: udid)
        _ = try await verifier.waitForDocument(timeout: .seconds(90))

        let address = SimulatorAddress(udid: udid, deviceSetPath: simulators.setDirectory.path)
        let bridge = LiveSimulatorBridge()
        let fold = SimulatorFoldSender(bridge: bridge)
        func size(of profile: SimulatorDisplayProfile) -> [Int] { [profile.width, profile.height].sorted() }
        let outer = size(of: panels.outer), inner = size(of: panels.inner)

        /// Waits for the hinge's status and for its angle to settle (a preset
        /// sweeps the hinge over 0.6 s, and the status turns on the way), then
        /// for the window on `panel`; returns the settled angle.
        func expect(_ status: String, on panel: [Int], _ label: String) async throws -> Double? {
            _ = try await verifier.wait(for: "device.hinge", bound: .seconds(20)) { $0.hasPrefix(status + " ") }
            let hinge = try await Self.settled(verifier, "device.hinge")
            let screen = try await verifier.wait(for: "device.screen", bound: .seconds(20)) { Self.pixels($0) == panel }
            Self.report("\(label): hinge \(hinge ?? "nothing"), screen \(screen ?? "nothing")")
            XCTAssertEqual(hinge.map { String($0.split(separator: " ")[0]) }, status, label)
            XCTAssertEqual(screen.flatMap(Self.pixels), panel, "\(label): the window fills the lit panel")
            return hinge.flatMap { Double($0.split(separator: " ").last ?? "") }
        }

        let booted = try await expect("closed", on: outer, "booted closed")
        fold.send(SimulatorFold.presetSteps(for: .halfOpened, from: 0), to: address)
        let half = try await expect("partiallyOpen", on: inner, "Half")
        fold.send(SimulatorFold.presetSteps(for: .opened, from: 130), to: address)
        let opened = try await expect("fullyOpen", on: inner, "Opened")
        fold.send(degrees: 100, to: address)
        let hundred = try await expect("partiallyOpen", on: inner, "the slider at 100°")
        fold.send(SimulatorFold.presetSteps(for: .closed, from: 100), to: address)
        let closed = try await expect("closed", on: outer, "Closed")
        // Apps read a sent angle as 5 + angle × 170 / 180 between the ends
        // (Device Hub's Half sends 130: 127.78°), and the ends as they are.
        XCTAssertEqual(try XCTUnwrap(booted), 0, accuracy: 0.5, "booted closed")
        XCTAssertEqual(try XCTUnwrap(half), 127.8, accuracy: 1, "Half")
        XCTAssertEqual(try XCTUnwrap(opened), 180, accuracy: 0.5, "Opened")
        XCTAssertEqual(try XCTUnwrap(hundred), 99.4, accuracy: 1, "the slider at 100°")
        XCTAssertLessThan(try XCTUnwrap(closed), 20, "Closed")

        // A ⌘ shortcut as Capture keyboard shortcuts sends it, then Home.
        let input = bridge.makeInput(for: address)
        _ = try input.connect()
        defer { input.disconnect() }
        for event in try XCTUnwrap(KeyShortcut(keyCode: 0).simulatorStroke).events { try input.send(event) }
        try input.flush(timeout: .seconds(2))
        let key = try await verifier.wait(for: "device.lastKey", bound: .seconds(10)) { $0 == "command+a" }
        Self.report("⌘A read as \(key ?? "nothing")")
        XCTAssertEqual(key, "command+a")

        try input.send(.button(.home, isDown: true))
        try input.send(.button(.home, isDown: false))
        try input.flush(timeout: .seconds(2))
        let away = try await verifier.wait(for: "device.appState", bound: .seconds(10)) { $0 == "background" }
        XCTAssertEqual(away, "background", "Home sends the app to the background")
        _ = try await simctl.launch(udid: udid, bundleIdentifier: IOSVerifierLiveTests.bundle)
        let back = try await verifier.wait(for: "device.appState", bound: .seconds(10)) { $0 == "active" }
        XCTAssertEqual(back, "active", "opened again")

        // On its side: a laptop shows the inner panel, a tent the outer one
        // from the device's other face. Both are held landscape left
        // (`SimulatorHeldPosture.orientation`); UIDevice reads the tent's
        // outer panel landscape right and the laptop's inner one landscape
        // left, its camera half standing up as the lid.
        fold.send(SimulatorHeldPosture.tent.steps(from: .outer, angle: 0), to: address)
        _ = try await expect("closed", on: outer, "Tent")
        let tent = try await verifier.wait(for: "sensors.orientation", bound: .seconds(10)) { $0 == "landscapeRight" }
        XCTAssertEqual(tent, "landscapeRight", "a tent")
        fold.send(SimulatorHeldPosture.laptop.steps(from: .outer, angle: 70), to: address)
        _ = try await expect("partiallyOpen", on: inner, "Laptop")
        let laptop = try await verifier.wait(for: "sensors.orientation", bound: .seconds(10)) { $0 == "landscapeLeft" }
        XCTAssertEqual(laptop, "landscapeLeft", "a laptop")
        Self.report("held: tent \(tent ?? "nothing"), laptop \(laptop ?? "nothing")")
        try? await simctl.terminate(udid: udid, bundleIdentifier: IOSVerifierLiveTests.bundle)
    }

    /// The row's token once it has not changed for 0.8 s (at most 15 s).
    private static func settled(_ verifier: VerifierReader, _ id: String) async throws -> String? {
        let deadline = ContinuousClock.now + .seconds(15)
        var last: String?
        var since = ContinuousClock.now
        while ContinuousClock.now < deadline {
            let now = try await verifier.document()?.rows[id]?.raw
            if now != last {
                last = now
                since = ContinuousClock.now
            } else if ContinuousClock.now - since >= .milliseconds(800) {
                return last
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return last
    }

    /// "2007x2853 landscapeRight" → [2007, 2853].
    private static func pixels(_ raw: String) -> [Int]? {
        let size = raw.split(separator: " ").first?.split(separator: "x").compactMap { Int($0) }
        return size?.count == 2 ? size?.sorted() : nil
    }

    private static func report(_ line: String) {
        print("FOLD-VERIFIER-LIVE \(line)")
    }
}
