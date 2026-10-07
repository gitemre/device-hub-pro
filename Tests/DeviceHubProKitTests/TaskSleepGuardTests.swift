import XCTest

/// Keeps every sleep in the package on the `Task.sleep(for:)` shim
/// (`Sources/DeviceHubProKit/Internal/TaskSleep.swift`). The standard library's
/// generic sleeps are `@_alwaysEmitIntoClient`: a call that bypasses the shim
/// makes our modules emit their own copy of the specialization again, and a
/// native-build-system release build aborts in `swift_task_dealloc`
/// (docs/native-build-async-odr.md). Unit tests cannot see that link-level
/// bug, so this test reads the sources instead.
final class TaskSleepGuardTests: XCTestCase {
    private static let sourcesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources", isDirectory: true)

    /// Sleeps that do not resolve to the shim: extra `tolerance:`/`clock:`
    /// arguments, or a clock's own `sleep(for:)`.
    private static let bypassPatterns = [
        #"\.sleep\(for:[^\n]*\b(tolerance|clock):"#,
        #"[Cc]lock(\(\))?\.sleep\(for:"#,
    ]

    func testNoSourceBypassesTheTaskSleepShim() throws {
        let files = try XCTUnwrap(FileManager.default.enumerator(
            at: Self.sourcesDirectory,
            includingPropertiesForKeys: nil
        )).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no sources found under \(Self.sourcesDirectory.path)")

        let expressions = try Self.bypassPatterns.map { try NSRegularExpression(pattern: $0) }
        var offenders: [String] = []
        for file in files where file.lastPathComponent != "TaskSleep.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                let range = NSRange(line.startIndex..., in: line)
                if expressions.contains(where: { $0.firstMatch(in: line, range: range) != nil }) {
                    offenders.append("\(file.lastPathComponent):\(number + 1): \(trimmed)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "use Task.sleep(for:) - see Sources/DeviceHubProKit/Internal/TaskSleep.swift")
    }

    /// The guard itself must catch the forms the shim cannot intercept.
    func testTheGuardRecognizesBypassingSleeps() throws {
        let expressions = try Self.bypassPatterns.map { try NSRegularExpression(pattern: $0) }
        func flagged(_ line: String) -> Bool {
            let range = NSRange(line.startIndex..., in: line)
            return expressions.contains { $0.firstMatch(in: line, range: range) != nil }
        }
        XCTAssertTrue(flagged("try await Task.sleep(for: .seconds(1), tolerance: .zero)"))
        XCTAssertTrue(flagged("try await Task.sleep(for: .seconds(1), clock: .continuous)"))
        XCTAssertTrue(flagged("try await ContinuousClock().sleep(for: .seconds(1))"))
        XCTAssertTrue(flagged("try await clock.sleep(for: interval)"))
        XCTAssertFalse(flagged("try await Task.sleep(for: .milliseconds(500))"))
        XCTAssertFalse(flagged("try? await Task.sleep(for: Self.frameFeedInterval(isRecording: true))"))
    }
}
