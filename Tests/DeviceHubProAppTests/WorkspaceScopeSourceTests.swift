import Foundation
import XCTest

/// Pins that nothing outside `AppModel` reaches a window's own state through
/// `AppModel`'s first-workspace shortcuts (`model.deviceSelection`,
/// `model.mirror`, …). Those read `model.workspace` — the FIRST window's —
/// so with `DHP_MULTIWINDOW=1` a sidebar, stage, title or menu using
/// them acted on another window: choosing a device in one tab changed the
/// other tab's. Views read their own window's
/// `@Environment(DeviceWorkspace.self)`, and menus the focused
/// `\.deviceWorkspace`.
final class WorkspaceScopeSourceTests: XCTestCase {
    private static let firstWorkspaceShortcuts = [
        "simulatorCanvas", "simulatorApps", "simulatorCrashReports", "appleControls",
        "window", "deviceSelection", "multiSelection", "mirror", "apps", "location",
        "context", "capture", "media", "controlsPanel", "hardware", "conditions",
        "links", "extras", "clipboard", "logcat", "select", "stopMirror",
        "tearDownMirror", "requestReconnect", "beginMirrorSession", "applyActiveAvdName",
    ]

    /// `AppModel` itself defines the shortcuts, and `DeviceWorkspace` is the
    /// state they forward to.
    private static let exemptFiles: Set<String> = ["AppModel.swift", "DeviceWorkspace.swift"]

    func testNoAppSourceUsesAFirstWorkspaceShortcut() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/DeviceHubProApp")
        let names = Self.firstWorkspaceShortcuts.joined(separator: "|")
        let pattern = try NSRegularExpression(pattern: #"\bmodel\??\.("# + names + #")\b"#)
        var offenders: [String] = []
        var scanned = 0
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let name = url.lastPathComponent
            if Self.exemptFiles.contains(name) || name.hasPrefix("AppModel+") { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let range = NSRange(line.startIndex..., in: line)
                if pattern.firstMatch(in: line, range: range) != nil {
                    offenders.append("\(name):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        // A wrong path would scan nothing and pass; the app has well over 100 files.
        XCTAssertGreaterThan(scanned, 100, "scanned \(scanned) files under \(sources.path)")
        XCTAssertTrue(
            offenders.isEmpty,
            "Use the window's own DeviceWorkspace instead:\n" + offenders.joined(separator: "\n")
        )
    }
}
