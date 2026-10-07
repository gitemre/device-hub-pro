import XCTest
@testable import DeviceHubProApp

/// Help ▸ Device Hub Pro Help is listed only for a real https page.
final class HelpLinkTests: XCTestCase {
    func testOnlyAnHttpsPageIsAHelpLink() {
        XCTAssertEqual(
            HelpLink.url(info: ["DeviceHubProHelpURL": "https://github.com/example/device-hub-pro#readme"])?.absoluteString,
            "https://github.com/example/device-hub-pro#readme"
        )
        XCTAssertNil(HelpLink.url(info: ["DeviceHubProHelpURL": ""]))
        XCTAssertNil(HelpLink.url(info: ["DeviceHubProHelpURL": "http://example.com"]))
        XCTAssertNil(HelpLink.url(info: [:]))
        XCTAssertNil(HelpLink.url(info: nil))
    }
}
