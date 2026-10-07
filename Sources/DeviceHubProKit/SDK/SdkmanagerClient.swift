import Foundation

public enum SdkmanagerError: Error, CustomStringConvertible {
    case javaNotFound
    case licenseDeclined(String)
    case cancelled
    case commandFailed(String)

    public var description: String {
        switch self {
        case .javaNotFound:
            return "Java is required to download SDK components but no working runtime was found."
        case .licenseDeclined(let package):
            return "The license for \(package) was declined; nothing was installed."
        case .cancelled:
            return "The download was cancelled."
        case .commandFailed(let reason):
            return reason
        }
    }
}

/// Lists and installs SDK packages through the SDK's `sdkmanager` (requires
/// Java, resolved through the same candidates `avdmanager` uses).
///
/// `install` streams the tool's output: each percentage it reports reaches
/// `onProgress` (after a first `nil` marking "not known yet"), and license
/// prompts reach `onLicense`, whose answer is written back to the tool's
/// stdin. The per-license prompts are written without a line terminator, so
/// they are detected from the partial output as it arrives. `cancel`
/// terminates the running install; one install runs at a time.
/// What one `sdkmanager --list` offers that the app uses.
public struct SdkmanagerListing: Sendable, Equatable {
    public let images: [SystemImage]
    /// The version of the `emulator` package under Available Packages.
    public let emulatorVersion: String?
}

public struct SdkmanagerClient: Sendable {
    public let sdkmanagerURL: URL
    private let javaURL: URL?
    /// The SDK the tool manages, passed as `--sdk_root`; nil lets the tool
    /// infer it from where it is installed.
    private let sdkRoot: URL?
    private let environment: [String: String]
    /// Bound for `--list`, which reads the repository over the network.
    private let listTimeout: Duration
    /// How long an install may print nothing before it is given up on.
    private let installIdleTimeout: Duration
    private let session = InstallSession()

    /// What an install that went quiet fails with.
    public static let stalledMessage = "No progress for 90 s. Check your internet connection."

    public init(
        sdkmanagerURL: URL,
        javaURL: URL? = nil,
        sdkRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        listTimeout: Duration = .seconds(180),
        installIdleTimeout: Duration = .seconds(90)
    ) {
        self.listTimeout = listTimeout
        self.installIdleTimeout = installIdleTimeout
        self.sdkmanagerURL = sdkmanagerURL
        self.javaURL = javaURL
        self.sdkRoot = sdkRoot
        self.environment = environment
    }

    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SdkmanagerClient? {
        guard let sdkmanagerURL = AvdmanagerLocator.locateSdkmanager(environment: environment) else {
            return nil
        }
        return SdkmanagerClient(sdkmanagerURL: sdkmanagerURL, environment: environment)
    }

    /// Runs `sdkmanager --list` and returns the system images it offers.
    /// Installed images keep coming from the on-disk scan.
    public func listAvailableImages() async throws -> [SystemImage] {
        SdkmanagerParsing.availableImages(fromListOutput: try await listOutput())
    }

    /// Runs `sdkmanager --list` once and returns the system images and the
    /// newest `emulator` package it offers.
    public func listAvailable() async throws -> SdkmanagerListing {
        let output = try await listOutput()
        return SdkmanagerListing(
            images: SdkmanagerParsing.availableImages(fromListOutput: output),
            emulatorVersion: SdkmanagerParsing.availableVersion(of: "emulator", fromListOutput: output)
        )
    }

