import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// Boot, Shut Down, Restart, Erase, Rename, Delete and Clone on a stub
/// simctl that replays the real captures of `DeviceHubPro-UI-core`
/// (`SimulatorLifecycleFixtureTests`): the calls each operation makes and
/// their order, the ready signal (Finished, then SpringBoard), the
/// operations in flight, who booted what, and the log folder a delete
/// removes. No test reaches a real simulator.
@MainActor
final class SimulatorLifecycleControllerTests: XCTestCase {
    private static let udid = SimulatorFixtures.udid

    /// The stub's usual answers, each a real capture (or an empty exit 0,
    /// which is what boot, shutdown, erase, rename and delete print).
    private static func arms(
        bootstatus: String? = nil,
        launchctl: String? = nil,
        screenshot: String? = nil,
        extra: String = ""
    ) -> String {
        let u = udid
        return """
        \(extra)
          *" boot \(u)")
            exit 0 ;;
          *" bootstatus \(u)")
            \(bootstatus ?? SimulatorFixtures.cat("simctl-bootstatus.after-boot.stdout.txt")) ;;
          *" spawn \(u) launchctl list")
            \(launchctl ?? SimulatorFixtures.cat("simctl-spawn-launchctl-list.ready.stdout.txt")) ;;
          *" io \(u) screenshot --type=png "*)
            \(screenshot ?? SimulatorFixtures.screenshot("simctl-io-screenshot.home-screen-loading.png")) ;;
          *" shutdown \(u)"|*" erase \(u)"|*" delete \(u)")
            exit 0 ;;
          *" rename \(u) "*)
            exit 0 ;;
          *" clone \(u) DeviceHubPro-UI-core-clone")
            \(SimulatorFixtures.cat("simctl-clone.stdout.txt")) ;;
        """
    }

    private struct Harness {
        let controller: SimulatorLifecycleController
        let status: StatusCenter
        let stub: StubTool
        let logs: URL
        let reloads: Counter
        /// Each `becameReady`: "started" for a boot this controller's
        /// `simctl boot` started, "followed" for any other.
        let ready: ReadyLog
    }

    @MainActor
    final class Counter {
        var value = 0
    }

    @MainActor
    final class ReadyLog {
        var calls: [String] = []
    }

    /// A controller on the stub, with `entries` as the listing.
    private func harness(arms: String, entries: [SimulatorEntry]) throws -> Harness {
        let stub = try makeStubTool("simctl", arms: arms)
        let set = try makeTemporaryFolder("set")
        let logs = try makeTemporaryFolder("logs")
        let client = SimctlClient(simctlURL: stub.url, deviceSet: set)
        let status = StatusCenter()
        let controller = SimulatorLifecycleController(status: status)
        let listing = Dictionary(uniqueKeysWithValues: entries.map { ($0.udid, $0) })
        let reloads = Counter()
        let ready = ReadyLog()
        controller.becameReady = { udid, startedHere in
            ready.calls.append(udid == Self.udid ? (startedHere ? "started" : "followed") : "other")
        }
        controller.simctlSource = { client }
        controller.entrySource = { listing[$0] }
        controller.logsDirectorySource = { logs }
        controller.reloadList = { reloads.value += 1 }
        controller.homeScreenPollInterval = .milliseconds(20)
        controller.homeScreenTimeout = .seconds(2)
        addTeardownBlock { @MainActor in controller.stop() }
        return Harness(controller: controller, status: status, stub: stub, logs: logs, reloads: reloads, ready: ready)
    }

    private func shutDownEntry() throws -> SimulatorEntry {
        try SimulatorFixtures.entry("simctl-list-j-devices.cloned.json", udid: Self.udid)
    }

    private func bootedEntry() throws -> SimulatorEntry {
        try SimulatorFixtures.entry("simctl-list-j-devices.booted-after-rename.json", udid: Self.udid)
    }

    private var u: String { Self.udid }

    // MARK: - Boot and ready

