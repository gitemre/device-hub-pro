import CoreGraphics
import Foundation
import IOSurface
import Synchronization

// The Kit's view of the private simulator bridge: the canvas session talks to
// `SimulatorBridging`, never to `DeviceHubProSimBridge` directly, so every rule
// around it (compatibility gate, fallback, threading) is testable with
// `FakeSimulatorBridge`. `LiveSimulatorBridge` is the real implementation.
//
// Threading: no member may be called on the main queue, except the state
// getters (`isStarted`, `isConnected`, `lastConnectReport`), which never
// wait. A screen's `start` and `stop` must not run from its own handler
// either: hop to the caller's queue first. The live bridge
// asserts that (`dispatchPrecondition`); its calls are synchronous IPC to
// CoreSimulatorService and can take hundreds of milliseconds, and the first
// input can wait up to about 40 s for dtuhidd.

/// A simulator the bridge addresses: its UDID and the device set that holds it.
public struct SimulatorAddress: Sendable, Hashable, CustomStringConvertible {
    public var udid: String
    /// The device set directory, or nil for the default set
    /// (`~/Library/Developer/CoreSimulator/Devices`).
    public var deviceSetPath: String?

    public init(udid: String, deviceSetPath: String? = nil) {
        self.udid = udid
        self.deviceSetPath = deviceSetPath
    }

    public var description: String {
        deviceSetPath.map { "\(udid) in \($0)" } ?? udid
    }
}

/// What loading the bridge found.
public struct SimulatorBridgeLoadInfo: Sendable, Equatable {
    /// `CFBundleVersion` of the CoreSimulator this process loaded.
    public var coreSimulatorVersion: String?
    /// Whether SimulatorKit is mapped into the process. The bridge never loads
    /// it; true means something else in the process did.
    public var simulatorKitLoaded: Bool

    public init(coreSimulatorVersion: String?, simulatorKitLoaded: Bool) {
        self.coreSimulatorVersion = coreSimulatorVersion
        self.simulatorKitLoaded = simulatorKitLoaded
    }
}

