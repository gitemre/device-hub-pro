// dhp-report: reads Device Hub Pro problem reports and says what went wrong,
// for the maintainers. The same pipeline as Help > Report a Problem in the app
// (DeviceHubProKit: collect, scrub, analyze, render), so a report from a user
// and one made here reach the same verdict. Never packaged.
//
//   dhp-report analyze <file|-> [--json]
//   dhp-report issue <number> [--repo owner/name] [--json]
//   dhp-report collect [--json] [--no-adb]
//   dhp-report help
//
// Exit status: 0 done, 1 usage, 2 no report found, 3 a report of a newer
// schema or damaged, 4 the GitHub CLI failed.

import DeviceHubProKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

enum DHPReport {
    static let usage = """
    Usage:
      dhp-report analyze <file|-> [--json]
          Finds every problem report in a file (or standard input) and prints
          what this build's analyzer says about each. --json prints the
          findings only.
      dhp-report issue <number> [--repo owner/name] [--json]
          Reads a GitHub issue with the GitHub CLI (gh, signed in), then
          analyzes it like `analyze`. The default repository is
          \(ProblemReportIssueLink.repository).
      dhp-report collect [--json] [--no-adb]
          Makes a report of this Mac, with the same reads and the same adb
          guard as the app: adb is asked only while a server of the same adb
          already runs. --no-adb asks adb nothing. --json prints the scrubbed
          report instead of the Markdown.
      dhp-report help

    Exit status: 0 done, 1 usage, 2 no report found, 3 newer schema or damaged
    report, 4 the GitHub CLI failed.
    """

    static func run(_ arguments: [String]) async -> Int32 {
        guard let command = arguments.first else {
            fputs(usage + "\n", stderr)
            return 1
        }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "help", "-h", "--help":
            print(usage)
            return 0
        case "analyze":
            return analyzeCommand(rest)
        case "issue":
            return await issueCommand(rest)
        case "collect":
            return await collectCommand(rest)
        default:
            fputs("Unknown command \(command).\n\n\(usage)\n", stderr)
            return 1
        }
    }

    // MARK: analyze

    static func analyzeCommand(_ arguments: [String]) -> Int32 {
        var json = false
        var source: String?
        for argument in arguments {
            if argument == "--json" {
                json = true
            } else if source == nil, argument == "-" || !argument.hasPrefix("--") {
                source = argument
            } else {
                fputs("Unexpected argument \(argument).\n\n\(usage)\n", stderr)
                return 1
            }
        }
        guard let source else {
            fputs("analyze needs a file, or - for standard input.\n\n\(usage)\n", stderr)
            return 1
        }
        let data: Data
        if source == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            guard let read = try? Data(contentsOf: URL(fileURLWithPath: source)) else {
                fputs("Couldn\u{2019}t read \(source).\n", stderr)
                return 1
            }
            data = read
        }
        return analyze(text: String(decoding: data, as: UTF8.self), json: json)
    }

    static func analyze(text: String, json: Bool) -> Int32 {
        let results = ProblemReportBuilder.analyze(markdownOrJSON: text)
        var analyzed: [AnalyzedProblemReport] = []
        var status: Int32 = 0
        for result in results {
            switch result {
            case .success(let report):
                analyzed.append(report)
            case .failure(.noReport):
                status = max(status, 2)
            case .failure(.newerSchema(let version)):
                fputs("A report is of schema \(version); this build reads schema \(ProblemReport.schemaVersion). Update dhp-report.\n", stderr)
                status = 3
            case .failure(.invalid(let reason)):
                fputs("A report could not be read: \(reason)\n", stderr)
                status = 3
            }
        }
        if json {
            print(ProblemReportBuilder.findingsJSON(analyzed))
        } else {
            for (index, item) in analyzed.enumerated() {
                if index > 0 { print(String(repeating: "-", count: 72)) }
                print(ProblemReportRenderer.terminal(item.report, findings: item.findings), terminator: "")
                if !item.newFindingIDs.isEmpty {
                    print("New since the app\u{2019}s check: " + item.newFindingIDs.joined(separator: ", "))
                }
            }
            if analyzed.isEmpty, status == 2 { fputs("No problem report found.\n", stderr) }
        }
        // A report that was read wins over one that was not found.
        if !analyzed.isEmpty, status == 2 { status = 0 }
        return status
    }

    // MARK: issue

    static func issueCommand(_ arguments: [String]) async -> Int32 {
        var number: Int?
        var repo = ProblemReportIssueLink.repository
        var json = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--repo", index + 1 < arguments.count {
                repo = arguments[index + 1]
                index += 2
                continue
            }
            if argument == "--json" {
                json = true
            } else if number == nil, let value = Int(argument.hasPrefix("#") ? String(argument.dropFirst()) : argument) {
                guard value > 0 else {
                    fputs("The issue number must be positive.\n\n\(usage)\n", stderr)
                    return 1
                }
                number = value
            } else {
                fputs("Unexpected argument \(argument).\n\n\(usage)\n", stderr)
                return 1
            }
            index += 1
        }
        guard let number else {
            fputs("issue needs an issue number.\n\n\(usage)\n", stderr)
            return 1
        }
        let text: String
        do {
            text = try await IssueTextFetcher.text(number: number, repo: repo)
        } catch {
            fputs("\(error)\n", stderr)
            let failure = error as? IssueTextFetcher.Failure
            switch failure?.cause {
            case .usage:
                return 1
            case .ghMissing:
                fputs("Install the GitHub CLI (gh), or save the issue text and run `dhp-report analyze <file>`.\n", stderr)
            case .notSignedIn:
                fputs("Sign in with `gh auth login`, or save the issue text and run `dhp-report analyze <file>`.\n", stderr)
            case .other, nil:
                // gh ran and said why (the issue does not exist, no network):
                // its own message is the answer.
                break
            }
            return 4
        }
        if !json {
            let title = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            print("Issue #\(number): \(title)\n")
        }
        return analyze(text: text, json: json)
    }

    // MARK: collect

    static func collectCommand(_ arguments: [String]) async -> Int32 {
        var json = false
        var inputs = ProblemReportInputs.live(producer: .cli)
        for argument in arguments {
            switch argument {
            case "--json": json = true
            case "--no-adb": inputs.runsAdb = false
            default:
                fputs("Unexpected argument \(argument).\n\n\(usage)\n", stderr)
                return 1
            }
        }
        let prepared = await ProblemReportBuilder.prepare(
            inputs: inputs,
            appState: nil,
            subject: nil,
            recentProblems: []
        )
        if json {
            guard let text = try? prepared.report.jsonText() else {
                fputs("The report could not be written.\n", stderr)
                return 1
            }
            print(text)
        } else {
            print(prepared.markdown, terminator: "")
        }
        return 0
    }
}

exit(await DHPReport.run(Array(CommandLine.arguments.dropFirst())))
