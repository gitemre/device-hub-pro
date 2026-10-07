import CoreGraphics
import Foundation
import XCTest
@testable import DeviceHubProKit

/// A sleeper the test releases by hand: the n-th call returns once `releaseNext()`
/// was called n+1 times; durations are recorded.
final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [Duration] = []
    private var released = 0

    var durations: [Duration] { lock.withLock { _durations } }

    func sleep(_ duration: Duration) async throws {
        let index = lock.withLock { () -> Int in
            _durations.append(duration)
            return _durations.count - 1
        }
        while lock.withLock({ released <= index }) {
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func releaseNext() { lock.withLock { released += 1 } }
}

/// The fast input session, its protocol and its lease: what is written to the helper, how its answers, its exit and
/// its silence are handled, the kill switch, the move pace and the tunnel
/// lease's command line and restarts.
final class FastInputTests: XCTestCase {
    private static let device = "00000000-1111-2222-3333-444444444444"
    private let helper = URL(fileURLWithPath: "/tmp/fake-helper")

    private func session(
        children: [FakeFastChild],
        lease: FakeLease = FakeLease(),
        environment: [String: String] = [:],
        configuration: FastInputSession.Configuration = .init(),
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (Duration) async throws -> Void = FastInputClock.sleep
    ) -> (session: FastInputSession, launcher: FakeFastLauncher, lease: FakeLease) {
        let launcher = FakeFastLauncher(children: children)
        let session = FastInputSession(
            coreDeviceIdentifier: Self.device,
            helperURL: helper,
            launcher: launcher,
            lease: lease,
            configuration: configuration,
            environment: environment,
            now: now,
            sleep: sleep
        )
        return (session, launcher, lease)
    }

    private func ready(_ id: String = "0x101") -> FakeFastChild {
        FakeFastChild(startup: ["ready \(id)"])
    }

    // MARK: The protocol

    func testCommandsEncodeToTheHelpersLines() {
        XCTAssertEqual(FastInputCommand.down(x: 0.25, y: 0.83).line, "down 0.25000 0.83000")
        XCTAssertEqual(FastInputCommand.move(x: 0.5, y: 0.5).line, "move 0.50000 0.50000")
        XCTAssertEqual(FastInputCommand.up(x: 1, y: 0).line, "up 1.00000 0.00000")
        XCTAssertEqual(FastInputCommand.tap(x: 0.75, y: 0.9, holdMs: 10).line, "tap 0.75000 0.90000 10")
        XCTAssertEqual(FastInputCommand.button(.home).line, "button home")
        XCTAssertEqual(FastInputCommand.button(.volumeUp).line, "button volumeUp")
        XCTAssertEqual(FastInputCommand.button(.volumeDown).line, "button volumeDown")
        XCTAssertEqual(FastInputCommand.hid(page: 0x0C, usage: 0x30, down: true).line, "hid c 30 down")
        XCTAssertEqual(FastInputCommand.hid(page: 0x0B, usage: 0x2D, down: false).line, "hid b 2d up")
        XCTAssertEqual(FastInputCommand.hid(page: 0xFF01, usage: 0x10, down: true).line, "hid ff01 10 down")
        XCTAssertEqual(FastInputCommand.ping.line, "ping")
        XCTAssertEqual(FastInputCommand.quit.line, "quit")
        // Out-of-range values are clamped, never sent.
        XCTAssertEqual(FastInputCommand.down(x: -1, y: 2).line, "down 0.00000 1.00000")
        XCTAssertEqual(FastInputCommand.tap(x: 0, y: 0, holdMs: 99_999).line, "tap 0.00000 0.00000 5000")
    }

    func testRepliesParse() {
        XCTAssertEqual(FastInputReply.parse("ok"), .ok)
        XCTAssertEqual(FastInputReply.parse("ok\n"), .ok)
        XCTAssertEqual(FastInputReply.parse("ready 0x101"), .ready(serviceID: "0x101"))
        XCTAssertEqual(FastInputReply.parse("err 1 send failed (5)"), .err(code: 1, message: "send failed (5)"))
        XCTAssertEqual(FastInputReply.parse("err 2"), .err(code: 2, message: ""))
        XCTAssertEqual(FastInputReply.parse("fatal 4 device tunnel is not connected"), .fatal(code: 4, message: "device tunnel is not connected"))
        XCTAssertNil(FastInputReply.parse(""))
        XCTAssertNil(FastInputReply.parse("hello"))
        XCTAssertNil(FastInputReply.parse("err x y"))
        XCTAssertNil(FastInputReply.parse("ready"))
    }

    // MARK: Starting

    func testStartHoldsTheLeaseLaunchesTheHelperWithTheDeviceAndWaitsForReady() async throws {
        let child = ready("0x101")
        let rig = session(children: [child])
        try await rig.session.start()
        XCTAssertEqual(rig.lease.starts, 1)
        XCTAssertEqual(rig.launcher.launches.count, 1)
        XCTAssertEqual(rig.launcher.launches[0].executable, helper)
        XCTAssertEqual(rig.launcher.launches[0].arguments, [Self.device])
        XCTAssertTrue(rig.launcher.launches[0].wantsLines)
        let serviceID = await rig.session.serviceID
        XCTAssertEqual(serviceID, "0x101")
        await rig.session.stop()
    }

    func testAFatalTunnelAnswerIsRetriedThenSucceeds() async throws {
        let first = FakeFastChild(startup: ["fatal 4 device tunnel is not connected"])
        let second = ready()
        var configuration = FastInputSession.Configuration()
        configuration.tunnelRetryDelay = .milliseconds(1)
        let rig = session(children: [first, second], configuration: configuration)
        try await rig.session.start()
        XCTAssertEqual(rig.launcher.launches.count, 2)
        XCTAssertEqual(first.terminated, 1)
        await rig.session.stop()
    }

    func testATunnelThatStaysDownEndsWithTunnelNotConnected() async {
        let children = (0..<3).map { _ in FakeFastChild(startup: ["fatal 4 device tunnel is not connected"]) }
        var configuration = FastInputSession.Configuration()
        configuration.tunnelAttempts = 3
        configuration.tunnelRetryDelay = .milliseconds(1)
        let rig = session(children: children, configuration: configuration)
        do {
            try await rig.session.start()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? FastInputError, .tunnelNotConnected)
        }
        XCTAssertEqual(rig.launcher.launches.count, 3)
        XCTAssertEqual(rig.lease.stops, 1, "a failed start lets the lease go")
    }

    func testOtherFatalAnswersMapToTypedErrors() async {
        let refused = session(children: [FakeFastChild(startup: ["fatal 3 service socket refused"])])
        do { try await refused.session.start(); XCTFail("expected a failure") } catch {
            XCTAssertEqual(error as? FastInputError, .socketRefused("service socket refused"))
        }
        let other = session(children: [FakeFastChild(startup: ["fatal 2 no device identifier"])])
        do { try await other.session.start(); XCTFail("expected a failure") } catch {
            XCTAssertEqual(error as? FastInputError, .helperFatal(code: 2, message: "no device identifier"))
        }
    }

    func testAHelperThatSaysNothingTimesOut() async {
        let quiet = FakeFastChild(respond: nil)
        var configuration = FastInputSession.Configuration()
        configuration.startTimeout = .milliseconds(50)
        let rig = session(children: [quiet], configuration: configuration)
        do { try await rig.session.start(); XCTFail("expected a failure") } catch {
            XCTAssertEqual(error as? FastInputError, .startTimedOut)
        }
        XCTAssertEqual(quiet.terminated, 1)
    }

    func testAHelperThatExitsAtStartIsReported() async {
        let dying = FakeFastChild(respond: nil)
        let rig = session(children: [dying])
        Task { try? await Task.sleep(for: .milliseconds(30)); dying.end() }
        do { try await rig.session.start(); XCTFail("expected a failure") } catch {
            XCTAssertEqual(error as? FastInputError, .helperExited)
        }
    }

    func testALaunchFailureAndALeaseFailureAreReported() async {
        let launcher = session(children: [])
        launcher.launcher.failing = [1]
        do { try await launcher.session.start(); XCTFail("expected a failure") } catch {
            XCTAssertEqual(error as? FastInputError, .launchFailed("scripted"))
        }
        let lease = FakeLease()
        lease.startError = .leaseFailed("no tunnel")
        let leased = session(children: [ready()], lease: lease)
        do { try await leased.session.start(); XCTFail("expected a failure") } catch {
            XCTAssertEqual(error as? FastInputError, .leaseFailed("no tunnel"))
        }
        XCTAssertEqual(leased.launcher.launches.count, 0, "no helper without the lease")
    }

    // MARK: The kill switch

    func testTheKillSwitchMakesItUnavailableAndStartsNothing() async {
        XCTAssertFalse(FastInputSession.isDisabled(environment: [:]))
        XCTAssertFalse(FastInputSession.isDisabled(environment: ["DHP_DISABLE_FAST_INPUT": ""]))
        XCTAssertTrue(FastInputSession.isDisabled(environment: ["DHP_DISABLE_FAST_INPUT": "1"]))
        XCTAssertTrue(FastInputSession.isDisabled(environment: ["DHP_DISABLE_FAST_INPUT": "anything"]))

        let rig = session(children: [ready()], environment: ["DHP_DISABLE_FAST_INPUT": "1"])
        do { try await rig.session.start(); XCTFail("expected a failure") } catch {
            XCTAssertEqual(error as? FastInputError, .disabled)
        }
        XCTAssertEqual(rig.lease.starts, 0)
        XCTAssertEqual(rig.launcher.launches.count, 0)
    }

    // MARK: Commands

    func testCommandsAreWrittenInOrderAndAnsweredOk() async throws {
        let child = ready()
        let rig = session(children: [child])
        try await rig.session.start()
        try await rig.session.down(CGPoint(x: 0.25, y: 0.83))
        try await rig.session.move(CGPoint(x: 0.3, y: 0.8))
        try await rig.session.up(CGPoint(x: 0.3, y: 0.8))
        try await rig.session.tap(CGPoint(x: 0.75, y: 0.9), holdMs: 10)
        try await rig.session.button(.home)
        try await rig.session.ping()
        XCTAssertEqual(child.written, [
            "down 0.25000 0.83000", "move 0.30000 0.80000", "up 0.30000 0.80000",
            "tap 0.75000 0.90000 10", "button home", "ping",
        ])
        await rig.session.stop()
    }

    func testHidEdgesAreWrittenAndStoppingReleasesAButtonStillDown() async throws {
        let child = ready()
        let rig = session(children: [child])
        try await rig.session.start()
        try await rig.session.hid(page: 0x0C, usage: 0xE9, down: true)
        try await rig.session.hid(page: 0x0C, usage: 0xE9, down: false)
        try await rig.session.hid(page: 0x0C, usage: 0x30, down: true)
        await rig.session.stop()
        XCTAssertEqual(child.written, ["hid c e9 down", "hid c e9 up", "hid c 30 down", "hid c 30 up", "quit"])
    }

    func testEdgeCommandsAreEncodedAndAnErr7KeepsTheSessionUsable() async throws {
        XCTAssertEqual(FastInputCommand.edge(.down, x: 0.5, y: 0.995).line, "edge down 0.50000 0.99500")
        XCTAssertEqual(FastInputCommand.edge(.move, x: 0.5, y: 0.55).line, "edge move 0.50000 0.55000")
        XCTAssertEqual(FastInputCommand.edge(.up, x: 0.5, y: 0.55).line, "edge up 0.50000 0.55000")
        let child = FakeFastChild(startup: ["ready 0x101"]) { line in
            line.hasPrefix("edge") ? ["err 7 digitizer connection unavailable"] : ["ok"]
        }
        let rig = session(children: [child])
        try await rig.session.start()
        do {
            try await rig.session.edge(.down, CGPoint(x: 0.5, y: 0.995))
            XCTFail("should throw")
        } catch FastInputError.commandFailed(let code, _) {
            XCTAssertEqual(code, 7)
        }
        try await rig.session.ping()
        await rig.session.stop()
    }

    func testOneCommandIsOutstandingAtATime() async throws {
        let child = FakeFastChild(startup: ["ready 0x101"], respond: nil)
        let rig = session(children: [child])
        try await rig.session.start()
        let session = rig.session
        let first = Task { try await session.down(CGPoint(x: 0.1, y: 0.1)) }
        let sentFirst = await waitUntil { child.written.count == 1 }
        XCTAssertTrue(sentFirst)
        // Started only once the first is written: two free tasks start in no set order.
        let second = Task { try await session.up(CGPoint(x: 0.1, y: 0.1)) }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(child.written.count, 1, "the second waits for the first answer")
        child.emit("ok")
        let sentSecond = await waitUntil { child.written.count == 2 }
        XCTAssertTrue(sentSecond)
        child.emit("ok")
        try await first.value
        try await second.value
        XCTAssertEqual(child.written.map { $0.split(separator: " ")[0] }, ["down", "up"])
        await rig.session.stop()
    }

    func testAnErrorAnswerEndsTheSessionAndLaterCallsThrowIt() async throws {
        let child = FakeFastChild(startup: ["ready 0x101"]) { line in line.hasPrefix("move") ? ["err 1 send failed (5)"] : ["ok"] }
        let rig = session(children: [child])
        try await rig.session.start()
        try await rig.session.down(CGPoint(x: 0.5, y: 0.5))
        let expected = FastInputError.commandFailed(code: 1, message: "send failed (5)")
        do { try await rig.session.move(CGPoint(x: 0.5, y: 0.6)); XCTFail("expected a failure") } catch {
            XCTAssertEqual(error as? FastInputError, expected)
        }
        XCTAssertEqual(child.terminated, 1)
        XCTAssertEqual(rig.lease.stops, 1)
        do { try await rig.session.up(CGPoint(x: 0.5, y: 0.6)); XCTFail("expected a failure") } catch {
            XCTAssertEqual(error as? FastInputError, expected)
        }
        XCTAssertEqual(child.written.count, 2, "nothing more is sent")
    }

    func testAHelperThatEndsMidCommandIsReported() async throws {
        let child = FakeFastChild(startup: ["ready 0x101"]) { _ in [] }
        let rig = session(children: [child])
        try await rig.session.start()
        let session = rig.session
        let pending = Task { try await session.button(.home) }
        _ = await waitUntil { child.written.count == 1 }
        child.end()
        do { try await pending.value; XCTFail("expected a failure") } catch {
            XCTAssertEqual(error as? FastInputError, .helperExited)
        }
    }

    func testASilentHelperTimesTheCommandOut() async throws {
        let child = FakeFastChild(startup: ["ready 0x101"], respond: nil)
        // Once started, every timer of a second or more fires at once; the helper never answers.
        let armed = Flag()
        let rig = session(children: [child], sleep: { duration in
            if armed.isSet, duration >= .seconds(1) { return }
            try await Task.sleep(for: duration)
        })
        try await rig.session.start()
        armed.set()
        do { try await rig.session.ping(); XCTFail("expected a failure") } catch {
            XCTAssertEqual(error as? FastInputError, .commandTimedOut)
        }
    }

    func testCallsBeforeStartAndAfterStopThrow() async throws {
        let rig = session(children: [ready()])
        do { try await rig.session.ping(); XCTFail("expected a failure") } catch {
            XCTAssertEqual(error as? FastInputError, .notReady)
        }
        try await rig.session.start()
        await rig.session.stop()
        do { try await rig.session.ping(); XCTFail("expected a failure") } catch {
            XCTAssertEqual(error as? FastInputError, .stopped)
        }
    }

    // MARK: Moves

    func testMovesAreAtLeastOneOver120HzApart() async throws {
        let clock = ManualNow()
        let sleeper = SleepLog()
        let child = ready()
        let rig = session(children: [child], now: { clock.now }, sleep: { duration in
            sleeper.record(duration)
            // Timers of a second or more are the answer timeouts: they wait.
            if duration >= .seconds(1) { try await Task.sleep(for: duration); return }
            clock.advance(duration.timeInterval)
        })
        try await rig.session.start()
        for i in 0..<4 { try await rig.session.move(CGPoint(x: 0.1 * Double(i), y: 0.5)) }
        let paces = sleeper.durations.filter { $0 < .milliseconds(50) }
        XCTAssertEqual(paces.count, 3, "the first move goes at once, each later one waits its turn")
        for pace in paces { XCTAssertEqual(pace.timeInterval, 1.0 / 120.0, accuracy: 0.0005) }
        XCTAssertEqual(child.written.filter { $0.hasPrefix("move") }.count, 4)
        await rig.session.stop()
    }

    // MARK: Stopping

    func testStopSendsQuitThenEndsTheHelperAndTheLease() async throws {
        let child = ready()
        let rig = session(children: [child])
        try await rig.session.start()
        await rig.session.stop()
        XCTAssertEqual(child.written.last, "quit")
        XCTAssertFalse(child.isRunning)
        XCTAssertEqual(rig.lease.stops, 1)
        await rig.session.stop()
        XCTAssertEqual(rig.lease.stops, 1, "stopping twice is harmless")
    }

    func testTerminateNowEndsTheChildrenWithoutWaiting() async throws {
        let child = ready()
        let rig = session(children: [child])
        try await rig.session.start()
        rig.session.terminateNow()
        XCTAssertEqual(child.terminated, 1)
        XCTAssertEqual(rig.lease.terminations, 1)
        await rig.session.stop()
    }

    // MARK: The lease

    private static func makeKeeper(
        launcher: FakeFastLauncher,
        sleeper: ManualSleeper,
        timing: TunnelLeaseKeeper.Timing = .init(),
        developerDirectory: URL? = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"),
        onFailure: (@Sendable (FastInputError) -> Void)? = nil
    ) -> TunnelLeaseKeeper {
        let counter = NameCounter()
        return TunnelLeaseKeeper(
            devicectlURL: URL(fileURLWithPath: "/usr/bin/devicectl"),
            coreDeviceIdentifier: Self.device,
            developerDirectory: developerDirectory,
            launcher: launcher,
            timing: timing,
            sleep: sleeper.sleep,
            makeName: { "devicehubpro-lease-\(counter.next())" },
            onFailure: onFailure
        )
    }

    private func keeper(
        launcher: FakeFastLauncher,
        sleeper: ManualSleeper,
        timing: TunnelLeaseKeeper.Timing = .init(),
        developerDirectory: URL? = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"),
        onFailure: (@Sendable (FastInputError) -> Void)? = nil
    ) -> TunnelLeaseKeeper {
        Self.makeKeeper(launcher: launcher, sleeper: sleeper, timing: timing,
                        developerDirectory: developerDirectory, onFailure: onFailure)
    }

    func testTheLeaseChildsCommandLineIsExactlyOneFixedShape() {
        XCTAssertEqual(
            TunnelLeaseKeeper.argv(coreDeviceIdentifier: Self.device, name: "devicehubpro-lease-abc", sessionTimeout: 300),
            [
                "device", "notification", "observe",
                "--device", Self.device,
                "--name", "devicehubpro-lease-abc",
                "--session-timeout", "300",
                "--timeout", "305",
                "--quiet",
            ]
        )
        // The session timeout is always below the overall one.
        let argv = TunnelLeaseKeeper.argv(coreDeviceIdentifier: Self.device, name: "n", sessionTimeout: 60)
        XCTAssertEqual(argv?[8], "60")
        XCTAssertEqual(argv?[10], "65")
        // Anything but plain values is refused.
        XCTAssertNil(TunnelLeaseKeeper.argv(coreDeviceIdentifier: "not-a-uuid", name: "n", sessionTimeout: 300))
        XCTAssertNil(TunnelLeaseKeeper.argv(coreDeviceIdentifier: Self.device, name: "--flag x", sessionTimeout: 300))
        XCTAssertNil(TunnelLeaseKeeper.argv(coreDeviceIdentifier: Self.device, name: "", sessionTimeout: 300))
        XCTAssertNil(TunnelLeaseKeeper.argv(coreDeviceIdentifier: Self.device, name: "n", sessionTimeout: 1))
    }

    /// A SIGTERM kills the app without the sessions' stop paths; the handler calls
    /// `FastInputTermination.terminateAll()`, which ends the lease's child at once instead of
    /// leaving it to its session timeout (measured 2026-10-01: two were left after `pkill`).
    func testTerminateAllEndsALeaseChildWithoutTheSessionStopping() async throws {
        let launcher = FakeFastLauncher()
        let keeper = keeper(launcher: launcher, sleeper: ManualSleeper())
        try await keeper.start()
        let child = try XCTUnwrap(launcher.children.first)
        XCTAssertTrue(child.isRunning)
        FastInputTermination.terminateAll()
        XCTAssertFalse(child.isRunning)
        XCTAssertEqual(child.terminated, 1)
        // The keeper's own stop afterwards is harmless on a child that is gone.
        await keeper.stop()
        XCTAssertFalse(child.isRunning)
    }

    func testAStoppedLeaseLeavesNothingToTerminate() async throws {
        let launcher = FakeFastLauncher()
        let keeper = keeper(launcher: launcher, sleeper: ManualSleeper())
        try await keeper.start()
        await keeper.stop()
        let child = try XCTUnwrap(launcher.children.first)
        XCTAssertEqual(child.terminated, 1)
        FastInputTermination.terminateAll()
        XCTAssertEqual(child.terminated, 1)
    }

    func testTheLeaseLaunchesDevicectlWithItsDeveloperDirectoryAndDiscardsItsOutput() async throws {
        let launcher = FakeFastLauncher()
        let lease = keeper(launcher: launcher, sleeper: ManualSleeper())
        try await lease.start()
        XCTAssertEqual(launcher.launches.count, 1)
        let launch = launcher.launches[0]
        XCTAssertEqual(launch.executable.lastPathComponent, "devicectl")
        XCTAssertEqual(launch.arguments.prefix(3), ["device", "notification", "observe"])
        XCTAssertEqual(launch.environment, ["DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"])
        XCTAssertFalse(launch.wantsLines)
        await lease.stop()
    }

    func testTheLeaseRestartsBeforeItsSessionEndsAndUsesAFreshNameEachTime() async throws {
        let launcher = FakeFastLauncher()
        let sleeper = ManualSleeper()
        let lease = keeper(launcher: launcher, sleeper: sleeper)
        try await lease.start()
        _ = await waitUntil { sleeper.durations.count == 1 }
        XCTAssertEqual(sleeper.durations, [.seconds(270)], "300 s session minus the 30 s lead")

        sleeper.releaseNext()
        _ = await waitUntil { launcher.launches.count == 2 }
        // The successor runs before the old child is ended.
        XCTAssertEqual(launcher.children[0].terminated, 1)
        XCTAssertEqual(launcher.children[1].terminated, 0)
        let names = launcher.launches.map { $0.arguments[6] }
        XCTAssertEqual(Set(names).count, 2)
        _ = await waitUntil { sleeper.durations.count == 2 }
        XCTAssertEqual(sleeper.durations.last, .seconds(270))

        await lease.stop()
        XCTAssertEqual(launcher.children[1].terminated, 1)
        sleeper.releaseNext()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(launcher.launches.count, 2, "a stopped lease starts nothing")
    }

    func testAFailedRestartKeepsTheOldChildReportsOnceAndRetriesSoon() async throws {
        let launcher = FakeFastLauncher()
        launcher.failing = [2]
        let sleeper = ManualSleeper()
        let failures = Counter()
        var timing = TunnelLeaseKeeper.Timing()
        timing.retryDelay = 5
        let lease = keeper(launcher: launcher, sleeper: sleeper, timing: timing) { _ in failures.increment() }
        try await lease.start()
        _ = await waitUntil { sleeper.durations.count == 1 }
        sleeper.releaseNext()
        _ = await waitUntil { sleeper.durations.count == 2 }
        XCTAssertEqual(failures.value, 1)
        XCTAssertEqual(launcher.children[0].terminated, 0, "the old lease stays until a successor runs")
        XCTAssertEqual(sleeper.durations.last, .seconds(5))
        sleeper.releaseNext()
        _ = await waitUntil { launcher.launches.count == 3 }
        XCTAssertEqual(launcher.children[0].terminated, 1)
        await lease.stop()
    }

    /// Fast input and the native live view each want the tunnel open; one resident child serves
    /// both (measured live: two children for one phone, started the same second).
    func testTwoConsumersOfOnePhoneShareOneLeaseChildThatEndsWhenBothReleased() async throws {
        let launcher = FakeFastLauncher()
        let sleeper = ManualSleeper()
        let hub = SharedTunnelLeases()
        let make: @Sendable () -> any FastInputLease = {
            Self.makeKeeper(launcher: launcher, sleeper: sleeper)
        }
        let first = hub.lease(for: Self.device, make: make)
        let second = hub.lease(for: Self.device, make: make)
        try await first.start()
        try await second.start()
        try await second.start()   // a second start of one handle holds nothing more
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(hub.holders(for: Self.device), 2)

        await first.stop()
        XCTAssertEqual(launcher.children[0].terminated, 0, "one holder is left")
        XCTAssertTrue(launcher.children[0].isRunning)
        await first.stop()   // stopping twice releases once
        XCTAssertEqual(hub.holders(for: Self.device), 1)

        await second.stop()
        XCTAssertEqual(launcher.children[0].terminated, 1)
        XCTAssertEqual(hub.holders(for: Self.device), 0)

        // A later consumer starts a fresh one.
        let third = hub.lease(for: Self.device, make: make)
        try await third.start()
        XCTAssertEqual(launcher.launches.count, 2)
        third.terminateNow()
        XCTAssertEqual(launcher.children[1].terminated, 1)
    }

    /// A start that fails gives its hold back: no holder stays, the failed
    /// lease is ended, and the next consumer builds and starts a fresh one.
    func testAFailedStartIsRolledBackAndTheNextConsumerStartsFresh() async throws {
        let launcher = FakeFastLauncher()
        launcher.failing = [1]
        let sleeper = ManualSleeper()
        let hub = SharedTunnelLeases()
        let make: @Sendable () -> any FastInputLease = {
            Self.makeKeeper(launcher: launcher, sleeper: sleeper)
        }
        let first = hub.lease(for: Self.device, make: make)
        do {
            try await first.start()
            XCTFail("the scripted launch failure must surface")
        } catch {}
        XCTAssertEqual(hub.holders(for: Self.device), 0)
        XCTAssertEqual(launcher.launches.count, 1)

        let second = hub.lease(for: Self.device, make: make)
        try await second.start()
        XCTAssertEqual(launcher.launches.count, 2, "a fresh lease, not the failed one")
        XCTAssertEqual(hub.holders(for: Self.device), 1)
        await second.stop()
        XCTAssertEqual(hub.holders(for: Self.device), 0)
    }

    /// Two consumers waiting on one failing start both fail, and the single
    /// failed lease is ended once the last of them lets go.
    func testTwoConsumersOfAFailingStartBothFailAndTheLeaseEndsOnce() async throws {
        let lease = FakeLease()
        lease.startError = .launchFailed("scripted")
        let hub = SharedTunnelLeases()
        let make: @Sendable () -> any FastInputLease = { lease }
        let a = hub.lease(for: Self.device, make: make)
        let b = hub.lease(for: Self.device, make: make)

        async let ra: Void = a.start()
        async let rb: Void = b.start()
        var failures = 0
        do { try await ra } catch { failures += 1 }
        do { try await rb } catch { failures += 1 }

        XCTAssertEqual(failures, 2)
        XCTAssertEqual(hub.holders(for: Self.device), 0)
        XCTAssertEqual(lease.terminations, 1)
    }

    func testPhonesDoNotShareALease() async throws {
        let launcher = FakeFastLauncher()
        let hub = SharedTunnelLeases()
        let sleeper = ManualSleeper()
        let other = "22222222-2222-2222-2222-222222222222"
        let a = hub.lease(for: Self.device) { Self.makeKeeper(launcher: launcher, sleeper: sleeper) }
        let b = hub.lease(for: other) { Self.makeKeeper(launcher: launcher, sleeper: sleeper) }
        try await a.start()
        try await b.start()
        XCTAssertEqual(launcher.launches.count, 2)
        await a.stop()
        await b.stop()
    }

    func testStoppingTheLeaseEndsItsChild() async throws {
        let launcher = FakeFastLauncher()
        let lease = keeper(launcher: launcher, sleeper: ManualSleeper())
        try await lease.start()
        await lease.stop()
        XCTAssertEqual(launcher.children[0].terminated, 1)
    }
}

// MARK: - Small helpers

private final class ManualNow: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1000
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [Duration] = []
    var durations: [Duration] { lock.withLock { _durations } }
    func record(_ duration: Duration) { lock.withLock { _durations.append(duration) } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private final class NameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
