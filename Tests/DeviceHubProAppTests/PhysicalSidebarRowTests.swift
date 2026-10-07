import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// A physical iPhone's sidebar row reads like Device Hub's (measured on
/// Device Hub 27.0, 2026-09-29): the marketing model under the name, whatever
/// the connection state.
@MainActor
final class PhysicalSidebarRowTests: XCTestCase {
    func testTheSubtitleIsTheModelNotTheState() async throws {
        let stub = try makePhysicalStub()
        for enabled in [true, false] {
            let inventory = try await makeListedPhysicalInventory(stub: stub, enabled: enabled)
            let entry = try XCTUnwrap(inventory.entries.first)
            XCTAssertEqual(DeviceSidebarView.physicalSubtitle(entry), "iPhone 12", "enabled: \(enabled)")
        }
    }
}
