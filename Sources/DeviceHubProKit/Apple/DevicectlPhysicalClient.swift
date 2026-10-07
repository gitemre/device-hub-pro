import Foundation

/// Errors `DevicectlPhysicalClient` raises for a physical iPhone, beside the
/// shared `DevicectlClientError` (refusals, usage errors) and `DevicectlError`
/// (everything else CoreDevice reports).
public enum DevicectlPhysicalError: Error, Equatable, CustomStringConvertible {
    /// CoreDevice error 1001: the device lacks a capability (the captured
    /// `info audio` on an iPhone 12 names `com.apple.coredevice.feature.audiooutput`,
    /// the captured `capture screen-record` `com.apple.coredevice.feature.screenrecording`).
    case unsupportedCapability(featureIdentifier: String?, name: String?)
    /// CoreDevice error 10002 ("The application failed to launch."): `reason`
    /// is CoreDevice's own explanation, e.g. that the requested application is
    /// not installed.
    case applicationFailedToLaunch(message: String, reason: String?)
    /// CoreDevice error 10014 ("Failed to send signal 15 to process …"):
    /// `reason` says, e.g., that no such process exists.
    case failedToSendSignal(message: String, reason: String?)

    public var description: String {
        switch self {
        case .unsupportedCapability(let identifier, let name):
            return "The device does not support \(name ?? identifier ?? "a capability")"
                + (identifier.map { " (\($0))" } ?? "")
        case .applicationFailedToLaunch(let message, let reason), .failedToSendSignal(let message, let reason):
            return [message, reason].compactMap { $0 }.joined(separator: " ")
        }
    }
}

/// The `devicectl device info` subcommands runs. The list is closed:
/// nothing else is ever handed to devicectl for a physical device (beside the
/// actions of `DevicectlPhysicalAction`).
public enum DevicectlPhysicalInfoSubcommand: String, CaseIterable, Sendable {
    case details, apps, processes, displays, lockState, appearance, voiceover, ddiServices, audio
}

/// The writing and file-reading actions adds, each a fixed
/// three-word devicectl subcommand. With the nine `device info` reads this is
/// everything the physical client can run; anything else is refused.
public enum DevicectlPhysicalAction: CaseIterable, Sendable {
    case infoFiles, installApp, uninstallApp, launchApp, terminate, openURL, screenshot, screenRecord, copyFrom
    /// Send Files: one file or folder from this Mac into an
    /// app's data container, in one fixed shape (`copyTo`).
    case copyTo
    /// one app's icon as a PNG file (Device Hub's Apps list shows
    /// real icons).
    case appIcon

    /// The words devicectl is given ahead of the common options.
    public var words: [String] {
        switch self {
        case .infoFiles: ["device", "info", "files"] // source-guard: allow list
        case .installApp: ["device", "install", "app"] // source-guard: allow list
        case .uninstallApp: ["device", "uninstall", "app"] // source-guard: allow list
        case .launchApp: ["device", "process", "launch"] // source-guard: allow list
        case .terminate: ["device", "process", "terminate"] // source-guard: allow list
        case .openURL: ["device", "process", "openURL"] // source-guard: allow list
        case .screenshot: ["device", "capture", "screenshot"] // source-guard: allow list
        case .screenRecord: ["device", "capture", "screen-record"] // source-guard: allow list
        case .copyFrom: ["device", "copy", "from"] // source-guard: allow list
        case .copyTo: ["device", "copy", "to"] // source-guard: allow list
        case .appIcon: ["device", "info", "appIcon"] // source-guard: allow list
        }
    }
}

/// The Controls commands adds: one fixed shape each, with the tail
/// (`DevicectlPhysicalClient.isValidControlTail`) checked flag by flag. Three
/// words, except the two location commands, which need four. They run only
/// where the phone lists the matching CoreDevice feature (the app's
/// `ApplePhysicalControlsBackend` gates each row on `details`' capabilities);
/// every other word under `settings`, `simulate`, `orientation` and
/// `pasteboard` (biometrics, reset, rotate, monitor, transfer, sync ...)
/// stays refused.
public enum DevicectlPhysicalControl: CaseIterable, Sendable {
    case settingsAppearance, settingsVoiceOver, orientationGet, orientationSet
    case simulateLocationCoordinate, simulateLocationClear, sendMemoryWarning, pasteboardCopy, pasteboardPaste

