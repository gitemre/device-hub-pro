import AppKit
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// A simulator's Apps inspector and stage drops (`SimulatorAppsController`)
/// on a stub simctl that replays the real captures of `DeviceHubPro-UI-apps`
/// (`SimctlAppsFixtureTests`): the scopes over a real listing, the calls
/// each action makes, the device build refused before simctl runs, the
/// archive unzipped and cleaned up, and each kind of drop. No test reaches a
/// real simulator.
@MainActor
final class SimulatorAppsControllerTests: XCTestCase {
    /// The booted private-set device of the listing capture.
    private static let udid = "95D9676B-3317-4BA5-8CF6-3CDD0488CACA"
    private static let fixtureBundle = "dev.devicehubpro.fixture.apps"
    private static let apps = SimulatorFixtures.root.appendingPathComponent("apps", isDirectory: true)

    private struct Harness {
        let controller: SimulatorAppsController
        let status: StatusCenter
        let stub: StubTool
        let inventory: SimulatorInventory
    }

    /// `listapps` answers with the capture holding the user app unless
    /// `listapps` is given; `extra` arms come first. `devices` replaces the
    /// device listing's `cat` command.
    private func harness(listapps: String? = nil, devices: String? = nil, extra: String = "") async throws -> Harness {
        let u = Self.udid
        let stub = try makeStubTool("simctl", arms: """
        \(extra)
          *"list -j devices")
            \(devices ?? SimulatorFixtures.cat("simctl-list-j-devices.booted.json")) ;;
          *"list -j runtimes")
            \(SimulatorFixtures.cat("simctl-list-j-runtimes.json")) ;;
          *"list -j devicetypes")
            \(SimulatorFixtures.cat("simctl-list-j-devicetypes.json")) ;;
          *" listapps \(u)")
            \(listapps ?? SimulatorFixtures.cat("simctl-listapps.with-user-app.stdout.txt")) ;;
          *" install \(u) "*|*" uninstall \(u) "*|*" addmedia \(u) "*|*" openurl \(u) "*|*" keychain \(u) add-root-cert "*|*" launch \(u) "*)
            exit 0 ;;
        """)
        let inventory = SimulatorInventory(
            apple: .stubbed(
                simctl: stub,
                devicesDirectory: try makeTemporaryFolder("set"),
                logsDirectory: try makeTemporaryFolder("logs")
            ),
            preferences: AppPreferences(defaults: .scratch())
        )
        addTeardownBlock { @MainActor in inventory.stop() }
        await inventory.refresh()
        let status = StatusCenter()
        let controller = SimulatorAppsController(simulators: inventory, status: status, defaults: .scratch())
        // The capture's system apps name the iOS 27.0 runtime's own Applications
        // folder, which this Mac may have: the launch-prohibited apps
        // (`SimulatorRuntimeApps`, tested on its own) would add `appinfo` calls.
        controller.listsLaunchProhibitedApps = false
        controller.temporaryDirectory = try makeTemporaryFolder("unzip")
        addTeardownBlock { @MainActor in controller.clear() }
        return Harness(controller: controller, status: status, stub: stub, inventory: inventory)
    }

    private var u: String { Self.udid }

    /// The calls after the provider's own listings.
    private func appCalls(_ stub: StubTool) -> [String] {
        stub.calls.filter { !$0.hasPrefix("list -j") }
    }

    // MARK: - Scopes

    /// Device Hub's four scopes over the real listing: 39 system apps and
    /// the developer app.
    func testScopesOverARealListing() throws {
        let apps = try SimctlParsing.apps(fromListApps: String(
            contentsOf: SimulatorFixtures.url("simctl-listapps.with-user-app.stdout.txt"),
            encoding: .utf8
        ))
        func count(_ scope: SimulatorAppScope) -> Int { apps.filter(scope.admits).count }
        XCTAssertEqual(count(.all), 40)
        XCTAssertEqual(count(.developer), 1)
        XCTAssertEqual(count(.defaultApps), 39)
        XCTAssertEqual(count(.appClips), 0)
        XCTAssertEqual(SimulatorAppScope.allCases.map(\.label), ["All Apps", "App Clips", "Default", "Developer"])
        XCTAssertEqual(SimulatorAppScope.developer.emptyLabel, "No Developer Apps")
    }

