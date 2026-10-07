import Foundation

/// Why the one privileged devicectl command did not produce a result.
public enum DevicectlPrivilegedError: Error, Equatable, CustomStringConvertible {
    /// The user dismissed macOS's administrator dialog (AppleScript error -128).
    case cancelled
    /// macOS refused the administrator password (AppleScript errors -60005,
    /// -60007, -60008).
    case authorizationFailed
    /// The privileged command ran and failed, with the first line it said.
    case failed(String)

    public var description: String {
        switch self {
        case .cancelled: "The administrator password was not entered."
        case .authorizationFailed: "macOS did not accept the administrator password."
        case .failed(let message): message.isEmpty ? "The privileged command failed." : message
        }
    }
}

/// Runs `devicectl device sysdiagnose` with administrator privileges through
/// macOS's own authorization dialog.
///
/// `devicectl device sysdiagnose` asks for the Mac's administrator password
/// on a terminal and fails without one (CoreDeviceCLISupport.DiagnoseError 0,
/// even with `--dry-run-only`); Device Hub does the same work in-process with
/// privileges of its own. The dialog is `osascript`'s `do shell script ...
/// with administrator privileges`: the user types the password into the system
/// dialog and Device Hub Pro never sees it. The wrapper runs that one validated
/// argv (`DevicectlPhysicalClient.commandLine`) and nothing else; devicectl
/// writes into a private temporary folder, which the script hands back to the
/// user (`chown -R`), and the caller moves the files into the folder the user
/// chose, as the user.
enum DevicectlPrivilegedRunner {
    /// `osascript`, the only launcher of the wrapper.
    static let defaultLauncher = URL(fileURLWithPath: "/usr/bin/osascript")

    /// How long the user has to answer the dialog, beyond the command's own time.
    static let dialogAllowance: Duration = .seconds(120)

    /// `text` inside single quotes for `/bin/sh`, so no character in it is
    /// special.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `text` as the inside of an AppleScript string literal (the caller adds
    /// the double quotes).
    static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The shell script: devicectl with its validated argv, then the hand-back
    /// of the work folder to the user whatever devicectl answered, then
    /// devicectl's own exit status.
    static func shellScript(
        devicectl: URL,
        arguments: [String],
        developerDirectory: URL?,
        workFolder: URL,
        userID: UInt32,
        groupID: UInt32
    ) -> String {
        var command = ""
        if let developerDirectory { command += "DEVELOPER_DIR=\(shellQuoted(developerDirectory.path)) " }
        command += ([devicectl.path] + arguments).map(shellQuoted).joined(separator: " ")
        return "\(command); s=$?; /usr/sbin/chown -R \(userID):\(groupID) \(shellQuoted(workFolder.path)); exit $s"
    }

    /// The `osascript` argv that runs `shellScript` with administrator
    /// privileges.
    static func osascriptArguments(shellScript: String, prompt: String) -> [String] {
        let source = "do shell script \"\(appleScriptEscaped(shellScript))\" with administrator privileges"
            + " with prompt \"\(appleScriptEscaped(prompt))\""
        return ["-e", source]
    }

    /// Maps what `osascript` printed on a failed run.
    static func error(fromStandardError text: String) -> DevicectlPrivilegedError {
        if text.contains("(-128)") { return .cancelled }
        if text.contains("(-60005)") || text.contains("(-60007)") || text.contains("(-60008)") {
            return .authorizationFailed
        }
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return .failed(first)
    }

    /// Runs `osascript` with the wrapper; throws on a non-zero exit.
    static func run(
        launcher: URL,
        script: String,
        prompt: String,
        commandTimeout: Duration
    ) async throws {
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: launcher,
                arguments: osascriptArguments(shellScript: script, prompt: prompt),
                environment: nil,
                timeout: commandTimeout + dialogAllowance
            )
        } catch ProcessRunnerError.timedOut(_, let seconds) {
            throw ProcessRunnerError.timedOut(command: "devicectl device sysdiagnose", seconds: seconds)
        }
        guard result.exitCode == 0 else { throw error(fromStandardError: result.standardErrorText) }
    }

    /// Moves what devicectl collected from `source` into `folder` (a name
    /// that is taken gets " 2", " 3", ...). Answers the files' new places.
    static func moveContents(of source: URL, into folder: URL) throws -> [URL] {
        let manager = FileManager.default
        let names = try manager.contentsOfDirectory(atPath: source.path).sorted()
        var moved: [URL] = []
        for name in names {
            let from = source.appendingPathComponent(name)
            var target = folder.appendingPathComponent(name)
            var counter = 2
            while manager.fileExists(atPath: target.path) {
                // "sysdiagnose_x.tar.gz" becomes "sysdiagnose_x 2.tar.gz".
                let dot = name.dropFirst().firstIndex(of: ".")
                let base = dot.map { String(name[..<$0]) } ?? name
                let rest = dot.map { String(name[$0...]) } ?? ""
                let numbered = "\(base) \(counter)\(rest)"
                target = folder.appendingPathComponent(numbered)
                counter += 1
            }
            try manager.moveItem(at: from, to: target)
            moved.append(target)
        }
        return moved
    }
}
