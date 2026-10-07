import Foundation

/// A fake command-line tool for client tests: an executable shell script
/// named `name` that records every invocation, answers the first rule whose
/// `match` is a substring of its space-joined argv with the rule's stdout,
/// stderr and exit code, and exits `defaultExitCode` silently otherwise.
///
/// The clients under test run it through the real `ProcessRunner`, so pipes,
/// timeouts and exit codes are exercised exactly as with the real tool.
/// Rule output comes from text or from a fixture file (replayed byte for
/// byte). The fake and its directory are removed on deinit.
final class FakeTool {
    struct Rule {
        enum Source {
            case text(String)
            case file(URL)
        }

        let match: String
        let stdout: Source
        let stderr: Source?
        let exitCode: Int32
        /// A fixture copied to the `--json-output <path>` argument instead of
        /// written to stdout (devicectl's file form).
        var jsonOutputFile: URL?

        /// A rule that writes `file` to the call's `--json-output` path (and,
        /// with `stdoutFile`, that file's bytes to standard output: devicectl's
        /// `pasteboard paste` prints the text there).
        init(_ match: String, jsonOutputFile: URL, stdoutFile: URL? = nil, exitCode: Int32 = 0) {
            self.match = match
            self.stdout = stdoutFile.map(Source.file) ?? .text("")
            self.stderr = nil
            self.exitCode = exitCode
            self.jsonOutputFile = jsonOutputFile
        }

        init(_ match: String, output: String = "", stderr: String? = nil, exitCode: Int32 = 0) {
            self.match = match
            self.stdout = .text(output)
            self.stderr = stderr.map(Source.text)
            self.exitCode = exitCode
        }

        init(_ match: String, stdoutFile: URL?, stderrFile: URL? = nil, exitCode: Int32 = 0) {
            self.match = match
            self.stdout = stdoutFile.map(Source.file) ?? .text("")
            self.stderr = stderrFile.map(Source.file)
            self.exitCode = exitCode
        }
    }

    let directory: URL
    let executableURL: URL
    private let traceURL: URL

    init(name: String, rules: [Rule], defaultExitCode: Int32 = 0) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeTool-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let traceURL = directory.appendingPathComponent("calls.log")
        self.directory = directory
        self.traceURL = traceURL

        func path(of source: Rule.Source, index: Int, stream: String) throws -> String {
            switch source {
            case .file(let url):
                return url.path
            case .text(let text):
                let url = directory.appendingPathComponent("\(stream)-\(index).txt")
                try Data(text.utf8).write(to: url)
                return url.path
            }
        }

        var branches: [String] = []
        for (index, rule) in rules.enumerated() {
            var body = "cat \(Self.quoted(try path(of: rule.stdout, index: index, stream: "out")))"
            if let file = rule.jsonOutputFile {
                body = "cp \(Self.quoted(file.path)) \"$JSON_OUT\""
                if case .file(let stdoutURL) = rule.stdout { body += "; cat \(Self.quoted(stdoutURL.path))" }
            }
            if let stderr = rule.stderr {
                body += "; cat \(Self.quoted(try path(of: stderr, index: index, stream: "err"))) >&2"
            }
            branches.append("  *\(Self.quoted(rule.match))*) \(body); exit \(rule.exitCode) ;;")
        }
        // Each invocation is recorded twice: `$*` on one line (for substring
        // checks) and every argument followed by a unit separator, then a
        // record separator (for exact argv checks).
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> \(Self.quoted(traceURL.path))
        printf '%s\\037' "$@" >> \(Self.quoted(traceURL.path + ".argv"))
        printf '\\036' >> \(Self.quoted(traceURL.path + ".argv"))
        JSON_OUT=""; PREV=""
        for ARG in "$@"; do
          if [ "$PREV" = "--json-output" ]; then JSON_OUT="$ARG"; fi
          PREV="$ARG"
        done
        case "$*" in
        \(branches.joined(separator: "\n"))
          *) exit \(defaultExitCode) ;;
        esac
        """
        executableURL = directory.appendingPathComponent(name)
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    }

    deinit {
        // Best effort: a leftover temporary directory must not fail a test.
        try? FileManager.default.removeItem(at: directory)
    }

    /// Every invocation's arguments joined by spaces, in order.
    var calls: [String] {
        // Best effort: no trace file means the tool was never run.
        guard let text = try? String(contentsOf: traceURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// Every invocation's exact argv, in order.
    var invocations: [[String]] {
        let url = URL(fileURLWithPath: traceURL.path + ".argv")
        // Best effort: no trace file means the tool was never run.
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\u{1E}", omittingEmptySubsequences: true).map { record in
            record.split(separator: "\u{1F}", omittingEmptySubsequences: false).dropLast().map(String.init)
        }
    }

    /// Single-quotes a string for the shell.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
