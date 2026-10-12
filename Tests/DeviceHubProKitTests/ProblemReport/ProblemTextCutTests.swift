import XCTest
@testable import DeviceHubProKit

/// The cut applied to text that has to be shortened before the scrubber sees it.
final class ProblemTextCutTests: XCTestCase {
    func testAShortTextIsKept() {
        XCTAssertEqual(ProblemTextCut.prefix("abc", 10), "abc")
        XCTAssertEqual(ProblemTextCut.prefix("abcde", 5), "abcde")
        XCTAssertEqual(ProblemTextCut.prefix("abc", 0), "abc", "no limit means no cut")
    }

    func testACutBetweenWordsIsAPlainPrefix() {
        XCTAssertEqual(ProblemTextCut.prefix("adb failed badly here", 10), "adb failed")
    }

    func testARunOfTokenCharactersCrossingTheCutIsDroppedWhole() {
        let key = String(repeating: "Qk/9xZtLmN", count: 5)
        let lead = String(repeating: "word ", count: 12)
        let text = lead + key + " end"
        // Cut 30 characters into the key: its front piece would be a run of 30 (at least 20, under half the result).
        XCTAssertEqual(ProblemTextCut.prefix(text, lead.count + 30), lead, "the front of the key goes")
        // Cut 10 characters into it: a run too short to be the front of a token.
        XCTAssertEqual(ProblemTextCut.prefix(text, lead.count + 10), String(text.prefix(lead.count + 10)))
    }

    func testATextThatIsMostlyOneRunKeepsItsStart() {
        let run = String(repeating: "m", count: 5_000)
        XCTAssertEqual(ProblemTextCut.prefix(run, 2_000).count, 2_000)
    }

    func testACutRightAfterARunKeepsIt() {
        let key = String(repeating: "Qk/9xZtLmN", count: 3)
        XCTAssertEqual(ProblemTextCut.prefix("key " + key + " tail", 4 + key.count), "key " + key, "the run ends at the cut")
    }
}
