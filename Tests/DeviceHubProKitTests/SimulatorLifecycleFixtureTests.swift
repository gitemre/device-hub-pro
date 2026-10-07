import CoreGraphics
import XCTest
@testable import DeviceHubProKit

/// The simulator tier's lifecycle captures: clone, boot and bootstatus, the
/// launchd job list the ready signal reads, and the default device set.
///
/// Provenance (captured 2026-09-26, Xcode 27.0 27A266a, CoreSimulator
/// 1171.7, the real simctl binary, never the `xcrun` wrapper):
/// - Lifecycle files (`simctl-clone.*`, `simctl-clone-booted.*`,
///   `simctl-boot-booted.*`, `simctl-bootstatus.after-boot.*`,
///   `simctl-bootstatus.already-booted.*`, `simctl-spawn-launchctl-list.*`,
///   `simctl-list-j-devices.cloned.json`,
///   `simctl-list-j-devices.booted-after-rename.json`): a throwaway
///   `DeviceHubPro-UI-core`, an iPhone 17 Pro on iOS 27.0 (24A434), UDID
///   425BD068-3D87-4F27-BE58-EB56A58B2C3A, in a private set
///   (`simctl --set <scratch>/simtier/set`), created, cloned (clone
///   B225F7EA-C520-4579-BB1C-5A6E2BB622EC, deleted at once), renamed to
///   `DeviceHubPro-UI-core-renamed`, booted for the first time, followed, shut
///   down, erased and deleted. `bootstatus` ran without `-b` right after
///   `boot` returned; the `.booting` job list is the first `spawn launchctl
///   list` after `boot` returned (0.03 s later), the `.ready` one the list
///   after `bootstatus` reported Finished.
/// - tvOS files (`simctl-spawn-launchctl-list.tvos-ready.stdout.txt`,
///   `simctl-io-screenshot.tvos-boot-screen.png`,
///   `simctl-io-screenshot.tvos-dark.png`): a throwaway `DeviceHubPro-UI-tvos`,
///   an Apple TV 4K (3rd generation) on tvOS 27.0 (24J360), UDID
///   81869B75-F68C-4FF3-ABDB-63B611D62541, in a private set, created,
///   booted for the first time and deleted with its log folder. The job
///   list is the `spawn launchctl list` right after `bootstatus` reported
///   Finished (6 s into the boot); the screenshots are the first two of a
///   once-a-second series taken from then on: the boot screen, then 3.6 s of
///   an all-black screen (three identical captures) before the home screen
///   (the fifth capture on; not kept, 5.4 MB).
/// - `simctl-spawn-notifyutil-g-dtuhidd-active.before-input.stdout.txt` and
///   `.after-input.stdout.txt`: written by `SimulatorInputFlagLiveTests`
///   (`DHP_IOS_CAPTURE_DIR`) on a throwaway iPhone 17 Pro on iOS 27.0
///   (24A434) in a private set, UDID 5844CDE2-EE9C-4E7B-AE61-0DC4D170A9DD,
///   deleted with its log folder: the flag read on the home screen, then
///   again 3 s after the bridge pressed the side button (the first input).
///   PRIVATE-API 24A434: the 1 comes from the private dtuhidd connection;
///   the live test is its canary.
/// - `simctl-list-j-devices.default-set.json` and `device_set.plist.default-set`:
///   a read of the default set (`simctl list -j devices` without
///   `--set`, and a byte copy of `~/Library/Developer/CoreSimulator/Devices/
///   device_set.plist`), nothing booted, nothing changed.
///
/// Redaction as in `SimctlFixtureTests`: the macOS user name in paths is the
/// same-length `aqauser001`, and the private set's scratch folder segment
/// the same-length `aqa-tmp-01/aqa-project-placeholder-01/aqa-session-placeholder-000000000000`;
/// `device_set.plist.default-set` holds no path and is byte-identical.
/// Exit codes are noted beside each stderr fixture.
final class SimulatorLifecycleFixtureTests: XCTestCase {
    static let udid = "425BD068-3D87-4F27-BE58-EB56A58B2C3A"
    static let cloneUDID = "B225F7EA-C520-4579-BB1C-5A6E2BB622EC"