    /// The words devicectl is given ahead of the common options.
    public var words: [String] {
        switch self {
        case .settingsAppearance: ["device", "settings", "appearance"] // source-guard: allow list
        case .settingsVoiceOver: ["device", "settings", "voiceover"] // source-guard: allow list
        case .orientationGet: ["device", "orientation", "get"] // source-guard: allow list
        case .orientationSet: ["device", "orientation", "set"] // source-guard: allow list
        case .simulateLocationCoordinate: ["device", "simulate", "location", "coordinate"] // source-guard: allow list
        case .simulateLocationClear: ["device", "simulate", "location", "clear"] // source-guard: allow list
        case .sendMemoryWarning: ["device", "process", "sendMemoryWarning"] // source-guard: allow list
        case .pasteboardCopy: ["device", "pasteboard", "copy"] // source-guard: allow list
        case .pasteboardPaste: ["device", "pasteboard", "paste"] // source-guard: allow list
        }
    }
}

/// The management commands the right-click menu of a physical device adds
/// (Device Hub's Restart, Rename, Collect
/// sysdiagnose and Unpair, and the Pair Nearby Device sheet's pairing), one
/// fixed shape each, with the tail checked flag
/// by flag (`DevicectlPhysicalClient.isValidManagementTail`). They carry
/// their own words (`reboot` and `rename` have two, `unpair` lives under
/// `manage`); every other word under `manage` (`ddis`, `loggingProfile`,
/// ...) stays refused. `pair` is the user-initiated pairing of the Pair
/// Nearby Device sheet: it runs only there,
/// only against a device the lister reported unpaired.
public enum DevicectlPhysicalManagement: CaseIterable, Sendable {
    case reboot, rename, sysdiagnose, unpair, pair

    /// The words devicectl is given ahead of the common options.
    public var words: [String] {
        switch self {
        case .reboot: ["device", "reboot"] // source-guard: allow list
        case .rename: ["device", "rename"] // source-guard: allow list
        case .sysdiagnose: ["device", "sysdiagnose"] // source-guard: allow list
        case .unpair: ["manage", "unpair"] // source-guard: allow list
        case .pair: ["manage", "pair"] // source-guard: allow list
        }
    }
}

/// What a management command answered: CoreDevice writes a `result` for some
/// (`sysdiagnose`) and none for others (`reboot`, `unpair`), so nothing is
/// required of it.
public struct DevicectlManagementResult: Decodable, Sendable, Equatable {}

/// Where `device info files` and `device copy from` read: an app's data
/// container (a development build's, by bundle identifier) or the device's
/// system crash logs.
public enum DevicectlPhysicalDomain: Sendable, Equatable {
    case appDataContainer(bundleID: String)
    case systemCrashLogs

    /// The `--domain-type` and `--domain-identifier` arguments.
    var arguments: [String] {
        switch self {
        case .appDataContainer(let bundleID):
            return ["--domain-type", "appDataContainer", "--domain-identifier", bundleID]
        case .systemCrashLogs:
            return ["--domain-type", "systemCrashLogs"]
        }
    }
}

/// Runs the CoreDevice `devicectl` binary against one physical iPhone.
///
/// The client is bound to an `ApplePhysicalDevice`, a value only
/// `ApplePhysicalDeviceLister` produces after an explicit opt-in, and every
/// command carries `--device <that CoreDevice identifier>`. It runs exactly
/// the nine `device info` reads of `DevicectlPhysicalInfoSubcommand`, the
/// ten actions of `DevicectlPhysicalAction` (install, uninstall, launch,
/// terminate, open URL, screenshot, screen recording, `info files` and
/// `copy from`) and the nine Controls commands of `DevicectlPhysicalControl`
/// (appearance, VoiceOver, orientation, simulated location, the memory
/// warning, the pasteboard's copy and paste), each in one fixed argument
/// shape, the four management commands of `DevicectlPhysicalManagement`
/// (reboot, rename, sysdiagnose, unpair), and refuses everything else: it
/// never enumerates devices, pairs, resets, changes any other setting
/// (biometrics included), simulates anything else, installs profiles, sends
/// input or copies files to the phone (beside `copy to` an app's container).
public final class DevicectlPhysicalClient: Sendable {
    public let devicectlURL: URL
    public let device: ApplePhysicalDevice
    public let developerDirectory: URL?
    /// devicectl's `-t`; the process itself gets a few seconds more.
    public let commandTimeout: Duration
    /// What runs the one privileged command (`osascript`; a test's fake).
    let privilegedLauncher: URL

    public static let defaultTimeout: Duration = .seconds(30)

    /// `osascript`, which shows the administrator dialog for `sysdiagnose`.
    public static let defaultPrivilegedLauncher = DevicectlPrivilegedRunner.defaultLauncher

    /// `install app` moves a whole bundle; it gets at least this long.
    public static let installTimeout: Duration = .seconds(120)

    /// Words that refuse a command outright when they are one of its three
    /// subcommand words (`copy to` is checked as a pair).
    static let refusedCommands: Set<String> = ["list", "manage", "pair", "pairings", "reset", "settings", "profile", "notification", "simulate", "orientation", "pasteboard", "motion", "appResize"] // source-guard: refusal list

