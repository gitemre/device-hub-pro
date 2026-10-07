import AppKit
import XCTest
@testable import DeviceHubProApp

/// The sidebar scroller probe: it finds the list's scroll view from where
/// it sits, keeps its scrollers hidden through KVO, and does no periodic
/// work once attached (it used to walk the whole window twice a second).
@MainActor
final class SidebarScrollChromeTests: XCTestCase {
    private struct Tree {
        let window: NSWindow
        let probe: NSView
        let sidebarList: NSScrollView
        let canvas: NSScrollView
    }

    /// root ─┬─ sidebar column (x 0, 300 wide) ─┬─ probe host ─ probe
    ///       │                                   └─ list scroll view
    ///       └─ canvas scroll view (x 400)
    private func makeTree() -> Tree {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let column = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        let probeHost = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        let probe = NSView(frame: .zero)
        let list = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        list.hasVerticalScroller = true
        let canvas = NSScrollView(frame: NSRect(x: 400, y: 0, width: 600, height: 600))
        canvas.hasVerticalScroller = true

        probeHost.addSubview(probe)
        column.addSubview(probeHost)
        column.addSubview(list)
        root.addSubview(column)
        root.addSubview(canvas)

        let window = NSWindow(
            contentRect: root.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        return Tree(window: window, probe: probe, sidebarList: list, canvas: canvas)
    }

    func testFindsTheSidebarListFromTheProbe() {
        let tree = makeTree()
        XCTAssertTrue(SidebarScrollChrome.scrollView(near: tree.probe) === tree.sidebarList)
    }

    func testIgnoresScrollViewsAwayFromTheLeadingEdge() {
        let tree = makeTree()
        tree.sidebarList.removeFromSuperview()
        XCTAssertNil(SidebarScrollChrome.scrollView(near: tree.probe), "the canvas is not the sidebar")
    }

    func testAttachingHidesTheScrollersAndKeepsThemHidden() {
        let tree = makeTree()
        let coordinator = SidebarScrollChromeHider.Coordinator()
        coordinator.attach(from: tree.probe)

        XCTAssertFalse(tree.sidebarList.hasVerticalScroller)
        XCTAssertTrue(tree.canvas.hasVerticalScroller, "only the sidebar is touched")

        // SwiftUI re-applies the scroller on later layout passes.
        tree.sidebarList.hasVerticalScroller = true
        XCTAssertFalse(tree.sidebarList.hasVerticalScroller, "KVO re-hides at once")
        tree.sidebarList.hasHorizontalScroller = true
        XCTAssertFalse(tree.sidebarList.hasHorizontalScroller)

        coordinator.detach()
    }

    func testAnAttachedProbeSchedulesNoFurtherWork() {
        let tree = makeTree()
        let coordinator = SidebarScrollChromeHider.Coordinator()
        coordinator.attach(from: tree.probe)
        XCTAssertNil(coordinator.retryTimer, "no timer once the list is found")
        // Further updates take the fast path.
        coordinator.attach(from: tree.probe)
        XCTAssertNil(coordinator.retryTimer)
        coordinator.detach()
    }

    func testAMissingListRetriesUntilItAppears() async throws {
        let tree = makeTree()
        tree.sidebarList.removeFromSuperview()
        let coordinator = SidebarScrollChromeHider.Coordinator()
        coordinator.attach(from: tree.probe)
        XCTAssertNotNil(coordinator.retryTimer, "the list is not laid out yet")

        let list = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        list.hasVerticalScroller = true
        tree.probe.superview?.superview?.addSubview(list)

        let deadline = Date().addingTimeInterval(3)
        while list.hasVerticalScroller, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(list.hasVerticalScroller)
        XCTAssertNil(coordinator.retryTimer)
        coordinator.detach()
    }
}