    private static func data(_ name: String) throws -> Data {
        try SimctlFixtureTests.data("simctl-core", name)
    }

    private static func text(_ name: String) throws -> String {
        try SimctlFixtureTests.text("simctl-core", name)
    }

    // MARK: - clone

    /// `simctl clone <udid> DeviceHubPro-UI-core-clone` on the shut-down device
    /// prints the clone's UDID (exit 0); the listing then holds both, the
    /// clone never used.
    func testACloneAnswersWithItsUDID() throws {
        XCTAssertEqual(SimctlParsing.createdUDID(from: try Self.text("simctl-clone.stdout.txt")), Self.cloneUDID)

        let devices = try SimctlParsing.devices(fromListJSON: try Self.data("simctl-list-j-devices.cloned.json"))
        XCTAssertEqual(devices.map(\.udid), [Self.udid, Self.cloneUDID])
        XCTAssertEqual(devices.map(\.name), ["DeviceHubPro-UI-core", "DeviceHubPro-UI-core-clone"])
        XCTAssertEqual(devices.map(\.state), [.shutdown, .shutdown])
        XCTAssertEqual(devices.map(\.lastUsedAt), [nil, nil])
    }

    /// Clone and boot of a booted device are refused as SimError 405 (both
    /// exit 149).
    func testCloneAndBootOfABootedDeviceAreInvalidState() throws {
        let clone = SimctlErrors.failure(
            arguments: ["clone", Self.udid, "DeviceHubPro-UI-core-clone2"],
            exitCode: 149,
            standardError: try Self.text("simctl-clone-booted.stderr.txt")
        )
        XCTAssertEqual(clone.kind, .invalidState)
        XCTAssertEqual(clone.message, "Unable to clone device in current state: Booted")

        let boot = SimctlErrors.failure(
            arguments: ["boot", Self.udid],
            exitCode: 149,
            standardError: try Self.text("simctl-boot-booted.stderr.txt")
        )
        XCTAssertEqual(boot.kind, .invalidState)
        XCTAssertEqual(boot.message, "Unable to boot device in current state: Booted")
    }

    // MARK: - bootstatus

    /// A first boot followed from the moment `boot` returned: BackBoard,
    /// then data migration for 17 s, then Finished, 19 updates in all.
    func testAFirstBootsPhases() throws {
        let updates = SimctlParsing.bootStatuses(from: try Self.text("simctl-bootstatus.after-boot.stdout.txt"))
        XCTAssertEqual(updates.count, 19)
        XCTAssertEqual(updates.first?.phase, .waitingOnBackBoard)
        XCTAssertEqual(updates.first?.status, 1)
        XCTAssertEqual(updates[1].phase, .waitingOnDataMigration)
        XCTAssertEqual(updates[2].reason, "Gathering plugins")
        XCTAssertEqual(updates.last?.isFinished, true)
        XCTAssertEqual(updates.last?.elapsedSeconds, 22)
        XCTAssertEqual(updates.filter { !$0.isTerminal }.count, 18)

        let phases = updates.compactMap(\.phase).map(DeviceBootPhase.init)
        XCTAssertEqual(phases.first, .waitingOnBackBoard)
        XCTAssertEqual(phases[1], .migratingData)
        XCTAssertEqual(phases.last, .waitingOnHomeScreen, "Finished leaves the home screen to wait for")
    }

    /// `bootstatus` on a device whose boot had finished prints one notice
    /// and no update (exit 0): the boot counts as finished.
    func testABootThatHadFinishedReportsNoUpdate() throws {
        let text = try Self.text("simctl-bootstatus.already-booted.stdout.txt")
        XCTAssertTrue(text.contains("Device already booted, nothing to do."))
        let updates = SimctlParsing.bootStatuses(from: text)
        XCTAssertEqual(updates, [])
        XCTAssertTrue(SimulatorReadiness.bootFinished(lastUpdate: updates.last))
    }