    /// A boot is `boot`, then `bootstatus` to Finished, then SpringBoard in
    /// the job list, then the home screen on a screenshot; the simulator is
    /// then ready and Device Hub Pro's.
    func testBootFollowsTheBootToReady() async throws {
        let h = try harness(arms: Self.arms(), entries: [try shutDownEntry()])

        let ready = await h.controller.boot(u)

        XCTAssertTrue(ready)
        XCTAssertEqual(h.stub.calls, [
            "boot \(u)", "bootstatus \(u)", "spawn \(u) launchctl list", "io \(u) screenshot --type=png",
        ])
        XCTAssertEqual(h.controller.readiness[u], .ready)
        XCTAssertTrue(h.controller.isReady(u))
        XCTAssertEqual(h.controller.bootedByDeviceHubPro, [u])
        XCTAssertEqual(h.controller.operations, [:])
        XCTAssertEqual(h.controller.runState(for: try shutDownEntry()), .ready, "ahead of a listing that lags")
        XCTAssertEqual(h.reloads.value, 1)
        XCTAssertNil(h.status.errorMessage)
        XCTAssertEqual(h.ready.calls, ["started"], "the Controls may set the kept location again")
    }

    /// SpringBoard runs from a boot's first seconds (the `.booting` job list
    /// has its pid), but ready waits for Finished: while `bootstatus` is in
    /// data migration the simulator reads booting, in that phase, and the job
    /// list is not even asked.
    func testReadyWaitsForFinishedWhileSpringBoardAlreadyRuns() async throws {
        let after = SimulatorFixtures.url("simctl-bootstatus.after-boot.stdout.txt").path
        let stubFolder = try makeTemporaryFolder("gate")
        let gate = stubFolder.appendingPathComponent("finish").path
        let bootstatus = """
        head -n 9 \(SimulatorFixtures.quoted(after))
                    while [ ! -f \(SimulatorFixtures.quoted(gate)) ]; do sleep 0.05; done
                    tail -n +10 \(SimulatorFixtures.quoted(after))
        """
        let h = try harness(
            arms: Self.arms(
                bootstatus: bootstatus,
                launchctl: SimulatorFixtures.cat("simctl-spawn-launchctl-list.booting.stdout.txt")
            ),
            entries: [try shutDownEntry()]
        )

        let boot = Task { await h.controller.boot(u) }
        await waitUntil(timeout: 10, "the migration phase") {
            h.controller.readiness[self.u] == .waiting(.migratingData)
        }
        XCTAssertEqual(h.controller.runState(for: try bootedEntry()), .booting(.migratingData))
        XCTAssertEqual(h.controller.operations[u], .starting)
        XCTAssertFalse(h.controller.isReady(u))
        XCTAssertFalse(h.stub.calls.contains("spawn \(u) launchctl list"))
        XCTAssertFalse(h.stub.calls.contains("io \(u) screenshot --type=png"))

        FileManager.default.createFile(atPath: gate, contents: Data())
        let ready = await boot.value

        XCTAssertTrue(ready)
        XCTAssertEqual(h.controller.readiness[u], .ready)
        XCTAssertEqual(Array(h.stub.calls.suffix(2)), ["spawn \(u) launchctl list", "io \(u) screenshot --type=png"])
    }

    /// Finished and SpringBoard while the boot screen still shows (as a
    /// warm boot measured): not ready until a screenshot shows the home
    /// screen. SpringBoard is asked for once; the screen until it changes.
    func testReadyWaitsForTheHomeScreenOnTheScreen() async throws {
        let stubFolder = try makeTemporaryFolder("state")
        let marker = stubFolder.appendingPathComponent("shown").path
        let screenshot = """
        if [ -f \(SimulatorFixtures.quoted(marker)) ]; then \(SimulatorFixtures.screenshot("simctl-io-screenshot.home-screen-loading.png")); else touch \(SimulatorFixtures.quoted(marker)); \(SimulatorFixtures.screenshot("simctl-io-screenshot.boot-screen.png")); fi
        """
        let h = try harness(arms: Self.arms(screenshot: screenshot), entries: [try shutDownEntry()])

        let ready = await h.controller.boot(u)

        XCTAssertTrue(ready)
        XCTAssertEqual(h.stub.calls, [
            "boot \(u)", "bootstatus \(u)", "spawn \(u) launchctl list",
            "io \(u) screenshot --type=png", "io \(u) screenshot --type=png",
        ])
        XCTAssertEqual(h.controller.readiness[u], .ready)
    }

