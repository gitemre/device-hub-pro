import XCTest
@testable import DeviceHubProKit

final class LogcatParserTests: XCTestCase {
    func testParsesThreadtimeLine() {
        let line = "09-10 15:34:12.345  1234  1256 I ActivityManager: Start proc com.example"
        guard case .entry(let entry) = LogcatParser.parse(line) else {
            return XCTFail("expected an entry")
        }
        XCTAssertEqual(entry.timestamp, "09-10 15:34:12.345")
        XCTAssertEqual(entry.pid, 1234)
        XCTAssertEqual(entry.tid, 1256)
        XCTAssertEqual(entry.level, .info)
        XCTAssertEqual(entry.tag, "ActivityManager")
        XCTAssertEqual(entry.message, "Start proc com.example")
        XCTAssertFalse(entry.isCrash)
    }

    func testParsesAllLevels() {
        let levels = ["V", "D", "I", "W", "E", "F"]
        let expected: [LogcatLevel] = [.verbose, .debug, .info, .warning, .error, .fatal]
        for (letter, level) in zip(levels, expected) {
            guard case .entry(let entry) = LogcatParser.parse(
                "09-10 10:00:00.000  1  1 \(letter) Tag: msg"
            ) else {
                return XCTFail("expected an entry for \(letter)")
            }
            XCTAssertEqual(entry.level, level)
        }
    }

    func testParsesTagWithSpacesAndEmptyMessage() {
        guard case .entry(let entry) = LogcatParser.parse(
            "09-10 10:00:00.000  10  11 E My Tag : "
        ) else {
            return XCTFail("expected an entry")
        }
        XCTAssertEqual(entry.tag, "My Tag")
        XCTAssertEqual(entry.message, "")
    }

    func testDetectsCrashLines() {
        guard case .entry(let entry) = LogcatParser.parse(
            "09-10 10:00:00.000  10  11 E AndroidRuntime: FATAL EXCEPTION: main"
        ) else {
            return XCTFail("expected an entry")
        }
        XCTAssertTrue(entry.isCrash)
    }

    func testIndentedLinesAreContinuations() {
        guard case .continuation = LogcatParser.parse("    at com.example.Main.onCreate(Main.kt:42)") else {
            return XCTFail("expected a continuation")
        }
    }

    func testUnknownLinesAreUnparsed() {
        guard case .unparsed = LogcatParser.parse("--------- beginning of main") else {
            return XCTFail("expected an unparsed line")
        }
    }

    func testLevelSeverityOrdering() {
        XCTAssertLessThan(LogcatLevel.verbose.severity, LogcatLevel.info.severity)
        XCTAssertLessThan(LogcatLevel.info.severity, LogcatLevel.error.severity)
        XCTAssertLessThan(LogcatLevel.error.severity, LogcatLevel.fatal.severity)
    }
}
