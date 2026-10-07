import Foundation

/// The Network conditions (emulator console) and App conditions (`am`)
/// commands behind the Controls rows of the same names. Every write here is
/// read back by its caller from where Android applies it
/// (`NetworkConditionsSnapshot`, `AppConditionsSnapshot`), never trusted
/// from the command's exit status: the console answers OK to values that do
/// nothing, and `am kill` returns 0 when it left the app running.
extension AdbClient {
    // MARK: - Network conditions (emulator console)

    /// One round trip for every Network conditions read but the console's.
    public func networkConditions(serial: String) async throws -> NetworkConditionsSnapshot {
        let output = try await shell(serial: serial, [NetworkConditionsSnapshot.probeScript])
        return NetworkConditionsSnapshot.parse(output)
    }

    /// The emulator on `serial`: its console's `avd name` and `avd
    /// discoverypath`, read together. nil when the console does not answer
    /// both (no emulator there, or it is shutting down).
    public func emulatorInstance(serial: String) async -> EmulatorInstance? {
        async let nameRead = try? await avdName(serial: serial)
        async let pathRead = try? await emuCommand(serial: serial, ["avd", "discoverypath"])
        let (name, pathOutput) = await (nameRead, pathRead)
        guard let name, let discoveryPath = pathOutput.flatMap(AdbParsing.discoveryPath(from:)) else {
            return nil
        }
        return EmulatorInstance(avdName: name, discoveryPath: discoveryPath)
    }

    /// `gsm meter on|off`: off marks mobile data temporarily not metered.
    public func setEmulatorMobileDataMetered(serial: String, metered: Bool) async throws {
        try await emuCommand(serial: serial, ["gsm", "meter", metered ? "on" : "off"])
    }

    // MARK: - App conditions (am)

    /// One round trip for every App conditions read (`AppConditionsSnapshot`).
    public func appConditions(serial: String, package: String?) async throws -> AppConditionsSnapshot {
        let output = try await shell(serial: serial, [AppConditionsSnapshot.probeScript(package: package)])
        return AppConditionsSnapshot.parse(output, package: package)
    }

    /// The package's last exit records, newest first (API 30+; empty
    /// before).
    public func processExitRecords(serial: String, package: String) async throws -> [ProcessExitRecord] {
        let output = try await shell(serial: serial, [AppConditionsSnapshot.exitRecordsScript(package: package)])
        return ProcessExitRecord.parse(output)
    }

    /// The package of the resumed activity, if any.
    public func foregroundPackage(serial: String) async throws -> String? {
        let output = try await shell(serial: serial, [AppConditionsSnapshot.foregroundScript])
        return AppConditionsSnapshot.foregroundPackage(fromActivities: output)
    }

    /// `am send-trim-memory --user current <package> <LEVEL>`. Throws
    /// `AppConditionsError.refused` with the activity manager's reason when
    /// it refuses the level.
    public func sendTrimMemory(serial: String, package: String, level: TrimMemoryLevel) async throws {
        try await runActivityManager(
            serial: serial,
            ["am", "send-trim-memory", "--user", "current", Self.shellQuoted(package), level.commandToken],
            command: "Trim memory"
        )
    }

    /// `am kill --user current <package>`: ends the package's processes
    /// that are in the background (adj ≥ SERVICE_ADJ) — what Android's
    /// memory reclaim does. A foreground app survives and the command
    /// still exits 0, so the caller reads the pids back.
    public func killBackgroundProcesses(serial: String, package: String) async throws {
        try await runActivityManager(
            serial: serial,
            ["am", "kill", "--user", "current", Self.shellQuoted(package)],
            command: "Kill process"
        )
    }

    /// Runs an `am` command, turning a refusal into `AppConditionsError`
    /// with the activity manager's own reason (it prints a stack trace or
    /// an `Error:` line on stderr and exits 255).
    private func runActivityManager(serial: String, _ arguments: [String], command: String) async throws {
        do {
            let output = try await shell(serial: serial, arguments)
            // Some refusals (a restricted user) print to stdout and exit 0.
            if let reason = AppConditionsError.reason(fromOutput: output) {
                throw AppConditionsError.refused(command: command, reason: reason)
            }
        } catch AdbError.commandFailed(_, let exitCode, let message) where exitCode != 1 {
            // Exit 1 is adb's own failure (device gone); anything else is
            // the command's, with its reason on stderr.
            throw AppConditionsError.refused(
                command: command,
                reason: AppConditionsError.reason(fromOutput: message)
                    ?? message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
