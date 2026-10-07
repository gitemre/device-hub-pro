internal import DeviceHubProSimBridge
import Foundation
import IOSurface

/// `SimulatorBridging` over the `DeviceHubProSimBridge` ObjC target.
///
/// Every call that reaches CoreSimulator or dtuhidd asserts it is off the
/// main queue (the ObjC side asserts again and stops the process on a
/// violation). Callers own a serial queue per session and make their bridge
/// calls there. The state getters (`isStarted`, `isConnected`,
/// `lastConnectReport`) are the exception: they never wait, not even for a
/// connect in progress, so a status poll may read them anywhere.
public struct LiveSimulatorBridge: SimulatorBridging {
    /// The Xcode developer directory whose CoreSimulator service context the
    /// bridge uses.
    public let developerDir: String

    public init(developerDir: String = LiveSimulatorBridge.defaultDeveloperDir()) {
        self.developerDir = developerDir
    }

    /// `DEVELOPER_DIR`, else the `xcode-select` link, else the standard Xcode path.
    public static func defaultDeveloperDir(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        selectLink: String = "/var/db/xcode_select_link"
    ) -> String {
        if let explicit = environment["DEVELOPER_DIR"], !explicit.isEmpty {
            return explicit
        }
        if let linked = try? FileManager.default.destinationOfSymbolicLink(atPath: selectLink), !linked.isEmpty {
            return linked
        }
        return "/Applications/Xcode.app/Contents/Developer"
    }

    public func load() throws -> SimulatorBridgeLoadInfo {
        dispatchPrecondition(condition: .notOnQueue(.main))
        do {
            try SimBridgeLoader.loadCoreSimulator()
        } catch {
            throw SimulatorBridgeError(bridging: error)
        }
        return SimulatorBridgeLoadInfo(
            coreSimulatorVersion: SimBridgeLoader.loadedCoreSimulatorVersion,
            simulatorKitLoaded: SimBridgeLoader.simulatorKitLoaded
        )
    }

    public func makeScreen(for address: SimulatorAddress) throws -> any SimulatorScreenBridging {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return try LiveSimulatorScreen(address: address, developerDir: developerDir)
    }

    public func makeInput(for address: SimulatorAddress) -> any SimulatorInputBridging {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return LiveSimulatorInput(address: address, developerDir: developerDir)
    }

    public func makeGSEvents(for address: SimulatorAddress) -> any SimulatorGSEventBridging {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return LiveSimulatorGSEvents(address: address, developerDir: developerDir)
    }

    /// The `CFBundleVersion` of the CoreSimulator this process loaded (read
    /// from the loaded framework's bundle, as `load()` reports it), nil
    /// before the first load. Never waits and reaches no service: safe on
    /// any queue. Compared with the installed one
    /// (`BridgeCompatibility.isStale`), it tells an Xcode update that
    /// replaced CoreSimulator under the running app.
    public static var loadedCoreSimulatorVersion: String? {
        SimBridgeLoader.loadedCoreSimulatorVersion
    }

    /// The bridge's process-wide counters, for the smoke tool and tests.
    public static var diagnostics: SimulatorBridgeDiagnostics {
        SimulatorBridgeDiagnostics(
            entryPoints: SimBridgeDiagnostics.entryCount,
            guardedCalls: SimBridgeDiagnostics.guardedCallCount,
            exceptions: SimBridgeDiagnostics.exceptionCount,
            screenRegistrations: SimBridgeDiagnostics.screenRegisterCount,
            screenUnregistrations: SimBridgeDiagnostics.screenUnregisterCount,
            simulatorKitLoaded: SimBridgeLoader.simulatorKitLoaded
        )
    }
}

/// Process-wide bridge counters.
public struct SimulatorBridgeDiagnostics: Sendable, Equatable {
    /// Bridge entry points called; each asserted it was off the main queue.
    public var entryPoints: UInt64
    /// Private calls made inside the exception guard.
    public var guardedCalls: UInt64
    /// NSExceptions the guard caught.
    public var exceptions: UInt64
    public var screenRegistrations: UInt64
    public var screenUnregistrations: UInt64
    /// Whether any SimulatorKit image is mapped (the bridge never loads it).
    public var simulatorKitLoaded: Bool
}

final class LiveSimulatorScreen: SimulatorScreenBridging {
    private let screen: SimBridgeScreen
    /// CoreSimulator delivers every callback here with `dispatch_sync`.
    private let callbackQueue = DispatchQueue(label: "com.devicehubpro.simbridge.screen-callbacks", qos: .userInteractive)
    let initialProperties: SimulatorScreenProperties

    init(address: SimulatorAddress, developerDir: String) throws {
        do {
            screen = try SimBridgeScreen(udid: address.udid, deviceSetPath: address.deviceSetPath, developerDir: developerDir)
        } catch {
            throw SimulatorBridgeError(bridging: error)
        }
        initialProperties = SimulatorScreenProperties(screen.initialProperties)
    }

    /// Never waits; safe on any queue.
    var isStarted: Bool { screen.isStarted }

    func currentSurface() throws -> SimulatorSurface {
        dispatchPrecondition(condition: .notOnQueue(.main))
        do {
            return SimulatorSurface(try screen.currentSurface())
        } catch {
            throw SimulatorBridgeError(bridging: error)
        }
    }

    func currentProperties() throws -> SimulatorScreenProperties {
        dispatchPrecondition(condition: .notOnQueue(.main))
        do {
            return SimulatorScreenProperties(try screen.currentProperties())
        } catch {
            throw SimulatorBridgeError(bridging: error)
        }
    }

