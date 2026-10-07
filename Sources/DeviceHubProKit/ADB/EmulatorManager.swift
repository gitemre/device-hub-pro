import Foundation

public enum EmulatorError: Error, CustomStringConvertible {
    case emulatorNotFound
    case launchFailed(String)
    case stopFailed(String)

    public var description: String {
        switch self {
        case .emulatorNotFound:
            return "The Android Emulator isn\u{2019}t installed."
        case .launchFailed(let reason):
            return "emulator launch failed: \(reason)"
        case .stopFailed(let reason):
            return "could not stop the emulator: \(reason)"
        }
    }
}

/// A running emulator VM discovered from the process list.
public struct RunningEmulator: Sendable, Hashable {
    public let avd: String
    public let processID: Int32
    public let grpcPort: Int?
}

/// Outcome of stopping an emulator VM.
public enum EmulatorStopResult: Sendable, Equatable {
    /// No running VM matched the AVD name; nothing was signalled.
    case notRunning
    /// The VM exited. `gracefully` is false when it was ended with SIGKILL
    /// (it ignored the gentler steps, or `killWithoutSaving` skipped them).
    case stopped(gracefully: Bool)
}

/// Which of this Mac's emulator VMs an `EmulatorManager` sees: the VMs its
/// process list holds, and so the only ones it matches by AVD name, attaches
/// to, signals on a stop, and probes gRPC ports for.
public enum EmulatorProcessScope: Sendable, Equatable {
    /// Every VM `ps` lists, whoever started it (Android Studio, the command
    /// line, another app): the app's view.
    case everyVM
    /// Only the VMs this process started: launched by an `EmulatorManager`
    /// (any instance) or registered with `EmulatorManager.adoptProcess`.
    /// Every other VM on the Mac is invisible, so it is never matched,
    /// attached to or signalled, and no gRPC port is ever probed for — the
    /// scope of a test, which must not reach an emulator it did not start.
    case ownProcesses
}

/// Locates and drives the Android emulator binary (AVD listing and launching).
public final class EmulatorManager: Sendable {
    public let emulatorURL: URL
    /// The VMs this manager sees (`runningEmulators()`, and through it
    /// `stop` and `killWithoutSaving`).
    public let processScope: EmulatorProcessScope

    /// `processScope` has no default: every construction says which VMs it
    /// may see. The app's (`AppEnvironment.live()`) is `.everyVM`; a test's
    /// is `.ownProcesses`, so a stub emulator can never be spelled in a way
    /// that quietly lists, matches, probes or signals the Mac's real VMs.
    public init(emulatorURL: URL, processScope: EmulatorProcessScope) {
        self.emulatorURL = emulatorURL
        self.processScope = processScope
    }

    /// This emulator binary seen through `scope`: `self` when it already
    /// is. Launches register their VM process-wide, so a VM launched through
    /// either instance is this process's own in both.
    public func scoped(to scope: EmulatorProcessScope) -> EmulatorManager {
        scope == processScope ? self : EmulatorManager(emulatorURL: emulatorURL, processScope: scope)
    }

