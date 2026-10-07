import XCTest
@testable import DeviceHubProKit

final class LastPictureCacheTests: XCTestCase {
    private func frame(width: Int = 40, height: Int = 80, fill: UInt8 = 7, rotation: Int = 0) -> Frame {
        Frame(data: Data(repeating: fill, count: width * height * 4), width: width, height: height, seq: 3, rotation: rotation)
    }

    func testARememberedPictureComesBackForTheSamePose() throws {
        let cache = LastPictureCache(capacity: 4, maxSide: 960)
        cache.remember(frame(fill: 9), for: "a")

        let picture = try XCTUnwrap(cache.picture(for: "a", matching: .portrait))
        XCTAssertEqual(picture.frame.width, 40)
        XCTAssertEqual(picture.frame.height, 80)
        XCTAssertEqual(picture.fullSize, CGSize(width: 40, height: 80))
        XCTAssertEqual(picture.frame.data.first, 9)
        XCTAssertNil(cache.picture(for: "b", matching: .portrait))
    }

    func testAPictureOfAnotherPoseIsNotUsed() {
        let cache = LastPictureCache()
        cache.remember(frame(width: 80, height: 40), for: "a")
        XCTAssertNil(cache.picture(for: "a", matching: .portrait), "a landscape picture shows sideways upright")
        XCTAssertNotNil(cache.picture(for: "a", matching: PicturePose(rotation: 0, isLandscape: true)))

        cache.remember(frame(rotation: 1), for: "b")
        XCTAssertNil(cache.picture(for: "b", matching: .portrait), "another rotation is another pose")
        XCTAssertNotNil(cache.picture(for: "b", matching: PicturePose(rotation: 1, isLandscape: false)))
    }

    func testTheLeastRecentlyUsedDeviceGoesFirst() {
        let cache = LastPictureCache(capacity: 4, maxSide: 960)
        for key in ["a", "b", "c", "d"] { cache.remember(frame(), for: key) }
        XCTAssertEqual(cache.keys, ["d", "c", "b", "a"])

        // Reading "a" makes it the newest, so "b" is the oldest now.
        XCTAssertNotNil(cache.picture(for: "a", matching: .portrait))
        cache.remember(frame(), for: "e")

        XCTAssertEqual(cache.keys, ["e", "a", "d", "c"])
        XCTAssertNil(cache.picture(for: "b", matching: .portrait))
    }

    func testRememberingADeviceAgainReplacesItsPicture() throws {
        let cache = LastPictureCache(capacity: 2, maxSide: 960)
        cache.remember(frame(fill: 1), for: "a")
        let first = try XCTUnwrap(cache.picture(for: "a", matching: .portrait))
        cache.remember(frame(fill: 2), for: "a")
        let second = try XCTUnwrap(cache.picture(for: "a", matching: .portrait))

        XCTAssertEqual(cache.keys, ["a"])
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.frame.data.first, 2)
    }

    func testABigPictureIsShrunkAndKeepsItsFullSize() throws {
        let cache = LastPictureCache(capacity: 4, maxSide: 100)
        cache.remember(frame(width: 400, height: 800, fill: 200), for: "a")

        let picture = try XCTUnwrap(cache.picture(for: "a", matching: .portrait))
        XCTAssertEqual(picture.frame.height, 100)
        XCTAssertEqual(picture.frame.width, 50)
        XCTAssertEqual(picture.frame.data.count, 50 * 100 * 4)
        XCTAssertEqual(picture.fullSize, CGSize(width: 400, height: 800))
        XCTAssertEqual(picture.frame.data.first, 200, "a flat color survives the shrinking")
    }

    func testAFrameWhoseBytesDoNotFitIsNotKept() {
        let cache = LastPictureCache()
        cache.remember(frame(fill: 1), for: "a")
        cache.remember(Frame(data: Data(count: 10), width: 40, height: 80, seq: 0), for: "a")

        XCTAssertEqual(cache.picture(for: "a", matching: .portrait)?.frame.data.first, 1, "the earlier picture stays")
    }

    func testForgetDropsADevice() {
        let cache = LastPictureCache()
        cache.remember(frame(), for: "a")
        cache.forget("a")
        XCTAssertNil(cache.picture(for: "a", matching: .portrait))
        XCTAssertTrue(cache.keys.isEmpty)
    }
}
