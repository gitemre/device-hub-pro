import XCTest
@testable import DeviceHubProApp

final class EmulatorUpdateOfferTests: XCTestCase {
    func testAnOlderEmulatorWithANewerPackageIsOffered() throws {
        let offer = try XCTUnwrap(
            EmulatorUpdateOffer.make(installed: "36.6.11", available: "37.2.12", emulatorRunning: false)
        )
        XCTAssertEqual(offer.title, "Update the emulator to 37.2.12")
        XCTAssertEqual(
            offer.caption,
            "The emulator 36.6.11 streams its screen the slow way: Device Hub Pro uses more memory and CPU. 37.2.12 streams it directly."
        )
        XCTAssertFalse(offer.blockedByRunningEmulator)
    }

    func testARunningEmulatorBlocksTheUpdate() throws {
        let offer = try XCTUnwrap(
            EmulatorUpdateOffer.make(installed: "36.6.11", available: "37.2.12", emulatorRunning: true)
        )
        XCTAssertTrue(offer.blockedByRunningEmulator)
    }

    func testNothingIsOfferedWhenUpToDateUnknownOrNotNewer() {
        XCTAssertNil(EmulatorUpdateOffer.make(installed: "37.2.3", available: "37.2.12", emulatorRunning: false))
        XCTAssertNil(EmulatorUpdateOffer.make(installed: "37.2.12", available: "37.2.12", emulatorRunning: false))
        XCTAssertNil(EmulatorUpdateOffer.make(installed: nil, available: "37.2.12", emulatorRunning: false))
        XCTAssertNil(EmulatorUpdateOffer.make(installed: "36.6.11", available: nil, emulatorRunning: false))
        XCTAssertNil(EmulatorUpdateOffer.make(installed: "36.6.11", available: "36.6.11", emulatorRunning: false))
    }
}
