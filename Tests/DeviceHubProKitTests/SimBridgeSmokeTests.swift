import Foundation
import IOSurface
import Synchronization
import XCTest
@testable import DeviceHubProKit

/// Live checks of the private simulator bridge inside this test process: the
/// in-process twin of `DeviceHubProSimBridgeSmoke` (Scripts/ios-bridge-smoke.sh).
///
/// PRIVATE-API CoreSimulator 1171.7. Verified with Xcode 27.0 (27A266a), the
/// iOS 27.0 (24A434) runtime and an iPhone 17 Pro; the simulator inherits the
/// host's tr_TR locale and Europe/Istanbul time zone, which only changes the
/// text on screen (no check reads text).
///
/// Opt-in: `DHP_IOS_LIVE=1`. The test then creates an iPhone 17 Pro in a
/// private device set under `$TMPDIR/devicehubpro-live-sims/<run>` (never the
/// default set, never `booted`), boots it, and deletes it afterwards together
/// with the log folder CoreSimulator leaves in `~/Library/Logs/CoreSimulator`.
/// `DHP_SIM_UDID` (plus `DHP_SIM_SET` for a private set) names an
/// already booted simulator to use instead. The test does not delete that
/// one, but it changes it: Settings is launched and left on a sub-page,
/// Safari opens https://example.com, Home is pressed, and connecting sets
/// `com.apple.coredevice.dtuhidd.active` to 1 until the simulator reboots,
/// which cuts legacy-Indigo input clients (older idb and other tools)
/// off from it. Name only a simulator nobody else is using. Its
/// "dtuhidd not active before input" check is only reported, since an
/// earlier run may have connected already.
///
/// Every bridge call runs on one serial queue; the bridge stops the process
/// on a main-queue call, so a green run also proves there was none.
final class SimBridgeSmokeTests: XCTestCase {
    private let session = DispatchQueue(label: "SimBridgeSmokeTests.session", qos: .userInitiated)

