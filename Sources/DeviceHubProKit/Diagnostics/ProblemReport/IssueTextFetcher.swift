import Foundation

/// Reads a GitHub issue's text (title, body and every comment) with the GitHub
/// CLI, for `dhp-report issue <number>`. The output is plain text, so no gh
/// JSON has to be decoded; `ProblemReportParser` finds the reports in it.
public enum IssueTextFetcher {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        /// Why it failed, for what to tell the user to do.
        public enum Cause: Equatable, Sendable {
            /// The arguments were refused before anything ran.
            case usage
            /// gh is not installed (or could not be started).
            case ghMissing
            /// gh ran and asked for a sign-in.
            case notSignedIn
            /// gh ran and said no (the issue does not exist, the network is
            /// down): its own message says why.
            case other
        }

        public let message: String
        public let cause: Cause
        public var description: String { message }

        public init(message: String, cause: Cause = .other) {
            self.message = message
            self.cause = cause
        }
    }

    /// The issue's title on the first line, then its body, then each comment's
    /// body. `gh` is the program that runs `gh` (`env`, so the user's PATH
    /// finds it); a test names its own.
    public static func text(
        number: Int,
        repo: String,
        gh: URL = URL(fileURLWithPath: "/usr/bin/env")
    ) async throws -> String {
        guard number > 0 else { throw Failure(message: "The issue number must be positive.", cause: .usage) }
        guard repo.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
            throw Failure(message: "The repository must be written owner/name.", cause: .usage)
        }
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: gh,
                arguments: [
                    "gh", "issue", "view", String(number), "--repo", repo,
                    "--json", "title,body,comments",
                    "--jq", ".title, .body, (.comments[].body)",
                ],
                timeout: .seconds(30)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure(message: "gh could not be run: \(error)", cause: .ghMissing)
        }
        guard result.exitCode == 0 else {
            let reason = result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = reason.isEmpty ? "gh exited with status \(result.exitCode)." : reason
            throw Failure(message: message, cause: cause(exitCode: result.exitCode, stderr: reason))
        }
        return result.standardOutputText
    }

    /// `env` answers 127 when it finds no gh; gh names its sign-in command
    /// when it has no credentials.
    static func cause(exitCode: Int32, stderr: String) -> Failure.Cause {
        if exitCode == 127 { return .ghMissing }
        let lowered = stderr.lowercased()
        if lowered.contains("gh auth login") || lowered.contains("gh_token") || lowered.contains("not logged in") {
            return .notSignedIn
        }
        return .other
    }
}