    func start(_ handler: @escaping @Sendable (SimulatorScreenEvent) -> Void) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        do {
            try screen.start(
                queue: callbackQueue,
                frameHandler: { handler(.frame) },
                surfaceHandler: { surface in handler(.surfaceChanged(surface.map(SimulatorSurface.init))) },
                propertiesHandler: { properties in handler(.propertiesChanged(SimulatorScreenProperties(properties))) }
            )
        } catch {
            throw SimulatorBridgeError(bridging: error)
        }
    }

    func stop() {
        dispatchPrecondition(condition: .notOnQueue(.main))
        dispatchPrecondition(condition: .notOnQueue(callbackQueue))
        screen.stop()
    }
}

final class LiveSimulatorInput: SimulatorInputBridging {
    private let hid: SimBridgeHID

    init(address: SimulatorAddress, developerDir: String) {
        hid = SimBridgeHID(udid: address.udid, deviceSetPath: address.deviceSetPath, developerDir: developerDir)
    }

    /// Never waits; safe on any queue.
    var isConnected: Bool { hid.isConnected }

    /// Never waits; safe on any queue.
    var lastConnectReport: SimulatorHIDConnectReport? {
        hid.lastConnectReport.map(SimulatorHIDConnectReport.init)
    }

    @discardableResult
    func connect() throws -> SimulatorHIDConnectReport {
        dispatchPrecondition(condition: .notOnQueue(.main))
        do {
            try hid.connect()
        } catch {
            throw SimulatorBridgeError(bridging: error)
        }
        guard let report = lastConnectReport else {
            throw SimulatorBridgeError(.unknown, "connected without a connect report")
        }
        return report
    }

    func send(_ event: SimulatorHIDEvent) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        do {
            switch event {
            case .touch(let x, let y, let phase):
                try hid.sendTouch(x: x, y: y, phase: SimBridgeTouchPhase(phase))
            case .edgeTouch(let x, let y, let phase, let edge):
                try hid.sendTouch(x: x, y: y, phase: SimBridgeTouchPhase(phase), edge: SimBridgeTouchEdge(rawValue: edge.rawValue) ?? .none)
            case .twoFingerTouch(let first, let second, let phase):
                try hid.sendTwoFingerTouch(
                    x: first.x, y: first.y, secondX: second.x, secondY: second.y, phase: SimBridgeTouchPhase(phase)
                )
            case .button(let button, let isDown):
                try hid.sendButton(usagePage: button.usagePage, usage: button.usage, down: isDown)
            case .key(let usage, let isDown):
                try hid.sendKey(usage: usage, down: isDown)
            }
        } catch {
            throw SimulatorBridgeError(bridging: error)
        }
    }

    func flush(timeout: Duration) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        do {
            try hid.flush(timeout: seconds)
        } catch {
            throw SimulatorBridgeError(bridging: error)
        }
    }

    func disconnect() {
        dispatchPrecondition(condition: .notOnQueue(.main))
        hid.disconnect()
    }
}

final class LiveSimulatorGSEvents: SimulatorGSEventBridging {
    private let purple: SimBridgePurple

    init(address: SimulatorAddress, developerDir: String) {
        purple = SimBridgePurple(udid: address.udid, deviceSetPath: address.deviceSetPath, developerDir: developerDir)
    }

    func sendOrientation(_ value: UInt32) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        do {
            try purple.sendOrientation(value)
        } catch {
            throw SimulatorBridgeError(bridging: error)
        }
    }

    func sendLock() throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        do {
            try purple.sendLock()
        } catch {
            throw SimulatorBridgeError(bridging: error)
        }
    }
}

extension SimBridgeTouchPhase {
    init(_ phase: SimulatorTouchPhase) {
        self = SimBridgeTouchPhase(rawValue: phase.rawValue) ?? .ended
    }
}

extension SimulatorScreenProperties {
    init(_ properties: SimBridgeScreenProperties) {
        self.init(
            screenType: properties.screenType,
            screenID: properties.screenID,
            uiOrientation: properties.uiOrientation,
            pixelWidth: Int(properties.pixelSize.width.rounded()),
            pixelHeight: Int(properties.pixelSize.height.rounded())
        )
    }
}

extension SimulatorHIDConnectReport {
    init(_ report: SimBridgeHIDConnectReport) {
        self.init(
            attempts: report.attempts,
            barrierMilliseconds: report.barrierMilliseconds,
            totalMilliseconds: report.totalMilliseconds
        )
    }
}

extension SimulatorBridgeError {
    /// Maps an error thrown by the ObjC bridge; anything outside its domain is `.unknown`.
    public init(bridging error: any Error) {
        let nsError = error as NSError
        guard nsError.domain == SimBridgeError.errorDomain else {
            self.init(.unknown, nsError.localizedDescription)
            return
        }
        let kind: Kind
        switch SimBridgeError.Code(rawValue: nsError.code) {
        case .loadFailed: kind = .loadFailed
        case .apiUnavailable: kind = .apiUnavailable
        case .exception: kind = .exception
        case .deviceNotFound: kind = .deviceNotFound
        case .deviceNotBooted: kind = .deviceNotBooted
        case .screenNotFound: kind = .screenNotFound
        case .serviceLookupFailed: kind = .serviceLookupFailed
        case .hidUnresponsive: kind = .hidUnresponsive
        case .invalidArgument: kind = .invalidArgument
        case .timedOut: kind = .timedOut
        case .cancelled: kind = .cancelled
        case .sendFailed: kind = .sendFailed
        default: kind = .unknown
        }
        var message = nsError.localizedDescription
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            message += " (\(underlying.domain) \(underlying.code): \(underlying.localizedDescription))"
        }
        self.init(kind, message, exceptionName: nsError.userInfo[AQSBExceptionNameKey] as? String)
    }
}
