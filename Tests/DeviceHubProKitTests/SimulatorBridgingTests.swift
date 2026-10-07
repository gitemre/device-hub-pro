import IOSurface
import Synchronization
import XCTest
@testable import DeviceHubProKit

private let testAddress = SimulatorAddress(udid: "00000000-0000-4000-8000-000000000001", deviceSetPath: "/tmp/set")

/// `FakeSimulatorBridge` (what the canvas session and its tests will drive),
/// the Kit's value types, and the mapping of the ObjC bridge's errors.
final class SimulatorBridgingTests: XCTestCase {
    private let address = testAddress
    private let background = DispatchQueue(label: "SimulatorBridgingTests.background")

    /// Runs `body` on a background queue, the way every bridge caller must.
    private func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) throws -> T {
        let result = Mutex<Result<T, any Error>?>(nil)
        let done = expectation(description: "background call")
        background.async {
            let outcome = Result { try body() }
            result.withLock { $0 = outcome }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(result.withLock { $0 }).get()
    }

    private func makeSurface(width: Int = 4, height: Int = 8) throws -> IOSurface {
        try XCTUnwrap(IOSurface(properties: [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .pixelFormat: 0x4247_5241,  // 'BGRA', what CoreSimulator vends
        ]))
    }

    // MARK: - Load

    func testLoadReportsTheConfiguredInfoAndCounts() throws {
        let fake = FakeSimulatorBridge()
        let info = try offMain { try fake.load() }
        XCTAssertEqual(info, SimulatorBridgeLoadInfo(coreSimulatorVersion: "1171.7", simulatorKitLoaded: false))
        _ = try offMain { try fake.load() }
        XCTAssertEqual(fake.loadCount, 2)
        XCTAssertEqual(fake.mainThreadCalls, 0)
    }

    /// The gate runs before anything loads: an untested or disabled
    /// CoreSimulator never reaches `load()`.
    func testLoadIfCompatibleChecksTheGateFirst() throws {
        let fake = FakeSimulatorBridge()
        XCTAssertEqual(try offMain { try fake.loadIfCompatible(installedVersion: "1171.7", environment: [:]) }.coreSimulatorVersion, "1171.7")
        XCTAssertEqual(fake.loadCount, 1)

        for (version, environment) in [("1172.1", [String: String]()), ("1100.1", [:]), ("1171.7", ["DHP_DISABLE_SIMBRIDGE": "1"])] {
            XCTAssertThrowsError(try offMain { try fake.loadIfCompatible(installedVersion: version, environment: environment) }) { error in
                XCTAssertEqual((error as? SimulatorBridgeError)?.kind, .incompatible, version)
            }
        }
        XCTAssertEqual(fake.loadCount, 1, "nothing loaded past a closed gate")

        _ = try offMain { try fake.loadIfCompatible(installedVersion: "1172.1", allowUntested: true, environment: [:]) }
        XCTAssertEqual(fake.loadCount, 2, "the user's opt-in opens an untested build")
    }

    func testALoadFailureIsThrown() {
        var configuration = FakeSimulatorBridge.Configuration()
        configuration.loadError = SimulatorBridgeError(.apiUnavailable, "SimServiceContext is missing")
        let fake = FakeSimulatorBridge(configuration)
        XCTAssertThrowsError(try offMain { try fake.load() }) { error in
            XCTAssertEqual((error as? SimulatorBridgeError)?.kind, .apiUnavailable)
        }
    }

    // MARK: - Screen

    func testStartDeliversTheCurrentSurfaceThenFramesUntilStopped() throws {
        var configuration = FakeSimulatorBridge.Configuration()
        let surface = SimulatorSurface(try makeSurface())
        configuration.surface = surface
        let fake = FakeSimulatorBridge(configuration)
        let events = Mutex<[SimulatorScreenEvent]>([])

        let screen = try offMain { try fake.makeScreen(for: testAddress) }
        XCTAssertEqual(screen.initialProperties.screenType, 0)
        XCTAssertFalse(screen.isStarted)
        try offMain { try screen.start { event in events.withLock { $0.append(event) } } }
        XCTAssertTrue(screen.isStarted)
        XCTAssertEqual(events.withLock { $0 }, [.surfaceChanged(surface)], "the current surface arrives right after registering")

        let fakeScreen = try XCTUnwrap(fake.screens.first)
        XCTAssertEqual(fakeScreen.address, address)
        fakeScreen.emit(.frame)
        fakeScreen.emit(.frame)
        let rotated = SimulatorScreenProperties(screenType: 0, screenID: 1, uiOrientation: 3, pixelWidth: 1206, pixelHeight: 2622)
        fakeScreen.emit(.propertiesChanged(rotated))
        try offMain { screen.stop() }
        fakeScreen.emit(.frame)

        XCTAssertEqual(events.withLock { $0 }, [.surfaceChanged(surface), .frame, .frame, .propertiesChanged(rotated)])
        XCTAssertEqual(fakeScreen.registerCount, 1)
        XCTAssertEqual(fakeScreen.unregisterCount, 1)
        try offMain { screen.stop() }
        XCTAssertEqual(fakeScreen.unregisterCount, 1, "stop is idempotent")
    }

    /// Every event reaches the handler on the screen's own queue, the first
    /// surface after `start` included, whichever queue started or emitted.
    func testTheHandlerRunsOnTheScreensOwnQueue() throws {
        var configuration = FakeSimulatorBridge.Configuration()
        configuration.surface = SimulatorSurface(try makeSurface())
        let fake = FakeSimulatorBridge(configuration)
        let screen = try offMain { try fake.makeScreen(for: testAddress) }
        let fakeScreen = try XCTUnwrap(fake.screens.first)
        let labels = Mutex<[String]>([])
        try offMain {
            try screen.start { _ in
                let label = String(cString: __dispatch_queue_get_label(nil))
                labels.withLock { $0.append(label) }
            }
        }
        fakeScreen.emit(.frame)
        try offMain { fakeScreen.emit(.frame) }
        XCTAssertEqual(labels.withLock { $0 }, Array(repeating: fakeScreen.callbackQueue.label, count: 3))
    }

    func testANilSurfaceMeansTheDeviceWentAway() throws {
        var configuration = FakeSimulatorBridge.Configuration()
        configuration.surface = SimulatorSurface(try makeSurface())
        let fake = FakeSimulatorBridge(configuration)
        let screen = try offMain { try fake.makeScreen(for: testAddress) }
        let last = Mutex<SimulatorScreenEvent?>(nil)
        try offMain { try screen.start { event in last.withLock { $0 = event } } }
        try XCTUnwrap(fake.screens.first).emit(.surfaceChanged(nil))
        XCTAssertEqual(last.withLock { $0 }, .surfaceChanged(nil))
        XCTAssertThrowsError(try offMain { try screen.currentSurface() }) { error in
            XCTAssertEqual((error as? SimulatorBridgeError)?.kind, .screenNotFound)
        }
    }

    func testStartingTwiceFails() throws {
        let fake = FakeSimulatorBridge()
        let screen = try offMain { try fake.makeScreen(for: testAddress) }
        try offMain { try screen.start { _ in } }
        XCTAssertThrowsError(try offMain { try screen.start { _ in } }) { error in
            XCTAssertEqual((error as? SimulatorBridgeError)?.kind, .invalidArgument)
        }
        XCTAssertEqual(try XCTUnwrap(fake.screens.first).registerCount, 1)
    }

    func testAScreenFailureIsThrown() {
        var configuration = FakeSimulatorBridge.Configuration()
        configuration.screenError = SimulatorBridgeError(.deviceNotBooted, "simulator is Shutdown, not booted")
        let fake = FakeSimulatorBridge(configuration)
        XCTAssertThrowsError(try offMain { try fake.makeScreen(for: testAddress) }) { error in
            XCTAssertEqual((error as? SimulatorBridgeError)?.kind, .deviceNotBooted)
        }
        XCTAssertTrue(fake.screens.isEmpty)
    }

    // MARK: - Input

    func testInputConnectsLazilyOnTheFirstSend() throws {
        let fake = FakeSimulatorBridge()
        let input = try offMain { fake.makeInput(for: testAddress) }
        let fakeInput = try XCTUnwrap(fake.inputs.first)
        XCTAssertFalse(input.isConnected, "creating the channel connects nothing (dtuhidd.active stays 0)")
        XCTAssertEqual(fakeInput.connectAttempts, 0)
        XCTAssertNil(input.lastConnectReport)

        try offMain {
            try input.send(.touch(x: 0.5, y: 0.7, phase: .began))
            try input.send(.touch(x: 0.5, y: 0.3, phase: .moved))
            try input.send(.touch(x: 0.5, y: 0.3, phase: .ended))
            try input.send(.button(.home, isDown: true))
            try input.send(.button(.home, isDown: false))
        }
        XCTAssertTrue(input.isConnected)
        XCTAssertEqual(fakeInput.connectAttempts, 1, "one connection for the whole gesture")
        XCTAssertEqual(input.lastConnectReport?.attempts, 1)
        XCTAssertEqual(fakeInput.sent, [
            .touch(x: 0.5, y: 0.7, phase: .began),
            .touch(x: 0.5, y: 0.3, phase: .moved),
            .touch(x: 0.5, y: 0.3, phase: .ended),
            .button(.home, isDown: true),
            .button(.home, isDown: false),
        ])
    }

    func testAFailedConnectLeavesTheNextSendToRetry() throws {
        var configuration = FakeSimulatorBridge.Configuration()
        configuration.failingConnects = 1
        let fake = FakeSimulatorBridge(configuration)
        let input = try offMain { fake.makeInput(for: testAddress) }
        XCTAssertThrowsError(try offMain { try input.send(.key(usage: 0x04, isDown: true)) }) { error in
            XCTAssertEqual((error as? SimulatorBridgeError)?.kind, .hidUnresponsive)
        }
        XCTAssertFalse(input.isConnected)
        try offMain { try input.send(.key(usage: 0x04, isDown: true)) }
        XCTAssertTrue(input.isConnected)
        let fakeInput = try XCTUnwrap(fake.inputs.first)
        XCTAssertEqual(fakeInput.connectAttempts, 2)
        XCTAssertEqual(fakeInput.sent, [.key(usage: 0x04, isDown: true)], "the failed send delivered nothing")
    }

    func testDisconnectMakesTheNextSendReconnect() throws {
        let fake = FakeSimulatorBridge()
        let input = try offMain { fake.makeInput(for: testAddress) }
        _ = try offMain { try input.connect() }
        try offMain { input.disconnect() }
        XCTAssertFalse(input.isConnected)
        try offMain { try input.send(.button(.home, isDown: true)) }
        XCTAssertEqual(try XCTUnwrap(fake.inputs.first).connectAttempts, 2)
    }

    func testAnOutOfRangeTouchIsRejectedWithoutConnecting() throws {
        let fake = FakeSimulatorBridge()
        let input = try offMain { fake.makeInput(for: testAddress) }
        XCTAssertThrowsError(try offMain { try input.send(.touch(x: 1.2, y: 0.5, phase: .began)) }) { error in
            XCTAssertEqual((error as? SimulatorBridgeError)?.kind, .invalidArgument)
        }
        XCTAssertEqual(try XCTUnwrap(fake.inputs.first).connectAttempts, 0)
    }

    /// The fake counts main-thread calls, so a controller's threading can be
    /// asserted without the live bridge's crash on a violation.
    func testMainThreadCallsAreCounted() throws {
        let fake = FakeSimulatorBridge()
        _ = try fake.load()
        let screen = try fake.makeScreen(for: address)
        try screen.start { _ in }
        _ = try offMain { try fake.load() }
        XCTAssertEqual(fake.mainThreadCalls, 3)
    }

    // MARK: - Values

    func testTheWireValuesMatchDtuhidd() {
        XCTAssertEqual(SimulatorTouchPhase.began.rawValue, 0)
        XCTAssertEqual(SimulatorTouchPhase.moved.rawValue, 1)
        XCTAssertEqual(SimulatorTouchPhase.ended.rawValue, 2)
        XCTAssertEqual(SimulatorHardwareButton.home.usagePage, 0x0C)
        XCTAssertEqual(SimulatorHardwareButton.home.usage, 0x40)
    }

    func testASurfaceReportsItsGeometryAndComparesByIdentity() throws {
        let raw = try makeSurface(width: 6, height: 10)
        let surface = SimulatorSurface(raw)
        XCTAssertEqual(surface.width, 6)
        XCTAssertEqual(surface.height, 10)
        XCTAssertEqual(surface.pixelFormat, 0x4247_5241)
        XCTAssertGreaterThanOrEqual(surface.bytesPerRow, 24)
        XCTAssertNotEqual(surface.surfaceID, 0)
        XCTAssertEqual(surface, SimulatorSurface(raw))
        XCTAssertNotEqual(surface, SimulatorSurface(try makeSurface(width: 6, height: 10)))

        let seed = surface.seed
        raw.lock(options: [], seed: nil)
        raw.unlock(options: [], seed: nil)
        XCTAssertNotEqual(surface.seed, seed, "a write lock bumps the seed the copy check reads")
    }

    func testAnAddressDescribesItsSet() {
        XCTAssertEqual(SimulatorAddress(udid: "A").description, "A")
        XCTAssertEqual(SimulatorAddress(udid: "A", deviceSetPath: "/s").description, "A in /s")
    }

    func testTheDeveloperDirComesFromTheEnvironmentThenTheSelectLink() throws {
        XCTAssertEqual(
            LiveSimulatorBridge.defaultDeveloperDir(environment: ["DEVELOPER_DIR": "/X.app/Contents/Developer"], selectLink: "/nonexistent"),
            "/X.app/Contents/Developer"
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devdir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("xcode_select_link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/Y.app/Contents/Developer")
        XCTAssertEqual(LiveSimulatorBridge.defaultDeveloperDir(environment: [:], selectLink: link), "/Y.app/Contents/Developer")
        XCTAssertEqual(
            LiveSimulatorBridge.defaultDeveloperDir(environment: ["DEVELOPER_DIR": ""], selectLink: "/nonexistent"),
            "/Applications/Xcode.app/Contents/Developer"
        )
    }

    // MARK: - Error mapping

    /// The ObjC bridge's error domain and codes are part of its contract
    /// (DeviceHubProSimBridge.h); the Kit maps them to its own kinds.
    func testBridgeErrorsMapToKinds() {
        let expected: [(Int, SimulatorBridgeError.Kind)] = [
            (1, .loadFailed), (2, .apiUnavailable), (3, .exception), (4, .deviceNotFound), (5, .deviceNotBooted),
            (6, .screenNotFound), (7, .serviceLookupFailed), (8, .hidUnresponsive), (9, .invalidArgument),
            (10, .timedOut), (11, .cancelled), (99, .unknown),
        ]
        for (code, kind) in expected {
            let error = NSError(domain: "com.devicehubpro.SimBridge", code: code, userInfo: [NSLocalizedDescriptionKey: "code \(code)"])
            XCTAssertEqual(SimulatorBridgeError(bridging: error).kind, kind, "code \(code)")
        }
    }

    func testAnExceptionKeepsItsNameAndTheUnderlyingError() {
        let underlying = NSError(domain: "com.apple.CoreSimulator.SimError", code: 405, userInfo: [NSLocalizedDescriptionKey: "no such service"])
        let error = NSError(domain: "com.devicehubpro.SimBridge", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "framebufferSurface raised NSInvalidArgumentException: unrecognized selector",
            "AQSBExceptionName": "NSInvalidArgumentException",
            NSUnderlyingErrorKey: underlying,
        ])
        let mapped = SimulatorBridgeError(bridging: error)
        XCTAssertEqual(mapped.kind, .exception)
        XCTAssertEqual(mapped.exceptionName, "NSInvalidArgumentException")
        XCTAssertTrue(mapped.message.contains("com.apple.CoreSimulator.SimError 405"), mapped.message)

        let foreign = SimulatorBridgeError(bridging: CocoaError(.fileNoSuchFile))
        XCTAssertEqual(foreign.kind, .unknown)
    }
}