    func testEveryBootstatusPhaseMapsToABootPhase() {
        XCTAssertEqual(DeviceBootPhase(.waitingOnBackBoard), .waitingOnBackBoard)
        XCTAssertEqual(DeviceBootPhase(.waitingOnDataMigration), .migratingData)
        XCTAssertEqual(DeviceBootPhase(.waitingOnSystemApp), .waitingOnSystemApp)
        XCTAssertEqual(DeviceBootPhase(.finished), .waitingOnHomeScreen)
        XCTAssertEqual(DeviceBootPhase(.other("Waiting on Something New")), .other("Waiting on Something New"))
    }

    // MARK: - launchctl list

    /// The job list's header is skipped, `-` is a job that is not running,
    /// and SpringBoard's pid is read from its label.
    func testTheJobListNamesSpringBoard() throws {
        let ready = SimctlParsing.launchdJobs(
            fromLaunchctlList: try Self.text("simctl-spawn-launchctl-list.ready.stdout.txt")
        )
        XCTAssertEqual(ready.count, 380)
        XCTAssertEqual(ready.filter { $0.pid == nil }.count, 223)
        XCTAssertEqual(ready.first, SimulatorLaunchdJob(pid: nil, status: 0, label: "com.apple.progressd"))
        XCTAssertFalse(ready.contains { $0.label == "Label" })
        XCTAssertEqual(SimulatorReadiness.homeScreenPID(in: ready), 25803)

        let booting = SimctlParsing.launchdJobs(
            fromLaunchctlList: try Self.text("simctl-spawn-launchctl-list.booting.stdout.txt")
        )
        XCTAssertEqual(booting.count, 351)
        XCTAssertEqual(SimulatorReadiness.homeScreenPID(in: booting), 25803)
        XCTAssertNil(SimulatorReadiness.homeScreenPID(in: []))
    }

    /// tvOS has no SpringBoard job: its home screen is PineBoard, which ran
    /// once the boot finished. Each platform's home screen label is its own;
    /// a platform no list was captured on has none.
    func testTheTVJobListNamesPineBoard() throws {
        let jobs = SimctlParsing.launchdJobs(
            fromLaunchctlList: try Self.text("simctl-spawn-launchctl-list.tvos-ready.stdout.txt")
        )
        XCTAssertEqual(jobs.count, 229)
        XCTAssertEqual(jobs.filter { $0.pid == nil }.count, 143)
        XCTAssertNil(SimulatorReadiness.homeScreenPID(in: jobs), "no SpringBoard on tvOS")
        XCTAssertEqual(SimulatorReadiness.homeScreenPID(in: jobs, label: SimulatorReadiness.tvHomeScreenLabel), 63359)

        XCTAssertEqual(SimulatorReadiness.homeScreenLabel(platform: "iOS"), "com.apple.SpringBoard")
        XCTAssertEqual(SimulatorReadiness.homeScreenLabel(platform: "tvOS"), "com.apple.PineBoard")
        XCTAssertNil(SimulatorReadiness.homeScreenLabel(platform: "watchOS"))
        XCTAssertNil(SimulatorReadiness.homeScreenLabel(platform: "xrOS"))
        XCTAssertNil(SimulatorReadiness.homeScreenLabel(platform: nil))

        let iOS = SimctlParsing.launchdJobs(
            fromLaunchctlList: try Self.text("simctl-spawn-launchctl-list.ready.stdout.txt")
        )
        XCTAssertNil(SimulatorReadiness.homeScreenPID(in: iOS, label: SimulatorReadiness.tvHomeScreenLabel))
    }

    /// `spawn launchctl list` on a shut-down device: SimError 405 (exit 149),
    /// "not booted", with an underlying SimLaunchHostService error.
    func testTheJobListOfAShutDownDeviceIsInvalidState() throws {
        let failure = SimctlErrors.failure(
            arguments: ["spawn", Self.udid, "launchctl", "list"],
            exitCode: 149,
            standardError: try Self.text("simctl-spawn-launchctl-list.shutdown.stderr.txt")
        )
        XCTAssertEqual(failure.kind, .invalidState)
        XCTAssertEqual(failure.message, "Process spawn via launchd failed because device is not booted.")
        XCTAssertEqual(failure.underlying.map(\.domain), ["com.apple.SimLaunchHostService.RequestError"])
    }

