import XCTest
@testable import DeviceHubProApp

/// The free names an auto-saved recording is moved to.
final class AutoSaveNamerTests: XCTestCase {
    private let clip = URL(fileURLWithPath: "/tmp/devicehubpro-recordings/ABC/Pixel_9-20260925-101500.mp4")
    private let desktop = URL(fileURLWithPath: "/Users/me/Desktop", isDirectory: true)

    func testAFreeNameIsTheClipsOwn() {
        let destination = AutoSaveNamer.destination(for: clip, in: desktop) { _ in false }
        XCTAssertEqual(destination.path, "/Users/me/Desktop/Pixel_9-20260925-101500.mp4")
    }

    func testTakenNamesGetDashTwoThenDashThree() {
        var taken: Set<String> = ["/Users/me/Desktop/Pixel_9-20260925-101500.mp4"]
        XCTAssertEqual(
            AutoSaveNamer.destination(for: clip, in: desktop) { taken.contains($0) }.lastPathComponent,
            "Pixel_9-20260925-101500-2.mp4"
        )
        taken.insert("/Users/me/Desktop/Pixel_9-20260925-101500-2.mp4")
        XCTAssertEqual(
            AutoSaveNamer.destination(for: clip, in: desktop) { taken.contains($0) }.lastPathComponent,
            "Pixel_9-20260925-101500-3.mp4"
        )
    }

    func testTheNameLoopAsksAboutEachCandidateInOrder() {
        var asked: [String] = []
        let destination = AutoSaveNamer.destination(for: clip, in: desktop) { path in
            asked.append((path as NSString).lastPathComponent)
            return asked.count < 3
        }
        XCTAssertEqual(asked, [
            "Pixel_9-20260925-101500.mp4",
            "Pixel_9-20260925-101500-2.mp4",
            "Pixel_9-20260925-101500-3.mp4",
        ])
        XCTAssertEqual(destination.lastPathComponent, "Pixel_9-20260925-101500-3.mp4")
    }

    func testSuffixedNamesAreAlwaysMp4() {
        let other = URL(fileURLWithPath: "/tmp/clip.mov")
        let destination = AutoSaveNamer.destination(for: other, in: desktop) { $0.hasSuffix("/clip.mov") }
        XCTAssertEqual(destination.lastPathComponent, "clip-2.mp4")
    }
}
