import XCTest
@testable import DeviceHubProApp

/// The TV remote sits right under the device, never lower than the pill's band.
final class TVRemotePlacementTests: XCTestCase {
    private let band = ParityMetrics.mainStagePillBand

    func testRemoteHugsASmallDeviceInATallStage() {
        let top = TVRemotePlacement.top(stageHeight: 900, pillBand: band, deviceHeight: 270)
        // The device is centred in what the stage keeps for it; the remote
        // starts a gap under its bottom edge.
        let area = 900 - TVRemoteView.reservedHeight - 20 - band
        let deviceBottom = 10 + area / 2 + 135
        XCTAssertEqual(top, deviceBottom + TVRemotePlacement.gap, accuracy: 0.5)
        XCTAssertLessThan(top, 900 - band - TVRemotePlacement.height - 8)
    }

    func testRemoteNeverGoesBelowThePillBand() {
        let stage: CGFloat = 400
        let top = TVRemotePlacement.top(stageHeight: stage, pillBand: band, deviceHeight: 380)
        XCTAssertEqual(top, stage - band - 8 - TVRemotePlacement.height, accuracy: 0.001)
    }

    func testAnUnmeasuredDeviceStillPlacesTheRemoteInsideTheStage() {
        let top = TVRemotePlacement.top(stageHeight: 700, pillBand: band, deviceHeight: 0)
        XCTAssertGreaterThan(top, 0)
        XCTAssertLessThan(top + TVRemotePlacement.height, 700)
    }
}
