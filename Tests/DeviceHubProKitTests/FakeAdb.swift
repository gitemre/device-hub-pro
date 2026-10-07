import Foundation
@testable import DeviceHubProKit

/// A fake `adb` executable for `AdbClient` tests: a `FakeTool` named `adb`.
/// Every invocation's argv is appended to a trace; the first rule whose
/// `match` is a substring of the argv answers with its output and exit code,
/// and anything unmatched exits 0 silently.
final class FakeAdb {
    typealias Rule = FakeTool.Rule

    let tool: FakeTool
    let client: AdbClient

    var directory: URL { tool.directory }

    init(_ rules: [Rule]) throws {
        tool = try FakeTool(name: "adb", rules: rules)
        client = AdbClient(adbURL: tool.executableURL)
    }

    /// Every argv adb was called with, in order.
    var calls: [String] { tool.calls }
}