/// The main screen's properties.
public struct SimulatorScreenProperties: Sendable, Equatable {
    /// CoreSimulator's screen type; 0 is the device's own panel.
    public var screenType: UInt64
    public var screenID: UInt32
    /// 1 portrait, 2 upside down, 3 and 4 the landscapes. The framebuffer
    /// stays in native portrait whatever this says.
    public var uiOrientation: UInt32
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(screenType: UInt64, screenID: UInt32, uiOrientation: UInt32, pixelWidth: Int, pixelHeight: Int) {
        self.screenType = screenType
        self.screenID = screenID
        self.uiOrientation = uiOrientation
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// The simulator's live framebuffer (32BGRA, native portrait).
///
/// CoreSimulator rewrites this one surface in place for every frame, so a
/// copy can tear: compare `seed` before and after copying and copy again when
/// it moved. Never hand the surface itself to a consumer as a frame.
///
/// `@unchecked Sendable`: an IOSurface is a kernel object with its own
/// locking; readers take its read lock around each copy.
public struct SimulatorSurface: @unchecked Sendable, Equatable {
    public let surface: IOSurface

    public init(_ surface: IOSurface) {
        self.surface = surface
    }

    public var width: Int { surface.width }
    public var height: Int { surface.height }
    public var bytesPerRow: Int { surface.bytesPerRow }
    /// The FourCC pixel format; `'BGRA'` (0x42475241) on Xcode 27.
    public var pixelFormat: OSType { surface.pixelFormat }
    /// Bumped by every write to the surface.
    public var seed: UInt32 { surface.seed }
    /// The kernel's ID for the surface; stable across frames and rotations.
    public var surfaceID: IOSurfaceID { IOSurfaceGetID(unsafeBitCast(surface, to: IOSurfaceRef.self)) }

    public static func == (lhs: SimulatorSurface, rhs: SimulatorSurface) -> Bool {
        lhs.surface === rhs.surface
    }
}

/// What the main screen reports once its callbacks are registered.
public enum SimulatorScreenEvent: Sendable, Equatable {
    /// The framebuffer: right after registering, when it is replaced, and nil
    /// when the device went away (shut down).
    case surfaceChanged(SimulatorSurface?)
    /// A new frame was presented. Nothing arrives while the screen is idle.
    case frame
    /// A screen property changed (rotation).
    case propertiesChanged(SimulatorScreenProperties)
}

public enum SimulatorTouchPhase: UInt64, Sendable {
    case began = 0
    case moved = 1
    case ended = 2
}

/// The screen edge a contact starts at (IndigoHIDEdge), in the panel's native
/// portrait frame.
public enum SimulatorTouchEdge: UInt64, Sendable, CaseIterable {
    case none = 0
    case top = 1
    case left = 2
    case bottom = 3
    case right = 4
}

/// A point on the panel as ratios (0...1) of the native portrait framebuffer.
public struct SimulatorTouchPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A session that presses any hardware button by its HID usage, down and
/// up as separate events: the live simulator canvas
/// (`SimulatorMirrorSession`), for the Apple chrome's buttons.
public protocol SimulatorButtonSending: AnyObject {
    func send(button: SimulatorHardwareButton, isDown: Bool)
    /// Whether the buttons reach the device now: the stage offers the Apple
    /// chrome's buttons only then. The live simulator canvas always does; a
    /// physical iPhone's view does while Control is on.
    var acceptsButtons: Bool { get }
}

extension SimulatorButtonSending {
    public var acceptsButtons: Bool { true }
}

/// A hardware button, sent as its HID usage (`IndigoButtonEvent`).
///
/// The usages come from idb (`SimulatorHIDButtonIdentity.swift`; see the
/// bridge's `PROVENANCE.md`); `SimulatorHardwareActions` documents which
/// ones were seen to work on iOS 27.0.
public enum SimulatorHardwareButton: Sendable, Equatable {
    /// Page 0x0C, usage 0x40 (Menu). Verified on iOS 27.0.
    case home
    /// The side (power / lock) button: page 0x0C, usage 0x30 (Power).
    case side
    /// Page 0x0C, usage 0xE9 (Volume Increment).
    case volumeUp
    /// Page 0x0C, usage 0xEA (Volume Decrement).
    case volumeDown
    /// Page 0x0C, usage 0xCF (Voice Command).
    case siri
    /// Any other button by its HID page and usage (none verified on iOS 27.0).
    case usage(page: UInt32, usage: UInt32)

    /// The button of a HID usage: a named case for the usages above, else
    /// `.usage` (an Apple chrome's Action button is page 0x0B, usage 0x2D).
    public init(usagePage: UInt32, usage: UInt32) {
        switch (usagePage, usage) {
        case (0x0C, 0x40): self = .home
        case (0x0C, 0x30): self = .side
        case (0x0C, 0xE9): self = .volumeUp
        case (0x0C, 0xEA): self = .volumeDown
        case (0x0C, 0xCF): self = .siri
        default: self = .usage(page: usagePage, usage: usage)
        }
    }

    /// The button's HID page and usage as integers (what a physical iPhone's
    /// fast input sends for it).
    public var hidCode: (page: Int, usage: Int) { (Int(usagePage), Int(usage)) }

    public var usagePage: UInt32 {
        switch self {
        case .home, .side, .volumeUp, .volumeDown, .siri: return 0x0C
        case .usage(let page, _): return page
        }
    }

    public var usage: UInt32 {
        switch self {
        case .home: return 0x40
        case .side: return 0x30
        case .volumeUp: return 0xE9
        case .volumeDown: return 0xEA
        case .siri: return 0xCF
        case .usage(_, let usage): return usage
        }
    }
}

public enum SimulatorHIDEvent: Sendable, Equatable {
    /// One digitizer contact; `x` and `y` are ratios (0...1) of the native
    /// portrait framebuffer, whatever the interface orientation.
    case touch(x: Double, y: Double, phase: SimulatorTouchPhase)
    /// One contact tagged with the native edge it started at.
    case edgeTouch(x: Double, y: Double, phase: SimulatorTouchPhase, edge: SimulatorTouchEdge)
    /// Two contacts in one event (`pointOne`, `pointTwo`) sharing one phase.
    case twoFingerTouch(first: SimulatorTouchPoint, second: SimulatorTouchPoint, phase: SimulatorTouchPhase)
    case button(SimulatorHardwareButton, isDown: Bool)
    /// A USB HID keyboard usage (page 7): a key position, not a character.
    case key(usage: UInt32, isDown: Bool)
}

/// How the input connection came up.
public struct SimulatorHIDConnectReport: Sendable, Equatable {
    /// dtuhidd liveness attempts it took (1 when it answered at once).
    public var attempts: Int
    /// Round trip of the barrier that answered.
    public var barrierMilliseconds: Double
    /// From the connect call to a usable connection, retries included.
    public var totalMilliseconds: Double

    public init(attempts: Int, barrierMilliseconds: Double, totalMilliseconds: Double) {
        self.attempts = attempts
        self.barrierMilliseconds = barrierMilliseconds
        self.totalMilliseconds = totalMilliseconds
    }
}

/// A bridge failure in the Kit's own terms.
public struct SimulatorBridgeError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// CoreSimulator could not be loaded.
        case loadFailed
        /// A private class, selector or function is gone: this CoreSimulator
        /// needs a bridge update. The session falls back to view-only.
        case apiUnavailable
        /// Apple's code raised an NSException (the guard caught it).
        case exception
        case deviceNotFound
        case deviceNotBooted
        case screenNotFound
        case serviceLookupFailed
        /// dtuhidd never answered its readiness barrier.
        case hidUnresponsive
        case invalidArgument
        case timedOut
        /// `disconnect()` cancelled the input connect in progress.
        case cancelled
        /// A mach message could not be sent (a kernel error other than a timeout).
        case sendFailed
        /// Refused by `BridgeCompatibility` before anything loaded.
        case incompatible
        case unknown
    }

