import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The Apps tab of an enabled physical device: the app list
/// from `device info apps`, Launch, Terminate (the pid comes from `device
/// info processes`), Uninstall, Install from a `.app` or `.ipa`, Open URL and
/// the container files, all against the stub devicectl replaying the
/// captures of the dedicated test iPhone.
@MainActor
final class PhysicalAppsControllerTests: XCTestCase {
    private static let udid = PhysicalFixtures.udid
    private static let bundleID = "com.devicehubpro.verifier"

    private struct Harness {
        let stub: StubTool
        let inventory: ApplePhysicalInventory
        let controller: PhysicalAppsController
        let status: StatusCenter
        let picker: TestPicker
        let temporary: URL
    }

    /// The captures every Apps test needs: the app list after the install,
    /// and `extra` arms first.
    private func harness(extra: String = "", enabled: Bool = true) async throws -> Harness {
        let stub = try makePhysicalStub(extra: """
          \(extra)
          *"device info apps"*)
            \(PhysicalFixtures.json("devicectl-info-apps-after-install.json")) ;;
        """)
        let inventory = try await makeListedPhysicalInventory(stub: stub, enabled: enabled)
        let status = StatusCenter()
        let picker = TestPicker()
        let temporary = try makeTemporaryFolder("apps")
        let controller = PhysicalAppsController(
            inventory: inventory,
            status: status,
            picker: picker,
            temporaryDirectory: temporary
        )
        controller.busyPollInterval = .milliseconds(5)
        return Harness(stub: stub, inventory: inventory, controller: controller, status: status, picker: picker, temporary: temporary)
    }

