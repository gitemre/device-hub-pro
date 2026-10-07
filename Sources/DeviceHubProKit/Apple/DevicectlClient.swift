import Foundation

/// Errors `DevicectlClient` raises before or instead of a decoded answer.
public enum DevicectlClientError: Error, Equatable, CustomStringConvertible {
    /// The device is not a simulator this client may address.
    case notASimulator(String)
    /// A subcommand this client never runs (device enumeration or management).
    case refusedCommand(String)
    /// devicectl rejected the arguments before running (exit 64, usage text on
    /// stderr, no JSON document).
    case usage(exitCode: Int32, message: String)
    /// A value Device Hub Pro rejects before running devicectl.
    case invalidValue(String)

    public var description: String {
        switch self {
        case .notASimulator(let identifier):
            return "devicectl may only address a listed simulator; '\(identifier)' is not one"
        case .refusedCommand(let command):
            return "devicectl \(command) is never run by Device Hub Pro"
        case .usage(let exitCode, let message):
            return "devicectl rejected the arguments (exit \(exitCode)): \(message)"
        case .invalidValue(let detail):
            return "Invalid value: \(detail)"
        }
    }
}

/// One `devicectl device settings appearance` change. The type holds exactly
/// one setting, so a call can never combine flags: CoreDevice applies a
/// multi-flag call all or nothing (21031 wrapping the first failure).
public enum DevicectlAppearanceSetting: Sendable, Equatable {
    case dark(Bool)
    case reduceMotion(Bool)
    case reduceTransparency(Bool)
    case increaseContrast(Bool)
    /// iOS Button Shapes.
    case showBorders(Bool)
    /// `off` turns the filter off; `on` alone brings back the last one.
    case colorFilter(Bool)
    /// A filter by type, which also turns it on (measured: `--color-filter-type`
    /// alone enables it), with an intensity for every type but Grayscale.
    /// devicectl takes the intensity only beside a type ("--color-filter-intensity
    /// requires --color-filter-type"), so the two travel as one setting.
    case colorFilterType(SimulatorColorFilterType, intensity: Double?)
    /// Required before an accessibility text size (21063 otherwise).
    case largerAccessibilitySizes(Bool)
    case textSize(SimulatorContentSize)
    /// 0.0 (fully translucent) to 1.0 (fully opaque).
    case liquidGlassOpacity(Double)
    /// Clear or Tinted Liquid Glass (iOS 26); iOS 27 lists one look only.
    case lookAndFeel(DevicectlLookAndFeel)

    /// Throws `DevicectlClientError.invalidValue` for a value devicectl would
    /// reject as a usage error: a text size that is only a read-only answer,
    /// an opacity outside 0–1, a colour filter intensity outside 0.25–1.
    public func validate() throws {
        switch self {
        case .textSize(let size) where !SimulatorContentSize.settable.contains(size):
            throw DevicectlClientError.invalidValue("text size \(size.rawValue) cannot be set")
        case .liquidGlassOpacity(let opacity) where !(0...1).contains(opacity):
            throw DevicectlClientError.invalidValue("Liquid Glass opacity \(opacity) is outside 0–1")
        case .colorFilterType(let type, let intensity?)
            where type.hasIntensity && !SimulatorColorFilterType.intensityRange.contains(intensity):
            throw DevicectlClientError.invalidValue("colour filter intensity \(intensity) is outside 0.25–1")
        default:
            break
        }
    }

    /// The flag and its value. Toggles take `on`/`off` (`true` is a usage
    /// error, exit 64).
    public var arguments: [String] {
        switch self {
        case .colorFilterType(let type, let intensity):
            var arguments = ["--color-filter-type", type.rawValue]
            if type.hasIntensity, let intensity {
                arguments += ["--color-filter-intensity", Self.decimal(intensity)]
            }
            return arguments
        case .liquidGlassOpacity(let opacity):
            return ["--liquid-glass-opacity", Self.decimal(opacity)]
        case .lookAndFeel(let look):
            return ["--look-and-feel", look.rawValue]
        case .dark(let on): return ["--mode", on ? "dark" : "light"]
        case .reduceMotion(let on): return ["--reduce-motion", Self.toggle(on)]
        case .reduceTransparency(let on): return ["--reduce-transparency", Self.toggle(on)]
        case .increaseContrast(let on): return ["--increase-contrast", Self.toggle(on)]
        case .showBorders(let on): return ["--show-borders", Self.toggle(on)]
        case .colorFilter(let on): return ["--color-filter", Self.toggle(on)]
        case .largerAccessibilitySizes(let on): return ["--larger-accessibility-sizes", Self.toggle(on)]
        case .textSize(let size): return ["--text-size", size.rawValue]
        }
    }

    private static func toggle(_ on: Bool) -> String { on ? "on" : "off" }

