import Foundation

/// Errors `SimctlClient` raises before or instead of running simctl.
public enum SimctlClientError: Error, Equatable, CustomStringConvertible {
    /// The arguments hold a selector that picks "some" or "every" simulator
    /// (`booted`, `all`, …). Device Hub Pro always names one device by UDID.
    case refusedSelector(String)
    /// A device argument that is not a simulator UDID.
    case invalidUDID(String)
    /// A value Device Hub Pro validates itself because simctl accepts it silently.
    case invalidValue(String)
    /// simctl exited 0 but printed something this build cannot read.
    case unexpectedOutput(command: String, detail: String)
    /// A stopped `recordVideo` left no playable movie.
    case incompleteRecording(String)

    public var description: String {
        switch self {
        case .refusedSelector(let token):
            return "simctl call refused: '\(token)' selects devices implicitly; name a UDID"
        case .invalidUDID(let value):
            return "'\(value)' is not a simulator UDID"
        case .invalidValue(let detail):
            return "Invalid value: \(detail)"
        case .unexpectedOutput(let command, let detail):
            return "\(command) printed unexpected output: \(detail)"
        case .incompleteRecording(let detail):
            return "Recording incomplete: \(detail)"
        }
    }
}

/// What one simctl run printed.
public struct SimctlOutput: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data

    public var standardOutputText: String { String(decoding: standardOutput, as: UTF8.self) }
    public var standardErrorText: String { String(decoding: standardError, as: UTF8.self) }
}

/// Runs the CoreSimulator `simctl` binary.
///
/// - Every call is an argv array (no shell) bounded by a timeout; when it
///   elapses the child is terminated and `ProcessRunnerError.timedOut`, naming
///   the simctl command, is thrown. A screenshot of a powered-off screen, for
///   one, blocks for 61 s before simctl gives up on its own.
/// - `deviceSet` makes every call address that `--set` folder instead of the
///   user's default set; tests always pass one.
/// - Arguments are refused when they hold a selector that resolves to "some"
///   or "every" device (`booted`, `booted_phone`, `all`, `unavailable`):
///   with several simulators booted, `booted` picks one arbitrarily, and the
///   default set is shared with Xcode, Device Hub and other tools. This also
///   refuses `privacy … reset all`; reset services one by one. The typed
///   calls exempt only the name a user chose (`create`, `rename`): a
///   simulator may be called "All".
/// - `DEVELOPER_DIR` is passed when `developerDirectory` is set. The `xcrun`
///   wrapper exports it before exec'ing the real binary, which Device Hub Pro calls
///   directly (`AppleToolchain`).
public final class SimctlClient: Sendable {
    public let simctlURL: URL
    public let deviceSet: URL?
    public let developerDirectory: URL?
    public let commandTimeout: Duration

    /// The default bound for one-shot calls.
    public static let defaultTimeout: Duration = .seconds(30)

    /// The bound for `bootstatus`: a first boot's data migration took 44 s on
    /// a loaded machine.
    public static let bootTimeout: Duration = .seconds(180)

    /// Selectors simctl resolves to an implicit set of devices. The next line
    /// is the only one in the Apple sources allowed to spell them
    /// (`AppleSourceGuardTests`).
    static let refusedSelectors: Set<String> = ["booted", "booted_phone", "booted_ipad", "booted_tv", "booted_watch", "booted_vision", "all", "unavailable"] // source-guard: refusal list

    public init(
        simctlURL: URL,
        deviceSet: URL? = nil,
        developerDirectory: URL? = nil,
        commandTimeout: Duration = SimctlClient.defaultTimeout
    ) {
        self.simctlURL = simctlURL
        self.deviceSet = deviceSet
        self.developerDirectory = developerDirectory
        self.commandTimeout = commandTimeout
    }

    // MARK: Argv

    /// The first refused selector in `arguments`, if any (case-insensitive).
    /// The positions in `freeText` are skipped.
    public static func refusedSelector(in arguments: [String], freeText: Set<Int> = []) -> String? {
        arguments.indices
            .first { !freeText.contains($0) && refusedSelectors.contains(arguments[$0].lowercased()) }
            .map { arguments[$0] }
    }