    private func onSession<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            session.async { continuation.resume(with: Result { try body() }) }
        }
    }

    private func requireLive() throws {
        guard ProcessInfo.processInfo.environment["DHP_IOS_LIVE"] == "1" else {
            throw XCTSkip("set DHP_IOS_LIVE=1 to run the live simulator-bridge checks")
        }
        let installed = BridgeCompatibility.installedCoreSimulatorVersion()
        let verdict = BridgeCompatibility.verdict(coreSimulatorVersion: installed)
        guard verdict.allowsBridge else {
            throw XCTSkip("the bridge is off on CoreSimulator \(installed ?? "?"): \(verdict)")
        }
    }

    func testTheBridgeStreamsAndDrivesALiveSimulator() async throws {
        try requireLive()
        let simulator = try LiveSimulator.provide()
        addTeardownBlock { simulator.cleanUp() }
        let address = simulator.address
        let bridge = LiveSimulatorBridge()
        let before = LiveSimulatorBridge.diagnostics

        let info = try await onSession { try bridge.load() }
        XCTAssertEqual(info.coreSimulatorVersion, BridgeCompatibility.installedCoreSimulatorVersion())
        XCTAssertFalse(info.simulatorKitLoaded, "the bridge must not need SimulatorKit")

        if simulator.createdHere {
            do {
                _ = try await onSession { try bridge.makeScreen(for: address) }
                XCTFail("a shut-down simulator has no screen to stream")
            } catch let error as SimulatorBridgeError {
                XCTAssertEqual(error.kind, .deviceNotBooted, error.message)
            }
            try simulator.boot()
        }

        // The screen: class-0 display, current surface right after registering.
        let screen = try await onSession { try bridge.makeScreen(for: address) }
        XCTAssertEqual(screen.initialProperties.screenType, 0)
        XCTAssertGreaterThan(screen.initialProperties.pixelWidth, 0)
        let input = try await onSession { bridge.makeInput(for: address) }
        XCTAssertFalse(input.isConnected, "nothing connects before the first input")

        let recorder = FrameRecorder()
        try await onSession { try screen.start { event in recorder.handle(event) } }
        let surface = try XCTUnwrap(recorder.waitForSurface(timeout: 3), "surfacesChanged fires right after registering")
        XCTAssertEqual(surface.pixelFormat, 0x4247_5241, "BGRA")
        XCTAssertEqual(surface.width, screen.initialProperties.pixelWidth)
        XCTAssertEqual(surface.height, screen.initialProperties.pixelHeight)

        // Animate the screen and wait for the first presented frame.
        try simulator.simctl(["launch", simulator.udid, "com.apple.Preferences"])
        XCTAssertTrue(recorder.waitForFrames(atLeast: 1, timeout: 15), "a frame after launching Settings")
        try await Task.sleep(for: .seconds(2))
        recorder.waitForIdle(quiet: 0.8, timeout: 15)

        let activeBefore = try simulator.dtuhiddActive()
        if simulator.createdHere {
            XCTAssertEqual(activeBefore, "0", "dtuhidd.active before the first input")
        }

        // Drag: the first send opens the connection.
        let dragFrames = recorder.frameCount
        let dragStart = Date()
        try await onSession {
            for gesture in 0..<6 {
                let (from, to) = gesture.isMultiple(of: 2) ? (0.7, 0.3) : (0.3, 0.7)
                try input.send(.touch(x: 0.5, y: from, phase: .began))
                for step in 1...15 {
                    try input.send(.touch(x: 0.5, y: from + (to - from) * Double(step) / 15, phase: .moved))
                    Thread.sleep(forTimeInterval: 0.016)
                }
                try input.send(.touch(x: 0.5, y: to, phase: .ended))
            }
        }
        let dragSeconds = Date().timeIntervalSince(dragStart)
        XCTAssertTrue(input.isConnected)
        let report = try XCTUnwrap(input.lastConnectReport)
        XCTAssertGreaterThanOrEqual(report.attempts, 1)
        let dragged = recorder.frameCount - dragFrames
        XCTAssertGreaterThan(dragged, 10, "frames while dragging")
        print(String(format: "SimBridgeSmokeTests: %d frames in %.1f s while dragging (%.1f fps); dtuhidd connect %@",
                     dragged, dragSeconds, Double(dragged) / dragSeconds, "\(report)"))

        let activeAfter = try simulator.dtuhiddActive()
        XCTAssertEqual(activeAfter, "1", "connecting marks dtuhidd active for the rest of the boot")
        print("SimBridgeSmokeTests: dtuhidd.active before=\(activeBefore) after=\(activeAfter)")

        // A tap on a Settings row navigates: a frame within a second, a new
        // seed, and more change than a status-bar clock tick (which also
        // moves the seed) could make.
        recorder.waitForIdle(quiet: 1.0, timeout: 15)
        let beforeTap = PixelSample(surface)
        let seed = surface.seed
        let tapFrames = recorder.frameCount
        try await onSession {
            try input.send(.touch(x: 0.5, y: 0.62, phase: .began))
            Thread.sleep(forTimeInterval: 0.06)
            try input.send(.touch(x: 0.5, y: 0.62, phase: .ended))
        }
        XCTAssertTrue(recorder.waitForFrames(atLeast: tapFrames + 1, timeout: 1), "a frame within 1 s of the tap")
        recorder.waitForIdle(quiet: 0.5, timeout: 5)
        XCTAssertNotEqual(surface.seed, seed, "the tap changed the IOSurface seed")
        let tapChanged = beforeTap.differingShare(PixelSample(surface))
        XCTAssertGreaterThan(tapChanged, 0.02, "the tap opened a settings page")
        print(String(format: "SimBridgeSmokeTests: the tap changed %.1f%% of the sampled pixels", tapChanged * 100))

        // Home: from Safari back to the home screen.
        try simulator.simctl(["openurl", simulator.udid, "https://example.com"])
        try await Task.sleep(for: .seconds(4))
        recorder.waitForIdle(quiet: 1.0, timeout: 20)
        let beforeHome = PixelSample(surface)
        let homeFrames = recorder.frameCount
        try await onSession {
            try input.send(.button(.home, isDown: true))
            Thread.sleep(forTimeInterval: 0.08)
            try input.send(.button(.home, isDown: false))
            try input.flush(timeout: .seconds(2))
        }
        XCTAssertTrue(recorder.waitForFrames(atLeast: homeFrames + 1, timeout: 5), "frames after Home")
        try await Task.sleep(for: .seconds(1))
        recorder.waitForIdle(quiet: 0.8, timeout: 10)
        let changed = beforeHome.differingShare(PixelSample(surface))
        XCTAssertGreaterThan(changed, 0.2, "Home replaced the screen")

        // While a connect runs, the getters answer at once (the main thread
        // included), and a disconnect from another queue cancels it. The
        // connect after a disconnect resolves the device, waits for the
        // barrier and then the 0.2 s reply tail, so it is still running when
        // one of the repeated disconnects below lands.
        try await onSession { input.disconnect() }
        let mainRead = await MainActor.run { (input.isConnected, screen.isStarted) }
        XCTAssertFalse(mainRead.0)
        XCTAssertTrue(mainRead.1)
        let outcome = Outcome<Result<SimulatorHIDConnectReport, SimulatorBridgeError>>()
        session.async {
            do {
                outcome.set(.success(try input.connect()))
            } catch let error as SimulatorBridgeError {
                outcome.set(.failure(error))
            } catch {
                outcome.set(.failure(SimulatorBridgeError(.unknown, "\(error)")))
            }
        }
        let (slowestGetterMs, disconnects) = await withCheckedContinuation { (continuation: CheckedContinuation<(Double, Int), Never>) in
            DispatchQueue(label: "SimBridgeSmokeTests.other").async {
                var slowest = 0.0
                var disconnects = 0
                let deadline = Date().addingTimeInterval(45)
                while outcome.value == nil && Date() < deadline {
                    let start = DispatchTime.now().uptimeNanoseconds
                    _ = input.isConnected
                    _ = input.lastConnectReport
                    slowest = max(slowest, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                    input.disconnect()
                    disconnects += 1
                    Thread.sleep(forTimeInterval: 0.02)
                }
                continuation.resume(returning: (slowest, disconnects))
            }
        }
        switch try XCTUnwrap(outcome.value, "the connect returned") {
        case .success(let report):
            XCTFail("a disconnect should have cancelled the connect; it connected: \(report)")
        case .failure(let error):
            XCTAssertEqual(error.kind, .cancelled, error.message)
        }
        XCTAssertFalse(input.isConnected)
        XCTAssertLessThan(slowestGetterMs, 100, "the getters do not wait for the connect")
        print(String(format: "SimBridgeSmokeTests: connect cancelled after %d disconnect(s); slowest getter read %.2f ms",
                     disconnects, slowestGetterMs))

        try await onSession {
            screen.stop()
            input.disconnect()
        }
        let after = LiveSimulatorBridge.diagnostics
        XCTAssertEqual(after.screenRegistrations - before.screenRegistrations, 1)
        XCTAssertEqual(after.screenUnregistrations - before.screenUnregistrations, 1)
        XCTAssertEqual(after.exceptions, before.exceptions, "no NSException from Apple's code")
        XCTAssertGreaterThan(after.entryPoints, before.entryPoints)
        XCTAssertFalse(after.simulatorKitLoaded)
        XCTAssertEqual(recorder.callbacksOnMain, 0, "screen callbacks run on the bridge's queue")
    }

    func testAnUnknownUDIDIsDeviceNotFound() async throws {
        try requireLive()
        let set = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-live-sims/empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: set)
            LiveSimulator.removeParentIfEmpty(of: set.path)
        }
        let bridge = LiveSimulatorBridge()
        let address = SimulatorAddress(udid: UUID().uuidString, deviceSetPath: set.path)
        do {
            _ = try await onSession { try bridge.makeScreen(for: address) }
            XCTFail("an empty set has no such simulator")
        } catch let error as SimulatorBridgeError {
            XCTAssertEqual(error.kind, .deviceNotFound, error.message)
        }
        // Input stays lazy: the failure shows only when it tries to connect.
        let input = try await onSession { bridge.makeInput(for: address) }
        do {
            try await onSession { try input.send(.button(.home, isDown: true)) }
            XCTFail("no simulator to connect to")
        } catch let error as SimulatorBridgeError {
            XCTAssertEqual(error.kind, .deviceNotFound, error.message)
        }
    }
}

