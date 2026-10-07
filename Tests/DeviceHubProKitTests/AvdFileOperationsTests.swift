import XCTest
@testable import DeviceHubProKit

private struct InjectedRollbackFailure: Error {}

final class AvdFileOperationsTests: XCTestCase {
    private var root: URL!
    private var avdHome: URL!
    private var fakeTrash: URL!

    private var fileManager: FileManager { FileManager.default }

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        avdHome = root.appendingPathComponent("avd", isDirectory: true)
        fakeTrash = root.appendingPathComponent("trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: avdHome, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A realistic AVD tree: `<Name>.ini` (absolute `path=` + `path.rel=`), the
    /// `<Name>.avd/` directory with a config plus userdata and a snapshot.
    @discardableResult
    private func makeAvd(named name: String = "Test") -> (ini: URL, directory: URL) {
        let directory = avdHome.appendingPathComponent("\(name).avd", isDirectory: true)
        let ini = avdHome.appendingPathComponent("\(name).ini")
        try? fileManager.createDirectory(
            at: directory.appendingPathComponent("snapshots/default_boot", isDirectory: true),
            withIntermediateDirectories: true
        )
        try? fileManager.createDirectory(
            at: directory.appendingPathComponent("snapshot", isDirectory: true),
            withIntermediateDirectories: true
        )
        try? iniText(name: name, directory: directory).write(to: ini, atomically: true, encoding: .utf8)
        try? configText(name: name).write(
            to: directory.appendingPathComponent("config.ini"),
            atomically: true,
            encoding: .utf8
        )
        for file in ["userdata-qemu.img", "userdata.img", "userdata-qemu.img.qcow2", "cache.img"] {
            try? Data("data".utf8).write(to: directory.appendingPathComponent(file))
        }
        try? Data("snap".utf8).write(
            to: directory.appendingPathComponent("snapshots/default_boot/snapshot.pb")
        )
        try? Data("old".utf8).write(to: directory.appendingPathComponent("snapshot/old.snap"))
        return (ini, directory)
    }

    private func iniText(name: String, directory: URL) -> String {
        """
        avd.ini.encoding=UTF-8
        path=\(directory.path)
        path.rel=avd/\(name).avd
        target=android-35

        """
    }

    private func configText(name: String) -> String {
        """
        AvdId=\(name)
        avd.ini.displayname=\(name)
        hw.lcd.width=1080
        hw.lcd.height=2400

        """
    }

    private func writeConfig(_ text: String, in directory: URL) {
        try? text.write(
            to: directory.appendingPathComponent("config.ini"),
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: - delete

    func testDeleteMovesIniAndDirectoryToInjectedTrash() throws {
        let avd = makeAvd()
        var trashed: [URL] = []

        try AvdFileOperations.delete(avdName: "Test", avdHome: avdHome) { url in
            trashed.append(url)
            try fileManager.moveItem(at: url, to: fakeTrash.appendingPathComponent(url.lastPathComponent))
        }

        XCTAssertEqual(Set(trashed), Set([avd.ini, avd.directory]))
        XCTAssertFalse(fileManager.fileExists(atPath: avd.ini.path))
        XCTAssertFalse(fileManager.fileExists(atPath: avd.directory.path))
        XCTAssertTrue(fileManager.fileExists(atPath: fakeTrash.appendingPathComponent("Test.ini").path))
        XCTAssertTrue(fileManager.fileExists(atPath: fakeTrash.appendingPathComponent("Test.avd").path))
    }

    func testDeleteThrowsForUnknownAvdWithoutCallingTrash() {
        var trashed: [URL] = []

        XCTAssertThrowsError(try AvdFileOperations.delete(avdName: "Ghost", avdHome: avdHome) { url in
            trashed.append(url)
        }) { error in
            guard case AvdFileOperationError.avdNotFound("Ghost") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(trashed.isEmpty)
    }

    func testDeleteTrashesTheDirectoryWhenTheIniIsMissing() throws {
        let avd = makeAvd()
        try fileManager.removeItem(at: avd.ini)
        var trashed: [URL] = []

        try AvdFileOperations.delete(avdName: "Test", avdHome: avdHome) { url in
            trashed.append(url)
        }

        XCTAssertEqual(trashed, [avd.directory])
        XCTAssertTrue(fileManager.fileExists(atPath: avd.directory.path))
    }

    // MARK: - rename

    func testRenameRewritesIniPathAndMovesBothItems() throws {
        let avd = makeAvd()

        let renamed = try AvdFileOperations.rename(avdName: "Test", to: "Renamed", avdHome: avdHome)

        XCTAssertEqual(renamed, "Renamed")
        let newIni = avdHome.appendingPathComponent("Renamed.ini")
        let newDirectory = avdHome.appendingPathComponent("Renamed.avd", isDirectory: true)
        XCTAssertFalse(fileManager.fileExists(atPath: avd.ini.path))
        XCTAssertFalse(fileManager.fileExists(atPath: avd.directory.path))
        XCTAssertTrue(fileManager.fileExists(atPath: newIni.path))
        XCTAssertTrue(fileManager.fileExists(atPath: newDirectory.appendingPathComponent("config.ini").path))
        XCTAssertTrue(fileManager.fileExists(atPath: newDirectory.appendingPathComponent("userdata-qemu.img").path))

        // Hand-derived: only the two path lines change, everything else is byte-identical.
        XCTAssertEqual(try String(contentsOf: newIni, encoding: .utf8), """
        avd.ini.encoding=UTF-8
        path=\(newDirectory.path)
        path.rel=avd/Renamed.avd
        target=android-35

        """)
    }

    func testRenameRejectsAnInvalidNameAndTouchesNothing() throws {
        let avd = makeAvd()
        let original = try String(contentsOf: avd.ini, encoding: .utf8)

        XCTAssertThrowsError(
            try AvdFileOperations.rename(avdName: "Test", to: "bad name!", avdHome: avdHome)
        ) { error in
            guard case AvdFileOperationError.invalidName("bad name!", let suggestion) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(suggestion, "bad_name")
        }

        XCTAssertTrue(fileManager.fileExists(atPath: avd.ini.path))
        XCTAssertTrue(fileManager.fileExists(atPath: avd.directory.path))
        XCTAssertEqual(try String(contentsOf: avd.ini, encoding: .utf8), original)
    }

    func testRenameRejectsAnExistingDestination() throws {
        let avd = makeAvd()
        let taken = makeAvd(named: "Taken")
        let takenIni = try String(contentsOf: taken.ini, encoding: .utf8)

        XCTAssertThrowsError(
            try AvdFileOperations.rename(avdName: "Test", to: "Taken", avdHome: avdHome)
        ) { error in
            guard case AvdFileOperationError.destinationExists("Taken") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertTrue(fileManager.fileExists(atPath: avd.ini.path))
        XCTAssertTrue(fileManager.fileExists(atPath: avd.directory.path))
        XCTAssertEqual(try String(contentsOf: taken.ini, encoding: .utf8), takenIni)
    }

    func testRenameRollsBackWhenTheDirectoryMoveFails() throws {
        let avd = makeAvd()
        let original = try String(contentsOf: avd.ini, encoding: .utf8)
        // A file-system failure after the ini was rewritten and moved: the
        // immutable flag makes the directory rename fail with EPERM.
        try fileManager.setAttributes([.immutable: true], ofItemAtPath: avd.directory.path)
        defer { try? fileManager.setAttributes([.immutable: false], ofItemAtPath: avd.directory.path) }

        XCTAssertThrowsError(
            try AvdFileOperations.rename(avdName: "Test", to: "Renamed", avdHome: avdHome)
        )

        XCTAssertTrue(fileManager.fileExists(atPath: avd.ini.path))
        XCTAssertTrue(fileManager.fileExists(atPath: avd.directory.path))
        XCTAssertFalse(fileManager.fileExists(atPath: avdHome.appendingPathComponent("Renamed.ini").path))
        XCTAssertEqual(try String(contentsOf: avd.ini, encoding: .utf8), original)
    }

    func testRenameUpdatesMatchingDisplayNameAndAvdId() throws {
        _ = makeAvd()
        let renamedDirectory = avdHome.appendingPathComponent("Renamed.avd", isDirectory: true)

        _ = try AvdFileOperations.rename(avdName: "Test", to: "Renamed", avdHome: avdHome)

        XCTAssertEqual(
            try String(contentsOf: renamedDirectory.appendingPathComponent("config.ini"), encoding: .utf8),
            """
            AvdId=Renamed
            avd.ini.displayname=Renamed
            hw.lcd.width=1080
            hw.lcd.height=2400

            """
        )
    }

    func testRenameKeepsACustomDisplayNameAndUpdatesTheId() throws {
        let avd = makeAvd()
        writeConfig(
            """
            AvdId=Test
            avd.ini.displayname=My Test Device
            hw.lcd.width=1080

            """,
            in: avd.directory
        )
        let renamedDirectory = avdHome.appendingPathComponent("Renamed.avd", isDirectory: true)

        _ = try AvdFileOperations.rename(avdName: "Test", to: "Renamed", avdHome: avdHome)

        XCTAssertEqual(
            try String(contentsOf: renamedDirectory.appendingPathComponent("config.ini"), encoding: .utf8),
            """
            AvdId=Renamed
            avd.ini.displayname=My Test Device
            hw.lcd.width=1080

            """
        )
    }

    func testRenameRollsBackWhenTheConfigRewriteFails() throws {
        let avd = makeAvd()
        let config = avd.directory.appendingPathComponent("config.ini")
        let originalIni = try String(contentsOf: avd.ini, encoding: .utf8)
        let originalConfig = try String(contentsOf: config, encoding: .utf8)
        // Renaming succeeds, then the display-name rewrite hits EPERM and the
        // whole rename must come back.
        try fileManager.setAttributes([.immutable: true], ofItemAtPath: config.path)
        defer { try? fileManager.setAttributes([.immutable: false], ofItemAtPath: config.path) }

        XCTAssertThrowsError(
            try AvdFileOperations.rename(avdName: "Test", to: "Renamed", avdHome: avdHome)
        )

        XCTAssertTrue(fileManager.fileExists(atPath: avd.ini.path))
        XCTAssertTrue(fileManager.fileExists(atPath: avd.directory.path))
        XCTAssertFalse(fileManager.fileExists(atPath: avdHome.appendingPathComponent("Renamed.ini").path))
        XCTAssertFalse(fileManager.fileExists(atPath: avdHome.appendingPathComponent("Renamed.avd").path))
        XCTAssertEqual(try String(contentsOf: avd.ini, encoding: .utf8), originalIni)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), originalConfig)
    }

    func testRenameReportsPartialStateWhenRollbackFails() throws {
        let avd = makeAvd()
        // The forward directory move fails on the immutable directory; the
        // injected move then fails the rollback of the ini as a second fault.
        try fileManager.setAttributes([.immutable: true], ofItemAtPath: avd.directory.path)
        defer { try? fileManager.setAttributes([.immutable: false], ofItemAtPath: avd.directory.path) }
        var moveCount = 0

        XCTAssertThrowsError(
            try AvdFileOperations.rename(
                avdName: "Test",
                to: "Renamed",
                avdHome: avdHome
            ) { from, to in
                moveCount += 1
                if moveCount == 3 { throw InjectedRollbackFailure() }
                try self.fileManager.moveItem(at: from, to: to)
            }
        ) { error in
            guard let operationError = error as? AvdFileOperationError,
                  case .renameFailed(let name, _, let rollbackFailures) = operationError
            else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(name, "Test")
            XCTAssertFalse(rollbackFailures.isEmpty)
            let message = "\(error)"
            XCTAssertTrue(message.contains("rollback could not restore"), message)
            XCTAssertTrue(message.contains("Renamed.ini"), message)
        }

        // The partial state is real: the ini could not move back, so the
        // best-effort original ini and the stray new-named ini both exist.
        XCTAssertTrue(fileManager.fileExists(atPath: avdHome.appendingPathComponent("Renamed.ini").path))
        XCTAssertTrue(fileManager.fileExists(atPath: avd.ini.path))
        XCTAssertTrue(fileManager.fileExists(atPath: avd.directory.path))
    }

    func testRenameThrowsWhenConfigIsUnreadableAndTouchesNothing() throws {
        let avd = makeAvd()
        let originalIni = try String(contentsOf: avd.ini, encoding: .utf8)
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(
            to: avd.directory.appendingPathComponent("config.ini")
        )

        XCTAssertThrowsError(
            try AvdFileOperations.rename(avdName: "Test", to: "Renamed", avdHome: avdHome)
        ) { error in
            guard case AvdFileOperationError.configUnreadable("Test") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertTrue(fileManager.fileExists(atPath: avd.ini.path))
        XCTAssertTrue(fileManager.fileExists(atPath: avd.directory.path))
        XCTAssertFalse(fileManager.fileExists(atPath: avdHome.appendingPathComponent("Renamed.avd").path))
        XCTAssertEqual(try String(contentsOf: avd.ini, encoding: .utf8), originalIni)
    }

    func testRenameAcceptsAMissingConfigFile() throws {
        let avd = makeAvd()
        try fileManager.removeItem(at: avd.directory.appendingPathComponent("config.ini"))

        let renamed = try AvdFileOperations.rename(avdName: "Test", to: "Renamed", avdHome: avdHome)

        XCTAssertEqual(renamed, "Renamed")
        XCTAssertTrue(fileManager.fileExists(atPath: avdHome.appendingPathComponent("Renamed.ini").path))
        XCTAssertFalse(
            fileManager.fileExists(
                atPath: avdHome.appendingPathComponent("Renamed.avd/config.ini").path
            )
        )
    }

    // MARK: - wipeData

    func testWipeDataThrowsWhenTheDirectoryCannotBeListed() throws {
        let avd = makeAvd()
        // Execute-only keeps `fileExists` working while listing needs read.
        try fileManager.setAttributes([.posixPermissions: 0o111], ofItemAtPath: avd.directory.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: avd.directory.path)
        }

        XCTAssertThrowsError(try AvdFileOperations.wipeData(avdName: "Test", avdHome: avdHome)) { error in
            guard case AvdFileOperationError.directoryUnreadable("Test") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(
            fileManager.fileExists(atPath: avd.directory.appendingPathComponent("userdata-qemu.img").path)
        )
    }

    func testWipeDataRemovesUserdataAndSnapshotsButKeepsConfig() throws {
        let avd = makeAvd()

        let removed = try AvdFileOperations.wipeData(avdName: "Test", avdHome: avdHome)

        XCTAssertEqual(
            Set(removed.map(\.lastPathComponent)),
            ["userdata-qemu.img", "userdata.img", "userdata-qemu.img.qcow2", "snapshots", "snapshot"]
        )
        for file in ["userdata-qemu.img", "userdata.img", "userdata-qemu.img.qcow2", "snapshots", "snapshot"] {
            XCTAssertFalse(
                fileManager.fileExists(atPath: avd.directory.appendingPathComponent(file).path),
                "\(file) should be gone"
            )
        }
        XCTAssertTrue(fileManager.fileExists(atPath: avd.directory.appendingPathComponent("config.ini").path))
        XCTAssertTrue(fileManager.fileExists(atPath: avd.directory.appendingPathComponent("cache.img").path))
        XCTAssertEqual(
            try String(contentsOf: avd.directory.appendingPathComponent("config.ini"), encoding: .utf8),
            configText(name: "Test")
        )
    }

    func testWipeDataReturnsEmptyWhenThereIsNothingToWipe() throws {
        let directory = avdHome.appendingPathComponent("Clean.avd", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? "AvdId=Clean\n".write(
            to: directory.appendingPathComponent("config.ini"),
            atomically: true,
            encoding: .utf8
        )

        let removed = try AvdFileOperations.wipeData(avdName: "Clean", avdHome: avdHome)

        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(fileManager.fileExists(atPath: directory.appendingPathComponent("config.ini").path))
    }

    func testWipeDataThrowsForUnknownAvd() {
        XCTAssertThrowsError(try AvdFileOperations.wipeData(avdName: "Ghost", avdHome: avdHome)) { error in
            guard case AvdFileOperationError.avdNotFound("Ghost") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    // MARK: - isRunning

    func testIsRunningMatchesByAvdNameOnly() {
        let running = [
            RunningEmulator(avd: "Pixel", processID: 1, grpcPort: nil),
            RunningEmulator(avd: "atd34", processID: 2, grpcPort: 8554),
        ]

        XCTAssertTrue(AvdFileOperations.isRunning(avdName: "atd34", runningEmulators: running))
        XCTAssertTrue(AvdFileOperations.isRunning(avdName: "Pixel", runningEmulators: running))
        XCTAssertFalse(AvdFileOperations.isRunning(avdName: "atd3", runningEmulators: running))
        XCTAssertFalse(AvdFileOperations.isRunning(avdName: "pixel", runningEmulators: running))
        XCTAssertFalse(AvdFileOperations.isRunning(avdName: "atd34", runningEmulators: []))
    }

    // MARK: - runState

    func testRunStateIsRunningOnAnExactNameMatch() async {
        let state = await AvdFileOperations.runState(avdName: "atd34") {
            [RunningEmulator(avd: "atd34", processID: 2, grpcPort: 8554)]
        }
        XCTAssertEqual(state, .running)
    }

    func testRunStateIsStoppedWhenTheQuerySucceedsWithoutAMatch() async {
        let state = await AvdFileOperations.runState(avdName: "atd34") {
            [RunningEmulator(avd: "Pixel", processID: 1, grpcPort: nil)]
        }
        XCTAssertEqual(state, .stopped)

        let empty = await AvdFileOperations.runState(avdName: "atd34") { [] }
        XCTAssertEqual(empty, .stopped)
    }

    func testRunStateIsUnknownWhenTheQueryFails() async {
        let state = await AvdFileOperations.runState(avdName: "atd34") {
            throw InjectedRollbackFailure()
        }
        XCTAssertEqual(state, .unknown)
    }

    // MARK: - home

    func testAvdHomeURLDefaultsToTheAndroidAvdDirectory() {
        XCTAssertEqual(AvdConfig.homeURL(avdHome: avdHome), avdHome)
        XCTAssertEqual(
            AvdConfig.defaultHomeURL(environment: [:], userHome: root).path,
            root.appendingPathComponent(".android/avd").path
        )
    }

    /// The emulator (and so the AVD list) honours `ANDROID_AVD_HOME` and the
    /// user-home variables; the file operations must act on the same AVDs,
    /// not on a same-named one in `~/.android/avd`.
    func testDefaultAvdHomeFollowsTheEmulatorsEnvironmentResolution() throws {
        let userHome = root.appendingPathComponent("user", isDirectory: true)
        let custom = root.appendingPathComponent("external/avd", isDirectory: true)
        let userAndroid = root.appendingPathComponent("prefs", isDirectory: true)
        let sdkHome = root.appendingPathComponent("sdkhome", isDirectory: true)
        for directory in [
            custom,
            userAndroid.appendingPathComponent("avd"),
            sdkHome.appendingPathComponent(".android/avd"),
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        XCTAssertEqual(
            AvdConfig.defaultHomeURL(
                environment: ["ANDROID_AVD_HOME": custom.path, "ANDROID_USER_HOME": userAndroid.path],
                userHome: userHome
            ).path,
            custom.path
        )
        // A missing ANDROID_AVD_HOME is skipped, as the emulator skips it.
        XCTAssertEqual(
            AvdConfig.defaultHomeURL(
                environment: [
                    "ANDROID_AVD_HOME": root.appendingPathComponent("missing").path,
                    "ANDROID_USER_HOME": userAndroid.path,
                ],
                userHome: userHome
            ).path,
            userAndroid.appendingPathComponent("avd").path
        )
        XCTAssertEqual(
            AvdConfig.defaultHomeURL(environment: ["ANDROID_SDK_HOME": sdkHome.path], userHome: userHome).path,
            sdkHome.appendingPathComponent(".android/avd").path
        )
    }

    // MARK: - custom content directory (`avdmanager create avd -p`)

    /// An AVD whose ini points `path=` outside the AVD home.
    @discardableResult
    private func makeExternalAvd(named name: String = "Test") throws -> (ini: URL, directory: URL) {
        let directory = root.appendingPathComponent("volume/\(name)-content", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try configText(name: name).write(
            to: directory.appendingPathComponent("config.ini"),
            atomically: true,
            encoding: .utf8
        )
        try Data("data".utf8).write(to: directory.appendingPathComponent("userdata-qemu.img"))
        let ini = avdHome.appendingPathComponent("\(name).ini")
        try """
        avd.ini.encoding=UTF-8
        path=\(directory.path)
        target=android-35

        """.write(to: ini, atomically: true, encoding: .utf8)
        return (ini, directory)
    }

    func testConfigReadsFollowTheIniPath() throws {
        let avd = try makeExternalAvd()

        XCTAssertEqual(
            AvdConfig.contentDirectory(avdName: "Test", avdHome: avdHome).standardizedFileURL,
            avd.directory.standardizedFileURL
        )
        XCTAssertEqual(AvdConfig.lcdSize(avdName: "Test", avdHome: avdHome), CGSize(width: 1080, height: 2400))
    }

    /// Removing such an AVD used to trash only the ini and report success,
    /// orphaning the (multi-GB) content directory.
    func testDeleteTrashesTheContentDirectoryTheIniPointsAt() throws {
        let avd = try makeExternalAvd()
        var trashed: [URL] = []

        try AvdFileOperations.delete(avdName: "Test", avdHome: avdHome) { trashed.append($0) }

        XCTAssertEqual(
            Set(trashed.map(\.standardizedFileURL)),
            Set([avd.ini.standardizedFileURL, avd.directory.standardizedFileURL])
        )
    }

    /// A malformed pointer must never name an unrelated directory: `path=`
    /// is only trusted when it holds an AVD `config.ini`.
    func testDeleteNeverTrashesAPathWithoutAnAvdConfig() throws {
        let ini = avdHome.appendingPathComponent("Broken.ini")
        try "path=\(root.path)\n".write(to: ini, atomically: true, encoding: .utf8)
        var trashed: [URL] = []

        try AvdFileOperations.delete(avdName: "Broken", avdHome: avdHome) { trashed.append($0) }

        XCTAssertEqual(trashed, [ini])
    }

    func testRenameKeepsACustomContentDirectoryInPlace() throws {
        let avd = try makeExternalAvd()
        let originalIni = try String(contentsOf: avd.ini, encoding: .utf8)

        try AvdFileOperations.rename(avdName: "Test", to: "Renamed", avdHome: avdHome)

        let newIni = avdHome.appendingPathComponent("Renamed.ini")
        XCTAssertFalse(fileManager.fileExists(atPath: avd.ini.path))
        XCTAssertEqual(try String(contentsOf: newIni, encoding: .utf8), originalIni)
        XCTAssertTrue(fileManager.fileExists(atPath: avd.directory.appendingPathComponent("userdata-qemu.img").path))
        XCTAssertFalse(fileManager.fileExists(atPath: avdHome.appendingPathComponent("Renamed.avd").path))
        XCTAssertEqual(AvdConfig.values(avdName: "Renamed", avdHome: avdHome)["AvdId"], "Renamed")
    }

    func testWipeDataClearsTheContentDirectoryTheIniPointsAt() throws {
        let avd = try makeExternalAvd()

        let removed = try AvdFileOperations.wipeData(avdName: "Test", avdHome: avdHome)

        XCTAssertEqual(removed.map(\.lastPathComponent), ["userdata-qemu.img"])
        XCTAssertFalse(fileManager.fileExists(atPath: avd.directory.appendingPathComponent("userdata-qemu.img").path))
        XCTAssertTrue(fileManager.fileExists(atPath: avd.directory.appendingPathComponent("config.ini").path))
    }

    // MARK: - case-only and CRLF renames

    /// `pixel_9` → `Pixel_9`: on the default case-insensitive APFS the
    /// destination "exists" because it is the source itself, which used to
    /// be refused as "already exists".
    func testCaseOnlyRenameIsNotADestinationConflict() throws {
        makeAvd(named: "pixel_9")

        let renamed = try AvdFileOperations.rename(avdName: "pixel_9", to: "Pixel_9", avdHome: avdHome)

        XCTAssertEqual(renamed, "Pixel_9")
        let names = try fileManager.contentsOfDirectory(atPath: avdHome.path).sorted()
        XCTAssertEqual(names, ["Pixel_9.avd", "Pixel_9.ini"])
        let ini = try String(contentsOf: avdHome.appendingPathComponent("Pixel_9.ini"), encoding: .utf8)
        XCTAssertTrue(ini.contains("path.rel=avd/Pixel_9.avd\n"), ini)
        XCTAssertEqual(
            AvdConfig.values(avdName: "Pixel_9", avdHome: avdHome)["AvdId"],
            "Pixel_9"
        )
    }

    /// `"\r\n"` is one Swift Character, so the old `split(separator: "\n")`
    /// saw a CRLF ini as one line: `path=` was never rewritten and the
    /// renamed AVD pointed at its old directory.
    func testRenameRewritesACRLFIniAndKeepsItsLineEndings() throws {
        let avd = makeAvd()
        try "avd.ini.encoding=UTF-8\r\npath=\(avd.directory.path)\r\npath.rel=avd/Test.avd\r\ntarget=android-35\r\n"
            .write(to: avd.ini, atomically: true, encoding: .utf8)
        writeConfig("AvdId=Test\r\navd.ini.displayname=Test\r\nhw.lcd.width=1080\r\n", in: avd.directory)

        try AvdFileOperations.rename(avdName: "Test", to: "Renamed", avdHome: avdHome)

        let newDirectory = avdHome.appendingPathComponent("Renamed.avd", isDirectory: true)
        XCTAssertEqual(
            try String(contentsOf: avdHome.appendingPathComponent("Renamed.ini"), encoding: .utf8),
            "avd.ini.encoding=UTF-8\r\npath=\(newDirectory.path)\r\npath.rel=avd/Renamed.avd\r\ntarget=android-35\r\n"
        )
        XCTAssertEqual(
            try String(contentsOf: newDirectory.appendingPathComponent("config.ini"), encoding: .utf8),
            "AvdId=Renamed\r\navd.ini.displayname=Renamed\r\nhw.lcd.width=1080\r\n"
        )
    }
}