    private func listOutput() async throws -> String {
        let environment = try await javaEnvironment()
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: sdkmanagerURL,
                arguments: baseArguments + ["--list"],
                environment: environment,
                timeout: listTimeout
            )
        } catch is CancellationError {
            throw SdkmanagerError.cancelled
        } catch let error as ProcessRunnerError {
            throw SdkmanagerError.commandFailed("sdkmanager --list could not finish: \(error)")
        } catch {
            throw SdkmanagerError.commandFailed(
                "sdkmanager --list could not run: \(error.localizedDescription)"
            )
        }
        guard result.exitCode == 0 else {
            throw SdkmanagerError.commandFailed(
                Self.failureMessage(
                    command: "sdkmanager --list",
                    exitCode: result.exitCode,
                    output: result.standardOutputText,
                    error: result.standardErrorText
                )
            )
        }
        return result.standardOutputText
    }

    /// Installs one package, answering license prompts through `onLicense`.
    ///
    /// `onProgress` is called with `nil` once when the install starts, then
    /// with each parsed percentage as 0…1. `onLicense` receives the license
    /// text and its answer is fed to the tool; returning false declines the
    /// license and `licenseDeclined` is thrown once the tool stops. A
    /// non-zero tool exit throws `commandFailed` with the tool's last output.
    public func install(
        package: String,
        onProgress: @Sendable @escaping (Double?) -> Void,
        onLicense: @Sendable @escaping (String) -> Bool
    ) async throws {
        onProgress(nil)
        session.prepare()
        let task = Task {
            do {
                let environment = try await self.javaEnvironment()
                try Task.checkCancellation()
                do {
                    try await self.performInstall(
                        package: package,
                        argument: package,
                        environment: environment,
                        onProgress: onProgress,
                        onLicense: onLicense
                    )
                } catch SdkmanagerError.commandFailed(let message)
                    where Self.isUnknownPackage(message) && package.contains(";") {
                    // cmdline-tools 23 (the Android CLI shim) may name packages with `/`.
                    try await self.performInstall(
                        package: package,
                        argument: Self.slashForm(of: package),
                        environment: environment,
                        onProgress: onProgress,
                        onLicense: onLicense
                    )
                }
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw error
            }
        }
        session.begin(task)
        defer { session.finish() }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            throw SdkmanagerError.cancelled
        }
    }

    private var baseArguments: [String] {
        sdkRoot.map { ["--sdk_root=\($0.path)"] } ?? []
    }

    /// Terminates the install started by `install`, if any.
    public func cancel() {
        session.cancel()
    }

    /// Removes an installed package with `sdkmanager --uninstall <package>`.
    ///
    /// sdkmanager exits 0 even when it cannot find the package (it only
    /// prints `Warning: Unable to find package …`), which usually means it
    /// manages a different SDK than the one scanned; that is reported as
    /// `commandFailed` rather than as a successful removal. When `sdkRoot` is
    /// given, the package must also be gone from it afterwards
    /// (`SdkPackageStorage.isInstalled`). AVDs built on a removed system
    /// image stop booting — `AvdConfig.avdNames(usingSystemImage:)` lists
    /// them for the confirmation. Cancelling the calling task terminates the
    /// tool and throws `cancelled`.
    public func uninstall(package: String, sdkRoot: URL? = nil) async throws {
        guard Self.isPackagePath(package) else {
            throw SdkmanagerError.commandFailed("\"\(package)\" is not an SDK package path.")
        }
        do {
            try await runUninstall(package: package, argument: package, sdkRoot: sdkRoot)
        } catch SdkmanagerError.commandFailed(let message)
            where Self.isUnknownPackage(message) && package.contains(";") {
            // cmdline-tools 23 (the Android CLI shim) may name packages with `/`.
            try await runUninstall(package: package, argument: Self.slashForm(of: package), sdkRoot: sdkRoot)
        }
    }

    private func runUninstall(package: String, argument: String, sdkRoot: URL?) async throws {
        let environment = try await javaEnvironment()
        let command = "sdkmanager --uninstall \(package)"
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: sdkmanagerURL,
                arguments: baseArguments + ["--uninstall", argument],
                environment: environment
            )
        } catch is CancellationError {
            throw SdkmanagerError.cancelled
        } catch {
            throw SdkmanagerError.commandFailed(
                "\(command) could not run: \(error.localizedDescription)"
            )
        }
        let output = String(decoding: result.standardOutput, as: UTF8.self)
        let errorOutput = String(decoding: result.standardError, as: UTF8.self)
        guard result.exitCode == 0 else {
            throw SdkmanagerError.commandFailed(
                Self.failureMessage(
                    command: command,
                    exitCode: result.exitCode,
                    output: Self.readableLines(of: output),
                    error: Self.readableLines(of: errorOutput)
                )
            )
        }
        if (output + errorOutput).range(of: "Unable to find package", options: .caseInsensitive) != nil {
            throw SdkmanagerError.commandFailed(
                "sdkmanager did not find \(package) in the SDK it manages; nothing was removed."
            )
        }
        if let sdkRoot, SdkPackageStorage.isInstalled(package: package, sdkRoot: sdkRoot) {
            throw SdkmanagerError.commandFailed(
                "\(command) finished, but \(package) is still installed in \(sdkRoot.path)."
            )
        }
    }

    /// Whether `package` is an sdkmanager package path
    /// (`system-images;android-35;google_apis;arm64-v8a`, `platforms;android-35`,
    /// `build-tools;35.0.0`): `;`-separated segments of letters, digits, `.`,
    /// `_` and `-`, never starting with `-` (the tool would read it as an
    /// option).
    public static func isPackagePath(_ package: String) -> Bool {
        guard !package.isEmpty, !package.hasPrefix("-") else { return false }
        let segments = package.split(separator: ";", omittingEmptySubsequences: false)
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber || "._-".contains(character))
            }
        }
    }

    /// The tool's output without its `\r` progress redraws and blank lines,
    /// for error messages.
    private static func readableLines(of output: String) -> String {
        output
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && SdkmanagerParsing.progress(from: $0) == nil }
            .joined(separator: "\n")
    }

    private func javaEnvironment() async throws -> [String: String] {
        guard let resolved = await AvdmanagerLocator.javaHomeEnvironment(
            environment: environment,
            preferred: javaURL
        ) else {
            throw SdkmanagerError.javaNotFound
        }
        return resolved
    }

    /// A package path in the `/` form cmdline-tools 23 lists
    /// (`system-images/android-35/google_apis/arm64-v8a`).
    static func slashForm(of package: String) -> String {
        package.replacingOccurrences(of: ";", with: "/")
    }

    /// Whether tool output says the package path was not recognised.
    static func isUnknownPackage(_ text: String) -> Bool {
        ["unable to find package", "failed to find package", "unknown package", "could not find package", "did not find"]
            .contains { text.range(of: $0, options: .caseInsensitive) != nil }
    }

    private func performInstall(
        package: String,
        argument: String,
        environment: [String: String],
        onProgress: @Sendable @escaping (Double?) -> Void,
        onLicense: @Sendable @escaping (String) -> Bool
    ) async throws {
        let output = InstallOutput()
        let clock = ActivityClock()
        let idleTimeout = installIdleTimeout
        let pollInterval = max(Duration.milliseconds(50), min(Duration.seconds(1), idleTimeout / 4))
        let exitCode: Int32? = try await withThrowingTaskGroup(of: Int32?.self) { group in
            group.addTask {
                try await ProcessRunner.stream(
                    executable: self.sdkmanagerURL,
                    arguments: self.baseArguments + [argument],
                    environment: environment,
                    onStdinReady: { stdin in self.session.attach(stdin) },
                    partialLineHandler: { pending in
                        clock.touch()
                        return Self.isLicensePromptAtEnd(of: pending)
                    },
                    onLine: { line in
                        clock.touch()
                        switch output.consume(line) {
                        case .progress(let value):
                            onProgress(value)
                        case .license(let text):
                            // The user may take minutes to read the license:
                            // that silence is not a stall.
                            clock.pause()
                            let accepted = output.wasDeclined ? false : onLicense(text)
                            clock.resume()
                            if !accepted {
                                output.markDeclined()
                            }
                            self.session.stdin?.write(accepted ? "y\n" : "n\n")
                        case .none:
                            break
                        }
                    }
                )
            }
            group.addTask {
                while true {
                    try? await Task.sleep(for: pollInterval)
                    // Cancelled because the tool ended (or the user cancelled).
                    if Task.isCancelled { return nil }
                    if clock.hasBeenIdle(for: idleTimeout) {
                        clock.markStalled()
                        return nil
                    }
                }
            }
            var code: Int32?
            do {
                for try await result in group {
                    if let result { code = result }
                    // Either the tool ended, or the watchdog fired and the
                    // cancel terminates the tool.
                    group.cancelAll()
                }
            } catch is CancellationError {
                if !clock.stalled { throw CancellationError() }
            }
            return code
        }
        if clock.stalled, !output.wasDeclined {
            throw SdkmanagerError.commandFailed(Self.stalledMessage)
        }
        guard let exitCode else { throw CancellationError() }
        if output.wasDeclined {
            throw SdkmanagerError.licenseDeclined(package)
        }
        guard exitCode == 0 else {
            throw SdkmanagerError.commandFailed(
                Self.failureMessage(
                    command: "sdkmanager \(package)",
                    exitCode: exitCode,
                    output: output.tailText,
                    error: ""
                )
            )
        }
    }

    /// A license prompt is any `(y/N)` question; the real tool writes both
    /// the newline-terminated `Review licenses… (y/N)?` gate and the
    /// unterminated `Accept? (y/N):` form.
    fileprivate static func isLicensePrompt(_ text: String) -> Bool {
        text.range(of: #"\(y\s*/\s*n\)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The same test for the partial (unterminated) output a prompt can be
    /// held in: the prompt must end the pending bytes, so ordinary chatter
    /// mentioning `(y/N)` mid-line is not mistaken for one.
    fileprivate static func isLicensePromptAtEnd(of pending: String) -> Bool {
        pending.range(
            of: #"\(y\s*/\s*n\)\s*\??\s*:?\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func failureMessage(
        command: String,
        exitCode: Int32,
        output: String,
        error: String
    ) -> String {
        let detail = [output, error]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let header = "\(command) failed with exit code \(exitCode)."
        return detail.isEmpty ? header : header + "\n" + detail
    }
}

/// When an install last printed anything, so a watchdog can tell a stalled
/// download from a slow one. A license question waiting on the user pauses
/// it.
private final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ContinuousClock.now
    private var pauses = 0
    private var stalledFlag = false

    func touch() {
        lock.lock()
        last = .now
        lock.unlock()
    }

    func pause() {
        lock.lock()
        pauses += 1
        lock.unlock()
    }

    func resume() {
        lock.lock()
        pauses -= 1
        last = .now
        lock.unlock()
    }

    func hasBeenIdle(for timeout: Duration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pauses == 0 && ContinuousClock.now - last > timeout
    }

    func markStalled() {
        lock.lock()
        stalledFlag = true
        lock.unlock()
    }

    var stalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stalledFlag
    }
}

