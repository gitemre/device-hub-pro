import Foundation
import XCTest
@testable import DeviceHubProKit

/// `PhysicalControlSession` on a fake transport, a
/// fake process and a fake launcher: what it refuses to start without, how it
/// starts and polls, the requests it sends, its one queue and busy flag, the
/// one relaunch, and how it stops. No test starts `xcodebuild` or touches a
/// device.
final class PhysicalControlSessionTests: XCTestCase {
    private func started(_ harness: ControlHarness) async throws -> ControlHarness {
        try await harness.session.start()
        return harness
    }

    // MARK: Refusing to start

    func testNoTeamMeansNoBuildNoLaunchAndAClearMessage() async throws {
        for team in [nil, "", "  "] as [String?] {
            let harness = ControlHarness.make(team: team)
            do {
                try await harness.session.start()
                XCTFail("no team")
            } catch {
                XCTAssertEqual(error as? PhysicalControlError, .noTeam)
            }
            XCTAssertEqual(harness.provisioner.callCount, 0, "nothing was built")
            XCTAssertEqual(harness.launcher.launchCount, 0, "nothing was launched")
            XCTAssertEqual(harness.transport.requests.count, 0)
            let state = await harness.session.snapshot().state
            XCTAssertEqual(state, .failed(.noTeam))
            XCTAssertTrue(PhysicalControlError.noTeam.description.contains("Xcode"))
        }
    }

    func testNoTunnelAddressMeansNoLaunch() async throws {
        let harness = ControlHarness.make(address: nil)
        do {
            try await harness.session.start()
            XCTFail("no tunnel address")
        } catch {
            XCTAssertEqual(error as? PhysicalControlError, .noTunnelAddress)
        }
        XCTAssertEqual(harness.launcher.launchCount, 0)
        XCTAssertEqual(harness.endpoints.all.count, 0)
    }

    /// The Mac side refuses anything that is not the CoreDevice tunnel's
    /// address: the runner is never launched with it and no request is sent.
    func testAnAddressThatIsNotTheTunnelIsRefusedWithNoFallback() async throws {
        for address in ["192.168.1.20", "fe80::1%en0", "2001:db8::1", "::1", "localhost"] {
            let harness = ControlHarness.make(address: address)
            do {
                try await harness.session.start()
                XCTFail(address)
            } catch {
                XCTAssertEqual(error as? PhysicalControlError, .notATunnelAddress, address)
            }
            XCTAssertEqual(harness.launcher.launchCount, 0, address)
            XCTAssertEqual(harness.transport.requests.count, 0, address)
            XCTAssertFalse(PhysicalControlError.notATunnelAddress.description.contains(address))
        }
    }

    func testAFailedBuildOrLaunchIsReportedAndNothingRuns() async throws {
        let harness = ControlHarness.make()
        harness.provisioner.failure = .buildFailed("No profiles were found")
        do {
            try await harness.session.start()
            XCTFail("the build failed")
        } catch {
            XCTAssertEqual(error as? PhysicalControlError, .buildFailed("No profiles were found"))
        }
        XCTAssertEqual(harness.launcher.launchCount, 0)

        let launching = ControlHarness.make()
        launching.launcher.failure = .launchFailed("no xcodebuild")
        do {
            try await launching.session.start()
            XCTFail("the launch failed")
        } catch {
            XCTAssertEqual(error as? PhysicalControlError, .launchFailed("no xcodebuild"))
        }
        let state = await launching.session.snapshot().state
        XCTAssertEqual(state, .failed(.launchFailed("no xcodebuild")))
    }

    // MARK: Starting

    func testStartBuildsLaunchesAndPollsStatusUntilTheRunnerAnswers() async throws {
        let transport = FakeControlTransport()
        let polls = Counter()
        transport.setHandler { request in
            if request.path == "/status" {
                // Two refusals while the runner boots, then it answers.
                if polls.next() <= 2 { throw PhysicalControlError.transportFailed("refused") }
                return FakeControlTransport.json(["ok": true])
            }
            return try await FakeControlTransport.defaultHandler(request)
        }
        let harness = ControlHarness.make(candidates: ["com.apple.mobilesafari"], transport: transport)
        try await harness.session.start()

        XCTAssertEqual(harness.provisioner.callCount, 1)
        XCTAssertEqual(harness.provisioner.teams, [ControlHarness.team])
        XCTAssertEqual(harness.launcher.launchCount, 1)
        XCTAssertEqual(transport.requests(path: "/status").count, 3)
        XCTAssertEqual(transport.requests(path: "/screen").count, 1)
        let snapshot = await harness.session.snapshot()
        XCTAssertEqual(snapshot.state, .ready)
        XCTAssertEqual(snapshot.orientation, .portrait)
        let size = await harness.session.portraitSize()
        XCTAssertEqual(size, CGSize(width: 390, height: 844))

        // Progress and the states the app watches, in order.
        let states = harness.snapshots.all.map(\.state)
        XCTAssertEqual(states.first, .preparing("Preparing the input runner…"))
        XCTAssertTrue(states.contains(.starting("Starting the input runner…")))
        XCTAssertEqual(states.last, .ready)
        let revisions = harness.snapshots.all.map(\.revision)
        XCTAssertEqual(revisions, revisions.sorted(), "revisions only grow")
    }