    /// The full argv for `arguments`: `--set <folder>` first when this client
    /// addresses a device set. Throws for a refused selector outside the
    /// `freeText` positions (a device name the user chose).
    public func commandLine(_ arguments: [String], freeText: Set<Int> = []) throws -> [String] {
        if let token = Self.refusedSelector(in: arguments, freeText: freeText) {
            throw SimctlClientError.refusedSelector(token)
        }
        guard let deviceSet else { return arguments }
        return ["--set", deviceSet.path] + arguments
    }

    /// The environment every simctl child gets on top of the app's own.
    public var environment: [String: String] {
        var environment: [String: String] = [:]
        if let developerDirectory {
            environment["DEVELOPER_DIR"] = developerDirectory.path
        }
        return environment
    }

    /// A simulator UDID is a UUID; a physical device's identifier is not, and
    /// neither is a selector or a device name.
    public static func validateUDID(_ udid: String) throws {
        guard UUID(uuidString: udid) != nil else {
            throw SimctlClientError.invalidUDID(udid)
        }
    }

    // MARK: Running

    /// Runs one simctl call and returns what it printed, whatever the exit
    /// status. `extraEnvironment` reaches simctl itself; variables prefixed
    /// `SIMCTL_CHILD_` are passed on to the booted or spawned process.
    public func run(
        _ arguments: [String],
        standardInput: Data? = nil,
        extraEnvironment: [String: String] = [:],
        timeout: Duration? = nil
    ) async throws -> SimctlOutput {
        try await run(
            arguments,
            freeText: [],
            standardInput: standardInput,
            extraEnvironment: extraEnvironment,
            timeout: timeout
        )
    }

    private func run(
        _ arguments: [String],
        freeText: Set<Int>,
        standardInput: Data?,
        extraEnvironment: [String: String],
        timeout: Duration?
    ) async throws -> SimctlOutput {
        let argv = try commandLine(arguments, freeText: freeText)
        let environment = self.environment.merging(extraEnvironment) { _, override in override }
        do {
            let result = try await ProcessRunner.run(
                executable: simctlURL,
                arguments: argv,
                standardInput: standardInput,
                environment: environment.isEmpty ? nil : environment,
                timeout: timeout ?? commandTimeout
            )
            return SimctlOutput(
                exitCode: result.exitCode,
                standardOutput: result.standardOutput,
                standardError: result.standardError
            )
        } catch ProcessRunnerError.timedOut(_, let seconds) {
            throw ProcessRunnerError.timedOut(
                command: (["simctl"] + arguments).joined(separator: " "),
                seconds: seconds
            )
        }
    }

    /// Runs one call and throws its decoded `SimctlFailure` on a non-zero exit.
    @discardableResult
    public func checked(
        _ arguments: [String],
        standardInput: Data? = nil,
        extraEnvironment: [String: String] = [:],
        timeout: Duration? = nil
    ) async throws -> SimctlOutput {
        try await checked(
            arguments,
            freeText: [],
            standardInput: standardInput,
            extraEnvironment: extraEnvironment,
            timeout: timeout
        )
    }

    /// `checked` with argument positions that hold free text (a name, a
    /// value), exempt from the selector refusal.
    @discardableResult
    func checked(
        _ arguments: [String],
        freeText: Set<Int>,
        standardInput: Data? = nil,
        extraEnvironment: [String: String] = [:],
        timeout: Duration? = nil
    ) async throws -> SimctlOutput {
        let output = try await run(
            arguments,
            freeText: freeText,
            standardInput: standardInput,
            extraEnvironment: extraEnvironment,
            timeout: timeout
        )
        guard output.exitCode == 0 else {
            throw SimctlErrors.failure(
                arguments: arguments,
                exitCode: output.exitCode,
                standardError: output.standardErrorText
            )
        }
        return output
    }

    // MARK: Catalog

