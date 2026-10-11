import Foundation

/// The emulator's console: a line protocol on a loopback TCP port, the one
/// `adb emu` talks to.
///
/// Why the app talks to it itself. `adb emu <command>` sends `auth <token>`
/// only when `$HOME/.emulator_console_auth_token` is readable and not empty,
/// then the command, then `quit`, and from what comes back it always drops
/// the first two `OK` lines (one ends the greeting, one the authentication)
/// and prints the rest (`client/console.cpp`, `adb_send_emulator_command`). A
/// console that asks for no authentication, which an EMPTY token file is the
/// documented way to get, sends one `OK` before the command's answer, so adb
/// drops the answer with it and prints nothing with exit status 0. An
/// emulator on such a Mac could not be named (`adb emu avd name`) or found
/// (`avd discoverypath`, the gRPC port and token), and its mirror never came
/// up. `LiveEmulatorConsole` reads the greeting instead of counting `OK`s.
///
/// The protocol, as captured (`Fixtures/emulator-console/`): every line ends
/// in `\r\n`; the console greets with lines ending in `OK`, and the greeting
/// says `Authentication required` when the emulator wants `auth <token>`
/// first; an answer ends with a line that is `OK` or an error line (`KO`,
/// `KO: unknown command, try 'help'`, `KO usage: …`: see `isErrorLine`);
/// `quit` ends the session without an answer.
public enum EmulatorConsole {
    /// The file the emulator and adb read the console's authentication token
    /// from, in `$HOME`.
    public static let tokenFileName = ".emulator_console_auth_token"

    /// `$HOME/.emulator_console_auth_token`, where adb and the emulator look.
    public static func defaultTokenFile() -> URL {
        let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(tokenFileName)
    }

    /// The console port of an adb serial, as adb derives it
    /// (`adb_get_emulator_console_port`): an emulator is `emulator-<port>`,
    /// and its console listens on that port. Nil for any other serial (a
    /// phone, an `adb connect` address, a name that only starts like one).
    public static func port(forSerial serial: String) -> Int? {
        let prefix = "emulator-"
        guard serial.hasPrefix(prefix) else { return nil }
        let digits = serial.dropFirst(prefix.count)
        guard !digits.isEmpty,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(digits),
              (1...Int(UInt16.max)).contains(port)
        else { return nil }
        return port
    }

    /// Whether `line` (one line of the console's text, its line ending
    /// optional) is one of the console's error lines: `KO` alone, or `KO:` or
    /// `KO ` and a message (`KO: unknown command, try 'help'`, `KO usage: …`,
    /// `KO:  bad sub-command`, all captured). A line that merely starts with
    /// the letters is not one: an AVD name can (`KOMPAKT_Phone`: names take
    /// letters, digits, `.`, `_` and `-`, never `:` or a blank), and `avd
    /// name` answers with it.
    static func isErrorLine(_ line: some StringProtocol) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "KO" || trimmed.hasPrefix("KO:") || trimmed.hasPrefix("KO ")
    }

    /// Whether `line` ends an answer: `OK`, or an error line.
    static func isTerminator(_ line: some StringProtocol) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" || isErrorLine(line)
    }

    /// Whether `answer` (what a command printed, `adb emu` or the console
    /// itself) is the console's error: its first line is an error line (`KO:
    /// unknown command`), or its last is (the `avd` help text a console that
    /// wants authentication prints, then `KO:  bad sub-command`).
    static func isErrorAnswer(_ answer: String) -> Bool {
        let lines = answer
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first, let last = lines.last else { return false }
        return isErrorLine(first) || isErrorLine(last)
    }

    /// Whether the console's greeting says the emulator wants `auth <token>`
    /// before most commands (`Android Console: Authentication required`).
    static func greetingAsksForAuthentication(_ greeting: String) -> Bool {
        greeting.contains("Authentication required")
    }

    /// The token in `file` without its line ending or any trailing blanks;
    /// nil when the file is missing, unreadable or empty.
    static func token(in file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

/// Why a console exchange failed. Never carries the authentication token.
public enum EmulatorConsoleError: Error, Equatable, CustomStringConvertible {
    /// Nothing answered on the console port (on 127.0.0.1 or ::1): the
    /// emulator is gone or its console is not there. `AdbClient` then asks
    /// adb instead.
    case couldNotConnect(port: Int, reason: String)
    /// The console refused the authentication token (its `KO` line).
    case authenticationRejected(String)
    /// The conversation did not go the way the console's protocol does: no
    /// greeting, or a write that failed.
    case protocolError(String)
    /// A command that cannot be sent as one line (empty, or holding a line
    /// break).
    case invalidCommand
    /// The exchange did not finish within the bound.
    case timedOut(Duration)

    public var description: String {
        switch self {
        case .couldNotConnect(let port, let reason):
            return "could not connect to the emulator console on port \(port): \(reason)"
        case .authenticationRejected(let reply):
            return "the emulator console refused the authentication token: \(reply)"
        case .protocolError(let reason):
            return "the emulator console did not answer as expected: \(reason)"
        case .invalidCommand:
            return "the emulator console takes one line per command"
        case .timedOut(let bound):
            return "the emulator console did not answer within \(bound)"
        }
    }

    /// Whether the console was never reached, so asking adb is still worth
    /// it.
    public var isConnectionFailure: Bool {
        if case .couldNotConnect = self { return true }
        return false
    }
}

/// How `AdbClient` reaches an emulator's console without adb. A protocol so
/// tests hand in a console of their own; `LiveEmulatorConsole` is the real
/// one.
public protocol EmulatorConsoleTransport: Sendable {
    /// Runs `arguments` (joined by single spaces) as one command on the
    /// console at `port` and returns the console's answer the way a working
    /// `adb emu` prints it: the answer's lines, `\r\n` kept, through the
    /// terminating `OK` or `KO` line (nothing of the greeting or of the
    /// authentication). A console that closes before the terminator (`kill`
    /// ends the VM) gives what it had sent, possibly nothing.
    ///
    /// Throws `EmulatorConsoleError`, `CancellationError` when the task is
    /// cancelled.
    func run(_ arguments: [String], port: Int, timeout: Duration) async throws -> String
}