    public var kind: Kind
    public var message: String
    /// The NSException's name, for `.exception`.
    public var exceptionName: String?

    public init(_ kind: Kind, _ message: String, exceptionName: String? = nil) {
        self.kind = kind
        self.message = message
        self.exceptionName = exceptionName
    }

    public var description: String { message }
}

/// Loads the private simulator bridge and hands out per-simulator screens and
/// input channels. See the file comment for the threading rule.
public protocol SimulatorBridging: Sendable {
    /// Loads CoreSimulator (idempotent). Check `BridgeCompatibility` first.
    func load() throws -> SimulatorBridgeLoadInfo
    /// Resolves the simulator's main screen. It must be booted.
    func makeScreen(for address: SimulatorAddress) throws -> any SimulatorScreenBridging
    /// An input channel for the simulator. Nothing connects until the first
    /// send or `connect()`: connecting marks dtuhidd active for the rest of
    /// the boot, which cuts legacy-Indigo clients off.
    func makeInput(for address: SimulatorAddress) -> any SimulatorInputBridging
    /// The simulator's GSEvent port (rotation, lock). Connectionless: each
    /// send looks the port up, so making one does nothing.
    func makeGSEvents(for address: SimulatorAddress) -> any SimulatorGSEventBridging
}

extension SimulatorBridging {
    /// Loads the bridge only when `BridgeCompatibility` allows
    /// `installedVersion` (by default the installed CoreSimulator, read
    /// without loading it); otherwise throws `.incompatible` and loads nothing.
    public func loadIfCompatible(
        installedVersion: String? = BridgeCompatibility.installedCoreSimulatorVersion(),
        allowUntested: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> SimulatorBridgeLoadInfo {
        let verdict = BridgeCompatibility.verdict(
            coreSimulatorVersion: installedVersion, allowUntested: allowUntested, environment: environment
        )
        guard verdict.allowsBridge else {
            throw SimulatorBridgeError(.incompatible, "the simulator bridge is off on CoreSimulator \(installedVersion ?? "?"): \(verdict)")
        }
        return try load()
    }
}

/// One simulator's main screen.
public protocol SimulatorScreenBridging: AnyObject, Sendable {
    /// The properties read when the screen was resolved.
    var initialProperties: SimulatorScreenProperties { get }
    /// Never waits; safe on any queue.
    var isStarted: Bool { get }
    /// The framebuffer right now, read synchronously.
    func currentSurface() throws -> SimulatorSurface
    /// The properties right now (the interface orientation among them), read
    /// synchronously. `propertiesChanged` reports changes once started.
    func currentProperties() throws -> SimulatorScreenProperties
    /// Registers the callbacks. `handler` runs on the screen's own serial
    /// queue; CoreSimulator waits for it, so it must stay short.
    func start(_ handler: @escaping @Sendable (SimulatorScreenEvent) -> Void) throws
    /// Unregisters. Idempotent, and safe after the device shut down. Never
    /// call it from the handler (the live bridge stops the process): to react
    /// to `.surfaceChanged(nil)`, hop to your own queue and stop from there.
    func stop()
}

/// Input to one simulator.
public protocol SimulatorInputBridging: AnyObject, Sendable {
    /// Never waits, not even for a connect in progress; safe on any queue.
    var isConnected: Bool { get }
    /// Never waits; safe on any queue.
    var lastConnectReport: SimulatorHIDConnectReport? { get }
    /// Connects now if needed (sends connect on their own).
    @discardableResult
    func connect() throws -> SimulatorHIDConnectReport
    /// Sends one event, connecting first when needed.
    func send(_ event: SimulatorHIDEvent) throws
    /// Waits until everything sent so far has left this process.
    func flush(timeout: Duration) throws
    /// Drops the connection; the next send connects again. Called from
    /// another queue while a connect runs, it cancels that connect, which
    /// throws `.cancelled`.
    func disconnect()
}

/// The GSEvents SpringBoard reads from the simulator's `PurpleWorkspacePort`.
/// Each send is one mach message with a send timeout (about 2 s at most).
public protocol SimulatorGSEventBridging: AnyObject, Sendable {
    /// A device-orientation event carrying `value`, 1 through 4
    /// (`SimulatorOrientation.gsEventValue` names them).
    func sendOrientation(_ value: UInt32) throws
    /// A lock-device event.
    func sendLock() throws
}

// MARK: - Test fake

/// A scriptable `SimulatorBridging` for tests: records every call, lets a test
/// emit screen events, and simulates lazy input connection. It also counts
/// calls made on the main thread, so a caller's threading can be asserted
/// without the live bridge's crash-on-violation.
public final class FakeSimulatorBridge: SimulatorBridging {
    public struct Configuration: Sendable {
        public var loadInfo = SimulatorBridgeLoadInfo(coreSimulatorVersion: "1171.7", simulatorKitLoaded: false)
        public var loadError: SimulatorBridgeError?
        public var screenError: SimulatorBridgeError?
        public var properties = SimulatorScreenProperties(
            screenType: 0, screenID: 1, uiOrientation: 1, pixelWidth: 1206, pixelHeight: 2622
        )
        public var surface: SimulatorSurface?
        /// How many connect attempts fail (with `connectError`) before one succeeds.
        public var failingConnects = 0
        public var connectError = SimulatorBridgeError(.hidUnresponsive, "fake: dtuhidd did not answer")
        public var connectReport = SimulatorHIDConnectReport(attempts: 1, barrierMilliseconds: 5, totalMilliseconds: 205)
        /// Thrown by every GSEvent send.
        public var gsEventError: SimulatorBridgeError?

