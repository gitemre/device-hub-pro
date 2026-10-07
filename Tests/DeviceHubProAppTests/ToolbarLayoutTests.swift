import AppKit
import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// The toolbar geometry measured against Device Hub on 2026-09-28 (ST-01,
/// TB-01): the leading accessory ends at the sidebar divider so the window
/// title starts beside it, and the leading cluster keeps DH's widths.
@MainActor
final class ToolbarLayoutTests: XCTestCase {
    // MARK: - Leading accessory

    func testTheAccessoryEndsAtTheSidebarDivider() {
        // A 300 pt sidebar with the accessory container starting at x = 88.
        XCTAssertEqual(LeadingToolbarAccessoryController.accessoryWidth(endX: 300, containerMinX: 88), 212)
        XCTAssertEqual(LeadingToolbarAccessoryController.accessoryWidth(endX: 320, containerMinX: 88), 232)
    }

    func testTheAccessoryNeverCollapsesToZeroWidth() {
        XCTAssertEqual(LeadingToolbarAccessoryController.accessoryWidth(endX: 50, containerMinX: 88), 1)
    }

    // MARK: - Leading cluster

    func testTheLeadingCapsuleMatchesDeviceHub() {
        // DH's capsule spans 173.5–248 pt: 74.5 pt of glass, 74 pt of layout.
        let capsule = 2 * ParityMetrics.toolbarLeadingButtonWidth
            + ParityMetrics.toolbarLeadingButtonSpacing
            + 2 * ParityMetrics.toolbarLeadingCapsulePadding
        XCTAssertEqual(capsule, 74)
        XCTAssertEqual(
            ParityMetrics.toolbarLeadingClusterWidth,
            capsule + ParityMetrics.toolbarLeadingClusterSpacing + ParityMetrics.toolbarSidebarToggleDiameter
        )
    }

    // MARK: - Stage title

    func testWithNoSelectionTheTitleIsDevices() {
        let model = AppModel.testing(adb: AdbClient(adbURL: URL(fileURLWithPath: "/usr/bin/false")))
        model.deviceSelection = nil
        let stage = StageTitle(model: model, workspace: model.workspace)
        XCTAssertEqual(stage.title, "Devices")
        XCTAssertEqual(stage.subtitle, "No Selection", "DH's window subtitle")
    }

    // MARK: - TB-01 click-area forwarder

    /// `MenuHitAreaOverlay` catches the click a borderless `Menu`'s own tiny
    /// native hit region missed (2026-09-28: confirmed live, real clicks a
    /// few points off dead centre on the `+`/filter buttons opened nothing)
    /// and forwards it to the nearest `NSPopUpButton` — by centre-to-centre
    /// distance, not the first one found in view-tree order: the `+` and
    /// filter buttons are siblings a couple of points apart, and "first
    /// found" resolved to the `+` button for both forwarders, so a filter
    /// click opened Create a Device instead. Built with two real
    /// `NSPopUpButton`s in a shared parent (like the toolbar's `+`/filter
    /// pair) rather than the live app, so this pins the geometry rule alone.
    func testTheClickForwarderPicksTheNearestPopUpButtonNotTheFirst() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let plusButton = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 28, height: 36))
        let filterButton = NSPopUpButton(frame: NSRect(x: 33, y: 0, width: 28, height: 36))
        // Added in this order so "first in view-tree order" would pick the
        // `+` button for every probe if the distance check were removed.
        parent.addSubview(plusButton)
        parent.addSubview(filterButton)

        let filterProbe = NSView(frame: filterButton.frame)
        parent.addSubview(filterProbe)
        XCTAssertEqual(
            MenuHitAreaOverlay.ClickForwardingView.nearestPopUpButton(from: filterProbe),
            filterButton,
            "a probe over the filter button must not resolve to its + sibling"
        )

        let plusProbe = NSView(frame: plusButton.frame)
        parent.addSubview(plusProbe)
        XCTAssertEqual(MenuHitAreaOverlay.ClickForwardingView.nearestPopUpButton(from: plusProbe), plusButton)
    }

    /// No `NSPopUpButton` anywhere in the ancestor chain: the forwarder has
    /// nothing to forward to (falls back to `super.mouseDown`, not tested
    /// here — this pins only the lookup itself).
    func testTheClickForwarderFindsNothingWithoutAPopUpButtonNearby() {
        let parent = NSView(frame: .zero)
        let probe = NSView(frame: .zero)
        parent.addSubview(probe)
        XCTAssertNil(MenuHitAreaOverlay.ClickForwardingView.nearestPopUpButton(from: probe))
    }
}

// MARK: - TB-01 leading menu buttons (2026-09-29)

@MainActor
final class LeadingToolbarMenuTests: XCTestCase {
    /// The + / filter menus are built as native menus: a section header, radio
    /// checks, a rule and a Sort By submenu, with each item running its own
    /// action.
    func testTheMenuBuilderMakesHeadersChecksRulesSubmenusAndActions() {
        var fired: [String] = []
        let menu = ToolbarMenuEntry.makeMenu([
            .header("Simulators"),
            .item("iPhone…") { fired.append("iPhone") },
            .separator,
            .item("All Devices", isChecked: true) { fired.append("all") },
            .submenu("Sort By", [
                .item("Availability", isChecked: true) { fired.append("availability") },
                .item("Name") { fired.append("name") },
            ]),
        ])
        XCTAssertEqual(menu.items.map(\.title), ["Simulators", "iPhone…", "", "All Devices", "Sort By"])
        XCTAssertTrue(menu.items[0].isSectionHeader)
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertEqual(menu.items[3].state, .on)
        XCTAssertEqual(menu.items[1].state, .off)
        let sort = menu.items[4].submenu
        XCTAssertEqual(sort?.items.map(\.title), ["Availability", "Name"])
        XCTAssertEqual(sort?.items.map(\.state), [.on, .off])

        for item in [menu.items[1], menu.items[3], sort!.items[1]] {
            _ = (item.target as AnyObject?)?.perform(item.action!, with: item)
        }
        XCTAssertEqual(fired, ["iPhone", "all", "name"])
    }

    /// DH's menus hang from the toolbar's bottom, 26 pt under the button
    /// centre (the popped window's top sits 5 pt above the origin it is
    /// given, so the origin goes 31 pt under), with the left edge at the
    /// measured offset from the centre. Screen space is y-up.
    func testTheMenuOriginHangsBelowTheButtonCentre() {
        let origin = ToolbarMenuButtonOverlay.menuOrigin(center: NSPoint(x: 194.5, y: 1000), leading: -25.5)
        XCTAssertEqual(origin.x, 169)
        XCTAssertEqual(origin.y, 969)
    }
}
