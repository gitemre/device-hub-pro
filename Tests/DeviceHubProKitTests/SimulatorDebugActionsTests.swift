import XCTest
@testable import DeviceHubProKit

/// Slow Animations and Simulate Memory Warning (`SimulatorDebugActions`) on a
/// fake simctl and a temporary device folder. The `notifyutil -g` answer
/// below is what the real command printed on an iOS 27.0 simulator
/// (CoreSimulator 1171.7, 2026-10-04); the live round trips against the
/// verifier are `IOSVerifierLiveTests.testSimctlRoundTripsOnAPrivateSetSimulator`.
final class SimulatorDebugActionsTests: XCTestCase {
    private static let udid = "5B59FD8E-4FE5-41B6-9B4F-0892086D6781"
    private static let name = "com.apple.UIKit.SimulatorSlowMotionAnimationState"

    private func client(_ fake: FakeTool) -> SimctlClient {
        SimctlClient(simctlURL: fake.executableURL, deviceSet: URL(fileURLWithPath: "/tmp/set"))
    }

    func testSlowAnimationsSetTheStateAndPostInOneSpawn() async throws {
        let fake = try FakeTool(name: "simctl", rules: [])
        try await client(fake).setSlowAnimations(udid: Self.udid, enabled: true)
        try await client(fake).setSlowAnimations(udid: Self.udid, enabled: false)
        XCTAssertEqual(fake.invocations, [
            ["--set", "/tmp/set", "spawn", Self.udid, "notifyutil", "-s", Self.name, "1", "-p", Self.name],
            ["--set", "/tmp/set", "spawn", Self.udid, "notifyutil", "-s", Self.name, "0", "-p", Self.name],
        ])
    }

    func testSlowAnimationsReadTheState() async throws {
        let off = try FakeTool(name: "simctl", rules: [.init("notifyutil -g", output: "\(Self.name) 0\n")])
        let isOff = try await client(off).slowAnimationsEnabled(udid: Self.udid)
        XCTAssertFalse(isOff)
        XCTAssertEqual(off.invocations, [["--set", "/tmp/set", "spawn", Self.udid, "notifyutil", "-g", Self.name]])
        let on = try FakeTool(name: "simctl", rules: [.init("notifyutil -g", output: "\(Self.name) 1\n")])
        let isOn = try await client(on).slowAnimationsEnabled(udid: Self.udid)
        XCTAssertTrue(isOn)
    }

    func testSlowAnimationsRefuseAnythingButAUDID() async throws {
        let fake = try FakeTool(name: "simctl", rules: [])
        do {
            try await client(fake).setSlowAnimations(udid: "booted", enabled: true)
            XCTFail("a simulator is always named by its UDID")
        } catch {}
        XCTAssertEqual(fake.invocations, [])
    }

    func testMemoryWarningBumpsTheFilesModificationTime() throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("aq-memwarn-\(UUID().uuidString)", isDirectory: true)
        let run = data.appendingPathComponent("var/run", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: data) }
        let file = SimulatorDebugActions.memoryWarningFile(dataDirectory: data)
        XCTAssertEqual(file.path, run.appendingPathComponent("memory_warning_simulation").path)
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try SimulatorDebugActions.simulateMemoryWarning(dataDirectory: data, now: now)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(attributes[.size] as? Int, 0, "the file's contents are never written")
    }

    /// A device that never booted has no file, and the action does not make
    /// one (a new file would not be watched).
    func testMemoryWarningNeedsABootedDevice() throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("aq-memwarn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: data) }
        XCTAssertThrowsError(try SimulatorDebugActions.simulateMemoryWarning(dataDirectory: data)) { error in
            XCTAssertEqual(error as? SimulatorDebugActions.MemoryWarningError, .notBooted("memory_warning_simulation"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: SimulatorDebugActions.memoryWarningFile(dataDirectory: data).path))
    }
}