        public init() {}
    }

    private struct State {
        var configuration: Configuration
        var loadCount = 0
        var mainThreadCalls = 0
        var screens: [FakeSimulatorScreen] = []
        var inputs: [FakeSimulatorInput] = []
        var gsEvents: [FakeSimulatorGSEvents] = []
    }

    private let state: Mutex<State>

    public init(_ configuration: Configuration = Configuration()) {
        state = Mutex(State(configuration: configuration))
    }

    public var configuration: Configuration {
        get { state.withLock { $0.configuration } }
        set { state.withLock { $0.configuration = newValue } }
    }

    public var loadCount: Int { state.withLock { $0.loadCount } }
    /// Calls into the fake (and its screens and inputs) made on the main thread.
    public var mainThreadCalls: Int {
        let own = state.withLock { $0.mainThreadCalls }
        return own + screens.reduce(0) { $0 + $1.mainThreadCalls } + inputs.reduce(0) { $0 + $1.mainThreadCalls }
            + gsEvents.reduce(0) { $0 + $1.mainThreadCalls }
    }
    public var screens: [FakeSimulatorScreen] { state.withLock { $0.screens } }
    public var inputs: [FakeSimulatorInput] { state.withLock { $0.inputs } }
    public var gsEvents: [FakeSimulatorGSEvents] { state.withLock { $0.gsEvents } }