    public func listDevices() async throws -> [SimulatorDevice] {
        let output = try await checked(["list", "-j", "devices"])
        return try SimctlParsing.devices(fromListJSON: output.standardOutput)
    }

    public func listRuntimes() async throws -> [SimulatorRuntime] {
        let output = try await checked(["list", "-j", "runtimes"])
        return try SimctlParsing.runtimes(fromListJSON: output.standardOutput)
    }

    public func listDeviceTypes() async throws -> [SimulatorDeviceType] {
        let output = try await checked(["list", "-j", "devicetypes"])
        return try SimctlParsing.deviceTypes(fromListJSON: output.standardOutput)
    }

    // MARK: Lifecycle

    /// Creates a device and returns its UDID.
    public func create(
        name: String,
        deviceTypeIdentifier: String,
        runtimeIdentifier: String
    ) async throws -> String {
        let arguments = ["create", name, deviceTypeIdentifier, runtimeIdentifier]
        let output = try await checked(arguments, freeText: [1])
        guard let udid = SimctlParsing.createdUDID(from: output.standardOutputText) else {
            throw SimctlClientError.unexpectedOutput(
                command: "simctl create",
                detail: output.standardOutputText
            )
        }
        return udid
    }

    /// Starts booting a device. simctl returns about a second in, long
    /// before the device is usable; follow with `bootStatus`. The time zone
    /// of the boot session comes from `timeZone` (`SIMCTL_CHILD_TZ`), since
    /// simctl has no time-zone command.
    public func boot(udid: String, timeZone: String? = nil) async throws {
        try Self.validateUDID(udid)
        var environment: [String: String] = [:]
        if let timeZone {
            environment["SIMCTL_CHILD_TZ"] = timeZone
        }
        try await checked(["boot", udid], extraEnvironment: environment)
    }

    /// Follows `bootstatus` until the device reports Finished (or the call
    /// fails), handing every update to `onUpdate` as it arrives. With
    /// `bootIfNeeded` a shut-down device is booted first. Returns the last
    /// update, or nil when simctl reported none: a device whose boot had
    /// already finished prints only "Device already booted, nothing to do."
    /// and exits 0. Without `bootIfNeeded` a shut-down device makes simctl
    /// wait silently for someone to boot it, until `timeout` (measured on
    /// Xcode 27.0: no output at all after 4 s).
    @discardableResult
    public func bootStatus(
        udid: String,
        bootIfNeeded: Bool = false,
        timeout: Duration = SimctlClient.bootTimeout,
        onUpdate: @escaping @Sendable (SimulatorBootStatus) -> Void = { _ in }
    ) async throws -> SimulatorBootStatus? {
        try Self.validateUDID(udid)
        var arguments = ["bootstatus", udid]
        if bootIfNeeded {
            arguments.append("-b")
        }
        let argv = try commandLine(arguments)
        let collector = BootStatusCollector(onUpdate: onUpdate)
        let executable = simctlURL
        let environment = self.environment
        let exitCode = try await Self.withTimeout(timeout, command: "simctl bootstatus \(udid)") {
            try await ProcessRunner.stream(
                executable: executable,
                arguments: argv,
                environment: environment,
                onLine: { collector.consume($0) }
            )
        }
        collector.finish()
        guard exitCode == 0 else {
            throw SimctlErrors.failure(
                arguments: arguments,
                exitCode: exitCode,
                standardError: collector.unparsedText
            )
        }
        return collector.last
    }

    /// Clone, erase and delete copy or remove a device's data: far past the
    /// default timeout on a large device, and killing simctl midway leaves
    /// a half-made or half-erased device.
    static let longOperationTimeout: Duration = .seconds(300)
    /// A shutdown can wait on a busy simulator for a while.
    static let shutdownTimeout: Duration = .seconds(60)

    public func shutdown(udid: String) async throws {
        try Self.validateUDID(udid)
        try await checked(["shutdown", udid], timeout: Self.shutdownTimeout)
    }

    /// Erases content and settings. simctl refuses a booted device
    /// (`SimctlFailure.Kind.invalidState`).
    public func erase(udid: String) async throws {
        try Self.validateUDID(udid)
        try await checked(["erase", udid], timeout: Self.longOperationTimeout)
    }

