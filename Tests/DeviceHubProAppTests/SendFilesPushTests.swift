import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// `.apns` push payload and `.mobileconfig` profile drops through
/// `SendFilesController` against a stub simctl:
/// which argv runs, in what order, what is asked and what is said. The stub
/// answers like simctl's success (exit 0, nothing printed on stdout for these
/// calls in the captures of the apps and keychain calls).
@MainActor
final class SendFilesPushTests: XCTestCase {
    private static let udid = "95D9676B-3317-4BA5-8CF6-3CDD0488CACA"

    private struct Harness {
        let stub: StubTool
        let controller: SendFilesController
        let apps: SimulatorAppsController
        let status: StatusCenter
        let folder: URL
    }

    private func harness() async throws -> Harness {
        let u = Self.udid
        let stub = try makeStubTool("simctl", arms: """
          *"list -j devices")
            \(SimulatorFixtures.cat("simctl-list-j-devices.booted.json")) ;;
          *"list -j runtimes")
            \(SimulatorFixtures.cat("simctl-list-j-runtimes.json")) ;;
          *"list -j devicetypes")
            \(SimulatorFixtures.cat("simctl-list-j-devicetypes.json")) ;;
          *" listapps \(u)")
            \(SimulatorFixtures.cat("simctl-listapps.with-user-app.stdout.txt")) ;;
          *" push \(u) "*|*" keychain \(u) add-root-cert "*)
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
        let simulatorApps = SimulatorAppsController(simulators: inventory, status: status, defaults: .scratch())
        simulatorApps.listsLaunchProhibitedApps = false
        let physicalStub = try makePhysicalStub(extra: "")
        let physical = try await makeListedPhysicalInventory(stub: physicalStub)
        let controller = SendFilesController(
            adbClient: nil,
            simulators: inventory,
            inventory: physical,
            status: status,
            defaults: .scratch(),
            apps: AppsController(
                adbClient: nil,
                status: status,
                recentAPKs: RecentAPKStore(defaults: .scratch()),
                pasteboard: TestPasteboard()
            ),
            simulatorApps: simulatorApps,
            physicalApps: PhysicalAppsController(
                inventory: physical,
                status: status,
                picker: TestPicker(),
                temporaryDirectory: try makeTemporaryFolder("apps")
            )
        )
        return Harness(stub: stub, controller: controller, apps: simulatorApps, status: status, folder: try makeTemporaryFolder("drops"))
    }

    private func write(_ name: String, _ text: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func calls(_ h: Harness) -> [String] {
        h.stub.calls.filter { $0.hasPrefix("push") || $0.hasPrefix("keychain") }
    }

    func testAPayloadNamingItsAppIsSentToThatApp() async throws {
        let h = try await harness()
        let file = try write("a.apns", #"{"Simulator Target Bundle": "com.example.app", "aps": {"alert": "Hi"}}"#, in: h.folder)
        h.controller.choosePushApp = { _, _, _ in XCTFail("the payload names its app"); return nil }
        await h.controller.send([file], to: .simulator(udid: Self.udid))
        XCTAssertEqual(calls(h), ["push \(Self.udid) com.example.app \(file.path)"])
        XCTAssertNil(h.status.errorMessage)
        XCTAssertEqual(h.controller.overlayText(for: [file], target: .simulator(udid: Self.udid)), "Send push notification to com.example.app")
    }

    func testSeveralFilesAreSentInOrderAndTheAppIsAskedOnceForThoseWithoutOne() async throws {
        let h = try await harness()
        let first = try write("1.apns", #"{"aps": {"badge": 1}}"#, in: h.folder)
        let second = try write("2.apns", #"{"Simulator Target Bundle": "com.example.app", "aps": {}}"#, in: h.folder)
        let third = try write("3.apns", #"{"aps": {"badge": 3}}"#, in: h.folder)
        var asked: [(count: Int, file: String)] = []
        h.controller.choosePushApp = { apps, file, _ in
            asked.append((apps.count, file))
            return apps.first { $0.id == "dev.devicehubpro.fixture.apps" }
        }
        await h.controller.send([first, second, third], to: .simulator(udid: Self.udid))
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.file, "1.apns")
        XCTAssertGreaterThan(asked.first?.count ?? 0, 1)
        XCTAssertEqual(calls(h), [
            "push \(Self.udid) dev.devicehubpro.fixture.apps \(first.path)",
            "push \(Self.udid) com.example.app \(second.path)",
            "push \(Self.udid) dev.devicehubpro.fixture.apps \(third.path)",
        ])
        XCTAssertNil(h.status.errorMessage)
    }

    func testCancellingTheAppQuestionSendsOnlyTheFilesThatNameTheirApp() async throws {
        let h = try await harness()
        let unnamed = try write("1.apns", #"{"aps": {}}"#, in: h.folder)
        let named = try write("2.apns", #"{"Simulator Target Bundle": "com.example.app", "aps": {}}"#, in: h.folder)
        var asked = 0
        h.controller.choosePushApp = { _, _, _ in asked += 1; return nil }
        await h.controller.send([unnamed, named, unnamed], to: .simulator(udid: Self.udid))
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(calls(h), ["push \(Self.udid) com.example.app \(named.path)"])
        XCTAssertNil(h.status.errorMessage)
    }

    func testABadPayloadIsExplainedAndTheOthersStillGo() async throws {
        let h = try await harness()
        let bad = try write("bad.apns", "{ not json", in: h.folder)
        let good = try write("good.apns", #"{"Simulator Target Bundle": "com.example.app", "aps": {}}"#, in: h.folder)
        await h.controller.send([bad, good], to: .simulator(udid: Self.udid))
        XCTAssertEqual(calls(h), ["push \(Self.udid) com.example.app \(good.path)"])
        XCTAssertTrue(h.status.errorMessage?.hasPrefix("“bad.apns” is not a push payload. The payload is not JSON") == true, h.status.errorMessage ?? "nil")
    }

    func testAnAppleFileOfAnotherKindStillCopiesAlongsideAPush() async throws {
        let h = try await harness()
        let plan = SimulatorSendRouting.plan([try write("a.apns", "{}", in: h.folder), try write("notes.txt", "x", in: h.folder)])
        XCTAssertEqual(plan.pushes.count, 1)
        XCTAssertEqual(plan.files.count, 1)
    }

    func testAndroidTakesNoPushPayload() async throws {
        let h = try await harness()
        let file = try write("a.apns", #"{"aps": {}}"#, in: h.folder)
        await h.controller.send([file], to: .android(serial: "emulator-5554"))
        XCTAssertEqual(h.status.errorMessage, "Push notifications can't be sent to Android this way.")
        XCTAssertEqual(h.controller.overlayText(for: [file], target: .android(serial: "emulator-5554")), "Push notifications can't be sent to Android this way")
    }

    func testAPhysicalPhoneRunsNoCommandForPushOrProfile() async throws {
        let h = try await harness()
        let push = try write("a.apns", #"{"aps": {}}"#, in: h.folder)
        let profile = try write("Corp.mobileconfig", "x", in: h.folder)
        h.controller.chooseApp = { _, _ in XCTFail("nothing to copy"); return nil }
        await h.controller.send([push, profile], to: .physical(udid: PhysicalFixtures.udid))
        XCTAssertEqual(h.status.errorMessage, "Push payloads and profiles can't be sent to a physical iPhone with public tools.")
        XCTAssertEqual(
            h.controller.overlayText(for: [push, profile], target: .physical(udid: PhysicalFixtures.udid)),
            "Push payloads and profiles can't be sent to a physical iPhone with public tools"
        )
    }

    func testAProfilesCertificatesAreAskedAboutThenTrusted() async throws {
        let h = try await harness()
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "PayloadType": "Configuration", "PayloadVersion": 1,
            "PayloadContent": [["PayloadType": "com.apple.security.root", "PayloadContent": Data([0x30, 0x00])]],
        ] as [String: Any], format: .xml, options: 0)
        let profile = h.folder.appendingPathComponent("Corp.mobileconfig")
        try plist.write(to: profile)
        var asked: [[URL]] = []
        await h.controller.send([profile], to: .simulator(udid: Self.udid)) { asked.append($0) }
        XCTAssertEqual(asked.count, 1)
        let staged = try XCTUnwrap(asked.first?.first)
        XCTAssertEqual(staged.lastPathComponent, "Corp.cer")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(calls(h).isEmpty, "nothing is trusted before the answer")

        await h.apps.trustRootCertificates(asked[0], udid: Self.udid)
        XCTAssertEqual(calls(h), ["keychain \(Self.udid) add-root-cert \(staged.path)"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "the staged certificate is removed after")
        XCTAssertNil(h.status.errorMessage)
    }

    func testAProfileWithoutCertificatesSaysSo() async throws {
        let h = try await harness()
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "PayloadType": "Configuration", "PayloadVersion": 1,
            "PayloadContent": [["PayloadType": "com.apple.wifi.managed"]],
        ] as [String: Any], format: .xml, options: 0)
        let profile = h.folder.appendingPathComponent("Wifi.mobileconfig")
        try plist.write(to: profile)
        await h.controller.send([profile], to: .simulator(udid: Self.udid)) { _ in XCTFail("nothing to trust") }
        XCTAssertTrue(h.status.errorMessage?.contains("holds no certificate") == true, h.status.errorMessage ?? "nil")
    }
}
