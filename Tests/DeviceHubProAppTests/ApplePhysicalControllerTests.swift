import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// What the app does with an enabled physical device: the Info
/// card from `details`, `lockState`, `ddiServices` and `displays`; a
/// screenshot that goes through `screenshot(to:)`; and a device that
/// reports a capability unsupported losing the matching UI. The stub
/// devicectl replays the captures of the dedicated test iPhone.
@MainActor
final class ApplePhysicalControllerTests: XCTestCase {
    private static let udid = PhysicalFixtures.udid

    /// An inventory with the test iPhone listed and enabled, and a
    /// controller on it.
    private func enabledDevice(
        stub: StubTool,
        picker: TestPicker = TestPicker()
    ) async throws -> (ApplePhysicalInventory, ApplePhysicalController, URL) {
        let preferences = AppPreferences(defaults: .scratch())
        preferences.setPhysicalAppleDevice(Self.udid, enabled: true)
        let inventory = try makePhysicalInventory(stub: stub, preferences: preferences, pollInterval: .seconds(60))
        let temporary = try makeTemporaryFolder("shots")
        let controller = ApplePhysicalController(inventory: inventory, picker: picker, temporaryDirectory: temporary)
        inventory.setShowing(true)
        let listed = await physicalWait { inventory.entries.first?.state == .ready }
        XCTAssertTrue(listed)
        return (inventory, controller, temporary)
    }

    // MARK: - Info card