    /// Deletes the device. simctl leaves `~/Library/Logs/CoreSimulator/<UDID>`
    /// behind; removing it is the caller's call.
    public func delete(udid: String) async throws {
        try Self.validateUDID(udid)
        try await checked(["delete", udid], timeout: Self.longOperationTimeout)
    }

    /// Renames the device; simctl renames a booted device too.
    public func rename(udid: String, to name: String) async throws {
        try Self.validateUDID(udid)
        try await checked(["rename", udid, name], freeText: [2])
    }

    /// Clones a shut-down device under `name` and returns the clone's UDID.
    /// The clone copies all content and settings. simctl refuses a booted
    /// device (`SimctlFailure.Kind.invalidState`, "Unable to clone device in
    /// current state: Booted").
    public func clone(udid: String, name: String) async throws -> String {
        try Self.validateUDID(udid)
        let output = try await checked(["clone", udid, name], freeText: [2], timeout: Self.longOperationTimeout)
        guard let clone = SimctlParsing.createdUDID(from: output.standardOutputText) else {
            throw SimctlClientError.unexpectedOutput(
                command: "simctl clone",
                detail: output.standardOutputText
            )
        }
        return clone
    }

    /// The device's launchd jobs (`spawn <udid> launchctl list`), which name
    /// the running SpringBoard (`SimulatorReadiness`). A device that is not
    /// booted fails with `SimctlFailure.Kind.invalidState` ("Process spawn
    /// via launchd failed because device is not booted.").
    public func launchdJobs(udid: String) async throws -> [SimulatorLaunchdJob] {
        try Self.validateUDID(udid)
        let output = try await checked(["spawn", udid, "launchctl", "list"])
        return SimctlParsing.launchdJobs(fromLaunchctlList: output.standardOutputText)
    }

    // MARK: Apps

    public func listApps(udid: String) async throws -> [SimulatorApp] {
        try Self.validateUDID(udid)
        let output = try await checked(["listapps", udid])
        return try SimctlParsing.apps(fromListApps: output.standardOutputText)
    }

    /// `listApps` plus the apps Device Hub lists and `listapps` leaves out
    /// (`SimulatorRuntimeApps`: the launch-prohibited system apps), each read
    /// with `appinfo`. One that `appinfo` does not answer for is skipped.
    public func listAllApps(udid: String) async throws -> [SimulatorApp] {
        let listed = try await listApps(udid: udid)
        let missing = SimulatorRuntimeApps.missingIdentifiers(from: listed)
        guard !missing.isEmpty else { return listed }
        let extra = await withTaskGroup(of: SimulatorApp?.self) { group in
            for identifier in missing {
                group.addTask { try? await self.appInfo(udid: udid, bundleIdentifier: identifier) }
            }
            var found: [SimulatorApp] = []
            for await app in group { if let app { found.append(app) } }
            return found
        }
        return listed + extra
    }

    public func appInfo(udid: String, bundleIdentifier: String) async throws -> SimulatorApp {
        try Self.validateUDID(udid)
        let output = try await checked(["appinfo", udid, bundleIdentifier])
        return try SimctlParsing.app(fromAppInfo: output.standardOutputText)
    }

    public enum AppContainer: String, Sendable {
        /// The `.app` bundle.
        case app
        /// The app's data container.
        case data
    }

    /// The host path of an app's bundle or data container.
    public func appContainerPath(
        udid: String,
        bundleIdentifier: String,
        container: AppContainer
    ) async throws -> String {
        try Self.validateUDID(udid)
        let output = try await checked(["get_app_container", udid, bundleIdentifier, container.rawValue])
        let path = output.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        // An app with no data container (a system app that never wrote one)
        // makes simctl exit 0 and print "(null)", measured on Xcode 27.0.
        guard !path.isEmpty, path != "(null)" else {
            throw SimctlClientError.unexpectedOutput(
                command: "simctl get_app_container \(container.rawValue)",
                detail: "\(bundleIdentifier) has no \(container.rawValue) container"
            )
        }
        return path
    }

