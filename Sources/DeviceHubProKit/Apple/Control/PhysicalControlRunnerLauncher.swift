import Foundation
import Synchronization

/// What starting the runner on the phone needs.
public struct PhysicalControlLaunchConfiguration: Sendable {
    /// The `.xctestrun` of the signed build.
    public let xctestrunURL: URL
    /// The phone's hardware UDID, for `-destination`. It is on the command
    /// line of the child for the run's duration and nowhere else.
    public let hardwareUDID: String
    /// The tunnel address and the token: the runner's only bind address and
    /// its only secret, in its environment.
    public let endpoint: PhysicalControlEndpoint
    public let developerDirectory: URL?
    /// The runner's own watchdog (`DHP_MAX_SECONDS`): it ends itself
    /// after this long, whatever the Mac does.
    public let maximumSeconds: Int

    public init(
        xctestrunURL: URL,
        hardwareUDID: String,
        endpoint: PhysicalControlEndpoint,
        developerDirectory: URL?,
        maximumSeconds: Int
    ) {
        self.xctestrunURL = xctestrunURL
        self.hardwareUDID = hardwareUDID
        self.endpoint = endpoint
        self.developerDirectory = developerDirectory
        self.maximumSeconds = maximumSeconds
    }
}

/// A running runner process, as the session sees it.
public protocol PhysicalControlRunnerProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    /// The last of the process's output (unredacted; the session redacts it
    /// before it keeps or shows any).
    var outputTail: String { get }
    /// SIGINT: what Ctrl-C does, which ends the test cleanly.
    func interrupt()
    /// SIGTERM.
    func terminate()
    /// SIGKILL.
    func kill()
    /// Waits until the process has exited, at most `timeout`; true when it
    /// has.
    func waitForExit(timeout: Duration) async -> Bool
}

/// Starts the runner. The real one is `XcodebuildRunnerLauncher`; tests hand
/// in a fake, so no test starts a process.
public protocol PhysicalControlRunnerLaunching: Sendable {
    func launch(_ configuration: PhysicalControlLaunchConfiguration) throws -> any PhysicalControlRunnerProcess
}

/// Runs the signed runner on the phone with `xcodebuild test-without-building`.
///
/// This file is the only place in Device Hub Pro that spells that command
/// (`AppleSourceGuardTests` pins it). The runner is the public XCTest
/// runner of `ios/agent`; nothing here uses a private CoreDevice service.
///
/// The child gets the bind address and the token as
/// `TEST_RUNNER_DHP_BIND` and `TEST_RUNNER_DHP_TOKEN` (xcodebuild
/// passes `TEST_RUNNER_*` variables to the runner without the prefix). The
/// token is not on the command line and is not printed; the child's output
/// is kept only as a short tail for failure messages.
public struct XcodebuildRunnerLauncher: PhysicalControlRunnerLaunching {
    public let xcodebuildURL: URL

    /// The runner's test: the one long-running `testServe`.
    static let testIdentifier = "DeviceHubProAgentUITests/DeviceHubProAgentUITests/testServe"

    public init(xcodebuildURL: URL) {
        self.xcodebuildURL = xcodebuildURL
    }

    /// Seconds without an authorized request after which the runner stops itself.
    static let idleSeconds = 90

    /// The command line for `configuration` (no secret in it).
    static func arguments(for configuration: PhysicalControlLaunchConfiguration) -> [String] {
        [
            "test-without-building",
            "-xctestrun", configuration.xctestrunURL.path,
            "-destination", "id=\(configuration.hardwareUDID)",
            "-only-testing:\(testIdentifier)",
        ]
    }

    /// The child's environment: the inherited one, the developer directory,
    /// and the runner's variables.
    static func environment(for configuration: PhysicalControlLaunchConfiguration) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("TEST_RUNNER_DHP_") {
            environment[key] = nil
        }
        if let developerDirectory = configuration.developerDirectory {
            environment["DEVELOPER_DIR"] = developerDirectory.path
        }
        environment["TEST_RUNNER_DHP_BIND"] = configuration.endpoint.address
        environment["TEST_RUNNER_DHP_TOKEN"] = configuration.endpoint.token.value
        environment["TEST_RUNNER_DHP_PORT"] = String(configuration.endpoint.port)
        environment["TEST_RUNNER_DHP_MAX_SECONDS"] = String(configuration.maximumSeconds)
        // The runner ends itself when no authorized request came for this long
        // (the Mac's health monitor polls /status, so a live Mac keeps it alive).
        environment["TEST_RUNNER_DHP_IDLE_SECONDS"] = String(idleSeconds)
        return environment
    }

    public func launch(_ configuration: PhysicalControlLaunchConfiguration) throws -> any PhysicalControlRunnerProcess {
        let process = Process()
        process.executableURL = xcodebuildURL
        process.arguments = Self.arguments(for: configuration)
        process.environment = Self.environment(for: configuration)
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let child = RunnerChild(process: process)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                child.append(data)
            }
        }
        process.terminationHandler = { _ in
            child.didExit()
            output.fileHandleForReading.readabilityHandler = nil
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw PhysicalControlError.launchFailed((error as NSError).localizedDescription)
        }
        return child
    }
}

/// The real child: a `Process` and the tail of its output.
final class RunnerChild: PhysicalControlRunnerProcess, @unchecked Sendable {
    private static let tailLimit = 6_000

    private let process: Process
    private let state = Mutex(State())

    private struct State {
        var tail = Data()
        var exited = false
    }

    init(process: Process) {
        self.process = process
    }

    var isRunning: Bool { !state.withLock { $0.exited } && process.isRunning }

    var outputTail: String {
        state.withLock { String(decoding: $0.tail, as: UTF8.self) }
    }

    func append(_ data: Data) {
        state.withLock { state in
            state.tail.append(data)
            if state.tail.count > Self.tailLimit {
                state.tail = state.tail.suffix(Self.tailLimit)
            }
        }
    }

    func didExit() {
        state.withLock { $0.exited = true }
    }

    func interrupt() {
        guard isRunning else { return }
        process.interrupt()
    }

    func terminate() {
        guard isRunning else { return }
        process.terminate()
    }

    func kill() {
        guard isRunning else { return }
        Foundation.kill(process.processIdentifier, SIGKILL)
    }

    func waitForExit(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while isRunning {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
}
