import AppKit
import SwiftUI
import XCTest
@testable import DeviceHubProApp

/// The Apps tabs' scope popup and empty state. The popup used to be a
/// borderless `Menu` with a `Color.clear` label overlaid on the cell; SwiftUI
/// sized its popup button to the empty label (6 x 14 pt, measured with
/// `NSHostingView.hitTest`), so only a spot in the middle of the 100 pt cell
/// opened the menu.
@MainActor
final class AppsScopePopupTests: XCTestCase {
    private enum Scope: Hashable { case all, user }

    private final class Box { var selection = Scope.all }

    private func popup(_ box: Box) -> AppsScopePopup<Scope> {
        AppsScopePopup(
            title: "All Apps",
            sections: [.init(items: [("All Apps", Scope.all), ("User Apps", Scope.user)])],
            selection: Binding(get: { box.selection }, set: { box.selection = $0 })
        )
    }

    private func host<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> (NSHostingView<V>, NSWindow) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (hosting, window)
    }

    /// Clicks `point` (in the window's coordinates) as the window server
    /// would: a mouse down and up delivered to the window.
    private func click(_ point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            )
            if let event { window.sendEvent(event) }
        }
    }

    func testAClickAnywhereInTheCellShowsTheMenu() throws {
        let box = Box()
        let (hosting, window) = host(
            popup(box),
            width: ParityMetrics.inspectorAppsScopeWidth,
            height: ParityMetrics.inspectorAppsFilterHeight
        )
        var shown: [NSMenu] = []
        let saved = AppsScopePresenter.present
        AppsScopePresenter.present = { menu, _, _ in shown.append(menu) }
        defer { AppsScopePresenter.present = saved }
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let w = hosting.bounds.width
        let h = hosting.bounds.height
        // The old cell opened only within a few points of its centre.
        let points = [
            NSPoint(x: 3, y: 3), NSPoint(x: w - 3, y: h - 3),
            NSPoint(x: 10, y: h / 2), NSPoint(x: w - 10, y: h / 2),
        ]
        for point in points {
            shown.removeAll()
            click(point, in: window)
            XCTAssertEqual(shown.count, 1, "a click at \(point) opens the menu")
        }
        let menu = try XCTUnwrap(shown.first)
        XCTAssertEqual(menu.items.map(\.title), ["All Apps", "User Apps"])
        XCTAssertEqual(menu.items.map(\.state), [.on, .off], "the current scope is checked")
    }

    func testPickingAnItemChangesTheSelection() throws {
        let box = Box()
        var shown: NSMenu?
        let saved = AppsScopePresenter.present
        AppsScopePresenter.present = { menu, _, _ in shown = menu }
        defer { AppsScopePresenter.present = saved }

        // Pressing the button is the same call a click makes.
        popup(box).present()
        let item = try XCTUnwrap(shown?.items.last)
        _ = item.target?.perform(item.action, with: item)
        XCTAssertEqual(box.selection, .user)
    }

    // MARK: - Empty states

    func testAnEmptyScopeSaysWhyAndNamesTheFix() {
        XCTAssertEqual(AppsController.AppsScope.user.emptyLabel, "No user-installed apps")
        XCTAssertEqual(AppsController.AppsScope.system.emptyLabel, "No system apps")
        XCTAssertEqual(AppsController.AppsScope.all.emptyLabel, "No Apps")
        XCTAssertEqual(PhysicalAppScope.userApps.emptyLabel, "No user-installed apps")
        XCTAssertEqual(PhysicalAppScope.allApps.emptyLabel, "No Apps")
    }

    func testTheEmptyStateShowsAllAppsButtonOnlyWhenAScopeIsTheCause() throws {
        var widened = 0
        let (hosting, window) = host(
            AppsEmptyState(message: "No user-installed apps", showAll: { widened += 1 }),
            width: 300, height: 120
        )
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        // The link sits under the message; scan the column for it.
        for y in stride(from: 10.0, to: 110.0, by: 6.0) where widened == 0 {
            click(NSPoint(x: 150, y: y), in: window)
        }
        XCTAssertEqual(widened, 1, "Show All Apps widens the scope")
        _ = hosting

        XCTAssertNil(AppsEmptyState(message: "No Apps", showAll: nil).showAll)
    }
}
