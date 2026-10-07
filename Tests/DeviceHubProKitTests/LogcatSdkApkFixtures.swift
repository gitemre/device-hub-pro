import Foundation
import XCTest

/// Real output captured from the tools the logcat, diagnostics, SDK, Pixel,
/// APK, skin and AVD parsers read, byte for byte. Nothing in the fixture
/// directory is hand-written:
///
/// - device commands ran read-only against an API 37 emulator
///   (`emulator-5554`, Pixel 9 Pro Fold AVD, `sdk_gphone16k_arm64`,
///   google_apis_playstore_ps16k): `adb -s emulator-5554 <command>`, one
///   file per command, named after it;
/// - host tools ran locally: `sdkmanager` (cmdline-tools 22.0), `aapt2`
///   (build-tools 37.0.0) and `unzip` on APKs pulled read-only from the
///   emulator (`adb pull` of AOSP system apps and the Device Hub Pro verifier);
/// - skin layouts and AVD `config.ini`/`<name>.ini` files are copies of the
///   SDK's `skins/` and `~/.android/avd/`.
///
/// Loaded relative to this file, so no `Package.swift` resource entry is
/// needed.
enum LogcatSdkApkFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/api37-emulator/logcat-sdk-apk", isDirectory: true)

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func data(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        try XCTUnwrap(
            try? Data(contentsOf: url(name)),
            "missing fixture \(name)",
            file: file,
            line: line
        )
    }

    /// The fixture decoded as UTF-8; every text fixture is valid UTF-8.
    static func text(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try XCTUnwrap(
            String(data: try data(name, file: file, line: line), encoding: .utf8),
            "fixture \(name) is not UTF-8",
            file: file,
            line: line
        )
    }

    /// A fresh temporary directory, removed when the test ends.
    static func temporaryDirectory(_ testCase: XCTestCase, prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// An executable script at `directory/name`.
    static func script(_ content: String, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
