import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// A physical device's stage starts from what it showed last and from its
/// own geometry, never from the device selected before it.
@MainActor
final class LastPictureSeedTests: XCTestCase {
    private let first = "00008110-0011223344556677"
    private let second = "00008120-8899AABBCCDDEEFF"

    private func session(_ udid: String, width: Int, height: Int, fill: UInt8 = 5) -> PhysicalScreenshotSession {
        let session = PhysicalScreenshotSession(hardwareUDID: udid, interval: .milliseconds(20)) { _ in }
        session.frames.put(Frame(data: Data(repeating: fill, count: width * height * 4), width: width, height: height, seq: 1))
        addTeardownBlock { session.stop() }
        return session
    }

    @discardableResult
    private func begin(_ session: PhysicalScreenshotSession, udid: String, on model: AppModel) -> Bool {
        model.workspace.beginMirrorSession(
            session,
            device: .physicalApple(udid),
            port: nil,
            capabilities: PhysicalLiveViewController.capabilities
        )
    }

    func testTheDeviceStartsFromItsLastPictureAndSize() throws {
        let model = AppModel.testing()
        let mirror = model.workspace.mirror
        XCTAssertTrue(begin(session(first, width: 117, height: 253, fill: 9), udid: first, on: model))
        XCTAssertNil(mirror.seedPicture, "nothing remembered the first time")
        model.workspace.stopMirror()

        XCTAssertTrue(begin(session(first, width: 117, height: 253, fill: 1), udid: first, on: model))
        let seed = try XCTUnwrap(mirror.seedPicture)
        XCTAssertEqual(seed.frame.data.first, 9, "the picture of the earlier session, not the new frame")
        XCTAssertEqual(mirror.mirrorViewState.devicePixelSize, CGSize(width: 117, height: 253))
    }

    func testTheNextDeviceNeverInheritsThePreviousDevicesGeometryOrPicture() {
        let model = AppModel.testing()
        let mirror = model.workspace.mirror
        begin(session(first, width: 117, height: 253), udid: first, on: model)
        mirror.mirrorViewState.devicePixelSize = CGSize(width: 1206, height: 2622)

        begin(session(second, width: 100, height: 200), udid: second, on: model)

        XCTAssertNil(mirror.mirrorViewState.devicePixelSize, "reset, not the other device's size")
        XCTAssertNil(mirror.seedPicture)
    }

    func testAnAndroidSessionBetweenKeepsTheirPicturesApart() {
        let model = AppModel.testing()
        let mirror = model.workspace.mirror
        begin(session(first, width: 117, height: 253), udid: first, on: model)
        model.workspace.stopMirror()

        model.workspace.beginMirrorSession(
            FakeMirrorSession(),
            device: .android("HT4CWJT01234"),
            port: nil,
            capabilities: .android(emulatorGrpc: false)
        )
        XCTAssertNil(mirror.seedPicture, "only a physical view is seeded")
        XCTAssertNil(mirror.mirrorViewState.devicePixelSize)
        model.workspace.stopMirror()

        begin(session(first, width: 117, height: 253), udid: first, on: model)
        XCTAssertNotNil(mirror.seedPicture, "the picture outlives the other device's session")
    }

    func testALandscapePictureDoesNotSeedAnUprightStage() {
        let model = AppModel.testing()
        let mirror = model.workspace.mirror
        begin(session(first, width: 253, height: 117), udid: first, on: model)
        model.workspace.stopMirror()

        begin(session(first, width: 117, height: 253), udid: first, on: model)
        XCTAssertNil(mirror.seedPicture, "the stage starts upright; a turned picture would show sideways")
        XCTAssertNil(mirror.mirrorViewState.devicePixelSize)
    }

    func testTheSeedEndsWithTheSession() {
        let model = AppModel.testing()
        let mirror = model.workspace.mirror
        begin(session(first, width: 117, height: 253), udid: first, on: model)
        model.workspace.stopMirror()
        begin(session(first, width: 117, height: 253), udid: first, on: model)
        XCTAssertNotNil(mirror.seedPicture)

        model.workspace.stopMirror()
        XCTAssertNil(mirror.seedPicture)
    }
}
