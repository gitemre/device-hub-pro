import Foundation
import os

public enum AdbError: Error, CustomStringConvertible {
    case adbNotFound
    case commandFailed(arguments: [String], exitCode: Int32, message: String)
    /// What was chosen for install is not an APK, split directory or `.apks`
    /// set that can be installed.
    case invalidInstallPackage(String)

    public var description: String {
        switch self {
        case .adbNotFound:
            return "The Android tools were not found. Choose Set Up Android Tools in the sidebar, or set ANDROID_HOME."
        case .commandFailed(let arguments, let exitCode, let message):
            return "adb \(arguments.joined(separator: " ")) failed (\(exitCode)): \(message)"
        case .invalidInstallPackage(let reason):
            return "Cannot install: \(reason)."
        }
    }

    /// Whether the device's `cmd` found no package manager service: Android
    /// is still booting and `pm` cannot answer yet. Captured live on
    /// 2026-09-28 from an API 37.1 emulator (Pixel 9 Pro Fold,
    /// google_apis_playstore_ps16k) in the first second adb listed it:
    /// `cmd: Can't find service: package` and a newline on stderr, exit 20,
    /// with `sys.boot_completed` still empty.
    public var isPackageServiceMissing: Bool {
        guard case .commandFailed(_, _, let message) = self else { return false }
        return message.contains(Self.packageServiceMissingMessage)
    }

    static let packageServiceMissingMessage = "Can't find service: package"

    /// Whether adb could not reach or start its server (not a device error).
    public var isServerStartFailure: Bool {
        guard case .commandFailed(_, _, let message) = self else { return false }
        return AdbServerStartFailure.matches(message)
    }
}

/// What the adb client prints when its server is not there and could not be
/// started: a server problem, never a device's.
///
/// SOURCE-DERIVED from platform/packages/modules/adb (android.googlesource.com,
/// main, 2026-10-05): `adb.cpp` prints "ADB server didn't ACK" (line 790);
/// `client/adb_client.cpp` prints "* failed to start daemon" (273),
/// "cannot connect to daemon at <spec>: <err>" (169, 203), "cannot connect to
/// daemon" (277) and "protocol fault (couldn't read status): <errno>" (140).
public enum AdbServerStartFailure {
    static let markers = [
        "ADB server didn't ACK",
        "failed to start daemon",
        "cannot connect to daemon",
        "protocol fault (couldn't read status)",
    ]

    public static func matches(_ text: String) -> Bool {
        markers.contains { text.contains($0) }
    }
}

/// Minimal wrapper around the `adb` command-line tool.
///
/// Every one-shot call is bounded: when its timeout elapses the adb child is
/// terminated and `ProcessRunnerError.timedOut` (naming the adb command) is
/// thrown, so a wedged transport — a Wi-Fi device that left the network, a
/// frozen emulator console — fails the call instead of hanging the UI.
/// Streaming work (logcat, screen recording, the scrcpy server) does not go
/// through these calls.
public final class AdbClient: Sendable {
    /// Where adb is; set once for a client made with `init(adbURL:)`, and
    /// later (`resolve`) for one made with `unresolved()`.
    private let location: OSAllocatedUnfairLock<URL?>

    /// The adb executable. For a client that has none yet (`isResolved`
    /// false) a path that does not exist, so a spawn fails like any missing
    /// binary; every call checks `isResolved` first and throws
    /// `AdbError.adbNotFound` instead.
    public var adbURL: URL {
        location.withLock { $0 } ?? URL(fileURLWithPath: "/nonexistent/adb")
    }

    /// Whether adb has been found: always true for `init(adbURL:)`.
    public var isResolved: Bool { location.withLock { $0 != nil } }

    /// This client's bound for one-shot calls that name none of their own.
    public let commandTimeout: Duration

    /// The default `commandTimeout`: ample for any healthy shell or console
    /// command (a busy device's `dumpsys meminfo` included).
    public static let defaultTimeout: Duration = .seconds(30)

    /// The bound for size-dependent transfers (install, pull): a large APK
    /// or recording over Wi-Fi can legitimately take minutes.
    public static let transferTimeout: Duration = .seconds(600)

    /// The bound for package-manager work that can stall on a slow device
    /// (uninstall, clear data) and for logcat dumps of a full buffer.
    public static let slowCommandTimeout: Duration = .seconds(60)