/// Thread-safe accumulator for one install's output: the license text seen
/// so far, a bounded tail for error messages, and the declined flag.
/// `onLine` arrives from the stdout and stderr reader threads, so every
/// access is locked.
private final class InstallOutput: @unchecked Sendable {
    enum Event {
        case progress(Double)
        case license(String)
        case none
    }

    private let lock = NSLock()
    private var licenseLines: [String] = []
    private var tail: [String] = []
    private var declined = false

    func consume(_ line: String) -> Event {
        lock.lock()
        defer { lock.unlock() }
        if let value = SdkmanagerParsing.progress(from: line) {
            return .progress(value)
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            tail.append(trimmed)
            if tail.count > 40 {
                tail.removeFirst(tail.count - 40)
            }
        }
        if SdkmanagerClient.isLicensePrompt(trimmed) {
            let text = SdkmanagerParsing.licensePromptLines(
                from: licenseLines.joined(separator: "\n")
            )
            .joined(separator: "\n")
            licenseLines.removeAll()
            return .license(text)
        }
        if !trimmed.isEmpty {
            licenseLines.append(trimmed)
        }
        return .none
    }

    func markDeclined() {
        lock.lock()
        declined = true
        lock.unlock()
    }

    var wasDeclined: Bool {
        lock.lock()
        defer { lock.unlock() }
        return declined
    }

    var tailText: String {
        lock.lock()
        defer { lock.unlock() }
        return tail.joined(separator: "\n")
    }
}

/// The running install, shared across the install task, its reader threads
/// and `cancel`.
private final class InstallSession: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Error>?
    private var stdinWriter: ProcessStdin?

    /// Clears any previous install: the caller must call this before
    /// spawning the next task, or an attach from the new task could race
    /// with the reset.
    func prepare() {
        lock.lock()
        task = nil
        stdinWriter = nil
        lock.unlock()
    }

    func begin(_ task: Task<Void, Error>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func attach(_ stdin: ProcessStdin) {
        lock.lock()
        stdinWriter = stdin
        lock.unlock()
    }

    func finish() {
        lock.lock()
        task = nil
        stdinWriter = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    var stdin: ProcessStdin? {
        lock.lock()
        defer { lock.unlock() }
        return stdinWriter
    }
}