    private func noteCall() {
        if Thread.isMainThread { state.withLock { $0.mainThreadCalls += 1 } }
    }

    public func load() throws -> SimulatorBridgeLoadInfo {
        noteCall()
        let configuration = state.withLock { state -> Configuration in
            state.loadCount += 1
            return state.configuration
        }
        if let error = configuration.loadError { throw error }
        return configuration.loadInfo
    }

    public func makeScreen(for address: SimulatorAddress) throws -> any SimulatorScreenBridging {
        noteCall()
        let configuration = self.configuration
        if let error = configuration.screenError { throw error }
        let screen = FakeSimulatorScreen(address: address, properties: configuration.properties, surface: configuration.surface)
        state.withLock { $0.screens.append(screen) }
        return screen
    }

    public func makeInput(for address: SimulatorAddress) -> any SimulatorInputBridging {
        noteCall()
        let configuration = self.configuration
        let input = FakeSimulatorInput(
            address: address,
            failingConnects: configuration.failingConnects,
            connectError: configuration.connectError,
            report: configuration.connectReport
        )
        state.withLock { $0.inputs.append(input) }
        return input
    }

    public func makeGSEvents(for address: SimulatorAddress) -> any SimulatorGSEventBridging {
        noteCall()
        let events = FakeSimulatorGSEvents(address: address, error: configuration.gsEventError)
        state.withLock { $0.gsEvents.append(events) }
        return events
    }
}

/// The fake's screen: `emit` delivers an event to the started handler.
///
/// Like CoreSimulator, it delivers every event with `sync` onto the screen's
/// own serial queue (`callbackQueue`), the first surface after `start`
/// included, and it stops the process when `start` or `stop` runs on that
/// queue. A caller that re-enters the screen from its handler fails here as
/// it would on the live bridge.
public final class FakeSimulatorScreen: SimulatorScreenBridging {
    public let address: SimulatorAddress
    public let initialProperties: SimulatorScreenProperties
    /// The serial queue every handler call runs on.
    public let callbackQueue = DispatchQueue(label: "com.devicehubpro.fake-simulator-screen.callbacks")

    private struct State {
        var surface: SimulatorSurface?
        var properties: SimulatorScreenProperties
        var handler: (@Sendable (SimulatorScreenEvent) -> Void)?
        var propertiesInterceptor: (@Sendable () -> Void)?
        var registerCount = 0
        var unregisterCount = 0
        var mainThreadCalls = 0
    }

    private let state: Mutex<State>

