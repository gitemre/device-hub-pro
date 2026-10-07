import Darwin
import XCTest
@testable import DeviceHubProKit

/// The bounded record of what the device-side scrcpy server printed.
final class ScrcpyServerLogTests: XCTestCase {
    func testSplitsLinesOnAnyTerminatorAndSkipsBlankOnes() {
        let log = ScrcpyServerLog()
        log.append("[server] INFO: one\r\n\n[server] WARN: two\r[server] ")
        log.append("ERROR: three\n")

        XCTAssertEqual(log.lines, [
            "[server] INFO: one",
            "[server] WARN: two",
            "[server] ERROR: three",
        ])
        XCTAssertEqual(log.tail(2), "[server] WARN: two | [server] ERROR: three")
    }

    func testKeepsOnlyTheNewestLinesAndBoundsEachLine() {
        let log = ScrcpyServerLog(maximumLines: 3)
        for index in 0..<10 {
            log.append("line \(index)\n")
        }
        log.append(String(repeating: "x", count: 10_000) + "\n")

        XCTAssertEqual(log.lines.count, 3)
        XCTAssertEqual(Array(log.lines.prefix(2)), ["line 8", "line 9"])
        XCTAssertEqual(log.lines.last?.utf8.count, ScrcpyServerLog.maximumLineLength)
    }

    func testAnnotateQuotesTheTailOnlyWhenThereIsOne() {
        let log = ScrcpyServerLog()
        XCTAssertEqual(log.annotate("failed"), "failed")
        log.append("ERROR: Could not open video stream\n")
        XCTAssertEqual(
            log.annotate("failed"),
            "failed (scrcpy server: ERROR: Could not open video stream)"
        )
    }

    /// The final line of a process that exits without a newline still counts,
    /// and the end of its output is observable.
    func testCapturesAPipeToEOF() throws {
        let log = ScrcpyServerLog()
        let pipe = Pipe()
        log.capture(pipe.fileHandleForReading)
        try pipe.fileHandleForWriting.write(contentsOf: Data("first\nlast words".utf8))
        try pipe.fileHandleForWriting.close()

        XCTAssertTrue(log.waitForOutputEnd(timeout: 3))
        XCTAssertEqual(log.lines, ["first", "last words"])
        XCTAssertNil(log.exitStatus)
        log.markExited(status: 3)
        XCTAssertEqual(log.exitStatus, 3)
    }
}
