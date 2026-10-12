import XCTest
@testable import DeviceHubProKit

/// `dhp-report issue` reads an issue through the GitHub CLI. The fake `env`
/// records its argv and answers with a report this suite renders itself (our own
/// output, not a tool's).
final class IssueTextFetcherTests: XCTestCase {
    func testTheIssueIsReadThroughGhWithOnePlainTextJqProgram() async throws {
        let world = try HermeticReportWorld()
        let prepared = await ProblemReportBuilder.prepare(
            inputs: try world.inputs(), appState: nil, subject: nil, recentProblems: [],
            now: Date(timeIntervalSince1970: 1_800_000_000), reportID: "3fa9c2d1"
        )
        let output = "Emulator never comes online\n### What happened?\n\nIt never came online.\n\n\(prepared.markdown)\nA comment\n"
        let env = try FakeTool(name: "env", rules: [FakeTool.Rule("issue view 123", output: output)])

        let text = try await IssueTextFetcher.text(number: 123, repo: "gitemre/device-hub-pro", gh: env.executableURL)
        XCTAssertEqual(text, output)
        XCTAssertEqual(env.invocations, [[
            "gh", "issue", "view", "123", "--repo", "gitemre/device-hub-pro",
            "--json", "title,body,comments", "--jq", ".title, .body, (.comments[].body)",
        ]])
        let found = ProblemReportParser.reports(in: text)
        XCTAssertEqual(try found[0].get().id, "3fa9c2d1")
    }

    func testAFailingGhSaysWhy() async throws {
        let env = try FakeTool(name: "env", rules: [FakeTool.Rule("issue view", output: "", stderr: "gh: Not Found (HTTP 404)\n", exitCode: 1)])
        do {
            _ = try await IssueTextFetcher.text(number: 9, repo: "gitemre/device-hub-pro", gh: env.executableURL)
            XCTFail("a failing gh must throw")
        } catch let failure as IssueTextFetcher.Failure {
            XCTAssertEqual(failure.message, "gh: Not Found (HTTP 404)")
            XCTAssertEqual(failure.cause, .other, "gh ran and said why: no advice to install it")
        }
    }

    /// What the CLI tells the user to do follows from why gh failed. The sign-in text is the one gh itself prints
    /// when it has no credentials; `env` answers 127 for a program it does not find.
    func testTheCauseOfAFailureDecidesWhatToSuggest() async throws {
        XCTAssertEqual(IssueTextFetcher.cause(exitCode: 127, stderr: "env: gh: No such file or directory"), .ghMissing)
        XCTAssertEqual(
            IssueTextFetcher.cause(exitCode: 4, stderr: "To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable"),
            .notSignedIn
        )
        XCTAssertEqual(
            IssueTextFetcher.cause(exitCode: 1, stderr: "GraphQL: Could not resolve to an issue or pull request with the number of 99999. (repository.issue)"),
            .other
        )
        let env = try FakeTool(name: "env", rules: [FakeTool.Rule("issue view", output: "", stderr: "To get started with GitHub CLI, please run:  gh auth login\n", exitCode: 4)])
        do {
            _ = try await IssueTextFetcher.text(number: 9, repo: "gitemre/device-hub-pro", gh: env.executableURL)
            XCTFail("a failing gh must throw")
        } catch let failure as IssueTextFetcher.Failure {
            XCTAssertEqual(failure.cause, .notSignedIn)
        }
    }

    func testAnUnrunnableProgramIsAFailureToo() async {
        do {
            _ = try await IssueTextFetcher.text(number: 1, repo: "gitemre/device-hub-pro", gh: URL(fileURLWithPath: "/nonexistent/env"))
            XCTFail("a missing program must throw")
        } catch let failure as IssueTextFetcher.Failure {
            XCTAssertTrue(failure.message.hasPrefix("gh could not be run"), failure.message)
            XCTAssertEqual(failure.cause, .ghMissing)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testTheArgumentsAreValidatedBeforeAnythingRuns() async throws {
        let env = try FakeTool(name: "env", rules: [])
        for (number, repo) in [(0, "gitemre/device-hub-pro"), (1, "--json"), (1, "a/b --repo c"), (1, "nowhere")] {
            do {
                _ = try await IssueTextFetcher.text(number: number, repo: repo, gh: env.executableURL)
                XCTFail("\(number) \(repo)")
            } catch let failure as IssueTextFetcher.Failure {
                XCTAssertEqual(failure.cause, .usage, "\(number) \(repo)")
            }
        }
        XCTAssertEqual(env.invocations, [])
    }
}