// MARK: - Helpers

/// Frames and surfaces as the bridge reports them.
private final class FrameRecorder: Sendable {
    private struct State {
        var surface: SimulatorSurface?
        var frames: [Date] = []
        var callbacksOnMain = 0
    }

    private let state = Mutex(State())

    func handle(_ event: SimulatorScreenEvent) {
        let onMain = Thread.isMainThread
        state.withLock { state in
            if onMain { state.callbacksOnMain += 1 }
            switch event {
            case .surfaceChanged(let surface): state.surface = surface
            case .frame: state.frames.append(Date())
            case .propertiesChanged: break
            }
        }
    }

    var frameCount: Int { state.withLock { $0.frames.count } }
    var callbacksOnMain: Int { state.withLock { $0.callbacksOnMain } }

    func waitForSurface(timeout: TimeInterval) -> SimulatorSurface? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let surface = state.withLock({ $0.surface }) { return surface }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return state.withLock { $0.surface }
    }

    func waitForFrames(atLeast count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if frameCount >= count { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return frameCount >= count
    }

    func waitForIdle(quiet: TimeInterval, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let last = state.withLock({ $0.frames.last }) else { return }
            if Date().timeIntervalSince(last) >= quiet { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

/// A coarse grid of BGRA samples read straight from the surface.
private struct PixelSample {
    let values: [UInt8]

    init(_ surface: SimulatorSurface) {
        let raw = surface.surface
        raw.lock(options: .readOnly, seed: nil)
        defer { raw.unlock(options: .readOnly, seed: nil) }
        let base = raw.baseAddress.assumingMemoryBound(to: UInt8.self)
        var values: [UInt8] = []
        for row in stride(from: 0, to: raw.height, by: max(1, raw.height / 80)) {
            for column in stride(from: 0, to: raw.width, by: max(1, raw.width / 40)) {
                let offset = row * raw.bytesPerRow + column * 4
                values.append(contentsOf: [base[offset], base[offset + 1], base[offset + 2]])
            }
        }
        self.values = values
    }

    func differingShare(_ other: PixelSample) -> Double {
        guard values.count == other.values.count, !values.isEmpty else { return 0 }
        var differing = 0
        for index in stride(from: 0, to: values.count, by: 3) {
            let delta = (0..<3).reduce(0) { $0 + abs(Int(values[index + $1]) - Int(other.values[index + $1])) }
            if delta > 48 { differing += 1 }
        }
        return Double(differing) / Double(values.count / 3)
    }
}

/// One simulator for the live test: created in a private set (and deleted
/// afterwards), or named by DHP_SIM_UDID.
private final class LiveSimulator: Sendable {
    let udid: String
    let setPath: String?
    let createdHere: Bool
    private let simctlPath: String
    private let environment: [String: String]

    var address: SimulatorAddress { SimulatorAddress(udid: udid, deviceSetPath: setPath) }

    private init(udid: String, setPath: String?, createdHere: Bool, simctlPath: String, environment: [String: String]) {
        self.udid = udid
        self.setPath = setPath
        self.createdHere = createdHere
        self.simctlPath = simctlPath
        self.environment = environment
    }

    static func provide() throws -> LiveSimulator {
        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = LiveSimulatorBridge.defaultDeveloperDir()
        // The real binary, not the xcrun wrapper that may run -runFirstLaunch.
        let real = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl"
        guard FileManager.default.isExecutableFile(atPath: real) else { throw XCTSkip("no simctl at \(real)") }

        if let named = environment["DHP_SIM_UDID"], !named.isEmpty {
            let set = environment["DHP_SIM_SET"].flatMap { $0.isEmpty ? nil : $0 }
            return LiveSimulator(udid: named, setPath: set, createdHere: false, simctlPath: real, environment: environment)
        }
        let set = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-live-sims/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        let created = run(real, ["--set", set.path, "create", "DeviceHubPro-SimBridgeSmokeTests",
                                 "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                                 "com.apple.CoreSimulator.SimRuntime.iOS-27-0"], environment: environment, timeout: 60)
        let udid = created.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard created.status == 0, UUID(uuidString: udid) != nil else {
            try? FileManager.default.removeItem(at: set)
            throw XCTSkip("cannot create an iPhone 17 Pro on iOS 27.0 here: \(created.output)")
        }
        return LiveSimulator(udid: udid, setPath: set.path, createdHere: true, simctlPath: real, environment: environment)
    }

    @discardableResult
    func simctl(_ arguments: [String], timeout: TimeInterval = 120) throws -> String {
        let result = Self.run(simctlPath, (setPath.map { ["--set", $0] } ?? []) + arguments, environment: environment, timeout: timeout)
        guard result.status == 0 else {
            throw SimulatorBridgeError(.unknown, "simctl \(arguments.joined(separator: " ")) failed (\(result.status)): \(result.output)")
        }
        return result.output
    }

    /// Boots and waits for the boot to finish, then lets SpringBoard settle.
    func boot() throws {
        try simctl(["bootstatus", udid, "-b"], timeout: 240)
        Thread.sleep(forTimeInterval: 10)
    }

    func dtuhiddActive() throws -> String {
        let output = try simctl(["spawn", udid, "notifyutil", "-g", "com.apple.coredevice.dtuhidd.active"], timeout: 30)
        return output.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
    }

    /// Shuts down and deletes a simulator this test created, its set and its
    /// log folder. A named simulator is not shut down or deleted.
    func cleanUp() {
        guard createdHere, let setPath else { return }
        _ = try? simctl(["shutdown", udid], timeout: 60)
        _ = try? simctl(["delete", udid], timeout: 60)
        try? FileManager.default.removeItem(atPath: setPath)
        Self.removeParentIfEmpty(of: setPath)
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CoreSimulator/\(udid)", isDirectory: true)
        try? FileManager.default.removeItem(at: logs)
    }

    /// `devicehubpro-live-sims` goes once no run uses it; rmdir leaves a
    /// directory that another run still fills.
    static func removeParentIfEmpty(of path: String) {
        _ = rmdir((path as NSString).deletingLastPathComponent)
    }

    /// Runs a command with a deadline. The pipe drains in the background, so
    /// a child that hangs with its output open still times out; on timeout it
    /// gets SIGTERM, then SIGKILL after 2 s.
    private static func run(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let output = PipeOutput()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                output.drained.signal()
            } else {
                output.append(chunk)
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return (-1, "\(error)")
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        // A grandchild that inherited the pipe can hold it open past the
        // exit; take what arrived by then.
        _ = output.drained.wait(timeout: .now() + 2)
        pipe.fileHandleForReading.readabilityHandler = nil
        if timedOut {
            return (-2, "timed out after \(timeout) s: \(output.text)")
        }
        return (process.terminationStatus, output.text)
    }
}

/// A value set once from one queue and polled from another.
private final class Outcome<Value: Sendable>: Sendable {
    private let stored = Mutex<Value?>(nil)

    func set(_ value: Value) { stored.withLock { $0 = value } }
    var value: Value? { stored.withLock { $0 } }
}

/// A child's output, collected while it runs.
private final class PipeOutput: Sendable {
    private let data = Mutex(Data())
    /// Signalled at end of file: every writer closed the pipe.
    let drained = DispatchSemaphore(value: 0)

    func append(_ chunk: Data) { data.withLock { $0.append(chunk) } }
    var text: String { String(decoding: data.withLock { $0 }, as: UTF8.self) }
}