    func testTheBuildsProgressReachesTheState() async throws {
        let harness = ControlHarness.make(wasBuilt: true)
        harness.provisioner.progress = ["Building the iPhone input runner (first time only, about a minute)…"]
        try await harness.session.start()
        let states = harness.snapshots.all.map(\.state)
        XCTAssertTrue(states.contains(.preparing("Building the iPhone input runner (first time only, about a minute)…")), "\(states)")
        XCTAssertTrue(states.contains(.starting("Installing the input runner on the iPhone…")), "the first run also installs")
    }

    /// The runner is launched with a fresh token and the tunnel address, and
    /// the transport gets the very same endpoint.
    func testTheLaunchAndTheTransportShareOneEndpointWithAFreshToken() async throws {
        let harness = try await started(ControlHarness.make())
        let configuration = try XCTUnwrap(harness.launcher.configurations.first)
        let endpoint = try XCTUnwrap(harness.endpoints.all.first)
        XCTAssertEqual(configuration.endpoint, endpoint)
        XCTAssertEqual(endpoint.address, ControlHarness.address)
        XCTAssertEqual(configuration.hardwareUDID, ControlHarness.udid)
        let environment = XcodebuildRunnerLauncher.environment(for: configuration)
        XCTAssertEqual(environment["TEST_RUNNER_DHP_BIND"], ControlHarness.address)
        let token = try XCTUnwrap(environment["TEST_RUNNER_DHP_TOKEN"])
        XCTAssertGreaterThanOrEqual(token.count, 32)

        let second = try await started(ControlHarness.make())
        let other = XcodebuildRunnerLauncher.environment(for: try XCTUnwrap(second.launcher.configurations.first))
        XCTAssertNotEqual(other["TEST_RUNNER_DHP_TOKEN"], token, "fresh per launch")
    }

    func testATokenSourceThatFailsMeansNoLaunch() async throws {
        let harness = ControlHarness.make(makeToken: { throw PhysicalControlError.tokenUnavailable })
        do {
            try await harness.session.start()
            XCTFail("no token")
        } catch {
            XCTAssertEqual(error as? PhysicalControlError, .tokenUnavailable)
        }
        XCTAssertEqual(harness.launcher.launchCount, 0)
    }

    func testARunnerThatNeverAnswersTimesOutAndIsStopped() async throws {
        let transport = FakeControlTransport { _ in throw PhysicalControlError.transportFailed("refused") }
        var timing = ControlHarness.fastTiming
        timing.warmStart = .milliseconds(120)
        let harness = ControlHarness.make(timing: timing, transport: transport)
        do {
            try await harness.session.start()
            XCTFail("timed out")
        } catch {
            XCTAssertEqual(error as? PhysicalControlError, .startTimedOut(seconds: 0))
        }
        let process = try XCTUnwrap(harness.launcher.processes.first)
        XCTAssertFalse(process.isRunning, "nothing keeps running")
        XCTAssertTrue(process.signals.contains("interrupt"))
        let state = await harness.session.snapshot().state
        if case .failed = state {} else { XCTFail("\(state)") }
    }

