import XCTest
import SwiftUI
@testable import DeviceHubProApp

/// A collapsed Controls group shows its chevron, so it does not read as an empty header.
final class DHGroupChevronTests: XCTestCase {
    func testACollapsedGroupAlwaysShowsItsChevron() {
        XCTAssertTrue(DHGroup<EmptyView>.showsChevron(isExpanded: false, isHovered: false, isFocused: false))
    }

    func testAnOpenGroupShowsItOnlyOnHoverOrFocus() {
        XCTAssertFalse(DHGroup<EmptyView>.showsChevron(isExpanded: true, isHovered: false, isFocused: false))
        XCTAssertTrue(DHGroup<EmptyView>.showsChevron(isExpanded: true, isHovered: true, isFocused: false))
        XCTAssertTrue(DHGroup<EmptyView>.showsChevron(isExpanded: true, isHovered: false, isFocused: true))
    }
}