    /// Every command the client may run, in a stable order: the nine
    /// `device info` reads, the actions, then the Controls commands.
    public static var allowedCommandWords: [[String]] {
        DevicectlPhysicalInfoSubcommand.allCases.map { ["device", "info", $0.rawValue] }
            + DevicectlPhysicalAction.allCases.map(\.words)
            + DevicectlPhysicalControl.allCases.map(\.words)
            + DevicectlPhysicalManagement.allCases.map(\.words)
            + [DevicectlPhysicalAction.launchApp.words + [Self.consoleFlag]]
    }

    /// The ordinary launch's three words, which the console launch shares.
    static var launchWords: [String] { DevicectlPhysicalAction.launchApp.words }

    public init(
        devicectlURL: URL,
        device: ApplePhysicalDevice,
        developerDirectory: URL? = nil,
        commandTimeout: Duration = DevicectlPhysicalClient.defaultTimeout,
        privilegedLauncher: URL = DevicectlPhysicalClient.defaultPrivilegedLauncher
    ) throws {
        guard UUID(uuidString: device.coreDeviceIdentifier) != nil else {
            throw DevicectlClientError.invalidValue("CoreDevice identifier \(device.coreDeviceIdentifier)")
        }
        self.devicectlURL = devicectlURL
        self.device = device
        self.developerDirectory = developerDirectory
        self.commandTimeout = commandTimeout
        self.privilegedLauncher = privilegedLauncher
    }

    // MARK: The gate

    /// The full argv for a command: its three subcommand words, then the
    /// device, the JSON destination, quiet output and the timeout, then the
    /// command's own options and operands (so an app's launch arguments come
    /// last). Refuses anything but one of the allowed shapes.
    public func commandLine(_ command: [String], jsonOutput: URL, timeout: Duration? = nil) throws -> [String] {
        let wordCount = try Self.validate(command)
        let seconds = max(1, Int((timeout ?? commandTimeout).components.seconds))
        return Array(command.prefix(wordCount))
            + ["--device", device.coreDeviceIdentifier, "--json-output", jsonOutput.path, "-q", "-t", String(seconds)]
            + Array(command.dropFirst(wordCount))
    }

    /// Throws `DevicectlClientError.refusedCommand` unless `command` is a
    /// `device info <read>`, one of the actions or one of the Controls
    /// commands in its exact shape; answers how many leading words are the
    /// subcommand (three, or four for the location commands).
    @discardableResult
    static func validate(_ command: [String]) throws -> Int {
        let refusal = DevicectlClientError.refusedCommand(command.joined(separator: " "))
        // A Controls command is matched, whole, before the refusal words are
        // consulted: `settings`, `simulate`, `orientation` and `pasteboard`
        // stay refused for every other shape.
        if let control = DevicectlPhysicalControl.allCases.first(where: { command.starts(with: $0.words) }) {
            let tail = Array(command.dropFirst(control.words.count))
            guard isValidControlTail(tail, for: control) else { throw refusal }
            return control.words.count
        }
        // A management command is matched, whole, before the refusal words
        // are consulted: `manage` stays refused for every other shape.
        if let management = DevicectlPhysicalManagement.allCases.first(where: { command.starts(with: $0.words) }) {
            let tail = Array(command.dropFirst(management.words.count))
            guard isValidManagementTail(tail, for: management) else { throw refusal }
            return management.words.count
        }
        // The console launch of the log pane is
        // matched, whole, by its own shape: `--console` is refused in every
        // other launch (`isValid(_:for:)` reads a leading dash as an option).
        if command.starts(with: DevicectlPhysicalAction.launchApp.words),
           command.dropFirst(3).first == Self.consoleFlag {
            guard isValidConsoleTail(Array(command.dropFirst(3))) else { throw refusal }
            return 3
        }
        let words = Array(command.prefix(3))
        // A refused word among the subcommand words is refused even inside an
        // otherwise plausible shape; operands (paths, bundle identifiers,
        // launch arguments) are not subcommand words.
        for (index, word) in words.enumerated() {
            if refusedCommands.contains(word) { throw refusal }
            if index + 1 < words.count, refusedCommands.contains(word + " " + words[index + 1]) { throw refusal }
        }
        guard words.count == 3, words[0] == "device" else { throw refusal }
        let tail = Array(command.dropFirst(3))

        if words[1] == "info", let read = DevicectlPhysicalInfoSubcommand(rawValue: words[2]) {
            // `info apps` may also list the default (system) apps, with that
            // one flag; every other read takes no option.
            guard tail.isEmpty || (read == .apps && (tail == [Self.includeDefaultAppsFlag] || tail == [Self.includeAllAppsFlag])) else { throw refusal }
            return 3
        }
        guard let action = DevicectlPhysicalAction.allCases.first(where: { $0.words == words }),
              isValid(tail, for: action)
        else { throw refusal }
        return 3
    }

