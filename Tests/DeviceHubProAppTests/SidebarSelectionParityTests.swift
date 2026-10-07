import AppKit
import SwiftUI
import XCTest
@testable import DeviceHubProApp

/// Sidebar parity, round 2 (2026-09-29).
final class SidebarSelectionParityTests: XCTestCase {
    private func row(title: String, model: String?) -> SidebarDeviceRow {
        SidebarDeviceRow(
            selection: .simulator("udid"),
            title: title,
            subtitle: "Simulator",
            version: "26.5",
            isRunning: false,
            symbol: "ipad",
            isEmulator: true,
            platform: .apple,
            searchText: model
        )
    }

    /// DH finds a simulator by its name and by its device family ("ipad"
    /// finds an iPad simulator named something else), not by the model
    /// (measured 2026-09-29: "A16" and "iphone 17" miss a simulator of that
    /// model with another name).
    func testTheSearchMatchesTheFamilyAsWellAsTheNameButNotTheModel() {
        let family = SidebarDeviceRow.searchFamily(of: "iPad Pro 13-inch (M5)")
        XCTAssertEqual(family, "iPad")
        let ipad = row(title: "Studio display test", model: family)
        XCTAssertTrue(ipad.matches(query: "ipad"))
        XCTAssertTrue(ipad.matches(query: "STUD"))
        XCTAssertFalse(ipad.matches(query: "iphone"))
        XCTAssertFalse(ipad.matches(query: "13-inch"))
        XCTAssertFalse(row(title: "Pixel", model: nil).matches(query: "ipad"))
        let phone = row(title: "z", model: SidebarDeviceRow.searchFamily(of: "iPhone 17"))
        XCTAssertTrue(phone.matches(query: "iphone"))
        XCTAssertFalse(phone.matches(query: "iphone 17"))
        XCTAssertEqual(SidebarDeviceRow.searchFamily(of: "Apple TV 4K (3rd generation)"), "Apple TV")
        XCTAssertNil(SidebarDeviceRow.searchFamily(of: nil))
    }

    /// A booted row on the accent pill keeps its coloured glyph on a light
    /// tile; DH's tile reads #c3d5fd over #0270f5.
    func testTheBootedSelectedTileIsLighterThanTheStoppedOne() {
        XCTAssertGreaterThan(
            ParityMetrics.sidebarSelectedBootedTileOpacity,
            ParityMetrics.sidebarSelectedTileOpacity * 2
        )
    }

    /// A window that is not key draws DH's paler gray (#e7e7e8) under the
    /// selection, lighter than the key window's unfocused #d7d7d7.
    func testTheInactiveSelectionIsPalerThanTheKeyWindowsGray() throws {
        let inactive = try XCTUnwrap(NSColor(ParityMetrics.sidebarSelectionInactive).usingColorSpace(.sRGB))
        XCTAssertEqual(inactive.redComponent, 231.0 / 255, accuracy: 0.004)
        XCTAssertGreaterThan(inactive.redComponent, ParityMetrics.sidebarSelectionWhite)
    }
}