    // MARK: - notifyutil

    /// `spawn <udid> notifyutil -g com.apple.coredevice.dtuhidd.active`
    /// prints the name and the state: 0 before anything connected dtuhidd in
    /// the boot, 1 once the first input did. Another name, or
    /// no number, reads as nothing.
    func testTheDtuhiddFlagIsReadBeforeAndAfterTheFirstInput() throws {
        let name = SimulatorHardwareActions.dtuhiddActiveNotification
        let before = try Self.text("simctl-spawn-notifyutil-g-dtuhidd-active.before-input.stdout.txt")
        let after = try Self.text("simctl-spawn-notifyutil-g-dtuhidd-active.after-input.stdout.txt")
        XCTAssertEqual(before, "com.apple.coredevice.dtuhidd.active 0\n")
        XCTAssertEqual(SimctlParsing.notifyState(fromNotifyutilOutput: before, name: name), 0)
        XCTAssertEqual(SimctlParsing.notifyState(fromNotifyutilOutput: after, name: name), 1)
        XCTAssertNil(SimctlParsing.notifyState(fromNotifyutilOutput: before, name: "com.apple.other"))
        XCTAssertNil(SimctlParsing.notifyState(fromNotifyutilOutput: "", name: name))
    }

    // MARK: - Ready

    /// SpringBoard ran 0.03 s after `boot` returned, while bootstatus still
    /// waited on BackBoard: not ready. The boot finished 21.7 s later, and a
    /// finished boot's notice counts as finished too; ready needs the home
    /// screen on top.
    func testReadyNeedsTheFinishedBootSpringBoardAndTheHomeScreen() throws {
        let updates = SimctlParsing.bootStatuses(from: try Self.text("simctl-bootstatus.after-boot.stdout.txt"))
        let booting = SimulatorReadiness.homeScreenPID(in: SimctlParsing.launchdJobs(
            fromLaunchctlList: try Self.text("simctl-spawn-launchctl-list.booting.stdout.txt")
        ))
        let ready = SimulatorReadiness.homeScreenPID(in: SimctlParsing.launchdJobs(
            fromLaunchctlList: try Self.text("simctl-spawn-launchctl-list.ready.stdout.txt")
        ))

        XCTAssertFalse(SimulatorReadiness.isReady(
            bootFinished: SimulatorReadiness.bootFinished(lastUpdate: updates.first),
            homeScreenPID: booting,
            showsHomeScreen: true
        ))
        XCTAssertTrue(SimulatorReadiness.isReady(
            bootFinished: SimulatorReadiness.bootFinished(lastUpdate: updates.last),
            homeScreenPID: ready,
            showsHomeScreen: true
        ))
        XCTAssertTrue(SimulatorReadiness.isReady(
            bootFinished: SimulatorReadiness.bootFinished(lastUpdate: nil),
            homeScreenPID: ready,
            showsHomeScreen: true
        ))
        XCTAssertFalse(SimulatorReadiness.isReady(
            bootFinished: SimulatorReadiness.bootFinished(lastUpdate: updates.last),
            homeScreenPID: ready,
            showsHomeScreen: false
        ), "Finished and SpringBoard while the boot screen shows")
        XCTAssertFalse(SimulatorReadiness.isReady(bootFinished: true, homeScreenPID: nil, showsHomeScreen: true))
    }

