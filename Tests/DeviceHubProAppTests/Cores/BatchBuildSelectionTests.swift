import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// Install Build's choice: builds, at most one per platform.
final class BatchBuildSelectionTests: XCTestCase {
    private func file(_ path: String, directory: Bool = false) -> (url: URL, isDirectory: Bool) {
        (url: URL(fileURLWithPath: path), isDirectory: directory)
    }

    func testOneBuildPerPlatformIsTaken() throws {
        let builds = try BatchBuildSelection.builds(from: [
            file("/tmp/app-debug.apk"),
            file("/tmp/Runner.app", directory: true),
        ]).get()
        XCTAssertEqual(builds.map(\.platform), [.android, .apple])
        XCTAssertEqual(builds.map { $0.url.lastPathComponent }, ["app-debug.apk", "Runner.app"])
    }

    func testAFolderOfSplitAPKsIsAnAndroidBuild() throws {
        let builds = try BatchBuildSelection.builds(from: [file("/tmp/splits", directory: true)]).get()
        XCTAssertEqual(builds.map(\.platform), [.android])
    }

    func testTwoBuildsForOnePlatformAreRefused() {
        XCTAssertEqual(
            BatchBuildSelection.builds(from: [file("/tmp/a.apk"), file("/tmp/b.apks")]),
            .failure(.twoForOnePlatform(.android))
        )
        XCTAssertEqual(
            BatchBuildSelection.builds(from: [file("/tmp/A.ipa"), file("/tmp/B.zip")]),
            .failure(.twoForOnePlatform(.apple))
        )
        XCTAssertEqual(
            BatchBuildProblem.twoForOnePlatform(.apple).description,
            "Choose one simulator build: every selected simulator installs the same one."
        )
    }

    func testAFileThatIsNoBuildIsNamed() {
        XCTAssertEqual(
            BatchBuildSelection.builds(from: [file("/tmp/a.apk"), file("/tmp/notes.txt")]),
            .failure(.notABuild("notes.txt"))
        )
    }
}
