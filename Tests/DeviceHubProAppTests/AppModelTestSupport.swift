import Foundation
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// A mirror session with no transport: tests feed its `FrameStore` and read
/// what the model did to it.
final class FakeMirrorSession: MirrorSessionProtocol, @unchecked Sendable {
    let frames = FrameStore()
    let transport: MirrorTransport = .h264

    private let lock = NSLock()
    private var _lastError: String?
    private var _isRunning = false
    private var _stopCount = 0
    private var _supportsHardwareKeys = true
    private var _hardwareKeyEvents: [HardwareKeyEvent] = []

    var lastError: String? {
        lock.withLock { _lastError }
    }

    /// Like an emulator session, by default; a test sets it false for a
    /// session without hardware keys.
    var supportsHardwareKeys: Bool {
        get { lock.withLock { _supportsHardwareKeys } }
        set { lock.withLock { _supportsHardwareKeys = newValue } }
    }

    /// Every hardware key event the app sent, in order.
    var hardwareKeyEvents: [HardwareKeyEvent] {
        lock.withLock { _hardwareKeyEvents }
    }

    var isRunning: Bool {
        lock.withLock { _isRunning }
    }

    var stopCount: Int {
        lock.withLock { _stopCount }
    }

    func start() {
        lock.withLock { _isRunning = true }
    }

    func stop() {
        lock.withLock {
            _isRunning = false
            _stopCount += 1
        }
    }

    func resync() async {}

    /// The frame count `stats()` reports; a test raises it to play a first frame.
    var reportedFrames: Int {
        get { lock.withLock { _reportedFrames } }
        set { lock.withLock { _reportedFrames = newValue } }
    }
    private var _reportedFrames = 0

    func stats() async -> MirrorStats {
        MirrorStats(fps: 0, totalFrames: reportedFrames, dropped: 0, averageLatencyMs: 0)
    }

    func send(_ command: TouchCommand) {}
    func send(contacts: [TouchCommand]) {}
    func send(_ command: KeyboardCommand) {}

    func send(_ event: HardwareKeyEvent) {
        lock.withLock { _hardwareKeyEvents.append(event) }
    }

    /// Stores a solid frame; each call is a new frame (new generation).
    func putFrame(width: Int = 64, height: Int = 128, shade: UInt8) {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            bytes[index] = shade
            bytes[index + 1] = 255 &- shade
            bytes[index + 2] = shade / 2
        }
        frames.put(Frame(data: Data(bytes), width: width, height: height, seq: 0))
    }
}

/// A physical device's scrcpy session with no transport: its control socket
/// is up or down as the test sets it, its stream fails when the test says
/// so, and it logs what the app sent it (the device clipboard, Back) instead
/// of reaching a phone.
final class FakePhysicalSession: MirrorSessionProtocol, PhysicalSessionControlling, @unchecked Sendable {
    /// One `setDeviceClipboard` call.
    struct ClipboardWrite: Equatable {
        let text: String
        let paste: Bool
    }

    let serial: String
    let frames = FrameStore()
    let transport: MirrorTransport = .h264

    private let lock = NSLock()
    private var _usesControlSocket: Bool
    private var _onDeviceClipboard: (@Sendable (String) -> Void)?
    private var _clipboardWrites: [ClipboardWrite] = []
    private var _backPresses = 0
    private var _lastError: String?
    private var _isRunning = false
    private var _stopCount = 0
    private var _stopAndWaitDelay: TimeInterval = 0
    private var _stopAndWaitCount = 0

    init(serial: String, usesControlSocket: Bool = true) {
        self.serial = serial
        _usesControlSocket = usesControlSocket
    }

    var usesControlSocket: Bool {
        get { lock.withLock { _usesControlSocket } }
        set { lock.withLock { _usesControlSocket = newValue } }
    }

    var onDeviceClipboard: (@Sendable (String) -> Void)? {
        get { lock.withLock { _onDeviceClipboard } }
        set { lock.withLock { _onDeviceClipboard = newValue } }
    }

    /// Every device clipboard the app set, in order.
    var clipboardWrites: [ClipboardWrite] {
        lock.withLock { _clipboardWrites }
    }

    var backPresses: Int {
        lock.withLock { _backPresses }
    }

    /// The stream's last error as the test sets it: while the session runs
    /// it is an input error; `fail(_:)` makes it a fatal one.
    var lastError: String? {
        get { lock.withLock { _lastError } }
        set { lock.withLock { _lastError = newValue } }
    }

    var isRunning: Bool {
        lock.withLock { _isRunning }
    }

    var stopCount: Int {
        lock.withLock { _stopCount }
    }

    /// The transport fails for good: like `PhysicalMirrorSession`, the
    /// session stops itself and leaves `error` in `lastError`.
    func fail(_ error: String) {
        lock.withLock {
            _lastError = error
            _isRunning = false
        }
    }

    func setDeviceClipboard(_ text: String, paste: Bool) {
        lock.withLock { _clipboardWrites.append(ClipboardWrite(text: text, paste: paste)) }
    }

    func sendBackOrScreenOn() {
        lock.withLock { _backPresses += 1 }
    }

    func start() {
        lock.withLock { _isRunning = true }
    }

    func stop() {
        lock.withLock {
            _isRunning = false
            _stopCount += 1
        }
    }

    /// How long `stopAndWait` blocks its caller, like the real session's
    /// bounded wait for its sockets and device server.
    var stopAndWaitDelay: TimeInterval {
        get { lock.withLock { _stopAndWaitDelay } }
        set { lock.withLock { _stopAndWaitDelay = newValue } }
    }

    var stopAndWaitCount: Int {
        lock.withLock { _stopAndWaitCount }
    }

