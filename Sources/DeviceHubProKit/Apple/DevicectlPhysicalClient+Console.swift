import Foundation

/// The console launch the physical iPhone's log pane runs: `devicectl device process launch --device <id> --console
/// --terminate-existing --environment-variables <json> <bundle id>`, which
/// starts one app with its standard streams bridged to devicectl's, the way
/// Xcode's console reads them (flags per `devicectl device process launch -h`,
/// Xcode 27.0 27A266a: HELP-DERIVED, and the bridge itself captured live on
/// the dedicated test iPhone). Ending devicectl (SIGINT) ends the app.
///
/// It is the one shape of the client that does not write JSON: it streams
/// lines (`PhysicalConsoleLogStream`), and carries no `-t` timeout, which
/// would end a session of any length.
extension DevicectlPhysicalClient {
    /// `--console`: attaches the app to the console and waits for it to exit.
    static let consoleFlag = "--console"

    /// The environment variables a console launch may set, and the values each
    /// may take. `OS_ACTIVITY_DT_MODE` makes the app's os_log, Logger and
    /// NSLog messages also go to stderr (what Xcode sets); `OS_ACTIVITY_MODE`
    /// `debug` adds the debug-level messages. Anything else is refused:
    /// `IDEPreferLogStreaming` was measured to change nothing.
    static let consoleEnvironmentValues: [String: Set<String>] = [
        "OS_ACTIVITY_DT_MODE": ["enable", "YES"],
        "OS_ACTIVITY_MODE": ["debug"],
    ]

    /// What the log pane sends: mirror os_log to stderr, debug level included.
    public static let defaultConsoleEnvironment: [String: String] = [
        "OS_ACTIVITY_DT_MODE": "enable",
        "OS_ACTIVITY_MODE": "debug",
    ]

    /// The JSON dictionary devicectl takes for `--environment-variables`, keys
    /// sorted so the shape is stable.
    static func consoleEnvironmentJSON(_ environment: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: environment, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw DevicectlClientError.invalidValue("console environment")
        }
        return text
    }

    /// Whether `tail` (what follows the three launch words) is exactly
    /// `--console --terminate-existing --environment-variables <json> <bundle
    /// id>`, the JSON a dictionary of allowed keys and values.
    static func isValidConsoleTail(_ tail: [String]) -> Bool {
        guard tail.count == 5,
              tail[0] == consoleFlag,
              tail[1] == "--terminate-existing",
              tail[2] == "--environment-variables",
              isBundleID(tail[4]),
              let object = try? JSONSerialization.jsonObject(with: Data(tail[3].utf8)),
              let environment = object as? [String: String],
              !environment.isEmpty
        else { return false }
        return environment.allSatisfy { key, value in consoleEnvironmentValues[key]?.contains(value) == true }
    }

    /// The full argv of a console launch of `bundleID`; refuses anything but
    /// the one allowed shape.
    public func consoleCommandLine(
        bundleID: String,
        environment: [String: String] = DevicectlPhysicalClient.defaultConsoleEnvironment
    ) throws -> [String] {
        let words = Self.launchWords
        let tail = [
            Self.consoleFlag, "--terminate-existing", "--environment-variables",
            try Self.consoleEnvironmentJSON(environment), bundleID,
        ]
        try Self.validate(words + tail)
        return words + ["--device", device.coreDeviceIdentifier] + tail
    }
}