    private static func isValid(_ tail: [String], for action: DevicectlPhysicalAction) -> Bool {
        switch action {
        case .infoFiles:
            return domainArguments(tail) != nil && domainArguments(tail)?.count == tail.count
        case .installApp:
            return tail.count == 1 && isPlainPath(tail[0])
        case .uninstallApp:
            return tail.count == 1 && isBundleID(tail[0])
        case .launchApp:
            var rest = tail[...]
            if rest.first == "--terminate-existing" { rest = rest.dropFirst() }
            guard let bundleID = rest.first, isBundleID(bundleID) else { return false }
            // Arguments starting with "-" would be read as devicectl options
            // (`--console` blocks, `--start-stopped` suspends the app).
            return rest.dropFirst().allSatisfy { !$0.hasPrefix("-") && !$0.contains("\0") }
        case .terminate:
            return tail.count == 2 && tail[0] == "--pid" && (Int(tail[1]).map { $0 > 0 } ?? false)
        case .openURL:
            return tail.count == 1 && isURL(tail[0])
        case .screenshot:
            return tail.count == 2 && tail[0] == "--destination" && isPlainPath(tail[1])
                && tail[1].lowercased().hasSuffix(".png")
        case .screenRecord:
            return tail.count == 4 && tail[0] == "--destination" && isPlainPath(tail[1])
                && tail[1].lowercased().hasSuffix(".mp4")
                && tail[2] == "--duration" && (Int(tail[3]).map { $0 > 0 } ?? false)
        case .appIcon:
            return tail.count == 8 && tail[0] == "--app-bundle-id" && isBundleID(tail[1])
                && tail[2] == "--width" && isIconSize(tail[3])
                && tail[4] == "--height" && isIconSize(tail[5])
                && tail[6] == "--destination" && isPlainPath(tail[7])
                && tail[7].lowercased().hasSuffix(".png")
        case .copyFrom:
            guard let domain = domainArguments(tail) else { return false }
            let rest = Array(tail.dropFirst(domain.count))
            return rest.count == 4 && rest[0] == "--source" && isRelativePath(rest[1])
                && rest[2] == "--destination" && isPlainPath(rest[3])
        case .copyTo:
            // Only an app's data container (never the crash logs or a group
            // container), one `--source` on this Mac and a relative path in the app.
            guard tail.starts(with: ["--domain-type", "appDataContainer", "--domain-identifier"]),
                  tail.count == 8, isBundleID(tail[3]) else { return false }
            return tail[4] == "--source" && isPlainPath(tail[5])
                && tail[6] == "--destination" && isRelativePath(tail[7])
        }
    }

    /// The leading `--domain-type …` arguments of `tail` when they are one of
    /// the two allowed domains, else nil.
    private static func domainArguments(_ tail: [String]) -> [String]? {
        if tail.starts(with: ["--domain-type", "appDataContainer", "--domain-identifier"]),
           tail.count >= 4, isBundleID(tail[3]) {
            return Array(tail.prefix(4))
        }
        if tail.starts(with: ["--domain-type", "systemCrashLogs"]),
           tail.count == 2 || tail[2] != "--domain-identifier" {
            return Array(tail.prefix(2))
        }
        return nil
    }

    /// Whether `tail` is exactly the one shape a management command may have:
    /// nothing for `reboot` (a full restart), `unpair` and `pair`, `--name <name>` for
    /// `rename` (a non-empty single line), `--destination <folder>` for
    /// `sysdiagnose`.
    static func isValidManagementTail(_ tail: [String], for management: DevicectlPhysicalManagement) -> Bool {
        switch management {
        case .reboot, .unpair, .pair:
            return tail.isEmpty
        case .rename:
            return tail.count == 2 && tail[0] == "--name" && isDeviceName(tail[1])
        case .sysdiagnose:
            return tail.count == 2 && tail[0] == "--destination" && isPlainPath(tail[1])
        }
    }

    /// A device name: not empty, one line, at most 255 characters.
    static func isDeviceName(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && text.count <= 255 && !text.contains("\0")
            && !text.contains("\n") && !text.contains("\r")
    }

    /// `device info apps`'s one option: also list the default (system) apps.
    static let includeDefaultAppsFlag = "--include-default-apps"
    static let includeAllAppsFlag = "--include-all-apps"

    /// A pixel size of an icon request: 1 to 1024.
    static func isIconSize(_ text: String) -> Bool {
        Int(text).map { (1...1024).contains($0) } ?? false
    }

