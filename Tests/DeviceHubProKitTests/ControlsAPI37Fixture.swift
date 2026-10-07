import Foundation
import XCTest

/// Byte-exact device output under `Fixtures/api37-emulator/controls`.
enum ControlsAPI37Fixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/api37-emulator/controls", isDirectory: true)

    static func text(_ name: String) throws -> String {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        return try XCTUnwrap(String(data: data, encoding: .utf8), "\(name) is UTF-8")
    }
}
