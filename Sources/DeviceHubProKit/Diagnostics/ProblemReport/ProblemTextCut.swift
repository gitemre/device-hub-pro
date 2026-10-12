import Foundation

/// Cuts raw text to a length before it is stored or scrubbed, without leaving
/// the front of a long token behind.
///
/// The scrubber recognises a token (the adb public key, a credential) only as a
/// whole: a cut in the middle of one leaves a piece that may not look like one
/// any more. So a text that has to be cut before it is scrubbed (an error
/// message kept across launches, a tool's stderr) is cut where no such run of
/// letters, digits, `+`, `/` and `=` crosses the cut. A text that can wait is
/// scrubbed first and cut afterwards (`ProblemReportCollector.cutLongLines`).
enum ProblemTextCut {
    /// A run this long, cut by the limit, is dropped from the end.
    static let longestHarmlessRun = 20

    /// `text` cut to `limit` characters, less the run of token characters the
    /// cut falls in, when that run is at least `longestHarmlessRun` long and
    /// not most of the result (a text that is one long run keeps its start).
    static func prefix(_ text: String, _ limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        var cut = String(text.prefix(limit))
        let next = text[text.index(text.startIndex, offsetBy: limit)]
        guard isTokenCharacter(next) else { return cut }
        let run = cut.reversed().prefix { isTokenCharacter($0) }.count
        if run >= longestHarmlessRun, run <= limit / 2 { cut.removeLast(run) }
        return cut
    }

    private static func isTokenCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "+/=".contains(character))
    }
}
