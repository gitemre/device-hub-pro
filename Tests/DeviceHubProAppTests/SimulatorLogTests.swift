import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The Diagnostics log view for a simulator (`LogcatController`'s simulator
/// source): its unified log through a stub simctl that replays the real
/// captures (`simctl listapps` and `log stream --style ndjson`, provenance in
/// `SimctlFixtureTests` and `SimulatorLogStreamTests`), shown as logcat
/// entries; the App picker's follow by process name; the status line; stop
/// and the hand-over to logcat; the search and the export with the
/// subsystem. No adb is ever run.
@MainActor
final class SimulatorLogTests: XCTestCase {
    private static let udid = SimulatorFixtures.udid

    /// A stub whose log stream prints the capture and then keeps running,
    /// as `log stream` does, until the stream is stopped.
    private func makeSimctl(streamEnds: Bool = false) throws -> StubTool {
        let log = SimulatorFixtures.url("simctl-spawn-log-stream-ndjson.trimmed.ndjson", folder: "logs").path
        let tail = streamEnds ? "" : "; exec sleep 30"
        return try makeStubTool("simctl", arms: """
          *"listapps \(Self.udid)")
            \(SimulatorFixtures.cat("simctl-listapps.stdout.txt")) ;;
          *"spawn \(Self.udid) log stream --style ndjson --level debug"*)
            cat \(SimulatorFixtures.quoted(log))\(tail) ;;
        """)
    }

    private func makeController(_ simctl: StubTool) -> LogcatController {
        let controller = LogcatController(adbClient: nil, status: StatusCenter(), picker: TestPicker())
        let client = SimctlClient(simctlURL: simctl.url)
        controller.simctlSource = { client }
        addTeardownBlock { @MainActor in controller.stopLogcat() }
        return controller
    }

    /// Opening streams the whole log, lists the apps that can be followed,
    /// and the poll shows the events as logcat entries (levels mapped, the
    /// process as the tag, the subsystem kept).
    func testOpeningStreamsTheWholeLogAsLogcatEntries() async throws {
        let simctl = try makeSimctl()
        let controller = makeController(simctl)

        await controller.openSimulatorLog(udid: Self.udid)

        XCTAssertEqual(controller.simulatorLogUDID, Self.udid)
        XCTAssertNil(controller.logcatSerial)
        XCTAssertEqual(controller.logSourceID, Self.udid)
        XCTAssertTrue(controller.logcatPackages.contains("com.apple.mobilesafari"))
        XCTAssertEqual(controller.logcatPackages, controller.logcatPackages.sorted())
        XCTAssertEqual(controller.logcatPackages.count, 39, "every listed app names its executable")
        await waitUntil(timeout: 5, "the poll never showed the events") { controller.logcatEntries.count == 29 }
        XCTAssertEqual(controller.logcatStatusText, "all logs")

        let first = try XCTUnwrap(controller.logcatEntries.first)
        XCTAssertEqual(first.timestamp, "09-25 15:06:19.359")
        XCTAssertEqual(first.tag, "ExtragalacticPoster")
        XCTAssertEqual(first.subsystem, "com.apple.defaults")
        XCTAssertEqual(first.level, .debug)
        XCTAssertEqual(
            Set(controller.logcatEntries.map(\.level)),
            [.verbose, .debug, .info, .error, .fatal],
            "activity records, Debug, Info and Default, Error, Fault"
        )
        XCTAssertEqual(simctl.calls.filter { $0.contains("log stream") }, [
            "spawn \(Self.udid) log stream --style ndjson --level debug",
        ])
    }

    /// A burst faster than the poll reaches the view whole: 2,900 events at
    /// once (the capture's 29 printed 100 times, as `SimulatorLogStreamTests`
    /// builds its burst). The poll used to publish only the newest 1,500,
    /// and the view's feed took them for all that was new, so the other
    /// 1,400 vanished from the list and from Export without a trace. The
    /// test feeds a `LogcatFeed` from every snapshot, as the view does.
    func testABurstReachesTheViewWhole() async throws {
        let log = SimulatorFixtures.url("simctl-spawn-log-stream-ndjson.trimmed.ndjson", folder: "logs").path
        let simctl = try makeStubTool("simctl", arms: """
          *"listapps \(Self.udid)")
            \(SimulatorFixtures.cat("simctl-listapps.stdout.txt")) ;;
          *"spawn \(Self.udid) log stream --style ndjson --level debug"*)
            i=0; while [ $i -lt 100 ]; do cat \(SimulatorFixtures.quoted(log)); i=$((i + 1)); done; exec sleep 30 ;;
        """)
        let controller = makeController(simctl)
        let feed = LogcatFeed()
        var key = LogcatFeed.SnapshotKey([])

        await controller.openSimulatorLog(udid: Self.udid)
        let deadline = ContinuousClock.now + .seconds(10)
        while feed.entries.count < 2900, ContinuousClock.now < deadline {
            let next = LogcatFeed.SnapshotKey(controller.logcatEntries)
            if next != key {
                key = next
                feed.ingest(controller.logcatEntries)
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(feed.entries.map(\.id), Array(1...2900), "every event once, in order, no gap marker")
        XCTAssertEqual(controller.logcatEntries.last?.id, 2900)
    }

    /// The window a poll publishes: the newest 1,500 of what the view had
    /// and what came, or all that came when one poll brings more.
    func testThePollWindow() {
        func entries(_ ids: ClosedRange<UInt64>) -> [LogcatEntry] {
            ids.map { LogcatEntry(id: $0, timestamp: "t", pid: 1, tid: 1, level: .info, tag: "p", message: "m") }
        }
        XCTAssertEqual(LogcatController.simulatorLogWindow([], adding: entries(1...10)).map(\.id), Array(1...10))
        XCTAssertEqual(
            LogcatController.simulatorLogWindow(entries(1...1500), adding: entries(1501...1600)).map(\.id),
            Array(101...1600)
        )
        XCTAssertEqual(
            LogcatController.simulatorLogWindow(entries(1...1500), adding: entries(1501...5000)).map(\.id),
            Array(1501...5000)
        )
    }

    /// Picking an app starts the stream over on its process: the predicate
    /// on the executable's name, which follows the app across relaunches.
    func testPickingAnAppFollowsItsProcess() async throws {
        let simctl = try makeSimctl()
        let controller = makeController(simctl)
        await controller.openSimulatorLog(udid: Self.udid)

        controller.setLogcatPackage("com.apple.mobilesafari")

        XCTAssertEqual(controller.logcatEntries, [], "the list on screen empties at once")
        await waitUntil(timeout: 5, "the followed stream never started") {
            simctl.calls.contains { $0.contains("--predicate") }
        }
        XCTAssertEqual(
            simctl.calls.last { $0.contains("log stream") },
            #"spawn \#(Self.udid) log stream --style ndjson --level debug --predicate process == "MobileSafari""#
        )
        await waitUntil(timeout: 5, "the status never named the app") {
            controller.logcatStatusText == "com.apple.mobilesafari · MobileSafari"
        }

        // (The whole-log stream the open started may never have launched:
        // the pick replaced it at once.)
        controller.setLogcatPackage(nil)
        await waitUntil(timeout: 5, "the whole log never came back") {
            simctl.calls.last { $0.contains("log stream") } == "spawn \(Self.udid) log stream --style ndjson --level debug"
        }
        await waitUntil(timeout: 5) { controller.logcatStatusText == "all logs" }
    }

    /// A stream that ends (the simulator shut down) reports why, which the
    /// view shows as "Stream disconnected" with Retry.
    func testAnEndedStreamReportsItsReason() async throws {
        let simctl = try makeSimctl(streamEnds: true)
        let controller = makeController(simctl)
        await controller.openSimulatorLog(udid: Self.udid)

        await waitUntil(timeout: 5, "the stream never ended") { controller.logcatStopReason != nil }
        XCTAssertEqual(controller.logcatStopReason, "log stream exited with status 0")
        await waitUntil(timeout: 5) { controller.logcatStatusText == "stopped: log stream exited with status 0" }
        XCTAssertEqual(controller.logcatEntries.count, 29, "what it streamed stays on screen")
    }

    /// Stop ends the stream and forgets the simulator; opening an adb
    /// device's logcat replaces a simulator's stream, and the other way
    /// round.
    func testStopAndTheHandOverBetweenPlatforms() async throws {
        let simctl = try makeSimctl()
        let controller = makeController(simctl)
        await controller.openSimulatorLog(udid: Self.udid)
        await waitUntil(timeout: 5) { !controller.logcatEntries.isEmpty }

        controller.stopLogcat()
        XCTAssertNil(controller.simulatorLogUDID)
        XCTAssertNil(controller.logSourceID)
        XCTAssertTrue(controller.logcatWasStopped)
        XCTAssertEqual(controller.logcatEntries, [])
        XCTAssertNil(controller.logcatStopReason, "a deliberate stop is no disconnect")

        await controller.openSimulatorLog(udid: Self.udid)
        await controller.openLogcat(serial: "emulator-5554")
        XCTAssertNil(controller.simulatorLogUDID)
        XCTAssertEqual(controller.logSourceID, "emulator-5554")

        await controller.openSimulatorLog(udid: Self.udid)
        XCTAssertNil(controller.logcatSerial)
        XCTAssertEqual(controller.logSourceID, Self.udid)
    }

    /// Opening the simulator it already streams starts nothing new.
    func testOpenIfNeededKeepsTheRunningStream() async throws {
        let simctl = try makeSimctl()
        let controller = makeController(simctl)
        controller.openSimulatorLogIfNeeded(udid: Self.udid)
        await waitUntil(timeout: 5) { simctl.calls.contains { $0.contains("log stream") } }
        controller.openSimulatorLogIfNeeded(udid: Self.udid)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(simctl.calls.filter { $0.contains("log stream") }.count, 1)
        XCTAssertEqual(simctl.calls.filter { $0.contains("listapps") }.count, 1)
    }

    /// A model whose simulator (`simctl list` replayed) is followed to
    /// ready, and the stub simctl it runs; its log stream keeps running.
    /// `listing`, when given, is the file `listapps` prints (a test swaps
    /// it); `extraArms` are matched first.
    private func makeReadyModel(listing: URL? = nil, extraArms: String = "") async throws -> (AppModel, StubTool) {
        let listapps = listing.map { "cat \(SimulatorFixtures.quoted($0.path))" }
            ?? SimulatorFixtures.cat("simctl-listapps.stdout.txt")
        let simctl = try makeStubTool("simctl", arms: extraArms + """
          *"list -j devices")
            \(SimulatorFixtures.cat("simctl-list-j-devices.booted-after-rename.json")) ;;
          *"list -j runtimes")
            \(SimulatorFixtures.cat("simctl-list-j-runtimes.json")) ;;
          *"list -j devicetypes")
            \(SimulatorFixtures.cat("simctl-list-j-devicetypes.json")) ;;
          *"bootstatus \(Self.udid)")
            \(SimulatorFixtures.cat("simctl-bootstatus.already-booted.stdout.txt")) ;;
          *"spawn \(Self.udid) launchctl list")
            \(SimulatorFixtures.cat("simctl-spawn-launchctl-list.ready.stdout.txt")) ;;
          *"io \(Self.udid) screenshot --type=png "*)
            \(SimulatorFixtures.screenshot("simctl-io-screenshot.home-screen-loading.png")) ;;
          *"listapps \(Self.udid)")
            \(listapps) ;;
          *"spawn \(Self.udid) log stream --style ndjson --level debug")
            exec sleep 30 ;;
        """)
        let model = AppModel.testing(apple: .stubbed(
            simctl: simctl,
            devicesDirectory: try makeTemporaryFolder("set"),
            logsDirectory: try makeTemporaryFolder("logs")
        ))
        addTeardownBlock { @MainActor in
            model.workspace.logcat.stopLogcat()
            model.stopSimulatorProvider()
        }
        return (model, simctl)
    }

    /// The Diagnostics toolbar button on a ready simulator's stage opens its
    /// log; on a stage with nothing live it opens nothing.
    func testTheDiagnosticsButtonOpensAReadySimulatorsLog() async throws {
        let (model, simctl) = try await makeReadyModel()

        model.deviceSelection = nil
        model.workspace.window.selectInspectorTab(.diagnostics)
        XCTAssertNil(model.logcat.logSourceID, "nothing live, nothing streams")
        model.workspace.window.showInspector = false

        await model.simulators.refresh()
        await waitUntil(timeout: 10, "never ready") { model.simulatorLifecycle.isReady(Self.udid) }
        model.deviceSelection = .simulator(Self.udid)
        model.workspace.window.selectInspectorTab(.diagnostics)
        await waitUntil(timeout: 5, "the log never opened") {
            model.logcat.simulatorLogUDID == Self.udid && simctl.calls.contains { $0.contains("log stream") }
        }
    }

    /// A simulator's log closes as soon as nothing shows it: another tab,
    /// the inspector hidden, another selection, the simulator no longer
    /// ready. A debug-level stream costs about a fifth of a core even while
    /// paused, so it must not run on behind another device (it did: only
    /// Stop, quit or the simulator's shutdown ended it). The close is no
    /// Stop: the view is not left on "Logcat stopped", and the tab opens
    /// the log again.
    func testTheLogClosesWhenNothingShowsIt() async throws {
        let (model, simctl) = try await makeReadyModel()
        await model.simulators.refresh()
        await waitUntil(timeout: 10, "never ready") { model.simulatorLifecycle.isReady(Self.udid) }
        model.deviceSelection = .simulator(Self.udid)
        model.workspace.window.showInspector = false
        var opened = 0
        func openAgain(_ why: String) async {
            model.workspace.window.selectInspectorTab(.diagnostics)
            opened += 1
            await waitUntil(timeout: 5, "the log never opened \(why)") {
                model.logcat.simulatorLogUDID == Self.udid
                    && simctl.calls.filter { $0.contains("log stream") }.count == opened
            }
        }
        func assertClosed(_ why: String) async {
            await waitUntil(timeout: 5, "\(why) left the log running") { model.logcat.simulatorLogUDID == nil }
            XCTAssertNil(model.logcat.logSourceID, why)
            XCTAssertFalse(model.logcat.logcatWasStopped, "\(why): not a Stop")
            XCTAssertEqual(model.logcat.logcatStatusText, "", why)
        }

        await openAgain("at first")
        model.workspace.window.inspectorTab = .info
        await assertClosed("another tab")

        await openAgain("after another tab")
        model.workspace.window.showInspector = false
        await assertClosed("the hidden inspector")

        await openAgain("after the inspector came back")
        model.deviceSelection = nil
        await assertClosed("another selection")

        model.deviceSelection = .simulator(Self.udid)
        model.workspace.window.showInspector = false
        await openAgain("on the simulator again")
        // `simctl list` reads it shut down.
        model.simulatorLifecycle.noteSnapshot([
            try SimulatorFixtures.entry("simctl-list-j-devices.cloned.json", udid: Self.udid),
        ])
        await assertClosed("the simulator no longer ready")
    }

    /// An app installed or removed while the log streams (a stage drop, the
    /// Apps inspector) is listed in the App picker without reopening the
    /// log, and nothing is restarted; a followed app that is gone stays
    /// listed, since the stream still follows its process. The two listings
    /// are real: a fresh iOS 27.0 simulator's 39 apps, and one with the
    /// fixture app installed (provenance in `SimctlAppsFixtureTests`).
    func testTheAppPickerFollowsInstalls() async throws {
        let listing = try makeTemporaryFolder("listapps").appendingPathComponent("listapps.txt")
        let fresh = try Data(contentsOf: SimulatorFixtures.url("simctl-listapps.stdout.txt"))
        let withApp = try Data(contentsOf: SimulatorFixtures.url("simctl-listapps.with-user-app.stdout.txt"))
        try fresh.write(to: listing)
        let log = SimulatorFixtures.url("simctl-spawn-log-stream-ndjson.trimmed.ndjson", folder: "logs").path
        let simctl = try makeStubTool("simctl", arms: """
          *"listapps \(Self.udid)")
            cat \(SimulatorFixtures.quoted(listing.path)) ;;
          *"spawn \(Self.udid) log stream --style ndjson --level debug"*)
            cat \(SimulatorFixtures.quoted(log)); exec sleep 30 ;;
        """)
        let controller = makeController(simctl)
        await controller.openSimulatorLog(udid: Self.udid)
        XCTAssertEqual(controller.logcatPackages.count, 39)

        try withApp.write(to: listing)
        await controller.reloadSimulatorApps(udid: Self.udid)
        XCTAssertEqual(controller.logcatPackages.count, 40)
        XCTAssertTrue(controller.logcatPackages.contains("dev.devicehubpro.fixture.apps"))
        controller.setLogcatPackage("dev.devicehubpro.fixture.apps")
        await waitUntil(timeout: 5, "the new app was never followed") {
            simctl.calls.last { $0.contains("log stream") }?.hasSuffix(#"--predicate process == "AQAAppsFixture""#) == true
        }

        try fresh.write(to: listing)
        await controller.reloadSimulatorApps(udid: Self.udid)
        XCTAssertEqual(controller.logcatPackages.count, 40, "the followed app stays listed")
        XCTAssertEqual(controller.selectedLogcatPackage, "dev.devicehubpro.fixture.apps")
        await controller.reloadSimulatorApps(udid: "00000000-0000-0000-0000-000000000000")
        XCTAssertEqual(simctl.calls.filter { $0.contains("listapps") }.count, 3, "another simulator is not read")
        XCTAssertEqual(simctl.calls.filter { $0.contains("log stream") }.count, 2, "the open and the follow only")
    }

    /// An app installed outside Device Hub Pro (`flutter run`, Xcode) reaches the
    /// App picker on its own while the log streams.
    func testAnAppInstalledElsewhereReachesThePicker() async throws {
        let listing = try makeTemporaryFolder("listapps-poll").appendingPathComponent("listapps.txt")
        try Data(contentsOf: SimulatorFixtures.url("simctl-listapps.stdout.txt")).write(to: listing)
        let withApp = try Data(contentsOf: SimulatorFixtures.url("simctl-listapps.with-user-app.stdout.txt"))
        let log = SimulatorFixtures.url("simctl-spawn-log-stream-ndjson.trimmed.ndjson", folder: "logs").path
        let simctl = try makeStubTool("simctl", arms: """
          *"listapps \(Self.udid)")
            cat \(SimulatorFixtures.quoted(listing.path)) ;;
          *"spawn \(Self.udid) log stream --style ndjson --level debug"*)
            cat \(SimulatorFixtures.quoted(log)); exec sleep 30 ;;
        """)
        let controller = makeController(simctl)
        controller.packageRefreshInterval = .milliseconds(100)
        await controller.openSimulatorLog(udid: Self.udid)
        XCTAssertFalse(controller.logcatPackages.contains("dev.devicehubpro.fixture.apps"))

        try withApp.write(to: listing)
        await waitUntil(timeout: 5, "the installed app never reached the picker") {
            controller.logcatPackages.contains("dev.devicehubpro.fixture.apps")
        }
    }

    /// The wiring: an uninstall through the Apps inspector reads the apps
    /// again for the streaming log's picker.
    func testAnUninstallReachesTheLogsAppPicker() async throws {
        let listing = try makeTemporaryFolder("listapps").appendingPathComponent("listapps.txt")
        try Data(contentsOf: SimulatorFixtures.url("simctl-listapps.with-user-app.stdout.txt")).write(to: listing)
        // `uninstall` prints nothing and exits 0 (SimctlAppsFixtureTests).
        let (model, simctl) = try await makeReadyModel(listing: listing, extraArms: """
          *"uninstall \(Self.udid) dev.devicehubpro.fixture.apps")
            ;;

        """)
        await model.simulators.refresh()
        await waitUntil(timeout: 10, "never ready") { model.simulatorLifecycle.isReady(Self.udid) }
        // The log runs only while the Diagnostics tab shows the simulator.
        model.deviceSelection = .simulator(Self.udid)
        model.workspace.window.selectInspectorTab(.diagnostics)
        await waitUntil(timeout: 5, "the log never opened") {
            model.logcat.simulatorLogUDID == Self.udid && model.logcat.logcatPackages.count == 40
        }
        XCTAssertTrue(model.logcat.logcatPackages.contains("dev.devicehubpro.fixture.apps"))

        try Data(contentsOf: SimulatorFixtures.url("simctl-listapps.stdout.txt")).write(to: listing)
        await model.simulatorApps.uninstall(bundleIdentifier: "dev.devicehubpro.fixture.apps", name: "AQA Fixture", udid: Self.udid)
        await waitUntil(timeout: 5, "the picker never read the apps again") {
            model.logcat.logcatPackages.count == 39
        }
        XCTAssertFalse(model.logcat.logcatPackages.contains("dev.devicehubpro.fixture.apps"))
        XCTAssertEqual(simctl.calls.filter { $0.contains("uninstall") }, ["uninstall \(Self.udid) dev.devicehubpro.fixture.apps"])
    }

    /// Without simctl (no Apple tooling) nothing is run.
    func testNoSimctlStartsNothing() async {
        let controller = LogcatController(adbClient: nil, status: StatusCenter(), picker: TestPicker())
        await controller.openSimulatorLog(udid: Self.udid)
        XCTAssertEqual(controller.simulatorLogUDID, Self.udid)
        XCTAssertEqual(controller.logcatPackages, [])
        XCTAssertNil(controller.logcatStopReason)
        controller.stopLogcat()
    }

    func testTheStatusLine() {
        XCTAssertEqual(LogcatController.describe(SimulatorLogStream.Status.idle, package: nil, process: nil), "idle")
        XCTAssertEqual(LogcatController.describe(SimulatorLogStream.Status.running, package: nil, process: nil), "all logs")
        XCTAssertEqual(
            LogcatController.describe(SimulatorLogStream.Status.running, package: "com.example.app", process: "Example"),
            "com.example.app · Example"
        )
        XCTAssertEqual(
            LogcatController.describe(SimulatorLogStream.Status.stopped(reason: "gone"), package: nil, process: nil),
            "stopped: gone"
        )
    }

    /// The follow is by process name: apps that share an executable name
    /// (every Flutter app runs as "Runner") show in each other's log, and the
    /// status line says which, where it read only "com.a · Runner".
    func testTheStatusLineNamesAppsThatShareTheProcessName() {
        let processes = ["com.a": "Runner", "com.b": "Runner", "com.c": "Runner", "com.apple.mobilesafari": "MobileSafari"]
        XCTAssertEqual(LogcatController.apps(sharingProcessOf: "com.a", in: processes), ["com.b", "com.c"])
        XCTAssertEqual(LogcatController.apps(sharingProcessOf: "com.apple.mobilesafari", in: processes), [])
        XCTAssertEqual(LogcatController.apps(sharingProcessOf: "com.unknown", in: processes), [])
        XCTAssertEqual(
            LogcatController.describe(.running, package: "com.a", process: "Runner", sharedWith: ["com.b"]),
            "com.a · Runner (com.b runs as Runner too)"
        )
        XCTAssertEqual(
            LogcatController.describe(.running, package: "com.a", process: "Runner", sharedWith: ["com.b", "com.c"]),
            "com.a · Runner (2 other apps run as Runner too)"
        )
    }

    /// The search matches a simulator event's subsystem too; a logcat
    /// entry (no subsystem) matches as before.
    func testTheSearchMatchesTheSubsystem() {
        let feed = LogcatFeed()
        feed.ingest([
            LogcatEntry(id: 1, timestamp: "t", pid: 1, tid: 1, level: .info, tag: "SpringBoard", message: "icons", subsystem: "com.apple.UIKit"),
            LogcatEntry(id: 2, timestamp: "t", pid: 1, tid: 1, level: .info, tag: "ActivityManager", message: "uikit start"),
            LogcatEntry(id: 3, timestamp: "t", pid: 1, tid: 1, level: .info, tag: "MobileSafari", message: "load", subsystem: "com.apple.WebKit"),
        ])
        feed.setFilter(level: .verbose, search: "UIKIT")
        XCTAssertEqual(feed.matches.map(\.id), [1, 2])
        feed.setFilter(level: .verbose, search: "webkit")
        XCTAssertEqual(feed.matches.map(\.id), [3])
    }

    /// Export names a simulator event's subsystem after its process; a
    /// logcat line is written as before.
    func testTheExportNamesTheSubsystem() {
        let text = LogcatController.logcatExportText([
            LogcatEntry(timestamp: "09-25 15:06:19.359", pid: 1, tid: 1, level: .debug, tag: "ExtragalacticPoster", message: "found no value", subsystem: "com.apple.defaults"),
            LogcatEntry(timestamp: "09-25 15:06:19.360", pid: 2, tid: 2, level: .error, tag: "ActivityManager", message: "boom"),
        ])
        XCTAssertEqual(text, """
        09-25 15:06:19.359 D ExtragalacticPoster (com.apple.defaults): found no value
        09-25 15:06:19.360 E ActivityManager: boom
        """)
    }
}