    /// The screen, from two `simctl io <udid> screenshot --type=png` captures
    /// of a later throwaway device (`DeviceHubPro-UI-core`, UDID
    /// 654CE413-6C69-4C85-8C81-CF59AE3DAF71, private set, iPhone 17 Pro, iOS
    /// 27.0, 2026-09-26, both 1206x2622 and byte-exact): the boot screen,
    /// taken as a warm boot reported Finished with SpringBoard running, and
    /// the home screen with its icons still loading, taken as a first boot
    /// did.
    func testTheHomeScreenIsToldFromTheBootScreen() throws {
        let boot = SimctlFixtureTests.url("simctl-core", "simctl-io-screenshot.boot-screen.png")
        let home = SimctlFixtureTests.url("simctl-core", "simctl-io-screenshot.home-screen-loading.png")
        XCTAssertEqual(SimulatorReadiness.showsHomeScreen(imageAt: boot), false)
        XCTAssertEqual(SimulatorReadiness.showsHomeScreen(imageAt: home), true)
        XCTAssertNil(SimulatorReadiness.showsHomeScreen(imageAt: SimctlFixtureTests.url("simctl-core", "simctl-clone.stdout.txt")))
    }

    /// What each capture shows: the home screen, the boot screen (the logo
    /// alone, also on a landscape 3840x2160 tvOS screen), or nothing lit —
    /// the black tvOS showed between the two, which a screen that is off
    /// shows too. A file without an image shows nothing known.
    func testTheScreenContentOfEachCapture() throws {
        func content(_ name: String) -> SimulatorReadiness.ScreenContent? {
            SimulatorReadiness.screenContent(imageAt: SimctlFixtureTests.url("simctl-core", name))
        }
        XCTAssertEqual(content("simctl-io-screenshot.home-screen-loading.png"), .homeScreen)
        XCTAssertEqual(content("simctl-io-screenshot.boot-screen.png"), .bootScreen)
        XCTAssertEqual(content("simctl-io-screenshot.tvos-boot-screen.png"), .bootScreen)
        XCTAssertEqual(content("simctl-io-screenshot.tvos-dark.png"), .dark)
        XCTAssertNil(content("simctl-clone.stdout.txt"))
        XCTAssertEqual(
            SimulatorReadiness.showsHomeScreen(imageAt: SimctlFixtureTests.url("simctl-core", "simctl-io-screenshot.tvos-dark.png")),
            false
        )
    }

