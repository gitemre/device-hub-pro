import Foundation

/// Every emulator console command of this client goes through one path:
/// `executeConsole`.
///
/// `adb emu …` cannot be relied on to show the console's answer (see
/// `EmulatorConsole`: with an empty `~/.emulator_console_auth_token` it prints
/// nothing and exits 0), so a client made by `locate()` or `unresolvedForApp()`
/// talks to the console itself and asks adb only when it cannot connect.
/// A client made with `init(adbURL:)` or `unresolved()` has no console
/// transport and always asks adb, so tests with a fake or stub adb never reach
/// an emulator on this Mac.
extension AdbClient {
    /// Whether this client talks to an emulator's console itself.
    public var talksToEmulatorConsoles: Bool { emulatorConsole != nil }

    /// Runs `arguments` as one console command of the emulator at `serial`
    /// and returns what `adb -s <serial> emu <arguments>` would have printed
    /// had it worked: standard output holding the answer through its `OK` or
    /// `KO` line, exit status 0.
    ///
    /// With a console transport and an `emulator-<port>` serial the command
    /// goes to the console. A console that cannot be reached (nothing
    /// listens, which adb would report in its own way) falls back to `adb
    /// emu`; one that answers wrongly or refuses the authentication token is
    /// an `AdbError.commandFailed` naming the `adb emu` argv, and one that
    /// does not answer in time is `ProcessRunnerError.timedOut`, as for any
    /// bounded call. Any other serial, and a client with no transport, runs
    /// `adb emu`.
    func executeConsole(serial: String, _ arguments: [String]) async throws -> ProcessResult {
        let adbArguments = ["-s", serial, "emu"] + arguments
        if let console = emulatorConsole, let port = EmulatorConsole.port(forSerial: serial) {
            guard isResolved else { throw AdbError.adbNotFound }
            let bound = AdbCallTimeout.override ?? commandTimeout
            do {
                let answer = try await console.run(arguments, port: port, timeout: bound)
                return ProcessResult(exitCode: 0, standardOutput: Data(answer.utf8), standardError: Data())
            } catch let error as EmulatorConsoleError {
                switch error {
                case .couldNotConnect:
                    break
                case .timedOut:
                    throw ProcessRunnerError.timedOut(
                        command: "emulator console \(serial) " + arguments.joined(separator: " "),
                        seconds: bound
                    )
                case .authenticationRejected, .protocolError, .invalidCommand:
                    throw AdbError.commandFailed(
                        arguments: adbArguments,
                        exitCode: 1,
                        message: error.description
                    )
                }
            }
        }
        return try await execute(adbArguments)
    }

    /// The AVD name in a console answer (`<name>\r\nOK\r\n`); nil for an
    /// error answer (`KO: …`), which has no name in it, and for an empty one.
    /// A name that only starts with the letters `KO` (`KOMPAKT_Phone`) is a
    /// name.
    static func avdName(fromConsoleAnswer answer: String) -> String? {
        guard !EmulatorConsole.isErrorAnswer(answer) else { return nil }
        return AdbParsing.avdName(from: answer)
    }

    /// The AVD name the emulator booted Android with, for the emulator whose
    /// console named none: `getprop ro.boot.qemu.avd_name`, which agrees with
    /// the console's `avd name` (captured on the same VM). Nil unless it
    /// answers with exactly one non-empty line.
    func avdNameFromProperty(serial: String) async throws -> String? {
        let result = try await execute(["-s", serial, "shell", "getprop", "ro.boot.qemu.avd_name"])
        guard result.exitCode == 0 else { return nil }
        let lines = result.standardOutputText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count == 1 else { return nil }
        return lines[0]
    }
}
