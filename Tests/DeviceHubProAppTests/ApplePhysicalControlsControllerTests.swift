import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// A physical iPhone's Controls panel on a stub devicectl that
/// replays the captures of the dedicated test iPhone (an iPhone 12 on iOS
/// 27.0; provenance in `ApplePhysicalControlsTests` and
/// `ApplePhysicalDeviceTests`): the rows its capability list offers, the
/// attach's reads, the poll's one spawn per tick, the writes and their
/// read-backs, and that nothing reaches a device that is not enabled.
@MainActor
final class ApplePhysicalControlsControllerTests: XCTestCase {
    private static let udid = PhysicalFixtures.udid

    private func stubArms() -> String {
        let pasteJSON = PhysicalFixtures.url("devicectl-pasteboard-paste.json").path
        let pasteText = PhysicalFixtures.url("devicectl-pasteboard-paste.stdout.txt").path
        return """
          *"device info appearance"*)
            \(PhysicalFixtures.json("devicectl-info-appearance-baseline.json")) ;;
          *"device info voiceover"*)
            \(PhysicalFixtures.json("devicectl-info-voiceover.json")) ;;
          *"device settings appearance"*"--mode dark"*)
            \(PhysicalFixtures.json("devicectl-settings-appearance-mode-dark.json")) ;;
          *"device settings appearance"*"--reduce-motion on"*)
            \(PhysicalFixtures.json("devicectl-settings-appearance-reduce-motion-on.json")) ;;
          *"device settings appearance"*"--text-size small"*)
            \(PhysicalFixtures.json("devicectl-settings-appearance-text-size-small.json")) ;;
          *"device settings voiceover"*"--enable"*)
            \(PhysicalFixtures.json("devicectl-settings-voiceover-enable.json")) ;;
          *"device simulate location coordinate"*)
            \(PhysicalFixtures.json("devicectl-simulate-location-coordinate.json")) ;;
          *"device simulate location clear"*)
            \(PhysicalFixtures.json("devicectl-simulate-location-clear.json")) ;;
          *"device pasteboard copy"*)
            \(PhysicalFixtures.json("devicectl-pasteboard-copy.json")) ;;
          *"device pasteboard paste"*)
            \(PhysicalFixtures.copy(from: pasteJSON)); cat \(SimulatorFixtures.quoted(pasteText)); exit 0 ;;
        """
    }

    private func harness(
        enabled: Bool = true,
        extra: String = ""
    ) async throws -> (controller: AppleControlsController, stub: StubTool, status: StatusCenter) {
        let stub = try makePhysicalStub(extra: extra + stubArms())
        let inventory = try await makeListedPhysicalInventory(stub: stub, enabled: enabled)
        let preferences = AppPreferences(defaults: .scratch())
        let tooling = AppleTooling.stubbed(
            simctl: nil,
            devicectl: stub,
            devicesDirectory: try makeTemporaryFolder("set"),
            logsDirectory: try makeTemporaryFolder("logs")
        )
        let simulators = SimulatorInventory(apple: tooling, preferences: preferences)
        addTeardownBlock { @MainActor in simulators.stop() }
        let status = StatusCenter()
        let controller = AppleControlsController(
            simulators: simulators,
            preferences: preferences,
            memory: AppleDeviceMemory(preferences: preferences),
            status: status
        )
        controller.physicalClient = { await inventory.client(for: $0) }
        return (controller, stub, status)
    }

    /// The device commands a stub saw, without the device and JSON options.
    private func deviceCommands(_ stub: StubTool) -> [String] {
        // `<words> --device <id> --json-output <file> -q -t <n> <tail…>`
        stub.deviceCalls.map {
            $0.replacingOccurrences(
                of: " --device \\S+ --json-output \\S+ -q -t [0-9]+",
                with: "",
                options: .regularExpression
            )
        }
    }

    // MARK: - Rows

    func testTheIPhone12ShowsTheRowsItsFeaturesAllow() async throws {
        let (controller, stub, _) = try await harness()
        await controller.attachPhysical(Self.udid)
        XCTAssertTrue(controller.isLoaded)
        XCTAssertTrue(controller.isPhysical)
        XCTAssertNil(controller.physicalFailure)
        XCTAssertEqual(Set(controller.groups.flatMap(\.rows)), ControlsRow.appleDeviceRows)
        XCTAssertEqual(controller.groups.map(\.id), [.displayAndSound, .accessibility, .location])
        XCTAssertEqual(
            controller.groups.first?.rows,
            [.appearance, .liquidGlass, .textSize, .reduceMotion, .showBorders, .reduceTransparency]
        )
        // No push, permissions, target app, links, status bar, language or time rows.
        XCTAssertFalse(controller.groups.flatMap(\.rows).contains(.targetApp))
        XCTAssertFalse(controller.groups.flatMap(\.rows).contains(.linkURL))

        // The capability list and each row's first read: nothing else.
        XCTAssertEqual(deviceCommands(stub), ["device info details", "device info appearance", "device info voiceover"])

        // What the reads said.
        XCTAssertEqual(controller.state.dark, false)
        XCTAssertEqual(controller.state.textSize, .large)
        XCTAssertEqual(controller.state.liquidGlassOpacity, 0.5)
        XCTAssertEqual(controller.state.voiceOver, false)
        XCTAssertEqual(controller.state.colorFilter, .some(nil))
        XCTAssertEqual(controller.state.reduceMotion, false)
    }