    // MARK: - Listing

    func testLoadListsByTitleAndFilters() async throws {
        let harness = try await harness()
        let controller = harness.controller

        await controller.load(udid: u)

        XCTAssertEqual(controller.appsUDID, u)
        XCTAssertEqual(controller.apps.count, 40)
        let titles = controller.apps.map(\.title)
        // Device Hub's order is literal: "AQA Fixture" comes before "Activity…".
        XCTAssertEqual(titles, titles.sorted())
        XCTAssertNil(controller.loadProblem)

        controller.scope = .developer
        XCTAssertEqual(controller.filteredApps.map(\.bundleIdentifier), [Self.fixtureBundle])
        controller.scope = .all
        controller.filter = "fixture"
        XCTAssertEqual(controller.filteredApps.map(\.title), ["AQA Fixture"])
        controller.filter = "MOBILESAFARI"
        XCTAssertEqual(controller.filteredApps.map(\.bundleIdentifier), ["com.apple.mobilesafari"])
    }

    /// A simulator that is off: simctl refuses (SimError 405, exit 149) and
    /// the tab says to start it.
    func testAShutDownSimulatorHasNoList() async throws {
        let harness = try await harness(
            listapps: SimulatorFixtures.catToStderr("simctl-listapps-shutdown.stderr.txt") + "; exit 149"
        )
        await harness.controller.load(udid: u)
        XCTAssertEqual(harness.controller.apps, [])
        XCTAssertEqual(harness.controller.loadProblem, SimulatorAppsController.shutDownProblem)
    }

