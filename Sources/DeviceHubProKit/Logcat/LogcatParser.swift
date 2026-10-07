import Foundation

/// Parses `adb logcat -v threadtime` output lines.
///
/// Example:
/// `09-10 15:34:12.345  1234  1256 I ActivityManager: Start proc ...`
///
/// liblog's `logprint.cpp` writes the threadtime header as
/// `"%s %5d %5d %c %-8s: "` — the tag, padded to eight columns, then a colon
/// and one space — so the tag ends at the first `": "` of the line, not at
/// its first colon. Real tags carry colons of their own (`AF::TrackHandle`,
/// `binder:650_5`, the process-name tag `s.messaging:rcs`).
public enum LogcatParser {
    public enum ParsedLine: Equatable, Sendable {
        case entry(LogcatEntry)
        case continuation(String)
        case unparsed(String)
    }

    private static let header = #"^(\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d{3})\s+(\d+)\s+(\d+)\s+([VDIWEF])\s+"#

    /// The threadtime layout: the tag runs to the first colon followed by a
    /// space, or by the end of the line (an empty message).
    private static let regex: NSRegularExpression? = try? NSRegularExpression(
        pattern: header + #"(.*?)\s*:(?: (.*))?$"#
    )

    /// A line whose tag colon is not followed by a space (not a layout
    /// logprint writes): the tag runs to the first colon.
    private static let lenientRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: header + #"(.*?)\s*:\s?(.*)$"#
    )

    /// Whether `line` is one of logcat's own buffer markers
    /// (`--------- beginning of main`, `--------- switch to crash`): stream
    /// bookkeeping, not text any process logged.
    public static func isBufferMarker(_ line: String) -> Bool {
        line.hasPrefix("--------- ")
    }

    public static func parse(_ line: String) -> ParsedLine {
        guard let regex, let lenientRegex else { return .unparsed(line) }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range)
            ?? lenientRegex.firstMatch(in: line, options: [], range: range)
        else {
            // Stack trace lines are indented; everything else is unparsed noise
            // (e.g. "--------- beginning of main").
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                return .continuation(line)
            }
            return .unparsed(line)
        }

        func group(_ index: Int) -> String? {
            guard let groupRange = Range(match.range(at: index), in: line) else { return nil }
            return String(line[groupRange])
        }

        guard
            let timestamp = group(1),
            let pidText = group(2), let pid = Int(pidText),
            let tidText = group(3), let tid = Int(tidText),
            let levelText = group(4), let level = LogcatLevel(rawValue: levelText)
        else {
            return .unparsed(line)
        }

        return .entry(LogcatEntry(
            timestamp: timestamp,
            pid: pid,
            tid: tid,
            level: level,
            tag: group(5) ?? "",
            message: group(6) ?? ""
        ))
    }
}