    /// A build that just ran also installs the runner on the phone, so the
    /// first start gets the long timeout and a cached one the short.
    func testTheFirstRunGetsTheLongTimeoutAndAWarmOneTheShort() async throws {
        func transport(readyAfter polls: Int) -> FakeControlTransport {
            let counter = Counter()
            return FakeControlTransport { request in
                if request.path == "/status", counter.next() <= polls {
                    throw PhysicalControlError.transportFailed("refused")
                }
                return try await FakeControlTransport.defaultHandler(request)
            }
        }
        var timing = ControlHarness.fastTiming
        timing.warmStart = .milliseconds(100)
        timing.firstRunStart = .seconds(5)
        timing.pollInterval = .milliseconds(10)

        // Ready after about 400 ms: too late for a warm start.
        let warm = ControlHarness.make(wasBuilt: false, timing: timing, transport: transport(readyAfter: 40))
        do {
            try await warm.session.start()
            XCTFail("the warm start timed out")
        } catch {
            guard case .startTimedOut = error as? PhysicalControlError else { return XCTFail("\(error)") }
        }
        // The same runner is fine on a first run.
        let first = ControlHarness.make(wasBuilt: true, timing: timing, transport: transport(readyAfter: 40))
        try await first.session.start()
        let state = await first.session.snapshot().state
        XCTAssertEqual(state, .ready)
    }

    func testARunnerThatExitsWhileStartingIsReportedWithItsRedactedOutput() async throws {
        let transport = FakeControlTransport { _ in throw PhysicalControlError.transportFailed("refused") }
        let launcher = FakeRunnerLauncher()
        let process = FakeRunnerProcess(tail: "AGENT_FATAL for team \(ControlHarness.team) on \(ControlHarness.udid) at \(ControlHarness.address)")
        process.die()
        launcher.queue(process)
        let harness = ControlHarness.make(transport: transport, launcher: launcher)
        do {
            try await harness.session.start()
            XCTFail("the runner exited")
        } catch let error as PhysicalControlError {
            guard case .runnerExited(let text) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(text.contains("AGENT_FATAL"))
            for secret in [ControlHarness.team, ControlHarness.udid, ControlHarness.address] {
                XCTAssertFalse(text.contains(secret), text)
                XCTAssertFalse(error.description.contains(secret))
            }
        }
    }

    func testAnUnauthorizedRunnerFailsTheStartWithoutRetrying() async throws {
        let transport = FakeControlTransport { _ in FakeControlTransport.json(["error": "unauthorized"], status: 401) }
        let harness = ControlHarness.make(transport: transport)
        do {
            try await harness.session.start()
            XCTFail("unauthorized")
        } catch {
            XCTAssertEqual(error as? PhysicalControlError, .unauthorized)
        }
        XCTAssertEqual(transport.requests(path: "/status").count, 1)
    }

    func testStartingTwiceStartsOnce() async throws {
        let harness = try await started(ControlHarness.make())
        try await harness.session.start()
        XCTAssertEqual(harness.launcher.launchCount, 1)
    }

    // MARK: Actions

    func testActionsBeforeStartAreRefused() async throws {
        let harness = ControlHarness.make()
        do {
            try await harness.session.tap(CGPoint(x: 1, y: 1))
            XCTFail("not started")
        } catch {
            XCTAssertEqual(error as? PhysicalControlError, .notReady)
        }
        XCTAssertEqual(harness.transport.requests.count, 0)
    }

    func testTapSwipeTypeAndButtonsSendTheRunnersRequests() async throws {
        let harness = try await started(ControlHarness.make())
        try await harness.session.tap(CGPoint(x: 195, y: 422))
        try await harness.session.swipe(from: CGPoint(x: 10, y: 700), to: CGPoint(x: 10, y: 300), duration: 0.4)
        try await harness.session.type("hello", bundleID: "com.apple.mobilenotes")
        try await harness.session.press(.home)
        try await harness.session.press(.volumeUp)
        try await harness.session.press(.volumeDown)

        let tap = try XCTUnwrap(harness.transport.requests(path: "/tap").first)
        XCTAssertEqual(tap, .tap(x: 195, y: 422, ref: nil), "no candidates: no refs, the runner uses Springboard")
        XCTAssertEqual(harness.transport.requests(path: "/swipe").first, .swipe(x1: 10, y1: 700, x2: 10, y2: 300, duration: 0.4, ref: nil))
        XCTAssertEqual(harness.transport.requests(path: "/type").first, .type(text: "hello", bundleID: "com.apple.mobilenotes"))
        XCTAssertEqual(harness.transport.requests(path: "/button"), [.button(.home), .button(.volumeUp), .button(.volumeDown)])
    }