    /// The pause between `kill-server` and `start-server` when a call finds
    /// the server could not start (`execute`).
    private let serverRestartBackoff: Duration
    /// When the last such repair ran, so concurrent calls that fail together
    /// do not each kill the server the first one just started.
    private let lastServerRepair = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)

    public init(
        adbURL: URL,
        commandTimeout: Duration = AdbClient.defaultTimeout,
        serverRestartBackoff: Duration = .milliseconds(500)
    ) {
        self.location = OSAllocatedUnfairLock(initialState: adbURL)
        self.commandTimeout = commandTimeout
        self.serverRestartBackoff = serverRestartBackoff
    }

    /// A client for a Mac where adb is not installed yet: its calls throw
    /// `AdbError.adbNotFound` until `resolve(_:)` hands it the adb the guided
    /// setup (or "Locate SDK…") found, so the app picks the tools up without
    /// being relaunched.
    public static func unresolved(commandTimeout: Duration = AdbClient.defaultTimeout) -> AdbClient {
        let client = AdbClient(adbURL: URL(fileURLWithPath: "/nonexistent/adb"), commandTimeout: commandTimeout)
        client.location.withLock { $0 = nil }
        return client
    }

    /// Points this client at adb; every holder of it sees the change.
    public func resolve(_ url: URL) {
        location.withLock { $0 = url }
    }

    /// Locates adb on this machine.
    public static func locate() -> AdbClient? {
        AdbBinaryLocator.locate().map { AdbClient(adbURL: $0) }
    }

    public func listDevices() async throws -> [AndroidDevice] {
        let result = try await execute(["devices", "-l"])
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(
                arguments: ["devices", "-l"],
                exitCode: result.exitCode,
                message: result.standardErrorText
            )
        }
        return AdbParsing.devices(from: result.standardOutputText)
    }

    public func getprop(serial: String) async throws -> [String: String] {
        let result = try await execute(["-s", serial, "shell", "getprop"])
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(
                arguments: ["-s", serial, "shell", "getprop"],
                exitCode: result.exitCode,
                message: result.standardErrorText
            )
        }
        return AdbParsing.getprop(from: result.standardOutputText)
    }

    /// Whether Android reports `sys.boot_completed` 1: its services (the
    /// package manager among them) are up. The boot waits of Start and of
    /// the Apps list both read it.
    public func isBootCompleted(serial: String) async throws -> Bool {
        try await getprop(serial: serial)["sys.boot_completed"] == "1"
    }

    public func deviceInfo(serial: String, isEmulator: Bool) async throws -> DeviceInfo {
        let properties = try await getprop(serial: serial)
        // Best effort: the hardware type features classify a TV image whose
        // characteristics say only "emulator".
        let features = await featureNames(serial: serial)
        return DeviceInfo.from(serial: serial, properties: properties, isEmulator: isEmulator, features: features)
    }

    /// The `feature:` names `pm list features` lists; empty when the read fails.
    public func featureNames(serial: String) async -> Set<String> {
        guard let result = try? await execute(["-s", serial, "shell", "pm", "list", "features"]),
              result.exitCode == 0
        else { return [] }
        return AdbParsing.features(from: result.standardOutputText)
    }

    /// PNG bytes of the current device screen.
    public func screenshot(serial: String) async throws -> Data {
        let arguments = ["-s", serial, "exec-out", "screencap", "-p"]
        let result = try await execute(arguments)
        guard result.exitCode == 0, !result.standardOutput.isEmpty else {
            throw AdbError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: result.standardErrorText
            )
        }
        guard let png = AdbParsing.pngData(from: result.standardOutput) else {
            throw AdbError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: "screencap output did not contain a PNG"
            )
        }
        return png
    }

    /// Installed package names, third-party only by default.
    public func listPackages(serial: String, thirdPartyOnly: Bool = true) async throws -> [String] {
        var arguments = ["-s", serial, "shell", "pm", "list", "packages"]
        if thirdPartyOnly {
            arguments.append("-3")
        }
        let result = try await execute(arguments)
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: result.standardErrorText
            )
        }
        return AdbParsing.packages(from: result.standardOutputText)
    }

    /// One installed package with its version code, for the Apps inspector.
    public struct InstalledPackage: Sendable, Hashable {
        public let id: String
        public let versionCode: String?

        public init(id: String, versionCode: String?) {
            self.id = id
            self.versionCode = versionCode
        }
    }

    /// Installed packages with version codes (`pm list packages --show-versioncode`).
    ///
    /// `--show-versioncode` arrived in Android 8.0 (API 26). Older package
    /// managers refuse it with an `Error: Unknown option: --show-versioncode`
    /// line: on stdout with exit 255 on Android 7 (`PackageManagerShellCommand`),
    /// on stderr with exit 1 on Android 6 and older (`Pm.java`), where the
    /// legacy shell merges it into stdout and always exits 0. Such a device
    /// gets the plain listing instead, without version codes.
    public func listPackagesDetailed(
        serial: String,
        includeSystem: Bool = false
    ) async throws -> [InstalledPackage] {
        var arguments = ["-s", serial, "shell", "pm", "list", "packages", "--show-versioncode"]
        if !includeSystem {
            arguments.append("-3")
        }
        let result = try await execute(arguments)
        let output = result.standardOutputText
        if Self.packageManagerRefused(output) {
            return try await listPackagesWithoutVersions(serial: serial, includeSystem: includeSystem)
        }
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: result.standardErrorText.isEmpty ? output : result.standardErrorText
            )
        }
        return AdbParsing.packagesWithVersions(from: output)
    }

    /// `pm list packages [-3]` for a package manager that predates
    /// `--show-versioncode`; a refusal here is an error, not an empty list.
    private func listPackagesWithoutVersions(
        serial: String,
        includeSystem: Bool
    ) async throws -> [InstalledPackage] {
        var arguments = ["-s", serial, "shell", "pm", "list", "packages"]
        if !includeSystem {
            arguments.append("-3")
        }
        let result = try await execute(arguments)
        let output = result.standardOutputText
        guard result.exitCode == 0, !Self.packageManagerRefused(output) else {
            throw AdbError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: [result.standardErrorText, output]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            )
        }
        return AdbParsing.packages(from: output).map { InstalledPackage(id: $0, versionCode: nil) }
    }

    /// Whether `pm` refused the request: a line of its own starting with
    /// `Error` (`Error: Unknown option: …`). Listing lines all start with
    /// `package:`, so a package id containing "error" never matches.
    static func packageManagerRefused(_ output: String) -> Bool {
        outputHasLine(output, startingWithAnyOf: ["Error"])
    }

    /// Whether any line of `output`, leading blanks trimmed, starts with one
    /// of `prefixes` (case-sensitive). Lines may end in `\n` or `\r\n`.
    static func outputHasLine(_ output: String, startingWithAnyOf prefixes: [String]) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return prefixes.contains { trimmed.hasPrefix($0) }
        }
    }

    /// One-shot logcat dump (most recent `lines` entries).
    public func logcatDump(serial: String, lines: Int = 300) async throws -> String {
        try await logcatDump(serial: serial, timeArgument: "\(lines)")
    }

    /// One-shot logcat dump holding only entries newer than `time` — logcat's
    /// time argument, either `MM-DD hh:mm:ss.mmm` or epoch seconds (there is
    /// no relative form; `DiagnosticsBundle` computes the cutoff). Android 7+.
    public func logcatDump(serial: String, since time: String) async throws -> String {
        try await logcatDump(serial: serial, timeArgument: time)
    }

    private func logcatDump(serial: String, timeArgument: String) async throws -> String {
        let arguments = ["-s", serial, "logcat", "-d", "-v", "threadtime", "-t", timeArgument]
        let result = try await execute(arguments, timeout: Self.slowCommandTimeout)
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: result.standardErrorText
            )
        }
        return result.standardOutputText
    }

    /// Sends a key event (e.g. 3 = Home, 4 = Back, 187 = Recents). With
    /// `longPress` the device receives a long press, which triggers secondary
    /// actions such as the power menu or split screen.
    public func sendKey(serial: String, keyCode: Int, longPress: Bool = false) async throws {
        var arguments = ["-s", serial, "shell", "input", "keyevent"]
        if longPress {
            arguments.append("--longpress")
        }
        arguments.append("\(keyCode)")

        let result = try await execute(arguments)
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: result.standardErrorText
            )
        }
    }

    /// Runs an emulator console command (`adb -s <serial> emu …`). Throws when the
    /// emulator answers `KO: …`.
    @discardableResult
    public func emuCommand(serial: String, _ arguments: [String]) async throws -> String {
        let full = ["-s", serial, "emu"] + arguments
        let result = try await execute(full)
        let output = result.standardOutputText

        guard result.exitCode == 0, !output.hasPrefix("KO") else {
            throw AdbError.commandFailed(
                arguments: full,
                exitCode: result.exitCode,
                message: output.isEmpty ? result.standardErrorText : output
            )
        }
        return output
    }

    /// The resize presets the emulator console offers (`adb emu
    /// resize-display` without an index). The console answers with its usage
    /// line, `KO usage: "resize-display <index>" 0: phone\t1: unfolded…`, and
    /// exit status 0, so unlike `emuCommand` this read accepts a KO answer and
    /// parses its list (`AdbParsing.resizePresets(fromUsage:)`); a KO without
    /// a usage yields no presets. Throws when adb itself fails. The console
    /// lists the same presets on every AVD: `AvdConfig.isResizable` tells
    /// whether this one can use them.
    public func resizeDisplayPresets(serial: String) async throws -> [ResizePreset] {
        let arguments = ["-s", serial, "emu", "resize-display"]
        let result = try await execute(arguments)
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: result.standardErrorText
            )
        }
        return AdbParsing.resizePresets(fromUsage: result.standardOutputText)
    }

    /// The framework's current display rotation (0…3), or nil when unavailable.
    @discardableResult
    public func displayRotation(serial: String) async -> Int? {
        guard let output = try? await shell(serial: serial, ["dumpsys", "display"]) else {
            return nil
        }
        return AdbParsing.displayRotation(from: output)
    }

    /// Every display device's screen shape — natural size, corner radii and
    /// cutout — from one `dumpsys display` (`DisplayShape.parse`); empty
    /// when the read fails.
    public func displayShapes(serial: String) async -> [DisplayShape] {
        guard let output = try? await shell(serial: serial, ["dumpsys", "display"]) else {
            return []
        }
        return DisplayShape.parse(dumpsysDisplay: output)
    }

    /// Runs an arbitrary `adb shell` command and returns its output, bounded
    /// by `timeout` (default: `commandTimeout`).
    public func shell(
        serial: String,
        _ arguments: [String],
        timeout: Duration? = nil
    ) async throws -> String {
        let full = ["-s", serial, "shell"] + arguments
        let result = try await execute(full, timeout: timeout)
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(
                arguments: full,
                exitCode: result.exitCode,
                message: result.standardErrorText
            )
        }
        return result.standardOutputText
    }

    /// Install flags beyond the always-on `-r` (replace, keeping data).
    public struct InstallOptions: Sendable, Equatable {
        /// `-t`: accept test-only packages (`android:testOnly`), which is what
        /// Android Studio's Run produces — without it the device refuses them
        /// with `INSTALL_FAILED_TEST_ONLY`. Harmless for other APKs.
        public var allowTestPackages: Bool
        /// `-d`: accept a lower version code than the installed one.
        public var allowDowngrade: Bool

        public init(allowTestPackages: Bool = true, allowDowngrade: Bool = false) {
            self.allowTestPackages = allowTestPackages
            self.allowDowngrade = allowDowngrade
        }
    }

    /// Installs (or replaces) an app on the device. `apkURL` is one APK, a
    /// directory of split APKs, or a bundletool `.apks` set; several APKs go
    /// in together with `install-multiple` (see `ApkInstallSet`). A `.apks`
    /// set with several variants installs the one for the device's API
    /// level.
    public func install(
        serial: String,
        apkURL: URL,
        options: InstallOptions = InstallOptions(),
        timeout: Duration = AdbClient.transferTimeout
    ) async throws {
        let set = try await ApkInstallSet.resolve(apkURL, deviceSdk: {
            try await self.sdkLevel(serial: serial)
        })
        defer { set.cleanUp() }
        let arguments = Self.installArguments(serial: serial, apks: set.apks, options: options)
        let result = try await execute(arguments, timeout: timeout)
        let output = result.standardOutputText
        guard !Self.installFailed(exitCode: result.exitCode, standardOutput: output) else {
            throw AdbError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: Self.installFailureMessage(
                    standardOutput: output,
                    standardError: result.standardErrorText
                )
            )
        }
    }

    /// Whether an `adb install` / `install-multiple` run failed: a non-zero
    /// exit, or a verdict line of its own on stdout. Streamed installs
    /// (Android 7+) exit 1 on failure. A pushed install (Android 6 and older,
    /// `install_app_legacy`) exits 0 whatever happens, because the legacy
    /// shell has no exit status, and its stdout also names the APK: pm's
    /// `\tpkg: /data/local/tmp/<name>` echo, merged in from stderr, and,
    /// up to platform-tools 34, adb's push summary (`<local path>: 1 file
    /// pushed, 0 skipped. …`). A path that merely contains "error"
    /// (`~/ErrorTracker/error-reporter.apk`) is therefore not a failure;
    /// pm's `Failure […]` and `Error: …` lines are.
    static func installFailed(exitCode: Int32, standardOutput: String) -> Bool {
        exitCode != 0
            || outputHasLine(standardOutput, startingWithAnyOf: ["Failure", "Error", "adb: failed", "adb: error"])
    }

    /// What a failed install reports. A streamed `adb install` prints
    /// `Performing Streamed Install` on stdout as it starts, then a failed
    /// verdict from the package manager on stderr (`adb: failed to install
    /// <apk>: Failure [INSTALL_FAILED_…]`), so stdout alone
    /// would lose the reason; older, pushed installs print `Failure […]` on
    /// stdout with nothing on stderr. The reason comes first, then whatever
    /// stdout said.
    static func installFailureMessage(standardOutput: String, standardError: String) -> String {
        [standardError, standardOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The device's API level (`ro.build.version.sdk`); nil when the value
    /// is not a number.
    func sdkLevel(serial: String) async throws -> Int? {
        let output = try await shell(serial: serial, ["getprop", "ro.build.version.sdk"])
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The adb argv for installing `apks`: `install` for one APK,
    /// `install-multiple` for a split set.
    static func installArguments(
        serial: String,
        apks: [URL],
        options: InstallOptions
    ) -> [String] {
        var arguments = ["-s", serial, apks.count > 1 ? "install-multiple" : "install", "-r"]
        if options.allowTestPackages {
            arguments.append("-t")
        }
        if options.allowDowngrade {
            arguments.append("-d")
        }
        return arguments + apks.map(\.path)
    }

    /// Launches `package` by firing its LAUNCHER intent via monkey.
    public func launchApp(serial: String, package: String) async throws {
        // `--pct-syskeys 0` is required on images without a physical keyboard
        // (the ATD and 16 KB-page emulators): with the default 2 % syskey
        // share monkey deterministically aborts ("SYS_KEYS has no physical
        // keys") before injecting the launch event.
        let arguments = [
            "-s", serial, "shell", "monkey",
            "-p", Self.shellQuoted(package), "-c", "android.intent.category.LAUNCHER",
            "--pct-syskeys", "0", "1",
        ]
        let result = try await execute(arguments)
        let output = result.standardOutputText
        let failed = result.exitCode != 0
            || output.localizedCaseInsensitiveContains("No activities found")
        guard !failed else {
            throw AdbError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: output.isEmpty ? result.standardErrorText : output
            )
        }
    }

    /// Force-stops `package` (`am force-stop`). Deliberately unconfirmed in
    /// the UI.
    public func forceStop(serial: String, package: String) async throws {
        let arguments = ["-s", serial, "shell", "am", "force-stop", Self.shellQuoted(package)]
        let result = try await execute(arguments)
        let output = result.standardOutputText
        let failed = result.exitCode != 0
            || output.localizedCaseInsensitiveContains("Error")
            || output.localizedCaseInsensitiveContains("Exception")
        guard !failed else {
            throw AdbError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: output.isEmpty ? result.standardErrorText : output
            )
        }
    }

    /// Erases all of `package`'s on-device data (`pm clear`). `pm clear`
    /// reports failures on stdout with a zero exit code on some images.
    public func clearData(serial: String, package: String) async throws {
        let arguments = ["-s", serial, "shell", "pm", "clear", Self.shellQuoted(package)]
        let result = try await execute(arguments, timeout: Self.slowCommandTimeout)
        let output = result.standardOutputText
        let failed = result.exitCode != 0
            || output.localizedCaseInsensitiveContains("Failed")
            || output.localizedCaseInsensitiveContains("Error")
        guard !failed else {
            throw AdbError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: output.isEmpty ? result.standardErrorText : output
            )
        }
    }

    /// The on-device data directory of `package` — Device Hub's "App
    /// Container" slot, mapped to the path root would use. Not readable from
    /// an unrooted shell; the context menu copies it as a string.
    public static func dataPath(package: String) -> String {
        "/data/data/\(package)"
    }

    /// Opens the device's Application Info screen for `package`.
    public func openAppInfo(serial: String, package: String) async throws {
        let arguments = [
            "-s", serial, "shell", "am", "start",
            "-a", "android.settings.APPLICATION_DETAILS_SETTINGS",
            "-d", "package:\(package)",
        ]
        let result = try await execute(arguments)
        let output = result.standardOutputText + "\n" + result.standardErrorText
        let failed = result.exitCode != 0 || Self.activityStartFailed(output)
        guard !failed else {
            throw AdbError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Whether `am start` output reports a failed start. The activity
    /// manager's shell command prints its failures as lines of their own
    /// that begin with `Error` (`Error: Activity not started, unable to
    /// resolve Intent { … }`, `Error type 3`), but it first echoes the
    /// intent (`Starting: Intent { … }`), whose data URI is the app's
    /// `package:<id>` in full on Android 13 and older — so an id that merely
    /// contains "error" (`com.example.errorreporter`) is not a failure.
    static func activityStartFailed(_ output: String) -> Bool {
        outputHasLine(output, startingWithAnyOf: ["Error"])
    }

    /// Uninstalls `package` from the device.
    public func uninstallApp(serial: String, package: String) async throws {
        let arguments = ["-s", serial, "uninstall", package]
        let result = try await execute(arguments, timeout: Self.slowCommandTimeout)
        let output = result.standardOutputText
        let failed = result.exitCode != 0
            || output.localizedCaseInsensitiveContains("Failure")
        guard !failed else {
            throw AdbError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: output.isEmpty ? result.standardErrorText : output
            )
        }
    }

    /// All settings from `settings list global` as key/value pairs.
    public func globalSettings(serial: String) async throws -> [String: String] {
        let result = try await execute(["-s", serial, "shell", "settings", "list", "global"])
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(
                arguments: ["-s", serial, "shell", "settings", "list", "global"],
                exitCode: result.exitCode,
                message: result.standardErrorText
            )
        }
        return AdbParsing.globalSettings(from: result.standardOutputText)
    }

    public func setAirplaneMode(serial: String, enabled: Bool) async throws {
        _ = try await shell(serial: serial, ["cmd", "connectivity", "airplane-mode", enabled ? "enable" : "disable"])
    }

    public func setWifi(serial: String, enabled: Bool) async throws {
        _ = try await shell(serial: serial, ["svc", "wifi", enabled ? "enable" : "disable"])
    }

    public func setBluetooth(serial: String, enabled: Bool) async throws {
        do {
            _ = try await shell(serial: serial, ["svc", "bluetooth", enabled ? "enable" : "disable"])
        } catch {
            // Newer images expose bluetooth through the manager service.
            _ = try await shell(serial: serial, ["cmd", "bluetooth_manager", enabled ? "enable" : "disable"])
        }
    }

    /// Turns battery saver on/off through PowerManager; throws
    /// `DeviceSettingsError.batterySaverRefusedWhileCharging` when enabling
    /// on a charger, which Android refuses (`AdbClient+Settings.swift`).
    public func setBatterySaver(serial: String, enabled: Bool) async throws {
        try await applyBatterySaver(serial: serial, enabled: enabled)
    }

    /// The device's appearance reading (`cmd uimode night`, API 23+).
    public func appearanceReading(serial: String) async throws -> AppearanceReading {
        let output = try await shell(serial: serial, ["cmd", "uimode", "night"])
        return AdbParsing.appearanceReading(from: output)
    }

    /// Applies an appearance setting (`cmd uimode night yes|no|auto`).
    public func setAppearanceMode(serial: String, _ mode: AppearanceMode) async throws {
        _ = try await shell(serial: serial, ["cmd", "uimode", "night", mode.commandValue])
    }

    /// Every setting in one namespace (`settings list <namespace>`) as
    /// key/value pairs, for the Controls settings rows.
    public func settingsList(serial: String, namespace: String) async throws -> [String: String] {
        let arguments = ["-s", serial, "shell", "settings", "list", namespace]
        let result = try await execute(arguments)
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: result.standardErrorText
            )
        }
        return AdbParsing.globalSettings(from: result.standardOutputText)
    }

    /// Applies one setting (`settings put <namespace> <key> <value>`). The key
    /// and value are quoted for the device shell (see `shellQuoted`), so a
    /// value such as a nested-class service `pkg/.Outer$Service` arrives
    /// intact instead of being expanded by the device's `sh`.
    private func putSetting(
        serial: String,
        namespace: String,
        key: String,
        value: String
    ) async throws {
        _ = try await shell(
            serial: serial,
            ["settings", "put", namespace, Self.shellQuoted(key), Self.shellQuoted(value)]
        )
    }

    /// Quotes one argument for the device shell. `adb shell` joins its
    /// arguments with spaces without escaping them (adb: "We don't escape
    /// here, just like ssh"), and the device's `sh` parses that line again,
    /// so an argument with shell syntax — `$`, spaces, quotes, `;`, globs —
    /// would be expanded or split on the device. Plain words pass unchanged;
    /// anything else is single-quoted, with an embedded `'` written `'\''`.
    /// Exact only for ASCII arguments (Foundation.Process decomposes
    /// non-ASCII argv): user text that may be non-ASCII goes through
    /// `shellWord` instead.
    public static func shellQuoted(_ argument: String) -> String {
        let plain = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:,=+-@%"
        )
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(plain.contains) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Writes the system font scale (`settings put system font_scale`).
    public func setFontScale(serial: String, scale: Double) async throws {
        try await putSetting(
            serial: serial,
            namespace: "system",
            key: "font_scale",
            value: "\(scale)"
        )
    }

    /// The three animation scale keys, in the global namespace.
    public static let animationScaleKeys = ["window_animation_scale", "transition_animation_scale", "animator_duration_scale"]

    /// The three animation scales as the device had them (a key it had not
    /// set is nil), read before Reduce Motion first changes them so Off can
    /// give the user's own values back.
    public struct AnimationScales: Sendable, Equatable {
        public var values: [String?]

        public init(values: [String?]) {
            self.values = values
        }

        /// True when every scale was already 0 (the device was reduced
        /// before Device Hub Pro touched it: nothing of the user's to keep).
        public var allZero: Bool {
            values.allSatisfy { $0.flatMap(Double.init) == 0 }
        }
    }

    /// Reads the three animation scales; nil when the device does not answer.
    public func animationScales(serial: String) async -> AnimationScales? {
        var values: [String?] = []
        for key in Self.animationScaleKeys {
            guard let output = try? await shell(serial: serial, ["settings", "get", "global", Self.shellQuoted(key)]) else {
                return nil
            }
            let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
            values.append(value.isEmpty || value == "null" ? nil : value)
        }
        return AnimationScales(values: values)
    }

    /// Turns Reduce Motion on/off by writing all three animation scales
    /// (`0` = animations off). The scales live in the global namespace. Off
    /// writes `restoring` (what the device had before Reduce Motion first
    /// ran: a key that was unset is deleted again), else the stock 1.0.
    public func setReduceMotion(serial: String, enabled: Bool, restoring: AnimationScales? = nil) async throws {
        for (index, key) in Self.animationScaleKeys.enumerated() {
            if enabled {
                try await putSetting(serial: serial, namespace: "global", key: key, value: "0")
            } else if let restoring, restoring.values.indices.contains(index) {
                if let value = restoring.values[index] {
                    try await putSetting(serial: serial, namespace: "global", key: key, value: value)
                } else {
                    _ = try await shell(serial: serial, ["settings", "delete", "global", Self.shellQuoted(key)])
                }
            } else {
                try await putSetting(serial: serial, namespace: "global", key: key, value: "1.0")
            }
        }
    }

    /// Writes `secure high_text_contrast_enabled`.
    public func setHighTextContrast(serial: String, enabled: Bool) async throws {
        try await putSetting(
            serial: serial,
            namespace: "secure",
            key: "high_text_contrast_enabled",
            value: enabled ? "1" : "0"
        )
    }

    /// Show Borders (layout bounds): the `debug.layout` system property plus
    /// the SYSPROPS poke that makes running apps redraw with it. Nothing in
    /// the platform reads a Global `debug_layout` key.
    public func setDebugLayout(serial: String, enabled: Bool) async throws {
        try await applyDebugLayout(serial: serial, enabled: enabled)
    }

    /// Applies one developer toggle through its real mechanism: a plain
    /// `settings put <namespace> <key> 0|1` for the key-driven rows, and for
    /// the others what Developer Options does (`DeviceToggle.readsDeviceEffect`,
    /// `AdbClient+Settings.swift`). Throws `DeviceSettingsError` when the
    /// device cannot change it from adb.
    @discardableResult
    public func setToggle(
        serial: String,
        toggle: DeviceToggle,
        enabled: Bool
    ) async throws -> ToggleWriteOutcome {
        switch toggle {
        case .forceRTL:
            return try await applyForceRTL(serial: serial, enabled: enabled)
        case .wifiVerboseLogging:
            return try await applyWifiVerboseLogging(serial: serial, enabled: enabled)
        case .showTaps, .showBackgroundANRs, .mobileDataAlwaysActive:
            try await putSetting(
                serial: serial,
                namespace: toggle.namespace,
                key: toggle.key,
                value: enabled ? "1" : "0"
            )
            return .applied
        }
    }

    /// Turns mobile data on/off (`svc data enable|disable`).
    public func setMobileData(serial: String, enabled: Bool) async throws {
        _ = try await shell(
            serial: serial,
            ["svc", "data", enabled ? "enable" : "disable"]
        )
    }

    /// The Data Saver reading (`cmd netpolicy get restrict-background`).
    public func dataSaverReading(serial: String) async throws -> DataSaverReading {
        let output = try await shell(
            serial: serial,
            ["cmd", "netpolicy", "get", "restrict-background"]
        )
        return DataSaverReading.parse(output)
    }

    /// Applies Data Saver (`cmd netpolicy set restrict-background true|false`).
    public func setDataSaver(serial: String, enabled: Bool) async throws {
        _ = try await shell(
            serial: serial,
            ["cmd", "netpolicy", "set", "restrict-background", enabled ? "true" : "false"]
        )
    }

    /// Turns TalkBack on/off by writing `accessibility_enabled` and the
    /// service component in `enabled_accessibility_services`. Other enabled
    /// accessibility services are preserved: the current list is read first,
    /// and a failed read aborts the toggle (throws) instead of being taken
    /// for an empty list — which would replace the list with TalkBack alone,
    /// or delete it outright when disabling.
    public func setTalkBack(serial: String, enabled: Bool, packageID: String) async throws {
        let component = TalkBack.serviceComponent(for: packageID)
        let raw = try await shell(
            serial: serial,
            ["settings", "get", "secure", "enabled_accessibility_services"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = enabled
            ? AccessibilityServices.adding(component, to: raw)
            : AccessibilityServices.removing(component, from: raw)

        // Enabling: list the service before flipping the flag so TalkBack is
        // running the moment it is on. Disabling: flip the flag first so the
        // service never runs without approval.
        if enabled {
            try await putAccessibilityServices(serial: serial, value: updated)
            try await putSetting(
                serial: serial,
                namespace: "secure",
                key: "accessibility_enabled",
                value: "1"
            )
        } else {
            try await putSetting(
                serial: serial,
                namespace: "secure",
                key: "accessibility_enabled",
                value: "0"
            )
            try await putAccessibilityServices(serial: serial, value: updated)
        }
    }

    /// Writes the accessibility-service list; an empty list is a *delete* —
    /// `settings put` with an empty value loses the argument on the way
    /// through `adb shell` and fails with "Bad arguments".
    private func putAccessibilityServices(serial: String, value: String) async throws {
        if value.isEmpty {
            _ = try await shell(
                serial: serial,
                ["settings", "delete", "secure", "enabled_accessibility_services"]
            )
        } else {
            try await putSetting(
                serial: serial,
                namespace: "secure",
                key: "enabled_accessibility_services",
                value: value
            )
        }
    }

    /// The media stream's volume (`media volume --stream 3 --get`, with the
    /// `cmd media_session volume` successor as the fallback for images that
    /// dropped the legacy `media` binary).
    public func mediaVolumeReading(serial: String) async throws -> MediaVolumeReading {
        let legacy = ["media", "volume", "--stream", "3", "--get"]
        if let output = try? await shell(serial: serial, legacy),
           let reading = DeviceSettingsParsing.mediaVolume(from: output) {
            return reading
        }
        let arguments = ["cmd", "media_session", "volume", "--stream", "3", "--get"]
        let output = try await shell(serial: serial, arguments)
        guard let reading = DeviceSettingsParsing.mediaVolume(from: output) else {
            throw AdbError.commandFailed(
                arguments: ["-s", serial, "shell"] + arguments,
                exitCode: 0,
                message: "unrecognized volume output: \(output)"
            )
        }
        return reading
    }

    /// Sets the media stream volume. Prefers the absolute writers
    /// (`media volume --stream 3 --set N`, then `cmd media_session volume`),
    /// and verifies the result: on several modern images those writers are
    /// denied to the shell user (`AUDIO_MEDIA_VOLUME`) yet exit 0, so the
    /// remaining steps are sent as volume key events — exactly what the
    /// hardware rocker does.
    public func setMediaVolume(serial: String, index: Int) async throws {
        let target = max(0, index)
        do {
            _ = try await shell(
                serial: serial,
                ["media", "volume", "--stream", "3", "--set", "\(target)"]
            )
        } catch {
            _ = try? await shell(
                serial: serial,
                ["cmd", "media_session", "volume", "--stream", "3", "--set", "\(target)"]
            )
        }
        guard let current = try? await mediaVolumeReading(serial: serial),
              current.index != target
        else { return }
        let keyCode = target > current.index ? 24 : 25
        for _ in 0..<abs(target - current.index) {
            _ = try await shell(serial: serial, ["input", "keyevent", "\(keyCode)"])
        }
    }

    /// Copies a file from the device to the local filesystem.
    public func pull(
        serial: String,
        remotePath: String,
        to localURL: URL,
        timeout: Duration = AdbClient.transferTimeout
    ) async throws {
        let arguments = ["-s", serial, "pull", remotePath, localURL.path]
        let result = try await execute(arguments, timeout: timeout)
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: result.standardErrorText
            )
        }
    }

    /// Starts `screenrecord` on the device. Stop it with
    /// `stopScreenRecordAndPull`: the helper interrupts the device-side
    /// recorder first (so the mp4 is finalized), which also lets the returned
    /// local process exit on its own.
    ///
    /// `screenrecord` stops by itself after 180 s unless told otherwise.
    /// Builds whose help offers "Set to 0 to remove the time limit" (Android
    /// 14+) record without a limit; older ones reject `--time-limit 0`, so the
    /// choice is made on the device and the recorder keeps its 180 s cap
    /// there — the returned process then exits early, which callers should
    /// watch for (`screenRecordHasNoTimeLimit(serial:)` tells in advance).
    /// `remotePath` should be unique: stopping matches the recorder by it.
    public func startScreenRecord(
        serial: String,
        remotePath: String,
        bitRate: Int = 8_000_000
    ) throws -> Process {
        try ProcessRunner.launchDetached(
            executable: adbURL,
            arguments: [
                "-s", serial, "shell",
                Self.screenRecordCommand(remotePath: remotePath, bitRate: bitRate),
            ]
        )
    }

    /// The device-side command line of a recording: one `sh` line that picks
    /// the unlimited form where `screenrecord` supports it and then `exec`s,
    /// so the recording process is `screenrecord` itself with `remotePath` on
    /// its command line (what `stopScreenRecordAndPull` matches).
    static func screenRecordCommand(remotePath: String, bitRate: Int) -> String {
        let path = shellQuoted(remotePath)
        let recorder = "screenrecord --bit-rate \(bitRate)"
        return "if screenrecord --help 2>&1 | grep -q 'remove the time limit'; "
            + "then exec \(recorder) --time-limit 0 \(path); "
            + "else exec \(recorder) \(path); fi"
    }

    /// Whether the device's `screenrecord` can record past its default 180 s
    /// (its help offers `--time-limit 0`). False when the help cannot be read.
    public func screenRecordHasNoTimeLimit(serial: String) async -> Bool {
        // Best effort: an unreadable help means the conservative answer.
        guard let result = try? await execute(["-s", serial, "shell", "screenrecord", "--help"]) else {
            return false
        }
        return (result.standardOutputText + result.standardErrorText)
            .contains("remove the time limit")
    }

    /// The suggested local name for a recording: `<device>-<timestamp>.mp4`
    /// (the device name sanitized for the filesystem).
    public static func recordingFileName(
        device: String,
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let name = sanitizedFileNameComponent(device)
        return "\(name.isEmpty ? "device" : name)-\(formatter.string(from: date)).mp4"
    }

    /// Replaces every character outside `[A-Za-z0-9-_.]` with a dash so a
    /// device name can be used as a local file name.
    private static func sanitizedFileNameComponent(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return String(name.map { allowed.contains($0) ? $0 : "-" })
    }

    /// Stops the device-side `screenrecord` cleanly (SIGINT, so the mp4 is
    /// finalized), waits for it to settle, pulls the file to `destination`
    /// and removes the device-side copy afterwards, best-effort. The caller's
    /// local process (from `startScreenRecord`) exits on its own once the
    /// recorder stops; terminate it afterwards if it lingers.
    ///
    /// Only the recorder writing `remotePath` is interrupted — another
    /// recording on the device (Android Studio, a second window) keeps going.
    public func stopScreenRecordAndPull(
        serial: String,
        remotePath: String,
        to destination: URL,
        settle: Duration = .seconds(2)
    ) async throws {
        // Best effort: a recorder that already stopped leaves nothing to signal.
        _ = try? await shell(serial: serial, Self.stopScreenRecordArguments(remotePath: remotePath))
        try? await Task.sleep(for: settle)
        try await pull(serial: serial, remotePath: remotePath, to: destination)
        _ = try? await shell(serial: serial, ["rm", "-f", Self.shellQuoted(remotePath)])
    }

    /// Abandons a recording: interrupts only the recorder writing
    /// `remotePath` and deletes its file, best effort.
    public func discardScreenRecord(serial: String, remotePath: String) async {
        // Best effort: a recorder that already stopped leaves nothing to signal.
        _ = try? await shell(serial: serial, Self.stopScreenRecordArguments(remotePath: remotePath))
        // Best effort: nothing to delete when the recorder never wrote a file.
        _ = try? await shell(serial: serial, ["rm", "-f", Self.shellQuoted(remotePath)])
    }

    /// `pkill -INT -f` for the recorder whose command line names
    /// `remotePath`. The `[s]` keeps the pattern from matching the device
    /// shell that runs `pkill` itself (its command line holds the pattern
    /// text, which contains no literal "screenrecord").
    static func stopScreenRecordArguments(remotePath: String) -> [String] {
        ["pkill", "-INT", "-f", shellQuoted("[s]creenrecord.*\(remotePath)")]
    }

    /// The AVD name of a running emulator, via the console command `avd name`.
    public func avdName(serial: String) async throws -> String? {
        let result = try await execute(["-s", serial, "emu", "avd", "name"])
        guard result.exitCode == 0 else { return nil }
        return AdbParsing.avdName(from: result.standardOutputText)
    }

    /// Runs adb with the given arguments (including any `-s <serial>`) and
    /// returns its standard output. Throws when adb exits non-zero, with the
    /// stderr in the error. Used by the scrcpy server launcher, whose exact
    /// argv is built by `ScrcpyServer`.
    @discardableResult
    public func run(
        _ arguments: [String],
        timeout: Duration? = nil
    ) async throws -> String {
        let result = try await execute(arguments, timeout: timeout)
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: result.standardErrorText
            )
        }
        return result.standardOutputText
    }

    // MARK: - Wireless pairing

    /// The bound for `pair`/`connect`: against an unreachable host adb waits
    /// on its own TCP timeout (a minute or more), which would otherwise hold
    /// the pairing sheet busy with no escape.
    public static let pairingTimeout: Duration = .seconds(15)

    /// Pairs with a device in wireless-debugging pairing mode (`adb pair
    /// <ip:port> <code>`, spec §11.3). `address` is the pairing dialog's
    /// `IP:port`, not the connect port. `timeout` terminates the adb process
    /// and throws `ProcessRunnerError.timedOut` when it elapses.
    @discardableResult
    public func pair(
        address: String,
        code: String,
        timeout: Duration = AdbClient.pairingTimeout
    ) async throws -> String {
        let arguments = ["pair", address, code]
        let result = try await execute(arguments, timeout: timeout)
        let stdout = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Failures arrive as "error: …" on stderr with a non-zero exit, but
        // some platform-tools builds report them on stdout with exit 0.
        let failed = result.exitCode != 0
            || stdout.localizedCaseInsensitiveContains("failed")
            || stdout.localizedCaseInsensitiveContains("error")
            || stderr.localizedCaseInsensitiveContains("failed")
            || stderr.localizedCaseInsensitiveContains("error")
        guard !failed else {
            throw AdbError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: stderr.isEmpty ? stdout : stderr
            )
        }
        return result.standardOutputText
    }

    /// Connects to a paired device over TCP (`adb connect <ip:port>`).
    /// `adb connect` reports failures on stdout with a zero exit, so the
    /// output is what decides success. `timeout` terminates the adb process
    /// and throws `ProcessRunnerError.timedOut` when it elapses.
    @discardableResult
    public func connect(
        address: String,
        timeout: Duration = AdbClient.pairingTimeout
    ) async throws -> String {
        let arguments = ["connect", address]
        let result = try await execute(arguments, timeout: timeout)
        let stdout = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = stdout + "\n" + stderr
        let failed = result.exitCode != 0
            || combined.localizedCaseInsensitiveContains("failed")
            || combined.localizedCaseInsensitiveContains("unable")
            || combined.localizedCaseInsensitiveContains("cannot")
        guard !failed else {
            throw AdbError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: stdout.isEmpty ? stderr : stdout
            )
        }
        return result.standardOutputText
    }

    /// Runs one adb call bounded by `timeout` (default: `commandTimeout`). A
    /// timeout is rethrown naming the adb command itself, so the alert says
    /// which call hung, not just "adb".
    private static func isServerCommand(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        return first == "kill-server" || first == "start-server"
    }

    /// `kill-server`, a short backoff, `start-server`; best effort (the retry
    /// of the caller's command reports whether it worked). The kill and start
    /// are skipped when a repair ran in the last few seconds: that one's
    /// server is already up.
    private func repairServer() async {
        let recent = lastServerRepair.withLock { last -> Bool in
            if let previous = last, previous.duration(to: .now) < .seconds(5) { return true }
            last = .now
            return false
        }
        if !recent {
            _ = try? await ProcessRunner.run(executable: adbURL, arguments: ["kill-server"], timeout: .seconds(10))
        }
        // Best effort: cancellation just ends the wait early.
        try? await Task.sleep(for: serverRestartBackoff)
        if !recent {
            _ = try? await ProcessRunner.run(executable: adbURL, arguments: ["start-server"], timeout: .seconds(20))
        }
    }

    func execute(
        _ arguments: [String],
        timeout: Duration? = nil
    ) async throws -> ProcessResult {
        guard isResolved else { throw AdbError.adbNotFound }
        do {
            let result = try await ProcessRunner.run(
                executable: adbURL,
                arguments: arguments,
                timeout: timeout ?? AdbCallTimeout.override ?? commandTimeout
            )
            // A server that failed to start (first run right after install, a
            // port race, a stale server): restart it once and ask again.
            guard result.exitCode != 0,
                  AdbServerStartFailure.matches(result.standardErrorText),
                  !Self.isServerCommand(arguments)
            else { return result }
            await repairServer()
            return try await ProcessRunner.run(
                executable: adbURL,
                arguments: arguments,
                timeout: timeout ?? AdbCallTimeout.override ?? commandTimeout
            )
        } catch ProcessRunnerError.timedOut(_, let seconds) {
            throw ProcessRunnerError.timedOut(
                command: "adb " + arguments.joined(separator: " "),
                seconds: seconds
            )
        }
    }
}

/// A shorter bound for the calls of one scope that name no timeout of their
/// own: a read-back loop on a device that stopped answering must not hold a
/// write's fence for `commandTimeout` per read.
public enum AdbCallTimeout {
    @TaskLocal public static var override: Duration?
}
