import Foundation

/// Why a report could not be read.
public enum ProblemReportParseError: Error, Equatable, Sendable {
    /// The text holds no report.
    case noReport
    /// The report was made by a newer schema than this build reads.
    case newerSchema(Int)
    /// The report's JSON is damaged.
    case invalid(String)
}

/// Finds the reports in the text of an issue, a comment or a file, and reads
/// them back. The JSON block is found by its `<!-- dhp-report v… -->` marker
/// and the first ```` ```json ```` fence after it, so it makes no difference
/// whether the user pasted the report into the form's `report` field, into a
/// code block of the old `logs` field, or into a comment.
public enum ProblemReportParser {
    /// Every report in `text`, in order; the Markdown form carries a marker, a
    /// bare JSON document (`dhp-report collect --json`) none.
    public static func reports(in text: String) -> [Result<ProblemReport, ProblemReportParseError>] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var results: [Result<ProblemReport, ProblemReportParseError>] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.contains("<!-- dhp-report v") else {
                index += 1
                continue
            }
            // The first fenced block after the marker, unless the closing
            // marker comes first.
            var cursor = index + 1
            var start: Int?
            while cursor < lines.count {
                let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("<!-- /dhp-report") || trimmed.hasPrefix("<!-- dhp-report v") { break }
                if isFence(trimmed), trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("json") {
                    start = cursor + 1
                    break
                }
                cursor += 1
            }
            guard let start else {
                results.append(.failure(.invalid("The report marker has no JSON block after it.")))
                index = max(cursor, index + 1)
                continue
            }
            var end = start
            while end < lines.count, !isFence(lines[end].trimmingCharacters(in: .whitespaces)) { end += 1 }
            results.append(decode(lines[start..<end].joined(separator: "\n")))
            index = end + 1
        }
        if !results.isEmpty { return results }

        // No marker: a bare JSON document (`dhp-report collect --json`), or
        // the JSON of a report copied from the rendered issue page, which
        // loses the marker and the fence and gains the summary above it.
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        var whole: Result<ProblemReport, ProblemReportParseError>?
        if trimmed.hasPrefix("{") {
            let decoded = decode(trimmed)
            if case .failure(.invalid) = decoded {} else { return [decoded] }
            whole = decoded
        }
        let bare = bareDocuments(in: lines)
        if !bare.isEmpty { return bare }
        return [whole ?? .failure(.noReport)]
    }

    /// The pretty-printed JSON documents standing in `lines` without a
    /// marker: from a line that is just `{` to the next line that is just `}`
    /// at the same indentation. A document is kept when it reads as a report
    /// or says it is one (`schemaVersion`).
    private static func bareDocuments(in lines: [String]) -> [Result<ProblemReport, ProblemReportParseError>] {
        var found: [Result<ProblemReport, ProblemReportParseError>] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.trimmingCharacters(in: .whitespaces) == "{" else {
                index += 1
                continue
            }
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            var end = index + 1
            while end < lines.count, lines[end].trimmingCharacters(in: .newlines) != indent + "}" { end += 1 }
            guard end < lines.count else { break }
            let text = lines[index...end].joined(separator: "\n")
            let result = decode(text)
            switch result {
            case .success, .failure(.newerSchema):
                found.append(result)
                index = end + 1
            default:
                index += 1
                if text.contains("\"schemaVersion\"") { found.append(result) }
            }
        }
        return found
    }

    private static func isFence(_ trimmedLine: String) -> Bool {
        trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~")
    }

    private static func decode(_ json: String) -> Result<ProblemReport, ProblemReportParseError> {
        let data = Data(json.utf8)
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let version = object["schemaVersion"] as? Int, version > ProblemReport.schemaVersion {
            return .failure(.newerSchema(version))
        }
        do {
            return .success(try ProblemReport.decoder().decode(ProblemReport.self, from: data))
        } catch let error as DecodingError {
            return .failure(.invalid(describe(error)))
        } catch {
            return .failure(.invalid(error.localizedDescription))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "The report has no \(key.stringValue) at \(path(context))."
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "The report\u{2019}s JSON is damaged at \(path(context)): \(context.debugDescription)"
        @unknown default:
            return "The report\u{2019}s JSON is damaged."
        }
    }
}
