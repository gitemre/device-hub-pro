import Foundation
import DeviceHubProKit

/// Why the files chosen for Install Build are not a set it takes.
enum BatchBuildProblem: Error, Equatable, CustomStringConvertible {
    /// A file that is neither platform's build.
    case notABuild(String)
    /// Two builds for one platform: each device installs one.
    case twoForOnePlatform(DevicePlatform)

    var description: String {
        switch self {
        case .notABuild(let name):
            "“\(name)” is not a build. Choose an .apk, an .apks set or a folder of split APKs for Android, an .app, .ipa or .zip for simulators."
        case .twoForOnePlatform(.android):
            "Choose one Android build: every selected Android device installs the same one."
        case .twoForOnePlatform(.apple):
            "Choose one simulator build: every selected simulator installs the same one."
        }
    }
}

/// Install Build's choice: the chosen files as builds, at most one per
/// platform (an Android build and a simulator build together reach a mixed
/// selection).
enum BatchBuildSelection {
    static func builds(from files: [(url: URL, isDirectory: Bool)]) -> Result<[BatchBuild], BatchBuildProblem> {
        var builds: [BatchBuild] = []
        for file in files {
            guard let build = BatchBuild.classify(file.url, isDirectory: file.isDirectory) else {
                return .failure(.notABuild(file.url.lastPathComponent))
            }
            if builds.contains(where: { $0.platform == build.platform }) {
                return .failure(.twoForOnePlatform(build.platform))
            }
            builds.append(build)
        }
        return .success(builds)
    }
}