    /// Two decimals with a point, whatever the Mac's locale.
    static func decimal(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// The look `--look-and-feel` takes on an iOS 26 simulator: Clear or Tinted
/// Liquid Glass (Device Hub's Liquid Glass popup). The runtime reads them back
/// as "Clear Liquid Glass" / "Tinted Liquid Glass" (`supportedLooksAndFeels`).
public enum DevicectlLookAndFeel: String, Sendable, CaseIterable, Equatable {
    case clear
    case tinted

    public init?(devicectlName: String) {
        switch devicectlName {
        case "Clear Liquid Glass": self = .clear
        case "Tinted Liquid Glass": self = .tinted
        default: return nil
        }
    }

    /// Device Hub's popup titles.
    public var title: String {
        switch self {
        case .clear: "Clear"
        case .tinted: "Tinted"
        }
    }
}

/// Runs the CoreDevice `devicectl` binary against one simulator.
///
/// The client is bound to a `SimulatorDevice`, a value only a `simctl list`
/// read produces, and every command it runs carries `--device <that UDID>`,
/// `-j -` (the versioned JSON on stdout, human text on stderr) and `-t`
/// (devicectl's own timeout). It never enumerates devices (`list devices`)
/// or runs `manage`: a physical iPhone may be attached to the Mac, and
/// nothing Device Hub Pro runs may address it. CoreDevice does not see simulators
/// in a private `simctl --set` (error 1000, `DevicectlError.Code.deviceNotFound`).
public final class DevicectlClient: Sendable {
    public let devicectlURL: URL
    public let udid: String
    public let developerDirectory: URL?
    /// devicectl's `-t`; the process itself gets a few seconds more.
    public let commandTimeout: Duration

    public static let defaultTimeout: Duration = .seconds(30)

    /// Subcommand words this client refuses outright.
    static let refusedCommands: Set<String> = ["list", "manage"] // source-guard: refusal list

    public init(
        devicectlURL: URL,
        simulator: SimulatorDevice,
        developerDirectory: URL? = nil,
        commandTimeout: Duration = DevicectlClient.defaultTimeout
    ) throws {
        guard UUID(uuidString: simulator.udid) != nil else {
            throw DevicectlClientError.notASimulator(simulator.udid)
        }
        self.devicectlURL = devicectlURL
        self.udid = simulator.udid
        self.developerDirectory = developerDirectory
        self.commandTimeout = commandTimeout
    }

    /// The full argv for a `device …` command: the command, then the device,
    /// the JSON destination and the timeout.
    public func commandLine(_ command: [String]) throws -> [String] {
        if let first = command.first, Self.refusedCommands.contains(first) {
            throw DevicectlClientError.refusedCommand(command.joined(separator: " "))
        }
        let seconds = max(1, Int(commandTimeout.components.seconds))
        return command + ["--device", udid, "-j", "-", "-t", String(seconds)]
    }

    // MARK: Commands

    /// `device info details`: identity, OS, and the capability list.
    public func details() async throws -> DevicectlResult<DevicectlDeviceDetails> {
        try await run(["device", "info", "details"], as: DevicectlDeviceDetails.self)
    }

    /// `device info appearance`: every appearance and accessibility field in
    /// one read (about 6 s the first time after boot, 0.3 s warm).
    public func appearance() async throws -> DevicectlResult<DevicectlAppearance> {
        try await run(["device", "info", "appearance"], as: DevicectlAppearance.self)
    }

    /// `device settings appearance` with exactly one setting. A text size
    /// must be one of the twelve categories (`unknown` and `unsupported` are
    /// read-only answers, and devicectl rejects them as a usage error).
    @discardableResult
    public func setAppearance(_ setting: DevicectlAppearanceSetting) async throws -> DevicectlResult<DevicectlAppearance> {
        try setting.validate()
        return try await run(["device", "settings", "appearance"] + setting.arguments, as: DevicectlAppearance.self)
    }

    /// `device orientation get`.
    public func orientation() async throws -> DevicectlResult<DevicectlOrientation> {
        try await run(["device", "orientation", "get"], as: DevicectlOrientation.self)
    }

    /// `device orientation set <orientation>`: rotates the simulated device
    /// (the interface follows when the foreground app supports the pose; an
    /// iPhone's home screen stays portrait). About 0.1 s warm on CoreDevice
    /// 642.16; answers with the new orientation.
    @discardableResult
    public func setOrientation(_ orientation: SimulatorOrientation) async throws -> DevicectlResult<DevicectlOrientation> {
        try await run(["device", "orientation", "set", orientation.rawValue], as: DevicectlOrientation.self)
    }

    // MARK: Running

    func run<Value: Decodable & Sendable>(
        _ command: [String],
        as type: Value.Type
    ) async throws -> DevicectlResult<Value> {
        let argv = try commandLine(command)
        var environment: [String: String]?
        if let developerDirectory {
            environment = ["DEVELOPER_DIR": developerDirectory.path]
        }
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: devicectlURL,
                arguments: argv,
                environment: environment,
                timeout: commandTimeout + .seconds(5)
            )
        } catch ProcessRunnerError.timedOut(_, let seconds) {
            throw ProcessRunnerError.timedOut(
                command: (["devicectl"] + command).joined(separator: " "),
                seconds: seconds
            )
        }
        do {
            return try DevicectlJSON.decode(type, from: result.standardOutput)
        } catch DevicectlJSON.DecodeError.noDocument where result.exitCode != 0 {
            let message = result.standardErrorText
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init) ?? ""
            throw DevicectlClientError.usage(exitCode: result.exitCode, message: message)
        }
    }
}