    /// A black screen (the display before the logo) is no home screen.
    func testABlackScreenIsNoHomeScreen() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 1206,
            height: 2622,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1206, height: 2622))
        XCTAssertFalse(SimulatorReadiness.showsHomeScreen(try XCTUnwrap(context.makeImage())))
        XCTAssertEqual(SimulatorReadiness.screenContent(try XCTUnwrap(context.makeImage())), .dark)
    }

    // MARK: - The default set

    /// The the default set: 28 devices over iOS 26.5 and 27.0 and tvOS
    /// 26.5 and 27.0, 27 of them created by CoreSimulator (one per runtime
    /// and device type); the one a user added (an iPhone 11) is not listed
    /// under `DefaultDevices`. 16 defaults were never booted (no
    /// `lastUsedAt`): Device Hub hides those.
    func testTheDefaultSetsDefaultDevices() throws {
        let defaults = SimctlParsing.defaultDeviceUDIDs(
            fromDeviceSetPlist: try Self.data("device_set.plist.default-set")
        )
        let devices = try SimctlParsing.devices(
            fromListJSON: try Self.data("simctl-list-j-devices.default-set.json")
        )
        XCTAssertEqual(defaults.count, 27)
        XCTAssertEqual(devices.count, 28)
        XCTAssertTrue(defaults.isSubset(of: Set(devices.map(\.udid))))
        let added = devices.filter { !defaults.contains($0.udid) }
        XCTAssertEqual(added.map(\.name), ["iPhone 11"])
        XCTAssertEqual(added.first?.udid, "472F358C-177D-4C25-82CC-5982BC4D3729")
        XCTAssertNotNil(added.first?.lastUsedAt)
        let unused = devices.filter { defaults.contains($0.udid) && $0.lastUsedAt == nil }
        XCTAssertEqual(unused.count, 16)
        XCTAssertEqual(unused.filter { $0.runtimeIdentifier.hasSuffix("iOS-27-0") }.count, 11)
        XCTAssertTrue(devices.allSatisfy { $0.state == .shutdown && $0.isAvailable })
    }

    /// A set without a readable `device_set.plist` has no defaults (a new
    /// private set has no such file: none appeared after `create` in the
    /// capture).
    func testAMissingDeviceSetFileHasNoDefaults() {
        XCTAssertEqual(SimctlParsing.defaultDeviceUDIDs(fromDeviceSetPlist: Data()), [])
        XCTAssertEqual(SimctlParsing.defaultDeviceUDIDs(fromDeviceSetPlist: Data("not a plist".utf8)), [])
    }

    // MARK: - SimctlClient on these captures

    /// `clone` passes the name as free text (it may spell a selector) and
    /// returns the printed UDID; `launchdJobs` spawns `launchctl list` on
    /// the UDID; a refused clone throws its failure.
    func testCloneAndJobListArgv() async throws {
        let url = { (name: String) in SimctlFixtureTests.url("simctl-core", name) }
        let fake = try FakeTool(name: "simctl", rules: [
            .init("clone \(Self.udid) all", stdoutFile: nil, stderrFile: url("simctl-clone-booted.stderr.txt"), exitCode: 149),
            .init("clone", stdoutFile: url("simctl-clone.stdout.txt")),
            .init("launchctl list", stdoutFile: url("simctl-spawn-launchctl-list.ready.stdout.txt")),
        ])
        let client = SimctlClient(simctlURL: fake.executableURL)

        let clone = try await client.clone(udid: Self.udid, name: "DeviceHubPro-UI-core-clone")
        XCTAssertEqual(clone, Self.cloneUDID)
        do {
            _ = try await client.clone(udid: Self.udid, name: "all")
            XCTFail("a booted device cannot be cloned")
        } catch let failure as SimctlFailure {
            XCTAssertEqual(failure.kind, .invalidState)
        }
        let jobs = try await client.launchdJobs(udid: Self.udid)
        XCTAssertEqual(SimulatorReadiness.homeScreenPID(in: jobs), 25803)

        XCTAssertEqual(fake.invocations, [
            ["clone", Self.udid, "DeviceHubPro-UI-core-clone"],
            ["clone", Self.udid, "all"],
            ["spawn", Self.udid, "launchctl", "list"],
        ])
        do {
            _ = try await client.launchdJobs(udid: "booted")
            XCTFail("a selector is no UDID")
        } catch let error as SimctlClientError {
            XCTAssertEqual(error, .invalidUDID("booted"))
        }
        XCTAssertEqual(fake.invocations.count, 3)
    }

    /// `bootStatus` on a boot that had finished returns nil after exit 0.
    func testBootStatusOfAFinishedBootReturnsNoUpdate() async throws {
        let fake = try FakeTool(name: "simctl", rules: [
            .init("bootstatus", stdoutFile: SimctlFixtureTests.url("simctl-core", "simctl-bootstatus.already-booted.stdout.txt")),
        ])
        let client = SimctlClient(simctlURL: fake.executableURL)
        let last = try await client.bootStatus(udid: Self.udid)
        XCTAssertNil(last)
        XCTAssertEqual(fake.invocations, [["bootstatus", Self.udid]])
    }

    func testARuntimeIdentifierSpellsItsPlatformAndVersion() {
        XCTAssertTrue(SimctlParsing.runtimePlatformAndVersion(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
            .map { $0 == ("iOS", "27.0") } ?? false)
        XCTAssertTrue(SimctlParsing.runtimePlatformAndVersion(identifier: "com.apple.CoreSimulator.SimRuntime.tvOS-26-5")
            .map { $0 == ("tvOS", "26.5") } ?? false)
        XCTAssertNil(SimctlParsing.runtimePlatformAndVersion(identifier: "com.apple.CoreSimulator.SimRuntime.iOS"))
        XCTAssertNil(SimctlParsing.runtimePlatformAndVersion(identifier: "iOS-27-0"))
    }
}