    /// A screen that keeps showing the boot screen: not responding once the
    /// bound passes.
    func testABootScreenThatStaysReadsAsNotResponding() async throws {
        let h = try harness(
            arms: Self.arms(screenshot: SimulatorFixtures.screenshot("simctl-io-screenshot.boot-screen.png")),
            entries: [try shutDownEntry()]
        )
        h.controller.homeScreenTimeout = .milliseconds(500)

        let ready = await h.controller.boot(u)

        XCTAssertFalse(ready)
        XCTAssertEqual(h.controller.readiness[u], .unresponsive)
        XCTAssertGreaterThanOrEqual(h.stub.calls.filter { $0.hasPrefix("io ") }.count, 1)
    }

    /// tvOS has no SpringBoard: its home screen process is PineBoard, which
    /// the tvOS job list names once the boot finished, so an Apple TV
    /// becomes ready (it read as not responding after 60 s). The listing is
    /// its the default set's Apple TV 4K on tvOS 27.0; the screenshot is
    /// the iOS home screen capture (the tvOS one, 5.4 MB, was not kept).
    func testAnAppleTVIsReadyOncePineBoardRuns() async throws {
        let tv = try SimulatorFixtures.entry(
            "simctl-list-j-devices.default-set.json",
            udid: "86BEC255-1847-46B5-A7C0-3F13F08ADBBB"
        )
        XCTAssertEqual(tv.platform, "tvOS")
        let t = tv.udid
        let h = try harness(
            arms: """
              *" boot \(t)")
                exit 0 ;;
              *" bootstatus \(t)")
                \(SimulatorFixtures.cat("simctl-bootstatus.already-booted.stdout.txt")) ;;
              *" spawn \(t) launchctl list")
                \(SimulatorFixtures.cat("simctl-spawn-launchctl-list.tvos-ready.stdout.txt")) ;;
              *" io \(t) screenshot --type=png "*)
                \(SimulatorFixtures.screenshot("simctl-io-screenshot.home-screen-loading.png")) ;;
            """,
            entries: [tv]
        )
        h.controller.homeScreenTimeout = .milliseconds(500)

        let ready = await h.controller.boot(t)

        XCTAssertTrue(ready)
        XCTAssertEqual(h.controller.readiness[t], .ready)
        XCTAssertEqual(h.stub.calls, [
            "boot \(t)", "bootstatus \(t)", "spawn \(t) launchctl list", "io \(t) screenshot --type=png",
        ])
    }