    /// A reverse-DNS bundle identifier: letters, digits, dot, hyphen and
    /// underscore, starting with a letter or digit.
    static func isBundleID(_ text: String) -> Bool {
        guard let first = text.first, first.isASCII, first.isLetter || first.isNumber, text.count <= 155 else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    /// A file path devicectl reads or writes: non-empty, never an option.
    static func isPlainPath(_ text: String) -> Bool {
        !text.isEmpty && !text.hasPrefix("-") && !text.contains("\0") && !text.contains("\n")
    }

    /// A path inside a domain: relative, without `..`.
    static func isRelativePath(_ text: String) -> Bool {
        isPlainPath(text) && !text.hasPrefix("/") && !text.split(separator: "/").contains("..")
    }

    static func isURL(_ text: String) -> Bool {
        guard isPlainPath(text), let url = URL(string: text), let scheme = url.scheme else { return false }
        return !scheme.isEmpty
    }

    // MARK: Commands (`device info`, read-only)

    /// `device info details`: identity, OS, connection and the capability list.
    public func details() async throws -> DevicectlResult<DevicectlDeviceDetails> {
        try await run(.details, as: DevicectlDeviceDetails.self)
    }

    /// `device info apps`: installed apps (the default list omits system apps).
    /// `includeDefaultApps` adds `--include-default-apps`, the whole list
    /// Device Hub's "All Apps" shows (the default apps that ship with the OS).
    /// `includeAll` adds `--include-all-apps` instead (default apps, app clips and
    /// removable apps; the session's foreground candidates), and wins.
    public func apps(includeDefaultApps: Bool = false, includeAll: Bool = false) async throws -> DevicectlResult<DevicectlAppList> {
        var command = ["device", "info", DevicectlPhysicalInfoSubcommand.apps.rawValue]
        if includeAll { command.append(Self.includeAllAppsFlag) } else if includeDefaultApps { command.append(Self.includeDefaultAppsFlag) }
        return try await run(command, as: DevicectlAppList.self)
    }

    /// `device info processes`: running processes.
    public func processes() async throws -> DevicectlResult<DevicectlProcessList> {
        try await run(.processes, as: DevicectlProcessList.self)
    }

    /// `device info displays`: displays and orientation.
    public func displays() async throws -> DevicectlResult<DevicectlDisplays> {
        try await run(.displays, as: DevicectlDisplays.self)
    }

    /// `device info lockState`.
    public func lockState() async throws -> DevicectlResult<DevicectlLockState> {
        try await run(.lockState, as: DevicectlLockState.self)
    }

    /// `device info appearance`.
    public func appearance() async throws -> DevicectlResult<DevicectlAppearance> {
        try await run(.appearance, as: DevicectlAppearance.self)
    }

    /// `device info voiceover`: the query only (`operation` is "query").
    public func voiceover() async throws -> DevicectlResult<DevicectlVoiceOver> {
        try await run(.voiceover, as: DevicectlVoiceOver.self)
    }

    /// `device info ddiServices`: the Developer Disk Image metadata.
    public func ddiServices() async throws -> DevicectlResult<DevicectlDDIServices> {
        try await run(.ddiServices, as: DevicectlDDIServices.self)
    }

    /// `device info audio`: iPhones without audio output selection answer
    /// with `DevicectlPhysicalError.unsupportedCapability`.
    public func audio() async throws -> DevicectlResult<DevicectlAudio> {
        try await run(.audio, as: DevicectlAudio.self)
    }

    // MARK: Commands (actions)

    /// `device install app <path>`: installs a signed `.app` (a development
    /// build whose provisioning profile lists this device).
    public func installApp(at app: URL) async throws -> DevicectlResult<DevicectlInstallResult> {
        try await run(
            DevicectlPhysicalAction.installApp.words + [app.path],
            as: DevicectlInstallResult.self,
            timeout: max(commandTimeout, Self.installTimeout)
        )
    }

    /// `device uninstall app <bundleID>`. Succeeds when the app is not
    /// installed, too (captured), so a caller checks `apps()` when it must know.
    public func uninstallApp(bundleID: String) async throws -> DevicectlResult<DevicectlUninstallResult> {
        try await run(DevicectlPhysicalAction.uninstallApp.words + [bundleID], as: DevicectlUninstallResult.self)
    }

    /// `device process launch [--terminate-existing] <bundleID> [arguments]`.
    /// The answer holds the pid (`value.processIdentifier`), what
    /// `terminate(pid:)` takes. An application that is not installed fails
    /// with `DevicectlPhysicalError.applicationFailedToLaunch`. Arguments that
    /// begin with `-` are refused.
    public func launchApp(
        bundleID: String,
        terminateExisting: Bool = false,
        arguments: [String] = []
    ) async throws -> DevicectlResult<DevicectlLaunchResult> {
        let options = terminateExisting ? ["--terminate-existing"] : []
        return try await run(
            DevicectlPhysicalAction.launchApp.words + options + [bundleID] + arguments,
            as: DevicectlLaunchResult.self
        )
    }

    /// `device process terminate --pid <pid>`: a SIGTERM. A pid that is gone
    /// fails with `DevicectlPhysicalError.failedToSendSignal`.
    public func terminate(pid: Int) async throws -> DevicectlResult<DevicectlTerminateResult> {
        try await run(
            DevicectlPhysicalAction.terminate.words + ["--pid", String(pid)],
            as: DevicectlTerminateResult.self
        )
    }

    /// `device process openURL <url>`: hands the URL to the app that owns its
    /// scheme (an https URL brings the default browser to the front).
    public func openURL(_ url: URL) async throws -> DevicectlResult<DevicectlOpenURLResult> {
        try await run(DevicectlPhysicalAction.openURL.words + [url.absoluteString], as: DevicectlOpenURLResult.self)
    }

    /// `device capture screenshot --destination <path>`: a PNG at full pixel
    /// size (`destination` must end in `.png`).
    public func screenshot(to destination: URL) async throws -> DevicectlResult<DevicectlScreenshotResult> {
        try await run(
            DevicectlPhysicalAction.screenshot.words + ["--destination", destination.path],
            as: DevicectlScreenshotResult.self
        )
    }

    /// `device info appIcon --app-bundle-id <id> --width <n> --height <n>
    /// --destination <x.png>`: the app's icon as a PNG file at (about) the
    /// size asked for (the device returns the sizes it supports; the answer
    /// says which). A placeholder icon is never returned (devicectl's
    /// default); an app the device does not know fails (CoreDevice 6003).
    public func appIcon(
        bundleID: String,
        width: Int,
        height: Int,
        to destination: URL
    ) async throws -> DevicectlResult<DevicectlAppIconResult> {
        try await run(
            DevicectlPhysicalAction.appIcon.words
                + ["--app-bundle-id", bundleID, "--width", String(width), "--height", String(height),
                   "--destination", destination.path],
            as: DevicectlAppIconResult.self
        )
    }

    /// `device info files` for one domain: the app data container of a
    /// development build, or the system crash logs.
    public func listFiles(domain: DevicectlPhysicalDomain) async throws -> DevicectlResult<DevicectlFileList> {
        try await run(DevicectlPhysicalAction.infoFiles.words + domain.arguments, as: DevicectlFileList.self)
    }

    /// `device copy from … --source <path in the domain> --destination <file>`:
    /// copies one file from the phone to this Mac (never the reverse).
    public func copyFrom(
        domain: DevicectlPhysicalDomain,
        source: String,
        to destination: URL
    ) async throws -> DevicectlResult<DevicectlCopyResult> {
        try await run(
            DevicectlPhysicalAction.copyFrom.words + domain.arguments
                + ["--source", source, "--destination", destination.path],
            as: DevicectlCopyResult.self
        )
    }

    /// `device copy to … --source <file or folder on this Mac> --destination <path in the
    /// app's container>` (Send Files): into an app's data
    /// container only, a folder keeping its tree. HELP-DERIVED (Xcode 27.0 27A266a,
    /// `devicectl device copy to -h`); never run against a real device by a test.
    public func copyTo(
        source: URL,
        bundleID: String,
        destination: String,
        timeout: Duration? = nil
    ) async throws -> DevicectlResult<DevicectlCopyResult> {
        try await run(
            DevicectlPhysicalAction.copyTo.words + DevicectlPhysicalDomain.appDataContainer(bundleID: bundleID).arguments
                + ["--source", source.path, "--destination", destination],
            as: DevicectlCopyResult.self,
            timeout: timeout ?? Self.installTimeout
        )
    }

    /// `device capture screen-record --destination <x.mp4> --duration <n>`.
    /// devicectl rejects a destination that does not end in `.mp4`. The
    /// iPhone 12 on iOS 27 lacks the capability (`unsupportedCapability`,
    /// feature `com.apple.coredevice.feature.screenrecording`).
    public func screenRecord(
        to destination: URL,
        duration: Duration
    ) async throws -> DevicectlResult<DevicectlScreenRecordResult> {
        let seconds = max(1, Int(duration.components.seconds))
        return try await run(
            DevicectlPhysicalAction.screenRecord.words
                + ["--destination", destination.path, "--duration", String(seconds)],
            as: DevicectlScreenRecordResult.self,
            timeout: commandTimeout + .seconds(seconds)
        )
    }

    // MARK: Commands (management)

    /// A sysdiagnose takes minutes.
    public static let sysdiagnoseTimeout: Duration = .seconds(600)

    /// `device reboot`: a full restart of the phone.
    public func reboot() async throws {
        try await runManagement(DevicectlPhysicalManagement.reboot.words)
    }

    /// `device rename --name <name>`: the user-visible name of the phone.
    public func rename(to name: String) async throws {
        try await runManagement(DevicectlPhysicalManagement.rename.words + ["--name", name])
    }

    /// `device sysdiagnose --destination <folder>`: gathers the phone's
    /// sysdiagnose and puts it into `folder` (it takes minutes: the timeout is
    /// ten). devicectl asks for the Mac's administrator password for this one
    /// command (a terminal prompt, DiagnoseError 0 without one), so it runs
    /// through macOS's authorization dialog (`DevicectlPrivilegedRunner`,
    /// into a private work folder, which is then
    /// moved into `folder` as the user. Answers the files' places. Throws
    /// `DevicectlPrivilegedError.cancelled` when the user dismisses the dialog.
    @discardableResult
    public func sysdiagnose(into folder: URL) async throws -> [URL] {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-sysdiagnose-\(UUID().uuidString)", isDirectory: true)
        let files = work.appendingPathComponent("collected", isDirectory: true)
        let output = work.appendingPathComponent("result.json")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let command = DevicectlPhysicalManagement.sysdiagnose.words + ["--destination", files.path]
        let argv = try commandLine(command, jsonOutput: output, timeout: Self.sysdiagnoseTimeout)
        let script = DevicectlPrivilegedRunner.shellScript(
            devicectl: devicectlURL,
            arguments: argv,
            developerDirectory: developerDirectory,
            workFolder: work,
            userID: getuid(),
            groupID: getgid()
        )
        do {
            try await DevicectlPrivilegedRunner.run(
                launcher: privilegedLauncher,
                script: script,
                prompt: "Device Hub Pro needs your administrator password to collect a sysdiagnose.",
                commandTimeout: Self.sysdiagnoseTimeout
            )
        } catch let privileged as DevicectlPrivilegedError {
            // A devicectl error document says more than osascript's line.
            if case .failed = privileged, let data = try? Data(contentsOf: output),
               let typed = Self.managementError(in: data) {
                throw typed
            }
            throw privileged
        }
        if let data = try? Data(contentsOf: output), !data.isEmpty, let typed = Self.managementError(in: data) {
            throw typed
        }
        return try DevicectlPrivilegedRunner.moveContents(of: files, into: folder)
    }

    /// The error a devicectl JSON document carries, or nil for a success.
    static func managementError(in json: Data) -> Error? {
        do {
            _ = try DevicectlJSON.decode(DevicectlManagementResult.self, from: json)
            return nil
        } catch DevicectlJSON.DecodeError.missingResult {
            return (try? DevicectlJSON.info(from: json))?.succeeded == true
                ? nil : DevicectlJSON.DecodeError.missingResult(commandType: "device sysdiagnose")
        } catch let error as DevicectlError {
            return typed(error) ?? error
        } catch {
            return error
        }
    }

    /// `manage unpair`: forgets the pairing of a manually paired phone.
    public func unpair() async throws {
        try await runManagement(DevicectlPhysicalManagement.unpair.words)
    }

    /// How long `manage pair` may wait: the phone asks its owner to accept
    /// (and, on some iOS versions, shows a code), which takes a while.
    public static let pairTimeout: Duration = .seconds(120)

    /// `manage pair --device <id>`: asks the phone to pair with this Mac (the
    /// phone shows its trust prompt). Only the Pair Nearby Device sheet calls
    /// it, for a device the lister reported unpaired; the command's shape has
    /// no code option (`devicectl manage pair -h`, Xcode 27.0).
    public func pair() async throws {
        guard !device.isPaired else { throw DevicectlClientError.refusedCommand("manage pair (already paired)") }
        try await runManagement(DevicectlPhysicalManagement.pair.words, timeout: Self.pairTimeout)
    }

    /// Runs one management command. A success may carry no `result`: only an
    /// error document or a usage error is a failure.
    private func runManagement(_ command: [String], timeout: Duration? = nil) async throws {
        let output = DevicectlJSONFile.temporaryURL(purpose: "action")
        defer { DevicectlJSONFile.remove(output) }
        let argv = try commandLine(command, jsonOutput: output, timeout: timeout)
        let label = command.prefix(3).joined(separator: " ")
        let ran = try await DevicectlJSONFile.runCapturingOutput(
            devicectlURL: devicectlURL,
            arguments: argv,
            jsonOutput: output,
            developerDirectory: developerDirectory,
            commandTimeout: timeout ?? commandTimeout,
            label: label
        )
        do {
            _ = try DevicectlJSON.decode(DevicectlManagementResult.self, from: ran.json)
        } catch DevicectlJSON.DecodeError.missingResult {
            // "success" without a result is done; anything else is not.
            guard (try? DevicectlJSON.info(from: ran.json))?.succeeded == true else {
                throw DevicectlJSON.DecodeError.missingResult(commandType: label)
            }
        } catch let error as DevicectlError {
            throw Self.typed(error) ?? error
        }
    }

    // MARK: Running

    func run<Value: Decodable & Sendable>(
        _ subcommand: DevicectlPhysicalInfoSubcommand,
        as type: Value.Type
    ) async throws -> DevicectlResult<Value> {
        try await run(["device", "info", subcommand.rawValue], as: type)
    }

    func run<Value: Decodable & Sendable>(
        _ command: [String],
        as type: Value.Type,
        timeout: Duration? = nil
    ) async throws -> DevicectlResult<Value> {
        try await runCapturingOutput(command, as: type, timeout: timeout).result
    }

    /// Like `run`, and also answers what devicectl printed on standard output
    /// (`pasteboard paste` prints the pasteboard's text there).
    func runCapturingOutput<Value: Decodable & Sendable>(
        _ command: [String],
        as type: Value.Type,
        timeout: Duration? = nil
    ) async throws -> (result: DevicectlResult<Value>, standardOutput: Data) {
        let output = DevicectlJSONFile.temporaryURL(purpose: "info")
        defer { DevicectlJSONFile.remove(output) }
        let argv = try commandLine(command, jsonOutput: output, timeout: timeout)
        let ran = try await DevicectlJSONFile.runCapturingOutput(
            devicectlURL: devicectlURL,
            arguments: argv,
            jsonOutput: output,
            developerDirectory: developerDirectory,
            commandTimeout: timeout ?? commandTimeout,
            label: command.prefix(3).joined(separator: " ")
        )
        do {
            return (try DevicectlJSON.decode(type, from: ran.json), ran.standardOutput)
        } catch let error as DevicectlError {
            throw Self.typed(error) ?? error
        }
    }

    /// The typed error for the CoreDevice codes this client knows, or nil.
    static func typed(_ error: DevicectlError) -> DevicectlPhysicalError? {
        if let frame = error.frames.first(where: { $0.code == DevicectlError.Code.capabilityNotSupported }) {
            return .unsupportedCapability(
                featureIdentifier: frame.capabilityFeatureIdentifier,
                name: frame.capabilityName
            )
        }
        guard let frame = error.frames.first else { return nil }
        switch frame.code {
        case DevicectlError.Code.applicationFailedToLaunch where frame.domain == DevicectlError.coreDeviceDomain:
            return .applicationFailedToLaunch(message: frame.message ?? "", reason: frame.failureReason)
        case DevicectlError.Code.failedToSendSignal where frame.domain == DevicectlError.coreDeviceDomain:
            return .failedToSendSignal(message: frame.message ?? "", reason: frame.failureReason)
        default:
            return nil
        }
    }
}

/// Runs devicectl with its JSON written to a temporary file (`--json-output
/// <path>`), which keeps stdout free for human-readable text. Shared by the
/// physical client and the lister.
enum DevicectlJSONFile {
    static func temporaryURL(purpose: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-devicectl-\(purpose)-\(UUID().uuidString).json")
    }