    /// The app's App Group containers. The documented `<group identifier>`
    /// form fails with a usage error on Xcode 27.0, so the list is read with
    /// `groups` and picked from here.
    public func groupContainers(udid: String, bundleIdentifier: String) async throws -> [SimulatorGroupContainer] {
        try Self.validateUDID(udid)
        let output = try await checked(["get_app_container", udid, bundleIdentifier, "groups"])
        return SimctlParsing.groupContainers(from: output.standardOutputText)
    }

    /// Launches an app and returns its pid. Launching an app that already
    /// runs returns the running pid without a relaunch unless
    /// `terminateRunning` is set.
    @discardableResult
    public func launch(udid: String, bundleIdentifier: String, terminateRunning: Bool = false) async throws -> Int {
        try Self.validateUDID(udid)
        var arguments = ["launch"]
        if terminateRunning {
            arguments.append("--terminate-running-process")
        }
        arguments += [udid, bundleIdentifier]
        let output = try await checked(arguments)
        guard let pid = SimctlParsing.launchedPID(from: output.standardOutputText) else {
            throw SimctlClientError.unexpectedOutput(command: "simctl launch", detail: output.standardOutputText)
        }
        return pid
    }

    /// Launches an app with arguments, environment variables
    /// (`SIMCTL_CHILD_<KEY>`) and the debugger / terminate flags
    /// (`SimulatorLaunchOptions`), and returns its pid.
    @discardableResult
    public func launch(
        udid: String,
        bundleIdentifier: String,
        options: SimulatorLaunchOptions
    ) async throws -> Int {
        try Self.validateUDID(udid)
        for variable in options.environment {
            if let problem = SimulatorLaunchOptions.validate(key: variable.key, value: variable.value) { throw problem }
        }
        let command = options.commandArguments(udid: udid, bundleIdentifier: bundleIdentifier)
        let output = try await checked(
            command.arguments,
            freeText: command.freeText,
            extraEnvironment: options.simctlEnvironment
        )
        guard let pid = SimctlParsing.launchedPID(from: output.standardOutputText) else {
            throw SimctlClientError.unexpectedOutput(command: "simctl launch", detail: output.standardOutputText)
        }
        return pid
    }

    /// Terminates a running app. An app that is not running fails with
    /// `SimctlFailure.Kind.notFound`.
    public func terminate(udid: String, bundleIdentifier: String) async throws {
        try Self.validateUDID(udid)
        try await checked(["terminate", udid, bundleIdentifier])
    }

    // MARK: ui

    public func appearance(udid: String) async throws -> SimulatorAppearance {
        let text = try await uiGet(udid: udid, option: "appearance")
        guard let value = SimctlParsing.appearance(from: text) else {
            throw SimctlClientError.unexpectedOutput(command: "simctl ui appearance", detail: text)
        }
        return value
    }

    public func setAppearance(udid: String, _ appearance: SimulatorAppearance) async throws {
        guard appearance == .light || appearance == .dark else {
            throw SimctlClientError.invalidValue("appearance \(appearance.rawValue) cannot be set")
        }
        try await uiSet(udid: udid, option: "appearance", value: appearance.rawValue)
    }

    public func increaseContrast(udid: String) async throws -> SimulatorIncreaseContrast {
        let text = try await uiGet(udid: udid, option: "increase_contrast")
        guard let value = SimctlParsing.increaseContrast(from: text) else {
            throw SimctlClientError.unexpectedOutput(command: "simctl ui increase_contrast", detail: text)
        }
        return value
    }

    public func setIncreaseContrast(udid: String, enabled: Bool) async throws {
        try await uiSet(udid: udid, option: "increase_contrast", value: enabled ? "enabled" : "disabled")
    }

    public func contentSize(udid: String) async throws -> SimulatorContentSize {
        let text = try await uiGet(udid: udid, option: "content_size")
        guard let value = SimctlParsing.contentSize(from: text) else {
            throw SimctlClientError.unexpectedOutput(command: "simctl ui content_size", detail: text)
        }
        return value
    }

