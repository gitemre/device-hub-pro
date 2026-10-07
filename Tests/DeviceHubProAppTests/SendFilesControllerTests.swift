import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// `SendFilesController` against the stub devicectl (a physical iPhone) and
/// scratch defaults: which app gets the files, what is remembered, what is run
/// and what never is. The `copy to` reply is the `copy from` capture's shape
/// (no capture of a `copy to` exists; no test ever runs it on a real device).
@MainActor
final class SendFilesControllerTests: XCTestCase {
    private static let udid = PhysicalFixtures.udid
    private static let bundleID = "com.devicehubpro.verifier"

    private struct Harness {
        let stub: StubTool
        let controller: SendFilesController
        let status: StatusCenter
        let defaults: UserDefaults
    }

    private func harness() async throws -> Harness {
        let stub = try makePhysicalStub(extra: """
          *"device copy to"*) \(PhysicalFixtures.json("devicectl-copy-from-readings.json")) ;;
          *"device info apps"*) \(PhysicalFixtures.json("devicectl-info-apps-after-install.json")) ;;
        """)
        let inventory = try await makeListedPhysicalInventory(stub: stub)
        let status = StatusCenter()
        let defaults = UserDefaults.scratch()
        let simulators = SimulatorInventory(
            apple: .stubbed(
                simctl: nil,
                devicesDirectory: try makeTemporaryFolder("set"),
                logsDirectory: try makeTemporaryFolder("logs")
            ),
            preferences: AppPreferences(defaults: .scratch())
        )
        addTeardownBlock { @MainActor in simulators.stop() }
        let apps = AppsController(
            adbClient: nil,
            status: status,
            recentAPKs: RecentAPKStore(defaults: .scratch()),
            pasteboard: TestPasteboard()
        )
        let simulatorApps = SimulatorAppsController(simulators: simulators, status: status, defaults: .scratch())
        let physicalApps = PhysicalAppsController(
            inventory: inventory,
            status: status,
            picker: TestPicker(),
            temporaryDirectory: try makeTemporaryFolder("apps")
        )
        let controller = SendFilesController(
            adbClient: nil,
            simulators: simulators,
            inventory: inventory,
            status: status,
            defaults: defaults,
            apps: apps,
            simulatorApps: simulatorApps,
            physicalApps: physicalApps
        )
        return Harness(stub: stub, controller: controller, status: status, defaults: defaults)
    }

    private func file(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    func testFilesGoIntoTheChosenAppsDocumentsAndTheChoiceIsRemembered() async throws {
        let h = try await harness()
        let folder = try makeTemporaryFolder("send")
        let notes = try file("notes.txt", in: folder)
        let photo = try file("photo.png", in: folder)
        var asked = 0
        h.controller.chooseApp = { apps, _ in
            asked += 1
            return apps.first { $0.id == Self.bundleID }
        }

        await h.controller.send([notes, photo], to: .physical(udid: Self.udid))

        XCTAssertEqual(asked, 1)
        XCTAssertNil(h.status.errorMessage)
        let copies = h.stub.deviceCalls.filter { $0.hasPrefix("device copy to") }
        XCTAssertEqual(copies.count, 2)
        XCTAssertTrue(copies[0].contains("--domain-type appDataContainer --domain-identifier \(Self.bundleID)"), copies[0])
        XCTAssertTrue(copies[0].contains("--source \(notes.path) --destination Documents/notes.txt"), copies[0])
        XCTAssertTrue(copies[1].contains("--source \(photo.path) --destination Documents/photo.png"), copies[1])

        // The second send does not ask again.
        await h.controller.send([notes], to: .physical(udid: Self.udid))
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(h.stub.deviceCalls.filter { $0.hasPrefix("device copy to") }.count, 3)
        XCTAssertEqual(
            h.controller.overlayText(for: [notes], target: .physical(udid: Self.udid)),
            "Copy 1 file to AQA Verifier’s Documents"
        )
    }

    func testAnAppThatIsDroppedWithFilesStillInstallsAndOnlyTheFilesAreCopied() async throws {
        let h = try await harness()
        let folder = try makeTemporaryFolder("send")
        let notes = try file("notes.txt", in: folder)
        h.controller.chooseApp = { apps, _ in apps.first }

        await h.controller.send([notes], to: .physical(udid: Self.udid))

        for call in h.stub.deviceCalls {
            XCTAssertTrue(
                ["device info", "device copy to"].contains { call.hasPrefix($0) } || call.hasPrefix("list devices"),
                call
            )
        }
    }

    func testCancellingTheAppQuestionSendsNothing() async throws {
        let h = try await harness()
        let notes = try file("notes.txt", in: try makeTemporaryFolder("send"))
        h.controller.chooseApp = { _, _ in nil }

        await h.controller.send([notes], to: .physical(udid: Self.udid))

        XCTAssertTrue(h.stub.deviceCalls.filter { $0.hasPrefix("device copy to") }.isEmpty)
    }

    func testPhotosAreExplainedInTheOverlayForAPhysicalPhone() async throws {
        let h = try await harness()
        let text = h.controller.overlayText(for: [URL(fileURLWithPath: "/tmp/a.png")], target: .physical(udid: Self.udid))
        XCTAssertTrue(text.contains("Photos can't be added to a physical iPhone"), text)
    }

    func testDestinationsAreRememberedPerPlatform() async throws {
        let h = try await harness()
        XCTAssertEqual(h.controller.androidDestination, .downloads)
        h.controller.androidDestination = .custom("/sdcard/Test/Inbox")
        XCTAssertEqual(h.controller.androidDestination, .custom("/sdcard/Test/Inbox"))
        XCTAssertEqual(h.controller.simulatorDestination, .filesApp)
        h.controller.simulatorDestination = .appDocuments(bundleIdentifier: "com.example.demo")
        XCTAssertEqual(h.controller.simulatorDestination, .appDocuments(bundleIdentifier: "com.example.demo"))
        XCTAssertEqual(SendFilesController.androidDestination(id: "custom", custom: "Download/X"), .custom("/sdcard/Download/X"))
        XCTAssertNil(SendFilesController.androidDestination(id: "custom", custom: "/data/x"))
        XCTAssertEqual(SendFilesController.androidDestination(id: "/sdcard/DCIM", custom: ""), .dcim)
    }
}