    static func remove(_ url: URL) {
        // Best effort: a leftover temporary file must not fail a call.
        try? FileManager.default.removeItem(at: url)
    }

    /// Runs `arguments` and returns the JSON document devicectl wrote to
    /// `jsonOutput`. A missing or empty file with a non-zero exit is a usage
    /// error (devicectl prints those to stderr only).
    static func run(
        devicectlURL: URL,
        arguments: [String],
        jsonOutput: URL,
        developerDirectory: URL?,
        commandTimeout: Duration,
        label: String
    ) async throws -> Data {
        try await runCapturingOutput(
            devicectlURL: devicectlURL,
            arguments: arguments,
            jsonOutput: jsonOutput,
            developerDirectory: developerDirectory,
            commandTimeout: commandTimeout,
            label: label
        ).json
    }

    /// `run`, with the process's standard output beside the JSON document.
    static func runCapturingOutput(
        devicectlURL: URL,
        arguments: [String],
        jsonOutput: URL,
        developerDirectory: URL?,
        commandTimeout: Duration,
        label: String
    ) async throws -> (json: Data, standardOutput: Data) {
        var environment: [String: String]?
        if let developerDirectory {
            environment = ["DEVELOPER_DIR": developerDirectory.path]
        }
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: devicectlURL,
                arguments: arguments,
                environment: environment,
                timeout: commandTimeout + .seconds(5)
            )
        } catch ProcessRunnerError.timedOut(_, let seconds) {
            throw ProcessRunnerError.timedOut(command: "devicectl \(label)", seconds: seconds)
        }
        // A missing file is the "no document" case below.
        let data = (try? Data(contentsOf: jsonOutput)) ?? Data()
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }), result.exitCode != 0 {
            let message = result.standardErrorText
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init) ?? ""
            throw DevicectlClientError.usage(exitCode: result.exitCode, message: message)
        }
        return (data, result.standardOutput)
    }
}