    public func setContentSize(udid: String, _ size: SimulatorContentSize) async throws {
        guard SimulatorContentSize.settable.contains(size) else {
            throw SimctlClientError.invalidValue("content size \(size.rawValue) cannot be set")
        }
        try await uiSet(udid: udid, option: "content_size", value: size.rawValue)
    }

    private func uiGet(udid: String, option: String) async throws -> String {
        try Self.validateUDID(udid)
        let arguments = ["ui", udid, option]
        let output = try await run(arguments)
        if let failure = SimctlErrors.uiFailure(
            arguments: arguments,
            exitCode: output.exitCode,
            standardError: output.standardErrorText
        ) {
            throw failure
        }
        return output.standardOutputText
    }

    private func uiSet(udid: String, option: String, value: String) async throws {
        try Self.validateUDID(udid)
        let arguments = ["ui", udid, option, value]
        let output = try await run(arguments)
        if let failure = SimctlErrors.uiFailure(
            arguments: arguments,
            exitCode: output.exitCode,
            standardError: output.standardErrorText
        ) {
            throw failure
        }
    }

    // MARK: status_bar

    public func statusBarOverrides(udid: String) async throws -> SimulatorStatusBarOverrides {
        try Self.validateUDID(udid)
        let output = try await checked(["status_bar", udid, "list"])
        return SimctlParsing.statusBarOverrides(from: output.standardOutputText)
    }

    public func clearStatusBar(udid: String) async throws {
        try Self.validateUDID(udid)
        try await checked(["status_bar", udid, "clear"])
    }

    // MARK: location

    /// The predefined scenarios `location <udid> run` accepts.
    public func locationScenarios(udid: String) async throws -> [SimulatorLocationScenario] {
        try Self.validateUDID(udid)
        let output = try await checked(["location", udid, "list"])
        return SimctlParsing.locationScenarios(from: output.standardOutputText)
    }

    /// Sets the simulated location. simctl accepts any pair (`999,999`
    /// exits 0) and offers no read-back, so the range is checked here and the
    /// value is the caller's to remember.
    public func setLocation(udid: String, latitude: Double, longitude: Double) async throws {
        try Self.validateUDID(udid)
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw SimctlClientError.invalidValue("location \(latitude),\(longitude) is out of range")
        }
        let pair = String(format: "%.6f,%.6f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
        try await checked(["location", udid, "set", pair])
    }

    // MARK: pasteboard and notifications

    /// Puts `text` on the simulator's pasteboard (`pbcopy`). simctl reads its
    /// standard input in the C locale's encoding unless told otherwise
    /// (measured: without a UTF-8 `LANG`, "ş" came back from `pbpaste` as
    /// MacRoman mojibake), so the call runs with `LANG=en_US.UTF-8`.
    public func setPasteboard(udid: String, text: String) async throws {
        try Self.validateUDID(udid)
        try await checked(["pbcopy", udid], standardInput: Data(text.utf8), extraEnvironment: Self.utf8Environment)
    }

    /// The simulator pasteboard's text (`pbpaste`), decoded as UTF-8.
    public func pasteboard(udid: String) async throws -> String {
        try Self.validateUDID(udid)
        let output = try await checked(["pbpaste", udid], extraEnvironment: Self.utf8Environment)
        return output.standardOutputText
    }

    /// The Darwin notification the simulator's pasteboard server posts on
    /// every change of the general pasteboard: measured on iOS 27.0 (Xcode
    /// 27.0, 2026-09-26) for a host `pbcopy`, once per copy, while
    /// `com.apple.pasteboard.changed`, `…general.changed` and
    /// `com.apple.UIKit.pboard.changed` stayed silent.
    public static let pasteboardChangedNotification = "com.apple.pasteboard.notify.changed"

