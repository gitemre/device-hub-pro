import XCTest
@testable import DeviceHubProKit

/// Send Files: routing per platform, the argv
/// each path runs, and the overlay's words.
///
/// The fixtures under `Fixtures/api35-emulator/send-files/` are byte-exact
/// captures from an API 35 emulator (AVD created for the run, `emulator-5580`,
/// platform-tools 37.0.0) of the commands the code runs; the ones under
/// `Fixtures/ios27-simulator/send-files/` are captures from an iPhone 17 Pro on
/// iOS 27.0 in a private device set (Xcode 27.0, 27A266a), taken on 2026-10-01.
/// No personal identifier was in them, so they are unchanged.
final class SendFilesTests: XCTestCase {
    private static let androidFixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/api35-emulator/send-files", isDirectory: true)
    private static let simulatorFixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ios27-simulator/send-files", isDirectory: true)

    private func android(_ name: String) throws -> String {
        try String(contentsOf: Self.androidFixtures.appendingPathComponent(name), encoding: .utf8)
    }

    private func file(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/send/\(name)") }

    private func makeFolder(_ files: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SendFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        for name in files {
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        return folder
    }

    // MARK: - Android routing and destination

    func testAndroidRoutingInstallsPackagesAndPushesEverythingElse() throws {
        let splits = try makeFolder(["base.apk", "split_config.apk"])
        let tree = try makeFolder(["a.txt", "sub/b.png"])
        let routes = AndroidSendRouting.route([file("app.apk"), file("photo.png"), splits, file("set.apks"), tree, file("notes.txt")])
        // The pushes are gathered into the first one, in the order they came.
        XCTAssertEqual(routes.count, 4)
        XCTAssertEqual(routes[0], .install(file("app.apk")))
        XCTAssertEqual(routes[2], .install(splits))
        XCTAssertEqual(routes[3], .install(file("set.apks")))
        XCTAssertEqual(routes[1], .push([file("photo.png"), tree, file("notes.txt")]))
    }

    func testAFolderWithOtherFilesIsPushedNotInstalled() throws {
        let mixed = try makeFolder(["base.apk", "readme.txt"])
        XCTAssertFalse(AndroidSendRouting.isInstallable(mixed))
        XCTAssertTrue(AndroidSendRouting.isInstallable(file("x.APK")))
        XCTAssertFalse(AndroidSendRouting.isInstallable(file("x.png")))
    }

    func testDestinationsNormaliseAndRefuse() {
        XCTAssertEqual(AndroidSendDestination.normalize(custom: "Download/Test"), "/sdcard/Download/Test")
        XCTAssertEqual(AndroidSendDestination.normalize(custom: "/storage/emulated/0/Download/Test/"), "/sdcard/Download/Test")
        XCTAssertEqual(AndroidSendDestination.normalize(custom: " /sdcard/DCIM "), "/sdcard/DCIM")
        XCTAssertNil(AndroidSendDestination.normalize(custom: "/data/local/tmp"))
        XCTAssertNil(AndroidSendDestination.normalize(custom: "Download/../../data"))
        XCTAssertNil(AndroidSendDestination.normalize(custom: ""))
        XCTAssertNil(AndroidSendDestination.normalize(custom: "Download/a\nb"))
        XCTAssertEqual(AndroidSendDestination.from(storedValue: "/sdcard/Pictures"), .pictures)
        XCTAssertEqual(AndroidSendDestination.from(storedValue: "Test/Inbox"), .custom("/sdcard/Test/Inbox"))
        XCTAssertNil(AndroidSendDestination.from(storedValue: nil))
        for preset in AndroidSendDestination.presets {
            XCTAssertEqual(AndroidSendDestination.from(storedValue: preset.storedValue), preset)
        }
    }

    // MARK: - adb output (real captures)

    func testPushedCountReadsTheRealOutput() throws {
        XCTAssertEqual(AdbClient.pushedCount(from: try android("adb-push-file.stderr")), 1)
        XCTAssertEqual(AdbClient.pushedCount(from: try android("adb-push-folder.stderr")), 2)
        XCTAssertNil(AdbClient.pushedCount(from: try android("adb-push-missing.stderr")))
    }

    func testScanOutcomeReadsTheRealOutput() throws {
        let found = AdbClient.scanOutcome(try android("shell-scan-file-found.stdout"))
        XCTAssertEqual(found.answers, 1)
        XCTAssertEqual(found.misses, 0)
        let missing = AdbClient.scanOutcome(try android("shell-scan-file-missing.stdout"))
        XCTAssertEqual(missing.answers, 1)
        XCTAssertEqual(missing.misses, 1)
    }

    func testScanCommandQuotesThePath() {
        XCTAssertEqual(
            AdbClient.scanFileCommand(path: "/storage/emulated/0/Pictures/photo one.png"),
            "content call --uri content://media/external/file --method scan_file --arg '/storage/emulated/0/Pictures/photo one.png'"
        )
        XCTAssertTrue(AdbClient.scanFileCommand(path: "/storage/emulated/0/x/it's.png").contains("'\\''"))
    }

    func testFilesToPushKeepTheTree() throws {
        let tree = try makeFolder(["a.txt", "sub/b.png"])
        let name = tree.lastPathComponent
        XCTAssertEqual(AdbClient.filesToPush(tree), ["\(name)/a.txt", "\(name)/sub/b.png"])
        XCTAssertEqual(AdbClient.filesToPush(tree.appendingPathComponent("a.txt")), ["a.txt"])
    }

    // MARK: - adb argv

    func testSendRunsMkdirPushReadlinkAndScan() async throws {
        let tree = try makeFolder(["a.txt", "sub/b.png"])
        let photo = tree.appendingPathComponent("a.txt")
        let fake = try FakeAdb([
            .init("push", stderr: try android("adb-push-folder.stderr")),
            .init("readlink -f /sdcard", output: "/storage/emulated/0\n"),
            .init("scan_file", stdoutFile: Self.androidFixtures.appendingPathComponent("shell-scan-file-found.stdout")),
        ])
        let result = try await fake.client.send([tree, photo], to: .downloads, serial: "emulator-5580")
        XCTAssertEqual(result.filesPushed, 4)
        XCTAssertEqual(result.destination, "/sdcard/Download")
        XCTAssertEqual(result.scanned, 1)
        let calls = fake.tool.invocations
        XCTAssertEqual(calls[0], ["-s", "emulator-5580", "shell", "mkdir", "-p", "/sdcard/Download"])
        XCTAssertEqual(calls[1], ["-s", "emulator-5580", "push", tree.path, "/sdcard/Download/"])
        XCTAssertEqual(calls[2], ["-s", "emulator-5580", "push", photo.path, "/sdcard/Download/"])
        XCTAssertEqual(calls[3], ["-s", "emulator-5580", "shell", "readlink", "-f", "/sdcard"])
        let scan = try XCTUnwrap(calls.last)
        XCTAssertEqual(Array(scan.prefix(3)), ["-s", "emulator-5580", "shell"])
        let name = tree.lastPathComponent
        XCTAssertTrue(scan[3].contains("--arg /storage/emulated/0/Download/\(name)/a.txt"), scan[3])
        XCTAssertTrue(scan[3].contains("/Download/\(name)/sub/b.png"), scan[3])
    }

    func testAFailedPushThrowsAdbsWords() async throws {
        let fake = try FakeAdb([
            .init("push", stderr: try android("adb-push-missing.stderr"), exitCode: 1),
        ])
        do {
            _ = try await fake.client.send([file("nonexistent.bin")], to: .documents, serial: "emulator-5580")
            XCTFail("a failed push throws")
        } catch let AdbError.commandFailed(_, _, message) {
            XCTAssertTrue(message.contains("cannot stat"), message)
        }
    }

    /// Cancelling a push in flight stops adb and deletes the half-written file.
    func testACancelledPushRemovesThePartialFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CancelPush-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("calls.log")
        let script = """
        #!/bin/sh
        echo "$*" >> '\(log.path)'
        case "$*" in
        *" push "*) exec sleep 30 ;;
        esac
        exit 0
        """
        let executable = directory.appendingPathComponent("adb")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let client = AdbClient(adbURL: executable)
        let source = directory.appendingPathComponent("big.bin")
        try Data("x".utf8).write(to: source)

        let task = Task { try await client.send([source], to: .downloads, serial: "emulator-5580") }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              !((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains(" push ") {
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled push throws")
        } catch is CancellationError {}
        let calls = (try String(contentsOf: log, encoding: .utf8)).split(separator: "\n").map(String.init)
        XCTAssertTrue(
            calls.contains("-s emulator-5580 shell rm -f /sdcard/Download/big.bin"),
            "the partial file is removed: \(calls)"
        )
    }

    func testACustomDestinationOutsideTheStorageIsRefusedBeforeAdbRuns() async throws {
        let fake = try FakeAdb([])
        do {
            _ = try await fake.client.send([file("a.txt")], to: .custom("/data/local/tmp"), serial: "emulator-5580")
            XCTFail("refused")
        } catch AdbError.commandFailed {}
        XCTAssertEqual(fake.calls, [])
    }

    // MARK: - Simulator

    func testSimulatorPlanSplitsFilesFromWhatSimctlTakes() {
        let plan = SimulatorSendRouting.plan([
            file("a.png"), file("notes.txt"), file("Demo.app"), file("data.json"), file("root.pem"),
            URL(string: "https://example.com")!,
        ])
        XCTAssertEqual(plan.files, [file("notes.txt"), file("data.json")])
        XCTAssertEqual(plan.existing.count, 4)
    }

    func testAppGroupsReadTheRealOutput() throws {
        let text = try String(
            contentsOf: Self.simulatorFixtures.appendingPathComponent("get_app_container-files-groups.stdout"),
            encoding: .utf8
        )
        let groups = SimctlClient.appGroups(from: text)
        XCTAssertEqual(Set(groups.keys), ["group.com.apple.DocumentManager", "group.com.apple.FileProvider.LocalStorage", "group.com.apple.tipsnext"])
        XCTAssertTrue(try XCTUnwrap(groups[SimctlClient.fileProviderGroup]).path.contains("/data/Containers/Shared/AppGroup/"))
    }

    func testFilesAppStorageUsesAnExplicitUDIDAndMakesTheFolder() async throws {
        let group = FileManager.default.temporaryDirectory.appendingPathComponent("SendFilesTests-group-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: group) }
        let udid = "29277F2B-DD00-415C-AFEE-2C5716916D79"
        let fake = try FakeTool(name: "simctl", rules: [
            .init("get_app_container \(udid) com.apple.DocumentsApp groups", output: "group.com.apple.FileProvider.LocalStorage\t\(group.path)\n"),
        ])
        let set = FileManager.default.temporaryDirectory
        let client = SimctlClient(simctlURL: fake.executableURL, deviceSet: set)
        let storage = try await client.filesAppStorage(udid: udid)
        XCTAssertEqual(storage.lastPathComponent, "File Provider Storage")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.path))
        XCTAssertEqual(fake.invocations, [["--set", set.path, "get_app_container", udid, "com.apple.DocumentsApp", "groups"]])
        let source = try makeFolder(["a.txt", "sub/b.png"])
        XCTAssertEqual(try SimctlClient.copyItems([source, source], into: storage), 2, "a second copy replaces the first")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.appendingPathComponent(source.lastPathComponent + "/sub/b.png").path))
    }