    init(address: SimulatorAddress, properties: SimulatorScreenProperties, surface: SimulatorSurface?) {
        self.address = address
        self.initialProperties = properties
        state = Mutex(State(surface: surface, properties: properties))
    }

    public var isStarted: Bool { state.withLock { $0.handler != nil } }
    public var registerCount: Int { state.withLock { $0.registerCount } }
    public var unregisterCount: Int { state.withLock { $0.unregisterCount } }
    var mainThreadCalls: Int { state.withLock { $0.mainThreadCalls } }

    private func noteCall() {
        if Thread.isMainThread { state.withLock { $0.mainThreadCalls += 1 } }
    }

    public func currentSurface() throws -> SimulatorSurface {
        noteCall()
        guard let surface = state.withLock({ $0.surface }) else {
            throw SimulatorBridgeError(.screenNotFound, "fake: no surface")
        }
        return surface
    }

    public func currentProperties() throws -> SimulatorScreenProperties {
        noteCall()
        let (properties, interceptor) = state.withLock { state in
            defer { state.propertiesInterceptor = nil }
            return (state.properties, state.propertiesInterceptor)
        }
        interceptor?()
        return properties
    }

    /// Runs `body` once, inside the next `currentProperties()`, after the
    /// value is read and before it is returned: an event `body` emits
    /// overtakes the read, like a rotation reported while the IPC reply is
    /// on its way.
    public func interceptNextCurrentProperties(_ body: @escaping @Sendable () -> Void) {
        state.withLock { $0.propertiesInterceptor = body }
    }

    /// Changes what `currentProperties()` reads without telling the handler,
    /// the way a device rotates before its `propertiesChanged` arrives.
    public func setCurrentProperties(_ properties: SimulatorScreenProperties) {
        state.withLock { $0.properties = properties }
    }

    public func start(_ handler: @escaping @Sendable (SimulatorScreenEvent) -> Void) throws {
        noteCall()
        dispatchPrecondition(condition: .notOnQueue(callbackQueue))
        let surface = try state.withLock { state -> SimulatorSurface? in
            guard state.handler == nil else {
                throw SimulatorBridgeError(.invalidArgument, "fake: the screen is already started")
            }
            state.handler = handler
            state.registerCount += 1
            return state.surface
        }
        // Like CoreSimulator: the current surface right after registering.
        callbackQueue.sync { handler(.surfaceChanged(surface)) }
    }

    public func stop() {
        noteCall()
        dispatchPrecondition(condition: .notOnQueue(callbackQueue))
        state.withLock { state in
            guard state.handler != nil else { return }
            state.handler = nil
            state.unregisterCount += 1
        }
    }

    /// Delivers `event` to the handler on `callbackQueue` and returns once it
    /// ran (dropped when not started). A `.surfaceChanged` also becomes the
    /// current surface, a `.propertiesChanged` the current properties.
    public func emit(_ event: SimulatorScreenEvent) {
        let handler = state.withLock { state -> (@Sendable (SimulatorScreenEvent) -> Void)? in
            switch event {
            case .surfaceChanged(let surface): state.surface = surface
            case .propertiesChanged(let properties): state.properties = properties
            case .frame: break
            }
            return state.handler
        }
        guard let handler else { return }
        callbackQueue.sync { handler(event) }
    }
}

/// The fake's input: connects lazily on the first send, like the live one.
public final class FakeSimulatorInput: SimulatorInputBridging {
    public let address: SimulatorAddress

    /// A `flush`: how many events had been sent, and whether the channel
    /// was connected.
    public struct Flush: Sendable, Equatable {
        public var sentCount: Int
        public var connected: Bool
    }

    private struct State {
        var connected = false
        var remainingFailures: Int
        var connectAttempts = 0
        var sent: [SimulatorHIDEvent] = []
        var flushes: [Flush] = []
        var report: SimulatorHIDConnectReport?
        var mainThreadCalls = 0
    }

    private let state: Mutex<State>
    private let connectError: SimulatorBridgeError
    private let report: SimulatorHIDConnectReport