    func testHiddenRowsAreNamedWithTheirReasons() async throws {
        let (controller, _, _) = try await harness()
        await controller.attachPhysical(Self.udid)
        let hidden = Dictionary(uniqueKeysWithValues: controller.hiddenRows.map { ($0.title, $0.reason) })
        XCTAssertEqual(Set(hidden.keys), [
            "Sound", "Orientation", "Face ID / Touch ID", "Memory warning", "Push notification", "Permissions",
            "Links", "Language", "24-hour time", "Time zone", "Status bar",
        ])
        XCTAssertEqual(hidden["Sound"], AppleControlsRouting.physicalVolumeUnavailable)
        XCTAssertEqual(hidden["Orientation"], AppleControlsRouting.physicalOrientationUnavailable)
        XCTAssertEqual(hidden["Memory warning"], AppleControlsRouting.physicalMemoryWarningUnavailable)
        XCTAssertEqual(hidden["Status bar"], AppleControlsRouting.physicalSimulatorOnly)
        XCTAssertEqual(hidden["Face ID / Touch ID"], AppleControlsRouting.physicalBiometricsUnavailable)
    }

    func testAFeatureThePhoneDoesNotListHidesItsRow() async throws {
        // SYNTHETIC: the test iPhone's `details` capture with the Liquid Glass
        // and pasteboard capabilities removed (no capture of a phone without
        // them exists).
        let details = try makeTemporaryFolder("details").appendingPathComponent("details.json")
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try PhysicalFixtures.data("devicectl-info-details.json")) as? [String: Any]
        )
        var result = try XCTUnwrap(document["result"] as? [String: Any])
        var capabilities = try XCTUnwrap(result["capabilities"] as? [[String: Any]])
        capabilities.removeAll {
            [ApplePhysicalFeature.customizeLiquidGlass.rawValue, ApplePhysicalFeature.pasteboard.rawValue]
                .contains($0["featureIdentifier"] as? String ?? "")
        }
        result["capabilities"] = capabilities
        document["result"] = result
        try JSONSerialization.data(withJSONObject: document).write(to: details)

        let (controller, _, _) = try await harness(extra: """
          *"device info details"*)
            \(PhysicalFixtures.json(from: details.path)) ;;
        """)
        await controller.attachPhysical(Self.udid)
        let rows = Set(controller.groups.flatMap(\.rows))
        XCTAssertFalse(rows.contains(.liquidGlass))
        XCTAssertTrue(rows.contains(.appearance))
        XCTAssertTrue(controller.hiddenRows.contains { $0.title == "Liquid Glass" && $0.reason.contains("Customize Liquid Glass") })
    }

    // MARK: - The poll and the writes

    func testThePollSpendsOneSpawnPerTick() async throws {
        let (controller, stub, _) = try await harness()
        await controller.attachPhysical(Self.udid)
        let before = stub.deviceCalls.count
        for _ in 0..<4 { await controller.pollTick() }
        XCTAssertEqual(Array(deviceCommands(stub).suffix(4)), [
            "device info appearance", "device info voiceover", "device info appearance", "device info voiceover",
        ])
        XCTAssertEqual(stub.deviceCalls.count - before, 4)
    }

    /// A write's answer is the read-back; the row updates from it.
    func testWritesGoThroughDevicectlAndReadBack() async throws {
        let (controller, stub, _) = try await harness()
        await controller.attachPhysical(Self.udid)
        await controller.setAppearance(dark: true)
        XCTAssertEqual(controller.state.dark, true)
        await controller.setReduceMotion(true)
        XCTAssertEqual(controller.state.reduceMotion, true)
        await controller.setTextSize(.small)
        XCTAssertEqual(controller.state.textSize, .small)
        await controller.setVoiceOver(true)
        XCTAssertEqual(controller.state.voiceOver, true)
        let commands = deviceCommands(stub)
        XCTAssertTrue(commands.contains("device settings appearance --mode dark"), "\(commands)")
        XCTAssertTrue(commands.contains("device settings appearance --reduce-motion on"), "\(commands)")
        XCTAssertTrue(commands.contains("device settings appearance --text-size small"), "\(commands)")
        XCTAssertTrue(commands.contains("device settings voiceover --enable"), "\(commands)")
    }

    func testTheLocationIsSetAsACoordinateAndClearedThroughDevicectl() async throws {
        let (controller, stub, _) = try await harness()
        await controller.attachPhysical(Self.udid)
        await controller.setLocation(.coordinate(name: "İstanbul", latitude: 41.0082, longitude: 28.9784))
        XCTAssertEqual(controller.location?.title, "İstanbul")
        await controller.setLocation(nil)
        XCTAssertNil(controller.location)
        let commands = deviceCommands(stub)
        XCTAssertTrue(
            commands.contains("device simulate location coordinate --latitude 41.008200 --longitude 28.978400"),
            "\(commands)"
        )
        XCTAssertTrue(commands.contains("device simulate location clear"), "\(commands)")
        XCTAssertEqual(controller.locationScenarios, [], "a phone has no scenarios")
    }

    func testTheClipboardSendsAndPullsText() async throws {
        let (controller, stub, _) = try await harness()
        await controller.attachPhysical(Self.udid)
        let sent = await controller.sendPasteboard("from the Mac")
        XCTAssertTrue(sent)
        let pulled = await controller.pullPasteboard()
        XCTAssertEqual(pulled, "devicehubpro-pasteboard-test")
        let commands = deviceCommands(stub)
        XCTAssertTrue(commands.contains { $0.hasPrefix("device pasteboard copy --file ") }, "\(commands)")
        XCTAssertTrue(commands.contains("device pasteboard paste"), "\(commands)")
    }

    /// A phone answering CoreDevice 1001 takes the row out at once.
    func testACallThatAnswers1001HidesItsRow() async throws {
        // SYNTHETIC: the captured `info audio` 1001 with its feature
        // identifier changed to the pasteboard's, for a call that the
        // stubbed phone refuses (no capture of a pasteboard 1001 exists).
        let text = try String(contentsOf: PhysicalFixtures.url("devicectl-info-audio.json"), encoding: .utf8)
            .replacingOccurrences(of: ApplePhysicalFeature.audioOutput.rawValue, with: ApplePhysicalFeature.pasteboard.rawValue)
        let file = try makeTemporaryFolder("unsupported").appendingPathComponent("unsupported.json")
        try Data(text.utf8).write(to: file)
        let (controller, _, status) = try await harness(extra: """
          *"device pasteboard copy"*)
            \(PhysicalFixtures.json(from: file.path, exitCode: 1)) ;;
        """)
        await controller.attachPhysical(Self.udid)
        XCTAssertTrue(controller.route(.clipboard).isOffered)
        let sent = await controller.sendPasteboard("x")
        XCTAssertFalse(sent)
        XCTAssertFalse(controller.route(.clipboard).isOffered)
        XCTAssertTrue(controller.route(.appearance).isOffered)
        XCTAssertNotNil(status.errorMessage)
    }

    // MARK: - Devices that are not usable

    /// Not enabled: no client, so not one command reaches the device.
    func testADeviceThatIsNotEnabledGetsNoCommand() async throws {
        let (controller, stub, _) = try await harness(enabled: false)
        await controller.attachPhysical(Self.udid)
        XCTAssertTrue(controller.isLoaded)
        XCTAssertNotNil(controller.physicalFailure)
        XCTAssertEqual(controller.groups.count, 0)
        XCTAssertEqual(stub.deviceCalls, [], "nothing but the list reached the stub")
        await controller.pollTick()
        XCTAssertEqual(stub.deviceCalls, [])
    }

    /// A capability read that fails leaves a reason and no rows.
    func testAFailedCapabilityReadLeavesAReasonAndNoRows() async throws {
        let (controller, _, _) = try await harness(extra: """
          *"device info details"*)
            exit 1 ;;
        """)
        await controller.attachPhysical(Self.udid)
        XCTAssertTrue(controller.isLoaded)
        XCTAssertTrue(controller.physicalFailure?.hasPrefix("Could not read this device's capabilities") == true)
        XCTAssertTrue(controller.groups.isEmpty)
    }

    /// The simulator path is untouched: attaching a simulator clears the
    /// physical mode.
    func testAttachingASimulatorLeavesPhysicalMode() async throws {
        let (controller, _, _) = try await harness()
        await controller.attachPhysical(Self.udid)
        XCTAssertTrue(controller.isPhysical)
        await controller.attach("95D9676B-3317-4BA5-8CF6-3CDD0488CACA")
        XCTAssertFalse(controller.isPhysical)
        XCTAssertNil(controller.physicalFailure)
    }
}
