import Foundation

/// What "Launch with Options…" passes to `simctl launch`: arguments,
/// environment variables and two flags. The argv follows `simctl help launch`
/// (HELP-DERIVED, Xcode 27.0): `launch [-w] [--terminate-running-process]
/// <device> <bundle id> [<argv 1> … <argv n>]`, with the environment given to
/// simctl as `SIMCTL_CHILD_<KEY>`.
public struct SimulatorLaunchOptions: Codable, Sendable, Equatable {
    public struct Variable: Codable, Sendable, Equatable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case missingEquals(line: Int)
        case invalidKey(String)
        case duplicateKey(String)
        case nulInValue(String)

        public var description: String {
            switch self {
            case .missingEquals(let line): "Environment line \(line) needs the form KEY=value."
            case .invalidKey(let key):
                "\"\(key)\" is not a valid variable name: use letters, digits and underscores, not starting with a digit."
            case .duplicateKey(let key): "\(key) is set twice."
            case .nulInValue(let key): "The value of \(key) cannot contain a NUL character."
            }
        }
    }

    public static let environmentPrefix = "SIMCTL_CHILD_"

    public var arguments: [String]
    public var environment: [Variable]
    /// `-w`: the app starts suspended until a debugger attaches.
    public var waitForDebugger: Bool
    /// `--terminate-running-process`.
    public var terminateRunning: Bool

    public init(
        arguments: [String] = [],
        environment: [Variable] = [],
        waitForDebugger: Bool = false,
        terminateRunning: Bool = false
    ) {
        self.arguments = arguments
        self.environment = environment
        self.waitForDebugger = waitForDebugger
        self.terminateRunning = terminateRunning
    }

    /// One argument per line; blank lines are dropped and a stray tab at a
    /// line's ends is trimmed, nothing else (an argument may carry spaces).
    public static func parseArguments(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: Self.tabs) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static let tabs = CharacterSet(charactersIn: "\t")

    public static func argumentsText(_ arguments: [String]) -> String { arguments.joined(separator: "\n") }

    /// `KEY=value` per line (the first `=` splits; the value keeps any other).
    public static func parseEnvironment(_ text: String) throws -> [Variable] {
        var variables: [Variable] = []
        for (offset, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: Self.tabs)[...]
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let equals = line.firstIndex(of: "=") else { throw Problem.missingEquals(line: offset + 1) }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...])
            if let problem = validate(key: key, value: value) { throw problem }
            guard !variables.contains(where: { $0.key == key }) else { throw Problem.duplicateKey(key) }
            variables.append(Variable(key: key, value: value))
        }
        return variables
    }

    public static func environmentText(_ variables: [Variable]) -> String {
        variables.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    /// A POSIX-style name: `[A-Za-z_][A-Za-z0-9_]*`.
    public static func validate(key: String, value: String = "") -> Problem? {
        guard let first = key.unicodeScalars.first,
              first == "_" || (first.isASCII && CharacterSet.letters.contains(first)),
              key.unicodeScalars.allSatisfy({ $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) })
        else { return .invalidKey(key) }
        if value.unicodeScalars.contains("\0") { return .nulInValue(key) }
        return nil
    }

    /// The variables for simctl's own environment.
    public var simctlEnvironment: [String: String] {
        Dictionary(environment.map { (Self.environmentPrefix + $0.key, $0.value) }) { _, last in last }
    }

    /// The `simctl` arguments (without `--set`) and the positions holding
    /// free text (the app's arguments: they may read like a selector).
    public func commandArguments(udid: String, bundleIdentifier: String) -> (arguments: [String], freeText: Set<Int>) {
        var command = ["launch"]
        if waitForDebugger { command.append("--wait-for-debugger") }
        if terminateRunning { command.append("--terminate-running-process") }
        command += [udid, bundleIdentifier]
        let start = command.count
        command += arguments
        return (command, Set(start..<command.count))
    }
}