    init(address: SimulatorAddress, failingConnects: Int, connectError: SimulatorBridgeError, report: SimulatorHIDConnectReport) {
        self.address = address
        self.connectError = connectError
        self.report = report
        state = Mutex(State(remainingFailures: failingConnects))
    }

    public var isConnected: Bool { state.withLock { $0.connected } }
    public var lastConnectReport: SimulatorHIDConnectReport? { state.withLock { $0.report } }
    /// Every connect attempt, lazy ones included.
    public var connectAttempts: Int { state.withLock { $0.connectAttempts } }
    /// The events delivered, in order.
    public var sent: [SimulatorHIDEvent] { state.withLock { $0.sent } }
    /// Every `flush`, in order.
    public var flushes: [Flush] { state.withLock { $0.flushes } }
    var mainThreadCalls: Int { state.withLock { $0.mainThreadCalls } }

    private func noteCall() {
        if Thread.isMainThread { state.withLock { $0.mainThreadCalls += 1 } }
    }

    @discardableResult
    public func connect() throws -> SimulatorHIDConnectReport {
        noteCall()
        return try state.withLock { try Self.connect(&$0, error: connectError, report: report) }
    }

    public func send(_ event: SimulatorHIDEvent) throws {
        noteCall()
        let points: [SimulatorTouchPoint]
        switch event {
        case .touch(let x, let y, _), .edgeTouch(let x, let y, _, _): points = [SimulatorTouchPoint(x: x, y: y)]
        case .twoFingerTouch(let first, let second, _): points = [first, second]
        case .button, .key: points = []
        }
        for point in points where !(0...1).contains(point.x) || !(0...1).contains(point.y) {
            throw SimulatorBridgeError(.invalidArgument, "fake: touch (\(point.x), \(point.y)) is out of range")
        }
        try state.withLock { state in
            _ = try Self.connect(&state, error: connectError, report: report)
            state.sent.append(event)
        }
    }

    public func flush(timeout: Duration) throws {
        noteCall()
        state.withLock { $0.flushes.append(Flush(sentCount: $0.sent.count, connected: $0.connected)) }
    }

    public func disconnect() {
        noteCall()
        state.withLock { $0.connected = false }
    }

    private static func connect(
        _ state: inout State,
        error: SimulatorBridgeError,
        report: SimulatorHIDConnectReport
    ) throws -> SimulatorHIDConnectReport {
        if state.connected, let existing = state.report { return existing }
        state.connectAttempts += 1
        if state.remainingFailures > 0 {
            state.remainingFailures -= 1
            throw error
        }
        state.connected = true
        state.report = report
        return report
    }
}

/// The fake's GSEvent port: records what was sent.
public final class FakeSimulatorGSEvents: SimulatorGSEventBridging {
    public enum Event: Sendable, Equatable {
        case orientation(UInt32)
        case lock
    }

    public let address: SimulatorAddress
    private let error: SimulatorBridgeError?

    private struct State {
        var sent: [Event] = []
        var mainThreadCalls = 0
    }

    private let state = Mutex(State())

    init(address: SimulatorAddress, error: SimulatorBridgeError?) {
        self.address = address
        self.error = error
    }

    /// The events sent, in order (failed sends included).
    public var sent: [Event] { state.withLock { $0.sent } }
    var mainThreadCalls: Int { state.withLock { $0.mainThreadCalls } }

    private func record(_ event: Event) throws {
        let onMain = Thread.isMainThread
        state.withLock { state in
            if onMain { state.mainThreadCalls += 1 }
            state.sent.append(event)
        }
        if let error { throw error }
    }

    public func sendOrientation(_ value: UInt32) throws {
        guard (1...4).contains(value) else {
            throw SimulatorBridgeError(.invalidArgument, "fake: orientation \(value) is not 1 through 4")
        }
        try record(.orientation(value))
    }

    public func sendLock() throws {
        try record(.lock)
    }
}