    /// A screen that stays dark once the boot finished and SpringBoard runs
    /// is a screen that is off (powered off with `simctl io … screenConfig
    /// power off`): ready once it stayed dark for the grace, not "not
    /// responding". The dark capture is the black a tvOS boot showed; a
    /// shorter black, as that boot's, is waited through.
    func testAScreenThatStaysDarkIsOffAndReady() async throws {
        let h = try harness(
            arms: Self.arms(screenshot: SimulatorFixtures.screenshot("simctl-io-screenshot.tvos-dark.png")),
            entries: [try shutDownEntry()]
        )
        h.controller.screenOffGrace = .milliseconds(300)
        h.controller.homeScreenTimeout = .seconds(5)

        let started = ContinuousClock.now
        let ready = await h.controller.boot(u)

        XCTAssertTrue(ready)
        XCTAssertEqual(h.controller.readiness[u], .ready)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(300))
        XCTAssertGreaterThanOrEqual(h.stub.calls.filter { $0.hasPrefix("io ") }.count, 2)
    }

    /// A screenshot that gives no picture — simctl waits 61 s on a screen
    /// that is powered off, and the capture is bounded well below — counts
    /// as a dark screen too.
    func testAScreenGivingNoPictureIsOffAndReady() async throws {
        let h = try harness(arms: Self.arms(screenshot: "exit 60"), entries: [try shutDownEntry()])
        h.controller.screenOffGrace = .milliseconds(200)

        let ready = await h.controller.boot(u)

        XCTAssertTrue(ready)
        XCTAssertEqual(h.controller.readiness[u], .ready)
    }

    /// A screen that is dark as the bound passes is off, however long it was
    /// dark; the boot screen showing then is not responding (above).
    func testAScreenDarkAtTheBoundIsOff() async throws {
        let h = try harness(
            arms: Self.arms(screenshot: SimulatorFixtures.screenshot("simctl-io-screenshot.tvos-dark.png")),
            entries: [try shutDownEntry()]
        )
        h.controller.homeScreenTimeout = .milliseconds(300)

        let ready = await h.controller.boot(u)

        XCTAssertTrue(ready)
        XCTAssertEqual(h.controller.readiness[u], .ready)
    }

    /// A simulator that read as not responding is followed again, from the
    /// start, on a Refresh: once it answers it is ready, with no restart.
    func testARefreshFollowsANotRespondingSimulatorAgain() async throws {
        let stubFolder = try makeTemporaryFolder("state")
        let marker = stubFolder.appendingPathComponent("answers").path
        let launchctl = """
        if [ -f \(SimulatorFixtures.quoted(marker)) ]; then \(SimulatorFixtures.cat("simctl-spawn-launchctl-list.ready.stdout.txt")); else exit 1; fi
        """
        let h = try harness(
            arms: Self.arms(
                bootstatus: SimulatorFixtures.cat("simctl-bootstatus.already-booted.stdout.txt"),
                launchctl: launchctl
            ),
            entries: [try bootedEntry()]
        )
        h.controller.homeScreenTimeout = .milliseconds(300)
        h.controller.noteSnapshot([try bootedEntry()])
        await waitUntil(timeout: 10, "not responding") { h.controller.readiness[self.u] == .unresponsive }

        // A later listing leaves it be; a Refresh follows it again.
        h.controller.noteSnapshot([try bootedEntry()])
        XCTAssertEqual(h.controller.readiness[u], .unresponsive)
        FileManager.default.createFile(atPath: marker, contents: Data())
        h.controller.refollowUnresponsive()

        await waitUntil(timeout: 10, "ready") { h.controller.isReady(self.u) }
        XCTAssertEqual(h.controller.bootedByDeviceHubPro, [], "followed, not booted")
        XCTAssertFalse(h.stub.calls.contains("boot \(u)"))
        XCTAssertEqual(h.ready.calls, ["followed"], "a Refresh starts no boot: the kept location is not sent")
    }

    /// After Finished the job list is asked again until it answers with
    /// SpringBoard (a spawn can fail while launchd settles).
    func testSpringBoardIsAskedForUntilItAnswers() async throws {
        let stubFolder = try makeTemporaryFolder("state")
        let marker = stubFolder.appendingPathComponent("asked").path
        let launchctl = """
        if [ -f \(SimulatorFixtures.quoted(marker)) ]; then \(SimulatorFixtures.cat("simctl-spawn-launchctl-list.ready.stdout.txt")); else touch \(SimulatorFixtures.quoted(marker)); exit 1; fi
        """
        let h = try harness(arms: Self.arms(launchctl: launchctl), entries: [try shutDownEntry()])

        let ready = await h.controller.boot(u)

        XCTAssertTrue(ready)
        XCTAssertEqual(h.stub.calls.filter { $0.hasSuffix("launchctl list") }.count, 2)
    }

    /// A job list that never answers: once the bound passes the simulator
    /// reads as not responding, and the boot reports it was not ready.
    func testAHomeScreenThatNeverComesReadsAsNotResponding() async throws {
        let h = try harness(arms: Self.arms(launchctl: "exit 1"), entries: [try shutDownEntry()])
        h.controller.homeScreenTimeout = .milliseconds(300)

        let ready = await h.controller.boot(u)

        XCTAssertFalse(ready)
        XCTAssertEqual(h.controller.readiness[u], .unresponsive)
        XCTAssertEqual(h.controller.runState(for: try bootedEntry()), .unreachable)
        XCTAssertEqual(h.controller.operations, [:])
    }

    /// A simulator someone else booted meanwhile: `boot` is refused as
    /// Booted (SimError 405), the boot is followed all the same (a finished
    /// boot's `bootstatus` reports nothing left), and it is not Device Hub Pro's.
    func testBootingABootedSimulatorFollowsItWithoutOwningIt() async throws {
        let h = try harness(
            arms: Self.arms(
                bootstatus: SimulatorFixtures.cat("simctl-bootstatus.already-booted.stdout.txt"),
                extra: """
                  *" boot \(u)")
                    \(SimulatorFixtures.catToStderr("simctl-boot-booted.stderr.txt")); exit 149 ;;
                """
            ),
            entries: [try bootedEntry()]
        )

        let ready = await h.controller.boot(u)

        XCTAssertTrue(ready)
        XCTAssertEqual(h.controller.bootedByDeviceHubPro, [])
        XCTAssertEqual(h.controller.readiness[u], .ready)
        XCTAssertNil(h.status.errorMessage)
        XCTAssertEqual(h.ready.calls, ["followed"], "someone else's boot")
    }

    // MARK: - Shut down and restart

    /// Shut Down ends the readiness and its ownership; a simulator that is
    /// already shut down counts as done (SimError 405).
    func testShutDownEndsReadinessAndOwnership() async throws {
        let h = try harness(arms: Self.arms(), entries: [try shutDownEntry()])
        await h.controller.boot(u)

        let stopped = await h.controller.shutDown(u)

        XCTAssertTrue(stopped)
        XCTAssertEqual(h.stub.calls.last, "shutdown \(u)")
        XCTAssertNil(h.controller.readiness[u])
        XCTAssertEqual(h.controller.bootedByDeviceHubPro, [])
        XCTAssertEqual(h.controller.runState(for: try shutDownEntry()), .stopped)

        let again = try harness(
            arms: Self.arms(extra: """
              *" shutdown \(u)")
                \(SimulatorFixtures.catToStderr("simctl-shutdown-already-shutdown.stderr.txt")); exit 149 ;;
            """),
            entries: [try shutDownEntry()]
        )
        let alreadyStopped = await again.controller.shutDown(u)
        XCTAssertTrue(alreadyStopped)
        XCTAssertNil(again.status.errorMessage)
    }

    /// A Shut Down interrupts a boot that is still waiting to be ready: the
    /// `bootstatus` wait ends, the boot reports it was not ready, and the
    /// simulator is left stopped with no operation.
    func testShutDownInterruptsABootWaitingToBeReady() async throws {
        let h = try harness(
            arms: Self.arms(bootstatus: "while true; do sleep 0.05; done"),
            entries: [try shutDownEntry()]
        )
        let boot = Task { await h.controller.boot(u) }
        await waitUntil(timeout: 10, "the wait") { h.controller.readiness[self.u] == .waiting(.launching) }
        await waitUntil(timeout: 10, "bootstatus running") { h.stub.calls.contains("bootstatus \(self.u)") }

        let secondBoot = await h.controller.boot(u)
        XCTAssertFalse(secondBoot, "one operation at a time")
        let clone = await h.controller.clone(u, as: "DeviceHubPro-UI-core-clone")
        XCTAssertNil(clone)

        let stopped = await h.controller.shutDown(u)
        let booted = await boot.value

        XCTAssertTrue(stopped)
        XCTAssertFalse(booted)
        XCTAssertEqual(h.stub.calls, ["boot \(u)", "bootstatus \(u)", "shutdown \(u)"])
        XCTAssertNil(h.controller.readiness[u])
        XCTAssertEqual(h.controller.bootedByDeviceHubPro, [])
        XCTAssertEqual(h.controller.operations, [:])
        XCTAssertNil(h.status.errorMessage)
    }

    /// Restart shuts down and boots again, and keeps its owner: a simulator
    /// someone else booted stays theirs.
    func testRestartKeepsTheOwner() async throws {
        let h = try harness(arms: Self.arms(), entries: [try bootedEntry()])
        h.controller.noteSnapshot([try bootedEntry()])
        await waitUntil(timeout: 10, "the external boot's readiness") { h.controller.isReady(self.u) }

        let restarted = await h.controller.restart(u)

        XCTAssertTrue(restarted)
        XCTAssertEqual(Array(h.stub.calls.suffix(5)), [
            "shutdown \(u)", "boot \(u)", "bootstatus \(u)", "spawn \(u) launchctl list", "io \(u) screenshot --type=png",
        ])
        XCTAssertEqual(h.controller.bootedByDeviceHubPro, [], "booted elsewhere, restarted here: still not ours")
        XCTAssertTrue(h.controller.isReady(u))
        XCTAssertEqual(h.ready.calls, ["followed", "started"], "the restart's boot is Device Hub Pro's to set up")
    }

    // MARK: - Erase

    /// Erasing a running simulator: shut down, erase, boot again, and wait
    /// for ready; a simulator Device Hub Pro booted stays Device Hub Pro's.
    func testEraseOfARunningSimulatorShutsDownErasesAndBootsAgain() async throws {
        let h = try harness(arms: Self.arms(), entries: [try shutDownEntry()])
        await h.controller.boot(u)
        let before = h.stub.calls.count

        let erased = await h.controller.erase(u)

        XCTAssertTrue(erased)
        XCTAssertEqual(Array(h.stub.calls.dropFirst(before)), [
            "shutdown \(u)", "erase \(u)", "boot \(u)", "bootstatus \(u)", "spawn \(u) launchctl list",
            "io \(u) screenshot --type=png",
        ])
        XCTAssertEqual(h.controller.bootedByDeviceHubPro, [u])
        XCTAssertTrue(h.controller.isReady(u))
        XCTAssertEqual(h.controller.operations, [:])
    }

    /// Erasing a stopped simulator only erases it.
    func testEraseOfAStoppedSimulatorOnlyErases() async throws {
        let h = try harness(arms: Self.arms(), entries: [try shutDownEntry()])

        let erased = await h.controller.erase(u)

        XCTAssertTrue(erased)
        XCTAssertEqual(h.stub.calls, ["erase \(u)"])
        XCTAssertNil(h.controller.readiness[u])
        XCTAssertEqual(h.controller.bootedByDeviceHubPro, [])
    }

    /// A listing that still says Shutdown about a running simulator: simctl
    /// refuses the erase as Booted (SimError 405), and the erase shuts it
    /// down, erases it and boots it again; it was not booted here, so it is
    /// not Device Hub Pro's.
    func testEraseCatchesAListingThatIsBehind() async throws {
        let stubFolder = try makeTemporaryFolder("state")
        let marker = stubFolder.appendingPathComponent("refused").path
        let erase = """
          *" erase \(u)")
            if [ -f \(SimulatorFixtures.quoted(marker)) ]; then exit 0; fi
            touch \(SimulatorFixtures.quoted(marker)); \(SimulatorFixtures.catToStderr("simctl-erase-booted.stderr.txt")); exit 149 ;;
        """
        let h = try harness(arms: Self.arms(extra: erase), entries: [try shutDownEntry()])

        let erased = await h.controller.erase(u)

        XCTAssertTrue(erased)
        XCTAssertEqual(h.stub.calls, [
            "erase \(u)", "shutdown \(u)", "erase \(u)", "boot \(u)", "bootstatus \(u)", "spawn \(u) launchctl list",
            "io \(u) screenshot --type=png",
        ])
        XCTAssertEqual(h.controller.bootedByDeviceHubPro, [])
        XCTAssertTrue(h.controller.isReady(u))
    }

    /// An erase simctl keeps refusing reaches the alert with simctl's reason.
    func testARefusedEraseReachesTheAlert() async throws {
        let h = try harness(
            arms: Self.arms(extra: """
              *" erase \(u)")
                \(SimulatorFixtures.catToStderr("simctl-erase-booted.stderr.txt")); exit 149 ;;
            """),
            entries: [try shutDownEntry()]
        )

        let erased = await h.controller.erase(u)

        XCTAssertFalse(erased)
        XCTAssertEqual(
            h.status.errorMessage,
            "Could not erase DeviceHubPro-UI-core: Unable to erase contents and settings in current state: Booted"
        )
        XCTAssertEqual(h.controller.operations, [:])
    }

    // MARK: - Delete

    /// Delete shuts a running simulator down, deletes it and removes its
    /// `Logs/CoreSimulator/<UDID>` folder, and only that folder.
    func testDeleteRemovesTheSimulatorAndItsLogFolder() async throws {
        let h = try harness(arms: Self.arms(), entries: [try bootedEntry()])
        let own = h.logs.appendingPathComponent(u, isDirectory: true)
        let other = h.logs.appendingPathComponent(SimulatorFixtures.cloneUDID, isDirectory: true)
        for folder in [own, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: folder.appendingPathComponent("system.log").path, contents: Data("x".utf8))
        }

        let deleted = await h.controller.delete(u)

        XCTAssertTrue(deleted)
        XCTAssertEqual(h.stub.calls, ["shutdown \(u)", "delete \(u)"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertNil(h.controller.readiness[u])
        XCTAssertEqual(h.controller.operations, [:])
    }

    /// A stopped simulator is deleted without a shutdown; a missing log
    /// folder is fine.
    func testDeleteOfAStoppedSimulator() async throws {
        let h = try harness(arms: Self.arms(), entries: [try shutDownEntry()])

        let deleted = await h.controller.delete(u)

        XCTAssertTrue(deleted)
        XCTAssertEqual(h.stub.calls, ["delete \(u)"])
        XCTAssertNil(h.status.errorMessage)
    }

    /// Only a UDID is ever an operation's subject: nothing runs and no folder
    /// is touched for anything else.
    func testOnlyAUDIDIsOperatedOn() async throws {
        let h = try harness(arms: Self.arms(), entries: [])
        for subject in ["booted", "all", "../\(u)", ""] {
            let deleted = await h.controller.delete(subject)
            XCTAssertFalse(deleted)
            let booted = await h.controller.boot(subject)
            XCTAssertFalse(booted)
        }
        XCTAssertEqual(h.stub.calls, [])
    }

    // MARK: - Clone and rename

    /// Clone answers with the clone's UDID; a running simulator cannot be
    /// cloned (SimError 405) and the alert says what to do.
    func testCloneAnswersWithTheClone() async throws {
        let h = try harness(arms: Self.arms(), entries: [try shutDownEntry()])

        let clone = await h.controller.clone(u, as: "  DeviceHubPro-UI-core-clone ")

        XCTAssertEqual(clone, SimulatorFixtures.cloneUDID)
        XCTAssertEqual(h.stub.calls, ["clone \(u) DeviceHubPro-UI-core-clone"])
        XCTAssertEqual(h.reloads.value, 1)

        let booted = try harness(
            arms: Self.arms(extra: """
              *" clone \(u) "*)
                \(SimulatorFixtures.catToStderr("simctl-clone-booted.stderr.txt")); exit 149 ;;
            """),
            entries: [try bootedEntry()]
        )
        let refused = await booted.controller.clone(u, as: "DeviceHubPro-UI-core-clone")
        XCTAssertNil(refused)
        XCTAssertEqual(booted.status.errorMessage, "Shut down DeviceHubPro-UI-core-renamed before cloning it.")

        let unnamed = await h.controller.clone(u, as: "  ")
        XCTAssertNil(unnamed)
        XCTAssertEqual(h.stub.calls.count, 1, "no name, no call")
    }

    /// A rename runs beside a boot waiting to be ready and leaves that
    /// boot's operation in place; an empty name is refused before simctl.
    func testRenameRunsBesideABootWait() async throws {
        let h = try harness(
            arms: Self.arms(bootstatus: "while true; do sleep 0.05; done"),
            entries: [try shutDownEntry()]
        )
        let boot = Task { await h.controller.boot(u) }
        await waitUntil(timeout: 10, "the wait") { h.controller.readiness[self.u] == .waiting(.launching) }

        let renamed = await h.controller.rename(u, to: "DeviceHubPro-UI-core-renamed")
        XCTAssertTrue(renamed)
        XCTAssertEqual(h.controller.operations[u], .starting)
        let unnamed = await h.controller.rename(u, to: " ")
        XCTAssertFalse(unnamed)
        XCTAssertEqual(h.status.errorMessage, "A simulator needs a name.")

        await h.controller.shutDown(u)
        _ = await boot.value
        XCTAssertEqual(h.stub.calls.filter { $0.hasPrefix("rename ") }, ["rename \(u) DeviceHubPro-UI-core-renamed"])
    }

    // MARK: - Listings

    /// A simulator booted elsewhere is followed to ready once a listing shows
    /// it booted, without becoming Device Hub Pro's; a listing that shows it shut
    /// down drops its readiness, and one without it forgets it.
    func testAnExternalBootIsFollowedAndForgotten() async throws {
        let h = try harness(
            arms: Self.arms(bootstatus: SimulatorFixtures.cat("simctl-bootstatus.already-booted.stdout.txt")),
            entries: [try bootedEntry()]
        )
        XCTAssertEqual(h.controller.runState(for: try bootedEntry()), .booting(.launching), "Booted is not ready")

        h.controller.noteSnapshot([try bootedEntry()])
        h.controller.noteSnapshot([try bootedEntry()])
        await waitUntil(timeout: 10, "ready") { h.controller.isReady(self.u) }

        XCTAssertEqual(
            h.stub.calls,
            ["bootstatus \(u)", "spawn \(u) launchctl list", "io \(u) screenshot --type=png"],
            "one wait for two listings"
        )
        XCTAssertEqual(h.controller.runState(for: try bootedEntry()), .ready)
        XCTAssertEqual(h.controller.bootedByDeviceHubPro, [])
        XCTAssertEqual(h.ready.calls, ["followed"], "a boot started elsewhere is not Device Hub Pro's to change")

        h.controller.noteSnapshot([try shutDownEntry()])
        XCTAssertNil(h.controller.readiness[u])
        XCTAssertEqual(h.controller.runState(for: try shutDownEntry()), .stopped)

        h.controller.noteSnapshot([try bootedEntry()])
        await waitUntil(timeout: 10, "ready again") { h.controller.isReady(self.u) }
        h.controller.noteSnapshot([])
        XCTAssertNil(h.controller.readiness[u])
    }

    /// A simulator Device Hub Pro booted and someone shut down elsewhere is no
    /// longer Device Hub Pro's to shut down at quit.
    func testAShutdownElsewhereEndsTheOwnership() async throws {
        let h = try harness(arms: Self.arms(), entries: [try shutDownEntry()])
        await h.controller.boot(u)
        XCTAssertEqual(h.controller.bootedByDeviceHubPro, [u])

        h.controller.noteSnapshot([try shutDownEntry()])

        XCTAssertEqual(h.controller.bootedByDeviceHubPro, [])
        XCTAssertNil(h.controller.readiness[u])
    }

    /// Once stopped (quit), a listing that still arrives — from a refresh
    /// that resumed during the quit — follows no booted simulator: no
    /// `bootstatus`, `launchctl` or screenshot child starts.
    func testAStoppedControllerFollowsNothing() async throws {
        let h = try harness(
            arms: Self.arms(bootstatus: SimulatorFixtures.cat("simctl-bootstatus.already-booted.stdout.txt")),
            entries: [try bootedEntry()]
        )

        h.controller.stop()
        h.controller.noteSnapshot([try bootedEntry()])
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(h.controller.readiness[u])
        XCTAssertEqual(h.stub.calls, [])
    }

    /// Without simctl (no Apple tooling) every operation is a no-op.
    func testWithoutSimctlNothingRuns() async throws {
        let controller = SimulatorLifecycleController(status: StatusCenter())
        let booted = await controller.boot(u)
        let deleted = await controller.delete(u)
        let clone = await controller.clone(u, as: "x")
        controller.noteSnapshot([try bootedEntry()])

        XCTAssertFalse(booted)
        XCTAssertFalse(deleted)
        XCTAssertNil(clone)
        XCTAssertEqual(controller.operations, [:])
        XCTAssertNil(controller.readiness[u])
    }
}
