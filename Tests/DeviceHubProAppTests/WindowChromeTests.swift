import AppKit
import XCTest
@testable import DeviceHubProApp

/// Window-chrome surgery support: the AppDelegate walks the window's view
/// tree to reach AppKit's split dividers, which are private classes matched
/// by name.
@MainActor
final class WindowChromeTests: XCTestCase {
    private final class SampleDividerView: NSView {}

    func testDescendantsFindTypedViewsAtAnyDepth() {
        let root = NSView()
        let split = NSSplitView()
        let button = NSButton()
        split.addSubview(button)
        button.addSubview(SampleDividerView())
        root.addSubview(split)

        XCTAssertEqual(root.devicehubproDescendants(ofType: NSSplitView.self).count, 1)
        XCTAssertTrue(root.devicehubproDescendants(ofType: NSSplitView.self).first === split)
        XCTAssertEqual(root.devicehubproDescendants(ofType: NSButton.self).count, 1)
        XCTAssertEqual(root.devicehubproDescendants(ofType: SampleDividerView.self).count, 1)
    }

    func testDescendantsExcludeTheReceiver() {
        let split = NSSplitView()
        XCTAssertTrue(split.devicehubproDescendants(ofType: NSSplitView.self).isEmpty)
    }

    func testSplitDividerMatchingIsNameBased() {
        XCTAssertTrue(SampleDividerView().devicehubproIsSplitDivider)
        XCTAssertFalse(NSSplitView().devicehubproIsSplitDivider)
        XCTAssertFalse(NSButton().devicehubproIsSplitDivider)
    }

    func testSystemSidebarToggleMatching() {
        let system = NSToolbarItem(
            itemIdentifier: NSToolbarItem.Identifier(
                "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
            )
        )
        XCTAssertTrue(system.devicehubproIsSystemSidebarToggle)

        for identifier in ["sidebar-toggle", "create-filter-capsule", "zoom-capsule"] {
            let item = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier(identifier))
            XCTAssertFalse(
                item.devicehubproIsSystemSidebarToggle,
                "\(identifier) must not be treated as the system toggle"
            )
        }
    }
}