    /// Siri and the App Switcher are two more of the closed request
    /// set; a phone without Siri (or an older runner without `/siri`) says
    /// "unsupported", softly, and the session goes on.
    func testSiriAndTheAppSwitcherSendTheirRequestsAndUnsupportedIsSoft() async throws {
        let harness = try await started(ControlHarness.make())
        try await harness.session.activateSiri(text: nil)
        try await harness.session.activateSiri(text: "hello")
        try await harness.session.showAppSwitcher()
        XCTAssertEqual(harness.transport.requests(path: "/siri"), [.siri(text: nil), .siri(text: "hello")])
        XCTAssertEqual(harness.transport.requests(path: "/appSwitcher"), [.appSwitcher])

        for status in [404, 500, 501] {
            harness.transport.setHandler { request in
                request.path == "/siri" ? FakeControlTransport.json(["error": "no siri"], status: status) : try await FakeControlTransport.defaultHandler(request)
            }
            do {
                try await harness.session.activateSiri(text: nil)
                XCTFail("unsupported")
            } catch {
                guard case .unsupported? = error as? PhysicalControlError else { return XCTFail("\(error)") }
                XCTAssertTrue((error as? PhysicalControlError)?.isSoft == true)
            }
        }
        let state = await harness.session.snapshot().state
        XCTAssertEqual(state, .ready, "an unsupported Siri does not end the session")

        // Any other action keeps its own mapping: a 500 on the App Switcher is an action failure.
        harness.transport.setHandler { request in
            request.path == "/appSwitcher" ? FakeControlTransport.json(["error": "boom"], status: 500) : try await FakeControlTransport.defaultHandler(request)
        }
        do {
            try await harness.session.showAppSwitcher()
            XCTFail("500")
        } catch {
            XCTAssertEqual(error as? PhysicalControlError, .actionFailed(status: 500, message: "boom"))
        }
    }