    func stopAndWait(timeout: TimeInterval) {
        let delay = stopAndWaitDelay
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        stop()
        lock.withLock { _stopAndWaitCount += 1 }
    }

    func resync() async {}

    func stats() async -> MirrorStats {
        MirrorStats(fps: 0, totalFrames: 0, dropped: 0, averageLatencyMs: 0)
    }

    func send(_ command: TouchCommand) {}
    func send(contacts: [TouchCommand]) {}
    func send(_ command: KeyboardCommand) {}
}

extension EmulatorManager {
    /// An emulator binary that fails every call (`/usr/bin/false`), seeing
    /// only the VMs this test process started: the Mac's real emulators are
    /// never listed, matched, probed or signalled through it.
    static var inert: EmulatorManager {
        EmulatorManager(emulatorURL: URL(fileURLWithPath: "/usr/bin/false"), processScope: .ownProcesses)
    }
}

/// An in-memory pasteboard: holds either the last text or the last PNG.
@MainActor
final class TestPasteboard: MacPasteboard {
    var text: String?
    var png: Data?

    func string() -> String? {
        text
    }

    func setString(_ text: String) {
        self.text = text
        png = nil
    }

    func setPNG(_ png: Data) {
        self.png = png
        text = nil
    }
}

/// A save panel stand-in: answers `destination` (nil = the user cancelled)
/// and records every file it was asked about. It has no auto-save
/// directory, so a clip nobody was asked about stays in its temporary
/// directory unless the test names one (never the user's Desktop).
@MainActor
final class TestPicker: FileDestinationPicker {
    var destination: URL?
    var autoSaveDirectory: URL?
    private(set) var suggestedNames: [String] = []

    func chooseDestination(suggestedName: String, directory: URL?) -> URL? {
        suggestedNames.append(suggestedName)
        return destination
    }
}

extension UserDefaults {
    /// An empty defaults store of the caller's own. Its suite name is an
    /// absolute path, so it is a plist in the temporary directory rather
    /// than a domain in ~/Library/Preferences: a test never reads another
    /// test's settings or a previous run's, and never writes the xctest
    /// domain behind `UserDefaults.standard`.
    static func scratch() -> UserDefaults {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceHubProAppTests-defaults", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .path
        guard let defaults = UserDefaults(suiteName: path) else {
            preconditionFailure("no defaults suite at \(path)")
        }
        return defaults
    }
}

extension AppEnvironment {
    /// A hermetic environment: no adb unless one is given, an emulator that
    /// fails every call, no Apple tooling unless some is given (stubs, see
    /// `AppleTooling.stubbed`), no launch options, empty defaults of its
    /// own, an in-memory pasteboard and a picker that cancels. Whatever
    /// emulator it is given sees only the VMs this test process started.
    @MainActor
    static func testing(
        adb: AdbClient? = nil,
        emulator: EmulatorManager? = EmulatorManager.inert,
        apple: AppleTooling? = nil,
        launch: LaunchOptions = .none,
        defaults: UserDefaults = .scratch()
    ) -> AppEnvironment {
        AppEnvironment(
            adbClient: adb,
            emulatorManager: emulator,
            emulatorProcesses: .ownProcesses,
            defaults: defaults,
            launch: launch,
            pasteboard: TestPasteboard(),
            picker: TestPicker(),
            apple: apple
        )
    }
}

extension AppModel {
    /// A model on `AppEnvironment.testing`: it has exactly the tools it is
    /// given — it never locates adb or the SDK emulator — the runner's
    /// `DHP_*` variables do not reach it, and it starts from a fresh
    /// install's settings unless the test hands it `defaults`.
    static func testing(
        adb: AdbClient? = nil,
        emulator: EmulatorManager? = EmulatorManager.inert,
        apple: AppleTooling? = nil,
        launch: LaunchOptions = .none,
        defaults: UserDefaults = .scratch()
    ) -> AppModel {
        AppModel(environment: .testing(adb: adb, emulator: emulator, apple: apple, launch: launch, defaults: defaults))
    }
}

/// A fake `adb`: logs every argv line to `calls.log` and answers with the
/// test's `case` arms (POSIX sh). Unmatched invocations fail.
struct StubAdb {
    let client: AdbClient
    let directory: URL
    let callsURL: URL

    var calls: [String] {
        ((try? String(contentsOf: callsURL, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .map(String.init)
    }

    func calls(containing text: String) -> [String] {
        calls.filter { $0.contains(text) }
    }
}

extension XCTestCase {
    /// Writes a fake adb whose `case "$*" in` arms are `arms`; each arm sees
    /// the whole argv joined by spaces (`-s emulator-5554 emu avd name`).
    func makeStubAdb(arms: String, file: StaticString = #filePath, line: UInt = #line) throws -> StubAdb {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let callsURL = directory.appendingPathComponent("calls.log")
        let adbURL = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(callsURL.path)"
        case "$*" in
        \(arms)
          *)
            exit 1 ;;
        esac
        exit 0
        """
        try Data(script.utf8).write(to: adbURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adbURL.path)
        return StubAdb(client: AdbClient(adbURL: adbURL), directory: directory, callsURL: callsURL)
    }

    /// Polls `condition` on the main actor until it holds or `timeout` passes.
    @MainActor
    func waitUntil(
        timeout: TimeInterval = 5,
        _ message: String = "condition not met",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            // Best effort: the sleep fails only on cancellation; the loop re-checks the deadline.
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("\(message) within \(timeout) s", file: file, line: line)
    }
}

extension AndroidDevice {
    static func online(_ serial: String, transport: String? = nil, model: String? = nil) -> AndroidDevice {
        AndroidDevice(serial: serial, state: "device", model: model, transportID: transport)
    }
}