    /// Follows a Darwin notification inside the simulator until the calling
    /// task is cancelled (`spawn <udid> notifyutil -w <name>`, which prints
    /// the name once per post; cancelling stops simctl, whose spawned
    /// notifyutil ends with it). `onPost` runs once per post, on the reader
    /// thread. Returns simctl's exit status when it ends on its own (the
    /// simulator shut down); a cancel throws `CancellationError`.
    public func watchDarwinNotification(
        udid: String,
        name: String,
        onPost: @escaping @Sendable () -> Void
    ) async throws -> Int32 {
        try Self.validateUDID(udid)
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains(where: \.isWhitespace) else {
            throw SimctlClientError.invalidValue("notification name '\(name)'")
        }
        let argv = try commandLine(["spawn", udid, "notifyutil", "-w", name])
        return try await ProcessRunner.stream(
            executable: simctlURL,
            arguments: argv,
            environment: environment,
            onLine: { line in
                // stderr shares the reader: "Child process terminated with
                // signal 15" when stopped, "getpwuid_r …" noise.
                if line.trimmingCharacters(in: .whitespaces) == name {
                    onPost()
                }
            }
        )
    }

    /// Posts a Darwin notification inside the simulator
    /// (`spawn <udid> notifyutil -p <name>`).
    public func postDarwinNotification(udid: String, name: String) async throws {
        try Self.validateUDID(udid)
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains(where: \.isWhitespace) else {
            throw SimctlClientError.invalidValue("notification name '\(name)'")
        }
        try await checked(["spawn", udid, "notifyutil", "-p", name])
    }

    /// A Darwin notification's state inside the simulator (`spawn <udid>
    /// notifyutil -g <name>`): for instance
    /// `SimulatorHardwareActions.dtuhiddActiveNotification`, which dtuhidd
    /// sets to 1 for the rest of the boot once a client connected. Reading
    /// changes nothing.
    public func notifyState(udid: String, name: String) async throws -> UInt64 {
        try Self.validateUDID(udid)
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains(where: \.isWhitespace) else {
            throw SimctlClientError.invalidValue("notification name '\(name)'")
        }
        let output = try await checked(["spawn", udid, "notifyutil", "-g", name])
        guard let state = SimctlParsing.notifyState(fromNotifyutilOutput: output.standardOutputText, name: name) else {
            throw SimctlClientError.unexpectedOutput(command: "simctl spawn notifyutil -g", detail: output.standardOutputText)
        }
        return state
    }