    /// The processes capture with the verifier's process (the executable
    /// and pid of the launch capture) added, and an app extension of it
    /// (SYNTHETIC: the capture holds no verifier process, only the shape
    /// `Weather.app/PlugIns/WeatherWidget.appex/WeatherWidget` proves).
    private func processesJSON() throws -> String {
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try PhysicalFixtures.data("devicectl-info-processes.json")) as? [String: Any]
        )
        var result = try XCTUnwrap(document["result"] as? [String: Any])
        var processes = try XCTUnwrap(result["runningProcesses"] as? [[String: Any]])
        let bundle = "file:///private/var/containers/Bundle/Application/99A596BC-82D8-4C65-BBD0-944CE7560FDE/DeviceHubProVerifier.app"
        processes.append(["executable": "\(bundle)/PlugIns/Widget.appex/Widget", "processIdentifier": 5000])
        processes.append(["executable": "\(bundle)/DeviceHubProVerifier", "processIdentifier": 4951])
        result["runningProcesses"] = processes
        document["result"] = result
        let file = try makeTemporaryFolder("procs").appendingPathComponent("processes.json")
        try JSONSerialization.data(withJSONObject: document).write(to: file)
        return file.path
    }

    private func verifierApp() throws -> PhysicalApp {
        let list = try DevicectlJSON.decode(
            DevicectlAppList.self, from: try PhysicalFixtures.data("devicectl-info-apps-after-install.json")
        ).value
        return PhysicalApp(try XCTUnwrap(list.apps.first))
    }

    // MARK: - Listing

    /// The list maps the real `apps[]` entry: name, bundle identifier,
    /// version, removable and container-accessible flags, the bundle path.
    func testAppListMapping() async throws {
        let h = try await harness()

        await h.controller.load(udid: Self.udid)

        let app = try XCTUnwrap(h.controller.apps.first)
        XCTAssertEqual(h.controller.apps.count, 1)
        XCTAssertEqual(app.title, "AQA Verifier")
        XCTAssertEqual(app.bundleIdentifier, Self.bundleID)
        XCTAssertEqual(app.displayVersion, "1.0")
        XCTAssertTrue(app.isRemovable)
        XCTAssertTrue(app.isDeveloperApp)
        XCTAssertTrue(app.containerAccessible)
        XCTAssertEqual(
            app.bundlePath,
            "/var/containers/Bundle/Application/99A596BC-82D8-4C65-BBD0-944CE7560FDE/DeviceHubProVerifier.app"
        )
        XCTAssertEqual(app.processNames, ["DeviceHubProVerifier", "AQA Verifier"])
        XCTAssertNil(h.controller.loadProblem)
        XCTAssertEqual(h.controller.appsUDID, Self.udid)
        let call = try XCTUnwrap(h.stub.deviceCalls.first { $0.contains("device info apps") })
        XCTAssertTrue(call.contains("device info apps --device \(PhysicalFixtures.coreDeviceIdentifier)"), call)

        h.controller.filter = "verif"
        XCTAssertEqual(h.controller.filteredApps.count, 1)
        h.controller.filter = "nothing"
        XCTAssertEqual(h.controller.filteredApps.count, 0)
    }

    /// An empty listing (the phone's first capture) is an empty list, not a
    /// problem.
    func testAnEmptyListingIsNotAProblem() async throws {
        let h = try await harness(extra: """
          *"device info apps"*) \(PhysicalFixtures.json("devicectl-info-apps.json")) ;;
        """)
        await h.controller.load(udid: Self.udid)
        XCTAssertEqual(h.controller.apps, [])
        XCTAssertNil(h.controller.loadProblem)
    }

    // MARK: - Launch and terminate

    /// Launch replaces a running copy (`--terminate-existing`), goes only to
    /// the enabled device, and the list is read again afterwards.
    func testLaunchArgvAndReload() async throws {
        let h = try await harness(extra: """
          *"process launch"*) \(PhysicalFixtures.json("devicectl-process-launch-verifier.json")) ;;
        """)
        await h.controller.load(udid: Self.udid)
        let app = try XCTUnwrap(h.controller.apps.first)

        await h.controller.launch(app, udid: Self.udid)

        let launch = try XCTUnwrap(h.stub.deviceCalls.first { $0.contains("process launch") })
        XCTAssertTrue(launch.contains("device process launch --device \(PhysicalFixtures.coreDeviceIdentifier)"), launch)
        XCTAssertTrue(launch.contains("--terminate-existing \(Self.bundleID)"), launch)
        XCTAssertEqual(h.stub.deviceCalls.filter { $0.contains("device info apps") }.count, 2, "listed on load and after the action")
        XCTAssertEqual(h.status.statusMessage, "Launched AQA Verifier")
        XCTAssertNil(h.status.errorMessage)
        XCTAssertNil(h.controller.activity)
        for call in h.stub.deviceCalls {
            XCTAssertTrue(call.contains("--device \(PhysicalFixtures.coreDeviceIdentifier)"), call)
        }
    }

    /// CoreDevice 10002 reads "<app> failed to launch: <reason>".
    func testALaunchFailureNamesTheReason() async throws {
        let h = try await harness(extra: """
          *"process launch"*) \(PhysicalFixtures.json("devicectl-process-launch-missing.json", exitCode: 1)) ;;
        """)
        await h.controller.load(udid: Self.udid)
        let app = try XCTUnwrap(h.controller.apps.first)

        await h.controller.launch(app, udid: Self.udid)

        XCTAssertEqual(
            h.status.errorMessage,
            "AQA Verifier failed to launch: The requested application com.example.notinstalled is not installed."
        )
    }

    /// Terminate looks the pid up in `device info processes`: the executable
    /// that sits in the app's bundle, not its extension's.
    func testTerminateFindsThePidFromTheProcesses() async throws {
        let h = try await harness(extra: """
          *"device info processes"*) \(PhysicalFixtures.json(from: try processesJSON())) ;;
          *"process terminate"*) \(PhysicalFixtures.json("devicectl-process-terminate.json")) ;;
        """)
        await h.controller.load(udid: Self.udid)
        let app = try XCTUnwrap(h.controller.apps.first)

        await h.controller.terminate(app, udid: Self.udid)

        let calls = h.stub.deviceCalls
        let processes = try XCTUnwrap(calls.firstIndex { $0.contains("device info processes") })
        let terminate = try XCTUnwrap(calls.firstIndex { $0.contains("process terminate") })
        XCTAssertLessThan(processes, terminate)
        XCTAssertTrue(calls[terminate].contains("device process terminate --device \(PhysicalFixtures.coreDeviceIdentifier)"), calls[terminate])
        XCTAssertTrue(calls[terminate].contains("--pid 4951"), calls[terminate])
        XCTAssertEqual(calls.filter { $0.contains("process terminate") }.count, 1, "the extension is left alone")
        XCTAssertEqual(h.status.statusMessage, "Terminated AQA Verifier")
    }

    /// An app that is not among the running processes is not signalled.
    func testTerminateOfAnAppThatIsNotRunning() async throws {
        let h = try await harness(extra: """
          *"device info processes"*) \(PhysicalFixtures.json("devicectl-info-processes.json")) ;;
        """)
        await h.controller.load(udid: Self.udid)
        let app = try XCTUnwrap(h.controller.apps.first)

        await h.controller.terminate(app, udid: Self.udid)

        XCTAssertFalse(h.stub.deviceCalls.contains { $0.contains("process terminate") })
        XCTAssertEqual(h.status.statusMessage, "AQA Verifier is not running")
        XCTAssertNil(h.status.errorMessage)
    }

    /// CoreDevice 10014 reads "<app> could not be stopped: <reason>".
    func testAStopFailureNamesTheReason() async throws {
        let h = try await harness(extra: """
          *"device info processes"*) \(PhysicalFixtures.json(from: try processesJSON())) ;;
          *"process terminate"*) \(PhysicalFixtures.json("devicectl-process-terminate-nopid.json", exitCode: 1)) ;;
        """)
        await h.controller.load(udid: Self.udid)
        let app = try XCTUnwrap(h.controller.apps.first)

        await h.controller.terminate(app, udid: Self.udid)

        XCTAssertEqual(
            h.status.errorMessage,
            "AQA Verifier could not be stopped: No such process; the process may have already terminated."
        )
    }

    func testTheProcessMatcherKeepsExtensionsOut() throws {
        let app = PhysicalApp(try syntheticApp(url: "file:///private/var/containers/Bundle/Application/AAAA/Weather.app/"))
        let processes: [DevicectlRunningProcess] = try [
            ("file:///private/var/containers/Bundle/Application/AAAA/Weather.app/Weather", 10),
            ("file:///private/var/containers/Bundle/Application/AAAA/Weather.app/PlugIns/W.appex/W", 11),
            ("file:///private/var/containers/Bundle/Application/BBBB/Other.app/Other", 12),
        ].map { executable, pid in
            try JSONDecoder().decode(
                DevicectlRunningProcess.self,
                from: Data(#"{"executable":"\#(executable)","processIdentifier":\#(pid)}"#.utf8)
            )
        }
        XCTAssertEqual(PhysicalApp.pids(of: app, in: processes), [10])
    }

    // MARK: - Uninstall

    /// Uninstall asks first (`requestUninstall`), then runs `device uninstall
    /// app <bundle>` on the enabled device and reads the list again.
    func testUninstallAfterConfirmation() async throws {
        let h = try await harness(extra: """
          *"uninstall app"*) \(PhysicalFixtures.json("devicectl-uninstall-app.json")) ;;
        """)
        await h.controller.load(udid: Self.udid)
        let app = try XCTUnwrap(h.controller.apps.first)

        h.controller.requestUninstall(app, udid: Self.udid)
        XCTAssertEqual(h.controller.pendingUninstall?.bundleIdentifier, Self.bundleID)
        XCTAssertFalse(h.stub.deviceCalls.contains { $0.contains("uninstall") }, "nothing before the user confirms")

        let request = try XCTUnwrap(h.controller.pendingUninstall)
        await h.controller.uninstall(bundleIdentifier: request.bundleIdentifier, name: request.name, udid: request.udid)

        let call = try XCTUnwrap(h.stub.deviceCalls.first { $0.contains("uninstall app") })
        XCTAssertTrue(call.contains("device uninstall app --device \(PhysicalFixtures.coreDeviceIdentifier)"), call)
        XCTAssertTrue(call.contains(Self.bundleID), call)
        XCTAssertEqual(h.status.statusMessage, "Uninstalled AQA Verifier")
        XCTAssertEqual(h.stub.deviceCalls.filter { $0.contains("device info apps") }.count, 2)
    }

    // MARK: - Install and drops

    private func makeDirectory(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A dropped `.app` installs through `device install app <path>`, is
    /// selected once listed, and the name reads from the folder.
    func testInstallFromADroppedApp() async throws {
        let h = try await harness(extra: """
          *"install app"*) \(PhysicalFixtures.json("devicectl-install-app.json")) ;;
        """)
        await h.controller.load(udid: Self.udid)
        let app = try makeDirectory("Demo.app", in: try makeTemporaryFolder("drop"))

        await h.controller.handleDrop([app], udid: Self.udid)

        let call = try XCTUnwrap(h.stub.deviceCalls.first { $0.contains("install app") })
        XCTAssertTrue(call.contains("device install app --device \(PhysicalFixtures.coreDeviceIdentifier)"), call)
        XCTAssertTrue(call.contains(app.path), call)
        XCTAssertEqual(h.status.statusMessage, "Installed Demo")
        XCTAssertEqual(h.controller.selectedID, Self.bundleID)
        XCTAssertEqual(h.stub.deviceCalls.filter { $0.contains("device info apps") }.count, 2)
        XCTAssertNil(h.controller.activity)
    }

    /// A dropped `.ipa` is unzipped into a temporary folder, its app
    /// installed, and the folder removed afterwards.
    func testInstallFromADroppedIPA() async throws {
        let h = try await harness(extra: """
          *"install app"*) \(PhysicalFixtures.json("devicectl-install-app.json")) ;;
        """)
        let staging = try makeTemporaryFolder("ipa")
        _ = try makeDirectory("Payload/Packed.app", in: staging)
        let ipa = try makeTemporaryFolder("ipaout").appendingPathComponent("Packed.ipa")
        let ditto = Process()
        ditto.executableURL = SimulatorAppArchive.ditto
        ditto.arguments = ["-c", "-k", staging.path, ipa.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        let installed = await h.controller.install(ipa, udid: Self.udid)

        XCTAssertTrue(installed)
        let call = try XCTUnwrap(h.stub.deviceCalls.first { $0.contains("install app") })
        XCTAssertTrue(call.contains("\(h.temporary.path)/DeviceHubPro-install-"), call)
        XCTAssertTrue(call.contains("/Payload/Packed.app"), call)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: h.temporary.path).filter { $0.hasPrefix("DeviceHubPro-install-") },
            [],
            "the unzipped copy is removed"
        )
        XCTAssertEqual(h.status.statusMessage, "Installed Packed")
    }

    /// A failed install says so in the alert, and a file that is no app
    /// never reaches devicectl.
    func testInstallFailuresAndNonApps() async throws {
        let h = try await harness(extra: """
          *"install app"*) exit 1 ;;
        """)
        let app = try makeDirectory("Broken.app", in: try makeTemporaryFolder("drop"))

        let installed = await h.controller.install(app, udid: Self.udid)
        XCTAssertFalse(installed)
        XCTAssertTrue(h.status.errorMessage?.hasPrefix("Failed to Install App:") == true, h.status.errorMessage ?? "")
        XCTAssertNil(h.controller.activity)

        let before = h.stub.deviceCalls.count
        let text = try makeTemporaryFolder("drop").appendingPathComponent("notes.txt")
        await h.controller.handleDrop([text], udid: Self.udid)
        XCTAssertEqual(h.stub.deviceCalls.count, before)
        XCTAssertEqual(
            h.status.errorMessage,
            "A physical device can't use “notes.txt”. Drop an app (.app or .ipa) or a link."
        )
        let zip = try makeTemporaryFolder("drop").appendingPathComponent("Some.zip")
        let refused = await h.controller.install(zip, udid: Self.udid)
        XCTAssertFalse(refused)
        XCTAssertEqual(h.status.errorMessage, "“Some.zip” is not an app (.app or .ipa).")
        XCTAssertEqual(h.stub.deviceCalls.count, before)
    }

    func testTheDropRouting() throws {
        let app = URL(fileURLWithPath: "/tmp/A.app")
        let ipa = URL(fileURLWithPath: "/tmp/B.IPA")
        let link = try XCTUnwrap(URL(string: "https://example.com"))
        let text = URL(fileURLWithPath: "/tmp/c.txt")
        XCTAssertEqual(PhysicalDrop.route([app, ipa, link]), [.installApp(app), .installArchive(ipa), .openURL(link)])
        if case .unsupported = PhysicalDrop.route(text) {} else { XCTFail("a text file is not accepted") }
    }

    // MARK: - Open URL

    /// Typed text opens through `device process openURL`, joins the recent
    /// links, and a dropped web link takes the same path; text that is no
    /// link never reaches the device.
    func testOpenURL() async throws {
        let h = try await harness(extra: """
          *"process openURL"*) \(PhysicalFixtures.json("devicectl-process-openURL.json")) ;;
        """)
        var recents: [String] = []
        h.controller.recordRecentURL = { recents.append($0) }

        let opened = await h.controller.openURL("  https://example.com ", udid: Self.udid)

        XCTAssertTrue(opened)
        XCTAssertEqual(recents, ["https://example.com"])
        let call = try XCTUnwrap(h.stub.deviceCalls.first { $0.contains("process openURL") })
        XCTAssertTrue(call.contains("device process openURL --device \(PhysicalFixtures.coreDeviceIdentifier) "), call)
        XCTAssertTrue(call.hasSuffix("https://example.com"), call)
        XCTAssertEqual(h.status.statusMessage, "Opened https://example.com")

        let dropped = try XCTUnwrap(URL(string: "myapp://path?x=1"))
        await h.controller.handleDrop([dropped], udid: Self.udid)
        XCTAssertEqual(recents, ["https://example.com", "myapp://path?x=1"])

        let before = h.stub.deviceCalls.count
        let bad = await h.controller.openURL("example.com", udid: Self.udid)
        XCTAssertFalse(bad)
        XCTAssertEqual(h.status.errorMessage, "example.com is not a URL: it needs a scheme, such as https: or myapp:.")
        let file = await h.controller.openURL("file:///etc/hosts", udid: Self.udid)
        XCTAssertFalse(file)
        XCTAssertEqual(h.status.errorMessage, "file:///etc/hosts is a file on the Mac: a device opens links, not files.")
        XCTAssertEqual(h.stub.deviceCalls.count, before)
    }

    // MARK: - Container files

    private var containerArms: String {
        """
        *"device info files"*"appDataContainer"*) \(PhysicalFixtures.json("devicectl-info-files-verifier.json")) ;;
        *"device copy from"*) \(PhysicalFixtures.capture("devicectl-copy-from-readings.json")) ;;
        """
    }

    /// The container listing (`--domain-type appDataContainer
    /// --domain-identifier <bundle>`) is the capture's tree, depth first.
    func testContainerListing() async throws {
        let h = try await harness(extra: containerArms)
        await h.controller.load(udid: Self.udid)
        let app = try XCTUnwrap(h.controller.apps.first)

        await h.controller.showContainerFiles(app, udid: Self.udid)

        XCTAssertEqual(h.controller.containerTarget?.bundleIdentifier, Self.bundleID)
        XCTAssertNil(h.controller.containerProblem)
        XCTAssertFalse(h.controller.isLoadingContainer)
        let expected = try DevicectlJSON.decode(
            DevicectlFileList.self, from: try PhysicalFixtures.data("devicectl-info-files-verifier.json")
        ).value.files
        XCTAssertEqual(h.controller.containerFiles.map(\.relativePath), expected.map(\.relativePath))
        let readings = try XCTUnwrap(h.controller.containerFiles.first { $0.relativePath == "Documents/readings.json" })
        XCTAssertFalse(readings.isDirectory)
        XCTAssertEqual(readings.size, 4724)
        XCTAssertEqual(readings.name, "readings.json")
        XCTAssertEqual(readings.depth, 1)
        XCTAssertEqual(h.controller.containerFiles.first { $0.relativePath == "Documents" }?.isDirectory, true)
        let call = try XCTUnwrap(h.stub.deviceCalls.first { $0.contains("device info files") })
        XCTAssertTrue(
            call.contains("--domain-type appDataContainer --domain-identifier \(Self.bundleID)"),
            call
        )

        h.controller.closeContainerFiles()
        XCTAssertNil(h.controller.containerTarget)
        XCTAssertEqual(h.controller.containerFiles, [])
    }

    /// "Save to…" copies one file through `device copy from` to a temporary
    /// file and moves it to the chosen place; a cancelled panel copies
    /// nothing; a folder is not copied.
    func testSavingAContainerFile() async throws {
        let h = try await harness(extra: containerArms)
        await h.controller.load(udid: Self.udid)
        let app = try XCTUnwrap(h.controller.apps.first)
        await h.controller.showContainerFiles(app, udid: Self.udid)
        let readings = try XCTUnwrap(h.controller.containerFiles.first { $0.relativePath == "Documents/readings.json" })
        let folder = try XCTUnwrap(h.controller.containerFiles.first { $0.isDirectory })
        var revealed: [URL] = []
        h.controller.revealInFinder = { revealed.append($0) }

        // Cancelled: the panel is asked, nothing is copied.
        let cancelled = await h.controller.saveContainerFile(readings)
        XCTAssertNil(cancelled)
        XCTAssertEqual(h.picker.suggestedNames, ["readings.json"])
        XCTAssertFalse(h.stub.deviceCalls.contains { $0.contains("device copy from") })

        let destination = try makeTemporaryFolder("saved").appendingPathComponent("mine.json")
        try Data("old".utf8).write(to: destination)
        h.picker.destination = destination
        let saved = await h.controller.saveContainerFile(readings, revealAfter: true)

        XCTAssertEqual(saved, destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("captured".utf8), "an existing file is replaced")
        XCTAssertEqual(revealed, [destination])
        let call = try XCTUnwrap(h.stub.deviceCalls.first { $0.contains("device copy from") })
        XCTAssertTrue(call.contains("device copy from --device \(PhysicalFixtures.coreDeviceIdentifier)"), call)
        XCTAssertTrue(call.contains("--domain-type appDataContainer --domain-identifier \(Self.bundleID)"), call)
        XCTAssertTrue(call.contains("--source Documents/readings.json"), call)
        XCTAssertTrue(call.contains("--destination \(h.temporary.path)/devicehubpro-physical-copy-"), call)
        XCTAssertEqual(h.status.statusMessage, "Saved mine.json")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: h.temporary.path),
            [],
            "the staging folder is removed"
        )

        let copies = h.stub.deviceCalls.filter { $0.contains("device copy from") }.count
        let none = await h.controller.saveContainerFile(folder)
        XCTAssertNil(none)
        XCTAssertEqual(h.stub.deviceCalls.filter { $0.contains("device copy from") }.count, copies)
    }

    // MARK: - No call for a device that is not enabled

    /// A listed device the user did not enable gets no call from the Apps
    /// tab: every action stops at the inventory's nil client, and the tab
    /// shows the state's hint.
    func testANonEnabledDeviceGetsNoCall() async throws {
        let h = try await harness(enabled: false)
        let app = try verifierApp()

        await h.controller.load(udid: Self.udid)
        await h.controller.launch(app, udid: Self.udid)
        await h.controller.terminate(app, udid: Self.udid)
        await h.controller.uninstall(bundleIdentifier: app.bundleIdentifier, name: app.title, udid: Self.udid)
        let install = try makeDirectory("X.app", in: try makeTemporaryFolder("drop"))
        await h.controller.handleDrop([install, try XCTUnwrap(URL(string: "https://example.com"))], udid: Self.udid)
        await h.controller.showContainerFiles(app, udid: Self.udid)
        XCTAssertNil(h.controller.containerFiles.first)

        XCTAssertEqual(h.stub.deviceCalls, [], "nothing but the list reached the tool")
        let hint = "Choose Use This Device to let Device Hub Pro read and manage it."
        XCTAssertEqual(h.controller.loadProblem, hint)
        XCTAssertEqual(h.controller.containerProblem, hint)
        XCTAssertEqual(h.status.errorMessage, hint)
        XCTAssertEqual(h.controller.apps, [])
    }

    /// The command line of each action carries only the enabled device's
    /// CoreDevice identifier, never `booted` or `all`, and no call in a whole
    /// session deletes, removes or copies anything to the phone (uninstall
    /// happens only in the test that confirms it).
    func testASessionRunsOnlyTheAllowedCommands() async throws {
        let h = try await harness(extra: """
          \(containerArms)
          *"process launch"*) \(PhysicalFixtures.json("devicectl-process-launch-verifier.json")) ;;
          *"device info processes"*) \(PhysicalFixtures.json(from: try processesJSON())) ;;
          *"process terminate"*) \(PhysicalFixtures.json("devicectl-process-terminate.json")) ;;
          *"process openURL"*) \(PhysicalFixtures.json("devicectl-process-openURL.json")) ;;
        """)
        await h.controller.load(udid: Self.udid)
        let app = try XCTUnwrap(h.controller.apps.first)
        await h.controller.launch(app, udid: Self.udid)
        await h.controller.terminate(app, udid: Self.udid)
        _ = await h.controller.openURL("https://example.com", udid: Self.udid)
        await h.controller.showContainerFiles(app, udid: Self.udid)
        h.picker.destination = try makeTemporaryFolder("saved").appendingPathComponent("x.json")
        _ = await h.controller.saveContainerFile(try XCTUnwrap(h.controller.containerFiles.first { !$0.isDirectory }))

        let allowed = ["device info apps", "device process launch", "device info processes", "device process terminate",
                       "device process openURL", "device info files", "device copy from"]
        XCTAssertFalse(h.stub.deviceCalls.isEmpty)
        for call in h.stub.deviceCalls {
            XCTAssertTrue(allowed.contains { call.hasPrefix($0) }, call)
            XCTAssertTrue(call.contains("--device \(PhysicalFixtures.coreDeviceIdentifier)"), call)
            for word in [" booted", " all ", "uninstall", "copy to", "delete", "remove", "reset", "settings"] {
                XCTAssertFalse(call.contains(word), "\(word) in \(call)")
            }
        }
    }

    // MARK: - Helpers

    private func syntheticApp(url: String) throws -> DevicectlInstalledApp {
        try JSONDecoder().decode(
            DevicectlInstalledApp.self,
            from: Data(#"{"bundleIdentifier":"com.example.weather","name":"Weather","url":"\#(url)"}"#.utf8)
        )
    }
}