    func testSimulatorDestinationsRoundTrip() {
        XCTAssertEqual(SimulatorFilesDestination.from(storedValue: "files"), .filesApp)
        XCTAssertEqual(SimulatorFilesDestination.from(storedValue: "app:com.example.demo"), .appDocuments(bundleIdentifier: "com.example.demo"))
        XCTAssertNil(SimulatorFilesDestination.from(storedValue: "app:-bad"))
        XCTAssertNil(SimulatorFilesDestination.from(storedValue: nil))
    }

    // MARK: - Physical routing

    func testPhysicalPlanKeepsAppsAndLinksAndCopiesTheRest() {
        let plan = PhysicalSendRouting.plan([file("a.ipa"), file("Demo.app"), file("a.png"), file("notes.txt"), URL(string: "https://example.com")!])
        XCTAssertEqual(plan.existing.count, 3)
        XCTAssertEqual(plan.files, [file("a.png"), file("notes.txt")])
        XCTAssertEqual(PhysicalSendRouting.containerPath(for: file("notes.txt")), "Documents/notes.txt")
    }

    // MARK: - The overlay's words

    func testTheOverlayNamesWhatWillHappen() throws {
        let photos = [file("1.png"), file("2.jpg"), file("3.heic")]
        let simulator = SendFilesTarget.simulator(filesDestination: .filesApp, filesAppName: nil)
        XCTAssertEqual(SendFilesSummary.describe(photos, target: simulator), "Add 3 photos to Photos")
        XCTAssertEqual(SendFilesSummary.describe([file("a.mov")], target: simulator), "Add 1 video to Photos")
        XCTAssertEqual(SendFilesSummary.describe([file("a.txt"), file("b.json")], target: simulator), "Copy 2 files to Files (On My iPhone)")
        XCTAssertEqual(SendFilesSummary.describe([file("Demo.app")], target: simulator), "Install app")
        XCTAssertEqual(SendFilesSummary.describe([file("card.vcf")], target: simulator), "Add 1 contact card to Contacts")
        XCTAssertEqual(
            SendFilesSummary.describe([file("a.txt")], target: .simulator(filesDestination: .appDocuments(bundleIdentifier: "x.y"), filesAppName: "Demo")),
            "Copy 1 file to Demo’s Documents"
        )
        let phone = SendFilesTarget.android(destination: .downloads)
        XCTAssertEqual(SendFilesSummary.describe([file("a.txt"), file("b.zip")], target: phone), "Copy 2 files to Downloads")
        XCTAssertEqual(SendFilesSummary.describe([file("a.apk")], target: phone), "Install app")
        XCTAssertEqual(SendFilesSummary.describe([file("a.apk"), file("p.png")], target: phone), "Install app, Copy 1 photo to Downloads")
        XCTAssertEqual(SendFilesSummary.describe([], target: phone), "Nothing to send")
    }

    func testThePhysicalOverlayExplainsPhotos() {
        let text = SendFilesSummary.describe([file("a.png")], target: .physical(appName: nil))
        XCTAssertEqual(text, "Copy 1 photo to an app’s Documents (choose one), Photos can't be added to a physical iPhone; choose an app's Documents.")
        XCTAssertEqual(
            SendFilesSummary.describe([file("a.txt")], target: .physical(appName: "Demo")),
            "Copy 1 file to Demo’s Documents"
        )
    }
}