    func testTapSendsTheFilteredCandidatesAsRefsInOneRequest() async throws {
        let transport = FakeControlTransport()
        let harness = try await started(ControlHarness.make(
            candidates: ["com.apple.mobilesafari", "com.apple.Preferences", "com.apple.springboard", "com.devicehubpro.agent.uitests.xctrunner", "com.apple.mobilesafari"],
            transport: transport
        ))
        let before = transport.requests.count
        try await harness.session.tap(CGPoint(x: 5, y: 6))
        XCTAssertEqual(transport.requests.count, before + 1, "one request, no /foreground first")
        XCTAssertEqual(transport.requests(path: "/foreground").count, 0)
        // Springboard is never a candidate, nor the runner itself (a lookup of
        // its own bundle hangs the runner), and each id once.
        XCTAssertEqual(transport.requests(path: "/tap").first,
                       .tap(x: 5, y: 6, ref: nil, refs: ["com.apple.mobilesafari", "com.apple.Preferences"]))
        try await harness.session.swipe(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 3, y: 4), duration: 0.3)
        XCTAssertEqual(transport.requests(path: "/swipe").first,
                       .swipe(x1: 1, y1: 2, x2: 3, y2: 4, duration: 0.3, ref: nil, refs: ["com.apple.mobilesafari", "com.apple.Preferences"]))
        XCTAssertEqual(transport.requests(path: "/foreground").count, 0)
    }

    private func awaitTrue(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testASpringboardAnswerRefreshesTheCandidatesOnceInTheBackground() async throws {
        let source = CandidateSource(["com.a"])
        let transport = FakeControlTransport { request in
            if request.path == "/tap" { return FakeControlTransport.json(["ok": true, "ref": "com.apple.springboard"]) }
            return try await FakeControlTransport.defaultHandler(request)
        }
        var timing = ControlHarness.fastTiming
        timing.missRefresh = .seconds(60)
        let harness = try await started(ControlHarness.make(
            candidateSource: { source.read() }, timing: timing, transport: transport))
        try await harness.session.tap(CGPoint(x: 1, y: 1))
        await awaitTrue { source.calls >= 2 }
        source.set(["com.b", "com.a"])
        let callsAfterFirstMiss = source.calls
        XCTAssertGreaterThanOrEqual(callsAfterFirstMiss, 2, "the miss reloaded the list")
        try await harness.session.tap(CGPoint(x: 2, y: 2))
        // A second miss inside missRefresh does not refresh again: the list the
        // second tap used is the cached one from the first refresh.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(source.calls, callsAfterFirstMiss)
        let taps = transport.requests(path: "/tap")
        XCTAssertEqual(taps.first, .tap(x: 1, y: 1, ref: nil, refs: ["com.a"]))
        XCTAssertEqual(taps.last, .tap(x: 2, y: 2, ref: nil, refs: ["com.a"]))
    }

    func testAfterTheRefreshTheNextTapCarriesTheNewList() async throws {
        let source = CandidateSource(["com.a"])
        let transport = FakeControlTransport { request in
            if request.path == "/tap" { source.set(["com.b"]); return FakeControlTransport.json(["ok": true, "ref": "com.apple.springboard"]) }
            return try await FakeControlTransport.defaultHandler(request)
        }
        let harness = try await started(ControlHarness.make(candidateSource: { source.read() }, transport: transport))
        try await harness.session.tap(CGPoint(x: 1, y: 1))
        for _ in 0..<200 {
            let ids = await harness.session.candidateIDs()
            if ids == ["com.b"] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await harness.session.tap(CGPoint(x: 2, y: 2))
        XCTAssertEqual(transport.requests(path: "/tap").last, .tap(x: 2, y: 2, ref: nil, refs: ["com.b"]))
    }

    func testAnAppAnswerMovesItToTheFrontOfTheList() async throws {
        let transport = FakeControlTransport { request in
            if request.path == "/tap" { return FakeControlTransport.json(["ok": true, "ref": "com.c"]) }
            return try await FakeControlTransport.defaultHandler(request)
        }
        let harness = try await started(ControlHarness.make(candidates: ["com.a", "com.b", "com.c"], transport: transport))
        try await harness.session.tap(CGPoint(x: 1, y: 1))
        try await harness.session.tap(CGPoint(x: 2, y: 2))
        XCTAssertEqual(transport.requests(path: "/tap").last,
                       .tap(x: 2, y: 2, ref: nil, refs: ["com.c", "com.a", "com.b"]))
    }

    func testTheCandidateListIsCappedAt400() async throws {
        XCTAssertEqual(PhysicalControlSession.maximumCandidates, 400)
        let many = (0..<450).map { "com.x\($0)" }
        let harness = try await started(ControlHarness.make(candidates: many))
        let ids = await harness.session.candidateIDs()
        XCTAssertEqual(ids, Array(many.prefix(400)))
    }

    /// com.apple.HangHUD always reports the foreground; as a reference the
    /// tap never returned (measured, iPhone 12 / iOS 27.0).
    func testAlwaysForegroundOverlaysAreNeverCandidates() async throws {
        let harness = try await started(ControlHarness.make(candidates: ["com.apple.HangHUD", "com.apple.Preferences"]))
        let ids = await harness.session.candidateIDs()
        XCTAssertEqual(ids, ["com.apple.Preferences"])
        _ = try await harness.session.foreground(ids: ["com.apple.HangHUD"])
        XCTAssertEqual(harness.transport.requests(path: "/foreground").count, 0, "never asked about an overlay")
    }

    func testLiveCandidatesListThePhonesAppsFirstThenTheAppleOnesNotYetListed() {
        let merged = PhysicalControlSession.mergedCandidates(installed: ["com.x", "com.apple.mobilesafari"])
        XCTAssertEqual(Array(merged.prefix(2)), ["com.x", "com.apple.mobilesafari"])
        XCTAssertEqual(merged.filter { $0 == "com.apple.mobilesafari" }.count, 1)
        XCTAssertTrue(merged.contains("com.apple.Preferences"))
        XCTAssertEqual(PhysicalControlSession.mergedCandidates(installed: []), PhysicalControlSession.commonAppleBundleIdentifiers)
    }

    func testForegroundAppStillUsesTheForegroundLookup() async throws {
        let transport = FakeControlTransport { request in
            if request.path == "/foreground" {
                return FakeControlTransport.json(["foreground": ["com.apple.Preferences"]])
            }
            return try await FakeControlTransport.defaultHandler(request)
        }
        let harness = try await started(ControlHarness.make(
            candidates: ["com.apple.mobilesafari", "com.apple.Preferences", "com.apple.springboard"],
            transport: transport
        ))
        let front = try await harness.session.foregroundApp()
        XCTAssertEqual(front, "com.apple.Preferences")
        XCTAssertEqual(transport.requests(path: "/foreground").first?.query["ids"], "com.apple.mobilesafari,com.apple.Preferences")
    }

    func testTheRunnersTimingAndReferenceAreKept() async throws {
        let transport = FakeControlTransport { request in
            if request.path == "/tap" {
                return FakeControlTransport.json([
                    "ok": true, "t0": 1.0, "ref": "com.apple.Preferences",
                    "timing": ["resolveMs": 12.5, "actionMs": 210.25],
                ])
            }
            return try await FakeControlTransport.defaultHandler(request)
        }
        let harness = try await started(ControlHarness.make(candidates: ["com.apple.Preferences"], transport: transport))
        var none = await harness.session.lastActionTiming()
        XCTAssertNil(none)
        try await harness.session.tap(CGPoint(x: 5, y: 6))
        let recorded = await harness.session.lastActionTiming()
        let timing = try XCTUnwrap(recorded)
        XCTAssertEqual(timing.kind, .tap)
        XCTAssertEqual(timing.runnerResolveMs, 12.5)
        XCTAssertEqual(timing.runnerActionMs, 210.25)
        XCTAssertEqual(timing.reference, "com.apple.Preferences")
        XCTAssertEqual(timing.runnerTapStart, 1.0)
        XCTAssertGreaterThanOrEqual(timing.roundTripMs, 0)

        // An answer without timing (an older runner) still works, with nil fields.
        transport.setHandler { request in
            request.path == "/swipe" ? FakeControlTransport.json(["ok": true]) : try await FakeControlTransport.defaultHandler(request)
        }
        try await harness.session.swipe(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 3, y: 4), duration: 0.3)
        none = await harness.session.lastActionTiming()
        XCTAssertEqual(none?.kind, .swipe)
        XCTAssertNil(none?.runnerResolveMs)
        XCTAssertNil(none?.runnerActionMs)
        XCTAssertNil(none?.reference)
    }

    func testNoCandidatesSendsNoRefsAndForegroundLookupsIgnoreTheRunnersOwnID() async throws {
        let harness = try await started(ControlHarness.make(candidates: ["com.apple.mobilesafari"]))
        try await harness.session.tap(CGPoint(x: 5, y: 6))
        XCTAssertEqual(harness.transport.requests(path: "/tap").first, .tap(x: 5, y: 6, ref: nil, refs: ["com.apple.mobilesafari"]))
        let none = try await harness.session.foreground(ids: [])
        XCTAssertEqual(none, [])
        let ownID = try await harness.session.foreground(ids: ["com.devicehubpro.agent.uitests.xctrunner"])
        XCTAssertEqual(ownID, [])
        XCTAssertEqual(harness.transport.requests(path: "/foreground").count, 0, "none for the runner's own id or an empty list")
    }

    func testOrientationIsReadAndSetWithTheReadBack() async throws {
        let harness = try await started(ControlHarness.make())
        let read = try await harness.session.orientation()
        XCTAssertEqual(read, .portrait)
        let set = try await harness.session.setOrientation(.landscapeLeft)
        XCTAssertEqual(set, .landscapeLeft)
        XCTAssertEqual(harness.transport.requests(path: "/orientation").last, .setOrientation(.landscapeLeft))
        let snapshot = await harness.session.snapshot()
        XCTAssertEqual(snapshot.orientation, .landscapeLeft, "the app's chrome follows this")
    }

    func testAnActionsErrorsAreTypedAndOnlyTheRunnersOwnEndControl() async throws {
        let harness = try await started(ControlHarness.make())
        // 409: the app shows no keyboard: soft, the session goes on.
        harness.transport.setHandler { request in
            request.path == "/type" ? FakeControlTransport.json(["error": "no keyboard is showing"], status: 409) : try await FakeControlTransport.defaultHandler(request)
        }
        do {
            try await harness.session.type("a", bundleID: "com.apple.mobilenotes")
            XCTFail("no keyboard")
        } catch {
            XCTAssertEqual(error as? PhysicalControlError, .keyboardNotShowing)
            XCTAssertTrue((error as? PhysicalControlError)?.isSoft == true)
        }
        var state = await harness.session.snapshot().state
        XCTAssertEqual(state, .ready)

        // 500: an XCTest issue; the runner's message reaches the caller.
        harness.transport.setHandler { request in
            request.path == "/tap" ? FakeControlTransport.json(["error": "Failed to synthesize"], status: 500) : try await FakeControlTransport.defaultHandler(request)
        }
        do {
            try await harness.session.tap(CGPoint(x: 1, y: 1))
            XCTFail("500")
        } catch {
            XCTAssertEqual(error as? PhysicalControlError, .actionFailed(status: 500, message: "Failed to synthesize"))
        }
        state = await harness.session.snapshot().state
        XCTAssertEqual(state, .ready, "an action's failure does not end the session; the app turns Control off")

        // 401: the runner refuses the token: the session ends.
        harness.transport.setHandler { request in
            request.path == "/tap" ? FakeControlTransport.json(["error": "unauthorized"], status: 401) : try await FakeControlTransport.defaultHandler(request)
        }
        do {
            try await harness.session.tap(CGPoint(x: 1, y: 1))
            XCTFail("401")
        } catch {
            XCTAssertEqual(error as? PhysicalControlError, .unauthorized)
        }
        state = await harness.session.snapshot().state
        XCTAssertEqual(state, .failed(.unauthorized))
        let process = try XCTUnwrap(harness.launcher.processes.first)
        XCTAssertFalse(process.isRunning)
    }

    // MARK: One queue, one busy flag

    func testActionsRunOneAtATimeInOrderAndAThirdIsBusy() async throws {
        let gate = Gate()
        let transport = FakeControlTransport { request in
            if request.path == "/tap" { await gate.wait() }
            return try await FakeControlTransport.defaultHandler(request)
        }
        let harness = try await started(ControlHarness.make(transport: transport))

        let first = Task { try await harness.session.tap(CGPoint(x: 1, y: 1)) }
        let arrived = await waitUntil { transport.requests(path: "/tap").count == 1 }
        XCTAssertTrue(arrived)
        var snapshot = await harness.session.snapshot()
        XCTAssertTrue(snapshot.isBusy)

        // One waits behind the one in flight ...
        let second = Task { try await harness.session.tap(CGPoint(x: 2, y: 2)) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(transport.requests(path: "/tap").count, 1, "the second has not started: one queue")
        // ... and a third is refused.
        do {
            try await harness.session.tap(CGPoint(x: 3, y: 3))
            XCTFail("busy")
        } catch {
            XCTAssertEqual(error as? PhysicalControlError, .busy)
        }

        await gate.open()
        try await first.value
        try await second.value
        let taps = transport.requests(path: "/tap")
        XCTAssertEqual(taps, [.tap(x: 1, y: 1, ref: nil), .tap(x: 2, y: 2, ref: nil)], "in order, the refused one never sent")
        snapshot = await harness.session.snapshot()
        XCTAssertFalse(snapshot.isBusy)
        XCTAssertTrue(harness.snapshots.all.contains { $0.isBusy })
        XCTAssertEqual(harness.snapshots.all.last?.isBusy, false)
    }

    // MARK: Runner death

    func testARunnerThatDiedIsStartedOnceAgainAndTheActionIsNotRepeated() async throws {
        let launcher = FakeRunnerLauncher()
        let harness = try await started(ControlHarness.make(launcher: launcher))
        let first = try XCTUnwrap(launcher.processes.first)
        let firstToken = XcodebuildRunnerLauncher.environment(for: launcher.configurations[0])["TEST_RUNNER_DHP_TOKEN"]

        // The runner dies; the next action meets a dead connection.
        first.die()
        let tapsBefore = harness.transport.requests(path: "/tap").count
        harness.transport.setHandler { request in
            if request.path == "/tap" { throw PhysicalControlError.transportFailed("reset") }
            return try await FakeControlTransport.defaultHandler(request)
        }
        do {
            try await harness.session.tap(CGPoint(x: 1, y: 1))
            XCTFail("the runner had died")
        } catch {
            XCTAssertEqual(error as? PhysicalControlError, .runnerRestarted)
            XCTAssertTrue((error as? PhysicalControlError)?.isSoft == true)
        }
        XCTAssertEqual(launcher.launchCount, 2, "one relaunch")
        XCTAssertEqual(harness.transport.requests(path: "/tap").count, tapsBefore + 1, "the tap was not repeated")
        let secondToken = XcodebuildRunnerLauncher.environment(for: launcher.configurations[1])["TEST_RUNNER_DHP_TOKEN"]
        XCTAssertNotEqual(firstToken, secondToken, "a relaunch has a fresh token")
        var state = await harness.session.snapshot().state
        XCTAssertEqual(state, .ready)

        // The second death ends it: no third launch.
        launcher.processes[1].die(tail: "died again")
        do {
            try await harness.session.tap(CGPoint(x: 1, y: 1))
            XCTFail("the runner died again")
        } catch {
            guard case .runnerExited(let text) = error as? PhysicalControlError else { return XCTFail("\(error)") }
            XCTAssertEqual(text, "died again")
        }
        XCTAssertEqual(launcher.launchCount, 2)
        state = await harness.session.snapshot().state
        if case .failed(.runnerExited) = state {} else { XCTFail("\(state)") }
        do {
            try await harness.session.tap(CGPoint(x: 1, y: 1))
            XCTFail("failed sessions take no actions")
        } catch {
            XCTAssertEqual(error as? PhysicalControlError, .notReady)
        }
    }

    func testAnIdleRunnerThatDiesIsFoundByTheHealthCheck() async throws {
        let launcher = FakeRunnerLauncher()
        let harness = try await started(ControlHarness.make(launcher: launcher))
        launcher.processes[0].die()
        await harness.session.checkHealth()
        XCTAssertEqual(launcher.launchCount, 2)
        var state = await harness.session.snapshot().state
        XCTAssertEqual(state, .ready)
        // A healthy runner is left alone.
        await harness.session.checkHealth()
        XCTAssertEqual(launcher.launchCount, 2)
        launcher.processes[1].die()
        await harness.session.checkHealth()
        XCTAssertEqual(launcher.launchCount, 2, "only one relaunch")
        state = await harness.session.snapshot().state
        if case .failed = state {} else { XCTFail("\(state)") }
    }

    func testARelaunchThatFailsEndsTheSession() async throws {
        let launcher = FakeRunnerLauncher()
        let harness = try await started(ControlHarness.make(launcher: launcher))
        launcher.processes[0].die()
        launcher.failure = .launchFailed("gone")
        await harness.session.checkHealth()
        let state = await harness.session.snapshot().state
        XCTAssertEqual(state, .failed(.launchFailed("gone")))
    }

    // MARK: Stopping

    func testStopPostsStopThenLeavesAProcessThatEndedAlone() async throws {
        let launcher = FakeRunnerLauncher()
        let harness = try await started(ControlHarness.make(launcher: launcher))
        let process = try XCTUnwrap(launcher.processes.first)
        // The runner ends itself when it is told to stop.
        harness.transport.setHandler { request in
            if request.path == "/stop" { process.die() }
            return try await FakeControlTransport.defaultHandler(request)
        }
        await harness.session.stop()
        XCTAssertEqual(harness.transport.requests(path: "/stop").count, 1)
        XCTAssertEqual(process.signals, [], "a runner that stopped politely is not signalled")
        let state = await harness.session.snapshot().state
        XCTAssertEqual(state, .stopped)
        await harness.session.stop()
        XCTAssertEqual(harness.transport.requests(path: "/stop").count, 1, "idempotent")
    }

    func testAStubbornRunnerIsInterruptedThenTerminatedThenKilled() async throws {
        let launcher = FakeRunnerLauncher()
        launcher.queue(FakeRunnerProcess(endsOn: ["kill"]))
        let harness = try await started(ControlHarness.make(launcher: launcher))
        await harness.session.stop()
        let process = try XCTUnwrap(launcher.processes.first)
        XCTAssertEqual(process.signals, ["interrupt", "terminate", "kill"], "SIGINT, SIGTERM, then SIGKILL")
        XCTAssertFalse(process.isRunning)

        let interrupted = FakeRunnerLauncher()
        let second = try await started(ControlHarness.make(launcher: interrupted))
        await second.session.stop()
        XCTAssertEqual(interrupted.processes[0].signals, ["interrupt"], "SIGINT ends a well-behaved runner")
    }

    func testTerminateNowInterruptsTheChildAtOnce() async throws {
        let launcher = FakeRunnerLauncher()
        let harness = try await started(ControlHarness.make(launcher: launcher))
        harness.session.terminateNow()
        XCTAssertEqual(launcher.processes[0].signals, ["interrupt"])
    }

    func testStopDuringAStartCancelsIt() async throws {
        let transport = FakeControlTransport { _ in throw PhysicalControlError.transportFailed("refused") }
        let harness = ControlHarness.make(transport: transport)
        let starting = Task { try await harness.session.start() }
        let launched = await waitUntil { harness.launcher.launchCount == 1 }
        XCTAssertTrue(launched)
        await harness.session.stop()
        do {
            try await starting.value
            XCTFail("the start was cancelled")
        } catch {
            XCTAssertEqual(error as? PhysicalControlError, .stopped)
        }
        XCTAssertFalse(harness.launcher.processes[0].isRunning)
        let state = await harness.session.snapshot().state
        XCTAssertEqual(state, .stopped)
    }

    func testASessionCanStartAgainAfterAStop() async throws {
        let harness = try await started(ControlHarness.make())
        await harness.session.stop()
        try await harness.session.start()
        XCTAssertEqual(harness.launcher.launchCount, 2)
        let state = await harness.session.snapshot().state
        XCTAssertEqual(state, .ready)
    }
}

// MARK: - Small helpers

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// Holds actions until it is opened.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