    /// A load cancelled with its view (`.task` ends) is not a failure: no
    /// "Could not list the apps" problem is shown.
    func testACancelledLoadShowsNoProblem() async throws {
        let harness = try await harness(listapps: "sleep 30")
        let controller = harness.controller
        let udid = u
        let task = Task { @MainActor in
            await controller.load(udid: udid)
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await task.value
        XCTAssertNil(controller.loadProblem)
    }

    /// A simulator with no user app has no `Containers/Bundle/Application`
    /// (CoreSimulator makes it with the first install; 28 of 29 simulators
    /// on the measuring Mac had none), so the watch opened nothing and an
    /// app installed from Xcode never showed. The list now follows the
    /// first app's folder and the later ones. The device listing is the
    /// real capture with its `dataPath`s pointed at a folder of the test.
    func testTheListFollowsAFirstInstalledAppAndLaterOnes() async throws {
        let data = try makeTemporaryFolder("data")
        let listing = try makeTemporaryFolder("listing").appendingPathComponent("devices.json")
        let escaped = data.path.replacingOccurrences(of: "/", with: "\\/")
        try String(contentsOf: SimulatorFixtures.url("simctl-list-j-devices.booted.json"), encoding: .utf8)
            .replacingOccurrences(of: #""dataPath" : "[^"]*""#, with: "\"dataPath\" : \"\(escaped)\"", options: .regularExpression)
            .write(to: listing, atomically: true, encoding: .utf8)
        let harness = try await harness(devices: "cat " + SimulatorFixtures.quoted(listing.path))
        XCTAssertEqual(harness.inventory.entry(udid: u)?.dataPath, data.path)
        let controller = harness.controller
        controller.changeDebounce = .milliseconds(20)
        func listings() -> Int { appCalls(harness.stub).filter { $0 == "listapps \(Self.udid)" }.count }

        await controller.load(udid: u)
        XCTAssertEqual(listings(), 1)

        let applications = data.appendingPathComponent("Containers/Bundle/Application", isDirectory: true)
        try FileManager.default.createDirectory(at: applications.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true)
        try await waitUntil { listings() == 2 }

        let second = applications.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try await waitUntil { listings() == 3 }

        try FileManager.default.removeItem(at: second)
        try await waitUntil { listings() == 4 }

        controller.clear()
        try FileManager.default.createDirectory(at: applications.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(listings(), 4, "a list no longer shown is not followed")
    }

    /// The deepest folder of the installed-apps path that exists.
    func testTheDeepestExistingFolder() throws {
        let root = try makeTemporaryFolder("deepest")
        let path = SimulatorAppsController.installedAppsPath
        XCTAssertEqual(SimulatorAppsController.deepestExistingFolder(of: path, in: root), root.path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Containers/Bundle"), withIntermediateDirectories: true)
        XCTAssertEqual(SimulatorAppsController.deepestExistingFolder(of: path, in: root), root.appendingPathComponent("Containers/Bundle").path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Containers/Bundle/Application"), withIntermediateDirectories: true)
        XCTAssertEqual(
            SimulatorAppsController.deepestExistingFolder(of: path, in: root),
            root.appendingPathComponent("Containers/Bundle/Application").path
        )
        XCTAssertNil(SimulatorAppsController.deepestExistingFolder(of: path, in: root.appendingPathComponent("missing")))
    }

    // MARK: - Actions

    func testUninstallReloadsTheList() async throws {
        let harness = try await harness()
        await harness.controller.load(udid: u)

        await harness.controller.uninstall(bundleIdentifier: Self.fixtureBundle, name: "AQA Fixture", udid: u)

        XCTAssertEqual(appCalls(harness.stub), ["listapps \(u)", "uninstall \(u) \(Self.fixtureBundle)", "listapps \(u)"])
        XCTAssertNil(harness.controller.activity)
        XCTAssertNil(harness.status.errorMessage)
    }

    func testTerminateOfAnAppThatIsNotRunning() async throws {
        let harness = try await harness(extra: """
          *" terminate \(u) "*)
            \(SimulatorFixtures.catToStderr("simctl-terminate-not-running.stderr.txt")); exit 3 ;;
        """)
        await harness.controller.load(udid: u)
        let safari = try XCTUnwrap(harness.controller.apps.first { $0.bundleIdentifier == "com.apple.mobilesafari" })

        await harness.controller.terminate(safari, udid: u)

        XCTAssertEqual(harness.status.statusMessage, "Safari is not running")
        XCTAssertNil(harness.status.errorMessage)
    }

    /// Show in Finder reveals the data container `listapps` named, without
    /// asking simctl again.
    func testShowDataContainerRevealsTheListedContainer() async throws {
        let harness = try await harness()
        await harness.controller.load(udid: u)
        var revealed: [URL] = []
        harness.controller.revealInFinder = { revealed.append($0) }
        let app = try XCTUnwrap(harness.controller.apps.first { $0.bundleIdentifier == Self.fixtureBundle })

        await harness.controller.showDataContainer(app, udid: u)

        XCTAssertEqual(revealed.map(\.lastPathComponent), ["2431DF93-C88C-4040-86CC-14B749A24295"])
        XCTAssertEqual(appCalls(harness.stub), ["listapps \(u)"])
    }

    // MARK: - Installs

    func testInstallingASimulatorBuild() async throws {
        let harness = try await harness()
        await harness.controller.load(udid: u)
        let app = Self.apps.appendingPathComponent("AQAAppsFixture.app", isDirectory: true)

        let installed = await harness.controller.install(app, udid: u)

        XCTAssertTrue(installed)
        XCTAssertEqual(appCalls(harness.stub), ["listapps \(u)", "install \(u) \(app.path)", "listapps \(u)"])
        XCTAssertEqual(harness.status.statusMessage, "Installed AQA Fixture")
        XCTAssertEqual(harness.controller.recents.entries.first?.package, Self.fixtureBundle)
        XCTAssertEqual(harness.controller.recents.entries.first?.name, "AQA Fixture")
        XCTAssertEqual(harness.controller.apps.count, 40, "the list is read again")
    }

    /// A device build is refused with its reason before simctl copies it.
    func testADeviceBuildIsRefusedBeforeSimctl() async throws {
        let harness = try await harness()
        let app = Self.apps.appendingPathComponent("AQAAppsFixture-device.app", isDirectory: true)

        let installed = await harness.controller.install(app, udid: u)

        XCTAssertFalse(installed)
        XCTAssertEqual(appCalls(harness.stub), [])
        let message = try XCTUnwrap(harness.status.errorMessage)
        XCTAssertTrue(message.contains("is built for iPhone and iPad devices, not for a simulator"), message)
        XCTAssertTrue(harness.controller.recents.entries.isEmpty)
    }

    /// An `.ipa` is unzipped into a temporary folder, its app installed from
    /// there, and the folder removed.
    func testAnArchiveIsUnzippedInstalledAndCleanedUp() async throws {
        let harness = try await harness()
        let work = try makeTemporaryFolder("ipa")
        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: Self.apps.appendingPathComponent("AQAAppsFixture.app"),
            to: payload.appendingPathComponent("AQAAppsFixture.app")
        )
        let ipa = work.appendingPathComponent("AQAAppsFixture.ipa")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--keepParent", payload.path, ipa.path]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        let installed = await harness.controller.install(ipa, udid: u)

        XCTAssertTrue(installed)
        XCTAssertEqual(appCalls(harness.stub).count, 1, "no list is shown, so none is read")
        let install = try XCTUnwrap(appCalls(harness.stub).first)
        XCTAssertTrue(install.hasPrefix("install \(u) \(harness.controller.temporaryDirectory.path)/DeviceHubPro-install-"), install)
        XCTAssertTrue(install.hasSuffix("/Payload/AQAAppsFixture.app"), install)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: harness.controller.temporaryDirectory.path),
            [],
            "the unzipped copy is removed"
        )
        XCTAssertEqual(harness.controller.recents.entries.first?.path, ipa.resolvingSymlinksInPath().path)
    }

    // MARK: - Drops

    /// Each kind of drop makes its call: a photo `addmedia`, a link
    /// `openurl`; a certificate waits for the confirmation (no call yet);
    /// anything else raises its reason.
    func testDropsRouteToTheirCalls() async throws {
        let harness = try await harness()
        var confirmations: [[URL]] = []
        let photo = URL(fileURLWithPath: "/tmp/drops/photo.png")
        let movie = URL(fileURLWithPath: "/tmp/drops/clip.mov")
        let certificate = URL(fileURLWithPath: "/tmp/drops/root.pem")
        let link = try XCTUnwrap(URL(string: "https://example.com/"))

        await harness.controller.handleDrop([photo, certificate, link, movie], udid: u) { confirmations.append($0) }

        XCTAssertEqual(appCalls(harness.stub), [
            "addmedia \(u) /tmp/drops/photo.png /tmp/drops/clip.mov",
            "openurl \(u) https://example.com/",
        ])
        XCTAssertEqual(confirmations, [[certificate]])
        XCTAssertNil(harness.status.errorMessage)

        await harness.controller.trustRootCertificates([certificate], udid: u)
        XCTAssertEqual(appCalls(harness.stub).last, "keychain \(u) add-root-cert /tmp/drops/root.pem")

        await harness.controller.handleDrop([URL(fileURLWithPath: "/tmp/drops/notes.txt")], udid: u) { _ in }
        XCTAssertEqual(
            harness.status.errorMessage,
            "A simulator can't use “notes.txt”. Drop an app (.app, .ipa or .zip), a photo, video or contact card, a certificate, or a link."
        )
    }

    /// Two certificates in one drop are asked about in one question, and
    /// both are trusted once the user agrees (only the last one was asked
    /// about, and the first dropped, when each replaced the other's question).
    func testADropsCertificatesAreAskedAboutTogether() async throws {
        let harness = try await harness()
        let first = URL(fileURLWithPath: "/tmp/drops/a.pem")
        let second = URL(fileURLWithPath: "/tmp/drops/b.cer")
        var confirmations: [[URL]] = []

        await harness.controller.handleDrop([first, second], udid: u) { confirmations.append($0) }

        XCTAssertEqual(confirmations, [[first, second]])
        XCTAssertEqual(appCalls(harness.stub), [], "nothing is trusted before the answer")
        let dialogs = SimulatorActionDialogs()
        dialogs.requestTrust(certificates: [first, second], udid: u, simulator: "iPhone 17 Pro")
        XCTAssertEqual(dialogs.confirmation?.title, "Trust 2 root certificates on \"iPhone 17 Pro\"?")
        XCTAssertEqual(
            dialogs.confirmation?.message.hasPrefix("\"a.pem\" and \"b.cer\": Safari and every app on the simulator will trust"),
            true,
            dialogs.confirmation?.message ?? ""
        )

        await harness.controller.trustRootCertificates([first, second], udid: u)

        XCTAssertEqual(appCalls(harness.stub), [
            "keychain \(u) add-root-cert /tmp/drops/a.pem",
            "keychain \(u) add-root-cert /tmp/drops/b.cer",
        ])
        XCTAssertEqual(harness.status.statusMessage, "Trusted 2 certificates")
        XCTAssertNil(harness.status.errorMessage)
    }

    /// Trust confirmed while the same drop's app still installs waits for
    /// the install and then runs (it was refused with "Wait for the current
    /// simulator operation to finish", and nothing was trusted).
    func testTrustConfirmedDuringAnInstallWaitsForIt() async throws {
        let harness = try await harness(extra: """
          *" install \(u) "*)
            sleep 1; exit 0 ;;
        """)
        harness.controller.busyPollInterval = .milliseconds(20)
        let certificate = URL(fileURLWithPath: "/tmp/drops/root.pem")
        let app = Self.apps.appendingPathComponent("AQAAppsFixture.app", isDirectory: true)
        var trust: Task<Void, Never>?
        let controller = harness.controller

        await controller.handleDrop([certificate, app], udid: u) { certificates in
            // The user answers while the install runs.
            trust = Task { @MainActor in await controller.trustRootCertificates(certificates, udid: Self.udid) }
        }
        await trust?.value

        XCTAssertEqual(appCalls(harness.stub), [
            "install \(u) \(app.path)",
            "keychain \(u) add-root-cert /tmp/drops/root.pem",
        ])
        XCTAssertEqual(harness.status.statusMessage, "Trusted root.pem")
        XCTAssertNil(harness.status.errorMessage)
        XCTAssertNil(controller.activity)
    }

    /// A link the Open URL sheet opens while an install runs (the slot is
    /// the controller's, so an install on any simulator) waits for the
    /// install and then opens. Since the two tracks merged it was
    /// refused with "Wait for the current simulator operation to finish"
    /// after the sheet had closed, and the link was not opened. A dropped
    /// link is still refused with that word, as every drop is.
    func testASheetsLinkDuringAnInstallWaitsForIt() async throws {
        let harness = try await harness(extra: """
          *" install \(u) "*)
            sleep 1; exit 0 ;;
        """)
        harness.controller.busyPollInterval = .milliseconds(20)
        let app = Self.apps.appendingPathComponent("AQAAppsFixture.app", isDirectory: true)
        let controller = harness.controller
        let install = Task { @MainActor in await controller.install(app, udid: Self.udid) }
        try await waitUntil { controller.isBusy }

        let dropped = await controller.openURL(try XCTUnwrap(URL(string: "https://example.com/?from=drop")), udid: u)
        XCTAssertFalse(dropped)
        XCTAssertEqual(harness.status.statusMessage, "Wait for the current simulator operation to finish")

        let opened = await controller.openURL("https://example.com/?from=sheet", udid: u)
        let installed = await install.value

        XCTAssertTrue(opened)
        XCTAssertTrue(installed)
        XCTAssertEqual(appCalls(harness.stub), [
            "install \(u) \(app.path)",
            "openurl \(u) https://example.com/?from=sheet",
        ])
        XCTAssertEqual(harness.status.statusMessage, "Opened https://example.com/?from=sheet")
        XCTAssertNil(harness.status.errorMessage)
        XCTAssertNil(controller.activity)
    }

    /// A drop's question that arrives while another shows waits its turn
    /// and shows once that one is answered; a question the user clicked
    /// for shows at once and puts the drop's back in front of the queue.
    func testDropQuestionsWaitTheirTurn() async throws {
        let dialogs = SimulatorActionDialogs()
        dialogs.queuedConfirmationDelay = .milliseconds(10)
        let a = URL(fileURLWithPath: "/tmp/drops/a.pem")
        let b = URL(fileURLWithPath: "/tmp/drops/b.pem")
        let app = try XCTUnwrap(try SimctlParsing.apps(fromListApps: String(
            contentsOf: SimulatorFixtures.url("simctl-listapps.with-user-app.stdout.txt"),
            encoding: .utf8
        )).first { $0.bundleIdentifier == Self.fixtureBundle })
        let first = SimulatorActionDialogs.Confirmation.trustCertificates(udid: u, simulator: "iPhone", certificates: [a])
        let second = SimulatorActionDialogs.Confirmation.trustCertificates(udid: u, simulator: "iPhone", certificates: [b])

        dialogs.requestTrust(certificates: [a], udid: u, simulator: "iPhone")
        dialogs.requestTrust(certificates: [b], udid: u, simulator: "iPhone")
        dialogs.requestTrust(certificates: [b], udid: u, simulator: "iPhone")
        XCTAssertEqual(dialogs.confirmation, first)
        XCTAssertEqual(dialogs.queuedConfirmations, [second], "asked once")

        dialogs.requestUninstall(app, udid: u)
        XCTAssertEqual(dialogs.confirmation, .uninstallApp(udid: u, bundleIdentifier: Self.fixtureBundle, name: "AQA Fixture"))
        XCTAssertEqual(dialogs.queuedConfirmations, [first, second])

        dialogs.finishConfirmation()
        dialogs.finishConfirmation()  // the alert's button and its binding both report the close
        XCTAssertNil(dialogs.confirmation, "not in the update that closes the last one")
        try await waitUntil { dialogs.confirmation == first }
        XCTAssertEqual(dialogs.queuedConfirmations, [second])

        dialogs.finishConfirmation()
        try await waitUntil { dialogs.confirmation == second }
        dialogs.finishConfirmation()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(dialogs.confirmation)
        XCTAssertEqual(dialogs.queuedConfirmations, [])
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A drag's items become URLs in their order: a Finder file and a link
    /// dragged from a browser; an item that is no URL is skipped.
    func testDragItemsBecomeURLs() async throws {
        let file = URL(fileURLWithPath: "/tmp/drops/photo.png")
        let link = try XCTUnwrap(URL(string: "https://example.com/a?b=1"))
        let urls = await SimulatorAppsController.urls(from: [
            NSItemProvider(object: file as NSURL),
            NSItemProvider(object: "plain text" as NSString),
            NSItemProvider(object: link as NSURL),
        ])
        XCTAssertEqual(urls, [file, link])
    }

    /// simctl's failures in the user's words: a file `addmedia` cannot
    /// import (exit 133) and a scheme no app opens (exit 115).
    func testDropFailuresAreExplained() async throws {
        let harness = try await harness(extra: """
          *" addmedia \(u) "*)
            \(SimulatorFixtures.catToStderr("simctl-addmedia-unsupported.stderr.txt", folder: "controls")); exit 133 ;;
          *" openurl \(u) "*)
            \(SimulatorFixtures.catToStderr("simctl-openurl-unknown-scheme.stderr.txt")); exit 115 ;;
        """)

        await harness.controller.addMedia([URL(fileURLWithPath: "/tmp/drops/photo.png")], udid: u)
        XCTAssertEqual(
            harness.status.errorMessage,
            "The simulator could not import “photo.png”: it takes photos, videos and contact cards."
        )

        await harness.controller.openURL(try XCTUnwrap(URL(string: "nosuchscheme-aqa://x")), udid: u)
        XCTAssertEqual(harness.status.errorMessage, "No app on the simulator opens nosuchscheme-aqa: links.")
    }

    /// A shut-down simulator also fails `addmedia` with 133, with no line
    /// naming the file: that is not called an unsupported file (it was).
    func testAddMediaOnAStoppedSimulatorIsNotAFileProblem() async throws {
        let harness = try await harness(extra: """
          *" addmedia \(u) "*)
            \(SimulatorFixtures.catToStderr("simctl-addmedia-shutdown.stderr.txt", folder: "controls")); exit 133 ;;
        """)

        await harness.controller.addMedia([URL(fileURLWithPath: "/tmp/drops/photo.png")], udid: u)

        XCTAssertEqual(harness.status.errorMessage, "Could not add “photo.png”: Multiple errors were returned; see stderr")
    }

    // MARK: - Confirmations

    /// Uninstalling an app and trusting a dropped root certificate are asked
    /// first, with the app's and the certificate's names.
    func testUninstallAndTrustAreConfirmed() throws {
        let dialogs = SimulatorActionDialogs()
        let app = try XCTUnwrap(try SimctlParsing.apps(fromListApps: String(
            contentsOf: SimulatorFixtures.url("simctl-listapps.with-user-app.stdout.txt"),
            encoding: .utf8
        )).first { $0.bundleIdentifier == Self.fixtureBundle })

        dialogs.requestUninstall(app, udid: u)
        XCTAssertEqual(dialogs.confirmation, .uninstallApp(udid: u, bundleIdentifier: Self.fixtureBundle, name: "AQA Fixture"))
        XCTAssertEqual(dialogs.confirmation?.title, "Uninstall \u{201C}AQA Fixture\u{201D}?")
        XCTAssertEqual(
            dialogs.confirmation?.message,
            "\"AQA Fixture\" (dev.devicehubpro.fixture.apps) and its data are removed from the simulator."
        )
        XCTAssertEqual(dialogs.confirmation?.confirmTitle, "Uninstall")

        let certificate = URL(fileURLWithPath: "/tmp/drops/root.pem")
        dialogs.finishConfirmation()
        dialogs.requestTrust(certificates: [certificate], udid: u, simulator: "iPhone 17 Pro")
        XCTAssertEqual(dialogs.confirmation?.udid, u)
        XCTAssertEqual(dialogs.confirmation?.title, "Trust \"root.pem\" as a root certificate on \"iPhone 17 Pro\"?")
        XCTAssertTrue(dialogs.confirmation?.message.contains("until the simulator's content and settings are reset") == true)
        XCTAssertEqual(dialogs.confirmation?.confirmTitle, "Trust")
    }

    // MARK: - Icons

    /// An app's icon comes from its bundle: the largest listed file.
    func testIconsAreReadFromTheBundle() async throws {
        let harness = try await harness()
        let bundlePath = Self.apps.appendingPathComponent("AQAAppsFixture.app").path
        let app = SimulatorApp(
            bundleIdentifier: Self.fixtureBundle,
            displayName: "AQA Fixture",
            bundleName: "AQAAppsFixture",
            executable: "AQAAppsFixture",
            shortVersion: "1.2",
            version: "7",
            applicationType: "User",
            path: bundlePath,
            dataContainer: nil,
            groupContainers: [:],
            isAppClip: false,
            isDeveloperApp: true,
            isFirstParty: false,
            isHidden: false,
            isRemovable: true,
            tags: []
        )
        XCTAssertNil(harness.controller.icon(for: app))

        await harness.controller.loadIcon(for: app)

        let icon = try XCTUnwrap(harness.controller.icon(for: app))
        XCTAssertEqual(icon.representations.first?.pixelsWide, 152)
    }
}