    private static let utf8Environment = ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]

    // MARK: io

    /// Writes a PNG screenshot of the main display to `destination`
    /// (`io <udid> screenshot`). A powered-off screen blocks simctl for 61 s,
    /// so pass a `timeout` below that when the screen may be off.
    public func screenshot(udid: String, to destination: URL, timeout: Duration? = nil) async throws {
        try Self.validateUDID(udid)
        try await checked(["io", udid, "screenshot", "--type=png", destination.path], timeout: timeout)
    }

    public enum VideoCodec: String, Sendable {
        /// simctl's default: `hvc1`.
        case hevc
        /// `avc1`, for players without HEVC.
        case h264
    }

    /// Records the screen into `destination` (a new file) until the calling
    /// task is cancelled, then returns once the movie is complete.
    ///
    /// simctl writes the movie's index only when it is interrupted, the way
    /// Ctrl-C stops it in a terminal, so the child is stopped with SIGINT
    /// (`ProcessStopSignal.interrupt`); SIGTERM would leave an unplayable
    /// file. Finalising took 10–20 ms in the spike; a recorder that ignores
    /// the interrupt is SIGKILLed after `ProcessRunner.terminationGracePeriod`.
    /// `onStarted` runs when simctl reports `Recording started` on stderr
    /// (at the first frame, about 0.35 s in). A recording that ends on its own
    /// with a failure (an invalid device or argument) throws its
    /// `SimctlFailure`; the device shutting down does not end it (measured
    /// 2026-09-26: simctl recorded on until interrupted). A stopped one
    /// throws `SimctlClientError.incompleteRecording` when simctl was
    /// SIGKILLed, had not reported `Recording started`, or left no file.
    /// simctl's exit status after the interrupt (0, measured 2026-09-26 on a
    /// running and on a shut-down simulator) is not judged.
    public func recordVideo(
        udid: String,
        to destination: URL,
        codec: VideoCodec = .hevc,
        onStarted: @escaping @Sendable () -> Void = {}
    ) async throws {
        try Self.validateUDID(udid)
        let arguments = ["io", udid, "recordVideo", "--codec=\(codec.rawValue)", destination.path]
        let argv = try commandLine(arguments)
        let transcript = RecordingTranscript()
        let exitCode: Int32
        do {
            exitCode = try await ProcessRunner.stream(
                executable: simctlURL,
                arguments: argv,
                environment: environment,
                stopSignal: .interrupt,
                onExit: { transcript.recordExit($0) },
                onLine: { line in
                    if transcript.append(line) {
                        onStarted()
                    }
                }
            )
        } catch is CancellationError {
            // The way a recording ends: the stream returns only after simctl
            // exited, so the movie is final unless one of these holds.
            if let exit = transcript.exit, exit.signaled, exit.status == SIGKILL {
                throw SimctlClientError.incompleteRecording("simctl ignored the interrupt and was killed")
            }
            guard transcript.hasStarted else {
                throw SimctlClientError.incompleteRecording("stopped before simctl reported Recording started")
            }
            guard FileManager.default.fileExists(atPath: destination.path) else {
                throw SimctlClientError.incompleteRecording("simctl wrote no file at \(destination.path)")
            }
            return
        }
        guard exitCode != 0 else { return }
        throw SimctlErrors.failure(arguments: arguments, exitCode: exitCode, standardError: transcript.text)
    }

    // MARK: Helpers

    /// Runs `body`, cancelling it (which terminates its child) once `timeout`
    /// elapses, and throws the typed timeout naming `command`.
    static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        command: String,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProcessRunnerError.timedOut(command: command, seconds: timeout)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ProcessRunnerError.timedOut(command: command, seconds: timeout)
            }
            return result
        }
    }
}

/// Collects a streamed `bootstatus` run: parsed updates go to the caller as
/// they complete; lines that are not part of an update are kept as the
/// failure text.
private final class BootStatusCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = SimulatorBootStatusParser()
    private var lastUpdate: SimulatorBootStatus?
    private var unparsed: [String] = []
    private let onUpdate: @Sendable (SimulatorBootStatus) -> Void

    init(onUpdate: @escaping @Sendable (SimulatorBootStatus) -> Void) {
        self.onUpdate = onUpdate
    }

    func consume(_ line: String) {
        lock.lock()
        let updates = parser.consume(line)
        if updates.isEmpty,
           !line.hasPrefix("\t"),
           !line.hasPrefix("["),
           !line.hasPrefix("Monitoring boot status"),
           !line.trimmingCharacters(in: .whitespaces).isEmpty {
            unparsed.append(line)
        }
        if let last = updates.last {
            lastUpdate = last
        }
        lock.unlock()
        updates.forEach(onUpdate)
    }

    func finish() {
        lock.lock()
        let updates = parser.finish()
        if let last = updates.last {
            lastUpdate = last
        }
        lock.unlock()
        updates.forEach(onUpdate)
    }

    var last: SimulatorBootStatus? {
        lock.lock()
        defer { lock.unlock() }
        return lastUpdate
    }

    var unparsedText: String {
        lock.lock()
        defer { lock.unlock() }
        return unparsed.joined(separator: "\n")
    }
}

/// What a running `recordVideo` printed (simctl reports progress and errors
/// on stderr) and how it ended; `append` reports the `Recording started`
/// line once.
private final class RecordingTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var started = false
    private var recordedExit: ProcessExit?

    /// Returns true for the first `Recording started` line.
    func append(_ line: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
        guard !started, line.contains("Recording started") else { return false }
        started = true
        return true
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func recordExit(_ exit: ProcessExit) {
        lock.lock()
        recordedExit = exit
        lock.unlock()
    }

    var exit: ProcessExit? {
        lock.lock()
        defer { lock.unlock() }
        return recordedExit
    }
}
