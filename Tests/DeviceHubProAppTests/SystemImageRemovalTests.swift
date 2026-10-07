import DeviceHubProKit
@testable import DeviceHubProApp
import XCTest

/// Settings ▸ Android system images ▸ Remove…: the confirmation's words and
/// the removal through sdkmanager (a fake one, never the real SDK).
@MainActor
final class SystemImageRemovalTests: XCTestCase {
    private let image = SystemImage(
        package: "system-images;android-36;google-tv;arm64-v8a",
        api: "android-36", tag: "google-tv", abi: "arm64-v8a"
    )

    // MARK: - The confirmation

    func testAnUnusedImageSaysWhatItFrees() {
        let plan = SystemImageRemovalPlan.make(image: image, sizeText: "8,1 GB", users: [], runningUsers: [])
        XCTAssertEqual(plan.title, "Remove Android 16 · Google TV · arm64?")
        XCTAssertTrue(plan.message.hasPrefix("This frees 8,1 GB. No emulator uses this image"), plan.message)
        XCTAssertNil(plan.blockedReason)
    }

    func testTheEmulatorsBuiltOnItAreNamed() {
        let one = SystemImageRemovalPlan.make(image: image, sizeText: "8,1 GB", users: ["Television (4K)"], runningUsers: [])
        XCTAssertTrue(one.message.contains("Television (4K) uses it and will not start"), one.message)
        let two = SystemImageRemovalPlan.make(image: image, sizeText: "…", users: ["A", "B"], runningUsers: [])
        XCTAssertTrue(two.message.hasPrefix("These emulators use it"), "an unknown size is left out: \(two.message)")
        XCTAssertTrue(two.message.hasSuffix("A, B."), two.message)
    }

    func testARunningEmulatorBlocksTheRemoval() {
        let plan = SystemImageRemovalPlan.make(
            image: image, sizeText: "8,1 GB", users: ["Television (4K)"], runningUsers: ["Television (4K)"]
        )
        XCTAssertEqual(plan.blockedReason, "Shut down Television (4K) first: it runs on this image.")
    }

    // MARK: - The removal

    func testRemovingAnImageUninstallsItAndRescans() async throws {
        let sandbox = try Sandbox.make()
        try sandbox.install(image.package)
        let sdk = SDKComponentModel(
            locateClient: { sandbox.client() },
            locateSdkRoot: { sandbox.sdkRoot },
            installSlot: SDKInstallSlot()
        )
        await sdk.rescanInstalled()
        XCTAssertEqual(sdk.installedImages.map(\.package), [image.package])

        let failure = await sdk.removeImage(package: image.package)

        XCTAssertNil(failure)
        XCTAssertTrue(sdk.installedImages.isEmpty)
        XCTAssertNil(sdk.removingPackage)
        XCTAssertEqual(sandbox.recordedArgs(), ["--uninstall", image.package])
        // The empty parents sdkmanager leaves are gone; system-images stays.
        let images = sandbox.sdkRoot.appendingPathComponent("system-images")
        XCTAssertFalse(FileManager.default.fileExists(atPath: images.appendingPathComponent("android-36").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: images.path))
    }

    func testPruningKeepsADirectoryThatStillHoldsAnImage() throws {
        let sandbox = try Sandbox.make()
        try sandbox.install("system-images;android-36;google_apis;arm64-v8a")
        let empty = sandbox.sdkRoot.appendingPathComponent("system-images/android-36/google-tv")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        SDKComponentModel.pruneEmptyDirectories(of: "system-images;android-36;google-tv;arm64-v8a", sdkRoot: sandbox.sdkRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sandbox.sdkRoot.appendingPathComponent("system-images/android-36/google_apis/arm64-v8a/package.xml").path
        ))
    }

    func testAFailedRemovalIsKeptForTheRowAndTheImageStays() async throws {
        let sandbox = try Sandbox.make(failUninstall: true)
        try sandbox.install(image.package)
        let sdk = SDKComponentModel(
            locateClient: { sandbox.client() },
            locateSdkRoot: { sandbox.sdkRoot },
            installSlot: SDKInstallSlot()
        )
        await sdk.rescanInstalled()

        let failure = await sdk.removeImage(package: image.package)

        XCTAssertNotNil(failure)
        XCTAssertEqual(sdk.removalFailures[image.package], failure)
        XCTAssertEqual(sdk.installedImages.map(\.package), [image.package])
    }

    func testARemovalWaitsForAnInstallElsewhere() async throws {
        let sandbox = try Sandbox.make()
        try sandbox.install(image.package)
        let slot = SDKInstallSlot()
        XCTAssertTrue(slot.claim("emulator"))
        let sdk = SDKComponentModel(locateClient: { sandbox.client() }, locateSdkRoot: { sandbox.sdkRoot }, installSlot: slot)

        let failure = await sdk.removeImage(package: image.package)

        XCTAssertEqual(failure, SDKComponentModel.removalBusyMessage)
        XCTAssertTrue(sandbox.recordedArgs().isEmpty, "sdkmanager never ran")
    }

    /// A fake sdkmanager over a temporary SDK: `--uninstall` removes the
    /// package directory (or fails), every call is recorded.
    private struct Sandbox {
        let root: URL
        var sdkRoot: URL { root.appendingPathComponent("sdk", isDirectory: true) }
        var argsFile: URL { root.appendingPathComponent("args.txt") }

        func client() -> SdkmanagerClient {
            SdkmanagerClient(
                sdkmanagerURL: root.appendingPathComponent("sdkmanager"),
                javaURL: root.appendingPathComponent("jdk/bin/java"),
                environment: ["PATH": "/usr/bin:/bin"]
            )
        }

        func install(_ package: String) throws {
            let directory = sdkRoot.appendingPathComponent(package.split(separator: ";").joined(separator: "/"))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("<package/>".utf8).write(to: directory.appendingPathComponent("package.xml"))
            try Data(repeating: 1, count: 1024).write(to: directory.appendingPathComponent("system.img"))
        }

        func recordedArgs() -> [String] {
            ((try? String(contentsOf: argsFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        static func make(failUninstall: Bool = false) throws -> Sandbox {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("SystemImageRemovalTests-\(UUID().uuidString)", isDirectory: true)
            let java = root.appendingPathComponent("jdk/bin/java")
            try FileManager.default.createDirectory(at: java.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write("#!/bin/sh\necho 'openjdk version \"21\"' >&2\n", to: java)
            let remove = failUninstall
                ? "printf 'boom: cannot uninstall\\n' >&2; exit 3"
                : "rm -rf \"$ROOT/sdk/$(printf '%s' \"$2\" | tr ';' '/')\""
            try write("""
                #!/bin/sh
                ROOT="\(root.path)"
                printf '%s\\n' "$@" >> "$ROOT/args.txt"
                if [ "$1" = "--uninstall" ]; then \(remove); fi
                exit 0
                """, to: root.appendingPathComponent("sdkmanager"))
            return Sandbox(root: root)
        }

        private static func write(_ text: String, to url: URL) throws {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
}