    /// The Info card's values, mapped from the list entry and the four reads
    /// of the real captures.
    func testInfoCardMappingFromTheCaptures() throws {
        let entry = try PhysicalFixtures.entry()
        let details = try DevicectlJSON.decode(
            DevicectlDeviceDetails.self, from: try PhysicalFixtures.data("devicectl-info-details.json")
        ).value
        let lock = try DevicectlJSON.decode(
            DevicectlLockState.self, from: try PhysicalFixtures.data("devicectl-info-lockState.json")
        ).value
        let ddi = try DevicectlJSON.decode(
            DevicectlDDIServices.self, from: try PhysicalFixtures.data("devicectl-info-ddiServices.json")
        ).value
        let displays = try DevicectlJSON.decode(
            DevicectlDisplays.self, from: try PhysicalFixtures.data("devicectl-info-displays.json")
        ).value

        let info = PhysicalDeviceInfo.make(entry: entry, details: details, lockState: lock, ddi: ddi, displays: displays)

        XCTAssertEqual(info.name, "aqa-test-phon")
        XCTAssertEqual(info.marketingName, "iPhone 12")
        XCTAssertEqual(info.modelIdentifier, "iPhone13,2")
        XCTAssertEqual(info.osVersion, "27.0")
        XCTAssertEqual(info.osBuild, "24A5380h")
        XCTAssertEqual(info.os, "iOS 27.0 (24A5380h)")
        XCTAssertEqual(info.pairing, "Paired")
        XCTAssertEqual(info.connection, "Connected")
        XCTAssertEqual(info.transport, "Wired")
        XCTAssertEqual(info.developerMode, "On")
        XCTAssertEqual(info.developerDiskImage, "Ready (27A266a)")
        XCTAssertEqual(info.lockState, "Unlocked")
        XCTAssertEqual(info.screenSize, "1170 × 2532 px")

        // Device Hub's cards: Name and OS without the build; the hardware
        // card with Capacity, ECID, Model, Product Type, Serial Number and UDID
        // (the captures' same-length placeholders); Display without "px".
        let cards = PhysicalInfoLayout.cards(entry: entry, info: info)
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards[0], [
            .init(.name, "aqa-test-phon"),
            .init(.os, "iOS 27.0"),
        ])
        XCTAssertEqual(cards[1], [
            .init(.capacity, "64 GB"),
            .init(.ecid, "1000000000000000"),
            .init(.model, "iPhone 12"),
            .init(.productType, "iPhone13,2"),
            .init(.serialNumber, "AQASERIAL000"),
            .init(.udid, "00000000-0000000000000000"),
        ])
        XCTAssertEqual(cards[2], [.init(.display, "1170 × 2532")])
        // Device Hub Pro's extra rows are still there once ticked in Edit Visibility.
        let everything = PhysicalInfoLayout.cards(entry: entry, info: info, visible: Set(PhysicalInfoProperty.allCases))
        XCTAssertEqual(everything.count, 4)
        XCTAssertEqual(everything[3], [
            .init(.pairing, "Paired"),
            .init(.connection, "Connected · Wired"),
            .init(.developerMode, "On"),
            .init(.developerDiskImage, "Ready (27A266a)"),
            .init(.lockState, "Unlocked"),
        ])
        XCTAssertEqual(everything[0].last, .init(.osBuild, "24A5380h"))
    }

    /// A device that is not enabled shows only what the list said: no
    /// command-derived row (capacity, ECID, serial number, display, disk image,
    /// lock state).
    func testAnEnabledlessCardShowsOnlyTheListsValues() throws {
        let entry = try PhysicalFixtures.entry(enabled: false)
        let cards = PhysicalInfoLayout.cards(entry: entry, info: nil)
        let labels = cards.flatMap { $0 }.map(\.label)
        XCTAssertEqual(labels, ["Name", "OS", "Model", "Product Type", "UDID"])
        XCTAssertEqual(cards[0][1].value, "iOS 27.0")
        let all = PhysicalInfoLayout.cards(entry: entry, info: nil, visible: Set(PhysicalInfoProperty.allCases))
        let everyLabel = all.flatMap { $0 }.map(\.label)
        XCTAssertFalse(everyLabel.contains("Display"))
        XCTAssertFalse(everyLabel.contains("Lock State"))
        XCTAssertFalse(everyLabel.contains("Developer Disk Image"))
        XCTAssertTrue(everyLabel.contains("Pairing"))
    }

    func testLockedAndUnavailableValues() throws {
        let entry = try PhysicalFixtures.entry()
        let locked = try DevicectlJSON.decode(
            DevicectlLockState.self,
            from: Data(#"{"info":{"arguments":[],"commandType":"x","jsonVersion":5,"outcome":"success","version":"1"},"result":{"passcodeRequired":true,"unlockedSinceBoot":true}}"#.utf8)
        ).value
        let info = PhysicalDeviceInfo.make(entry: entry, details: nil, lockState: locked, ddi: nil, displays: nil)
        XCTAssertEqual(info.lockState, "Locked")
        XCTAssertNil(info.osBuild)
        XCTAssertEqual(info.os, "iOS 27.0")
        XCTAssertEqual(PhysicalDeviceInfo.humanize("localNetwork"), "Local Network")
        XCTAssertEqual(PhysicalDeviceInfo.humanize("wired"), "Wired")
    }

    /// An enabled device's reads run (`details`, `lockState`, `ddiServices`,
    /// `displays`, each `--device <id>`), and a failed read keeps the last
    /// good values for its fields.
    func testRefreshReadsTheFourAnswers() async throws {
        let stub = try makePhysicalStub()
        let (_, controller, _) = try await enabledDevice(stub: stub)

        await controller.refreshInfo(udid: Self.udid)

        let info = try XCTUnwrap(controller.infos[Self.udid])
        XCTAssertEqual(info.os, "iOS 27.0 (24A5380h)")
        XCTAssertEqual(info.lockState, "Unlocked")
        XCTAssertEqual(info.screenSize, "1170 × 2532 px")
        XCTAssertNil(controller.infoErrors[Self.udid])
        let reads = stub.deviceCalls.map { call in
            ["details", "lockState", "ddiServices", "displays"].first { call.contains("device info \($0)") }
        }
        XCTAssertEqual(Set(reads.compactMap { $0 }), ["details", "lockState", "ddiServices", "displays"])
        for call in stub.deviceCalls {
            XCTAssertTrue(call.contains("--device \(PhysicalFixtures.coreDeviceIdentifier)"), call)
            XCTAssertFalse(call.contains("booted"), call)
        }
    }

    /// A read that fails keeps its fields; when every read fails the reason
    /// is kept (a locked or busy device).
    func testFailedReadsKeepTheLastValuesAndReportWhenAllFail() async throws {
        let failMarker = try makeTemporaryFolder("fail").appendingPathComponent("fail")
        let quoted = SimulatorFixtures.quoted(failMarker.path)
        func guarded(_ name: String) -> String {
            "if [ -e \(quoted) ]; then exit 1; fi; " + PhysicalFixtures.json(name)
        }
        let stub = try makePhysicalStub(extra: """
          *"device info details"*) \(guarded("devicectl-info-details.json")) ;;
          *"device info lockState"*) \(guarded("devicectl-info-lockState.json")) ;;
          *"device info ddiServices"*) \(guarded("devicectl-info-ddiServices.json")) ;;
          *"device info displays"*) \(guarded("devicectl-info-displays.json")) ;;
        """)
        let (_, controller, _) = try await enabledDevice(stub: stub)
        await controller.refreshInfo(udid: Self.udid)
        let good = try XCTUnwrap(controller.infos[Self.udid])
        XCTAssertNil(controller.infoErrors[Self.udid])

        FileManager.default.createFile(atPath: failMarker.path, contents: Data())
        await controller.refreshInfo(udid: Self.udid)

        XCTAssertEqual(controller.infos[Self.udid], good, "the last good values stand")
        XCTAssertNotNil(controller.infoErrors[Self.udid])
    }

    // MARK: - Screenshot

    /// A screenshot goes through `device capture screenshot --destination
    /// <temporary .png>`, is kept as the device's last one, and the
    /// temporary file is removed.
    func testScreenshotIsTakenKeptAndCleanedUp() async throws {
        let stub = try makePhysicalStub(extra: """
          *"capture screenshot"*) \(PhysicalFixtures.capture("devicectl-capture-screenshot.json")) ;;
        """)
        let (_, controller, temporary) = try await enabledDevice(stub: stub)

        let png = await controller.takeScreenshot(udid: Self.udid)

        XCTAssertEqual(png, Data("captured".utf8))
        XCTAssertEqual(controller.screenshots[Self.udid]?.png, png)
        XCTAssertNil(controller.operations[Self.udid])
        XCTAssertNil(controller.messages[Self.udid])
        let call = try XCTUnwrap(stub.deviceCalls.first { $0.contains("capture screenshot") })
        XCTAssertTrue(call.contains("--device \(PhysicalFixtures.coreDeviceIdentifier)"))
        XCTAssertTrue(call.contains("--destination \(temporary.path)/devicehubpro-physical-"))
        XCTAssertTrue(call.contains(".png"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
        XCTAssertEqual(leftovers, [], "the temporary PNG is removed")
    }

    /// A failing screenshot says why and keeps the previous one.
    func testAFailedScreenshotKeepsThePreviousOne() async throws {
        let failMarker = try makeTemporaryFolder("fail").appendingPathComponent("fail")
        let stub = try makePhysicalStub(extra: """
          *"capture screenshot"*)
            if [ -e \(SimulatorFixtures.quoted(failMarker.path)) ]; then exit 1; fi
            \(PhysicalFixtures.capture("devicectl-capture-screenshot.json")) ;;
        """)
        let (_, controller, _) = try await enabledDevice(stub: stub)
        let first = await controller.takeScreenshot(udid: Self.udid)
        XCTAssertNotNil(first)

        FileManager.default.createFile(atPath: failMarker.path, contents: Data())
        let second = await controller.takeScreenshot(udid: Self.udid)

        XCTAssertNil(second)
        XCTAssertEqual(controller.screenshots[Self.udid]?.png, first)
        XCTAssertTrue(controller.messages[Self.udid]?.hasPrefix("Screenshot failed") == true)
        XCTAssertTrue(controller.isSupported(.screenshot, udid: Self.udid), "an ordinary failure is not a missing capability")
    }

    // MARK: - Capabilities

    /// CoreDevice's 1001 for screen recording (the captured failure of the
    /// iPhone 12 on iOS 27) is remembered per device: the recording button
    /// goes, the capability set loses `.record`, and it is not asked again.
    /// Screenshots stay.
    func testAnUnsupportedRecordingHidesTheRecordingUI() async throws {
        let stub = try makePhysicalStub(extra: """
          *"capture screen-record"*) \(PhysicalFixtures.json("devicectl-capture-screen-record.json", exitCode: 1)) ;;
        """)
        let picker = TestPicker()
        let (_, controller, _) = try await enabledDevice(stub: stub, picker: picker)
        XCTAssertTrue(controller.isSupported(.screenRecording, udid: Self.udid))
        XCTAssertTrue(controller.capabilities(udid: Self.udid).contains(.record))

        await controller.recordScreen(udid: Self.udid)

        XCTAssertFalse(controller.isSupported(.screenRecording, udid: Self.udid))
        XCTAssertFalse(controller.capabilities(udid: Self.udid).contains(.record))
        XCTAssertTrue(controller.capabilities(udid: Self.udid).contains(.screenshot))
        XCTAssertTrue(controller.isSupported(.screenshot, udid: Self.udid))
        XCTAssertEqual(controller.messages[Self.udid], "This device does not support screen recording.")
        XCTAssertEqual(picker.suggestedNames, [], "nothing to save, nothing asked")
        let recordCalls = stub.deviceCalls.filter { $0.contains("screen-record") }
        XCTAssertEqual(recordCalls.count, 1)

        await controller.recordScreen(udid: Self.udid)
        XCTAssertEqual(stub.deviceCalls.filter { $0.contains("screen-record") }.count, 1, "not asked again")
    }

    /// The memory is per device and forgotten with it.
    func testForgettingADeviceClearsWhatWasKept() async throws {
        let stub = try makePhysicalStub(extra: """
          *"capture screen-record"*) \(PhysicalFixtures.json("devicectl-capture-screen-record.json", exitCode: 1)) ;;
        """)
        let (inventory, controller, _) = try await enabledDevice(stub: stub)
        await controller.refreshInfo(udid: Self.udid)
        await controller.recordScreen(udid: Self.udid)
        XCTAssertNotNil(controller.infos[Self.udid])
        XCTAssertNotNil(controller.messages[Self.udid])

        inventory.disable(udid: Self.udid)

        XCTAssertNil(controller.infos[Self.udid])
        XCTAssertNil(controller.messages[Self.udid])
        XCTAssertNil(controller.screenshots[Self.udid])
    }

    /// A recording that works is saved where the picker says, from the
    /// temporary file.
    func testARecordingIsSavedWhereThePickerSays() async throws {
        let stub = try makePhysicalStub(extra: """
          *"capture screen-record"*) \(PhysicalFixtures.capture("devicectl-capture-screenshot.json")) ;;
        """)
        let picker = TestPicker()
        let destination = try makeTemporaryFolder("saved").appendingPathComponent("clip.mp4")
        picker.destination = destination
        let (_, controller, temporary) = try await enabledDevice(stub: stub, picker: picker)

        await controller.recordScreen(udid: Self.udid)

        XCTAssertEqual(try Data(contentsOf: destination), Data("captured".utf8))
        XCTAssertEqual(controller.messages[Self.udid], "Saved clip.mp4.")
        XCTAssertTrue(try XCTUnwrap(picker.suggestedNames.first).hasSuffix(".mp4"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.path), [])
        let call = try XCTUnwrap(stub.deviceCalls.first { $0.contains("screen-record") })
        XCTAssertTrue(call.contains("--duration 10"))
    }

    func testTheCapabilityOfAPhysicalDevice() {
        XCTAssertEqual(DeviceCapabilities.physicalApple(supportsRecording: true), [.screenshot, .record])
        XCTAssertEqual(DeviceCapabilities.physicalApple(supportsRecording: false), [.screenshot])
        XCTAssertFalse(DeviceCapabilities.physicalApple(supportsRecording: true).contains(.mirror))
        XCTAssertFalse(DeviceCapabilities.physicalApple(supportsRecording: true).contains(.touch))
    }
}
