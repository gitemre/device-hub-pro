import Foundation

extension AdbClient {
    /// The rules of one direction on a device: `adb -s <serial> forward
    /// --list` or `reverse --list`.
    public func portForwardRules(
        serial: String,
        direction: PortForwardRule.Direction
    ) async throws -> [PortForwardRule] {
        let arguments = ["-s", serial, direction.rawValue, "--list"]
        let result = try await execute(arguments)
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(arguments: arguments, exitCode: result.exitCode, message: result.standardErrorText)
        }
        return PortForwarding.rules(from: result.standardOutputText, direction: direction, serial: serial)
    }

    /// Both directions, forward first.
    public func allPortForwardRules(serial: String) async throws -> [PortForwardRule] {
        let forward = try await portForwardRules(serial: serial, direction: .forward)
        let reverse = try await portForwardRules(serial: serial, direction: .reverse)
        return forward + reverse
    }

    /// Adds a rule: `adb -s <serial> forward <host> <device>` or `reverse
    /// <device> <host>` (adb's own argument order: the listening socket
    /// first). Returns what adb printed (the allocated port for `tcp:0`).
    @discardableResult
    public func addPortForward(serial: String, rule: PortForwardRule) async throws -> String {
        if let problem = PortForwarding.validate(direction: rule.direction, listen: rule.listen, target: rule.target) {
            throw AdbError.commandFailed(arguments: [], exitCode: 0, message: problem)
        }
        let arguments = ["-s", serial, rule.direction.rawValue, rule.listen, rule.target]
        let result = try await execute(arguments)
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(arguments: arguments, exitCode: result.exitCode, message: result.standardErrorText)
        }
        return result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes one rule by its listening socket: `forward --remove <local>`,
    /// `reverse --remove <remote>`.
    public func removePortForward(serial: String, rule: PortForwardRule) async throws {
        if let problem = PortForwarding.validate(spec: rule.listen) {
            throw AdbError.commandFailed(arguments: [], exitCode: 0, message: problem)
        }
        let arguments = ["-s", serial, rule.direction.rawValue, "--remove", rule.listen]
        let result = try await execute(arguments)
        guard result.exitCode == 0 else {
            throw AdbError.commandFailed(arguments: arguments, exitCode: result.exitCode, message: result.standardErrorText)
        }
    }
}