    /// The emulator found on this Mac (`locateBinary`), seeing the VMs
    /// `processScope` names.
    public static func locate(
        processScope: EmulatorProcessScope,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> EmulatorManager? {
        locateBinary(environment: environment).map {
            EmulatorManager(emulatorURL: $0, processScope: processScope)
        }
    }

    /// The emulator binary on this Mac: `DHP_EMULATOR`, then the SDK
    /// roots (`ANDROID_HOME`, `ANDROID_SDK_ROOT`, the default SDK, the one
    /// the located adb is in), then Homebrew's. For callers that only need
    /// the SDK's location; nil when none is executable.
    public static func locateBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var candidates: [String] = []

        if let explicit = environment["DHP_EMULATOR"], !explicit.isEmpty {
            candidates.append(explicit)
        }
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = environment[key], !root.isEmpty {
                candidates.append(root + "/emulator/emulator")
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates.append(home + "/Library/Android/sdk/emulator/emulator")

        if let adb = AdbBinaryLocator.locate(environment: environment) {
            let sdkRoot = adb.deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(sdkRoot.appendingPathComponent("emulator/emulator").path)
        }

        candidates.append("/opt/homebrew/bin/emulator")
        candidates.append("/usr/local/bin/emulator")

        let fileManager = FileManager.default
        return candidates
            .first { fileManager.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    public func listAvds() async throws -> [String] {
        // Bounded like every one-shot tool call (see `AdbClient`): a hung
        // emulator binary must not stall a refresh forever.
        let result = try await ProcessRunner.run(
            executable: emulatorURL,
            arguments: ["-list-avds"],
            timeout: AdbClient.defaultTimeout
        )
        return result.standardOutputText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Launches a headless (window hidden) emulator with the gRPC control channel
    /// enabled and host GPU rendering. Output is appended to
    /// `logFileURL(forAvd:)`.
    ///
    /// Boots like Android Studio's Quick Boot: from the AVD's quick-boot
    /// snapshot when it has one, saving a fresh one on a clean exit (the
    /// emulator's own default; the AVD's boot settings still apply).
    /// `coldBoot` skips loading the snapshot for this launch only
    /// (`-no-snapshot-load`) — after `AvdDisplayRepair` rewrote `config.ini`,
    /// whose hardware the saved snapshot no longer matches, or to recover a
    /// guest that powered off (end the old VM with `killWithoutSaving` first,
    /// so the broken guest is neither saved nor still holding the AVD). The
    /// cold boot still saves a snapshot on exit, so the next launch is quick
    /// again.
    ///
    /// `grpcTokenAuth` adds `-grpc-use-token`: the VM's gRPC API then rejects
    /// any local process that lacks the token the emulator writes to its
    /// discovery file, instead of letting every local user drive the VM. The
    /// caller must read that file once the VM is up —
    /// `EmulatorDiscovery.grpcInfo(serial:adbClient:)` registers the token
    /// for the port — before any gRPC call, or every call is refused.
    @discardableResult
    public func launch(
        avd: String,
        grpcPort: Int,
        audioEnabled: Bool = true,
        coldBoot: Bool = false,
        grpcTokenAuth: Bool = false
    ) throws -> Process {
        let arguments = Self.launchArguments(
            avd: avd,
            grpcPort: grpcPort,
            audioEnabled: audioEnabled,
            coldBoot: coldBoot,
            grpcTokenAuth: grpcTokenAuth
        )
        let process: Process
        do {
            process = try ProcessRunner.launchDetached(
                executable: emulatorURL,
                arguments: arguments,
                logURL: logFileURL(forAvd: avd)
            )
        } catch {
            throw EmulatorError.launchFailed("\(error)")
        }
        // The launcher execs the VM, so this pid is the one `ps` lists.
        Self.launchedProcesses.insert(process.processIdentifier, avd: avd)
        return process
    }

    /// Records a VM process this process started without `launch` — a test's
    /// stand-in VM — as its own: `.ownProcesses` managers then list it (while
    /// `ps` shows it running `avd`), and `stop` may escalate to SIGKILL for it
    /// as for a VM it launched.
    static func adoptProcess(_ processID: Int32, avd: String) {
        launchedProcesses.insert(processID, avd: avd)
    }

    /// The emulator command line `launch` uses.
    static func launchArguments(
        avd: String,
        grpcPort: Int,
        audioEnabled: Bool,
        coldBoot: Bool,
        grpcTokenAuth: Bool = false
    ) -> [String] {
        var arguments = [
            "-avd", avd,
            "-grpc", "\(grpcPort)",
            "-gpu", "host",
            "-no-boot-anim",
            "-qt-hide-window",
        ]
        if grpcTokenAuth {
            arguments.append("-grpc-use-token")
        }
        if coldBoot {
            arguments.append("-no-snapshot-load")
        }
        if !audioEnabled {
            arguments.append("-no-audio")
        }
        return arguments
    }

    /// Emulators currently running on this machine, parsed from `ps`.
    /// Detects the AVD name and the gRPC port from the VM's command line.
    /// An `.ownProcesses` manager lists only the VMs this process started —
    /// the pid and the AVD name must both be the ones it recorded, so a
    /// recycled pid never names someone else's VM.
    public func runningEmulators() async throws -> [RunningEmulator] {
        let psOutput = try await Self.processList()
        switch processScope {
        case .everyVM:
            return Self.parseRunningEmulators(psOutput: psOutput)
        case .ownProcesses:
            let own = Self.launchedProcesses
            return Self.parseRunningEmulators(psOutput: psOutput) { processID, avd in
                own.avd(of: processID) == avd
            }
        }
    }

    /// Whether any VM on the Mac runs `avd`, whoever started it — whatever
    /// this manager's `processScope`. For a check whose safe answer is to
    /// refuse: a file action on the AVD, a rewrite of its `config.ini`, a
    /// second launch of it. Reading `ps` reaches no VM; matching, attaching
    /// and signalling stay within the scope (`runningEmulators()`), so an
    /// `.ownProcesses` manager still never acts on a VM it did not start,
    /// but it no longer takes that VM's AVD for stopped either. Throws when
    /// the process list cannot be read (the caller refuses).
    public func isAnyVMRunning(avd: String) async throws -> Bool {
        let psOutput = try await Self.processList()
        return Self.parseRunningEmulators(psOutput: psOutput).contains { $0.avd == avd }
    }

    /// `ps -axo pid=,command=`: every process on the Mac with its command
    /// line, the source of `runningEmulators()`.
    private static func processList() async throws -> String {
        try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,command="],
            timeout: .seconds(10)
        ).standardOutputText
    }

    /// The ports `GrpcPortService` probes for a VM whose command line names
    /// no gRPC port — the emulator's defaults, 8554 for the first console on.
    /// A probe cannot tell whose port answered, so an `.ownProcesses`
    /// manager probes none.
    public var grpcScanPorts: [Int] {
        switch processScope {
        case .everyVM: Array(8554...8563)
        case .ownProcesses: []
        }
    }

    /// The loopback port nothing can listen on: TCP has no port 0, and a
    /// connect to it fails at once (`EADDRNOTAVAIL`).
    public static let unreachableGrpcPort = 0

    /// The gRPC port for a VM about to be launched. `.everyVM`: the first
    /// free one from 8554 on, reserved (`firstFreePort()`). `.ownProcesses`:
    /// `unreachableGrpcPort` — its VMs are stand-ins that serve no gRPC, and
    /// a port from the emulators' range could meanwhile be taken by a real
    /// VM another process launches, which a session that falls back to
    /// this port (no discovery file) would then drive.
    public func reserveGrpcPort() -> Int {
        switch processScope {
        case .everyVM: Self.firstFreePort()
        case .ownProcesses: Self.unreachableGrpcPort
        }
    }

    /// Stops the running emulator VM for `avd`, gently first:
    ///
    /// 1. The emulator console's `kill` (`adb -s <serial> emu kill`): the
    ///    emulator's own clean shutdown, which also saves its quick-boot
    ///    snapshot — that can take a while for a large RAM image, so the
    ///    wait is `shutdownTimeout`. `serial` is looked up through `adb` when
    ///    not given; without adb (nil, or a console that refuses) this step
    ///    is skipped. The caller always names its adb: a default located on
    ///    the Mac would ask every emulator's console for its AVD name.
    /// 2. SIGTERM (the emulator treats it as a shutdown request too), waiting
    ///    `gracefulTimeout`.
    /// 3. SIGKILL — only for a VM this app launched, or with `force`. A VM
    ///    started elsewhere (Android Studio, the command line, an earlier
    ///    run of the app) may still be writing its snapshot, so it is left
    ///    running and `EmulatorError.stopFailed` says so.
    ///
    /// The target is found in the process list, so this also covers VMs
    /// started outside this app, for which no launch handle exists — for an
    /// `.everyVM` manager; an `.ownProcesses` one finds only its process's
    /// own VMs, and answers `.notRunning` for any other.
    public func stop(
        avd: String,
        serial: String? = nil,
        adb: AdbClient?,
        shutdownTimeout: TimeInterval = 60,
        gracefulTimeout: TimeInterval = 20,
        force: Bool = false
    ) async throws -> EmulatorStopResult {
        guard let target = try await runningEmulators().first(where: { $0.avd == avd }) else {
            return .notRunning
        }
        let processID = target.processID
        var requestShutdown: (@Sendable () async -> Bool)?
        if let adb {
            requestShutdown = {
                await Self.requestConsoleShutdown(avd: avd, serial: serial, adb: adb)
            }
        }
        let steps = EmulatorStopSteps(
            requestShutdown: requestShutdown,
            isRunning: { [self] in
                let running = try await self.runningEmulators()
                return running.contains { $0.avd == avd }
            },
            // Best effort: a VM that is already gone (or cannot be signalled)
            // surfaces as exited (or still running) in the exit wait.
            signal: { signal in _ = kill(processID, signal) }
        )
        return try await Self.stopSequence(
            avd: avd,
            processID: processID,
            steps: steps,
            shutdownTimeout: shutdownTimeout,
            gracefulTimeout: gracefulTimeout,
            killAllowed: force || Self.launchedProcesses.contains(processID)
        )
    }

    /// The escalation behind `stop`, with its process-facing steps injected.
    static func stopSequence(
        avd: String,
        processID: Int32,
        steps: EmulatorStopSteps,
        shutdownTimeout: TimeInterval,
        gracefulTimeout: TimeInterval,
        killAllowed: Bool,
        pollInterval: Duration = .milliseconds(250)
    ) async throws -> EmulatorStopResult {
        if let requestShutdown = steps.requestShutdown, await requestShutdown(),
           try await waitForExit(steps.isRunning, timeout: shutdownTimeout, pollInterval: pollInterval) {
            return .stopped(gracefully: true)
        }
        steps.signal(SIGTERM)
        if try await waitForExit(steps.isRunning, timeout: gracefulTimeout, pollInterval: pollInterval) {
            return .stopped(gracefully: true)
        }
        guard killAllowed else {
            throw EmulatorError.stopFailed(
                "\(avd) (pid \(processID)) is still shutting down — it may be saving its snapshot. "
                    + "It was not started by Device Hub Pro, so it is not force-killed; try again in a moment."
            )
        }
        steps.signal(SIGKILL)
        guard try await waitForExit(steps.isRunning, timeout: 3, pollInterval: pollInterval) else {
            throw EmulatorError.stopFailed("\(avd) (pid \(processID)) is still running after SIGKILL")
        }
        return .stopped(gracefully: false)
    }

    /// Ends the running VM for `avd` at once, without its clean shutdown, and
    /// returns once its process is gone — for a guest that is broken (powered
    /// off or hung) and is cold-booted next.
    ///
    /// `stop` would be wrong here. Its clean shutdown saves the broken guest
    /// as the AVD's quick-boot snapshot, so the next ordinary launch boots
    /// straight back into it; and the VM keeps the AVD locked while it writes
    /// that snapshot, so a relaunch in the meantime is refused ("Another
    /// emulator instance is running"). SIGKILL saves nothing, and the lock it
    /// leaves behind is stale once the pid is gone, which the emulator
    /// detects and clears — so this waits for the pid itself to disappear
    /// (reaped, not just dropped from `ps`) before returning.
    ///
    /// Unlike `stop`, this also kills a VM started outside the app (one this
    /// manager's `processScope` lists): the caller discards its guest either
    /// way, and a clean shutdown's only product would be that broken
    /// snapshot. Throws
    /// `EmulatorError.stopFailed` when the process outlives `exitTimeout`.
    @discardableResult
    public func killWithoutSaving(avd: String, exitTimeout: TimeInterval = 10) async throws -> EmulatorStopResult {
        guard let target = try await runningEmulators().first(where: { $0.avd == avd }) else {
            return .notRunning
        }
        let processID = target.processID
        let steps = EmulatorStopSteps(
            requestShutdown: nil,
            isRunning: { Self.processExists(processID) },
            // Best effort: a VM that is already gone surfaces as exited in
            // the exit wait.
            signal: { signal in _ = kill(processID, signal) }
        )
        return try await Self.killSequence(
            avd: avd,
            processID: processID,
            steps: steps,
            exitTimeout: exitTimeout
        )
    }

    /// The escalation behind `killWithoutSaving`: SIGKILL, then the exit
    /// wait. No clean-shutdown request and no SIGTERM — both save the
    /// snapshot.
    static func killSequence(
        avd: String,
        processID: Int32,
        steps: EmulatorStopSteps,
        exitTimeout: TimeInterval,
        pollInterval: Duration = .milliseconds(100)
    ) async throws -> EmulatorStopResult {
        steps.signal(SIGKILL)
        guard try await waitForExit(steps.isRunning, timeout: exitTimeout, pollInterval: pollInterval) else {
            throw EmulatorError.stopFailed("\(avd) (pid \(processID)) is still running after SIGKILL")
        }
        return .stopped(gracefully: false)
    }

    /// Whether `processID` still names a process, a zombie included: the
    /// emulator's AVD lock counts as held while `kill(pid, 0)` succeeds.
    static func processExists(_ processID: Int32) -> Bool {
        kill(processID, 0) == 0 || errno == EPERM
    }

    /// True once `isRunning` reports the VM gone, polling until `timeout`.
    private static func waitForExit(
        _ isRunning: () async throws -> Bool,
        timeout: TimeInterval,
        pollInterval: Duration
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try await !isRunning() { return true }
            try await Task.sleep(for: pollInterval)
        } while Date() < deadline
        return try await !isRunning()
    }

    /// Asks the VM to shut itself down through its console (`emu kill`).
    /// False when the request could not be delivered: no adb transport is
    /// known for the AVD, or the console refused.
    static func requestConsoleShutdown(avd: String, serial: String?, adb: AdbClient) async -> Bool {
        var target = serial
        if target == nil {
            target = await emulatorSerial(forAvd: avd, adb: adb)
        }
        guard let target else { return false }
        do {
            try await adb.emuCommand(serial: target, ["kill"])
            return true
        } catch {
            return false
        }
    }

    /// The adb serial of the running emulator whose console names `avd`.
    static func emulatorSerial(forAvd avd: String, adb: AdbClient) async -> String? {
        // Best effort: without a device list there is no console to ask.
        guard let devices = try? await adb.listDevices() else { return nil }
        for device in devices where device.isEmulator {
            // Best effort: a console that does not answer is not the one.
            if let name = try? await adb.avdName(serial: device.serial), name == avd {
                return device.serial
            }
        }
        return nil
    }

    /// The VMs this process launched (or adopted), with their AVD names:
    /// `stop` escalates to SIGKILL only for these (or when forced), and they
    /// are all an `.ownProcesses` manager lists.
    private static let launchedProcesses = LaunchedProcesses()

    /// Parses `ps -axo pid=,command=` output into running emulator VMs,
    /// keeping only those `include` accepts (all by default).
    static func parseRunningEmulators(
        psOutput: String,
        including include: (_ processID: Int32, _ avd: String) -> Bool = { _, _ in true }
    ) -> [RunningEmulator] {
        var seen = Set<String>()
        var running: [RunningEmulator] = []

        for rawLine in psOutput.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.contains("qemu-system"), line.contains(" -avd ") else { continue }

            let tokens = line.split(separator: " ").map(String.init)
            guard let first = tokens.first, let pid = Int32(first) else { continue }

            var avd: String?
            var port: Int?
            var index = 1
            while index < tokens.count {
                if tokens[index] == "-avd", index + 1 < tokens.count {
                    avd = tokens[index + 1]
                    index += 2
                    continue
                }
                if tokens[index] == "-grpc", index + 1 < tokens.count {
                    port = Int(tokens[index + 1])
                    index += 2
                    continue
                }
                index += 1
            }

            // Filtered before the de-duplication: a VM the filter drops must
            // not hide a kept one of the same AVD further down.
            guard let name = avd, include(pid, name), !seen.contains(name) else { continue }
            seen.insert(name)
            running.append(RunningEmulator(avd: name, processID: pid, grpcPort: port))
        }

        return running
    }

    /// Log file the launched emulator writes to: in
    /// `~/Library/Logs/DeviceHubPro`, where the app keeps each AVD's log, for an
    /// `.everyVM` manager (never the shared `/tmp`, where another user could
    /// plant a link in its place); in the user's temporary directory for an
    /// `.ownProcesses` one, so its launches never truncate the log of a real
    /// AVD that has the same name.
    public func logFileURL(forAvd avd: String) -> URL {
        let sanitized = avd.replacingOccurrences(
            of: "[^A-Za-z0-9_.-]",
            with: "-",
            options: .regularExpression
        )
        let directory = switch processScope {
        case .everyVM: Self.appLogDirectory
        case .ownProcesses: FileManager.default.temporaryDirectory
        }
        return directory.appendingPathComponent("devicehubpro-emulator-\(sanitized).log")
    }

    /// `~/Library/Logs/DeviceHubPro`, made (readable by the user only) on first use.
    static var appLogDirectory: URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DeviceHubPro", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    /// Last lines of the emulator log, for error messages.
    public func logTail(forAvd avd: String, lines: Int = 12) -> String {
        let url = logFileURL(forAvd: avd)
        guard
            let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8),
            !text.isEmpty
        else {
            return "(no emulator log at \(url.path))"
        }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    /// How long a port handed out by `firstFreePort` stays reserved for the
    /// emulator it was chosen for. The emulator binds its gRPC server only
    /// seconds into its startup, so without the reservation two launches in
    /// that window both probe the same port as free.
    public static let portReservationWindow: Duration = .seconds(180)

    private static let portReservations = PortReservations()

    /// Finds a free localhost port for the gRPC channel, starting at `start`,
    /// and reserves it in-process for `portReservationWindow`: a port handed
    /// out here is skipped by later calls until its emulator has bound it (the
    /// probe then sees it taken) or the window lapses. Call
    /// `releasePortReservation(_:)` when the launch it was meant for fails.
    public static func firstFreePort(startingAt start: Int = 8554, limit: Int = 64) -> Int {
        portReservations.reserveFirst(
            in: start..<(start + limit),
            for: portReservationWindow,
            where: { isPortAvailable(UInt16($0)) }
        ) ?? start
    }

    /// Returns a port reserved by `firstFreePort` to the pool (its launch
    /// failed, or its emulator is gone).
    public static func releasePortReservation(_ port: Int) {
        portReservations.release(port)
    }

    private static func isPortAvailable(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

/// The process-facing steps of `EmulatorManager.stop`, injectable for tests.
struct EmulatorStopSteps: Sendable {
    /// Asks the VM to shut down cleanly; true when the request was delivered.
    /// Nil when no clean-shutdown channel exists.
    var requestShutdown: (@Sendable () async -> Bool)?
    /// Whether the VM is still in the process list.
    var isRunning: @Sendable () async throws -> Bool
    /// Sends a signal to the VM process.
    var signal: @Sendable (Int32) -> Void
}

/// Pids of emulator VMs launched by this process, with the AVD each runs.
final class LaunchedProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var avds: [Int32: String] = [:]

    func insert(_ pid: Int32, avd: String) {
        lock.lock()
        avds[pid] = avd
        lock.unlock()
    }

    func contains(_ pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return avds[pid] != nil
    }

    /// The AVD the VM with `pid` was launched for; nil for a pid this
    /// process did not launch.
    func avd(of pid: Int32) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return avds[pid]
    }
}

/// Ports handed out for emulator launches whose gRPC server may not be bound
/// yet, each until its deadline. Lock-protected, so concurrent launches
/// never receive the same port.
final class PortReservations: @unchecked Sendable {
    private let lock = NSLock()
    private var deadlines: [Int: ContinuousClock.Instant] = [:]
    private let clock = ContinuousClock()

    /// Reserves and returns the first port in `range` that is neither
    /// reserved nor rejected by `isFree`; nil when none qualifies.
    func reserveFirst(
        in range: Range<Int>,
        for window: Duration,
        where isFree: (Int) -> Bool
    ) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        let now = clock.now
        deadlines = deadlines.filter { $0.value > now }
        for port in range where deadlines[port] == nil && isFree(port) {
            deadlines[port] = now.advanced(by: window)
            return port
        }
        return nil
    }

    func release(_ port: Int) {
        lock.lock()
        deadlines[port] = nil
        lock.unlock()
    }
}
